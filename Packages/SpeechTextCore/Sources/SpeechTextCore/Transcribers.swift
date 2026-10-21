// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Provider Type

public enum STTProviderType: String, CaseIterable, Identifiable, Sendable {
    case apple = "apple"
    case groq = "groq"
    case elevenlabs = "elevenlabs"
    case openai = "openai"
    case local = "local"

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: "Apple"
        case .groq: "Groq Whisper"
        case .elevenlabs: "ElevenLabs Scribe"
        case .openai: "OpenAI"
        case .local: "Local model"
        }
    }
}

// MARK: - Tuning

/// Every latency and quality knob the cloud STT providers use, in one place, so a value
/// measured against the live service is not re-derived by feel in two files. All of
/// these were verified by probing the ElevenLabs API on 2026-08-29.
public enum STTTuning {
    /// Seconds of silence after which Scribe Realtime's VAD commits a segment — the
    /// server's own default. Each segment is transcribed on its own and punctuated as a
    /// finished sentence, so a pause this long mid-sentence leaves a full stop and a
    /// capital in the middle of it ("що ми. Зробили"). It was 1.0 s while committed text
    /// was pasted into the app as it arrived and every tenth of a second was a wait for
    /// the paste; since nothing reaches the app before the stop, a shorter pause
    /// only cuts more sentences — at 1.0 s thinking pauses already split them.
    static let vadSilenceThresholdSeconds: Double = 1.5

    /// A Scribe Realtime segment left open longer than this is not trusted: the stop
    /// pastes the upload's answer instead of the stream's (`OpenSegmentClock`).
    /// The server closes a segment by itself after about 36 s of audio, whatever the VAD
    /// says (ElevenLabs' commit-strategy guide, which also advises committing every
    /// 20–30 s), and a segment that ran up to that bound is where the audio corpus caught
    /// the model writing text that is not in the audio: on `uk-continuous-long` the
    /// MacBook microphone's second segment ended in "Що ще?" fifteen times in five runs
    /// of six, and the headset's in an invented schedule in two. 30 s is short of that
    /// bound and past every segment a dictation with ordinary pauses produced — the
    /// clean `uk-hard-words`, one 25.7 s segment, stays on the stream — so only a
    /// dictation the server had to cut is paid for twice. 20 s, tried first, sent that
    /// clip to the upload too. Closing long segments from the client was measured and
    /// rejected: the reply to each client commit often ended in an invented sentence.
    static let streamLongestTrustedSegmentSeconds: Double = 30

    /// How long `finish()` waits for the transcript of its final commit before pasting
    /// what it has. Scribe normally answers well inside a second; this only bounds the
    /// wait when the server is slow or the reply is lost, so the paste can never hang.
    static let streamFinishTimeoutSeconds: Double = 4

    /// How long a stop made before the realtime session is ready waits for it. OpenAI's
    /// session transcribes nothing until `session.updated`, and a commit sent earlier
    /// finds an empty buffer — so `finish()` waits for it, flushes the audio held
    /// meanwhile, and only then commits. The handshake takes well under a second; past
    /// this the stream gives up and the stop uploads the file instead.
    static let streamSessionReadyTimeoutSeconds: Double = 3

    /// Size of each audio message on the socket. The tap delivers ~20 ms buffers, and a
    /// WebSocket frame per buffer is mostly overhead; 100 ms keeps the first partial
    /// arriving quickly without flooding the connection.
    static let streamChunkSeconds: Double = 0.1

    /// Silence appended to the last chunk sent with `commit: true`. The server ignores
    /// a commit with under 0.3 s of uncommitted audio (`commit_throttled`), so 0.4 s
    /// guarantees the commit is honoured and adds nothing to the transcript.
    static let streamCommitPaddingSeconds: Double = 0.4

    /// Upper bound on audio held client-side while the socket is still handshaking
    /// (`session_started` not yet seen). Ten seconds is far more than a TLS handshake
    /// takes; if it fills, the stream gives up (`.failed`) rather than dropping the
    /// oldest audio and later reporting a transcript with the opening seconds missing
    /// as a success — the batch fallback has the full recording on disk.
    static let streamPreSessionBufferSeconds: Double = 10

