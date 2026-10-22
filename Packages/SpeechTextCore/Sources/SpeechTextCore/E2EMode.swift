// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What `scripts/e2e.sh` changes in a debug build, read from launch arguments (the
/// argument domain, so nothing here is ever written to the app's preferences). A
/// Release build compiles none of it: `isActive` is false and every input is nil.
///
/// - `-SPTAudioInput a.wav,b.wav` — every capture start (`SpeechEngine.makeCapture`)
///   plays the next file instead of opening a microphone; see `FileCapture`.
/// - `-SPTKeysFile <path>` — API keys for this session only, in the env-file shape
///   `LiveProviderTests` reads (`GROQ_API_KEY=…`). Never written anywhere: the installed
///   keychain build takes a key in its preferences domain for a newer one and would
///   replace the user's own with it.
/// - The bundle identifier `app.speech-text.SpeechText.e2e`, which the script stamps on
///   its build: its own preferences domain and its own data folder
///   (`Application Support/SpeechText-e2e`), so a run never reaches the user's settings,
///   History or traces, and no rename migration copies anything into it.
/// - `-SPTCloseStreamAfter <seconds>` — once per launch, that long after the first
///   stream's first partial, its socket is closed and the session told the network went
///   away (`StreamCloser`), so the reconnect runs as after a Wi-Fi drop (OA4)
///   without switching the Mac's network off.
/// - `-SPTAppleFailAfter <seconds>` — once per launch, that long after the first Apple
///   chunk's first words, the chunk then current fails as a real task error would
///   (kAFAssistantErrorDomain 1101; `AppleRecognitionSession.failChunkForE2E`), so the
///   rotation after an error (`AppleErrorRotation`) runs without a recogniser that fails
///   on cue.
public enum E2EMode {
    static let bundleIdentifier = "app.speech-text.SpeechText.e2e"

    /// The env-file names, as `LiveProviderTests` reads them from the environment.
    static let keyNames: [String: String] = [
        "GROQ_API_KEY": SettingsKeys.groqAPIKey,
        "OPENAI_API_KEY": SettingsKeys.openAIAPIKey,
        "ELEVENLABS_API_KEY": SettingsKeys.elevenLabsAPIKey,
        "ANTHROPIC_API_KEY": SettingsKeys.anthropicAPIKey,
    ]

    /// `NAME=value` lines (an `export ` prefix, quotes, blank lines and `#` comments
    /// allowed) mapped onto the `SettingsKeys` the store holds; unknown names are left out.
    public static func parseKeys(_ text: String) -> [String: String] {
        var keys: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if let key = keyNames[name], !value.isEmpty { keys[key] = value }
        }
        return keys
    }

    #if DEBUG
    static var isActive: Bool { Bundle.main.bundleIdentifier == bundleIdentifier }

    /// The clips `-SPTAudioInput` names, in order; nil when the argument is absent.
    public static let audioInputs: [URL]? = UserDefaults.standard.string(forKey: "SPTAudioInput").map { list in
        list.split(separator: ",").map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)) }
    }

    public static let keysFile: URL? = UserDefaults.standard.string(forKey: "SPTKeysFile")
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

    /// `-SPTCloseStreamAfter`'s seconds; nil when the argument is absent or not positive.
    static let closeStreamAfter: TimeInterval? = {
        let seconds = UserDefaults.standard.double(forKey: "SPTCloseStreamAfter")
        return seconds > 0 ? seconds : nil
    }()

    /// Read and set under `lock` only, which is what makes the unchecked access safe.
    private nonisolated(unsafe) static var streamCloserUsed = false

    /// `-SPTAppleFailAfter`'s seconds; nil when the argument is absent or not positive.
    static let appleFailAfter: TimeInterval? = {
        let seconds = UserDefaults.standard.double(forKey: "SPTAppleFailAfter")
        return seconds > 0 ? seconds : nil
    }()

    /// Under `lock`, as `streamCloserUsed` is.
    private nonisolated(unsafe) static var appleFailureUsed = false

    /// `-SPTAppleFailAfter`'s seconds the first time it is asked in an e2e launch with the
    /// argument — an Apple chunk's first words — and nil every other time, so one chunk in
    /// the launch fails and no other.
    public static func appleFailureOnce() -> TimeInterval? {
        guard isActive, let seconds = appleFailAfter else { return nil }
        let first = lock.withLock { () -> Bool in
            defer { appleFailureUsed = true }
            return !appleFailureUsed
        }
        return first ? seconds : nil
    }

    /// `provider`, or — the first time in an e2e launch with `-SPTCloseStreamAfter` — the
    /// same provider behind a `StreamCloser`. Only the first: the reconnect builds its
    /// transcriber straight from `makeStreamingTranscriber`, so it is never closed again.
    public static func closingOnce(_ provider: StreamingTranscriber) -> StreamingTranscriber {
        guard isActive, let seconds = closeStreamAfter else { return provider }
        let first = lock.withLock { () -> Bool in
            defer { streamCloserUsed = true }
            return !streamCloserUsed
        }
        return first ? StreamCloser(provider, after: seconds) : provider
    }

    private static let lock = NSLock()
    /// Under `lock`, as `streamCloserUsed` is.
    private nonisolated(unsafe) static var playedInputs = 0

    /// The clip for the next capture, or nil once every one has played — that capture
    /// records silence, as a microphone in a quiet room would.
    public static func nextAudioInput() -> URL? {
        guard let inputs = audioInputs else { return nil }
        return lock.withLock {
            defer { playedInputs += 1 }
            return playedInputs < inputs.count ? inputs[playedInputs] : nil
        }
    }
    #else
    static let isActive = false
    static let closeStreamAfter: TimeInterval? = nil
    static let appleFailAfter: TimeInterval? = nil
    public static let audioInputs: [URL]? = nil
    public static let keysFile: URL? = nil
    #endif

    /// The folder in Application Support this build keeps History, recordings and
    /// traces in.
    public static var supportFolderName: String { isActive ? "SpeechText-e2e" : "SpeechText" }
}

