// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation
import Speech
import SpeechTextCore

// MARK: - Apple on-device

/// SFSpeechRecognitionTask stops accepting audio after roughly a minute. Left alone,
/// every word spoken past that point is silently dropped. The session rotates to a fresh
/// recognition task before the limit and stitches the chunks together — and at once when
/// a chunk's task fails after the segment has words, since a failed task takes no more
/// audio either (`AppleErrorRotation`).
///
/// Main-actor state, except the request the tap appends to, which `feed` reads from the
/// audio thread while a rotation swaps it on main — so it is held under a lock.
@MainActor
final class AppleRecognitionSession: RecognitionSession {
    var onEvent: (@MainActor @Sendable (RecognitionEvent) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private let locale: String
    /// The current chunk's request. Set and cleared on main; read by `feed`.
    private var request: SFSpeechAudioBufferRecognitionRequest? {
        get { requestBox.current }
        set { requestBox.set(newValue) }
    }
    private let requestBox = RequestBox()
    private var task: SFSpeechRecognitionTask?
    /// Transcript committed from earlier chunks (see `rotate`).
    private var committedText = ""
    /// The current chunk's results, kept across the recogniser's resets after a pause
    /// and its empty finals (`AppleUtterances`).
    private var utterances = AppleUtterances()
    /// Set on `isFinal`, or promoted from the live text when the recogniser errors.
    private var finalText = ""
    /// Recognition errors other than 216 (cancelled), as `RecognitionFailure` words them.
    private var lastError: String?
    /// The current chunk's task reported an error, so no further callback is coming.
    private var chunkFailed = false
    /// Incremented on every rotation so callbacks from retired chunks can be discarded.
    private var chunkToken = 0
    private var chunkTimer: Timer?
    /// When a chunk that failed after the segment had words is replaced.
    private var errorRotation = AppleErrorRotation()
    /// Comfortably under SFSpeechRecognitionTask's ~60s ceiling.
    private let chunkDuration: TimeInterval = 50
    /// False once the mic stopped feeding this segment (pause / finish), so a rotation
    /// timer that fires late does not open a chunk nobody feeds.
    private var isFeeding = false
    private var isCancelled = false
    /// The `finish()` wait, resumed by `isFinal`, the 0.5 s deadline, or `cancel()`.
    /// Bool = cancelled.
    private var finishContinuation: CheckedContinuation<Bool, Never>?
    private var finishDeadline: DispatchWorkItem?

    /// The Dictionary's words, fitted to Apple's limit
    /// (`RecordingConfiguration.liveVocabulary`) — set on every chunk's request,
    /// since each rotation builds a new one.
    private let contextualStrings: [String]

    init(recognizer: SFSpeechRecognizer?, locale: String, contextualStrings: [String] = []) {
        self.recognizer = recognizer
        self.locale = locale
        self.contextualStrings = contextualStrings
    }

    func start() throws {
        // Denied or restricted: every task would fail, so the start does — with the
        // remedy. Not determined proceeds: the system asks on the first task.
        if Self.speechPermissionDenied {
            throw RecognitionSessionError.speechPermissionDenied
        }
        guard let recognizer, recognizer.isAvailable else {
            throw RecognitionSessionError.recognizerUnavailable(locale)
        }
        isFeeding = true
        startChunk(recognizer)
    }

    private static var speechPermissionDenied: Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted: return true
        default: return false
        }
    }

    private func startChunk(_ recognizer: SFSpeechRecognizer) {
        chunkFailed = false
        errorRotation.chunkStarted(at: ProcessInfo.processInfo.systemUptime)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }
        self.request = request

        chunkToken += 1
        let token = chunkToken

        // `@Sendable`, so it is not taken for main-actor code: the recogniser calls it on
        // a queue of its own, and it hops to main for everything but reading the result.
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            guard let self else { return }
            if let result {
                let partial = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                DispatchQueue.main.async {
                    // Ignore late callbacks from a chunk we've already rotated away from.
                    guard self.chunkToken == token else { return }
                    let before = self.utterances
                    self.utterances.receive(partial)
                    if self.utterances.settled != before.settled {
                        dlog("Engine", "apple: a new utterance began — keeping the \(transcriptWords(before.current).count) words before it")
                    }
                    if !self.utterances.text.isEmpty {
                        if self.errorRotation.heardWords() {
                            dlog("Engine", "apple: the chunk after an error rotation hears words (\(self.utterances.text.count) chars)")
                        }
                        #if DEBUG
                        self.armFailureForE2E()
                        #endif
                    }
                    // What the recogniser has moved past is committed: it will not revise it.
                    self.onEvent?(.live(committed: joinedTranscript(self.committedText, self.utterances.settled),
                                        partial: self.utterances.current))
                    if isFinal {
                        dlog("Engine", "recognitionTask: isFinal=true, \(partial.count) chars"
                             + (partial.isEmpty ? " — keeping the \(self.utterances.text.count) chars heard before it" : ""))
                        self.finalText = joinedTranscript(self.committedText, self.utterances.text)
                        // No-op unless a finish is waiting, so isFinal during a chunk
                        // rotation or a pause changes nothing.
                        self.resolveFinish(cancelled: false)
                    }
                }
            }
            if let error {
                let nsErr = error as NSError
                dlog("Engine", "recognitionTask error: code=\(nsErr.code), domain=\(nsErr.domain), desc=\(error.localizedDescription)", level: .error)
                DispatchQueue.main.async {
                    guard self.chunkToken == token else { return }
                    self.chunkDidFail(nsErr)
                }
            }
        }

        scheduleChunkRotation()
    }

    /// The current chunk's task reported `error`. Main thread, for the current chunk only:
    /// the callback has already discarded a retired chunk's.
    private func chunkDidFail(_ error: NSError) {
        // The task is over: a `finish()` that starts after this has nothing to wait for.
        chunkFailed = true
        if finalText.isEmpty {
            finalText = joinedTranscript(committedText, utterances.text)
        }
        // Text from the whole segment, earlier chunks included: a fresh chunk that fails
        // right after a rotation is not a recording without text.
        let hasText = !joinedTranscript(committedText, utterances.text)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let permissionDenied = Self.speechPermissionDenied
        if let failure = RecognitionFailure.apple(
            domain: error.domain, code: error.code,
            description: error.localizedDescription, hasText: hasText,
            permissionDenied: permissionDenied, locale: locale) {
            if !hasText {
                dlog("Engine", "recognitionTask failed before any text: onDevice=\(recognizer?.supportsOnDeviceRecognition == true), permissionDenied=\(permissionDenied)", level: .error)
            }
            lastError = failure.message
            onEvent?(.failure(failure))
            // An error before any text ends the recording (the engine acts on the event).
            // After text the recording goes on, so a task that takes no more audio is
            // replaced — unless the permission is gone, which no fresh task gets back.
            if !failure.endsRecording, !permissionDenied {
                rotateAfterError()
            }
        }
        // Nothing more is coming after an error: a `finish()` waiting on this task gets
        // its answer now rather than at the 0.5 s deadline.
        resolveFinish(cancelled: false)
    }

    /// A failed task takes no more audio, so every word until the next chunk would be
    /// lost: the chunk is replaced now, or as soon as `AppleErrorRotation` allows, rather
    /// than at the 50 s timer. A deferred rotation is the chunk timer brought forward, so
    /// a pause, a stop or a cancel stops it as they stop the timer, and `rotate()` asks
    /// `isFeeding` again whenever it runs. `rotate()` commits the dead chunk's words once
    /// and re-arms the 50 s timer for the new chunk.
    private func rotateAfterError() {
        let heard = utterances.text.count
        switch errorRotation.decide(at: ProcessInfo.processInfo.systemUptime, isFeeding: isFeeding) {
        case .rotate(let delay) where delay > 0:
            dlog("Engine", "apple: chunk failed after text, rotating in \(String(format: "%.1f", delay)) s (the chunk heard \(heard) chars; \(errorRotation.barrenRotations) of \(AppleErrorRotation.barrenRotationLimit) rotations without words)")
            scheduleChunkRotation(after: delay)
        case .rotate:
            dlog("Engine", "apple: chunk failed after text, rotating now (the chunk heard \(heard) chars; \(errorRotation.barrenRotations) of \(AppleErrorRotation.barrenRotationLimit) rotations without words)")
            rotate()
        case .leaveToTimer:
            dlog("Engine", "apple: chunk failed after text, left to the 50 s rotation (\(AppleErrorRotation.barrenRotationLimit) rotations in a row heard no words)")
        case .notFeeding:
            break
        }
    }

    /// In the main run loop's common modes, not only the default one: while the status
    /// menu is open (or a window is dragged) the run loop is in event tracking, a default
    /// mode timer waits it out, and past the recogniser's minute every word is dropped.
    /// `after` brings it forward for a chunk that failed (`rotateAfterError`).
    private func scheduleChunkRotation(after interval: TimeInterval? = nil) {
        chunkTimer?.invalidate()
        let timer = Timer(timeInterval: interval ?? chunkDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rotate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        chunkTimer = timer
    }

    private func rotate() {
        guard isFeeding, let recognizer else { return }
        let live = joinedTranscript(committedText, utterances.text)
        dlog("Engine", "AppleRecognitionSession.rotate: committing \(live.count) chars, starting fresh chunk")

        // Commit the latest partial. Partials arrive continuously, so this captures
        // essentially everything said in this chunk; at most a word at the boundary
        // is at risk, which beats losing every word after the one-minute mark.
        committedText = live.trimmingCharacters(in: .whitespacesAndNewlines)
        utterances = AppleUtterances()
        // An isFinal from the retired chunk described only that chunk. Left in place it
        // would make the stop return chunk 1 alone, dropping everything said after.
        finalText = ""

        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil

        // The tap appends to `request` by reference, so the running engine feeds the
        // new request automatically — no need to touch the tap.
        startChunk(recognizer)
    }

    private func stopChunkTimer() {
        chunkTimer?.invalidate()
        chunkTimer = nil
    }

    nonisolated func feed(native: AVAudioPCMBuffer, pcm16: Data?) {
        // Apple's recognizer gets the native buffer — it does its own resampling.
        requestBox.current?.append(native)
    }

    /// The task and request stay alive, so a stop from a pause that had recognised
    /// nothing yet can still end the audio and wait for a final result. A pause with text
    /// has its History row written by the engine there and then, and the stop does not
    /// finish this session again — it would write the same segment twice.
    /// Idempotent — a stop calls it again (before `finish()`) so the rotation timer is
    /// killed on the main thread synchronously, not after `finish()`'s async hop.
    func pause() -> String? {
        isFeeding = false
        stopChunkTimer()
        return joinedTranscript(committedText, utterances.text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func finish() async -> RecognitionOutcome {
        // Everything the closures below touch is main-actor state, read and written there.
        let session = self
        let cancelled: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                guard !session.isCancelled else {
                    continuation.resume(returning: true)
                    return
                }
                session.isFeeding = false
                session.stopChunkTimer()
                session.request?.endAudio()
                guard !session.chunkFailed else {
                    // The task already ended with an error: no final result is coming,
                    // and waiting out the deadline would only hold the notice back.
                    dlog("Engine", "apple: task already failed, not waiting for a final result", level: .notice)
                    continuation.resume(returning: false)
                    return
                }
                dlog("Engine", "apple: waiting ≤0.5s for final result, live=\(joinedTranscript(session.committedText, session.utterances.text).count) chars")
                session.finishContinuation = continuation
                // 0.5s is the upper bound; the recognition callback resolves this early
                // when a result with `isFinal` arrives, so the user isn't kept waiting on a timer.
                let deadline = DispatchWorkItem { [weak session = session] in
                    session?.resolveFinish(cancelled: false)
                }
                session.finishDeadline = deadline
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: deadline)
            }
        }
        guard !cancelled else { return .cancelled }

        return await MainActor.run {
            var text = session.finalText
            if text.isEmpty {
                let live = joinedTranscript(session.committedText, session.utterances.text)
                dlog("Engine", "apple: finalText empty, using live text (\(live.count) chars)")
                text = live
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            dlog("Engine", "apple: done, finalText=\(text.count) chars")
            return RecognitionOutcome(text: text, error: session.lastError, audioFileURL: nil, cancelled: false)
        }
    }

    private func resolveFinish(cancelled: Bool) {
        guard let continuation = finishContinuation else { return }
        if !cancelled, finishDeadline?.isCancelled == false, finalText.isEmpty == false {
            dlog("Engine", "apple: final result arrived, finishing early")
        }
        finishContinuation = nil
        finishDeadline?.cancel()
        finishDeadline = nil
        continuation.resume(returning: cancelled)
    }

    func cancel() {
        isCancelled = true
        isFeeding = false
        stopChunkTimer()
        task?.cancel()
        task = nil
        request = nil
        // Drops late callbacks from the cancelled task.
        chunkToken += 1
        resolveFinish(cancelled: true)
    }

    #if DEBUG
    /// scripts/e2e.sh's apple-error scenario (`-SPTAppleFailAfter`): the first time a
    /// chunk hears words in an e2e launch with it, the chunk then current fails that long
    /// after. A no-op otherwise.
    private func armFailureForE2E() {
        guard let seconds = E2EMode.appleFailureOnce() else { return }
        dlog("E2E", "failing the Apple chunk in \(seconds) s (-SPTAppleFailAfter)")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.failChunkForE2E()
        }
    }

    /// The current chunk fails as a real task error would: its task cancelled and its late
    /// callbacks retired by the token, as `cancel()` retires them, so nothing more comes
    /// from it — then the error path, with kAFAssistantErrorDomain 1101 and the
    /// description such an error has.
    private func failChunkForE2E() {
        guard isFeeding, !chunkFailed else { return }
        dlog("E2E", "failing the Apple chunk now (-SPTAppleFailAfter)")
        chunkToken += 1
        task?.cancel()
        task = nil
        chunkDidFail(NSError(domain: "kAFAssistantErrorDomain", code: 1101))
    }
    #endif
}

