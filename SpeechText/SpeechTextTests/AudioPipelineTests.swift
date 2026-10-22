// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import AppKit
import AVFoundation
@testable import SpeechTextCore

// MARK: - Helpers

/// A deinterleaved float32 buffer holding a sine, in every channel, at the format's rate.
private func makeSineBuffer(format: AVAudioFormat, frames: AVAudioFrameCount,
                            frequency: Double = 440, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let channels = buffer.floatChannelData!
    for frame in 0 ..< Int(frames) {
        let sample = amplitude * Float(sin(2.0 * .pi * frequency * Double(frame) / format.sampleRate))
        for ch in 0 ..< Int(format.channelCount) {
            channels[ch][frame] = sample
        }
    }
    return buffer
}

private func mono48k() -> AVAudioFormat {
    AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
}

private func int16Frames(_ data: Data) -> Int { data.count / MemoryLayout<Int16>.size }

private func int16Samples(_ data: Data) -> [Int16] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
}

// MARK: - PCMDownsampler

final class PCMDownsamplerTests: XCTestCase {

    func testDownsamples48kMonoByThree() throws {
        let downsampler = try XCTUnwrap(PCMDownsampler(sourceFormat: mono48k(), targetRate: 16_000))
        let input = makeSineBuffer(format: mono48k(), frames: 4_800)

        var pcm = try XCTUnwrap(downsampler.convert(input), "converter reported an error")
        if let tail = downsampler.flush() { pcm.append(tail) }

        // 48 kHz → 16 kHz is 3:1; the resampler's priming/delay line costs a few frames.
        let frames = int16Frames(pcm)
        XCTAssertEqual(frames, 1_600, accuracy: 64)

        // The waveform survives: a 0.5-amplitude sine should peak near 0.5 * Int16.max,
        // swinging both ways — not silence, not clipping, not a DC offset.
        let samples = int16Samples(pcm)
        XCTAssertGreaterThan(Int(samples.max() ?? 0), 10_000)
        XCTAssertLessThan(Int(samples.min() ?? 0), -10_000)
        XCTAssertLessThan(Int(samples.max() ?? 0), 22_000)
    }

    func testStereoDownmixesToMono() throws {
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let downsampler = try XCTUnwrap(PCMDownsampler(sourceFormat: stereo, targetRate: 16_000))
        let input = makeSineBuffer(format: stereo, frames: 4_800)

        var pcm = try XCTUnwrap(downsampler.convert(input))
        if let tail = downsampler.flush() { pcm.append(tail) }

        // Mono output: the frame count follows the sample-rate ratio, not the channel
        // count — a channel-interleaving bug would double it.
        XCTAssertEqual(int16Frames(pcm), 1_600, accuracy: 64)
        XCTAssertGreaterThan(Int(int16Samples(pcm).max() ?? 0), 5_000)
    }

    func testConverterKeepsStateAcrossCalls() throws {
        // Two half-buffers through one converter must produce what one full buffer does:
        // the resampler's delay line carries samples across the call boundary.
        let whole = try XCTUnwrap(PCMDownsampler(sourceFormat: mono48k(), targetRate: 16_000))
        var wholePCM = try XCTUnwrap(whole.convert(makeSineBuffer(format: mono48k(), frames: 4_800)))
        if let tail = whole.flush() { wholePCM.append(tail) }

        let halves = try XCTUnwrap(PCMDownsampler(sourceFormat: mono48k(), targetRate: 16_000))
        var halvesPCM = Data()
        for _ in 0 ..< 2 {
            halvesPCM.append(try XCTUnwrap(halves.convert(makeSineBuffer(format: mono48k(), frames: 2_400))))
        }
        if let tail = halves.flush() { halvesPCM.append(tail) }

        XCTAssertEqual(int16Frames(halvesPCM), int16Frames(wholePCM), accuracy: 16)
    }
}

// MARK: - AudioBufferWriter

final class AudioBufferWriterTests: XCTestCase {

    func testWriteProducesReadable16kMonoFileOfExpectedDuration() throws {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())

        // 1.0 s of audio, delivered in ten tap-sized buffers.
        for _ in 0 ..< 10 {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))
        }
        XCTAssertEqual(writer.bufferedDuration, 1.0, accuracy: 0.05)

        let url = try writer.writeAudioFile()
        defer { AudioBufferWriter.cleanup(fileURL: url) }
        XCTAssertEqual(url.pathExtension, AudioBufferWriter.preferredUploadCodec.fileExtension)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertEqual(seconds, 1.0, accuracy: 0.05)
    }

    /// 0.2 s is 3 200 frames, under one FLAC block: Core Audio's encoder wrote that as a
    /// 42-byte file with no header and no samples. It has to open, and hold the audio.
    func testSegmentShorterThanOneFLACBlockIsWrittenAsADecodableFile() throws {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))
        writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))

        let url = try writer.writeAudioFile()
        defer { AudioBufferWriter.cleanup(fileURL: url) }
        XCTAssertEqual(url.pathExtension, "wav")

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(Double(file.length), 3_200, accuracy: 64)
    }

    func testSegmentOfOneFLACBlockAndUpStaysFLAC() throws {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        for _ in 0 ..< 4 {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))
        }

        let url = try writer.writeAudioFile()
        defer { AudioBufferWriter.cleanup(fileURL: url) }
        XCTAssertEqual(url.pathExtension, AudioBufferWriter.preferredUploadCodec.fileExtension)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length), 6_400, accuracy: 64)
    }

    func testEmptyWriterThrowsNoAudio() {
        let writer = AudioBufferWriter()
        XCTAssertThrowsError(try writer.writeAudioFile()) { error in
            guard case AudioBufferWriter.AudioBufferWriterError.noAudio = error else {
                return XCTFail("expected noAudio, got \(error)")
            }
        }
    }

    func testSilentSegmentHasNoAudibleSignal() {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        for _ in 0 ..< 10 {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: 0.001))
        }
        XCTAssertFalse(writer.hasAudibleSignal, "a −60 dBFS hum is a dead microphone, not speech")

        writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: 0.05))
        XCTAssertTrue(writer.hasAudibleSignal, "one quiet syllable is enough to upload")

        writer.reset()
        XCTAssertFalse(writer.hasAudibleSignal)
    }

    func testUnmeasuredNativeAudioCountsAsAudible() {
        // No `prepare`: the native fallback path has no converted samples to measure,
        // and the guard must not turn that into a skipped upload.
        let writer = AudioBufferWriter()
        writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: 0.001))
        XCTAssertTrue(writer.hasAudibleSignal)
    }

    func testResetClearsBufferedAudio() {
        // No `prepare` — the native-copy fallback path, where reset() is fully
        // observable (the converter's delay line can't re-materialise frames).
        let writer = AudioBufferWriter()
        writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))
        XCTAssertEqual(writer.bufferedDuration, 0.1, accuracy: 0.001)

        writer.reset()
        XCTAssertEqual(writer.bufferedDuration, 0)
        XCTAssertThrowsError(try writer.writeAudioFile())
    }
}

// MARK: - BatchRecognitionSession

/// Counts uploads instead of making them.
private final class RecordingBatchTranscriber: BatchTranscriber, @unchecked Sendable {
    private(set) var uploads: [URL] = []
    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        uploads.append(audioFileURL)
        return "текст"
    }
}

final class BatchRecognitionSessionTests: XCTestCase {