    /// How long `finish()` keeps listening after a `committed_transcript` arrives before
    /// treating it as the reply to its own commit. The server answers in order, so if
    /// the VAD had just closed an earlier segment when the user stopped, that segment's
    /// transcript lands first and the final one — preceded by its `partial_transcript`s —
    /// is still on its way; closing on the first would drop the last phrase without any
    /// failure to trigger the batch fallback. A partial arriving inside this window
    /// is held, and the wait moves to `streamCommitAfterPartialSeconds`. Measured replies for a padded commit are well under this.
    static let streamCommitGraceSeconds: Double = 0.2

    /// How long `finish()` goes on waiting once a partial follows that commit reply
    /// (`StreamFinishSettle`). A commit of ours queued behind an earlier segment's lands
    /// about as quickly as the first reply did (0.2–0.3 s after the stop in the 1.10
    /// traces); with none by then, the held partial is unresolved and the segment is
    /// uploaded. Armed once, by the first held partial: an echo that keeps growing used
    /// to hold the paste for the whole `streamFinishTimeoutSeconds`.
    static let streamCommitAfterPartialSeconds: Double = 1.0

    /// A segment whose loudest sample never reached this fraction of full scale
    /// (about −44 dBFS) is not uploaded. Whisper does not answer silence with nothing:
    /// it answers with "Thank you for watching" or "Дякую за перегляд", and that would
    /// be pasted. Peak rather than RMS, and deliberately low: one spoken syllable clears
    /// it by 20 dB even on a quiet microphone, so what it catches is a muted or dead
    /// input and a shortcut pressed with nothing said. Room noise above it still goes to
    /// the model. Chosen from the levels in the Debug Log, not from a measured corpus.
    public static let silencePeakFloor: Float = 0.006

    /// A segment shorter than this is dropped without an upload, a History row or an
    /// error: it is a shortcut pressed and let go at once, or a pause the instant after a
    /// resume, not a word. 0.3 s is also about where a file becomes worth sending — one
    /// FLAC block (`AudioBufferWriter.flacBlockFrames`, 0.29 s) — and the measured 0.2 s
    /// segment that prompted this was answered with "Audio file might be corrupted" by
    /// OpenAI and could never be retried from History.
    public static let minimumSegmentSeconds: Double = 0.3

    /// A segment no longer than this whose whole result is a known hallucination
    /// (`HallucinationFilter`) is kept as an empty result, its audio archived. Long
    /// enough for a shortcut pressed with a breath or a cough behind it; short enough
    /// that a real dictation of one of those phrases on its own is unlikely. A starting
    /// value, not a measurement: the audio corpus is what tunes it.
    static let hallucinationSegmentSeconds: Double = 2.0

    /// A window of Silero VAD (256 ms) whose speech probability is above this holds a
    /// voice (`VoiceActivity`). Measured on the audio corpus: the loudest keyboard and
    /// room noise reached 0.78 (the MacBook's own microphone), every recording of speech
    /// reached 1.00 in at least four windows; a cough reached 1.00 too, which is why
    /// `HallucinationFilter` still judges what comes back.
    public static let voiceProbabilityThreshold: Float = 0.85

    /// How many windows over `voiceProbabilityThreshold` a segment needs to be sent.
    /// Measured on the corpus's tap path: a single word, «Так.», filled exactly two
    /// windows, every longer recording of speech at least four — and room noise on a
    /// MacBook's microphone raised one isolated window to 0.95 in fifteen seconds. So a
    /// long segment needs two, which that spike never reaches, and a short one needs one,
    /// because a one-word dictation is short and losing it is worse than letting a
    /// moment of noise reach the engine, where `HallucinationFilter` still judges it.
    public static let voiceWindowsRequired = 2
    public static let voiceWindowsRequiredWhenShort = 1
    /// At most this long, a segment is short for `voiceWindowsRequiredWhenShort`: a
    /// one-word dictation with the press and release around it (the corpus's «Так.» is
    /// 2.0 s); the noise clips are 10–15 s.
    public static let voiceShortSegmentSeconds = 2.5

    /// Batch upload timeouts. `URLSession.shared` ignores `URLRequest.timeoutInterval`
    /// and enforces its own 60 s default, which a multi-minute FLAC can exceed. 120 s
    /// per request covers a stalled response; 300 s for the whole resource covers a
    /// slow upload of a long recording.
    static let batchRequestTimeoutSeconds: TimeInterval = 120
    public static let batchResourceTimeoutSeconds: TimeInterval = 300

