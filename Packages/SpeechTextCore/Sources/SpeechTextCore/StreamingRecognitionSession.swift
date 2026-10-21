// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation

// MARK: - Streaming with batch fallback

/// Pushes the tap's audio over the realtime socket — the writer's own 16 kHz bytes when
/// the provider wants that rate, a converted copy of the native buffer when it wants
/// another — and mirrors its events into committed / partial text. When the stream
/// breaks or ends with nothing, `finish()` hands the segment to the wrapped batch
/// session, which uploads the same writer's file.
///
/// A stream that drops for want of a network is opened again (`StreamReconnectPolicy`)
/// with a fresh provider from `reconnect`, so the overlay goes on showing words after a
/// short outage. What was on screen when it dropped is kept as committed text, and the
/// new socket's words are merged after it (`TranscriptMerge`), never doubled. The new
/// socket did not hear the outage, though, so a segment that had one is finished by
/// the upload all the same — the reconnect is for the overlay, not for the text.
///
/// Main-actor state, with two ways in from elsewhere: `feed` on the audio thread, which
/// touches only the `let`s and the audio-thread state below, and `finish()` off main.
@MainActor
public final class StreamingRecognitionSession: RecognitionSession {
    public var onEvent: (@MainActor @Sendable (RecognitionEvent) -> Void)?

    /// The stream events are read from. Replaced on a reconnect; main-thread state.
    private var provider: StreamingTranscriber
    /// The one `feed` sends to, read on the audio thread; nil while nothing should be
    /// sent — the stream failed for good, or is between a drop and its reconnect.
    private let sendTarget = TranscriberBox()
    /// A fresh provider for a reconnect; nil when the stream is not to be reopened.
    private let reconnect: (@MainActor @Sendable () -> StreamingTranscriber?)?
    private let policy: StreamReconnectPolicy
    private let writer: AudioBufferWriter
    /// The user's stated languages, handed to the provider whole — see
    /// `StreamingTranscriber.connect(languages:)` for what each one does with the count.
    private let languages: [String]
    /// A `BatchRecognitionSession` over the same writer in the app. Typed by the protocol
    /// so a replay can stand in the upload's answer without a network or an audio file.
    private let fallback: RecognitionSession

    // Main-thread state.
    private var committedText = "" {
        didSet { committedWords = transcriptWords(committedText) }
    }
    /// `committedText` tokenised once per commit rather than once per partial — the
    /// partial arrives several times a second and is merged against all of it each time.
    private var committedWords: [TranscriptWord] = []
    private var partialText = ""
    /// Set when the stream broke; `finish()` then falls back to the batch upload.
    private var failure: String?
    private var connected = false
    private var eventsTask: Task<Void, Never>?
    /// Counts the providers this segment has had, so a replaced one's late events —
    /// already in flight to main when it was dropped — are recognised and ignored.
    private var generation = 0
    /// The generation whose provider has reported `.failed`. A socket can report one drop
    /// more than once; only the first report is the drop.
    private var failedGeneration = 0
    /// A stream dropped during this segment: whatever it shows since, the stop uploads.
    private var hadOutage = false
    /// Outages so far, and attempts made in the current one — `StreamReconnectPolicy`'s inputs.
    private var outages = 0
    private var attempts = 0
    /// The current provider has said something since it was attached: its outage is over.
    private var providerHasSpoken = false
    private var reconnectTask: Task<Void, Never>?
    /// `finish()` or `cancel()` has begun: nothing is reopened after that.
    private var closing = false

    // Audio-thread state. `feed` is the only thing that touches these, and the tap
    // calls it serially, so they need no lock — which is what makes the unchecked
    // access safe.
    //
    // A provider whose socket wants a rate other than the writer's owns a converter of
    // its own, fed from the *native* tap buffer rather than from the writer's output:
    // 48 kHz → 24 kHz in one step is both cheaper and cleaner than 48 → 16 → 24. This is
    // what `StreamingTranscriber.sampleRate` was declared for ("the engine converts the
    // mic feed to it"); before OpenAI's realtime tier, every provider happened to want
    // the writer's 16 kHz and the mismatch simply skipped the stream.
    private let needsResampling: Bool
    private nonisolated(unsafe) var resampler: PCMDownsampler?
    /// The format `resampler` was built for. A device change hands the tap a new one
    /// mid-recording (see `SpeechEngine.restartAudioEngine`), and the converter cannot
    /// be re-pointed, so it is rebuilt — losing only the handful of frames in its delay
    /// line, at a boundary where the hardware just changed anyway.
    ///
    /// Compared with `!=`, which on an `AVAudioFormat` is `isEqual:` and not object
    /// identity (`AVAudioFormatEqualityTests` pins that down): the tap hands out a fresh
    /// instance per buffer, so an identity test would rebuild the converter fifty times
    /// a second and throw away its delay line each time.
    private nonisolated(unsafe) var resamplerFormat: AVAudioFormat?

