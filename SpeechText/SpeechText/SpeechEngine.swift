// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Speech
import AVFoundation
import os.log
import SpeechTextCore

private let seLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SpeechText",
                            category: "SpeechEngine")

/// The single stored source of truth for the engine's state. The four booleans the
/// views read are computed from it, so a state can no longer be half-updated — a stop
/// that cleared `isRecording` a line before it set `isTranscribing` could be observed
/// in between as "idle".
enum RecordingPhase: Equatable {
    case idle
    /// The capture's `start()` running on the background queue.
    case starting
    case recording
    /// `segmentInFlight` is true while a batch/stream segment handed over at pause is
    /// still being transcribed — that is exactly when `isTranscribing` used to be true
    /// while paused. Apple pauses never set it (the live text is handed over at once).
    case paused(segmentInFlight: Bool)
    /// A stop is waiting for the final text.
    case finishing

    var isRecording: Bool { self == .recording }
    var isPaused: Bool { if case .paused = self { return true } else { return false } }
    var isTranscribing: Bool {
        switch self {
        case .finishing, .paused(segmentInFlight: true): return true
        default: return false
        }
    }
    var isStartingEngine: Bool { self == .starting }
}

/// Main-actor state. The audio thread reaches only the writer and the session's `feed`,
/// and `engineQueue` only the capture it is handed.
@MainActor @Observable
final class SpeechEngine {
    private(set) var phase: RecordingPhase = .idle {
        didSet {
            dlog("Engine", "phase: \(oldValue) → \(phase)")
            // Same signal the old `isTranscribing` didSet fired: resume waiters only on
            // the true → false edge. `paused(true) → finishing` is deliberately not an
            // edge — the segment is still in flight and a stop is now waiting on it too.
            if oldValue.isTranscribing && !phase.isTranscribing { resumeTranscriptionWaiters() }
        }
    }
    var isRecording: Bool { phase.isRecording }
    var isPaused: Bool { phase.isPaused }
    var isTranscribing: Bool { phase.isTranscribing }
    /// True while the audio engine is being prepared on the background thread.
    /// Used by the overlay to show a "preparing" animation before the mic is live.
    var isStartingEngine: Bool { phase.isStartingEngine }

    /// Every piece of text this recording has issued, with identity and state. The
    /// sessions report cumulative `committed` / `partial` strings; the layer turns them
    /// into spans, so a surface can draw the boundary between what has settled and what
    /// is still moving instead of receiving one re-joined string.
    private(set) var spanLayer = TranscriptSpanLayer()
    /// The current segment's text, settled and moving joined — what it has always been.
    /// Computed from the span layer now, so there is one source of truth; `@Observable`
    /// tracks it through `spanLayer`.
    var liveText: String { spanLayer.segmentText }
    var finalText = "" {
        didSet {
            if oldValue != finalText {
                dlog("Engine", "finalText updated: \(finalText.count) chars", level: .debug)
            }
        }
    }
    var editedText: String = ""
    /// Set when a segment's transcription is ready to be inserted at cursor
    var pendingInsertionText: String?
    /// The spans that text is made of, when it can be attributed to them — a sink that
    /// records ranges (the Record Window's `TextInsertionHandler`) keys its insertions by
    /// these, so a later pass can find and replace exactly one span. Empty when the text
    /// cannot be attributed (an Apple pause hands back its own joined string, whose
    /// partial the layer has not committed yet); the sink then inserts one untracked piece.
    private(set) var pendingInsertionSpans: [TranscriptSpanID] = []
    var errorMessage: String? {
        didSet {
            if let msg = errorMessage { dlog("Engine", "⚠ errorMessage: \(msg)", level: .error) }
        }
    }
    /// Callers parked in `awaitTranscription()`. Resumed from `phase`'s didSet — the
    /// `isTranscribing` true → false edge — so there is exactly one place the signal
    /// fires, and it fires after every path has already written its
    /// `finalText` / `errorMessage` / `lastRecordID`.
    private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []
    var barLevels: [CGFloat] = Array(repeating: 0, count: 12)
    /// The latest per-segment levels from the audio thread, and whether a main-queue hop
    /// to fold them into `barLevels` is already scheduled — see `installAudioTap`.
    private nonisolated let levelBox = LevelBox()
    private nonisolated let levelHopPending = AtomicFlag()

    /// Kept alive between sessions so the speech model stays loaded (~300-500ms to
    /// create); rebuilt only when the locale changes.
    private var speechRecognizer: SFSpeechRecognizer?
    /// Created fresh for each recording session so it always binds to the current audio
    /// device: `AVAudioEngine` on the system's input, or the one device the microphone
    /// choice names (`AudioCapture`).
    private var audioEngine: AudioCapture?
    /// Collects every segment's audio, whatever the tier: the batch upload, the stream's
    /// fallback, and the archive History keeps when nothing was recognised.
    private var audioBufferWriter: AudioBufferWriter?
    /// The recogniser for the current segment. One per segment: a resume makes a new one.
    private var session: RecognitionSession?
    private var transcriptionTask: Task<Void, Never>?
    /// Provider, model, keys and locale for the current/last session, read from
    /// UserDefaults once at `startRecording` so a Settings change mid-recording cannot
    /// switch the provider between pause and stop. Also kept for restart after a device change.
    private var configuration: RecordingConfiguration?
    private var providerType: STTProviderType { configuration?.provider ?? .apple }
    /// Incremented each time the engine is torn down. Background engine-start closures compare
    /// against this to detect stale sessions and bail out safely.
    private var engineStartToken = 0
    /// `prepare()`/`start()` run here, and so does the `stop()` of an engine that may
    /// still be starting: `AVAudioEngine` is not thread-safe, and a cancel that stopped
    /// it on main while the start was mid-flight raced two mutations of one graph.
    private let engineQueue = DispatchQueue(label: "SpeechEngine.audio", qos: .userInitiated)
    /// True once a pause has started `finish()` on the current segment — or, for Apple,
    /// written its History row — so a subsequent stop knows not to send the same audio a
    /// second time, nor to write the same segment twice.
    private var segmentFinishStarted = false
    /// History entry written for the most recent successful transcription, so the LLM
    /// pass (which runs later, in AppState or the Record Window) can attach itself to it.
    private(set) var lastRecordID: UUID?
    /// The History row of the latest segment that failed for want of a network
    /// (`RecognitionOutcome.offline`) with its audio archived — what "No connection —
    /// saved to History" offers to retry. Kept apart from `lastRecordID`, which the
    /// LLM pass and `recordApps` attach to and which must never name a failed row.
    /// Cleared on each new session.
    private(set) var offlineRecordID: UUID?
    /// The last segment failed because the vendor no longer serves the model
    /// (`RecognitionOutcome.modelUnavailable`); the failure notice offers the picker.
    private(set) var failedForModel = false
    /// Whether a segment that produced no words, with no error, is written to History
    /// (with its audio kept for a retry). Off for the Edit shortcut's instruction: saying
    /// nothing there means "just polish", and the edit writes its own record.
    var recordsEmptyOutcomes = true

