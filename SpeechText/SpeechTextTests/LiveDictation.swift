// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import CryptoKit
import Foundation
import SpeechTextCore

// A recorded clip played through the app's own recognition code the way the microphone
// would deliver it, against a real engine. Shared by `LiveProviderTests` and the
// `SpeechTextEvaluation` tool; no XCTest here.
//
// What is real: `AudioBufferWriter`, `StreamingRecognitionSession` with its
// `BatchRecognitionSession` fallback, the providers and their sockets, the span layer and
// `InlineDelivery`'s stop decision. What stands in: the tap (a WAV cut into tap-sized
// buffers, at the tap's rate and — for a stream — at the tap's pace) and the paste (the
// stop's text is recorded, not pasted).

// MARK: - The inline flow around a session

/// What `SpeechEngine` and `AppState` do with a session's events and its outcome: every
/// `.live` event cleaned into the span layer the overlay draws, and at the stop the
/// outcome cleaned, committed, settled and handed to `InlineDelivery.stopResult` with the
/// whole recording's text.
///
/// `DictationReplay` and the live runs both go through this, so the glue is copied from
/// the app once. **A change to that order in `SpeechEngine.stopRecording` or
/// `AppState.handleTranscriptionResult` has to be mirrored here.**
@MainActor
final class InlineDictationFlow {
    private(set) var layer = TranscriptSpanLayer()
    private let clean: (String) -> String
    private let finish: (String) -> String

    /// `SpeechEngine.startRecording` → `setupRecordingSession`. `clean` is what every
    /// `.live` event goes through (`RecordingConfiguration.cleaned`); `finish` is what the
    /// segment's final text goes through (`RecordingConfiguration.finished` — the cleanup
    /// plus the Dictionary's corrections, which are never applied to live text).
    init(clean: @escaping (String) -> String, finish: ((String) -> String)? = nil) {
        self.clean = clean
        self.finish = finish ?? clean
        layer.reset()
        layer.beginSegment()
    }

    /// `SpeechEngine.setupRecordingSession`'s `onEvent`.
    func live(committed: String, partial: String) {
        layer.ingest(committed: clean(committed), partial: clean(partial))
    }

    /// `SpeechEngine.stopRecording` (after `session.finish()`) →
    /// `AppState.handleTranscriptionResult`. Returns the cleaned outcome with the decision.
    /// `microphoneLost`: the engine ended the recording itself, for that reason
    /// (`SpeechEngine.endRecording(microphoneLost:)`), which explains only a segment that
    /// came back with no words and no error of its own.
    func stop(_ outcome: RecognitionOutcome, aiMode: Bool,
              microphoneLost reason: String? = nil) -> (outcome: RecognitionOutcome, result: InlineDelivery.StopResult) {
        var outcome = outcome
        outcome.text = finish(outcome.text)
        if let reason, !outcome.cancelled, outcome.text.isEmpty, outcome.error == nil {
            outcome.error = reason
        }
        layer.commitSegment(outcome.text)
        layer.settleSegment()
        // `SpeechEngine.recordOutcome` puts the error in `errorMessage` only when the
        // segment has no text: words with an error after them are pasted.
        let failed = outcome.error != nil && outcome.text.isEmpty
        let result = InlineDelivery.stopResult(finalText: outcome.text, failed: failed,
                                               aiMode: aiMode, recordingText: layer.text)
        return (outcome, result)
    }

    /// `AppState.cancelInlineFlow` → `SpeechEngine.cancelRecording`.
    func cancel() {
        layer.reset()
    }
}

// MARK: - The microphone

/// A clip as the tap hands it over: Float32 mono at 48 kHz in ~20 ms buffers (the tap's
/// ~50 a second), so the writer converts 48 → 16 kHz and OpenAI's socket 48 → 24 kHz, as
/// they do in the app — not the 16 kHz the file happens to be stored at.
/// `@unchecked Sendable`: the buffers are filled once, when the clip is read, and only
/// read after that.
struct TapAudio: @unchecked Sendable {
    static let sampleRate: Double = 48_000
    static let framesPerBuffer: AVAudioFrameCount = 960

    let format: AVAudioFormat
    let buffers: [AVAudioPCMBuffer]
    let duration: TimeInterval
    /// The first 16 hex digits of the recording's SHA-256 (and the cut, for a clip taken
    /// from the start of another): what tells a re-recorded clip from an engine that changed.
    let digest: String