    private func writer(seconds: Double) -> AudioBufferWriter {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        for _ in 0 ..< Int((seconds / 0.1).rounded()) {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800))
        }
        return writer
    }

    /// A shortcut pressed and let go at once: no upload, no error, and an outcome the
    /// engine writes no History row for.
    func testASegmentTooShortToBeSpeechIsDroppedWithoutATrace() async {
        let provider = RecordingBatchTranscriber()
        let session = BatchRecognitionSession(provider: provider, writer: writer(seconds: 0.2), language: nil, languages: [])

        let outcome = await session.finish()

        XCTAssertTrue(provider.uploads.isEmpty)
        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.error)
        XCTAssertNil(outcome.audioFileURL)
        XCTAssertTrue(outcome.cancelled, "the one outcome the engine records nothing for")
    }

    func testASegmentLongEnoughToBeSpeechIsUploaded() async {
        let provider = RecordingBatchTranscriber()
        let session = BatchRecognitionSession(provider: provider, writer: writer(seconds: 0.4), language: nil, languages: [])

        let outcome = await session.finish()
        defer { outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:)) }

        XCTAssertEqual(provider.uploads.count, 1)
        XCTAssertEqual(outcome.text, "текст")
        XCTAssertFalse(outcome.cancelled)
    }
}

private final class AnsweringBatchTranscriber: BatchTranscriber, @unchecked Sendable {
    let answer: String
    init(_ answer: String) { self.answer = answer }
    func transcribe(audioFileURL: URL, language: String?) async throws -> String { answer }
}

/// A detector that answers what it is told, and counts what it was asked.
private final class FakeVoiceDetector: VoiceActivityDetector, @unchecked Sendable {
    let probabilities: [Float]?
    private(set) var samplesSeen = 0
    init(_ probabilities: [Float]?) { self.probabilities = probabilities }
    func speechProbabilities(_ samples: [Float]) async throws -> [Float] {
        samplesSeen = samples.count
        guard let probabilities else { throw URLError(.cannotDecodeContentData) }
        return probabilities
    }
}

/// A transcriber that must never be asked.
private final class UnreachableBatchTranscriber: BatchTranscriber, @unchecked Sendable {
    private(set) var called = false
    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        called = true
        return "Thank you for watching."
    }
}

/// a segment with no voice in it is neither sent nor pasted.
@MainActor
final class VoiceActivityTests: XCTestCase {
    private func writer(seconds: Double) -> AudioBufferWriter {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        for _ in 0 ..< Int((seconds / 0.1).rounded()) {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: 0.5))
        }
        return writer
    }

    private func withDetector<T>(_ detector: VoiceActivityDetector?, _ body: () async throws -> T) async rethrows -> T {
        let saved = VoiceActivity.detector
        VoiceActivity.detector = detector
        defer { VoiceActivity.detector = saved }
        return try await body()
    }

    /// The corpus's own windows: «Так.» filled two; room noise on a MacBook's
    /// microphone raised one isolated window to 0.95 in fifteen seconds.
    func testALongSegmentNeedsTwoWindowsAndAShortOneOne() {
        let word: [Float] = [0.09, 0.06, 0.09, 1, 1, 0.21, 0.25, 0.16]
        XCTAssertTrue(VoiceActivityReading(probabilities: word, segmentSeconds: 2.0).holdsSpeech)
        let room = Array(repeating: Float(0.01), count: 30) + [0.17, 0.95, 0.13] + Array(repeating: Float(0.01), count: 30)
        XCTAssertFalse(VoiceActivityReading(probabilities: room, segmentSeconds: 15).holdsSpeech)
        XCTAssertTrue(VoiceActivityReading(probabilities: [0.1, 0.95, 0.1], segmentSeconds: 1.5).holdsSpeech,
                      "a short segment: one window is a one-word dictation")
        XCTAssertTrue(VoiceActivityReading(probabilities: [0.1, 0.95, 0.1],
                                           segmentSeconds: STTTuning.voiceShortSegmentSeconds).holdsSpeech)
        XCTAssertFalse(VoiceActivityReading(probabilities: [0.1, 0.95, 0.1], segmentSeconds: 2.6).holdsSpeech)
        XCTAssertFalse(VoiceActivityReading(probabilities: [0.58, STTTuning.voiceProbabilityThreshold],
                                            segmentSeconds: 1).holdsSpeech,
                       "the keyboard's loudest window, and the threshold itself, are not a voice")
        XCTAssertFalse(VoiceActivityReading(probabilities: [], segmentSeconds: 0).holdsSpeech)
        let reading = VoiceActivityReading(probabilities: [0.9, 1, 0.3], segmentSeconds: 0.8)
        XCTAssertEqual(reading.maxProbability, 1)
        XCTAssertEqual(reading.windowsOverThreshold, 2)
    }

    /// Usage's speaking time: the silence before the first word and after the last is
    /// left out, a window either side kept, a pause between words kept.
    func testTheVoicedSpanRunsFromTheFirstWordToTheLast() {
        // Ten windows of 0.5 s: silence, words at 3–4 and 6, a pause at 5, silence.
        let speech: [Float] = [0.01, 0.02, 0.1, 0.95, 0.99, 0.3, 0.9, 0.2, 0.01, 0.01]
        XCTAssertEqual(VoiceActivityReading(probabilities: speech, segmentSeconds: 5).voicedSpanSeconds ?? 0,
                       3, accuracy: 0.0001, "windows 2 to 7")
        let edges: [Float] = [0.9, 0.1, 0.1, 0.9]
        XCTAssertEqual(VoiceActivityReading(probabilities: edges, segmentSeconds: 2).voicedSpanSeconds ?? 0,
                       2, accuracy: 0.0001, "the margin is held inside the segment")
        XCTAssertNil(VoiceActivityReading(probabilities: [0.1, 0.6, 0.2], segmentSeconds: 1).voicedSpanSeconds)
        XCTAssertNil(VoiceActivityReading(probabilities: [], segmentSeconds: 0).voicedSpanSeconds)
    }

    func testAnUploadCarriesItsSpeakingTime() async {
        let outcome = await withDetector(FakeVoiceDetector([0.1, 0.1, 0.99, 0.99, 0.1, 0.1])) {
            await BatchRecognitionSession(provider: UnreachableBatchTranscriber(), writer: writer(seconds: 3),
                                          language: nil, languages: []).finish()
        }
        outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:))
        XCTAssertEqual(outcome.speakingSeconds ?? 0, 2, accuracy: 0.0001, "windows 1 to 4 of six in 3 s")
        let unread = await withDetector(nil) {
            await BatchRecognitionSession(provider: UnreachableBatchTranscriber(), writer: writer(seconds: 3),
                                          language: nil, languages: []).finish()
        }
        unread.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:))
        XCTAssertNil(unread.speakingSeconds, "no detector: Usage counts the whole segment")
    }

    func testAnUploadWithNoVoiceIsNeverSentAndKeepsItsAudio() async {
        let detector = FakeVoiceDetector([0.1, 0.6, 0.2])
        let transcriber = UnreachableBatchTranscriber()
        let outcome = await withDetector(detector) {
            await BatchRecognitionSession(provider: transcriber, writer: writer(seconds: 3), language: nil, languages: [])
                .finish()
        }
        defer { outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:)) }
        XCTAssertFalse(transcriber.called, "nothing sent, nothing billed")
        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.error)
        XCTAssertNotNil(outcome.audioFileURL, "archived for a History retry")
        XCTAssertFalse(outcome.cancelled, "an empty result, which History records")
        XCTAssertEqual(outcome.usage, [], "no request, no ledger entry")
        XCTAssertEqual(detector.samplesSeen, 48_000, "the segment's 16 kHz samples")
    }

    func testAnUploadWithAVoiceIsSent() async {
        for detector in [FakeVoiceDetector([0.1, 0.99, 0.99, 0.2]), FakeVoiceDetector(nil), nil] {
            let transcriber = UnreachableBatchTranscriber()
            let outcome = await withDetector(detector) {
                await BatchRecognitionSession(provider: transcriber, writer: writer(seconds: 3), language: nil, languages: [])
                    .finish()
            }
            outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:))
            XCTAssertTrue(transcriber.called, "a voice, a detector that failed, or none at all: sent as before")
        }
    }

    /// A one-word dictation: one window over the threshold is enough in a short segment,
    /// not in a long one.
    func testOneWindowSendsAShortSegmentButNotALongOne() async {
        for (seconds, sent) in [(2.0, true), (3.0, false)] {
            let transcriber = UnreachableBatchTranscriber()
            let outcome = await withDetector(FakeVoiceDetector([0.1, 1, 0.2])) {
                await BatchRecognitionSession(provider: transcriber, writer: writer(seconds: seconds), language: nil,
                                              languages: []).finish()
            }
            outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:))
            XCTAssertEqual(transcriber.called, sent, "\(seconds) s")
        }
    }

    func testAStreamWithNoVoiceIsNotPasted() async {
        let provider = ScriptedStreamingTranscriber()
        provider.eventsAtFinish = [.committed("Thank you.")]
        let outcome = await withDetector(FakeVoiceDetector([0.2, 0.3])) { () async -> RecognitionOutcome in
            let session = StreamingRecognitionSession(provider: provider, writer: writer(seconds: 3), languages: [],
                                                      fallback: ScriptedSegment(error: "no fallback expected"))
            try! session.start()
            return await session.finish()
        }
        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.error)
        XCTAssertFalse(outcome.cancelled)
    }

    func testAStreamWithAVoiceIsPasted() async {
        let provider = ScriptedStreamingTranscriber()
        provider.eventsAtFinish = [.committed("Thank you.")]
        let outcome = await withDetector(FakeVoiceDetector([0.2, 1, 1])) { () async -> RecognitionOutcome in
            let session = StreamingRecognitionSession(provider: provider, writer: writer(seconds: 3), languages: [],
                                                      fallback: ScriptedSegment(error: "no fallback expected"))
            try! session.start()
            return await session.finish()
        }
        XCTAssertEqual(outcome.text, "Thank you.")
    }
}