    func requestMicrophoneAccess(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        // `@Sendable`: the answer comes on a queue of AVFoundation's.
        AVCaptureDevice.requestAccess(for: .audio) { @Sendable granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    /// A start failed before any audio was taken — the session could not open, or the
    /// audio engine would not start. Called with the message, before the phase goes
    /// `.idle`, so the inline flow can take its overlay down: nothing else reads
    /// `errorMessage` until a stop, and there is no stop coming.
    var onStartFailure: ((String) -> Void)?

    /// The recogniser failed before it produced any text, and the engine has stopped the
    /// recording itself (`RecognitionFailure.endsRecording`). Called once the phase is
    /// `.finishing`, so `awaitTranscription()` waits for the stop's result — the error,
    /// with the audio in History. The owner did not ask for this stop and has no waiter
    /// parked; without this it would leave its overlay listening until the user stopped.
    /// Unset (the Record Window) the stop still happens: the panel's status line shows
    /// `errorMessage` and its knob goes back to idle.
    var onRecognitionFailure: ((String) -> Void)?

    /// The microphone went away under a live recording — no usable input after a device
    /// change, a device that would not settle, a restart's engine that would not start —
    /// and the engine has stopped the recording itself, as a stop does: what was said is
    /// transcribed and written to History. Called once the phase is `.finishing`, with
    /// the reason. The owner did not ask for this stop and has no waiter parked; without
    /// this the inline dictation was never pasted, and its overlay stayed up until the
    /// next press — which, with the stop still transcribing, cancelled it. Unset (the
    /// Record Window), the stop's text is handed to the panel as a pause's is.
    var onMicrophoneLost: ((String) -> Void)?

    /// A segment failed for want of a network and its audio is in History
    /// (`offlineRecordID`). The owner hands it to `OfflineRetry` to be transcribed once the
    /// network is back — or leaves this unset where that would be no use (an Edit
    /// instruction, a Try it dictation).
    var onSavedOffline: ((UUID) -> Void)?

    /// What the microphone choice came to for the engine running now.
    private(set) var microphone: MicrophoneResolution?

    /// Automatic recorded from the Mac's microphone instead of Bluetooth headphones —
    /// the inline flow says so, once.
    var onMicrophoneSubstituted: ((MicrophoneResolution) -> Void)?

    func startRecording(locale: String = "en-US") {
        guard case .idle = phase else {
            // A second start while one is starting rebuilt the session under it; one
            // while a stop is finishing cancelled that stop's result. Both are ignored —
            // the callers cancel or wait explicitly.
            dlog("Engine", "startRecording: phase=\(phase), ignoring")
            return
        }
        let configuration = RecordingConfiguration.current(locale: locale)
        // Every caller is told the same way as for a microphone that would not open; the
        // inline flow asks first, to offer the picker (`AppState.startRecording`).
        guard !configuration.modelChoiceMissing else {
            let message = "Choose a model for \(configuration.provider.vendor.modelChoiceTarget) in Settings to dictate."
            dlog("Engine", "startRecording: no model chosen for \(configuration.provider.rawValue) — refused", level: .notice)
            errorMessage = message
            onStartFailure?(message)
            return
        }
        self.configuration = configuration
        dlog("Engine", "startRecording: locale=\(locale), provider=\(providerType.rawValue)")
        // A local model that is not loaded yet starts loading while the user speaks,
        // rather than after the stop. Loaded already, this costs nothing.
        if configuration.provider == .local {
            LocalSTT.prewarm(configuration.modelID(for: .local))
        }
        editedText = ""
        pendingInsertionText = nil
        pendingInsertionSpans = []
        lastRecordID = nil
        offlineRecordID = nil
        failedForModel = false
        spanLayer.reset()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        setupRecordingSession()
    }

    func pauseRecording() {
        pauseRecording(thenResume: nil)
    }

    /// `thenResume`: a device change is closing the segment, and the next one opens on
    /// the new device in `locale` as soon as that cannot cost this one — at once when the
    /// session already has the text (Apple), once its transcription has landed otherwise,
    /// since a resume before then would cancel the upload with the segment in it.
    private func pauseRecording(thenResume resumeLocale: String?) {
        dlog("Engine", "pauseRecording: phase=\(phase), provider=\(providerType.rawValue)")
        guard isRecording, let audioEngine, let session, let configuration else {
            dlog("Engine", "pauseRecording: guard failed (phase=\(phase), audioEngine=\(self.audioEngine != nil), session=\(self.session != nil))", level: .notice)
            return
        }
        stopAudioEngine(audioEngine)
        barLevels = Array(repeating: 0, count: 12)

        if let liveSegment = session.pause().map(configuration.cleaned) {
            let segmentText = configuration.finished(liveSegment)
            // The session already has the text (Apple): hand it over, no transcribing state.
            dlog("Engine", "pauseRecording(apple): segmentText=\(segmentText.count) chars")
            phase = .paused(segmentInFlight: false)
            if !segmentText.isEmpty {
                // One History row per segment, as the batch tier writes: the stop's row
                // carries only the last segment, and a resume cancels this one's task
                // without an outcome.
                recordOutcome(RecognitionOutcome(text: segmentText, error: nil,
                                                 audioFileURL: nil, cancelled: false),
                              writer: audioBufferWriter, locale: configuration.historyLocale)
                // A stop from this pause finishes from it: asked again, the session hands
                // back the same segment, and History got it twice. A pause with nothing
                // recognised leaves it to the stop, which still archives its audio.
                segmentFinishStarted = true
                // The Dictionary changed a word the live spans still spell the old way:
                // the segment's text is the authority, as a batch result is.
                if segmentText != liveSegment {
                    spanLayer.commitSegment(segmentText)
                }
                setPendingInsertion(segmentText)
            }
            if let resumeLocale { resumeRecording(locale: resumeLocale) }
            return
        }

        phase = .paused(segmentInFlight: true)
        // This segment's audio is being sent now. Stopping without resuming must not
        // send it a second time — that produced duplicate requests (and duplicate
        // history entries, and duplicate billing) for one recording.
        segmentFinishStarted = true
        let writer = audioBufferWriter
        let locale = configuration.historyLocale
        dlog("Engine", "pauseRecording(\(configuration.streams ? "stream" : "batch")): starting transcription task")

        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await Self.finishSegment(session, configuration: configuration)
            // A cancel can land while the upload is still in flight. If the reply came
            // back first, the segment was still transcribed, so it is still written to
            // History — but nothing that belongs to the engine's state now is touched.
            // A resume no longer cancels this task: it waits for the segment to land.
            let superseded = Task.isCancelled
            self.recordOutcome(outcome, writer: writer, locale: locale, superseded: superseded)
            guard !superseded else { return }
            if outcome.error == nil {
                self.spanLayer.commitSegment(outcome.text)
                self.spanLayer.settleSegment()
                if !outcome.text.isEmpty {
                    self.setPendingInsertion(outcome.text)
                }
            }
            // Still paused (a stop in the meantime moved on to .finishing and its
            // waiter owns the transition): the segment has landed.
            if case .paused(segmentInFlight: true) = self.phase {
                self.phase = .paused(segmentInFlight: false)
                if let resumeLocale { self.resumeRecording(locale: resumeLocale) }
            }
        }
    }

    /// The session's answer with the finished text, worked out off main: `finish()` is
    /// nonisolated, and the text pass after it ran off main before the engine was a
    /// main-actor type, as it still does. The task that awaits this is the engine's, on main.
    private nonisolated static func finishSegment(_ session: RecognitionSession,
                                                  configuration: RecordingConfiguration) async -> RecognitionOutcome {
        var finished = await session.finish()
        finished.text = configuration.finished(finished.text)
        return finished
    }

    func resumeRecording(locale: String = "en-US") {
        dlog("Engine", "resumeRecording: phase=\(phase), locale=\(locale)")
        // Not while the paused segment is still being transcribed: the resume cancels
        // `transcriptionTask`, and with it the upload — the segment's audio deleted, its
        // History row never written, its text never handed over.
        guard case .paused(segmentInFlight: false) = phase else { return }
        configuration?.locale = locale
        transcriptionTask?.cancel()
        transcriptionTask = nil
        setupRecordingSession()
    }

    /// Common setup for a new recording segment. Creates a fresh engine, buffer writer
    /// and recognition session.
    private func setupRecordingSession() {
        guard let configuration else {
            dlog("Engine", "setupRecordingSession: no configuration — startRecording was never called", level: .fault)
            return
        }
        let locale = configuration.locale
        dlog("Engine", "setupRecordingSession: locale=\(locale), provider=\(configuration.provider.rawValue)")
        var timer = StartTimer()
        phase = .starting
        // Fresh segment with a fresh buffer writer — nothing has been sent for it yet.
        segmentFinishStarted = false
        // A resume (or a restart after a device change) opens the next segment rather
        // than wiping the timeline: `liveText` reads the current segment, so the ghost
        // text starts empty exactly as it did when it was a stored string.
        spanLayer.beginSegment()
        finalText = ""
        errorMessage = nil
        barLevels = Array(repeating: 0, count: 12)

        session?.cancel()
        session = nil
        timer.lap("teardown")

        let engine = makeAudioEngine()
        timer.lap("capture")

        let writer = AudioBufferWriter()
        audioBufferWriter = writer

        if configuration.provider == .apple {
            // Reuse the existing recognizer when the locale is unchanged — creating a new
            // SFSpeechRecognizer reloads the speech model (~300-500ms on first use).
            if speechRecognizer?.locale.identifier != locale {
                speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
            }
        }

        let newSession = makeRecognitionSession(configuration: configuration, writer: writer,
                                                recognizer: speechRecognizer)
        // `newSession` must be weak: the closure is stored on the session itself, so a
        // strong capture is a retain cycle that leaks a session (and, for the cloud
        // tiers, its AudioBufferWriter and AVAudioConverter) per segment. While the
        // session is current the engine holds it strongly, so the identity guard still
        // sees every event that should be acted on.
        // The committed string is cumulative and changes only on a commit, while a
        // partial arrives several times a second: cleaning the whole committed text on
        // every event ran three regexes per word over the entire dictation each time.
        // Its last result is kept and reused while the input is unchanged.
        var cleanedCommitted = (raw: "", cleaned: "")
        newSession.onEvent = { [weak self, weak newSession] event in
            guard let self, let newSession, self.session === newSession else { return }
            switch event {
            case .live(let committed, let partial):
                // Cleaned here, before the text becomes a span, and not at the stop: the
                // overlay draws the spans while the user speaks, and the layer turns only
                // the increment of the cumulative committed text into a new span — cleaned
                // text that stopped extending what came before would be drawn as a revision.
                if committed != cleanedCommitted.raw {
                    cleanedCommitted = (committed, configuration.cleaned(committed))
                }
                self.spanLayer.ingest(committed: cleanedCommitted.cleaned,
                                      partial: configuration.cleaned(partial))
            case .failure(let failure):
                // A failure after text is not the dictation's: the recording goes on and
                // the stop pastes what was heard (`recordOutcome`). Left in `errorMessage`
                // until the stop, it made the whole dictation a failure, handed to the
                // Record Window instead of pasted. The session logged the error itself.
                guard failure.endsRecording else {
                    dlog("Engine", "recognition error after text — not a failure, the recording goes on", level: .notice)
                    return
                }
                self.errorMessage = failure.message
                self.endRecording(after: failure)
            }
        }
        session = newSession
        timer.lap("session")

        // The session opens first (a stream's TLS handshake overlaps the hardware start),
        // then the tap, then the engine.
        do {
            try newSession.start()
        } catch {
            // Same terminal shape as every other failure path: the result fields first,
            // then `.idle` (so `isStartingEngine` doesn't stay true forever and parked
            // `awaitTranscription()` callers see a finished result), then `cleanup()` —
            // which also drops the fresh capture, its configuration-change hook and
            // the half-built session that would otherwise leak until the next start.
            errorMessage = error.localizedDescription
            onStartFailure?(error.localizedDescription)
            phase = .idle
            cleanup()
            return
        }
        timer.lap("session start")

        guard installAudioTap() else {
            // No input device: the same terminal shape as a session that would not open.
            let message = errorMessage ?? "No audio input device available"
            onStartFailure?(message)
            phase = .idle
            cleanup()
            return
        }
        timer.lap("tap")
        reportMainThreadStart(timer, as: "start")
        startAudioEngine(engine, timer: timer)
    }

    /// Past this, a start held the main thread long enough to be seen: the overlay that
    /// was ordered front before it could not draw.
    private static let slowStartThreshold: TimeInterval = 0.25

    /// The main thread's share of a start, step by step. A slow one also goes to the
    /// system log at a level it keeps, so a stall is still readable after the app quit.
    private func reportMainThreadStart(_ timer: StartTimer, as what: String) {
        let elapsed = timer.elapsed
        guard elapsed > Self.slowStartThreshold else {
            dlog("Engine", "\(what) on the main thread: \(StartTimer.ms(elapsed)) (\(timer.summary))")
            return
        }
        dlog("Engine", "⚠ slow \(what) held the main thread \(StartTimer.ms(elapsed)) (\(timer.summary))", level: .notice)
        seLog.warning("slow \(what, privacy: .public) held the main thread \(StartTimer.ms(elapsed), privacy: .public) (\(timer.summary, privacy: .public))")
    }

    /// A fresh capture on the microphone the choice comes to *now* — the old one is torn
    /// down first, which avoids stale-format crashes when the user switches devices
    /// between recordings — with its configuration changes routed to
    /// `handleAudioConfigChange`. Resolved on every capture — a start, a resume, a
    /// restart after a device change — so a picked headset that leaves falls back on its
    /// own. A resolution that names a device is captured from that device alone
    /// (`DeviceCapture`, see AudioCapture.swift for why not through `AVAudioEngine`); one
    /// that names none keeps `AVAudioEngine` on the system's input, the path the app
    /// always took. A device that cannot be opened is logged and the system's input
    /// used; the microphone choice never fails a recording.
    private func makeAudioEngine(waiting: Bool = false) -> AudioCapture {
        tearDownAudioEngine(waiting: waiting)
        let capture = makeCapture()
        audioEngine = capture
        capture.onConfigurationChange = { [weak self, weak capture] in
            // A capture already replaced has nothing left to say.
            guard let self, let capture, self.audioEngine === capture else { return }
            self.handleAudioConfigChange()
        }
        return capture
    }

    private func makeCapture() -> AudioCapture {
        #if DEBUG
        if E2EMode.audioInputs != nil {
            // An end-to-end run: no microphone is opened at all.
            let clip = E2EMode.nextAudioInput()
            microphone = MicrophoneResolution()
            do {
                let capture = try FileCapture(url: clip)
                dlog("Engine", "microphone: file \(clip?.lastPathComponent ?? "(silence)")")
                return capture
            } catch {
                dlog("Engine", "⚠ could not read \(clip?.path ?? "?"): \(error.localizedDescription) — silence", level: .error)
                return try! FileCapture(url: nil)
            }
        }
        #endif
        let resolveBegan = ProcessInfo.processInfo.systemUptime
        let resolution = AudioInputDevices.resolve(configuration?.microphone ?? .automatic)
        let resolved = ProcessInfo.processInfo.systemUptime - resolveBegan
        if resolved > Self.slowStartThreshold {
            dlog("Engine", "⚠ resolving the microphone took \(StartTimer.ms(resolved))", level: .notice)
        }
        microphone = resolution
        guard let device = resolution.device else {
            dlog("Engine", "microphone: system input")
            return EngineCapture()
        }
        guard let id = AudioInputDevices.deviceID(forUID: device.uid) else {
            dlog("Engine", "microphone: \(device.name) is gone — system input", level: .notice)
            microphone = MicrophoneResolution()
            return EngineCapture()
        }
        let openBegan = ProcessInfo.processInfo.systemUptime
        do {
            let capture = try DeviceCapture(deviceID: id)
            dlog("Engine", "microphone: \(device.name) (\(Int(capture.format.sampleRate)) Hz, "
                 + "resolved in \(StartTimer.ms(resolved)), opened in \(StartTimer.ms(ProcessInfo.processInfo.systemUptime - openBegan)))"
                 + (resolution.avoided.map { " instead of \($0.name)" } ?? "")
                 + (resolution.pickedIsMissing ? " — the picked microphone is not connected" : ""))
            if resolution.avoided != nil { onMicrophoneSubstituted?(resolution) }
            return capture
        } catch {
            dlog("Engine", "microphone: could not open \(device.name) (\(error.localizedDescription)) — system input", level: .error)
            microphone = MicrophoneResolution()
            return EngineCapture()
        }
    }

    /// `prepare()` + `start()` acquire audio hardware resources and can block the main
    /// thread for 100–300 ms, so they run on `engineQueue`. The token detects a stale
    /// start (the user stopped before the engine was ready).
    private func startAudioEngine(_ engine: AudioCapture, timer: StartTimer? = nil) {
        engineStartToken += 1
        let token = engineStartToken
        let queued = ProcessInfo.processInfo.systemUptime

        engineQueue.async { [weak self] in
            // A queue still busy with an earlier stop delays the start as surely as a slow
            // device does.
            let began = ProcessInfo.processInfo.systemUptime
            do {
                try engine.start()
            } catch {
                let desc = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.engineStartToken == token else { return }
                    seLog.error("startAudioEngine: audio engine failed to start: \(desc, privacy: .public)")
                    let message = "Audio engine failed to start: \(desc)"
                    guard self.phase == .starting else {
                        // A restart on a new device: the segment is already recording, and
                        // what it holds is ended as a restart with no usable input ends it.
                        // Going idle here reset the writer and cancelled the session — the
                        // dictation gone, with no History row, and the overlay left up.
                        self.endRecording(microphoneLost: message)
                        return
                    }
                    self.errorMessage = message
                    self.onStartFailure?(message)
                    self.phase = .idle
                    self.cleanup()
                }
                return
            }
            let finished = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [weak self] in
                // Session was cancelled (stop pressed before engine finished starting).
                guard let self, self.engineStartToken == token else {
                    self?.engineQueue.async { engine.stop() }
                    return
                }
                // Only a fresh start moves the phase: a restart on a new device is already
                // `.recording`, and a pause or stop that arrived while the restart was in
                // flight has already moved on — resurrecting `.recording` over `.finishing`
                // woke the stop's waiter with an empty result.
                if self.phase == .starting { self.phase = .recording }
                seLog.info("startAudioEngine: audio engine started successfully")
                let now = ProcessInfo.processInfo.systemUptime
                let timing = "waited \(StartTimer.ms(began - queued)) for the queue, started in \(StartTimer.ms(finished - began))"
                    + (timer.map { ", \(StartTimer.ms(now - $0.began)) after the start began" } ?? "")
                if let timer, now - timer.began > 1 {
                    dlog("Engine", "⚠ microphone live late: \(timing)", level: .notice)
                    seLog.warning("microphone live late: \(timing, privacy: .public)")
                } else {
                    dlog("Engine", "microphone live: \(timing)")
                }
            }
        }
    }

    /// The recogniser failed with no text to show for the segment, and nothing it would
    /// be fed from here on is transcribed. What ending the recording means depends on
    /// how far it got.
    private func endRecording(after failure: RecognitionFailure) {
        switch phase {
        case .starting:
            // The session opens before the audio engine, so its task can fail before the
            // microphone is live: that is a start failure, and ends like one — no audio
            // was taken, so there is nothing for History to keep.
            dlog("Engine", "recognition failed before the microphone opened — a start failure", level: .error)
            onStartFailure?(failure.message)
            phase = .idle
            cleanup()
        case .recording:
            // The ordinary stop: `finish()` returns the error at once, and `recordOutcome`
            // writes the History row with the audio taken so far.
            dlog("Engine", "recognition failed before any text — ending the recording", level: .error)
            stopRecording()
            onRecognitionFailure?(failure.message)
        case .idle, .paused, .finishing:
            // A pause or a stop already took the segment, and its outcome carries the error.
            break
        }
    }

    /// The microphone went away under a live recording: it ends as a stop does, and the
    /// owner is told (`onMicrophoneLost`). The reason is the engine's, not the
    /// transcription's — left in `errorMessage`, it made a result with words in it a
    /// failure, handed to the Record Window instead of pasted — so it explains only a
    /// segment that comes back with none (`stopRecording(explainingEmptyBy:)`).
    private func endRecording(microphoneLost reason: String) {
        // Only a live recording: a stop ignores any other phase, and the owner must not be
        // told of a stop that never happened.
        guard case .recording = phase else { return }
        dlog("Engine", "the microphone was lost — ending the recording: \(reason)", level: .error)
        errorMessage = nil
        stopRecording(explainingEmptyBy: reason)
        onMicrophoneLost?(reason)
    }

    /// The audio device changed under a live segment: only the engine and its tap are
    /// rebuilt. The writer and the session stay — the writer is re-prepared for the new
    /// hardware format and keeps appending to the same 16 kHz buffer, so the segment has
    /// no boundary at all, no upload in flight, and nothing to lose.
    private func restartAudioEngine() {
        // Waiting: `installAudioTap` re-prepares the writer, which is only safe once no
        // callback of the old tap can be inside `append`.
        var timer = StartTimer()
        let engine = makeAudioEngine(waiting: true)
        timer.lap("capture")
        guard installAudioTap() else {
            // The new device offers no usable input. Ending the recording here hands the
            // user what was said so far, with the reason; leaving `.recording` standing
            // with no tap was a dead microphone they only found out about at the stop.
            dlog("Engine", "restartAudioEngine: no usable input after the device change — stopping", level: .error)
            if phase == .starting {
                // `stopRecording` ignores `.starting`: end it as a start failure instead.
                let message = errorMessage ?? "No audio input device available"
                onStartFailure?(message)
                phase = .idle
                cleanup()
            } else {
                endRecording(microphoneLost: errorMessage ?? "No audio input device available")
            }
            return
        }
        timer.lap("tap")
        reportMainThreadStart(timer, as: "restart")
        startAudioEngine(engine, timer: timer)
    }

    /// Returns once `isTranscribing` is false. Returns immediately when nothing is in
    /// flight, which is what a stop that never started transcription (or a cancel) needs.
    @MainActor
    func awaitTranscription() async {
        guard isTranscribing else { return }
        await withCheckedContinuation { continuation in
            transcriptionWaiters.append(continuation)
        }
    }

    private func resumeTranscriptionWaiters() {
        guard !transcriptionWaiters.isEmpty else { return }
        let waiters = transcriptionWaiters
        transcriptionWaiters.removeAll()
        // The continuations hop back onto the main actor, so the caller runs after the
        // current call (including its `cleanup()`) has returned — same as the old poll.
        waiters.forEach { $0.resume() }
    }

    /// Cancel any in-progress recording or transcription without producing a result.
    /// `errorMessage` is deliberately left alone.
    func cancelRecording() {
        dlog("Engine", "cancelRecording: phase=\(phase)")
        transcriptionTask?.cancel()
        transcriptionTask = nil
        phase = .idle
        finalText = ""
        // The whole timeline goes: nothing from a cancelled recording is pasted anywhere.
        spanLayer.reset()
        // A segment handed over at a pause and not yet consumed by the panel would
        // otherwise be inserted after the cancel.
        pendingInsertionText = nil
        pendingInsertionSpans = []
        barLevels = Array(repeating: 0, count: 12)
        cleanup()
    }

    func stopRecording() {
        stopRecording(explainingEmptyBy: nil)
    }

    /// `reason`: the engine is ending the recording itself (`endRecording(microphoneLost:)`).
    /// A segment that comes back with no words and no error of its own is that reason's
    /// failure — its History row and the notice say why the dictation ended — and one with
    /// words is handed to the sink as a pause's segment is.
    private func stopRecording(explainingEmptyBy reason: String?) {
        dlog("Engine", "stopRecording: phase=\(phase), provider=\(providerType.rawValue)")
        switch phase {
        case .recording, .paused:
            break
        default:
            // `.starting` is deliberately still ignored (the hotkey path cancels instead).
            dlog("Engine", "stopRecording: not recording or paused, ignoring")
            return
        }
        if isRecording, let audioEngine {
            stopAudioEngine(audioEngine)
        }
        let wasPaused = isPaused

        // Stopping from a paused state where the segment was already sent: the audio is
        // in flight (or done) — finish with that result instead of transcribing it again.
        // An Apple pause that wrote its row is done the same way.
        if wasPaused && segmentFinishStarted {
            dlog("Engine", "stopRecording: segment already transcribed at pause — not resending")
            finalizeAfterPausedTranscription()
            return
        }

        guard let session, let configuration else {
            dlog("Engine", "stopRecording: no session — cleaning up")
            phase = .idle
            cleanup()
            return
        }

        // Stop feeding synchronously, on the thread the Apple chunk-rotation timer fires
        // on: `finish()` only stops that timer after an async hop back to main, and a
        // 50 s rotation firing in the gap would open a fresh, never-fed request whose
        // "no speech" error the token guard would then accept as the segment's error.
        // For the other tiers `pause()` is a stateless no-op; the returned text is
        // recomputed by `finish()`.
        _ = session.pause()

        phase = .finishing
        let writer = audioBufferWriter
        let locale = configuration.historyLocale
        let tier = configuration.provider == .apple ? "apple" : (configuration.streams ? "stream" : "batch")
        dlog("Engine", "stopRecording(\(tier)): liveText=\(liveText.count) chars, starting transcription task")

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            var finished = await Self.finishSegment(session, configuration: configuration)
            if let reason, !finished.cancelled, finished.text.isEmpty, finished.error == nil {
                finished.error = reason
            }
            let outcome = finished
            // A stale task must never touch a newer session's state — but the
            // outcome may still own a segment file (the upload finished before the
            // cancel landed), and `recordOutcome` will never run to release it.
            guard !Task.isCancelled else {
                if let url = outcome.audioFileURL { AudioBufferWriter.cleanup(fileURL: url) }
                return
            }
            self.recordOutcome(outcome, writer: writer, locale: locale)
            self.finalText = outcome.text
            self.spanLayer.commitSegment(outcome.text)
            self.spanLayer.settleSegment()
            // A stop nobody asked for: the Record Window takes a pause's segments only,
            // and would otherwise never show these words.
            if reason != nil, !outcome.text.isEmpty {
                self.setPendingInsertion(outcome.text)
            }
            self.phase = .idle
            self.cleanup()
        }
    }

    /// Completes a stop that arrived while paused, reusing the transcription the pause
    /// already started. Waits for it if it's still running so `awaitTranscription()`
    /// doesn't return before the text lands. The waiter is stored in `transcriptionTask`
    /// so a cancel in the meantime stops it from running `cleanup()` against a newer session.
    private func finalizeAfterPausedTranscription() {
        if let pending = transcriptionTask, !pending.isCancelled,
           case .paused(segmentInFlight: true) = phase {
            // `paused(true) → finishing` keeps `isTranscribing` true throughout, so no
            // waiter wakes up before the text has landed.
            phase = .finishing
            transcriptionTask = Task { [weak self] in
                // Cancelling the waiter must also cancel the segment task it waits on:
                // `pending` is no longer reachable from `transcriptionTask`, and left
                // alive its completion would run against whatever newer session the
                // engine holds by then (and the abandoned upload would still be billed).
                await withTaskCancellationHandler {
                    await pending.value
                    guard let self, !Task.isCancelled else { return }
                    if self.finalText.isEmpty {
                        self.finalText = self.liveText
                    }
                    self.phase = .idle
                    self.cleanup()
                } onCancel: {
                    pending.cancel()
                }
            }
        } else {
            if finalText.isEmpty {
                finalText = liveText
            }
            phase = .idle
            cleanup()
        }
    }

    // MARK: - Insertion

    /// Hands a finished segment to whichever sink is listening, naming the spans it is
    /// made of when they spell exactly that text. The spans are written *before* the
    /// text, because the text is what observers key on and they must see both.
    private func setPendingInsertion(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if spanLayer.segmentStableText == trimmed {
            pendingInsertionSpans = spanLayer.segmentStableSpans.map(\.id)
        } else {
            pendingInsertionSpans = []
            dlog("Span", "pending insertion is not what the spans spell — inserted untracked", level: .notice)
        }
        pendingInsertionText = text
    }

    // MARK: - History

    /// Writes the segment's History entry from what the session returned. Non-empty text
    /// is a success even when an error was also reported (Apple: an error after some
    /// words) — for the stop too: the error is only logged, never put in `errorMessage`,
    /// which would make the dictation a failure and send its words to the Record Window
    /// instead of pasting them. Text that cleanup emptied is no text, and its error stays.
    /// With nothing recognised the audio is archived — the writer has it for every
    /// tier, so on-device recognition producing nothing still leaves a cloud retry.
    /// `superseded`: the segment landed after its task was cancelled by a resume. It
    /// still belongs in History, but the engine's live state is the *new* session's, so
    /// its failure must neither be shown as the current error nor be inferred from one.
    private func recordOutcome(_ outcome: RecognitionOutcome, writer: AudioBufferWriter?,
                               locale: String, superseded: Bool = false) {
        guard !outcome.cancelled else {
            if let url = outcome.audioFileURL { AudioBufferWriter.cleanup(fileURL: url) }
            return
        }
        let provider = providerType.rawValue
        let model = configuration?.model.id
        let duration = writer?.bufferedDuration ?? 0
        let history = TranscriptionHistory.shared
        // The session only knows its own errors; engine-level failures (e.g.
        // `installAudioTap`'s "No audio input device available") live in `errorMessage`.
        // Any error known when an empty segment lands makes the entry a failure, so the
        // History row stays explainable after the fact.
        let failure = outcome.error ?? (superseded ? nil : errorMessage)
        if outcome.error != nil, !outcome.text.isEmpty {
            dlog("Engine", "segment has \(outcome.text.count) chars and a recognition error — kept as a success, the error only logged", level: .notice)
        } else if let error = outcome.error, !superseded {
            errorMessage = error
        }
        if !outcome.text.isEmpty {
            if let url = outcome.audioFileURL { AudioBufferWriter.cleanup(fileURL: url) }
            let id = history.recordSuccess(text: outcome.text, provider: provider, model: model, locale: locale,
                                           duration: duration, speakingDuration: outcome.speakingSeconds,
                                           usage: outcome.usage)
            lastRecordID = id
            // Apple's tier never asks the detector, so it is asked here — from the samples
            // taken now, since `cleanup()` resets the writer, and after the row is written,
            // so the stop's paste does not wait for it.
            if outcome.speakingSeconds == nil, VoiceActivity.detector != nil, let samples = writer?.convertedSamples {
                Task.detached(priority: .utility) {
                    guard let seconds = await VoiceActivity.read(samples)?.voicedSpanSeconds else { return }
                    await MainActor.run { TranscriptionHistory.shared.recordSpeakingDuration(id: id, seconds) }
                }
            }
            return
        }
        if failure == nil, !recordsEmptyOutcomes {
            if let url = outcome.audioFileURL { AudioBufferWriter.cleanup(fileURL: url) }
            return
        }
        // Nothing came back — preserve the audio so it can be retried. A batch session
        // already wrote it; otherwise archive the writer's buffer now. Not for a failure
        // under `STTTuning.minimumSegmentSeconds`, though — an Apple recogniser that
        // failed at once leaves a clip of a few dozen milliseconds, which no provider can
        // transcribe (the batch tier drops such a segment outright). The row stays: it is
        // what explains the failure.
        let tooShortToRetry = failure != nil && duration < STTTuning.minimumSegmentSeconds
        let audioURL = outcome.audioFileURL ?? (tooShortToRetry ? nil : (try? writer?.writeAudioFile()) ?? nil)
        if let error = failure {
            if outcome.modelUnavailable, !superseded { failedForModel = true }
            let id = history.recordFailure(error: error, provider: provider, model: model, locale: locale,
                                           duration: duration, audioURL: audioURL, usage: outcome.usage)
            if outcome.offline, !superseded, history.record(id: id)?.isRetryable == true {
                offlineRecordID = id
                onSavedOffline?(id)
            }
        } else {
            history.recordEmpty(provider: provider, model: model, locale: locale,
                                duration: duration, audioURL: audioURL, usage: outcome.usage)
        }
    }

    // MARK: - Audio

    /// False, with `errorMessage` set, when there is nothing to tap.
    @discardableResult
    private func installAudioTap() -> Bool {
        guard let audioEngine, let writer = audioBufferWriter, let session else {
            seLog.error("installAudioTap: no audio engine")
            errorMessage = "Audio engine not initialized"
            return false
        }

        let hwFormat = audioEngine.format

        // Validate — a 0-channel or 0-sampleRate format means no input device is available
        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            seLog.error("installAudioTap: invalid hardware format (channels=\(hwFormat.channelCount), sampleRate=\(hwFormat.sampleRate))")
            errorMessage = "No audio input device available"
            return false
        }

        // The tap delivers the hardware's native format (see `EngineCapture.installTap`).
        seLog.info("installAudioTap: hwFormat=\(hwFormat.description, privacy: .public)")

        // One conversion per buffer: the writer converts to 16 kHz mono Int16 as audio
        // arrives and hands the bytes back, and the session gets those same bytes (a
        // stream sends them; Apple takes the native buffer instead). The writer and the
        // session are per-segment and the tap is removed before either is dropped, so the
        // tap holds them strongly.
        // Re-prepared on a device restart: the format may have changed, and no tap
        // exists in between (`tearDownAudioEngine` removed it synchronously).
        writer.prepare(sourceFormat: hwFormat)
        dlog("Engine", "input format: \(Int(hwFormat.sampleRate)) Hz, \(hwFormat.channelCount) ch")

        // Fresh for every tap, so a new device is scaled from the defaults rather than
        // from the loudness of the one before it.
        let scratch = TapScratch()
        audioEngine.installTap { [weak self] buffer in
            if !scratch.reportedFormatMismatch, buffer.format.sampleRate != hwFormat.sampleRate {
                scratch.reportedFormatMismatch = true
                dlog("Engine", "⚠ tap delivers \(Int(buffer.format.sampleRate)) Hz, prepared for \(Int(hwFormat.sampleRate)) Hz", level: .notice)
            }
            let pcm = writer.append(buffer)
            session.feed(native: buffer, pcm16: pcm)

            guard let self else { return }
            // One main-queue hop per tap buffer (~50/s) just to smooth twelve numbers is
            // avoidable: the levels go into a box the display reads on its own clock,
            // and the hop is taken only when none is already pending.
            let seconds = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
            self.levelBox.store(scratch.normalizer.levels(rms: Self.perSegmentRMS(buffer: buffer, count: 12),
                                                          seconds: seconds))
            if !self.levelHopPending.swap(true) {
                DispatchQueue.main.async {
                    self.levelHopPending.swap(false)
                    let levels = self.levelBox.take()
                    for i in 0..<min(self.barLevels.count, levels.count) {
                        self.barLevels[i] = self.barLevels[i] * 0.2 + levels[i] * 0.8
                    }
                }
            }
        }
        return true
    }

    /// Called when the audio hardware configuration changes (device switch, sample rate change, etc.).
    /// AVAudioEngine stops itself automatically — a fresh engine on the new device carries
    /// the same segment on (`restartAudioEngine`), or, where the segment cannot cross a
    /// format change, it is closed the way a pause closes it and the next one opened.
    ///
    /// This used to rebuild the whole session, which lost the segment: the old writer was
    /// replaced before its audio was ever written, and a batch session's `cancel()` is a
    /// no-op — so with Groq or a local model the first half of a dictation vanished
    /// without a History row when AirPods connected mid-sentence.
    /// When the engine was last rebuilt for a device change under a live recording.
    private var recentDeviceRestarts: [Date] = []
    /// Plugging in a headset raises two or three notifications in a second; five in ten
    /// seconds is a device that will not settle.
    private static let deviceRestartBudget = 5
    private static let deviceRestartWindow: TimeInterval = 10

    private func handleAudioConfigChange() {
        dlog("Engine", "handleAudioConfigChange: audio device changed, phase=\(phase)")
        seLog.warning("handleAudioConfigChange: audio device changed, phase=\(String(describing: self.phase), privacy: .public)")

        // A change that stops the capture is one to act on; one it keeps running
        // through needs nothing. Pointing `AVAudioEngine` at a device with `setDeviceID`
        // (before `DeviceCapture`) raised a notification of its own once the engine
        // started, and treated as a device change it tore down a starting engine — the
        // dictation sat in `.starting` recording nothing — or restarted a recording one,
        // whose new selection raised the next, until the budget ended it.
        if audioEngine?.isRunning == true {
            dlog("Engine", "handleAudioConfigChange: engine still running — nothing to restart")
            return
        }

        switch phase {
        case .starting where audioEngine != nil, .recording:
            // A device that keeps announcing itself — a Bluetooth headset renegotiating
            // its profile, an aggregate device whose input is not the system's — restarts
            // the engine, and the restart raises the next notification. Past the budget
            // the recording ends with what was said, rather than looping until the app is
            // force-quit.
            let now = Date()
            recentDeviceRestarts = recentDeviceRestarts.filter { now.timeIntervalSince($0) < Self.deviceRestartWindow }
            recentDeviceRestarts.append(now)
            guard recentDeviceRestarts.count <= Self.deviceRestartBudget else {
                dlog("Engine", "handleAudioConfigChange: \(recentDeviceRestarts.count) device changes in \(Int(Self.deviceRestartWindow)) s — stopping", level: .error)
                recentDeviceRestarts.removeAll()
                if phase == .starting {
                    // `stopRecording` ignores `.starting`; no audio was taken, so this
                    // ends as a start failure does.
                    let message = "The microphone kept changing — try again"
                    errorMessage = message
                    onStartFailure?(message)
                    phase = .idle
                    cleanup()
                } else {
                    endRecording(microphoneLost: "The microphone kept changing — try again")
                }
                return
            }
            if phase == .starting {
                // The start in flight is on an engine that stopped, and a teardown would
                // bump its token and leave the phase at `.starting` for good; a fresh
                // engine's start moves it to `.recording` as the first one would have.
                restartAudioEngine()
                return
            }
            if providerType != .apple, audioBufferWriter?.isConvertingLive == true {
                // The cloud and local tiers only ever see the writer's 16 kHz bytes, so
                // the segment carries straight on across the new device.
                restartAudioEngine()
            } else {
                // Apple's request takes the native buffers, whose format just changed
                // (and a writer already on its native fallback path can hold only one
                // format), so the segment is closed exactly as a user pause closes it and
                // the next one opens on the new device. The whole recording's text is
                // still `spanLayer.text`, which is what the stop pastes and finalizes.
                // A segment that has to be uploaded first is resumed once it has landed:
                // resumed at once, its upload was cancelled and the segment lost.
                pauseRecording(thenResume: configuration?.locale ?? "en-US")
            }
        case .paused:
            // Stay paused: the stale engine is discarded here, and a resume builds a fresh
            // one on the new device anyway. Going idle instead left the Record Window
            // showing a pause the engine had already abandoned.
            tearDownAudioEngine()
        case .idle, .starting, .finishing:
            // Not recording — just discard the stale engine so the next session gets a fresh one.
            // A stop that is mid-wait keeps waiting inside its session.
            tearDownAudioEngine()
        }
    }

    /// Stops the engine and removes its tap, on `engineQueue` behind any start still in
    /// flight, and marks that start stale.
    ///
    /// Asynchronous by default: waiting here would stall the main thread for the whole
    /// of a slow (Bluetooth) start whenever a cancel or stop lands during one. A buffer
    /// or two delivered after this returns is tolerated by every tier — `pause()` and
    /// `finish()` ignore late feeds, and `append` converts under the lock the stop's flush
    /// takes and drops a buffer once flushed, so one still converting when `finish()`
    /// writes the file never shares the converter with the flush — and the tap
    /// closure holds the writer and session strongly until it is removed, so dropping
    /// the engine's references right after is safe. `waiting` is for the one caller
    /// that re-prepares the writer next and must know no callback is inside `append`.
    private func stopAudioEngine(_ engine: AudioCapture, waiting: Bool = false) {
        engineStartToken += 1
        let stop: @Sendable () -> Void = {
            engine.stop()
            engine.removeTap()
        }
        if waiting { engineQueue.sync(execute: stop) } else { engineQueue.async(execute: stop) }
    }

    /// Stop and discard the current audio engine so the next session creates a fresh one.
    private func tearDownAudioEngine(waiting: Bool = false) {
        // Bump the token so any in-flight background prepare()/start() knows it's stale.
        engineStartToken += 1
        if let engine = audioEngine {
            engine.onConfigurationChange = nil
            stopAudioEngine(engine, waiting: waiting)
        }
        audioEngine = nil
    }

    /// Never writes `phase`: every caller sets `.idle` immediately before calling, after
    /// its `finalText` / `errorMessage` / `lastRecordID` are in place — so the waiters
    /// that resume on that edge always see a finished result.
    private func cleanup() {
        dlog("Engine", "cleanup: phase=\(phase)")
        // speechRecognizer is intentionally kept alive between sessions so the speech
        // model stays loaded in memory, making subsequent recordings start much faster.
        //
        // The engine (and so the tap) goes first. The stop is asynchronous — see
        // `stopAudioEngine` — and `reset()` leaves the writer's converter alone for
        // exactly that reason: a callback still inside `append` finds it intact.
        tearDownAudioEngine()
        audioBufferWriter?.reset()
        audioBufferWriter = nil
        session?.cancel()
        session = nil
    }

    /// Split the audio buffer into N segments and compute RMS for each, raw — the
    /// display's scale is `LevelNormalizer`'s.
    /// Each bar gets a different time-slice of the actual audio → natural asymmetry.
    private nonisolated static func perSegmentRMS(buffer: AVAudioPCMBuffer, count: Int) -> [Float] {
        guard let data = buffer.floatChannelData else {
            return Array(repeating: 0, count: count)
        }
        let frames = Int(buffer.frameLength)
        let samples = data[0]
        let segmentSize = frames / count
        guard segmentSize > 0 else {
            return Array(repeating: 0, count: count)
        }

        var levels = [Float]()
        levels.reserveCapacity(count)
        for i in 0..<count {
            let start = i * segmentSize
            let end = min(start + segmentSize, frames)
            var sum: Float = 0
            for j in start..<end {
                sum += samples[j] * samples[j]
            }
            let rms = sqrt(sum / Float(end - start))
            levels.append(rms)
        }
        return levels
    }
}

