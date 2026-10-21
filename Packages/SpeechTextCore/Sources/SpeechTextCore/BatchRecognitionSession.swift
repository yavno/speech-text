// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AVFoundation

// MARK: - Batch upload

/// Writes the segment the engine's writer collected and uploads it. No live text.
@MainActor
public final class BatchRecognitionSession: RecognitionSession {
    public var onEvent: (@MainActor @Sendable (RecognitionEvent) -> Void)?

    private let provider: BatchTranscriber
    private let writer: AudioBufferWriter
    /// nil leaves the language to the model — see `RecordingConfiguration.cloudLanguage`.
    private let language: String?
    /// Every language the user stated, which the result's script is judged against
    /// (`HallucinationFilter.rejection`); empty judges no script.
    private let languages: [String]

    public nonisolated init(provider: BatchTranscriber, writer: AudioBufferWriter, language: String?, languages: [String]) {
        self.provider = provider
        self.writer = writer
        self.language = language
        self.languages = languages
    }

    /// Nothing to open.
    public func start() throws {}

    /// The engine's writer already has the audio.
    public nonisolated func feed(native: AVAudioPCMBuffer, pcm16: Data?) {}

    /// The segment's text needs the upload.
    public func pause() -> String? { nil }

    /// On failure the audio file is handed back rather than deleted, so the engine can
    /// archive it for a retry — a failed upload no longer means the speech is gone.
    public nonisolated func finish() async -> RecognitionOutcome {
        // Before the file is written: a press-and-release of the shortcut is not a
        // recording to archive, and a provider handed a fraction of a second answers
        // with an error (or, for Whisper, with a hallucinated sentence).
        let duration = writer.bufferedDuration
        if duration > 0, duration < STTTuning.minimumSegmentSeconds {
            dlog("Engine", "BatchRecognitionSession.finish: \(String(format: "%.2f", duration))s is too short to be speech — dropped")
            return .discarded
        }

        let fileURL: URL
        do {
            fileURL = try writer.writeAudioFile()
        } catch AudioBufferWriter.AudioBufferWriterError.noAudio {
            // A segment with no audio in it (a pause the instant after a resume) is an
            // empty result, not a failure: History would otherwise show it as an error
            // reading "No audio was recorded".
            dlog("Engine", "BatchRecognitionSession.finish: no audio in this segment")
            return RecognitionOutcome(text: "", error: nil, audioFileURL: nil, cancelled: Task.isCancelled)
        } catch {
            dlog("Engine", "BatchRecognitionSession.finish: could not write audio file: \(error.localizedDescription)", level: .error)
            return RecognitionOutcome(text: "", error: error.localizedDescription,
                                      audioFileURL: nil, cancelled: Task.isCancelled)
        }

        // After the file is written, so the segment is still archived for a History retry
        // should the guard ever be wrong about a very quiet voice.
        guard writer.hasAudibleSignal else {
            dlog("Engine", "BatchRecognitionSession.finish: the segment is silent — not uploaded")
            return RecognitionOutcome(text: "", error: nil, audioFileURL: fileURL, cancelled: Task.isCancelled)
        }
        // Audible, but no voice in it — keyboard, a fan, the street: not sent, so
        // not billed, and kept like a silent segment.
        let reading = await VoiceActivity.read(writer)
        if let reading, !reading.holdsSpeech {
            dlog("Engine", "BatchRecognitionSession.finish: no voice in the segment — not uploaded")
            return RecognitionOutcome(text: "", error: nil, audioFileURL: fileURL, cancelled: Task.isCancelled)
        }

        let meter = provider.meter
        let start = Date()
        func event(_ billing: SpeechBilling?, succeeded: Bool) -> [UsageEvent] {
            meter.map { [$0.event(.upload, audioSeconds: duration, billing: billing, succeeded: succeeded,
                                  latency: Date().timeIntervalSince(start), date: start)] } ?? []
        }
        do {
            dlog("Engine", "BatchRecognitionSession.finish: calling provider, language=\(language ?? "auto")…")
            let result = try await provider.transcribeMetered(audioFileURL: fileURL, language: language)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            dlog("Engine", "BatchRecognitionSession.finish: done, \(text.count) chars")
            let usage = event(result.billing, succeeded: true)
            if let rejection = HallucinationFilter.rejection(text, segmentSeconds: duration, languages: languages) {
                dlog("Engine", "BatchRecognitionSession.finish: the whole result of a \(String(format: "%.1f", duration))s segment is \(rejection) — dropped, audio kept")
                return RecognitionOutcome(text: "", error: nil, audioFileURL: fileURL, cancelled: false, usage: usage)
            }
            return RecognitionOutcome(text: text, error: nil, audioFileURL: fileURL, cancelled: false, usage: usage,
                                      speakingSeconds: reading?.voicedSpanSeconds)
        } catch {
            dlog("Engine", "BatchRecognitionSession.finish: error: \(error.localizedDescription)", level: .error)
            if Task.isCancelled {
                AudioBufferWriter.cleanup(fileURL: fileURL)
                return .cancelled
            }
            return RecognitionOutcome(text: "", error: error.localizedDescription,
                                      audioFileURL: fileURL, cancelled: false,
                                      offline: NetworkFailure.isOffline(error),
                                      modelUnavailable: (error as? TranscriptionError)?.isModelUnavailable == true,
                                      usage: NetworkFailure.isOffline(error) ? [] : event(nil, succeeded: false))
        }
    }

    /// The upload runs inside the engine's transcription task; cancelling that cancels
    /// the URLSession request.
    public func cancel() {}
}