/// The upload's and the stream's guards against text nobody said.
@MainActor
final class HallucinationGuardTests: XCTestCase {

    private func writer(seconds: Double, amplitude: Float = 0.5) -> AudioBufferWriter {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        for _ in 0 ..< Int((seconds / 0.1).rounded()) {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: amplitude))
        }
        return writer
    }

    private func upload(_ answer: String, seconds: Double, languages: [String] = []) async -> RecognitionOutcome {
        let session = BatchRecognitionSession(provider: AnsweringBatchTranscriber(answer),
                                              writer: writer(seconds: seconds), language: nil, languages: languages)
        return await session.finish()
    }

    /// The whole answer for a short segment is a subtitle sign-off: nothing to paste, the
    /// audio kept for a History retry.
    func testAnUploadAnsweredWithAKnownHallucinationIsEmptyAndKeepsItsAudio() async {
        let outcome = await upload("Thank you for watching!", seconds: 1)
        defer { outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:)) }

        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.error)
        XCTAssertNotNil(outcome.audioFileURL)
        XCTAssertFalse(outcome.cancelled, "an empty result, which History records")
    }

    func testTheSameAnswerForALongerSegmentIsKept() async {
        let outcome = await upload("Thank you for watching!", seconds: 2.5)
        defer { outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:)) }

        XCTAssertEqual(outcome.text, "Thank you for watching!")
    }

    /// noise a model wrote down — a breath as «.», a cough in another script — is
    /// dropped like a known phrase, at any length; the script only once languages are stated.
    func testAnUploadOfPunctuationOrAForeignScriptIsEmptyAndKeepsItsAudio() async {
        for (answer, languages) in [("..", [String]()), ("うーん。", ["uk", "en"]), ("흠..", ["uk", "en"])] {
            let outcome = await upload(answer, seconds: 10, languages: languages)
            defer { outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:)) }
            XCTAssertEqual(outcome.text, "", answer)
            XCTAssertNotNil(outcome.audioFileURL, answer)
            XCTAssertFalse(outcome.cancelled, answer)
        }
        let unstated = await upload("うーん。", seconds: 10)
        defer { unstated.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:)) }
        XCTAssertEqual(unstated.text, "うーん。", "with no language stated the model may be right")
    }

    func testAStreamAnsweredInAForeignScriptIsEmptyAndDrawsNothing() async {
        let provider = ScriptedStreamingTranscriber()
        provider.eventsAtFinish = [.committed("음 음 음")]
        let session = StreamingRecognitionSession(provider: provider, writer: writer(seconds: 5), languages: ["uk", "en"],
                                                  fallback: ScriptedSegment(error: "no fallback expected"))
        var drawn: [String] = []
        session.onEvent = { event in
            if case .live(let committed, let partial) = event { drawn.append(committed + partial) }
        }
        try! session.start()
        let outcome = await session.finish()
        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.error)
        XCTAssertEqual(drawn.filter { !$0.isEmpty }, [], "the overlay never shows it")
    }

    private func stream(_ text: String, writer: AudioBufferWriter) async -> RecognitionOutcome {
        let provider = ScriptedStreamingTranscriber()
        provider.eventsAtFinish = [.committed(text)]
        let session = StreamingRecognitionSession(provider: provider, writer: writer, languages: [],
                                                  fallback: ScriptedSegment(error: "no fallback expected"))
        try! session.start()
        return await session.finish()
    }

    /// A stream is answered by the server whatever the microphone heard, so the upload's
    /// guards now apply to its text too.
    func testAStreamAnsweredWithAKnownHallucinationIsEmpty() async {
        let outcome = await stream("Evet.", writer: writer(seconds: 1))

        XCTAssertEqual(outcome.text, "")
        XCTAssertNil(outcome.error)
        XCTAssertFalse(outcome.cancelled)
    }

    func testAStreamOverASilentSegmentIsEmpty() async {
        let outcome = await stream("Hello there.", writer: writer(seconds: 1, amplitude: 0.001))

        XCTAssertEqual(outcome.text, "")
        XCTAssertFalse(outcome.cancelled, "an empty result, archived by the engine")
    }

    func testAStreamOverASegmentTooShortToBeSpeechLeavesNoTrace() async {
        let outcome = await stream("Hello.", writer: writer(seconds: 0.2))

        XCTAssertEqual(outcome.text, "")
        XCTAssertTrue(outcome.cancelled, "the one outcome the engine records nothing for")
    }

    func testAnAudibleStreamIsKept() async {
        let outcome = await stream("Hello there.", writer: writer(seconds: 1))

        XCTAssertEqual(outcome.text, "Hello there.")
    }
}

/// The stream's guards seen where they matter: the stop pastes the span layer, not the
/// session's outcome, so the words the overlay already drew must be taken back too.
@MainActor
final class HallucinationGuardReplayTests: XCTestCase {

    private func writer(seconds: Double, amplitude: Float) -> AudioBufferWriter {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        for _ in 0 ..< Int((seconds / 0.1).rounded()) {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: amplitude))
        }
        return writer
    }

    private func replay(over writer: AudioBufferWriter) async -> DictationReplay.Result {
        var setup = DictationReplay.Setup()
        setup.writer = writer
        return await DictationReplay.run(setup, in: FakeApp(), [
            .partial("Hello"),
            .committed("Hello there."),
        ])
    }

    func testWordsAStreamInventedOverSilenceAreDrawnThenTakenBack() async {
        let run = await replay(over: writer(seconds: 1, amplitude: 0.001))

        XCTAssertTrue(run.overlay.contains { $0.text == "Hello there." })
        XCTAssertEqual(run.overlay.last?.text, "")
        XCTAssertEqual(run.document, "")
        XCTAssertEqual(run.stop, .noSpeech)
    }

    func testWordsOverASegmentTooShortToBeSpeechAreTakenBack() async {
        let run = await replay(over: writer(seconds: 0.2, amplitude: 0.5))

        XCTAssertEqual(run.overlay.last?.text, "")
        XCTAssertEqual(run.document, "")
        XCTAssertEqual(run.stop, .noSpeech)
    }

    func testAnAudibleSegmentIsPasted() async {
        let run = await replay(over: writer(seconds: 1, amplitude: 0.5))

        XCTAssertEqual(run.document, "Hello there. ")
    }
}

