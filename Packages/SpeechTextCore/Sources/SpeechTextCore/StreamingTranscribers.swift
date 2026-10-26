// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation

// MARK: - Streaming STT Protocol

public enum StreamingSTTEvent: Sendable {
    /// The in-progress text of the current speech segment. Replaces the previous partial.
    case partial(String)
    /// A segment the provider considers final. Segments accumulate.
    case committed(String)
    /// The stream is no longer usable. Whatever was committed so far is still valid,
    /// but the caller should fall back to a batch upload for the whole recording.
    case failed(Error)
}

/// A provider that transcribes audio as it is being captured, over a persistent
/// connection, instead of taking a finished file. Audio is pushed as 16-bit PCM at
/// `sampleRate`; text comes back through `events` while the user is still speaking.
///
/// `Sendable`, because a recognition session uses one from three places at once: the
/// audio thread sends to it, main reads its events, and the stop finishes it off main.
public protocol StreamingTranscriber: AnyObject, Sendable {
    /// The sample rate `send(pcm16:)` expects. The engine converts the mic feed to it.
    var sampleRate: Double { get }
    var events: AsyncStream<StreamingSTTEvent> { get }

    /// Opens the connection. Safe to call once per instance.
    ///
    /// `languages` is the user's own list of ISO-639-1 codes, empty when they named none,
    /// and the count is the whole contract. Each provider honours as much of it as its
    /// API allows: exactly one language is forced, and a *set* reaches only the endpoint
    /// that accepts one. Everywhere else two or more means the same as none — let the
    /// model detect — because sending one of several would be a guess, and a guessed
    /// language is not a mis-spelling but a translation of what was said.
    func connect(languages: [String])
    /// Pushes mono 16-bit little-endian PCM. May be called from the audio thread.
    func send(pcm16: Data)
    /// Commits whatever audio is still pending, waits (bounded) for the provider's last
    /// committed segment, then closes the connection and ends `events`.
    func finish() async
    /// Drops the connection immediately without waiting for anything.
    func cancel()
}

/// Builds a streaming provider for a session's configuration, or nil when the
/// selected engine/model works in batch mode.
public func makeStreamingTranscriber(configuration: RecordingConfiguration) -> StreamingTranscriber? {
    guard configuration.streams else { return nil }
    switch configuration.provider {
    case .elevenlabs:
        return ElevenLabsRealtimeTranscriber(apiKey: configuration.apiKey(for: .elevenLabs),
                                          model: configuration.model.id,
                                          keyterms: configuration.liveVocabulary)
    case .openai:
        return OpenAIRealtimeTranscriber(apiKey: configuration.apiKey(for: .openAI),
                                      model: configuration.model.id,
                                      keywords: configuration.liveVocabulary)
    case .apple, .groq, .local:
        return nil
    }
}

// MARK: - The socket

/// The WebSocket a realtime transcriber talks through — `URLSessionWebSocketTask`'s own
/// shape, so the app hands it one unchanged, and the contract tests
/// (RealtimeTranscriberContractTests.swift) a fake that records what is sent, completes a
/// send inside the call when asked to, and delivers scripted messages when the test says.
protocol RealtimeWebSocket: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message,
              completionHandler: @escaping @Sendable ((any Error)?) -> Void)
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: RealtimeWebSocket {}

/// Opens the socket for a request; the app's default opens a `URLSessionWebSocketTask`.
typealias RealtimeSocketOpener = @Sendable (URLRequest) -> any RealtimeWebSocket

/// Every wait a realtime transcriber times — the finish timeout, the commit grace, the
/// hold's deadline, the ready wait. Must return early when its task is cancelled, as
/// `Task.sleep` does: `finish()` cancels the timer it no longer needs and waits for it.
/// The contract tests pass a clock they advance by hand.
typealias RealtimeSleep = @Sendable (TimeInterval) async -> Void