/// The request `feed` appends to, shared between main (which swaps it on a rotation) and
/// the audio thread (which reads it for every buffer). The lock is held only to read or
/// write the reference, never across an `append`. `@unchecked Sendable`: `request` is held
/// under `lock`.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    var current: SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }
}

// MARK: - Languages on this Mac

/// Which of the user's languages Apple's recogniser takes on-device on this Mac — the answer
/// `LanguageCoverage.decidedBySystem` stands for. Asked of macOS, never written down:
/// it follows the Dictation languages installed, so it differs from Mac to Mac. It does not
/// need the Speech Recognition permission: on 2026-10-17, with the permission not yet asked,
/// macOS answered true for en-US and uk-UA and false for es-ES ("No Assistant asset").
enum AppleOnDeviceLanguages {
    @MainActor private static var answers: [String: Bool] = [:]

    /// True or false once macOS has said; nil for a code with no Apple locale, which then
    /// stays silent. A locale macOS cannot recognise at all is false.
    @MainActor static func supports(_ code: String) -> Bool? {
        guard let locale = spokenLanguage(id: languageSubtag(code))?.localeIdentifier else { return nil }
        if let known = answers[locale] { return known }
        let answer = SFSpeechRecognizer(locale: Locale(identifier: locale))?.supportsOnDeviceRecognition ?? false
        answers[locale] = answer
        return answer
    }

    /// Forgets the answers, so a page that appears asks again — the user may have added a
    /// Dictation language in System Settings meanwhile.
    @MainActor static func refresh() { answers = [:] }
}