    /// Quality flags for Scribe. `tag_audio_events` defaults to *true* on the API, which
    /// would put "(laughs)" and "(door closes)" into pasted text, so it is sent off
    /// explicitly. `no_verbatim` drops fillers and false starts server-side — the point
    /// of dictation is the words the user meant, not the ones they stumbled over. The
    /// docs say it is only honoured by scribe_v2; scribe_v1 accepts and ignores it.
    static let tagAudioEvents = false
    static let noVerbatim = true
}

// MARK: - Batch STT Protocol

public protocol BatchTranscriber: Sendable {
    func transcribe(audioFileURL: URL, language: String?) async throws -> String
    /// The text and what the vendor said it billed. Declared here, not only in the
    /// extension, so a transcriber's own version is the one called through
    /// `any BatchTranscriber` — an extension-only method would always run the default
    /// and the History ledger would never see a vendor's numbers.
    func transcribeMetered(audioFileURL: URL, language: String?) async throws -> Transcription
    /// The vendor and model a request goes to, for the History ledger (`UsageEvent`).
    /// Nil for a transcriber whose requests nobody bills — the local engines.
    var meter: UsageMeter? { get }
}

extension BatchTranscriber {
    public func transcribeMetered(audioFileURL: URL, language: String?) async throws -> Transcription {
        Transcription(text: try await transcribe(audioFileURL: audioFileURL, language: language))
    }

    public var meter: UsageMeter? { nil }
}

/// An upload's text, and what the vendor said it billed for it.
public struct Transcription: Equatable, Sendable {
    public let text: String
    public var billing: SpeechBilling? = nil
}

/// What one speech request was billed for, in the vendor's own words. Only what the
/// reply said: a vendor that reports nothing leaves both nil, and `UsageMeter` supplies a
/// documented rule where one exists.
public struct SpeechBilling: Equatable, Sendable {
    /// OpenAI's `usage` of `type: "duration"`, ElevenLabs' `audio_duration_secs`.
    var seconds: Double? = nil
    /// OpenAI's `usage` of `type: "tokens"`: `inputTokens` counts the audio tokens.
    var tokens: ChatUsage? = nil

    /// Reads the shapes the upload endpoints answer with. Never throws: a transcript must
    /// not be lost to a vendor changing a field the app only meters.
    static func decode(_ data: Data) -> SpeechBilling? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let seconds = (json["audio_duration_secs"] as? NSNumber)?.doubleValue {
            return SpeechBilling(seconds: seconds)
        }
        guard let usage = json["usage"] as? [String: Any] else { return nil }
        if let seconds = (usage["seconds"] as? NSNumber)?.doubleValue {
            return SpeechBilling(seconds: seconds)
        }
        if let input = (usage["input_tokens"] as? NSNumber)?.intValue,
           let output = (usage["output_tokens"] as? NSNumber)?.intValue {
            return SpeechBilling(tokens: ChatUsage(inputTokens: input, outputTokens: output))
        }
        return nil
    }
}

/// Who a speech request is billed by: the vendor actually called (an Apple session's
/// uploads go to Groq), the model, and the billing rule the vendor documents where its
/// reply says nothing — Groq's ten-second minimum per request.
public struct UsageMeter: Equatable, Sendable {
    let vendor: Provider
    let model: String
    /// Data on the vendor's `OpenAICompatibleUpload`, never a check on its name.
    var minimumBilledSeconds: Double? = nil
    /// Terms sent with the request: ElevenLabs bills a surcharge for them.
    var keyterms = 0

    /// One request's ledger entry. `audioSeconds` is what was sent; billed seconds are
    /// the vendor's figure, else its documented minimum, else unknown — never a guess.
    /// `succeeded`: the vendor answered, whatever the answer held — a reply dropped as a
    /// hallucination was still billed.
    public func event(_ kind: UsageEvent.Kind, audioSeconds: Double, billing: SpeechBilling?, succeeded: Bool,
               latency: Double?, date: Date = Date()) -> UsageEvent {
        // A request the vendor refused is taken as unbilled: no vendor here documents
        // charging for an error reply.
        let billed = succeeded ? billing?.seconds ?? minimumBilledSeconds.map { max($0, audioSeconds) } : nil
        return UsageEvent(date: date, kind: kind, vendor: vendor, model: model, succeeded: succeeded,
                          audioSeconds: audioSeconds, billedSeconds: billed,
                          tokens: billing?.tokens, keyterms: keyterms > 0 ? keyterms : nil, latency: latency)
    }
}

