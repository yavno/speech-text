// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import AVFoundation
@testable import SpeechTextCore

// MARK: - Multipart helpers (Transcribers.swift)

final class MultipartTests: XCTestCase {

    func testAppendMultipartFieldLayout() {
        var body = Data()
        body.appendMultipartField(boundary: "BOUND", name: "model", value: "whisper-large-v3-turbo")
        let expected = "--BOUND\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n"
        XCTAssertEqual(String(data: body, encoding: .utf8), expected)
    }

    func testAppendMultipartFileLayout() {
        let payload = Data([0x01, 0x02, 0x03])
        var body = Data()
        body.appendMultipartFile(boundary: "BOUND", name: "file",
                                 filename: "recording.flac", mimeType: "audio/flac",
                                 data: payload)
        var expected = "--BOUND\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.flac\"\r\nContent-Type: audio/flac\r\n\r\n".data(using: .utf8)!
        expected.append(payload)
        expected.append("\r\n".data(using: .utf8)!)
        XCTAssertEqual(body, expected)
    }

    func testMultipartAudioPartPicksTypeFromExtension() {
        let flac = multipartAudioPart(for: URL(fileURLWithPath: "/tmp/x.flac"))
        XCTAssertEqual(flac.filename, "recording.flac")
        XCTAssertEqual(flac.mimeType, "audio/flac")

        let wav = multipartAudioPart(for: URL(fileURLWithPath: "/tmp/x.wav"))
        XCTAssertEqual(wav.filename, "recording.wav")
        XCTAssertEqual(wav.mimeType, "audio/wav")

        // No extension degrades to WAV — the historical container.
        let bare = multipartAudioPart(for: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertEqual(bare.mimeType, "audio/wav")
    }
}

// MARK: - The OpenAI tier

final class OpenAISTTTests: XCTestCase {

    /// Constructed directly — never via `current()`, which reads the real defaults.
    private func config(provider: STTProviderType = .openai,
                        openAIModel: String = "gpt-transcribe",
                        openAIKey: String = "ok") -> RecordingConfiguration {
        RecordingConfiguration(provider: provider, locale: "uk-UA", localeIsAutomatic: true, apiKeys: [.groq: "gk", .elevenLabs: "ek", .openAI: openAIKey], models: [.groq: "whisper-large-v3-turbo", .elevenLabs: "scribe_v2", .openAI: openAIModel])
    }

    func testStreamsOnlyForTheRealtimeModel() {
        XCTAssertTrue(config(openAIModel: openAIRealtimeSTTModel).streams)
        XCTAssertFalse(config(openAIModel: "gpt-transcribe").streams)
        // The model string alone must not be enough: the provider has to match too.
        XCTAssertFalse(config(provider: .groq, openAIModel: openAIRealtimeSTTModel).streams)
    }

    /// The realtime model exists only behind the WebSocket — the upload endpoint rejects
    /// it — so the stream's fallback and History retries go to the batch model.
    func testBatchModelMapsRealtimeToTheUploadModel() {
        XCTAssertEqual(config(openAIModel: openAIRealtimeSTTModel).batchModel, "gpt-transcribe")
        XCTAssertEqual(config(openAIModel: "gpt-4o-mini-transcribe").batchModel, "gpt-4o-mini-transcribe")
    }

    func testRetryReadinessNamesTheOpenAIKey() {
        XCTAssertNil(config().batchUnavailableReason(modelInstalled: { _ in false }))
        let reason = config(openAIKey: "").batchUnavailableReason()
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("OpenAI"))
    }

    /// Auto still means "the model decides" here, as it does for every cloud tier.
    func testAutoLanguageIsNotForcedOnTheModel() {
        XCTAssertNil(config().cloudLanguage)
        XCTAssertEqual(config().historyLocale, autoLanguageID)
    }

    /// `whisper-1` answered two seconds of near-silence with "MBC 뉴스 이덕영입니다."
    /// (2026-09-21), which the app would have pasted into the user's document, and
    /// `gpt-4o-transcribe-diarize` answers in a shape this app does not decode. Neither
    /// may be offered, however the catalogue is later rearranged.
    func testCatalogueLeavesOutTheModelsThatCannotBeTrusted() {
        let ids = offeredSTTModels(of: .openAI).map(\.id)
        XCTAssertFalse(ids.contains("whisper-1"))
        XCTAssertFalse(ids.contains("gpt-4o-transcribe-diarize"))
        XCTAssertTrue(ids.contains("gpt-transcribe"))
        XCTAssertTrue(ids.contains(openAIRealtimeSTTModel))
    }

    // MARK: The realtime session's configuration