#if DEBUG
/// A stream that loses its connection mid-dictation, for `-SPTCloseStreamAfter`. It
/// passes everything through to the real transcriber until `seconds` after the first
/// partial, then reports `.failed(URLError(.networkConnectionLost))` — the error a Wi-Fi
/// drop gives, which `StreamReconnectPolicy` reopens — and cancels the real one, which
/// closes its socket. The socket really closes; the error is ours. After that it sends
/// nothing and reports nothing more, as a dead socket would.
///
/// `@unchecked Sendable`: its only mutable state, `closed` and `armed`, is held under `lock`.
final class StreamCloser: StreamingTranscriber, @unchecked Sendable {
    private let inner: StreamingTranscriber
    private let seconds: TimeInterval
    private let lock = NSLock()
    private var closed = false
    private var armed = false
    private let continuation: AsyncStream<StreamingSTTEvent>.Continuation
    let events: AsyncStream<StreamingSTTEvent>
    var sampleRate: Double { inner.sampleRate }

    init(_ inner: StreamingTranscriber, after seconds: TimeInterval) {
        self.inner = inner
        self.seconds = seconds
        (events, continuation) = AsyncStream<StreamingSTTEvent>.makeStream()
    }

    func connect(languages: [String]) {
        inner.connect(languages: languages)
        Task { [weak self, inner] in
            for await event in inner.events {
                guard let self else { return }
                guard !self.lock.withLock({ self.closed }) else { return }
                if case .partial = event { self.arm() }
                self.continuation.yield(event)
            }
            self?.continuation.finish()
        }
    }

    private func arm() {
        let first = lock.withLock { () -> Bool in
            defer { armed = true }
            return !armed
        }
        guard first else { return }
        dlog("E2E", "closing the stream in \(seconds) s (-SPTCloseStreamAfter)")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.close() }
    }

    private func close() {
        guard lock.withLock({ () -> Bool in
            defer { closed = true }
            return !closed
        }) else { return }
        dlog("E2E", "closing the stream's socket now (-SPTCloseStreamAfter)")
        continuation.yield(.failed(URLError(.networkConnectionLost)))
        continuation.finish()
        inner.cancel()
    }

    func send(pcm16: Data) {
        guard !lock.withLock({ closed }) else { return }
        inner.send(pcm16: pcm16)
    }

    func finish() async {
        guard !lock.withLock({ closed }) else { return }
        await inner.finish()
    }

    func cancel() {
        lock.withLock { closed = true }
        continuation.finish()
        inner.cancel()
    }
}
#endif