let realtimeTaskSleep: RealtimeSleep = { seconds in
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// MARK: - ElevenLabs Scribe v2 Realtime

/// WebSocket client for `wss://api.elevenlabs.io/v1/speech-to-text/realtime`.
///
/// The server runs voice-activity detection and commits a segment on every pause in
/// speech, sending `partial_transcript` while a segment is in progress and
/// `committed_transcript` when it closes. `finish()` sends a last chunk with
/// `commit: true` so the tail of the dictation is committed without waiting for the
/// VAD's silence threshold.
///
/// The engine calls `connect` before it starts `AVAudioEngine`, so the TLS handshake
/// overlaps the 100–300 ms the hardware takes to come up. Audio that arrives before
/// the server's `session_started` is held in `preSessionMessages` — already encoded as
/// the socket messages it will become, on the audio thread — and flushed the moment it
/// does: the server does not promise to keep audio sent ahead of that message, and
/// the first syllable of a dictation is exactly what must not be lost.
///
/// `@unchecked Sendable`, which `StreamingTranscriber` relies on, and the checking is
/// this map's to do, field by field:
///
/// - `lock` guards everything the audio thread, the receive loop, `finish()` and the
///   timers share: `task`, `receiveLoop`, the audio held (`pendingAudio`,
///   `preSessionMessages`, `preSessionBytes`), `sessionStarted`, `isClosed`, and the
///   stop's wait — `awaitingCommit`, `commitArrived`, `finishContinuation`, `settle` and
///   the two timers, `commitGrace` and `holdDeadline`.
/// - `sendLock` guards no field. It orders the socket's sends, so a batch is not split
///   by a chunk from another thread, and is always taken before `lock`, never under it.
/// - `lastCommittedText` is touched only by `handle`, which runs serially on the receive
///   loop, so it needs no lock.
/// - The rest is `let`, and `continuation` may be yielded to from any thread.
final class ElevenLabsRealtimeTranscriber: StreamingTranscriber, @unchecked Sendable {
    let sampleRate: Double = 16_000
    let events: AsyncStream<StreamingSTTEvent>

    private let apiKey: String
    private let model: String
    /// Sent as `keyterms` — already fitted to this model's limits.
    private let keyterms: [String]
    private let continuation: AsyncStream<StreamingSTTEvent>.Continuation

    private let lock = NSLock()
    /// Serialises the socket's `send` calls, so a batch (the pre-session flush, or the
    /// messages `finish()` releases ahead of its commit) cannot be interleaved by a
    /// chunk from the audio thread. Deliberately *not* `lock`: a `send` completion that
    /// URLSession runs synchronously re-enters `fail` → `close`, which take `lock`.
    /// Always acquired before `lock`, never while holding it.
    private let sendLock = NSLock()
    private var task: (any RealtimeWebSocket)?
    private var receiveLoop: Task<Void, Never>?
    private var pendingAudio = Data()
    /// Chunks ready to send but held until `session_started`, already encoded as the
    /// socket messages they will become, so the flush is nothing but `task.send` calls
    /// (the base64/JSON work is done on the audio thread as the chunk is buffered,
    /// which is where it would have been done anyway). Bounded by
    /// `STTTuning.streamPreSessionBufferSeconds`: if it fills, the stream fails over.
    private var preSessionMessages: [String] = []
    private var preSessionBytes = 0
    private var sessionStarted = false
    private var isClosed = false
    /// Resumed by the first `committed_transcript` that arrives after `finish()` asked
    /// for a commit, so the caller does not have to guess how long to wait.
    private var finishContinuation: CheckedContinuation<Void, Never>?
    /// Set once `finish()` has asked for a commit, and flipped when that commit's
    /// transcript arrives — which can happen before the wait is even installed.
    private var awaitingCommit = false
    private var commitArrived = false
    /// Counts down `STTTuning.streamCommitGraceSeconds` after a `committed_transcript`
    /// seen while awaiting the commit; cancelled by a partial that shows more is coming.
    private var commitGrace: Task<Void, Never>?
    /// What the messages after the stop's commit have settled — see `StreamFinishSettle`.
    /// nil until `finish()` sends that commit.
    private var settle: StreamFinishSettle?
    /// `STTTuning.streamCommitAfterPartialSeconds`, armed by the first partial `settle`
    /// holds and never extended by the ones after it.
    private var holdDeadline: Task<Void, Never>?
    /// The text of the most recent `committed_transcript`, kept so the partial that
    /// echoes it can be recognised. Touched only from `handle`, which runs serially on
    /// the receive loop, so it needs no lock. Cleared by the first partial that says
    /// something else — that one belongs to the next segment.
    private var lastCommittedText = ""

    /// Bytes of 16-bit mono PCM for a given duration at `sampleRate`.
    private func bytes(forSeconds seconds: Double) -> Int { Int(sampleRate * seconds) * 2 }
    /// Send audio in `STTTuning.streamChunkSeconds` messages rather than one per tap buffer.
    private var minimumChunkBytes: Int { bytes(forSeconds: STTTuning.streamChunkSeconds) }
    private var maxPreSessionBytes: Int { bytes(forSeconds: STTTuning.streamPreSessionBufferSeconds) }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config)
    }()

    private let openSocket: RealtimeSocketOpener
    private let sleep: RealtimeSleep

    init(apiKey: String, model: String, keyterms: [String] = [],
         openSocket: RealtimeSocketOpener? = nil, sleep: @escaping RealtimeSleep = realtimeTaskSleep) {
        self.apiKey = apiKey
        self.model = model
        self.keyterms = keyterms
        self.openSocket = openSocket ?? { Self.session.webSocketTask(with: $0) }
        self.sleep = sleep
        var continuation: AsyncStream<StreamingSTTEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect(languages: [String]) {
        var request = URLRequest(url: Self.realtimeURL(model: model, languages: languages, keyterms: keyterms))
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        // The count only: terms are often people's names, and the log is public.
        dlog("ElevenLabs", "realtime: connecting, model=\(model), language=\(languages.count == 1 ? languages[0] : "auto"), keyterms=\(keyterms.count)")
        let task = openSocket(request)
        lock.lock()
        self.task = task
        lock.unlock()
        task.resume()

        adoptReceiveLoop(Task { [weak self] in
            await self?.runReceiveLoop(task)
        })
    }

    /// The socket's address. Every value is percent-encoded by hand: `URLComponents`
    /// leaves `+`, which the server reads as a space, so "C++" would arrive as "C  ".
    static func realtimeURL(model: String, languages: [String], keyterms: [String]) -> URL {
        var items = [
            URLQueryItem(name: "model_id", value: model),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            // Tunables and quality flags — see `STTTuning`. The server echoes both in
            // `session_started.config` (verified live), so a typo here would be visible
            // in the debug log rather than silently ignored.
            URLQueryItem(name: "vad_silence_threshold_secs",
                         value: String(STTTuning.vadSilenceThresholdSeconds)),
            URLQueryItem(name: "no_verbatim", value: STTTuning.noVerbatim ? "true" : "false"),
        ]
        // Scribe's query string has `language_code` and nothing plural, so a set cannot
        // be narrowed here: two or more languages go unsent and the model detects.
        if languages.count == 1 {
            items.append(URLQueryItem(name: "language_code", value: languages[0]))
        }
        // An array parameter is the name repeated. Nothing when there are no terms: they
        // cost extra.
        items += keyterms.map { URLQueryItem(name: "keyterms", value: $0) }

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        components.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        return components.url!
    }

    func send(pcm16: Data) {
        // `sendLock` first, and held until the chunk is on the socket: taken only after
        // `lock` was released, a `finish()` that won it in between found `pendingAudio`
        // already emptied, committed nothing but padding, and the chunk landed *after*
        // the commit — up to 100 ms of the last word in a segment that never closes.
        sendLock.lock()
        defer { sendLock.unlock() }
        lock.lock()
        // Nothing after the stop's commit (`awaitingCommit`): `finish()` has already taken
        // the audio it commits, and a chunk sent now would open a segment never closed.
        guard !isClosed, !awaitingCommit, let task else {
            lock.unlock()
            return
        }
        pendingAudio.append(pcm16)
        guard pendingAudio.count >= minimumChunkBytes else {
            lock.unlock()
            return
        }
        let chunk = pendingAudio
        pendingAudio = Data()
        guard sessionStarted else {
            // Handshake still in flight: hold the chunk. If the bound is hit the server
            // is not coming; rather than drop audio and later call a transcript missing
            // its opening seconds a success, fail so the stop takes the batch upload.
            guard preSessionBytes + chunk.count <= maxPreSessionBytes else {
                lock.unlock()
                fail(TranscriptionError.realtime(.elevenLabs, "no_session",
                    "no session_started within \(STTTuning.streamPreSessionBufferSeconds)s of audio"))
                return
            }
            if let message = Self.encodeChunk(chunk, commit: false, sampleRate: sampleRate) {
                preSessionMessages.append(message)
                preSessionBytes += chunk.count
            }
            lock.unlock()
            return
        }
        lock.unlock()

        if let message = Self.encodeChunk(chunk, commit: false, sampleRate: sampleRate) {
            enqueue(message, over: task)
        }
    }

    /// `session_started` arrived: release everything held for it, in order, ahead of
    /// any chunk `send` produces from now on.
    private func flushPreSessionAudio() {
        // `sendLock` is taken first and held across the drain, so a chunk the audio
        // thread produces the moment `sessionStarted` flips waits behind the audio that
        // was recorded before it. `lock` is released before the sends: holding it across
        // `task.send` deadlocks the moment URLSession runs a completion synchronously,
        // because that completion path (`fail` → `close`) takes `lock` too.
        sendLock.lock()
        defer { sendLock.unlock() }

        lock.lock()
        sessionStarted = true
        let held = preSessionMessages
        preSessionMessages = []
        preSessionBytes = 0
        let task = self.task
        lock.unlock()

        guard let task, !held.isEmpty else { return }
        dlog("ElevenLabs", "realtime: flushing \(held.count) chunk(s) buffered before session_started")
        for message in held {
            enqueue(message, over: task)
        }
    }

    func finish() async {
        guard let (held, chunk, task) = takePendingForFinish() else { return }

        // Pad the tail with silence so the commit is not throttled — see
        // `STTTuning.streamCommitPaddingSeconds`.
        var tail = chunk
        tail.append(Data(count: bytes(forSeconds: STTTuning.streamCommitPaddingSeconds)))
        dlog("ElevenLabs", "realtime: finishing, committing \(tail.count) bytes")
        // One batch: anything still held for `session_started` has to reach the server
        // ahead of the commit, or the commit closes a segment missing its own audio.
        var messages = held
        if let commit = Self.encodeChunk(tail, commit: true, sampleRate: sampleRate) {
            messages.append(commit)
        }
        sendMessages(messages, over: task)

        // Wait for the commit's transcript, but never hang the paste on it.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    guard let self else { cont.resume(); return }
                    self.installFinishWait(cont)
                }
            }
            group.addTask { [weak self] in
                await self?.sleep(STTTuning.streamFinishTimeoutSeconds)
                guard !Task.isCancelled else { return }
                dlog("ElevenLabs", "realtime: no commit reply within \(STTTuning.streamFinishTimeoutSeconds)s — using what we have", level: .notice)
                self?.endFinishWait()
            }
            // The group waits for both children on exit; the timeout resumes the
            // continuation, and the continuation's arrival cancels the timeout.
            await group.next()
            group.cancelAll()
        }

        // Already ended by whoever woke the wait; this only makes sure, through the one
        // place that decides how it ends.
        endFinishWait()
        close(with: nil)
    }

    func cancel() {
        dlog("ElevenLabs", "realtime: cancelled")
        close(with: nil)
    }

    // MARK: Internals

    /// Locks can't be taken inside an async function, so `finish()` grabs its state here.
    /// Returns the messages still held for `session_started` (they go out ahead of the
    /// commit; if the session never started, the commit fails and the batch path takes
    /// over), the audio to commit, and the socket.
    private func takePendingForFinish() -> ([String], Data, any RealtimeWebSocket)? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, let task else { return nil }
        let held = preSessionMessages
        preSessionMessages = []
        preSessionBytes = 0
        let chunk = pendingAudio
        pendingAudio = Data()
        awaitingCommit = true
        settle = StreamFinishSettle()
        return (held, chunk, task)
    }

    /// Is this `partial_transcript` nothing but the segment the server already
    /// committed? Compared whole and trimmed rather than by prefix: a genuine next
    /// segment that opens with the same words is still growing, so it only matches
    /// once it has said exactly as much — and even then its own commit carries the
    /// text, so nothing is lost but a moment of ghost text.
    static func isEchoOfCommitted(partial: String, lastCommitted: String) -> Bool {
        let partial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !partial.isEmpty else { return false }
        return partial == lastCommitted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func encodeChunk(_ pcm: Data, commit: Bool, sampleRate: Double) -> String? {
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": pcm.base64EncodedString(),
            "commit": commit,
            "sample_rate": Int(sampleRate),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Puts the whole batch on the socket with nothing of another thread's in between.
    private func sendMessages(_ messages: [String], over task: any RealtimeWebSocket) {
        sendLock.lock()
        defer { sendLock.unlock() }
        for message in messages {
            enqueue(message, over: task)
        }
    }

    /// The raw send. Callers hold `sendLock`; `task.send` only enqueues, so the hold is
    /// short even for a flush of the whole pre-session buffer.
    private func enqueue(_ text: String, over task: any RealtimeWebSocket) {
        task.send(.string(text)) { [weak self] error in
            if let error {
                self?.fail(error)
            }
        }
    }

    private func runReceiveLoop(_ task: any RealtimeWebSocket) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                let closed = lock.withLock { isClosed }
                if !closed {
                    fail(error)
                }
                return
            }

            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
            @unknown default: continue
            }
            handle(text)
        }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["message_type"] as? String else {
            dlog("ElevenLabs", "realtime: unreadable message of \(raw.utf8.count) bytes", level: .notice)
            return
        }

        switch type {
        case "session_started":
            let config = json["config"] as? [String: Any] ?? [:]
            dlog("ElevenLabs", "realtime: session started (vad_silence=\(config["vad_silence_threshold_secs"] ?? "?"), no_verbatim=\(config["no_verbatim"] ?? "?"))")
            flushPreSessionAudio()
        case "partial_transcript":
            let text = json["text"] as? String ?? ""
            // Scribe sometimes repeats a segment it has just committed as one more
            // partial (observed ~60 ms after the commit). Taken at face value it reads
            // as a fresh segment holding the same words: the caller joins it onto the
            // committed text — pasting the dictation twice. It is an echo of a closed
            // segment, so drop it. An echo that is re-heard rather than repeated gets
            // past this test; after the stop, `holdAfterCommitReply` catches it.
            guard !Self.isEchoOfCommitted(partial: text, lastCommitted: lastCommittedText) else {
                dlog("ElevenLabs", "realtime: ignoring partial echoing the committed segment", level: .debug)
                return
            }
            if !text.isEmpty { lastCommittedText = "" }
            if holdAfterCommitReply(text) { return }
            continuation.yield(.partial(text))
        case "committed_transcript":
            let text = json["text"] as? String ?? ""
            dlog("ElevenLabs", "realtime: committed \(text.count) chars")
            lastCommittedText = text
            // Yielded before the settle hears of it: a wait that ended in between would
            // otherwise close the stream with this commit's text still unsent, and the
            // stop would paste without it.
            continuation.yield(.committed(text))
            noteCommitReply()
            commitReplyArrived()
        case "committed_transcript_with_timestamps", "committed_transcript_entities":
            break
        case "commit_throttled":
            // Our commit was ignored (too little audio since the last one). Nothing
            // further is coming for it, so stop waiting; the stream itself is fine —
            // unless a partial is held, whose words now have no commit to carry them.
            dlog("ElevenLabs", "realtime: \(json["error"] as? String ?? "commit throttled")", level: .notice)
            endFinishWait()
        case "auth_error", "quota_exceeded", "rate_limited", "session_time_limit_exceeded",
             "error", "invalid_request":
            // The documented error variants. Only these end the stream: failing on
            // anything unrecognised would turn a future informational message (a
            // keepalive, a VAD state change, …) into a silent degrade where every
            // recording pays for the streamed minutes *and* a batch re-upload.
            let detail = json["error"] as? String ?? raw
            // log-privacy: ok — the vendor's error message, not a transcript
            dlog("ElevenLabs", "realtime: \(type): \(detail.prefix(200))", level: .error)
            fail(TranscriptionError.realtime(.elevenLabs, type, detail))
        default:
            // Unknown but well-formed — the server's vocabulary is open (three purely
            // informational types are already special-cased above). A socket that
            // genuinely breaks still reaches `fail` through `runReceiveLoop`'s catch,
            // so ignoring this never loses the batch fallback.
            dlog("ElevenLabs", "realtime: ignoring unknown message_type \(type)")
        }
    }

    /// Reports the stream broken, once. One drop is often reported twice — by the receive
    /// loop's error and by a pending send's completion, on URLSession's queue — so the
    /// stream is claimed closed in the same critical section that checks it; a check
    /// released before `close` let both through, and each `.failed` opened a socket of its
    /// own. The yield and the rest of the close run outside `lock`: this is reached from a
    /// send's completion, under `sendLock`.
    private func fail(_ error: Error) {
        guard let claim = claimClose() else { return }
        report(error, closing: claim)
    }

    /// The rest of a failure claimed under `lock`, outside it.
    private func report(_ error: Error, closing claim: ClosedSocket) {
        dlog("ElevenLabs", "realtime: failed: \(error.localizedDescription)", level: .error)
        continuation.yield(.failed(error))
        tearDown(claim)
    }

    /// A `committed_transcript` while `finish()` is waiting. It is probably the reply
    /// to our commit — but it may be an earlier VAD segment's, with ours still queued
    /// behind it, so release the wait only after `STTTuning.streamCommitGraceSeconds`
    /// pass without a partial showing that another segment is open.
    private func commitReplyArrived() {
        lock.lock()
        guard awaitingCommit, !isClosed, settle?.isOver != true else {
            lock.unlock()
            return
        }
        commitGrace?.cancel()
        commitGrace = Task { [weak self] in
            await self?.sleep(STTTuning.streamCommitGraceSeconds)
            guard !Task.isCancelled else { return }
            self?.endFinishWait()
        }
        lock.unlock()
    }

    /// A partial after the stop's commit has been answered. It is held rather than
    /// passed on (`StreamFinishSettle`): if another commit follows, that commit carries
    /// the words; if none does, it was the server decoding the committed segment again,
    /// and the deadline settles it. The grace is cancelled — the server is still talking.
    /// Once the wait has ended it is dropped instead: the stop has taken its text.
    private func holdAfterCommitReply(_ text: String) -> Bool {
        lock.lock()
        guard !isClosed, var state = settle, state.holds(partial: text) else {
            lock.unlock()
            return false
        }
        settle = state
        guard !state.isOver else {
            lock.unlock()
            dlog("ElevenLabs", "realtime: dropping a partial that came after the wait ended (\(text.count) chars)")
            return true
        }
        commitGrace?.cancel()
        commitGrace = nil
        if holdDeadline == nil {
            holdDeadline = Task { [weak self] in
                await self?.sleep(STTTuning.streamCommitAfterPartialSeconds)
                guard !Task.isCancelled else { return }
                self?.endFinishWait()
            }
        }
        lock.unlock()
        dlog("ElevenLabs", "realtime: holding a partial after the commit reply (\(text.count) chars)", level: .debug)
        return true
    }

    /// A `committed_transcript` after the stop's commit: whatever partial was held, this
    /// commit carries it.
    private func noteCommitReply() {
        lock.lock()
        settle?.committed()
        holdDeadline?.cancel()
        holdDeadline = nil
        lock.unlock()
    }

    /// Ends the wait — the grace after a commit reply, the hold's deadline, the finish
    /// timeout, a throttled commit and `finish()` itself all come here, on threads of
    /// their own. A partial still held is the one case nothing settles: the server
    /// re-decoding the segment it committed, or the final segment's words with their
    /// commit late or never coming. Neither guess is safe — one pastes the dictation
    /// twice, the other drops its last words — so the stream fails and the stop uploads
    /// the segment.
    ///
    /// Decided in one critical section with the close it may claim: checked and acted on
    /// apart, a partial held in between was let go with the wait, and the stop pasted
    /// text missing its last words with no failure reported. The yield and the teardown
    /// run after `lock` is released, as `fail`'s do.
    private func endFinishWait() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        guard settle?.end() == true else {
            let cont = endWaitLocked()
            lock.unlock()
            cont?.resume()
            return
        }
        let claim = claimCloseLocked()
        lock.unlock()
        dlog("ElevenLabs", "realtime: no commit followed the held partial — uploading the segment instead", level: .notice)
        report(TranscriptionError.realtime(.elevenLabs, "unresolved_tail", "a partial followed the stop's commit and no commit carried it"),
               closing: claim)
    }

    private func installFinishWait(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isClosed || commitArrived {
            lock.unlock()
            cont.resume()
            return
        }
        finishContinuation = cont
        lock.unlock()
    }

    /// Lets `finish()` go on, for a close: the stream is over whatever was held.
    private func resumeFinish() {
        lock.lock()
        let cont = endWaitLocked()
        lock.unlock()
        cont?.resume()
    }

    /// Marks the wait over and takes the continuation to resume. Caller holds `lock`
    /// and resumes it after releasing it.
    private func endWaitLocked() -> CheckedContinuation<Void, Never>? {
        if awaitingCommit { commitArrived = true }
        commitGrace?.cancel()
        commitGrace = nil
        holdDeadline?.cancel()
        holdDeadline = nil
        let cont = finishContinuation
        finishContinuation = nil
        return cont
    }

    private func close(with error: Error?) {
        guard let claim = claimClose() else { return }
        tearDown(claim)
    }

    /// Stores the receive loop `connect` started — unless the stream closed meanwhile (a
    /// send that failed at once), when nothing would cancel it but this.
    private func adoptReceiveLoop(_ loop: Task<Void, Never>) {
        lock.lock()
        let closed = isClosed
        if !closed { receiveLoop = loop }
        lock.unlock()
        if closed { loop.cancel() }
    }

    /// Marks the stream closed and takes its socket and receive loop, in one critical
    /// section. nil when it was already closed: whoever closed it does the rest.
    private func claimClose() -> ClosedSocket? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return nil }
        return claimCloseLocked()
    }

    /// `claimClose` for a caller that already holds `lock` and has seen it open.
    private func claimCloseLocked() -> ClosedSocket {
        isClosed = true
        let claim = ClosedSocket(task: task, receiveLoop: receiveLoop)
        task = nil
        receiveLoop = nil
        return claim
    }

    /// The rest of a close, outside `lock`.
    private func tearDown(_ claim: ClosedSocket) {
        resumeFinish()
        claim.receiveLoop?.cancel()
        claim.task?.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
    }
}