/// The multipart filename and MIME type for an upload, read off the file's extension.
/// `AudioBufferWriter` decides the container (FLAC normally, WAV as its fallback) and
/// History keeps whatever it was handed, so the providers must not assume either: a
/// `.wav` archived before FLAC uploads existed has to retry as a WAV. The filename
/// matters too — Groq sniffs the extension when the MIME type is ambiguous.
func multipartAudioPart(for fileURL: URL) -> (filename: String, mimeType: String) {
    let ext = fileURL.pathExtension.lowercased()
    switch ext {
    case "flac": return ("recording.flac", "audio/flac")
    case "wav", "": return ("recording.wav", "audio/wav")
    default: return ("recording.\(ext)", "audio/\(ext)")
    }
}

/// Builds a batch provider for a session's configuration. Shared by the live
/// recording path, the streaming fallback and History retries, so all three honour
/// the same snapshot. The realtime→scribe_v2 and Apple→Groq mappings live on
/// `RecordingConfiguration.batchModel`. The local tier goes through `LocalSTT` so this
/// file never names WhisperKit (it is compiled into the standalone test bundle).
public func makeBatchTranscriber(configuration: RecordingConfiguration) -> BatchTranscriber {
    switch configuration.provider {
    case .elevenlabs:
        ElevenLabsTranscriber(apiKey: configuration.apiKey(for: .elevenLabs), model: configuration.batchModel,
                              keyterms: configuration.batchVocabulary)
    case .groq, .openai, .apple:
        // Apple's uploads go to Groq (`batchProvider`).
        OpenAICompatibleTranscriber(provider: configuration.batchProvider.vendor,
                                    apiKey: configuration.apiKey(for: configuration.batchProvider.vendor),
                                    model: configuration.batchModel,
                                    prompt: configuration.whisperPrompt, keywords: configuration.batchVocabulary)
    case .local:
        LocalSTT.transcriberFactory(configuration.modelID(for: .local))
    }
}

// MARK: - OpenAI-compatible uploads (Groq, OpenAI)

/// How a provider serves OpenAI's transcription upload: `POST` a multipart form with
/// `file`, `model` and `language`, authorised with a Bearer key. Groq's endpoint is
/// literally `api.groq.com/openai/v1/...`; what differs between the two is data, held in
/// each provider's `ProviderDescriptor.speechUpload`.
struct OpenAICompatibleUpload {
    /// How the user's vocabulary goes out.
    enum VocabularyField {
        /// Whisper's free-text `prompt` (`RecordingConfiguration.whisperPrompt`).
        case prompt
        /// A `keywords[]` field per term, as OpenAI's guide writes it.
        case keywords
    }

    let url: URL
    /// Fields sent right after `model`, the same on every request.
    var fixedFields: [(name: String, value: String)] = []
    let vocabulary: VocabularyField
    /// Log the language the reply says it detected (OpenAI's `languages`).
    var logsDetectedLanguage = false
    /// The least a request is billed for, whatever its length — Groq's ten seconds.
    var minimumBilledSeconds: Double? = nil
}

/// The upload transcriber for every provider with an `OpenAICompatibleUpload`. The error
/// text names the provider, so a rejected OpenAI key never reads as Groq's.
struct OpenAICompatibleTranscriber: BatchTranscriber {
    let provider: Provider
    let upload: OpenAICompatibleUpload
    let apiKey: String
    let model: String
    /// Whisper's prompt — sent only where the upload takes a prompt. Nil sends none.
    let prompt: String?
    /// The user's vocabulary, already fitted to this model (`RecordingConfiguration
    /// .batchVocabulary`) — sent only where the upload takes keywords. Empty sends none.
    let keywords: [String]