// MARK: - Recogniser failures (RecognitionSession.swift)

final class RecognitionFailureTests: XCTestCase {

    private func apple(domain: String = "kLSRErrorDomain", code: Int = 102,
                       description: String = "Failed to access assets",
                       hasText: Bool = false, permissionDenied: Bool = false,
                       locale: String = "en") -> RecognitionFailure? {
        RecognitionFailure.apple(domain: domain, code: code, description: description,
                                 hasText: hasText, permissionDenied: permissionDenied,
                                 locale: locale)
    }

    /// the on-device recogniser failed 44 ms in, and the overlay listened for 12 s.
    func testAFailureBeforeAnyTextEndsTheRecording() throws {
        let failure = try XCTUnwrap(apple())

        XCTAssertTrue(failure.endsRecording)
        XCTAssertEqual(failure.message,
                       "Couldn't load the English speech model. Add it to Dictation in System Settings › Keyboard.")
    }

    /// Nothing that was already recognised is thrown away, and Apple's 50 s rotation
    /// opens a fresh task: the recording goes on, as before.
    func testAFailureAfterTextLetsTheRecordingGoOn() throws {
        let failure = try XCTUnwrap(apple(hasText: true))

        XCTAssertFalse(failure.endsRecording)
        XCTAssertTrue(failure.message.contains("English speech model"),
                      "still explained should the segment come back with no words after all")
    }

    /// A rotation, a stop and `cancel()` all cancel a task — in whichever domain.
    func testACancellationIsNotAFailure() {
        XCTAssertNil(apple(domain: "kAFAssistantErrorDomain", code: 216, description: "Canceled"))
        XCTAssertNil(apple(domain: "kLSRErrorDomain", code: 216, description: "Canceled"))
        XCTAssertNil(apple(domain: "kAFAssistantErrorDomain", code: 216, hasText: true))
    }

    /// Only a cause the error names is explained; anything else keeps the recogniser's
    /// own words — and still ends a recording that has no text.
    func testAnotherErrorKeepsItsOwnWords() throws {
        let noSpeech = try XCTUnwrap(apple(domain: "kAFAssistantErrorDomain", code: 1110,
                                           description: "No speech detected"))
        XCTAssertEqual(noSpeech.message, "No speech detected")
        XCTAssertTrue(noSpeech.endsRecording)

        let sameCodeOtherDomain = try XCTUnwrap(apple(domain: "kAFAssistantErrorDomain", code: 102,
                                                      description: "Something else"))
        XCTAssertEqual(sameCodeOtherDomain.message, "Something else")
    }

    /// The permission is read, not inferred — and when it is off, that is the remedy,
    /// whatever the error said.
    func testADeniedPermissionIsWhatTheUserIsTold() throws {
        let failure = try XCTUnwrap(apple(permissionDenied: true))

        XCTAssertEqual(failure.message, RecognitionFailure.speechPermissionMessage)
        XCTAssertTrue(failure.endsRecording)
        XCTAssertEqual(RecognitionSessionError.speechPermissionDenied.errorDescription,
                       RecognitionFailure.speechPermissionMessage,
                       "the start refuses with the same words")
    }

    /// Apple is handed a regional locale; the notice names the language, in English
    /// whatever the Mac's own language is.
    func testTheLanguageIsNamedInEnglishFromAnyLocaleSpelling() {
        XCTAssertEqual(RecognitionFailure.languageName("en"), "English")
        XCTAssertEqual(RecognitionFailure.languageName("en-US"), "English")
        XCTAssertEqual(RecognitionFailure.languageName("en_GB"), "English")
        XCTAssertEqual(RecognitionFailure.languageName("uk-UA"), "Ukrainian")
    }

    /// The status notice's detail is two lines (`StatusOverlayView`: `lineLimit(2)`, 11 pt,
    /// 340 pt panel less 2 × 16 padding, the 24 pt icon and 12 spacing): past them the
    /// remedy is what gets cut. Measured as laid out, not counted in characters. And
    /// `AppState.friendlySTTError` rewrites a message containing an HTTP status or a
    /// network word, so none may appear in these.
    func testEveryExplanationFitsTheNoticeAndPassesThroughUnchanged() throws {
        var messages = [RecognitionFailure.speechPermissionMessage]
        for language in spokenLanguageCatalog {
            messages.append(try XCTUnwrap(apple(locale: language.localeIdentifier)).message)
        }
        func laidOutHeight(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11)])
                .boundingRect(with: NSSize(width: 272, height: CGFloat.greatestFiniteMagnitude),
                              options: .usesLineFragmentOrigin).height
        }
        // Two lines as the same layout measures them, rather than a font metric that
        // rounds differently.
        let twoLines = laidOutHeight("Ag\nAg")
        XCTAssertLessThan(twoLines, laidOutHeight("Ag\nAg\nAg"))
        for message in messages {
            XCTAssertLessThanOrEqual(laidOutHeight(message), twoLines, message)
            for token in ["413", "429", "401", "403", "-1001", "-1009", "too large", "timed out", "offline"] {
                XCTAssertFalse(message.localizedCaseInsensitiveContains(token), message)
            }
        }
    }
}

// MARK: - Provider error text

final class ProviderErrorMessageTests: XCTestCase {

    /// The reply that reached the user whole when a short segment failed to upload.
    func testOpenAIsMessageIsKeptAndTheJSONIsNot() {
        let body = """
        {"error":{"message":"Audio file might be corrupted or unsupported","type":"invalid_request_error","param":"file","code":"invalid_value"}}
        """
        XCTAssertEqual(TranscriptionError.httpError(.openAI, 400, body).errorDescription,
                       "OpenAI couldn't transcribe the recording: Audio file might be corrupted or unsupported. (HTTP 400)")
    }