/// What a close takes out from under a realtime transcriber's `lock`, to be cancelled
/// once it is released.
private struct ClosedSocket {
    let task: (any RealtimeWebSocket)?
    let receiveLoop: Task<Void, Never>?
}

// MARK: - Settling the stop's commit

/// What Scribe's messages after the stop's commit add up to.
///
/// Nothing on the wire ties a transcript to the commit it answers — a
/// `committed_transcript` is only its text — and Scribe follows a commit, often within
/// 50 ms, with one more partial decoding the same audio again. Sometimes that is the
/// committed text word for word (`isEchoOfCommitted`), sometimes it is re-heard ("Все
/// так, як ми домовились." came back as "Всі так раптом домовились, що вони...", 1.10,
/// and a restatement with another word count before it), and joined on at the stop it pasted the dictation twice.
///
/// Nothing is said after the stop, so a partial after a commit that answered it has
/// two possible meanings. The commit was an earlier VAD segment's, landing late, and
/// the partial is the final segment, whose own commit — ours — is still coming and will
/// carry its words; or the commit was ours, and the partial is the echo. So the partial
/// is held, never shown: a later commit drops it, and one still held when the wait ends
/// is `isUnresolved` — the provider then fails the stream and the segment is uploaded,
/// because guessing either way loses: an echo kept doubles the text, a tail dropped
/// truncates it. Pure, so the replay harness settles a scripted stop the same way.
///
/// The end of the wait is part of the state, not a separate check: the grace after a
/// commit, the hold's deadline, the finish timeout and a throttled commit each end it on
/// a thread of their own, and a partial can be held between a look at `isUnresolved`
/// and the wait being let go — the stop then pasted a dictation missing its last words
/// and reported nothing. `end()` decides both at once, and once it has, nothing more is
/// held.
struct StreamFinishSettle {
    private(set) var replied = false
    private(set) var held: String?
    /// The wait has ended (`end()`); the stop has already taken the stream's text.
    private(set) var isOver = false

