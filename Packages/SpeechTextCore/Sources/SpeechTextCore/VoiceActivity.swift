// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

// Voice activity detection: whether a segment's audio holds a human voice at all,
// asked before an upload and before a stream's answer is pasted. Keyboard typing and room
// noise are louder than `STTTuning.silencePeakFloor`, so they reached the engines, which
// answered «Thank you for watching.» or «so» — and that was pasted. A model that hears a
// voice in a window says so with a probability; this file decides what those mean, and
// the detector itself (Silero VAD, through FluidAudio) is registered at launch from
// `VoiceActivityRuntime.swift`, the way `LocalSTT` is — so this file stays in the test
// subset and the test bundle never sees FluidAudio.

/// Turns a segment's 16 kHz mono samples into one speech probability per window.
public protocol VoiceActivityDetector: AnyObject, Sendable {
    func speechProbabilities(_ samples: [Float]) async throws -> [Float]
}

/// What the detector said about one segment.
public struct VoiceActivityReading: Equatable, Sendable {
    /// The highest probability of any window.
    public var maxProbability: Float
    /// How many windows were above `STTTuning.voiceProbabilityThreshold`.
    public var windowsOverThreshold: Int
    /// How long the segment was.
    var segmentSeconds: Double
    /// From the first window with a voice in it to the last, each widened by one window
    /// (an onset or a trailing-off word often scores under the threshold), within the
    /// segment; nil when no window held a voice. What Usage counts as time spent
    /// speaking: the silence before the first word and after the last is the shortcut's,
    /// not the speaker's, while a pause between words stays — it is the thinking a typist
    /// does too.
    public var voicedSpanSeconds: Double?

    init(probabilities: [Float], segmentSeconds: Double) {
        maxProbability = probabilities.max() ?? 0
        windowsOverThreshold = probabilities.filter { $0 > STTTuning.voiceProbabilityThreshold }.count
        self.segmentSeconds = segmentSeconds
        // The window's length from the segment rather than the model's constant, so a
        // detector with other windows — or a last window padded out — measures alike.
        if let first = probabilities.firstIndex(where: { $0 > STTTuning.voiceProbabilityThreshold }),
           let last = probabilities.lastIndex(where: { $0 > STTTuning.voiceProbabilityThreshold }),
           segmentSeconds > 0 {
            let window = segmentSeconds / Double(probabilities.count)
            let start = max(0, Double(first - 1) * window)
            let end = min(segmentSeconds, Double(last + 2) * window)
            voicedSpanSeconds = end - start
        }
    }

    /// How many windows this segment needs: one for a short segment — a one-word
    /// dictation — and two for a longer one, where a single window is a spike of noise.
    var windowsRequired: Int {
        segmentSeconds <= STTTuning.voiceShortSegmentSeconds
            ? STTTuning.voiceWindowsRequiredWhenShort : STTTuning.voiceWindowsRequired
    }

    /// A voice was heard: at least `windowsRequired` windows over the threshold.
    var holdsSpeech: Bool { windowsOverThreshold >= windowsRequired }
}

public enum VoiceActivity {
    /// Set at launch by `registerVoiceActivity`, once the model has loaded; nil — the test
    /// bundle, or a model that would not load — lets every segment through, as before.
    /// Under a lock: the model loads in the background while a dictation may already ask.
    public static var detector: VoiceActivityDetector? {
        get { detectorLock.withLock { $0 } }
        set { detectorLock.withLock { $0 = newValue } }
    }
    private static let detectorLock = OSAllocatedUnfairLock<VoiceActivityDetector?>(initialState: nil)

    /// The detector's reading of what `writer` holds; nil when there is nothing to judge
    /// with — no detector, audio that was never converted (the native fallback, which is
    /// unmeasured and counts as speech, as it does for the silence guard), or a detector
    /// that failed. nil never drops anything.
    public static func read(_ writer: AudioBufferWriter) async -> VoiceActivityReading? {
        guard let samples = writer.convertedSamples else { return nil }
        return await read(samples)
    }

    /// The same for samples already taken from a writer — the engine's, for a segment
    /// Apple recognised, read after the writer itself has been reset.
    public static func read(_ samples: [Float]) async -> VoiceActivityReading? {
        guard let detector, !samples.isEmpty else { return nil }
        let start = Date()
        do {
            let reading = VoiceActivityReading(probabilities: try await detector.speechProbabilities(samples),
                                               segmentSeconds: Double(samples.count) / AudioBufferWriter.uploadSampleRate)
            dlog("Engine", String(format: "voice activity: max %.2f, %d windows over %.2f (%d needed for %.1f s), %.0f ms",
                                  reading.maxProbability, reading.windowsOverThreshold,
                                  STTTuning.voiceProbabilityThreshold, reading.windowsRequired,
                                  reading.segmentSeconds, Date().timeIntervalSince(start) * 1000))
            return reading
        } catch {
            dlog("Engine", "voice activity: the detector failed — the segment is kept: \(error.localizedDescription)", level: .error)
            return nil
        }
    }
}