    func testElevenLabsDetailShapes() {
        XCTAssertEqual(providerErrorMessage(vendor: "ElevenLabs", status: 401,
                                            body: #"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#),
                       "ElevenLabs couldn't transcribe the recording: Invalid API key. (HTTP 401)")
        XCTAssertEqual(providerErrorMessage(vendor: "ElevenLabs", status: 422,
                                            body: #"{"detail":[{"loc":["body","file"],"msg":"field required"}]}"#),
                       "ElevenLabs couldn't transcribe the recording: field required. (HTTP 422)")
    }

    func testABodyThatSaysNothingFallsBackToTheStatus() {
        XCTAssertEqual(TranscriptionError.httpError(.groq, 502, "<html>Bad Gateway</html>").errorDescription,
                       "Groq couldn't transcribe the recording: the service is having problems. (HTTP 502)")
        XCTAssertEqual(providerErrorMessage(vendor: "Groq", status: 429, body: ""),
                       "Groq couldn't transcribe the recording: too many requests — try again in a moment. (HTTP 429)")
    }
}

// MARK: - Microphone choice

final class MicrophoneChoiceTests: XCTestCase {
    private let builtIn = AudioInputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)
    private let airPods = AudioInputDevice(uid: "34-0E-22-ED-33-5E:input", name: "AirPods Pro", transport: .bluetooth)
    private let usb = AudioInputDevice(uid: "AppleUSBAudioEngine:Yeti", name: "Yeti", transport: .usb)
    private let iPhone = AudioInputDevice(uid: "iPhone-continuity", name: "iPhone Microphone", transport: .other)

    func testTheStoredValueRoundTrips() {
        for choice in [MicrophoneChoice.automatic, .systemDefault, .device(uid: airPods.uid)] {
            XCTAssertEqual(MicrophoneChoice(stored: choice.stored), choice)
        }
        XCTAssertEqual(MicrophoneChoice(stored: ""), .automatic, "an install that never chose is Automatic")
    }

    func testAutomaticRecordsWithTheMacInsteadOfBluetoothHeadphones() {
        let resolution = MicrophoneResolution.resolve(.automatic, devices: [builtIn, airPods], defaultUID: airPods.uid)
        XCTAssertEqual(resolution.device, builtIn)
        XCTAssertEqual(resolution.avoided, airPods)
    }

    func testAutomaticKeepsTheHeadphonesWhenTheLidIsClosed() {
        var closed = builtIn
        closed.canHear = false
        let resolution = MicrophoneResolution.resolve(.automatic, devices: [closed, airPods], defaultUID: airPods.uid)
        XCTAssertNil(resolution.device, "a closed lid's microphone records silence")
        XCTAssertNil(resolution.avoided)
    }

    func testAutomaticKeepsTheHeadphonesOnAMacWithNoMicrophoneOfItsOwn() {
        let resolution = MicrophoneResolution.resolve(.automatic, devices: [iPhone, airPods], defaultUID: airPods.uid)
        XCTAssertNil(resolution.device, "only the Mac's own microphone stands in — never an iPhone")
    }

    func testAutomaticLeavesEveryOtherSystemInputAlone() {
        for current in [builtIn, usb, iPhone] {
            let resolution = MicrophoneResolution.resolve(.automatic, devices: [builtIn, usb, iPhone, airPods],
                                                          defaultUID: current.uid)
            XCTAssertNil(resolution.device, "\(current.name) is used as the system has it")
        }
        XCTAssertNil(MicrophoneResolution.resolve(.automatic, devices: [], defaultUID: nil).device)
    }

    func testSystemDefaultNeverSubstitutes() {
        let resolution = MicrophoneResolution.resolve(.systemDefault, devices: [builtIn, airPods], defaultUID: airPods.uid)
        XCTAssertEqual(resolution, MicrophoneResolution())
    }

    func testAPickedDeviceIsUsedEvenWhenItIsTheHeadphones() {
        let resolution = MicrophoneResolution.resolve(.device(uid: airPods.uid), devices: [builtIn, airPods],
                                                      defaultUID: airPods.uid)
        XCTAssertEqual(resolution.device, airPods)
        XCTAssertNil(resolution.avoided)
        XCTAssertFalse(resolution.pickedIsMissing)
    }

    func testAPickedDeviceStaysWhenTheDefaultMoves() {
        let resolution = MicrophoneResolution.resolve(.device(uid: usb.uid), devices: [builtIn, usb, airPods],
                                                      defaultUID: airPods.uid)
        XCTAssertEqual(resolution.device, usb)
    }

    func testAPickedDeviceThatIsNotConnectedFallsBackToAutomatic() {
        let resolution = MicrophoneResolution.resolve(.device(uid: usb.uid), devices: [builtIn, airPods],
                                                      defaultUID: airPods.uid)
        XCTAssertEqual(resolution.device, builtIn)
        XCTAssertEqual(resolution.avoided, airPods)
        XCTAssertTrue(resolution.pickedIsMissing)
    }
}

// MARK: - LevelNormalizer

/// The level meter's automatic gain: what it draws for a voice must not depend on how
/// far the microphone is from the mouth.
final class LevelNormalizerTests: XCTestCase {
    /// One tap buffer: 1024 frames at 48 kHz.
    private let seconds = 1024.0 / 48_000

    /// Feeds `duration` seconds of buffers whose loudness `rms(t)` gives, and returns
    /// each buffer's mean display height.
    private func run(_ normalizer: inout LevelNormalizer, for duration: Double,
                     rms: (Double) -> Float) -> [CGFloat] {
        var heights: [CGFloat] = []
        var t = 0.0
        while t < duration {
            let levels = normalizer.levels(rms: Array(repeating: rms(t), count: 12), seconds: seconds)
            heights.append(levels.reduce(0, +) / CGFloat(levels.count))
            t += seconds
        }
        return heights
    }

    /// Syllables at five a second, each 30 dB above the gap after it.
    private func speech(_ loudness: Float) -> (Double) -> Float {
        { t in t.truncatingRemainder(dividingBy: 0.2) < 0.12 ? loudness : loudness / 30 }
    }

    func testAQuietAndALoudMicrophoneDrawTheSameVoiceAlike() {
        var distant = LevelNormalizer()
        var headset = LevelNormalizer()
        // −40 dBFS on a MacBook half a metre away, −14 dBFS on a headset.
        let quiet = run(&distant, for: 3, rms: speech(0.01)).suffix(47)
        let loud = run(&headset, for: 3, rms: speech(0.2)).suffix(47)
        XCTAssertGreaterThan(quiet.max()!, 0.9)
        XCTAssertGreaterThan(loud.max()!, 0.9)
        XCTAssertEqual(quiet.max()!, loud.max()!, accuracy: 0.05)
    }

    func testAQuietVoiceShowsFromItsFirstSyllable() {
        var normalizer = LevelNormalizer()
        let first = run(&normalizer, for: 0.1, rms: { _ in 0.01 })
        XCTAssertGreaterThan(first.first!, 0.4)
    }

    func testLouderStillRisesHigherThanQuieter() {
        var normalizer = LevelNormalizer()
        _ = run(&normalizer, for: 2, rms: speech(0.05))
        let loud = normalizer.levels(rms: Array(repeating: 0.05, count: 12), seconds: seconds)[0]
        let softer = normalizer.levels(rms: Array(repeating: 0.0125, count: 12), seconds: seconds)[0]
        XCTAssertGreaterThan(softer, 0.1)
        XCTAssertGreaterThan(loud - softer, 0.2)
    }

    func testARoomWithNobodySpeakingStaysDark() {
        var normalizer = LevelNormalizer()
        // Room noise flickering between −62 and −58 dBFS.
        let hiss = run(&normalizer, for: 5, rms: { t in Int(t / self.seconds) % 2 == 0 ? 0.0008 : 0.00126 })
        XCTAssertLessThan(hiss.suffix(100).max()!, 0.05)
        var muted = LevelNormalizer()
        XCTAssertEqual(run(&muted, for: 1, rms: { _ in 0 }).max(), 0)
    }

    func testTheScaleFollowsADeviceThatGoesQuieter() {
        var normalizer = LevelNormalizer()
        _ = run(&normalizer, for: 3, rms: speech(0.2))
        let after = run(&normalizer, for: 6, rms: speech(0.01)).suffix(47)
        XCTAssertGreaterThan(after.max()!, 0.9)
    }
}

// MARK: - The usage ledger

/// Answers as a vendor would, with what it says it billed.
private final class MeteredBatchTranscriber: BatchTranscriber, @unchecked Sendable {
    let answer: Result<Transcription, Error>
    let meter: UsageMeter?
    init(_ answer: Result<Transcription, Error>, meter: UsageMeter?) {
        self.answer = answer
        self.meter = meter
    }
    func transcribe(audioFileURL: URL, language: String?) async throws -> String {
        XCTFail("the metered call is the one a session makes")
        return try answer.get().text
    }
    func transcribeMetered(audioFileURL: URL, language: String?) async throws -> Transcription {
        try answer.get()
    }
}

/// What each request a segment makes leaves in History's ledger — the units Usage counts
/// and prices, written whatever the request's answer was.
@MainActor
final class UsageLedgerTests: XCTestCase {
    private let groq = UsageMeter(vendor: .groq, model: "whisper-large-v3-turbo", minimumBilledSeconds: 10)