    /// Whether `text` is kept back rather than passed on: a partial with words in it,
    /// after a commit reply. Before one it is the final segment taking shape. After the
    /// wait has ended such a partial is kept back but not held — dropped: passed on, it
    /// would be joined onto the text the stop pastes, which is the doubled dictation
    /// again, and held, it would be a hold nothing will ever settle.
    mutating func holds(partial text: String) -> Bool {
        guard replied, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if !isOver { held = text }
        return true
    }

    /// A `committed_transcript` arrived. It carries whatever was held.
    mutating func committed() {
        replied = true
        held = nil
    }

    /// The wait is over. True when it ended with a partial no commit carried — the
    /// stream must then fail, so the stop uploads the segment.
    mutating func end() -> Bool {
        isOver = true
        return held != nil
    }

    /// The wait ended, or would end now, with a partial that no commit carried.
    var isUnresolved: Bool { held != nil }
}

// MARK: - OpenAI GPT Live Transcribe

/// WebSocket client for `wss://api.openai.com/v1/realtime?intent=transcription`.
///
/// Three things make it a different shape from Scribe's socket, all of them established
/// against the live service on 2026-09-21 rather than read off the docs:
///
/// 1. **It runs no voice-activity detection.** `turn_detection` is rejected outright for
///    `gpt-live-transcribe` ("Turn detection is not supported for this transcription
///    model"), so nothing is ever committed on a pause: one item stays open, growing,
///    until we ask for it. There is no mid-dictation `.committed` and no VAD threshold
///    to tune — the whole segment arrives at `finish()`.
/// 2. **Transcripts arrive as increments, not restatements.** Each
///    `...transcription.delta` carries only the newly decoded text. The caller's merge
///    layer is written against cumulative strings, so the accumulation happens here and
///    `.partial` is always the whole segment so far. `.completed` carries the
///    authoritative transcript of the item and wins over the deltas that built it —
///    the deltas stopped a word short of it in every run.
/// 3. **The session must be configured before audio counts.** A fresh session has
///    `transcription: null`, so audio appended before the server acknowledges our
///    `session.update` is transcribed by nobody. `session.updated` — not the
///    `session.created` that precedes it — is therefore the "server is ready" signal
///    the pre-session buffer waits for.
///
/// The audio format is not negotiable: the session rejects any rate but exactly 24 kHz
/// (16 kHz is "below minimum", 48 kHz "above maximum"), which is why
/// `StreamingRecognitionSession` resamples for this provider instead of handing over
/// the 16 kHz bytes the upload file is made of.
///
/// `@unchecked Sendable`, which `StreamingTranscriber` relies on, with the same kind of
/// map as `ElevenLabsRealtimeTranscriber`'s:
///
/// - `lock` guards `task`, `receiveLoop`, `languages`, the audio held (`pendingAudio`,
///   `preSessionMessages`, `preSessionBytes`), `sessionReady`, `isClosed`, the ready wait
///   (`readyContinuation`, `readyWaitExpired`) and the stop's (`awaitingCommit`,
///   `commitArrived`, `finishContinuation`).
/// - `sendLock` guards no field: it orders the socket's sends, taken before `lock`.
/// - `deltas` and `completedText` are touched only by `handle`, on the receive loop, so
///   they need no lock.
/// - The rest is `let`, and `continuation` may be yielded to from any thread.
final class OpenAIRealtimeTranscriber: StreamingTranscriber, @unchecked Sendable {
    /// Fixed by the service — see the class comment.
    let sampleRate: Double = 24_000
    let events: AsyncStream<StreamingSTTEvent>