    private func sessionUpdate(languages: [String]) throws -> [String: Any] {
        let raw = try XCTUnwrap(OpenAIRealtimeTranscriber.encodeSessionUpdate(
            model: openAIRealtimeSTTModel, languages: languages, sampleRate: 24_000))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let session = try XCTUnwrap(json["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "session.update")
        return try XCTUnwrap(audio["input"] as? [String: Any])
    }

    /// Everything in this message is load-bearing: a session left unconfigured has
    /// `transcription: null` and silently transcribes nothing, the rate is refused
    /// unless it is exactly 24 kHz, and `turn_detection` — which a fresh session
    /// defaults to — is rejected outright by this model.
    func testSessionUpdateConfiguresTheTranscription() throws {
        let input = try sessionUpdate(languages: [])

        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)

        XCTAssertTrue(input["turn_detection"] is NSNull)

        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, openAIRealtimeSTTModel)
        // Auto: the model is told nothing and detects the language itself.
        XCTAssertNil(transcription["language"])
    }

    func testSessionUpdateSendsOneLanguageInTheSingularForm() throws {
        let transcription = try XCTUnwrap(try sessionUpdate(languages: ["uk"])["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["language"] as? String, "uk")
        XCTAssertNil(transcription["languages"])
    }

    /// `gpt-live-transcribe` is the one endpoint in this app that takes a candidate set
    /// (`languages: ["en", "fr"]`), so it is the one place the user's whole list is worth
    /// more than its first entry — everywhere else two languages mean "detect it".
    func testSessionUpdateSendsSeveralLanguagesAsACandidateSet() throws {
        let transcription = try XCTUnwrap(try sessionUpdate(languages: ["uk", "en"])["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["languages"] as? [String], ["uk", "en"])
        // Not both: the plural field replaces the singular one for this model.
        XCTAssertNil(transcription["language"])
    }

    /// The tier the factory picks, and the rate it asks the engine to convert to. 16 kHz
    /// — what the upload file is made of — is refused by the service as below minimum.
    func testTheFactoryBuildsARealtimeTranscriberAtTwentyFourKilohertz() {
        let streaming = makeStreamingTranscriber(configuration: config(openAIModel: openAIRealtimeSTTModel))
        XCTAssertTrue(streaming is OpenAIRealtimeTranscriber)
        XCTAssertEqual(streaming?.sampleRate, 24_000)
        XCTAssertNil(makeStreamingTranscriber(configuration: config(openAIModel: "gpt-transcribe")))
    }
}

// MARK: - The assumption the streaming resampler rests on

final class AVAudioFormatEqualityTests: XCTestCase {

    /// `StreamingRecognitionSession` rebuilds its converter when the tap's format
    /// changes, and decides that with `!=`. The tap hands out a *new* `AVAudioFormat`
    /// instance for every buffer, so this only works because `NSObject`'s `==` is
    /// `isEqual:` — an identity comparison would rebuild the converter per buffer,
    /// discarding the resampler's delay line fifty times a second.
    func testEqualFormatsCompareEqualEvenAsDistinctInstances() throws {
        let a = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                            channels: 1, interleaved: false))
        let b = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                            channels: 1, interleaved: false))
        XCTAssertFalse(a === b)
        let held: AVAudioFormat? = a
        XCTAssertFalse(held != b)
    }

    func testADifferentRateIsSeenAsAChange() throws {
        let held: AVAudioFormat? = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                 channels: 1, interleaved: false)
        let changed = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                                  channels: 1, interleaved: false))
        XCTAssertTrue(held != changed)
        let none: AVAudioFormat? = nil
        XCTAssertTrue(none != changed)
    }
}

// MARK: - Upload bodies and transcription errors (Transcribers.swift)

/// Every upload's whole form, written out, and every transcription error's words: what
/// each vendor is sent and what the user reads, pinned before the transcribers share code.
final class UploadBodyTests: XCTestCase {

    private let audio = Data("AUDIO".utf8)
    private let part = (filename: "recording.flac", mimeType: "audio/flac")
    private let groq = Provider.groq.descriptor.speechUpload!
    private let openAI = Provider.openAI.descriptor.speechUpload!

    private func file() -> String {
        "--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.flac\"\r\nContent-Type: audio/flac\r\n\r\nAUDIO\r\n"
    }