    /// Custom URLSession — see `STTTuning.batchRequestTimeoutSeconds` for why.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = STTTuning.batchRequestTimeoutSeconds
        config.timeoutIntervalForResource = STTTuning.batchResourceTimeoutSeconds
        return URLSession(configuration: config)
    }()

    /// `provider` must have a `speechUpload`; `ProviderDescriptorTests` checks every
    /// engine that `makeBatchTranscriber` sends here has one.
    init(provider: Provider, apiKey: String, model: String? = nil, prompt: String? = nil, keywords: [String] = []) {
        guard let upload = provider.descriptor.speechUpload else {
            preconditionFailure("\(provider) has no OpenAI-compatible upload")
        }
        self.provider = provider
        self.upload = upload
        self.apiKey = apiKey
        self.model = model ?? provider.defaultSpeechModel
        self.prompt = prompt
        self.keywords = keywords
    }

    var meter: UsageMeter? {
        UsageMeter(vendor: provider, model: model, minimumBilledSeconds: upload.minimumBilledSeconds,
                   keyterms: upload.vocabulary == .keywords ? keywords.count : 0)
    }

    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        try await transcribeMetered(audioFileURL: audioFileURL, language: language).text
    }

    func transcribeMetered(audioFileURL: URL, language: String?) async throws -> Transcription {
        let log = provider.displayName
        let boundary = UUID().uuidString

        var request = URLRequest(url: upload.url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioFileURL)
        let part = multipartAudioPart(for: audioFileURL)
        // The count only: terms are often people's names, and the log is public.
        let keywordNote = upload.vocabulary == .keywords ? ", keywords=\(keywords.count)" : ""
        dlog(log, "transcribe: audioSize=\(audioData.count) bytes (\(part.mimeType)), model=\(model), language=\(language ?? "nil")\(keywordNote)")

        request.httpBody = Self.multipartBody(boundary: boundary, audio: audioData, part: part, upload: upload,
                                              model: model, language: language, prompt: prompt, keywords: keywords)

        let startTime = CFAbsoluteTimeGetCurrent()
        dlog(log, "transcribe: sending request…", level: .debug)
        let (data, response) = try await Self.session.data(for: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        dlog(log, "transcribe: response received in \(String(format: "%.2f", elapsed))s, size=\(data.count) bytes")
        RateLimitStore.shared.record(vendor: provider, model: model, response: response)

        let provider = provider
        try validatedHTTPResponse(response, data: data, log: log, label: "transcribe",
                                  bodyLimit: 200,
                                  nonHTTPMessage: "transcribe: invalid response (not HTTP)",
                                  invalidResponse: TranscriptionError.invalidResponse(provider),
                                  httpError: { TranscriptionError.httpError(provider, $0, $1) })

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        if upload.logsDetectedLanguage {
            // The detected language is logged, never decoded into a typed field: the batch
            // reply spells it `[{"code":"uk"}]` and the realtime session `["uk"]`, and a
            // transcript must not be lost to a vendor changing the shape of a field the app
            // only prints. It is worth printing — this project shipped a data-loss bug from
            // forcing the keyboard layout's language on a cloud model, and on Auto this line
            // is the record of what the model decided instead.
            dlog(log, "transcribe: success, text=\(decoded.text.count) chars, detected=\(Self.detectedLanguages(in: data) ?? "?")")
        } else {
            dlog(log, "transcribe: success, text=\(decoded.text.count) chars")
        }
        return Transcription(text: decoded.text, billing: SpeechBilling.decode(data))
    }

    /// The `languages` field as a log line, whatever shape it arrived in.
    private static func detectedLanguages(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["languages"] else { return nil }
        if let codes = raw as? [String] { return codes.joined(separator: ",") }
        if let objects = raw as? [[String: Any]] {
            return objects.compactMap { $0["code"] as? String }.joined(separator: ",")
        }
        return String(describing: raw)
    }
}