// MARK: - Audio-thread hand-off

/// What one tap keeps between its buffers. `@unchecked Sendable`: only that tap's
/// callbacks touch it, and they run one after another.
private final class TapScratch: @unchecked Sendable {
    /// A selected microphone whose format the node had not caught up with would be
    /// converted at the wrong rate — the upload sped up or slowed down. Said once.
    var reportedFormatMismatch = false
    var normalizer = LevelNormalizer()
}

/// The most recent levels the tap computed. Written on the audio thread, read on main;
/// a lock around twelve values is cheaper than a block allocation per buffer.
/// `@unchecked Sendable`: `levels` is held under `lock`.
private final class LevelBox: @unchecked Sendable {
    private var levels: [CGFloat] = []
    private let lock = NSLock()

    func store(_ new: [CGFloat]) {
        lock.lock(); levels = new; lock.unlock()
    }

    func take() -> [CGFloat] {
        lock.lock(); defer { lock.unlock() }
        return levels
    }
}

/// A boolean that can be set-and-read atomically from two threads. `@unchecked Sendable`:
/// `value` is held under `lock`.
private final class AtomicFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    /// Sets the flag and returns what it was.
    @discardableResult
    func swap(_ new: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}

// MARK: - Start timing

/// The steps of a start, timed for the Debug Log. Everything up to `startAudioEngine`
/// runs on the main thread, after the overlay was ordered front and before it can draw:
/// a step that stalls there (Core Audio answering slowly while Bluetooth headphones
/// change profile) leaves the user with no overlay and a microphone that opens late,
/// and the log has to say which step it was.
private struct StartTimer {
    private(set) var began = ProcessInfo.processInfo.systemUptime
    private var last = ProcessInfo.processInfo.systemUptime
    private var steps: [String] = []

    /// Closes the step since the previous lap.
    mutating func lap(_ step: String) {
        let now = ProcessInfo.processInfo.systemUptime
        steps.append("\(step) \(Self.ms(now - last))")
        last = now
    }

    var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - began }
    var summary: String { steps.joined(separator: ", ") }

    static func ms(_ seconds: TimeInterval) -> String { "\(Int((seconds * 1000).rounded())) ms" }
}