    private func writer(seconds: Double, amplitude: Float = 0.5) -> AudioBufferWriter {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        for _ in 0 ..< Int((seconds / 0.1).rounded()) {
            writer.append(makeSineBuffer(format: mono48k(), frames: 4_800, amplitude: amplitude))
        }
        return writer
    }

    private func upload(_ answer: Result<Transcription, Error>, meter: UsageMeter?, seconds: Double = 1,
                        amplitude: Float = 0.5) async -> RecognitionOutcome {
        let session = BatchRecognitionSession(provider: MeteredBatchTranscriber(answer, meter: meter),
                                              writer: writer(seconds: seconds, amplitude: amplitude), language: nil, languages: [])
        let outcome = await session.finish()
        outcome.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:))
        return outcome
    }

    /// Declared on the protocol, so a transcriber's own metered call is the one that runs
    /// through `any BatchTranscriber` — an extension-only default would always win.
    func testAVendorsOwnMeteringIsWhatTheProtocolCalls() async throws {
        let transcriber: any BatchTranscriber = MeteredBatchTranscriber(
            .success(Transcription(text: "hi", billing: SpeechBilling(seconds: 3))), meter: groq)
        let result = try await transcriber.transcribeMetered(audioFileURL: URL(fileURLWithPath: "/dev/null"), language: nil)
        XCTAssertEqual(result.billing?.seconds, 3)
        XCTAssertEqual(transcriber.meter, groq)
    }

    func testAnUploadIsBilledAtTheVendorsFigureElseItsDocumentedMinimum() async throws {
        let reported = await upload(.success(Transcription(text: "текст", billing: SpeechBilling(seconds: 12))), meter: groq)
        let event = try XCTUnwrap(reported.usage.first)
        XCTAssertEqual(reported.usage.count, 1)
        XCTAssertEqual(event.kind, .upload)
        XCTAssertEqual(event.vendor, .groq)
        XCTAssertEqual(event.model, "whisper-large-v3-turbo")
        XCTAssertTrue(event.succeeded)
        XCTAssertEqual(try XCTUnwrap(event.audioSeconds), 1, accuracy: 0.05)
        XCTAssertEqual(event.billedSeconds, 12, "the vendor's figure wins")

        let silentVendor = await upload(.success(Transcription(text: "текст")), meter: groq)
        XCTAssertEqual(silentVendor.usage.first?.billedSeconds, 10, "Groq bills ten seconds at least")

        let noRule = await upload(.success(Transcription(text: "текст")),
                                  meter: UsageMeter(vendor: .elevenLabs, model: "scribe_v2", keyterms: 3))
        XCTAssertNil(noRule.usage.first?.billedSeconds, "unknown, never guessed")
        XCTAssertEqual(noRule.usage.first?.keyterms, 3)
    }

    /// A reply dropped as a hallucination, or a refusal, was still a request.
    func testARequestIsInTheLedgerWhateverItsAnswer() async {
        let hallucinated = await upload(.success(Transcription(text: "Thank you for watching!")), meter: groq)
        XCTAssertEqual(hallucinated.text, "")
        XCTAssertEqual(hallucinated.usage.map(\.succeeded), [true])

        let refused = await upload(.failure(TranscriptionError.httpError(.groq, 401, "{}")), meter: groq)
        XCTAssertEqual(refused.usage.map(\.succeeded), [false])
        XCTAssertNil(refused.usage.first?.billedSeconds, "an error reply is not taken as billed")

        let offline = await upload(.failure(URLError(.notConnectedToInternet)), meter: groq)
        XCTAssertTrue(offline.offline)
        XCTAssertEqual(offline.usage, [], "a request that reached no network reached no vendor")
    }

    func testWhatIsNeverSentLeavesNoEntry() async {
        let silent = await upload(.success(Transcription(text: "текст")), meter: groq, amplitude: 0.001)
        XCTAssertEqual(silent.usage, [], "a silent segment is not uploaded")

        let local = await upload(.success(Transcription(text: "текст")), meter: nil)
        XCTAssertEqual(local.text, "текст")
        XCTAssertEqual(local.usage, [], "a model on this Mac bills nobody")
    }

    /// A stream that fell back was paid for twice: the socket and the upload.
    func testAStreamAndTheUploadThatReplacedItAreTwoEntries() async {
        let realtime = UsageMeter(vendor: .elevenLabs, model: "scribe_v2_realtime")

        let provider = ScriptedStreamingTranscriber()
        provider.eventsAtFinish = [.committed("Hello there.")]
        let kept = StreamingRecognitionSession(provider: provider, writer: writer(seconds: 1), languages: [],
                                               fallback: ScriptedSegment(error: "no fallback expected"), meter: realtime)
        try! kept.start()
        let streamed = await kept.finish()
        XCTAssertEqual(streamed.text, "Hello there.")
        XCTAssertEqual(streamed.usage.map(\.kind), [.stream])
        XCTAssertEqual(streamed.usage.first?.model, "scribe_v2_realtime")
        XCTAssertEqual(streamed.usage.first?.succeeded, true)

        let broken = ScriptedStreamingTranscriber()
        broken.eventsAtFinish = [.failed(StreamBroke())]
        let upload = MeteredBatchTranscriber(.success(Transcription(text: "Hello there.", billing: SpeechBilling(seconds: 1))),
                                             meter: UsageMeter(vendor: .elevenLabs, model: "scribe_v2"))
        let audio = writer(seconds: 1)
        let fellBack = StreamingRecognitionSession(provider: broken, writer: audio, languages: [],
                                                   fallback: BatchRecognitionSession(provider: upload, writer: audio, language: nil, languages: []),
                                                   meter: realtime)
        try! fellBack.start()
        let answer = await fellBack.finish()
        answer.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:))
        XCTAssertEqual(answer.text, "Hello there.")
        XCTAssertEqual(answer.usage.map(\.kind), [.stream, .upload])
        XCTAssertEqual(answer.usage.map(\.model), ["scribe_v2_realtime", "scribe_v2"])
        XCTAssertEqual(answer.usage.map(\.succeeded), [false, true], "the socket broke")

        let silent = ScriptedStreamingTranscriber()
        let quietAudio = writer(seconds: 1)
        let emptied = StreamingRecognitionSession(provider: silent, writer: quietAudio, languages: [],
                                                  fallback: BatchRecognitionSession(provider: upload, writer: quietAudio, language: nil, languages: []),
                                                  meter: realtime)
        try! emptied.start()
        let replaced = await emptied.finish()
        replaced.audioFileURL.map(AudioBufferWriter.cleanup(fileURL:))
        XCTAssertEqual(replaced.usage.map(\.kind), [.stream, .upload])
        XCTAssertEqual(replaced.usage.map(\.succeeded), [true, true],
                       "a stream that answered with nothing was not refused — only paid for twice")
    }

    /// The shapes the upload endpoints answer with.
    func testTheVendorsBillingIsReadFromTheirOwnReplies() {
        func decode(_ json: String) -> SpeechBilling? { SpeechBilling.decode(Data(json.utf8)) }
        XCTAssertEqual(decode(#"{"text":"hi","usage":{"type":"duration","seconds":7}}"#), SpeechBilling(seconds: 7))
        XCTAssertEqual(decode(#"{"text":"hi","usage":{"type":"tokens","input_tokens":120,"input_token_details":{"audio_tokens":110,"text_tokens":10},"output_tokens":8,"total_tokens":128}}"#),
                       SpeechBilling(tokens: ChatUsage(inputTokens: 120, outputTokens: 8)))
        XCTAssertEqual(decode(#"{"language_code":"ukr","text":"привіт","audio_duration_secs":4.25,"transcription_id":"t"}"#),
                       SpeechBilling(seconds: 4.25))
        XCTAssertNil(decode(#"{"text":"hi","x_groq":{"id":"req"}}"#))
        XCTAssertNil(decode("not json"))
    }
}

/// The ledger as History stores it and Usage prices it.
final class UsageLedgerPricingTests: XCTestCase {
    private let now = Date()

    private func record(provider: String = "elevenlabs", duration: TimeInterval = 60, events: [UsageEvent]?,
                        refinement: TranscriptionRecord.Refinement? = nil) -> TranscriptionRecord {
        var record = TranscriptionRecord(id: UUID(), date: now, text: "hello there olena", status: .success,
                                         errorMessage: nil, provider: provider, locale: "uk", duration: duration,
                                         audioFileName: nil, usageEvents: events)
        record.refinement = refinement
        return record
    }

    private func speech(_ kind: UsageEvent.Kind, _ vendor: Provider, model: String? = nil, seconds: Double,
                        billed: Double? = nil, keyterms: Int? = nil) -> UsageEvent {
        UsageEvent(date: now, kind: kind, vendor: vendor, model: model ?? vendor.defaultSpeechModel, succeeded: true,
                   audioSeconds: seconds, billedSeconds: billed, keyterms: keyterms)
    }

    private func perMinute(_ vendor: Provider, _ model: String) throws -> Double {
        try XCTUnwrap(UsagePrices.speech(vendor: vendor, model: model).listed?.perMinute)
    }

    /// History stores the vendor's and the kind's raw values; a rename is a migration.
    func testTheLedgerKeepsItsStoredNames() throws {
        let event = UsageEvent(date: Date(timeIntervalSince1970: 0), kind: .stream, vendor: .elevenLabs,
                               model: "scribe_v2_realtime", succeeded: true, audioSeconds: 2)
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertTrue(json.contains(#""vendor":"elevenLabs""#), json)
        XCTAssertTrue(json.contains(#""kind":"stream""#), json)
        XCTAssertEqual(Provider.allCases.map(\.rawValue),
                       ["apple", "groq", "elevenLabs", "anthropic", "openAI", "local", "ollama"])
        XCTAssertEqual([UsageEvent.Kind.upload, .stream, .retry, .rewrite, .edit].map(\.rawValue),
                       ["upload", "stream", "retry", "rewrite", "edit"])
    }

    func testARecordFromBeforeTheLedgerStillDecodes() throws {
        let old = try JSONDecoder().decode(TranscriptionRecord.self, from: Data("""
            {"id":"\(UUID().uuidString)","date":0,"text":"hi","status":"success","provider":"groq","duration":3}
            """.utf8))
        XCTAssertNil(old.usageEvents)
    }

    /// Every request is priced: the socket and the upload that replaced it, at the billed
    /// seconds where the vendor reported them.
    func testALedgerIsPricedFromItsEntriesAlone() throws {
        let realtime = try perMinute(.elevenLabs, "scribe_v2_realtime")
        let elevenLabs = try perMinute(.elevenLabs, "scribe_v2")
        let groq = try perMinute(.groq, "whisper-large-v3-turbo")
        XCTAssertNotEqual(realtime, elevenLabs, "each model at its own price")
        let cost = RecordCost(record(events: [speech(.stream, .elevenLabs, model: "scribe_v2_realtime", seconds: 30),
                                              speech(.upload, .elevenLabs, seconds: 30, billed: 31),
                                              speech(.retry, .groq, seconds: 3, billed: 10)]))
        XCTAssertEqual(cost.speech, 30 / 60 * realtime + 31 / 60 * elevenLabs + 10 / 60 * groq, accuracy: 1e-12)

        XCTAssertEqual(RecordCost(record(events: [])).total, 0, "nothing sent, nothing spent — not the minute it lasted")
        var old = record(events: nil)
        old.sttModel = "scribe_v2"
        XCTAssertEqual(RecordCost(old).speech, elevenLabs, accuracy: 1e-12,
                       "a record from before the ledger is priced by its length at its model's price")
        let unnamed = RecordCost(record(events: nil))
        XCTAssertEqual(unnamed.speech, 0, "Scribe's models differ, and this record names neither: not guessed")
        XCTAssertEqual(unnamed.unpricedSpeech, ["ElevenLabs"])
        XCTAssertEqual(RecordCost(record(provider: "local", events: nil)).unpricedSpeech, [], "every local model is free")
    }

    /// Scribe bills keyterm prompting per hour on top of the audio; OpenAI's keywords cost
    /// nothing extra.
    func testKeytermsAddTheirSurchargeWhereTheVendorBillsOne() throws {
        let plain = RecordCost(record(events: [speech(.upload, .elevenLabs, seconds: 3600)])).speech
        let withTerms = RecordCost(record(events: [speech(.upload, .elevenLabs, seconds: 3600, keyterms: 12)])).speech
        XCTAssertEqual(plain, 0.22, accuracy: 1e-9)
        XCTAssertEqual(withTerms, 0.22 + 0.05, accuracy: 1e-9)
        let stream = RecordCost(record(events: [speech(.stream, .elevenLabs, model: "scribe_v2_realtime",
                                                       seconds: 3600, keyterms: 3)])).speech
        XCTAssertEqual(stream, 0.39 + 0.08, accuracy: 1e-9)
        let openAI = RecordCost(record(provider: "openai", events: [speech(.upload, .openAI, seconds: 60, keyterms: 5)]))
        XCTAssertEqual(openAI.speech, 0.0045, accuracy: 1e-12)
    }

    /// A retry clears the pass it replaced, not what the pass cost.
    func testARewriteIsPricedFromTheLedgerAfterItsPassIsCleared() throws {
        let pass = TranscriptionRecord.Refinement(inputText: "hello", outputText: "Hello.", presetName: nil,
                                                  provider: "anthropic", model: "claude-sonnet-5",
                                                  usage: ChatUsage(inputTokens: 2000, outputTokens: 40))
        let event = try XCTUnwrap(TranscriptionHistory.chatEvent(for: pass, latency: 1.2, date: now))
        XCTAssertEqual(event.kind, .rewrite)
        XCTAssertEqual(event.vendor, .anthropic)
        XCTAssertEqual(event.latency, 1.2)

        let price = try XCTUnwrap(UsagePrices.chat(provider: "anthropic", model: "claude-sonnet-5").listed)
        let cleared = RecordCost(record(provider: "apple", events: [event], refinement: nil))
        XCTAssertEqual(cleared.ai, price.cost(ChatUsage(inputTokens: 2000, outputTokens: 40)), accuracy: 1e-12)
        let withPass = RecordCost(record(provider: "apple", events: [event], refinement: pass))
        XCTAssertEqual(withPass.ai, cleared.ai, accuracy: 1e-12, "priced once, from the ledger, not again from the pass")
        XCTAssertEqual(withPass.estimatedAIPasses, 0)

        var noReply = pass
        noReply.usage = nil
        noReply.outputText = ""
        noReply.errorMessage = "HTTP 500"
        XCTAssertEqual(TranscriptionHistory.chatEvent(for: noReply, latency: nil)?.succeeded, false)
        XCTAssertEqual(TranscriptionHistory.chatEvent(for: noReply, latency: nil)?.kind, .rewrite)
    }

    /// A token-billed transcription is still speech: priced by its audio, never as a chat model.
    func testASpeechRequestIsPricedAsSpeechWhateverItsReplyCarried() throws {
        let groq = try perMinute(.groq, "whisper-large-v3-turbo")
        var upload = speech(.upload, .groq, seconds: 60)
        upload.tokens = ChatUsage(inputTokens: 900, outputTokens: 20)
        let cost = RecordCost(record(provider: "groq", events: [upload]))
        XCTAssertEqual(cost.speech, groq, accuracy: 1e-12)
        XCTAssertEqual(cost.ai, 0)
        XCTAssertEqual(cost.unpricedChat, [])
    }

    /// A refused upload or retry was not billed; a socket was used whatever it answered.
    func testARefusedRequestCostsNothingAndAStreamCostsItsAudio() throws {
        let elevenLabs = try perMinute(.elevenLabs, "scribe_v2")
        let realtime = try perMinute(.elevenLabs, "scribe_v2_realtime")
        let refused = UsageEvent(date: now, kind: .retry, vendor: .elevenLabs, model: "scribe_v2", succeeded: false,
                                 audioSeconds: 60)
        XCTAssertEqual(RecordCost(record(events: [refused, refused])).speech, 0)

        let broken = UsageEvent(date: now, kind: .stream, vendor: .elevenLabs, model: "scribe_v2_realtime",
                                succeeded: false, audioSeconds: 30)
        let cost = RecordCost(record(events: [broken, speech(.upload, .elevenLabs, seconds: 30)]))
        XCTAssertEqual(cost.speech, (realtime + elevenLabs) / 2, accuracy: 1e-12,
                       "the broken socket and its upload, half a minute each")
    }

    func testAnEnginesUnpricedRequestsAreNamedNotGuessed() {
        let cost = RecordCost(record(events: [speech(.upload, .openAI, model: "gpt-9-transcribe", seconds: 60)]))
        XCTAssertEqual(cost.speech, 0)
        XCTAssertEqual(cost.unpricedSpeech, ["gpt-9-transcribe"], "an ID the catalogue does not list is named, not priced as another")
    }
}

// MARK: - The stop's flush and a late tap buffer

/// What the appending thread saw, read by the test once it has finished.
private final class LateAppends: @unchecked Sendable {
    private let lock = NSLock()
    private var writeDone = false
    private var late: [Data?] = []

    var hasWritten: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writeDone
    }

    func markWritten() {
        lock.lock()
        writeDone = true
        lock.unlock()
    }

    func record(_ pcm: Data?) {
        lock.lock()
        late.append(pcm)
        lock.unlock()
    }

    var results: [Data?] {
        lock.lock()
        defer { lock.unlock() }
        return late
    }
}

final class AudioBufferWriterStopTests: XCTestCase {

    /// The stop is queued on `engineQueue` and its task writes the file at once
    /// (`SpeechEngine.stopAudioEngine`), so a tap callback can still be inside `append`
    /// while `writeAudioFile` flushes the converter. Two threads driving one
    /// `AVAudioConverter` corrupt it; a buffer that arrives once the flush has begun is
    /// after the stop, and is dropped — never converted, never kept.
    func testATapBufferDuringTheStopsFlushNeverReachesTheConverter() throws {
        let writer = AudioBufferWriter()
        writer.prepare(sourceFormat: mono48k())
        // Read, never written, by the thread below, which is what makes the unchecked
        // hand-off safe.
        nonisolated(unsafe) let buffer = makeSineBuffer(format: mono48k(), frames: 4_800)
        let appends = LateAppends()
        let running = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            // Bounded by time, since how long the write takes is not ours to know; done
            // once twenty buffers have arrived after the file was written. Paced once the
            // write may have begun, so a converter that kept taking buffers after the
            // flush cannot fill the memory while the test waits.
            let deadline = Date().addingTimeInterval(20)
            var index = 0
            while Date() < deadline {
                let afterWrite = appends.hasWritten
                let pcm = writer.append(buffer)
                if afterWrite {
                    appends.record(pcm)
                    if appends.results.count == 20 { break }
                }
                index += 1
                if index == 20 { running.signal() }
                if index > 20 { Thread.sleep(forTimeInterval: 0.0005) }
            }
            done.signal()
        }

        running.wait()
        let url = try writer.writeAudioFile()
        defer { AudioBufferWriter.cleanup(fileURL: url) }
        appends.markWritten()
        let written = writer.bufferedDuration
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success, "the appending thread never finished")

        XCTAssertFalse(appends.results.isEmpty, "no buffer arrived after the write")
        XCTAssertTrue(appends.results.allSatisfy { $0 == nil }, "a buffer after the stop was converted")
        XCTAssertEqual(writer.bufferedDuration, written, "a buffer after the stop was kept")

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(Int(file.length), Int((written * AudioBufferWriter.uploadSampleRate).rounded()),
                       "the file holds exactly what the writer kept")
    }
}

// MARK: - A failed write leaves nothing behind

final class AudioBufferWriterFailedWriteTests: XCTestCase {

    private struct EncoderRefused: Error {}

    /// An attempt that writes part of a file and then throws.
    private func halfWrite(_ url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: 64))
        throw EncoderRefused()
    }

    /// Both encodings failing — likely on the mixed path, whose native tail already failed
    /// once — left the WAV attempt's half-written file in the temp folder: the user's
    /// speech, with no History row pointing at it.
    func testBothEncodingsFailingLeaveNoFileBehind() {
        var attempts: [URL] = []
        XCTAssertThrowsError(try AudioBufferWriter.writeWithCodecFallback(preferred: .flac) { _, url in
            attempts.append(url)
            try halfWrite(url)
        })

        XCTAssertEqual(attempts.map(\.pathExtension), ["flac", "wav"])
        for url in attempts {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) was left behind")
        }
    }

    /// A recording under one FLAC block is written as WAV to begin with: its one attempt.
    func testAShortRecordingsFailedWAVLeavesNoFileBehind() {
        var attempts: [URL] = []
        XCTAssertThrowsError(try AudioBufferWriter.writeWithCodecFallback(preferred: .wav) { _, url in
            attempts.append(url)
            try halfWrite(url)
        })

        XCTAssertEqual(attempts.map(\.pathExtension), ["wav"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: attempts[0].path))
    }

    func testAWAVThatSucceedsAfterAFailedFLACIsTheOnlyFileLeft() throws {
        var attempts: [URL] = []
        let url = try AudioBufferWriter.writeWithCodecFallback(preferred: .flac) { codec, url in
            attempts.append(url)
            if codec == .flac { try halfWrite(url) }
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 2, count: 64))
        }
        defer { AudioBufferWriter.cleanup(fileURL: url) }

        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(url, attempts[1])
        XCTAssertEqual(url.pathExtension, "wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: attempts[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - An error after text

@MainActor
final class ErrorAfterTextTests: XCTestCase {

    /// Apple's recogniser can answer the stop's `endAudio()` on a chunk that heard nothing
    /// after a rotation with "No speech detected", with a minute of words already in the
    /// segment. Those words are pasted; the error made the dictation a failure, handed to
    /// the Record Window with "Transcription failed".
    func testWordsWithAnErrorAfterThemArePasted() {
        let flow = InlineDictationFlow(clean: cleanedTranscript)
        flow.live(committed: "First minute of words.", partial: "")
        let outcome = RecognitionOutcome(text: "First minute of words.", error: "No speech detected",
                                         audioFileURL: nil, cancelled: false)

        let (_, result) = flow.stop(outcome, aiMode: false)
        XCTAssertEqual(result, .paste("First minute of words."))
    }

    func testAnErrorWithNoWordsIsStillAFailure() {
        let flow = InlineDictationFlow(clean: cleanedTranscript)
        let outcome = RecognitionOutcome(text: "", error: "No speech detected", audioFileURL: nil, cancelled: false)

        let (_, result) = flow.stop(outcome, aiMode: false)
        XCTAssertEqual(result, .failed(partial: ""))
    }

    /// Words that cleanup removes are no words: the error explains the empty result.
    func testAnErrorAfterOnlyHesitationsIsStillAFailure() {
        let flow = InlineDictationFlow(clean: cleanedTranscript)
        let outcome = RecognitionOutcome(text: "е-е-е", error: "No speech detected", audioFileURL: nil, cancelled: false)

        let (cleaned, result) = flow.stop(outcome, aiMode: false)
        XCTAssertEqual(cleaned.text, "")
        XCTAssertEqual(result, .failed(partial: ""))
    }
}