    enum Failure: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self { case .unreadable(let why): "Could not read the clip: \(why)" }
        }
    }

    /// `seconds` keeps only the recording's start — how the silence clips are cut.
    /// The clip's audio from the corpus folder.
    init(clip: CorpusClip, in corpus: URL) throws {
        try self.init(contentsOf: corpus.appendingPathComponent(clip.audioFile), seconds: clip.seconds)
    }

    init(contentsOf url: URL, seconds: Double? = nil) throws {
        var hash = SHA256()
        hash.update(data: try Data(contentsOf: url))
        if let seconds { hash.update(data: Data("\(seconds)".utf8)) }
        digest = hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        let file = try AVAudioFile(forReading: url)
        var frames = AVAudioFrameCount(file.length)
        if let seconds { frames = min(frames, AVAudioFrameCount(seconds * file.processingFormat.sampleRate)) }
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw Failure.unreadable("no buffer for \(frames) frames")
        }
        try file.read(into: source, frameCount: frames)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw Failure.unreadable("no converter from \(file.processingFormat)")
        }
        let capacity = AVAudioFrameCount(Double(source.frameLength) * Self.sampleRate / file.processingFormat.sampleRate) + 4096
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw Failure.unreadable("no buffer for the conversion")
        }
        var handed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if handed {
                status.pointee = .endOfStream
                return nil
            }
            handed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }

        var buffers: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        while offset < converted.frameLength {
            let count = min(Self.framesPerBuffer, converted.frameLength - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }
            buffer.frameLength = count
            memcpy(buffer.floatChannelData![0], converted.floatChannelData![0] + Int(offset),
                   Int(count) * MemoryLayout<Float>.size)
            buffers.append(buffer)
            offset += count
        }
        self.format = format
        self.buffers = buffers
        self.duration = Double(converted.frameLength) / Self.sampleRate
    }
}

// MARK: - Engines

/// The keys a run may use, from the environment only — never from the app's settings,
/// and they may be other keys than the app's.
struct ProviderKeys {
    var keys: [Provider: String] = [:]

    /// The variable each speech vendor's key is read from.
    static let variables: [Provider: String] = [
        .groq: "GROQ_API_KEY", .elevenLabs: "ELEVENLABS_API_KEY", .openAI: "OPENAI_API_KEY",
    ]

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ProviderKeys {
        ProviderKeys(keys: variables.compactMapValues { environment[$0].flatMap { $0.isEmpty ? nil : $0 } })
    }
}

/// One row of the matrix: a model from `sttModelCatalog`.
struct CorpusEngine {
    let model: STTModelDescriptor

    /// `vendor/model`, as `SPEECHTEXT_ENGINES` names it.
    var id: String { "\(model.vendor.rawValue)/\(model.id)" }

    /// The table's column: the vendor, since Groq and the Mac both run a "Whisper Large
    /// V3 Turbo", and the picker's name without its " — live text" gloss.
    var name: String {
        let short = model.displayName.components(separatedBy: " — ")[0]
        return "\(model.vendor.displayName) · \(short)"
    }

    /// Every model the matrix can run — all but Apple's recogniser, whose permission
    /// prompt would hang a headless run.
    static var all: [CorpusEngine] {
        sttModelCatalog.filter { $0.delivery != .systemRecognizer }.map(CorpusEngine.init)
    }

    var isLocal: Bool { model.vendor == .local }

    var provider: STTProviderType {
        switch model.vendor {
        case .groq: .groq
        case .elevenLabs: .elevenlabs
        case .openAI: .openai
        case .local: .local
        case .apple, .anthropic, .ollama: .apple
        }
    }

    /// Why this engine cannot run here, as the table's cell — nil when it can.
    func unavailable(keys: ProviderKeys, modelInstalled: (String) -> Bool = { isLocalModelInstalled($0) }) -> CorpusResult.Status? {
        switch model.requirement {
        case .none: return nil
        case .installedModel: return modelInstalled(model.id) ? nil : .notInstalled
        case .apiKey:
            return keys.keys[model.vendor, default: ""].isEmpty ? .noKey : nil
        }
    }