    private let apiKey: String
    private let model: String
    /// Sent as `keywords` in the session's transcription block — already fitted to this
    /// model's limits.
    private let keywords: [String]
    private let continuation: AsyncStream<StreamingSTTEvent>.Continuation

    private let lock = NSLock()
    /// Serialises the socket's `send` calls — same discipline as
    /// `ElevenLabsRealtimeTranscriber`: always acquired before `lock`, never while holding
    /// it, because a send completion URLSession runs synchronously re-enters `fail` →
    /// `close`, which take `lock`.
    private let sendLock = NSLock()
    private var task: (any RealtimeWebSocket)?
    private var receiveLoop: Task<Void, Never>?
    private var pendingAudio = Data()
    /// Chunks encoded on the audio thread and held until `session.updated`.
    private var preSessionMessages: [String] = []
    private var preSessionBytes = 0
    private var sessionReady = false
    private var isClosed = false
    /// The languages `connect` was given, kept until `session.created` asks for the
    /// configuration. Written under `lock` before the socket opens, read under it on the
    /// receive loop.
    private var languages: [String] = []
    /// Resumed by the transcript of the commit `finish()` asked for.
    private var finishContinuation: CheckedContinuation<Void, Never>?
    /// Resumed once the audio held for `session.updated` is on the socket, so a stop made
    /// before the session was ready commits after that audio rather than ahead of it.
    private var readyContinuation: CheckedContinuation<Void, Never>?
    /// The ready wait timed out; a continuation installed after that must not be stored.
    private var readyWaitExpired = false
    private var awaitingCommit = false
    private var commitArrived = false
    /// Deltas accumulated per `item_id`. Touched only from `handle`, which runs serially
    /// on the receive loop, so it needs no lock.
    private var deltas: [String: String] = [:]
    /// Every item completed so far, joined. `.committed` has to be *cumulative* — that
    /// is the shape the caller's `mergedTranscript` is written against, where a commit
    /// restating everything replaces what is held. Without turn detection there is only
    /// ever one item, so this is the same string either way today; it is kept here so
    /// that a second item — if the service ever commits on a pause — appends instead of
    /// being merged against text it does not restate.
    private var completedText = ""

