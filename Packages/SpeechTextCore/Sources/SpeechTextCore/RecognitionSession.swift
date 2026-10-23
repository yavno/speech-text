// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation

// MARK: - Protocol

/// What a session tells the engine while a segment is open. Always delivered on the main thread.
public enum RecognitionEvent: Sendable {
    /// The text so far. `committed` will not change again; `partial` may still be revised.
    /// Kept apart (rather than pre-joined) so a later span layer can map them onto
    /// partial / commit / revise without re-splitting a string.
    case live(committed: String, partial: String)
    /// The recogniser reported an error while the segment was open. Its message becomes
    /// `SpeechEngine.errorMessage`, and `endsRecording` tells the engine not to keep a
    /// dead recogniser listening. Streaming sessions never send this: a broken stream is
    /// their own business (they fall back to the batch upload).
    case failure(RecognitionFailure)
}

/// A recogniser error as the engine acts on it: what the user is told, and whether the
/// recording can go on.
public struct RecognitionFailure: Equatable, Sendable {
    /// What the status notice, the Record Window's status line and the History row say.
    public var message: String
    /// The recogniser failed before it produced any text. Nothing follows an error — the
    /// task is over — so listening on only takes audio no one transcribes: one overlay
    /// listened for twelve seconds after a failure 44 ms in. The engine ends the
    /// recording at once instead. With text already there the recording goes on as it
    /// always has: that text is kept for the stop, and Apple's session opens a fresh task
    /// at once rather than at its next 50 s chunk rotation (`AppleErrorRotation`).
    public var endsRecording: Bool

    /// kAFAssistantErrorDomain 216: the task was cancelled — by a chunk rotation, a stop
    /// or `cancel()` — which is not a failure. Matched on the code alone, as it always was.
    static let cancelledCode = 216
    /// The on-device recogniser's own error domain.
    static let localSpeechDomain = "kLSRErrorDomain"
    /// kLSRErrorDomain 102, "Failed to access assets": the recogniser could not load its
    /// model for the language.
    static let assetsCode = 102
    /// kLSRErrorDomain 201, "Siri and Dictation are disabled": macOS Dictation is off for
    /// this account — a new account's state. `isAvailable` still answers true, so nothing
    /// tells before the task fails (measured 2026-10-22, macOS 26).
    static let dictationOffCode = 201

    /// What Apple's recogniser reported, as the user will read it — nil for a
    /// cancellation. Pure: the session reads the error, the text it holds and the Speech
    /// Recognition permission, and hands the answers in. The raw error stays in the Debug
    /// Log; the message has to fit the status notice's two lines, which the tests measure.
    public static func apple(domain: String, code: Int, description: String,
                      hasText: Bool, permissionDenied: Bool,
                      locale: String) -> RecognitionFailure? {
        guard code != cancelledCode else { return nil }
        let message: String
        if permissionDenied {
            // Read from `SFSpeechRecognizer.authorizationStatus()`, not guessed from the error.
            message = speechPermissionMessage
        } else if domain == localSpeechDomain, code == assetsCode {
            // Only what the error says — the assets could not be loaded — and where they
            // come from. "Not downloaded yet" is the usual reason, but not one it names.
            let language = languageName(locale)
            message = "Couldn't load the \(language) speech model. Add it to Dictation in System Settings › Keyboard."
        } else if domain == localSpeechDomain, code == dictationOffCode {
            message = dictationOffMessage
        } else {
            message = description
        }
        return RecognitionFailure(message: message, endsRecording: !hasText)
    }

    /// macOS Dictation is off: Apple's engine is that recogniser, so it works only with it on.
    public static let dictationOffMessage =
        "Dictation is off on this Mac. Turn it on in System Settings › Keyboard › Dictation."

    /// Also the start failure when the permission is already known to be off.
    public static let speechPermissionMessage =
        "Speech Recognition is off for SpeechText. Turn it on in System Settings › Privacy & Security."

    /// "English" for "en", "en-US" or "en_US" — named in English, as the rest of the UI
    /// is, rather than in whatever language the Mac runs in.
    static func languageName(_ locale: String) -> String {
        let code = Locale(identifier: locale).language.languageCode?.identifier ?? locale
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? locale
    }
}