    /// The session's settings with `language` forced, or Auto when nil — built by hand,
    /// as `RecordingConfiguration.current()` would, minus the UserDefaults. `dictionary`
    /// is the clip's Dictionary pass: its words are sent to the engine as the app sends
    /// them (`vocabulary`, ranked as a fresh list is — newest first) and correct the
    /// stop's text (`dictionary`).
    /// `stated` is "Languages I speak" with nothing forced (two or more); `language`
    /// forces one, as a single stated language does.
    func configuration(keys: ProviderKeys, language: String?, stated: [String] = [],
                       dictionary: [VocabularyEntry] = []) -> RecordingConfiguration {
        let forced = language.flatMap { spokenLanguage(id: $0) }
        var configuration = RecordingConfiguration(
            provider: provider,
            locale: forced?.localeIdentifier ?? "en-US",
            languages: forced.map { [$0.id] } ?? stated,
            localeIsAutomatic: forced == nil,
            apiKeys: keys.keys,
            models: [model.vendor: model.id],
            dictionary: dictionary
        )
        if !dictionary.isEmpty {
            configuration.vocabulary = CustomVocabulary.ranked(dictionary, now: Date(), rankByUse: false,
                                                               historyTexts: { [] })
        }
        return configuration
    }
}

// MARK: - One run

/// The upload a stream falls back to, noting that it was asked — which is how a row tells
/// a realtime answer from the upload that stood in for it.
@MainActor
private final class ObservedFallback: RecognitionSession {
    var onEvent: (@MainActor @Sendable (RecognitionEvent) -> Void)?
    private let wrapped: RecognitionSession
    private(set) var answered = false

    init(_ wrapped: RecognitionSession) { self.wrapped = wrapped }

    func start() throws { try wrapped.start() }
    nonisolated func feed(native: AVAudioPCMBuffer, pcm16: Data?) { wrapped.feed(native: native, pcm16: pcm16) }
    func pause() -> String? { wrapped.pause() }
    nonisolated func finish() async -> RecognitionOutcome {
        await MainActor.run { answered = true }
        return await wrapped.finish()
    }
    func cancel() { wrapped.cancel() }
}