extension OpenAICompatibleTranscriber {
    /// The upload's form, apart so its fields can be tested without a request.
    static func multipartBody(boundary: String, audio: Data, part: (filename: String, mimeType: String),
                              upload: OpenAICompatibleUpload, model: String, language: String?,
                              prompt: String?, keywords: [String]) -> Data {
        var body = Data()

        body.appendMultipartFile(boundary: boundary, name: "file",
                                 filename: part.filename, mimeType: part.mimeType,
                                 data: audio)
        body.appendMultipartField(boundary: boundary, name: "model", value: model)
        for field in upload.fixedFields {
            body.appendMultipartField(boundary: boundary, name: field.name, value: field.value)
        }

        if let language {
            // `language` (singular) is what Whisper documents; OpenAI's gpt-transcribe
            // documents `languages` but accepts this one too and normalises it — verified
            // against the live endpoint, which answered `"languages":[{"code":"uk"}]` to it.
            let iso639 = String(language.prefix(2))
            body.appendMultipartField(boundary: boundary, name: "language", value: iso639)
        }

        switch upload.vocabulary {
        case .prompt:
            if let prompt {
                body.appendMultipartField(boundary: boundary, name: "prompt", value: prompt)
            }
        case .keywords:
            for term in keywords {
                body.appendMultipartField(boundary: boundary, name: "keywords[]", value: term)
            }
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

/// The text every upload endpoint here answers with.
private struct TranscriptionResponse: Decodable {
    let text: String
}

/// A transcription that failed, in any provider's words: an upload's reply the app could
/// not use, an HTTP error (`providerErrorMessage`), or a realtime socket's error event.
public enum TranscriptionError: LocalizedError, Sendable {
    case invalidResponse(Provider)
    case httpError(Provider, Int, String)
    /// The realtime socket reported an error, or sent something unusable. The code is
    /// what `StreamReconnectPolicy` reads (`no_session` is a drop worth reopening).
    case realtime(Provider, String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let provider): "Invalid response from \(provider.displayName) API"
        case .httpError(let provider, let code, let body):
            providerErrorMessage(vendor: provider.displayName, status: code, body: body)
        case .realtime(let provider, let code, let detail): "\(provider.displayName) realtime \(code): \(detail)"
        }
    }
}

// MARK: - ElevenLabs Implementation

struct ElevenLabsTranscriber: BatchTranscriber {
    let apiKey: String
    let model: String
    /// The user's vocabulary, already fitted to this model (`RecordingConfiguration
    /// .batchVocabulary`). Empty sends no field at all.
    let keyterms: [String]

    /// Custom URLSession — see `STTTuning.batchRequestTimeoutSeconds` for why.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = STTTuning.batchRequestTimeoutSeconds
        config.timeoutIntervalForResource = STTTuning.batchResourceTimeoutSeconds
        return URLSession(configuration: config)
    }()

    init(apiKey: String, model: String = Provider.elevenLabs.defaultSpeechModel, keyterms: [String] = []) {
        self.apiKey = apiKey
        self.model = model
        self.keyterms = keyterms
    }

    var meter: UsageMeter? { UsageMeter(vendor: .elevenLabs, model: model, keyterms: keyterms.count) }

    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        try await transcribeMetered(audioFileURL: audioFileURL, language: language).text
    }

    func transcribeMetered(audioFileURL: URL, language: String?) async throws -> Transcription {
        let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioFileURL)
        let part = multipartAudioPart(for: audioFileURL)
        // The count only: terms are often people's names, and the log is public.
        dlog("ElevenLabs", "transcribe: audioSize=\(audioData.count) bytes (\(part.mimeType)), model=\(model), language=\(language ?? "nil"), keyterms=\(keyterms.count)")

        request.httpBody = Self.multipartBody(boundary: boundary, audio: audioData, part: part,
                                              model: model, language: language, keyterms: keyterms)

        let startTime = CFAbsoluteTimeGetCurrent()
        dlog("ElevenLabs", "transcribe: sending request…")
        let (data, response) = try await Self.session.data(for: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        dlog("ElevenLabs", "transcribe: response received in \(String(format: "%.2f", elapsed))s, size=\(data.count) bytes")

        try validatedHTTPResponse(response, data: data, log: "ElevenLabs", label: "transcribe",
                                  bodyLimit: 200,
                                  nonHTTPMessage: "transcribe: invalid response (not HTTP)",
                                  invalidResponse: TranscriptionError.invalidResponse(.elevenLabs),
                                  httpError: { TranscriptionError.httpError(.elevenLabs, $0, $1) })

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let billing = SpeechBilling.decode(data)
        dlog("ElevenLabs", "transcribe: success, text=\(decoded.text.count) chars, billed=\(billing?.seconds.map { String(format: "%.1fs", $0) } ?? "?")")
        return Transcription(text: decoded.text, billing: billing)
    }
}