    /// Bytes of 16-bit mono PCM for a given duration at `sampleRate`.
    private func bytes(forSeconds seconds: Double) -> Int { Int(sampleRate * seconds) * 2 }
    private var minimumChunkBytes: Int { bytes(forSeconds: STTTuning.streamChunkSeconds) }
    private var maxPreSessionBytes: Int { bytes(forSeconds: STTTuning.streamPreSessionBufferSeconds) }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config)
    }()

    private let openSocket: RealtimeSocketOpener
    private let sleep: RealtimeSleep

    init(apiKey: String, model: String, keywords: [String] = [],
         openSocket: RealtimeSocketOpener? = nil, sleep: @escaping RealtimeSleep = realtimeTaskSleep) {
        self.apiKey = apiKey
        self.model = model
        self.keywords = keywords
        self.openSocket = openSocket ?? { Self.session.webSocketTask(with: $0) }
        self.sleep = sleep
        var continuation: AsyncStream<StreamingSTTEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect(languages: [String]) {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // The count only: terms are often people's names, and the log is public.
        dlog("OpenAI", "realtime: connecting, model=\(model), languages=\(languages.isEmpty ? "auto" : languages.joined(separator: ",")), keywords=\(keywords.count)")
        let task = openSocket(request)
        lock.lock()
        self.task = task
        self.languages = languages
        lock.unlock()
        task.resume()

        adoptReceiveLoop(Task { [weak self] in
            await self?.runReceiveLoop(task)
        })
    }

    func send(pcm16: Data) {
        sendLock.lock()
        defer { sendLock.unlock() }
        lock.lock()
        // Nothing after the stop's commit (`awaitingCommit`): `finish()` has already taken
        // the audio it commits, and a chunk sent now would open a segment never closed.
        guard !isClosed, !awaitingCommit, let task else {
            lock.unlock()
            return
        }
        pendingAudio.append(pcm16)
        guard pendingAudio.count >= minimumChunkBytes else {
            lock.unlock()
            return
        }
        let chunk = pendingAudio
        pendingAudio = Data()
        guard sessionReady else {
            // Held rather than sent: until `session.updated` the session transcribes
            // with `transcription: null`, so audio sent now is audio thrown away. If the
            // bound fills the server is not coming — fail, and let the stop upload the
            // file rather than report a transcript missing its opening seconds.
            guard preSessionBytes + chunk.count <= maxPreSessionBytes else {
                lock.unlock()
                fail(TranscriptionError.realtime(.openAI, "no_session",
                    "no session.updated within \(STTTuning.streamPreSessionBufferSeconds)s of audio"))
                return
            }
            if let message = Self.encodeAudio(chunk) {
                preSessionMessages.append(message)
                preSessionBytes += chunk.count
            }
            lock.unlock()
            return
        }
        lock.unlock()

        if let message = Self.encodeAudio(chunk) {
            enqueue(message, over: task)
        }
    }

    /// `session.updated` arrived: release everything held for it, in order, ahead of any
    /// chunk `send` produces from now on.
    private func flushPreSessionAudio() {
        // Declared first so it runs last: a `finish()` waiting for the session enqueues
        // its commit only after every held chunk is ahead of it on the socket.
        defer { wakeReadyWaiter() }
        sendLock.lock()
        defer { sendLock.unlock() }

        lock.lock()
        guard !sessionReady else {
            lock.unlock()
            return
        }
        sessionReady = true
        let held = preSessionMessages
        preSessionMessages = []
        preSessionBytes = 0
        let task = self.task
        lock.unlock()

        guard let task, !held.isEmpty else { return }
        dlog("OpenAI", "realtime: flushing \(held.count) chunk(s) buffered before session.updated")
        for message in held {
            enqueue(message, over: task)
        }
    }

    func finish() async {
        // A stop that beats `session.updated` (a shortcut pressed and let go at once)
        // used to commit straight away: the commit reached a session that was not
        // configured yet, found none of the held audio in its buffer, and was refused as
        // empty. Wait for the session, and for `flushPreSessionAudio` to send what it was
        // holding, before the commit goes out behind it.
        guard await waitUntilSessionReady() else { return }
        guard let (chunk, task) = takePendingForFinish() else { return }

        // The tail is padded with silence because the server refuses a commit holding
        // under 100 ms of audio (`input_audio_buffer_commit_empty`) — and the tail of a
        // dictation is exactly where the buffer can be nearly empty. Silence costs the
        // transcript nothing; see `STTTuning.streamCommitPaddingSeconds`.
        var tail = chunk
        tail.append(Data(count: bytes(forSeconds: STTTuning.streamCommitPaddingSeconds)))
        dlog("OpenAI", "realtime: finishing, committing \(tail.count) bytes")
        var messages: [String] = []
        if let audio = Self.encodeAudio(tail) { messages.append(audio) }
        if let commit = Self.encode(["type": "input_audio_buffer.commit"]) { messages.append(commit) }
        sendMessages(messages, over: task)

        // Wait for that commit's transcript, but never hang the paste on it.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    guard let self else { cont.resume(); return }
                    self.installFinishWait(cont)
                }
            }
            group.addTask { [weak self] in
                await self?.sleep(STTTuning.streamFinishTimeoutSeconds)
                guard !Task.isCancelled else { return }
                dlog("OpenAI", "realtime: no transcript within \(STTTuning.streamFinishTimeoutSeconds)s — using what we have", level: .notice)
                self?.resumeFinish()
            }
            await group.next()
            group.cancelAll()
        }

        resumeFinish()
        close(with: nil)
    }

    func cancel() {
        dlog("OpenAI", "realtime: cancelled")
        close(with: nil)
    }

    // MARK: Internals

    /// Locks can't be taken inside an async function, so `finish()` grabs its state here.
    /// Only called once the session is ready, so nothing is still held for it.
    private func takePendingForFinish() -> (Data, any RealtimeWebSocket)? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, sessionReady, let task else { return nil }
        let chunk = pendingAudio
        pendingAudio = Data()
        awaitingCommit = true
        return (chunk, task)
    }

    /// True once `session.updated` has arrived and the audio held for it is on the
    /// socket. False when the socket closed meanwhile, or when the session did not come
    /// within `STTTuning.streamSessionReadyTimeoutSeconds` — then the stream is failed,
    /// so the stop hands the segment to the upload, which has all of it on disk.
    private func waitUntilSessionReady() async -> Bool {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    guard let self else { cont.resume(); return }
                    self.installReadyWait(cont)
                }
            }
            group.addTask { [weak self] in
                await self?.sleep(STTTuning.streamSessionReadyTimeoutSeconds)
                guard !Task.isCancelled else { return }
                self?.expireReadyWait()
            }
            await group.next()
            group.cancelAll()
        }

        let (ready, closed) = lock.withLock { (sessionReady, isClosed) }
        if closed { return false }
        guard ready else {
            dlog("OpenAI", "realtime: stopped before session.updated, none within \(STTTuning.streamSessionReadyTimeoutSeconds)s", level: .notice)
            fail(TranscriptionError.realtime(.openAI, "no_session", "session.updated did not arrive before the stop"))
            return false
        }
        return true
    }

    private func installReadyWait(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        // `sessionReady` is set inside `flushPreSessionAudio` under `sendLock`, which the
        // flush holds until every held chunk is enqueued — so seeing it here and not
        // waiting still commits behind them: the commit's own send takes `sendLock`.
        if sessionReady || isClosed || readyWaitExpired {
            lock.unlock()
            cont.resume()
            return
        }
        readyContinuation = cont
        lock.unlock()
    }

    private func expireReadyWait() {
        lock.lock()
        readyWaitExpired = true
        lock.unlock()
        wakeReadyWaiter()
    }

    private func wakeReadyWaiter() {
        lock.lock()
        let cont = readyContinuation
        readyContinuation = nil
        lock.unlock()
        cont?.resume()
    }

    static func encodeSessionUpdate(model: String, languages: [String], sampleRate: Double,
                                    keywords: [String] = []) -> String? {
        var transcription: [String: Any] = ["model": model]
        // Absent rather than empty when there are none, so a session without a
        // vocabulary is configured exactly as it always was.
        if !keywords.isEmpty {
            transcription["keywords"] = keywords
        }
        switch languages.count {
        case 0:
            break
        case 1:
            // Accepted as the singular form and normalised by the server into
            // `languages: ["uk"]`, which `session.updated` echoes back.
            transcription["language"] = languages[0]
        default:
            // The one endpoint in this app that takes a *candidate set*: gpt-live-transcribe
            // picks among the languages the user says they speak instead of among all of
            // them. Every other engine here takes a single value, which is why two or more
            // languages reach them as "detect it yourself" — so this is the only place the
            // list is worth more than its first entry.
            transcription["languages"] = languages
        }
        let input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": Int(sampleRate)],
            "transcription": transcription,
            // Explicitly off: a fresh session defaults to `server_vad`, which this model
            // rejects. Sending null is accepted and is what the echo confirms.
            "turn_detection": NSNull(),
        ]
        return encode(["type": "session.update",
                       "session": ["type": "transcription", "audio": ["input": input]]])
    }

    private static func encodeAudio(_ pcm: Data) -> String? {
        encode(["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    private static func encode(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Puts the whole batch on the socket with nothing of another thread's in between.
    private func sendMessages(_ messages: [String], over task: any RealtimeWebSocket) {
        sendLock.lock()
        defer { sendLock.unlock() }
        for message in messages {
            enqueue(message, over: task)
        }
    }

    private func enqueue(_ text: String, over task: any RealtimeWebSocket) {
        task.send(.string(text)) { [weak self] error in
            if let error {
                self?.fail(error)
            }
        }
    }

    private func runReceiveLoop(_ task: any RealtimeWebSocket) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                let closed = lock.withLock { isClosed }
                if !closed {
                    fail(error)
                }
                return
            }

            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
            @unknown default: continue
            }
            handle(text)
        }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            dlog("OpenAI", "realtime: unreadable message of \(raw.utf8.count) bytes", level: .notice)
            return
        }

        switch type {
        case "session.created":
            // The session exists, but with `transcription: null` — it transcribes nothing
            // until it is configured. Configuring here rather than straight after
            // `resume()` costs one frame's latency (measured at about 10 ms, against the
            // 100–300 ms the microphone takes to come up) and asks nothing of
            // URLSession's queueing of sends made before the handshake finishes.
            lock.lock()
            let languages = self.languages
            let task = self.task
            lock.unlock()
            dlog("OpenAI", "realtime: session created — configuring")
            if let task, let update = Self.encodeSessionUpdate(model: model, languages: languages,
                                                              sampleRate: sampleRate, keywords: keywords) {
                sendMessages([update], over: task)
            }
        case "session.updated":
            dlog("OpenAI", "realtime: session configured (\(Self.transcriptionConfig(in: json)))")
            flushPreSessionAudio()
        case "conversation.item.input_audio_transcription.delta":
            guard let item = json["item_id"] as? String else { return }
            let accumulated = (deltas[item] ?? "") + (json["delta"] as? String ?? "")
            deltas[item] = accumulated
            // Leading whitespace: the first delta of an item opens with a space. The
            // partial carries everything completed before it for the same reason
            // `.committed` does — it is read as the whole segment so far, not as an
            // increment on it.
            let text = joinedSegments(completedText, accumulated.trimmingCharacters(in: .whitespacesAndNewlines))
            continuation.yield(.partial(text))
        case "conversation.item.input_audio_transcription.completed":
            let item = json["item_id"] as? String
            // The item's authoritative text. It has been a word or two ahead of the
            // deltas every time it was measured, so it replaces them rather than
            // extending them; the caller's `mergedTranscript` does that replacement.
            let transcript = (json["transcript"] as? String)
                ?? item.flatMap { deltas[$0] }
                ?? ""
            if let item { deltas[item] = nil }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                completedText = joinedSegments(completedText, trimmed)
            }
            dlog("OpenAI", "realtime: transcript complete, \(trimmed.count) chars")
            continuation.yield(.committed(completedText))
            resumeFinish()
        case "conversation.item.input_audio_transcription.failed":
            let detail = Self.errorDetail(in: json) ?? raw
            // log-privacy: ok — the vendor's error message, not a transcript
            dlog("OpenAI", "realtime: transcription failed: \(detail.prefix(200))", level: .error)
            fail(TranscriptionError.realtime(.openAI, "transcription_failed", detail))
        case "error":
            let error = json["error"] as? [String: Any] ?? [:]
            let code = error["code"] as? String ?? "error"
            let detail = error["message"] as? String ?? raw
            if code == "input_audio_buffer_commit_empty" {
                // The commit held too little audio to be honoured — the recording was
                // over before anything reached the socket. Nothing further is coming for
                // it, so stop waiting; the stream itself is fine and the stop falls back
                // to the upload, which has the whole segment on disk.
                // log-privacy: ok — the vendor's error message, not a transcript
                dlog("OpenAI", "realtime: \(detail.prefix(160))", level: .notice)
                resumeFinish()
                return
            }
            // log-privacy: ok — the vendor's error message, not a transcript
            dlog("OpenAI", "realtime: error \(code): \(detail.prefix(200))", level: .error)
            fail(TranscriptionError.realtime(.openAI, code, detail))
        default:
            // The realtime vocabulary is large and mostly about conversations rather
            // than transcription (`input_audio_buffer.speech_started`,
            // `conversation.item.added`, …). Failing on anything unrecognised would turn
            // an informational event into a silent degrade where every recording pays
            // for the streamed minutes *and* a batch re-upload; a socket that genuinely
            // breaks still reaches `fail` through `runReceiveLoop`'s catch.
            break
        }
    }

    /// The transcription block `session.updated` echoes, for the log line — the same
    /// reason Scribe's config is printed: a typo in what we sent is visible here rather
    /// than silently ignored.
    private static func transcriptionConfig(in json: [String: Any]) -> String {
        guard let session = json["session"] as? [String: Any],
              let audio = session["audio"] as? [String: Any],
              let input = audio["input"] as? [String: Any] else { return "?" }
        let transcription = input["transcription"] as? [String: Any] ?? [:]
        let rate = (input["format"] as? [String: Any])?["rate"] ?? "?"
        let languages = transcription["languages"] ?? transcription["language"] ?? "auto"
        // The keywords' count, never the words: the log is public.
        let keywords = (transcription["keywords"] as? [Any])?.count ?? 0
        return "model=\(transcription["model"] ?? "?"), rate=\(rate), language=\(languages), keywords=\(keywords)"
    }

    private static func errorDetail(in json: [String: Any]) -> String? {
        guard let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }

    /// Reports the stream broken, once — claimed closed in the check's own critical
    /// section, as `ElevenLabsRealtimeTranscriber.fail` explains.
    private func fail(_ error: Error) {
        guard let claim = claimClose() else { return }
        dlog("OpenAI", "realtime: failed: \(error.localizedDescription)", level: .error)
        continuation.yield(.failed(error))
        tearDown(claim)
    }

    private func installFinishWait(_ cont: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isClosed || commitArrived {
            lock.unlock()
            cont.resume()
            return
        }
        finishContinuation = cont
        lock.unlock()
    }

    private func resumeFinish() {
        lock.lock()
        if awaitingCommit { commitArrived = true }
        let cont = finishContinuation
        finishContinuation = nil
        lock.unlock()
        cont?.resume()
    }

    private func close(with error: Error?) {
        guard let claim = claimClose() else { return }
        tearDown(claim)
    }

    /// As `ElevenLabsRealtimeTranscriber.adoptReceiveLoop`.
    private func adoptReceiveLoop(_ loop: Task<Void, Never>) {
        lock.lock()
        let closed = isClosed
        if !closed { receiveLoop = loop }
        lock.unlock()
        if closed { loop.cancel() }
    }

    /// Marks the stream closed and takes its socket and receive loop, in one critical
    /// section. nil when it was already closed: whoever closed it does the rest.
    private func claimClose() -> ClosedSocket? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return nil }
        isClosed = true
        let claim = ClosedSocket(task: task, receiveLoop: receiveLoop)
        task = nil
        receiveLoop = nil
        return claim
    }

    /// The rest of a close, outside `lock`.
    private func tearDown(_ claim: ClosedSocket) {
        resumeFinish()
        wakeReadyWaiter()
        claim.receiveLoop?.cancel()
        claim.task?.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
    }
}