@MainActor
enum LiveDictation {
    /// Plays `audio` through `engine` and judges what the stop would have pasted.
    /// Streaming engines are fed at the tap's pace, since their answer depends on it; an
    /// upload or on-device engine gets the whole clip at once, since its answer does not
    /// and the stop-to-text time is measured from the stop either way. A streaming run's
    /// `DictationTrace` is written to `traceDirectory` as `<clip>--<vendor>-<model>[--lang].json`.
    static func run(clip: CorpusClip, audio: TapAudio, engine: CorpusEngine, pass: CorpusPass,
                    keys: ProviderKeys, traceDirectory: URL?) async -> CorpusResult {
        let language = pass.language
        var result = CorpusResult(clip: clip.name, engine: engine.id, engineName: engine.name,
                                  language: pass.label, status: .ran)
        result.expected = clip.expected
        result.audioDigest = audio.digest
        let configuration = engine.configuration(keys: keys, language: language, stated: pass.stated,
                                                 dictionary: pass.dictionary ? clip.dictionaryEntries : [])
        let writer = AudioBufferWriter()
        let fallback = ObservedFallback(BatchRecognitionSession(
            provider: makeBatchTranscriber(configuration: configuration),
            writer: writer, language: configuration.cloudLanguage, languages: configuration.languages))
        let session: RecognitionSession
        let streams: Bool
        // RecognitionSessionFactory, minus Apple.
        if let streamer = makeStreamingTranscriber(configuration: configuration) {
            session = StreamingRecognitionSession(provider: streamer, writer: writer,
                                                  languages: configuration.languages, fallback: fallback,
                                                  reconnect: { makeStreamingTranscriber(configuration: configuration) },
                                                  meter: configuration.streamMeter,
                                                  longestTrustedSegment: configuration.longestTrustedStreamSegment)
            streams = true
        } else {
            session = fallback
            streams = false
        }

        let recorder = streams ? DictationTraceRecorder(setup: DictationTrace.Setup(
            aiMode: false, removesDisfluencies: configuration.removesDisfluencies,
            dashStyle: configuration.dashStyle, app: "Corpus: \(clip.name)")) : nil
        DictationTraceRecorder.current = recorder

        let flow = InlineDictationFlow(clean: configuration.cleaned, finish: configuration.finished)
        var started = Date()
        var firstText: Date?
        session.onEvent = { event in
            MainActor.assumeIsolated {
                guard case .live(let committed, let partial) = event else { return }
                flow.live(committed: committed, partial: partial)
                if firstText == nil, !flow.layer.text.isEmpty { firstText = Date() }
            }
        }

        // SpeechEngine.setupRecordingSession: the session opens before the tap.
        writer.prepare(sourceFormat: audio.format)
        do {
            try session.start()
        } catch {
            result.error = error.localizedDescription
        }
        started = Date()
        await play(audio, into: writer, session: session, paced: streams)

        // What the sessions' voice guard will see, kept on the row.
        if let reading = await VoiceActivity.read(writer) {
            result.voiceProbability = Double(reading.maxProbability)
            result.voiceWindows = reading.windowsOverThreshold
        }

        // SpeechEngine.stopRecording.
        DictationTraceRecorder.record(.stop)
        _ = session.pause()
        let stopped = Date()
        let finished = await session.finish()
        let (outcome, decision) = flow.stop(finished, aiMode: false)
        result.stopToTextSeconds = Date().timeIntervalSince(stopped)
        result.firstPartialSeconds = firstText.map { $0.timeIntervalSince(started) }
        result.path = engine.isLocal ? .onDevice : !streams ? .upload : fallback.answered ? .fallback : .stream
        result.error = result.error ?? outcome.error

        if case .paste(let text) = decision {
            result.pasted = text
            DictationTraceRecorder.record(.stopPaste, text: text + " ")
        }
        result.wordErrorRate = clip.expectsNothing ? nil
            : CorpusMeasure.wordErrorRate(expected: clip.expected, actual: result.pasted ?? "")
        result.substitutions = CorpusMeasure.substitutions(expected: clip.expected, actual: result.pasted ?? "")
        // English forced to Ukrainian is reported, not judged: what comes out of it (a
        // translation, a transliteration) is the finding, not a failure.
        let judged = language == nil || language == clip.language || clip.language == "mixed"
        result.failures = judged ? CorpusChecks.failures(clip: clip, clipSeconds: audio.duration,
                                                         pasted: result.pasted, error: result.error) : []

        DictationTraceRecorder.current = nil
        if let recorder, let traceDirectory {
            writeTrace(recorder, named: "\(clip.name)--\(engine.model.vendor.rawValue)-\(engine.model.id)"
                       + (language.map { "--\($0)" } ?? "") + (pass.dictionary ? "--dictionary" : "")
                       + (pass.stated.isEmpty ? "" : "--" + pass.label),
                       into: traceDirectory)
        }
        if let file = outcome.audioFileURL { AudioBufferWriter.cleanup(fileURL: file) }
        writer.reset()
        return result
    }

    /// The tap: each buffer to the writer, and the writer's bytes with the buffer to the
    /// session — off the main thread, which the session's events need free.
    private static func play(_ audio: TapAudio, into writer: AudioBufferWriter,
                             session: RecognitionSession, paced: Bool) async {
        // The writer and the session's `feed` are written for the audio thread, as the
        // app's tap holds them; the caller is suspended on the continuation until the
        // loop has ended.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let start = DispatchTime.now().uptimeNanoseconds
                let step = Double(TapAudio.framesPerBuffer) / TapAudio.sampleRate
                for (index, buffer) in audio.buffers.enumerated() {
                    if paced {
                        let due = start + UInt64(Double(index + 1) * step * 1_000_000_000)
                        let now = DispatchTime.now().uptimeNanoseconds
                        if due > now { usleep(useconds_t((due - now) / 1000)) }
                    }
                    let pcm = writer.append(buffer)
                    session.feed(native: buffer, pcm16: pcm)
                }
                continuation.resume()
            }
        }
    }

    /// The recorder names its file by the second; a run makes many a minute, so it is
    /// written aside and renamed.
    private static func writeTrace(_ recorder: DictationTraceRecorder, named name: String, into directory: URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechtext-trace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let written = recorder.write(into: scratch) else { return }
        let target = directory.appendingPathComponent(name + ".json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: written, to: target)
    }
}