    /// The socket's sample rate. Fixed for the session: a reconnect makes the same
    /// provider again, and the converter below is built for it.
    private let sampleRate: Double
    /// The realtime model the socket is billed under — its ledger entry, apart from the
    /// fallback upload's, which the batch session writes itself.
    private let meter: UsageMeter?
    /// How long the server has kept each segment open, and how long it may before the
    /// stop stops trusting the stream: nil for a provider that keeps one item open
    /// until the stop by design.
    private let segments: OpenSegmentBox
    private let longestTrustedSegment: Double?

    public nonisolated init(provider: StreamingTranscriber, writer: AudioBufferWriter, languages: [String],
         fallback: RecognitionSession,
         reconnect: (@MainActor @Sendable () -> StreamingTranscriber?)? = nil,
         policy: StreamReconnectPolicy = StreamReconnectPolicy(),
         meter: UsageMeter? = nil,
         longestTrustedSegment: Double? = nil) {
        self.meter = meter
        self.segments = OpenSegmentBox(OpenSegmentClock(sampleRate: provider.sampleRate))
        self.longestTrustedSegment = longestTrustedSegment
        self.needsResampling = provider.sampleRate != AudioBufferWriter.uploadSampleRate
        self.sampleRate = provider.sampleRate
        self.provider = provider
        self.writer = writer
        self.languages = languages
        self.fallback = fallback
        self.reconnect = reconnect
        self.policy = policy
    }

    public func start() throws {
        connected = true
        attach(provider)
    }

    /// Opens `provider`'s socket and makes it the one events are read from and audio is
    /// sent to. The provider buffers what `feed` sends until its session is ready — the
    /// same pre-session buffer a first connection relies on.
    private func attach(_ provider: StreamingTranscriber) {
        // The socket being replaced is closed whatever state it is in: one left open would
        // live until the server closed it, paid for and never fed. (`start()` attaches
        // the provider the session was made with, which replaces nothing.)
        let replaced = self.provider
        if replaced !== provider { replaced.cancel() }
        generation += 1
        let generation = self.generation
        self.provider = provider
        providerHasSpoken = false
        // A new socket opens a segment of its own.
        segments.segmentClosed()
        provider.connect(languages: languages)
        eventsTask = Self.mirror(provider, into: self, generation: generation)
        sendTarget.set(provider)
    }

    /// Reads `provider`'s events off main and hands each to `handle` there. Made in a
    /// nonisolated function so the task is not the main actor's: the loop waits on the
    /// socket off main, as it always has. The session is held weakly.
    private nonisolated static func mirror(_ provider: StreamingTranscriber,
                                           into session: StreamingRecognitionSession,
                                           generation: Int) -> Task<Void, Never> {
        Task { [weak session] in
            for await event in provider.events {
                await session?.handle(event, generation: generation)
            }
        }
    }