/// The result of a finished segment. History bookkeeping stays in the engine, so this
/// carries everything the engine needs to write the record.
public struct RecognitionOutcome: Sendable {
    /// Trimmed. Empty when nothing was recognised or the segment failed.
    public var text: String
    /// Set when the segment failed. May coexist with non-empty text (Apple: an error after
    /// some words were recognised) — text wins, for History and the stop's paste alike, and
    /// the engine only logs the error.
    public var error: String?
    /// The segment file a batch session wrote. Ownership passes to the engine, which
    /// deletes it on success and hands it to History otherwise.
    public var audioFileURL: URL?
    /// `cancel()` or task cancellation cut the wait short: nothing is recorded and the
    /// file, if any, is deleted.
    public var cancelled: Bool
    /// The segment failed because there was no network (`NetworkFailure.isOffline`), not
    /// because a provider answered badly. The user is told it is saved to History rather
    /// than shown the provider's error, and the archived audio is retried once the
    /// network is back — into History, never pasted (`TranscriptionRecord.undelivered`).
    public var offline = false
    /// The vendor answered that the model is not served (`ModelUnavailableReply`): the
    /// failure notice offers the model picker. Nothing retries on it.
    public var modelUnavailable = false
    /// Every request the segment cost (`UsageEvent`) — on an empty or failed outcome too,
    /// since a request the vendor answered was billed whatever the answer held.
    public var usage: [UsageEvent] = []
    /// The segment's speech from its first word to its last
    /// (`VoiceActivityReading.voicedSpanSeconds`), when the detector read it; nil leaves
    /// the engine to read it itself (Apple), or Usage to count the whole segment.
    public var speakingSeconds: Double? = nil

    public init(text: String, error: String?, audioFileURL: URL?, cancelled: Bool,
                offline: Bool = false, modelUnavailable: Bool = false,
                usage: [UsageEvent] = [], speakingSeconds: Double? = nil) {
        self.text = text
        self.error = error
        self.audioFileURL = audioFileURL
        self.cancelled = cancelled
        self.offline = offline
        self.modelUnavailable = modelUnavailable
        self.usage = usage
        self.speakingSeconds = speakingSeconds
    }

    public static let cancelled = RecognitionOutcome(text: "", error: nil, audioFileURL: nil, cancelled: true)

    /// A segment too short to be speech (`STTTuning.minimumSegmentSeconds`): leaves no
    /// trace at all — no text, no error, no History row. It is `cancelled` because that
    /// is the one outcome the engine records nothing for; a dedicated flag would have to
    /// be read in `SpeechEngine.recordOutcome`, and until one is this spelling says why.
    static let discarded = RecognitionOutcome.cancelled
}

/// One segment of recognition, whatever the tier. Created by `makeRecognitionSession`
/// once per segment (a resume is a new session); the engine owns the microphone, the
/// tap and the `AudioBufferWriter`, and the session gets the writer by reference.
///
/// Three threads reach a session, and each requirement says which: the engine drives it
/// on the main actor, the tap feeds it from the audio thread, and `finish()` runs off
/// main, hopping there for whatever state it shares with the rest.
public protocol RecognitionSession: AnyObject, Sendable {
    /// Set by the engine before `start()`. Invoked on the main thread.
    @MainActor var onEvent: (@MainActor @Sendable (RecognitionEvent) -> Void)? { get set }
    /// Opens sockets / recognisers. Called before the tap is installed and before the
    /// audio engine starts, so a TLS handshake overlaps the hardware start.
    @MainActor func start() throws
    /// One tap buffer, from the audio thread. `native` is the hardware-format buffer
    /// (Apple resamples itself); `pcm16` is the writer's 16 kHz mono Int16 conversion of
    /// the same buffer, nil on the writer's native-copy fallback path or on a converter error.
    func feed(native: AVAudioPCMBuffer, pcm16: Data?)
    /// The mic stopped feeding this segment (pause, or a stop about to `finish()`).
    /// Returns the segment's text when the session can hand it over at once (Apple's
    /// live text, no history entry), or nil when it must be waited for with `finish()`.
    /// Must be idempotent and synchronous on the main thread: the engine calls it before
    /// spawning the `finish()` task so no session-internal timer can fire in between.
    @MainActor func pause() -> String?
    /// Commits what is pending and returns the segment's text once known. Bounded: Apple
    /// waits ≤ 0.5 s for `isFinal`, streaming ≤ `STTTuning.streamFinishTimeoutSeconds`
    /// then falls back, batch is bounded by the provider's URLSession timeouts.
    /// Called at most once per session.
    func finish() async -> RecognitionOutcome
    /// Drops everything immediately. Idempotent; safe after `finish()` returned.
    @MainActor func cancel()
}

public enum RecognitionSessionError: LocalizedError, Sendable {
    case recognizerUnavailable(String)
    /// Speech Recognition is denied or restricted for the app, so every task would fail.
    case speechPermissionDenied

    public var errorDescription: String? {
        switch self {
        case .recognizerUnavailable(let locale): return "Speech recognizer not available for \(locale)"
        case .speechPermissionDenied: return RecognitionFailure.speechPermissionMessage
        }
    }
}