extension ElevenLabsTranscriber {
    /// The upload's form, apart so its fields can be tested without a request.
    static func multipartBody(boundary: String, audio: Data, part: (filename: String, mimeType: String),
                              model: String, language: String?, keyterms: [String]) -> Data {
        var body = Data()

        body.appendMultipartFile(boundary: boundary, name: "file",
                                 filename: part.filename, mimeType: part.mimeType,
                                 data: audio)
        body.appendMultipartField(boundary: boundary, name: "model_id", value: model)
        // Quality flags — see `STTTuning`. Both are accepted by every batch model ID
        // (verified against scribe_v1 and scribe_v2).
        body.appendMultipartField(boundary: boundary, name: "tag_audio_events",
                                  value: STTTuning.tagAudioEvents ? "true" : "false")
        body.appendMultipartField(boundary: boundary, name: "no_verbatim",
                                  value: STTTuning.noVerbatim ? "true" : "false")

        if let language {
            let iso639 = String(language.prefix(2))
            body.appendMultipartField(boundary: boundary, name: "language_code", value: iso639)
        }

        // A list field is the same name repeated, which is how the vendor's own SDK
        // sends it. Billed as a surcharge per hour (`SpeechRates.keytermSurchargePerMinute`), so nothing unless there are terms.
        for term in keyterms {
            body.appendMultipartField(boundary: boundary, name: "keyterms", value: term)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

// MARK: - Error text

/// A provider's error reply as a sentence the user can read. The reply body is JSON
/// written for developers (`{"error":{"message":…,"type":…,"param":…}}`), and it used to
/// be shown whole, braces and all; the Debug Log still has it verbatim. What is kept is
/// the provider's own message — the one part that says what went wrong — and the status,
/// so a History row stays traceable.
///
/// The shapes read are the three vendors': OpenAI and Groq nest it under
/// `error.message`, ElevenLabs under `detail.message` (or `detail` as a plain string,
/// or a list of validation failures).
/// A body with none of them falls back to what the status means.
func providerErrorMessage(vendor: String, status: Int, body: String) -> String {
    let reason = providerErrorReason(in: body) ?? genericReason(forStatus: status)
    let sentence = reason.last.map { ".!?".contains($0) } == true ? reason : reason + "."
    return "\(vendor) couldn't transcribe the recording: \(sentence) (HTTP \(status))"
}

/// The provider's own message in an error reply, or nil when the body has none.
func providerErrorReason(in body: String) -> String? {
    guard let data = body.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let candidates: [Any?] = [
        (json["error"] as? [String: Any])?["message"],
        json["error"],
        (json["detail"] as? [String: Any])?["message"],
        json["detail"],
        // A validation failure: `{"detail":[{"loc":…,"msg":…}]}`.
        (json["detail"] as? [[String: Any]])?.first?["msg"],
        json["message"],
    ]
    for case let text as String in candidates.compactMap({ $0 }) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { return line }
    }
    return nil
}

private func genericReason(forStatus status: Int) -> String {
    switch status {
    case 401, 403: "the API key was rejected"
    case 413: "the recording is too large"
    case 429: "too many requests — try again in a moment"
    case 500...: "the service is having problems"
    default: "the request was refused"
    }
}

// MARK: - HTTP Response Validation

/// The check every provider in this app runs on a JSON POST's reply: it must be an HTTP
/// response, and its status must be 2xx; anything else is logged with the body and turned
/// into that provider's own error.
///
/// One place rather than five near-identical copies. Each caller keeps its own log
/// category, message label and error type — only the shape is shared. Foundation only,
/// so the standalone test bundle still builds.
///
/// - Parameters:
///   - label: prefix for the log line, e.g. `"transcribe"` or the LLM's own label.
///   - bodyLimit: how much of the error body is logged.
///   - nonHTTPMessage: logged when the reply is not an HTTP response at all; nil logs nothing.
@discardableResult
func validatedHTTPResponse(_ response: URLResponse,
                           data: Data,
                           log category: String,
                           label: String,
                           bodyLimit: Int = 300,
                           nonHTTPMessage: String? = nil,
                           invalidResponse: Error,
                           httpError: (Int, String) -> Error) throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
        if let nonHTTPMessage { dlog(category, nonHTTPMessage, level: .error) }
        throw invalidResponse
    }
    guard (200 ... 299).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? "Unknown error"
        // log-privacy: ok — the vendor's error reply, which says what was wrong with the request
        dlog(category, "\(label): HTTP \(http.statusCode): \(body.prefix(bodyLimit))", level: .error)
        throw httpError(http.statusCode, body)
    }
    return http
}

// MARK: - Multipart Helpers

extension Data {
    mutating func appendMultipartField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(boundary: String, name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}