    private func handle(_ event: StreamingSTTEvent, generation: Int) {
        // A provider replaced by a reconnect may still have an event on its way here.
        guard generation == self.generation else { return }
        if case .failed = event {
            // One drop, one reconnect. Each report of the same drop used to schedule a
            // reconnect of its own — two new sockets, the first never fed nor closed —
            // and count as another outage against the segment's limit.
            guard failedGeneration != generation else { return }
            failedGeneration = generation
        }
        switch event {
        case .partial(let text): DictationTraceRecorder.record(.partial, text: text)
        case .committed(let text): DictationTraceRecorder.record(.committed, text: text)
        case .failed(let error): DictationTraceRecorder.record(.streamFailed, error: error.localizedDescription)
        }
        switch event {
        case .partial, .committed:
            providerHasSpoken = true
        case .failed:
            break
        }
        switch event {
        case .partial(let text):
            // The stream re-states what it has already committed — sometimes verbatim,
            // sometimes grown by the words said since — so the partial is reduced to
            // what it actually adds. Joining it whole pastes the dictation twice.
            partialText = transcriptContinuation(of: committedText, committedWords: committedWords, in: text)
        case .committed(let text):
            segments.segmentClosed()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Merged, not appended: a commit that restates the whole accumulated
                // transcript replaces what we hold rather than doubling it, and its
                // version of the overlapping words wins — it was made with more audio.
                committedText = mergedTranscript(committedText, trimmed)
            }
            partialText = ""
        case .failed(let error):
            sendTarget.set(nil)
            if !reopen(after: error) {
                failure = error.localizedDescription
            }
        }
        emitLive()
    }

    /// What the overlay draws. A stream opened on silence may answer with a known
    /// hallucination ("Evet."), a lone «.» or a foreign script as its first words; while
    /// that is everything the segment holds, the overlay shows nothing rather than flash it. The text itself is kept —
    /// once real words follow, the whole of it is shown, which only extends the empty
    /// view, so the span layer sees no revision.
    private func emitLive() {
        let whole = joinedSegments(committedText, partialText)
        if HallucinationFilter.rejection(whole, segmentSeconds: writer.bufferedDuration, languages: languages) != nil {
            onEvent?(.live(committed: "", partial: ""))
        } else {
            onEvent?(.live(committed: committedText, partial: partialText))
        }
    }

    /// Schedules the stream's reconnect after `error`, when the policy allows one. False
    /// when it does not: the stream is over and the stop uploads the segment.
    private func reopen(after error: Error) -> Bool {
        guard !closing, failure == nil, let reconnect,
              StreamReconnectPolicy.isReconnectable(error) else { return false }
        // The provider that failed had spoken since it was attached (or it is the
        // first): this is a new outage, not another failed attempt at the last one.
        if providerHasSpoken || outages == 0 {
            outages += 1
            attempts = 0
        }
        guard let delay = policy.delay(attempt: attempts, outage: outages) else {
            dlog("Engine", "stream: giving up after \(attempts) reconnect attempt(s), outage \(outages) — batch fallback at stop", level: .error)
            return false
        }
        attempts += 1
        hadOutage = true
        // What was on screen when the link dropped stays there. The partial is folded
        // into the committed text because the new socket starts from nothing — OpenAI's
        // never commits before the stop, so otherwise everything said so far would
        // vanish with the next partial. The new socket's words are merged after it, so
        // a restatement of any of it replaces rather than doubles.
        committedText = joinedSegments(committedText, partialText)
        partialText = ""
        dlog("Engine", "stream: dropped (\(error.localizedDescription)) — reconnecting in \(delay)s, attempt \(attempts) of outage \(outages)", level: .notice)
        // One reconnect in flight at a time.
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.closing else { return }
            self.reconnectTask = nil
            guard let next = reconnect() else {
                self.failure = error.localizedDescription
                return
            }
            DictationTraceRecorder.record(.streamReconnected)
            self.attach(next)
        }
        return true
    }

    private func markFailed(_ message: String) {
        guard failure == nil else { return }
        failure = message
        sendTarget.set(nil)
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    public nonisolated func feed(native: AVAudioPCMBuffer, pcm16: Data?) {
        guard let provider = sendTarget.current else { return }
        if needsResampling {
            // The writer's bytes are the wrong rate for this socket, so the stream does
            // not depend on the writer converting at all — only on this converter.
            guard let converted = resampled(native) else {
                let nativeRate = native.format.sampleRate
                DispatchQueue.main.async {
                    guard self.failure == nil else { return }
                    dlog("Engine", "stream: cannot convert \(nativeRate) Hz to \(self.sampleRate) Hz — stream discarded, batch fallback at stop", level: .error)
                    self.markFailed("Could not convert audio for streaming")
                }
                return
            }
            if !converted.isEmpty {
                provider.send(pcm16: converted)
                segments.feed(byteCount: converted.count)
            }
            return
        }
        if let pcm16 {
            provider.send(pcm16: pcm16)
            segments.feed(byteCount: pcm16.count)
        } else if !writer.isConvertingLive {
            // No live converter (or it died mid-session). The writer keeps the audio
            // natively, but the stream can no longer be fed, so the stop must upload the file.
            DispatchQueue.main.async {
                guard self.failure == nil else { return }
                dlog("Engine", "stream: live conversion unavailable — stream will be discarded, batch fallback at stop", level: .error)
                self.markFailed("Could not convert audio for streaming")
            }
        }
    }

    /// One tap buffer at the provider's rate. Returns an empty `Data` while the
    /// converter primes (it has taken the audio and not emitted any yet), and nil only
    /// when no converter can be made for this hardware format.
    private nonisolated func resampled(_ buffer: AVAudioPCMBuffer) -> Data? {
        if resampler == nil || resamplerFormat != buffer.format {
            resampler = PCMDownsampler(sourceFormat: buffer.format, targetRate: sampleRate)
            resamplerFormat = resampler == nil ? nil : buffer.format
            if resampler != nil {
                dlog("Engine", "stream: converting \(buffer.format.sampleRate) Hz tap to \(sampleRate) Hz")
            }
        }
        guard let resampler else { return nil }
        return resampler.convert(buffer)
    }

    public func pause() -> String? { nil }

    public nonisolated func finish() async -> RecognitionOutcome {
        // Snapshot under main-actor isolation: `cancel()` nils `eventsTask` on main, a
        // reconnect replaces `provider` there, and this function runs off it. Its
        // main-actor state is read and written below only inside `MainActor.run`; off main
        // this function touches only what the session holds as `let`s — the writer, the
        // fallback, the meter and the lock-held segment clock.
        let session = self
        let stopped = Date()
        let longest = segments.clock
        let tooLong = longest.exceeded(longestTrustedSegment)
        let (connected, events, provider, hadOutage) = await MainActor.run { () -> (Bool, Task<Void, Never>?, StreamingTranscriber, Bool) in
            session.closing = true
            session.reconnectTask?.cancel()
            session.reconnectTask = nil
            // Nothing is fed from here on. The engine removes its tap asynchronously, and
            // a buffer it delivers after the provider's `finish()` has taken the audio to
            // commit would go out behind the commit, into a segment that never closes.
            // Cleared after `closing`, so no reconnect can set it again, and before that
            // `finish()`, so audio fed until now still goes ahead of the commit.
            session.sendTarget.set(nil)
            return (session.connected, session.eventsTask, session.provider, session.hadOutage)
        }
        if tooLong {
            // The text at the end of a segment this long is where the model was caught
            // inventing words, so the upload answers; nothing of the stream's is waited for.
            await MainActor.run {
                DictationTraceRecorder.record(.segmentTooLong, text: String(format: "%.1f", (longest.longestSeconds * 10).rounded(.up) / 10))
            }
            dlog("Engine", "StreamingRecognitionSession.finish: a segment ran \(String(format: "%.1f", longest.longestSeconds))s, over \(longestTrustedSegment ?? 0)s — the upload answers", level: .notice)
            provider.cancel()
            await events?.value
        } else if hadOutage {
            // The socket in use now — if the reconnect got one — never heard the outage,
            // so its text has a hole in it wherever the link was down. Nothing to wait
            // for: close it and let the upload, which has the whole segment, answer.
            provider.cancel()
            await events?.value
        } else if connected {
            await provider.finish()
            // `finish()` closes the event stream, so draining the mirror task here means
            // the last committed transcript is in `committedText` before it is read.
            await events?.value
        }
        guard !Task.isCancelled else { return .cancelled }

        let (text, failure) = await MainActor.run {
            // A partial still pending at the stop is the next segment, and may finish a
            // word the last commit cut — joined like any other segment.
            (joinedSegments(session.committedText, session.partialText).trimmingCharacters(in: .whitespacesAndNewlines),
             session.failure)
        }

        // The socket's ledger entry: the audio it was sent, and whether it held.
        // No vendor reports a stream's billed seconds, so only what was sent is known.
        func streamEvent(answered: Bool) -> [UsageEvent] {
            guard connected || hadOutage, let meter else { return [] }
            return [meter.event(.stream, audioSeconds: writer.bufferedDuration, billing: nil, succeeded: answered,
                                latency: Date().timeIntervalSince(stopped), date: stopped)]
        }

        if failure == nil, !hadOutage, !tooLong, !text.isEmpty {
            let (guarded, reading) = await guardedStreamResult(text)
            if var dropped = guarded {
                // A segment too short to be speech leaves no row to carry an entry.
                if !dropped.cancelled { dropped.usage = streamEvent(answered: true) }
                return dropped
            }
            dlog("Engine", "StreamingRecognitionSession.finish: stream done, \(text.count) chars")
            return RecognitionOutcome(text: text, error: nil, audioFileURL: nil, cancelled: false,
                                      usage: streamEvent(answered: true), speakingSeconds: reading?.voicedSpanSeconds)
        }

        let reason = failure ?? (hadOutage ? "dropped during the segment"
            : tooLong ? "kept a segment open too long" : "returned nothing")
        dlog("Engine", "StreamingRecognitionSession.finish: stream \(reason) — falling back to batch upload", level: .notice)
        // The partial text on screen described a stream that is being discarded.
        await MainActor.run { session.onEvent?(.live(committed: "", partial: "")) }
        // Answered unless the socket broke: a stream that came back with nothing was a
        // working request, not a refused one.
        let streamUsage = streamEvent(answered: failure == nil && !hadOutage)
        let answer = await fallback.finish()
        await MainActor.run {
            DictationTraceRecorder.record(.fallback, text: answer.text, error: answer.error)
        }
        // The socket was paid for as well as the upload that replaced it.
        var outcome = answer
        if !outcome.cancelled { outcome.usage = streamUsage + outcome.usage }
        return outcome
    }

    /// The upload's guards, applied to the stream's answer: a segment too short to be
    /// speech, a silent one, one with no voice in it and one whose whole text
    /// `HallucinationFilter` rejects come back
    /// as they would from `BatchRecognitionSession`, not as text to paste. A stream is
    /// answered by the server's model whatever the microphone heard, so without these it
    /// pasted "Evet." for a shortcut pressed and let go. nil lets the text through, with
    /// the detector's reading when it judged the segment — Usage's speaking time.
    ///
    /// The silent and hallucinated segments are an empty result with no file: the engine
    /// archives the writer's audio for a History retry itself (`recordOutcome`). A writer
    /// that holds nothing measured nothing, and only the phrase test applies.
    private nonisolated func guardedStreamResult(_ text: String) async -> (RecognitionOutcome?, VoiceActivityReading?) {
        let duration = writer.bufferedDuration
        let empty = RecognitionOutcome(text: "", error: nil, audioFileURL: nil, cancelled: false)
        var dropped: RecognitionOutcome?
        var reading: VoiceActivityReading?
        if duration > 0, duration < STTTuning.minimumSegmentSeconds {
            dlog("Engine", "StreamingRecognitionSession.finish: \(String(format: "%.2f", duration))s is too short to be speech — dropped")
            dropped = .discarded
        } else if duration > 0, !writer.hasAudibleSignal {
            dlog("Engine", "StreamingRecognitionSession.finish: the segment is silent — its text dropped")
            dropped = empty
        } else {
            if duration > 0 { reading = await VoiceActivity.read(writer) }
            if let reading, !reading.holdsSpeech {
                // The audio has already gone up the socket; what the server made of a
                // keyboard or a fan is still not pasted.
                dlog("Engine", "StreamingRecognitionSession.finish: no voice in the segment — its text dropped")
                dropped = empty
            } else if let rejection = HallucinationFilter.rejection(text, segmentSeconds: duration, languages: languages) {
                dlog("Engine", "StreamingRecognitionSession.finish: the whole result of a \(String(format: "%.1f", duration))s segment is \(rejection) — dropped")
                dropped = empty
            }
        }
        guard let dropped else { return (nil, reading) }
        // The overlay may still show what the stream said; it is not what the stop pastes.
        await MainActor.run { self.onEvent?(.live(committed: "", partial: "")) }
        return (dropped, reading)
    }

    public func cancel() {
        closing = true
        reconnectTask?.cancel()
        reconnectTask = nil
        sendTarget.set(nil)
        eventsTask?.cancel()
        eventsTask = nil
        provider.cancel()
        fallback.cancel()
    }
}