    private func field(_ name: String, _ value: String) -> String {
        "--B\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }

    private let end = "--B--\r\n"

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func testGroqsForm() {
        XCTAssertEqual(text(OpenAICompatibleTranscriber.multipartBody(boundary: "B", audio: audio, part: part, upload: groq,
                                                          model: "whisper-large-v3-turbo", language: "uk-UA",
                                                          prompt: "SpeechText, C++", keywords: ["unsent"])),
                       file() + field("model", "whisper-large-v3-turbo") + field("response_format", "json")
                           + field("language", "uk") + field("prompt", "SpeechText, C++") + end)
        XCTAssertEqual(text(OpenAICompatibleTranscriber.multipartBody(boundary: "B", audio: audio, part: part, upload: groq,
                                                          model: "whisper-large-v3", language: nil,
                                                          prompt: nil, keywords: ["unsent"])),
                       file() + field("model", "whisper-large-v3") + field("response_format", "json") + end)
    }

    func testOpenAIsForm() {
        XCTAssertEqual(text(OpenAICompatibleTranscriber.multipartBody(boundary: "B", audio: audio, part: part, upload: openAI,
                                                            model: "gpt-transcribe", language: "uk-UA",
                                                            prompt: "unsent", keywords: ["SpeechText", "R&D"])),
                       file() + field("model", "gpt-transcribe") + field("language", "uk")
                           + field("keywords[]", "SpeechText") + field("keywords[]", "R&D") + end)
        XCTAssertEqual(text(OpenAICompatibleTranscriber.multipartBody(boundary: "B", audio: audio, part: part, upload: openAI,
                                                            model: "gpt-4o-mini-transcribe", language: nil,
                                                            prompt: "unsent", keywords: [])),
                       file() + field("model", "gpt-4o-mini-transcribe") + end)
    }

    func testElevenLabsForm() {
        XCTAssertEqual(text(ElevenLabsTranscriber.multipartBody(boundary: "B", audio: audio, part: part,
                                                                model: "scribe_v2", language: "uk-UA",
                                                                keyterms: ["SpeechText", "C++"])),
                       file() + field("model_id", "scribe_v2") + field("tag_audio_events", "false")
                           + field("no_verbatim", "true") + field("language_code", "uk")
                           + field("keyterms", "SpeechText") + field("keyterms", "C++") + end)
    }

    func testTheErrorsSayWhatTheySaid() {
        XCTAssertEqual(TranscriptionError.invalidResponse(.groq).errorDescription, "Invalid response from Groq API")
        XCTAssertEqual(TranscriptionError.invalidResponse(.elevenLabs).errorDescription, "Invalid response from ElevenLabs API")
        XCTAssertEqual(TranscriptionError.invalidResponse(.openAI).errorDescription, "Invalid response from OpenAI API")
        XCTAssertEqual(TranscriptionError.httpError(.groq, 401, "").errorDescription,
                       "Groq couldn't transcribe the recording: the API key was rejected. (HTTP 401)")
        XCTAssertEqual(TranscriptionError.httpError(.elevenLabs, 429, "").errorDescription,
                       "ElevenLabs couldn't transcribe the recording: too many requests — try again in a moment. (HTTP 429)")
        XCTAssertEqual(TranscriptionError.httpError(.openAI, 500, "").errorDescription,
                       "OpenAI couldn't transcribe the recording: the service is having problems. (HTTP 500)")
        XCTAssertEqual(TranscriptionError.realtime(.elevenLabs, "no_session", "x").errorDescription, "ElevenLabs realtime no_session: x")
        XCTAssertEqual(TranscriptionError.realtime(.openAI, "transcription_failed", "y").errorDescription,
                       "OpenAI realtime transcription_failed: y")
    }
}

final class ProviderDescriptorTests: XCTestCase {

    /// Each engine's uploads go to the transcriber its provider describes: one that
    /// `makeBatchTranscriber` sends to the OpenAI-compatible transcriber has a
    /// `speechUpload` (its init would stop otherwise), and Apple's go to Groq's.
    func testEveryEngineUploadsThroughTheTranscriberItsProviderDescribes() {
        for engine in STTProviderType.allCases {
            let configuration = RecordingConfiguration(provider: engine, locale: "uk-UA", localeIsAutomatic: true)
            switch engine {
            case .groq, .openai, .apple:
                let transcriber = makeBatchTranscriber(configuration: configuration) as? OpenAICompatibleTranscriber
                XCTAssertEqual(transcriber?.provider, engine == .apple ? .groq : engine.vendor, engine.rawValue)
            case .elevenlabs:
                XCTAssertTrue(makeBatchTranscriber(configuration: configuration) is ElevenLabsTranscriber)
                XCTAssertNil(engine.vendor.descriptor.speechUpload)
            case .local:
                XCTAssertNil(engine.vendor.descriptor.speechUpload)
            case .server:
                XCTAssertTrue(makeBatchTranscriber(configuration: configuration) is ServerTranscriber)
                XCTAssertNil(engine.vendor.descriptor.speechUpload)
            }
        }
    }
}