/// The session's `OpenSegmentClock`: fed on the audio thread, told on main that the
/// server closed a segment. `@unchecked Sendable`: `value` is held under `lock`.
private final class OpenSegmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OpenSegmentClock

    init(_ clock: OpenSegmentClock) {
        value = clock
    }

    var clock: OpenSegmentClock {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func feed(byteCount: Int) {
        lock.lock()
        value.feed(byteCount: byteCount)
        lock.unlock()
    }

    func segmentClosed() {
        lock.lock()
        value.segmentClosed()
        lock.unlock()
    }
}

/// The provider `feed` sends to, shared between main (which swaps it on a reconnect)
/// and the audio thread (which reads it for every buffer). The lock is held only to
/// read or write the reference — never across a `send`, which takes the provider's own
/// locks. A buffer that read the old provider just before a swap goes to a closed
/// socket, whose `send` does nothing. `@unchecked Sendable`: `provider` is held under `lock`.
private final class TranscriberBox: @unchecked Sendable {
    private let lock = NSLock()
    private var provider: StreamingTranscriber?

    var current: StreamingTranscriber? {
        lock.lock()
        defer { lock.unlock() }
        return provider
    }

    func set(_ provider: StreamingTranscriber?) {
        lock.lock()
        self.provider = provider
        lock.unlock()
    }
}
