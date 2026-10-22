// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One inline dictation as the app saw it: the provider's events as they arrived, the
/// stop, the batch fallback's answer, the rewrite, and the stop's paste. Written by
/// `DictationTraceRecorder` when `recordDictationTraces` is on, and read back by the
/// test target's `DictationReplay`, which plays the events through the recognition code
/// again — so a dictation that went wrong once becomes a test that stays.
///
/// Flat and hand-editable on purpose: after reviewing a trace, set `expectedDocument` to
/// what the document *should* hold, and the replay checks that as well.
public struct DictationTrace: Codable, Equatable, Sendable {
    /// Traces recorded before the stop became the only paste also carry `aiDraft`, `livePreview` and `probe`, from
    /// when text could be pasted while the user spoke. The decoder ignores them.
    public struct Setup: Codable, Equatable, Sendable {
        var aiMode = false
        var removesDisfluencies = true
        /// Optional so a trace recorded before the setting existed still decodes; nil
        /// replays as `.emDash`, which is what those dictations were pasted with.
        var dashStyle: DashStyle?
        /// The app the dictation started in — for the reader.
        var app: String?
        /// The app in front at the stop, which the dictation was pasted into. Nil
        /// until the stop, and in traces recorded before it.
        var destination: String?

        public init(aiMode: Bool = false, removesDisfluencies: Bool = true, dashStyle: DashStyle? = nil,
                    app: String? = nil, destination: String? = nil) {
            self.aiMode = aiMode
            self.removesDisfluencies = removesDisfluencies
            self.dashStyle = dashStyle
            self.app = app
            self.destination = destination
        }
    }

    public struct Event: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// The provider's partial, as it arrived — before any merging.
            case partial
            /// The provider's committed segment, as it arrived.
            case committed
            /// The stream broke; `error` says how.
            case streamFailed
            /// A fresh stream took over from the one that failed before it
            /// (`StreamReconnectPolicy`); the events after it are the new stream's.
            case streamReconnected
            /// At the stop: a segment ran past `STTTuning.streamLongestTrustedSegmentSeconds`,
            /// so the upload answers; `text` is its length in seconds. A trace holds
            /// no audio, so this is what lets a replay measure the same segment.
            case segmentTooLong
            /// The user switched the dictation's mode with the other shortcut; `text` is
            /// `"ai"` or `"inline"`. `Setup.aiMode` is the mode it started in.
            case modeSwitch
            /// The user stopped the recording.
            case stop
            /// The batch upload's answer after the stream broke or came back empty.
            case fallback
            /// The LLM's rewrite in `text`, or its failure in `error`.
            case refinement
            /// The stop's own paste.
            case stopPaste
        }

        /// Seconds since the recording started.
        var t: Double
        var kind: Kind
        var text: String?
        var error: String?
    }

    var version = 1
    var recordedAt: Date
    var setup: Setup
    var events: [Event] = []
    /// Written by hand after reviewing the trace. Nil: the replay only checks that the app
    /// still pastes what it pasted when the trace was recorded.
    var expectedDocument: String?
    var note: String?

    /// Only a streamed dictation can be replayed: the other tiers have no events.
    var isReplayable: Bool {
        events.contains { [.partial, .committed, .streamFailed, .fallback].contains($0.kind) }
    }

    static func decode(_ data: Data) throws -> DictationTrace {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DictationTrace.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// Collects one dictation's `DictationTrace`, on the main actor.
@MainActor
public final class DictationTraceRecorder {
    /// The dictation being traced, or nil — which is always, unless the setting is on.
    public static var current: DictationTraceRecorder?

    private var trace: DictationTrace
    private let started: Date

    public init(setup: DictationTrace.Setup, now: Date = Date()) {
        trace = DictationTrace(recordedAt: now, setup: setup)
        started = now
    }

    public static func record(_ kind: DictationTrace.Event.Kind, text: String? = nil, error: String? = nil) {
        current?.record(kind, text: text, error: error)
    }

    /// The app the stop chose to paste into.
    public static func recordDestination(_ app: String?) {
        current?.trace.setup.destination = app
    }

    func record(_ kind: DictationTrace.Event.Kind, text: String? = nil, error: String? = nil) {
        let t = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
        trace.events.append(.init(t: t, kind: kind, text: text, error: error))
    }

    /// Writes the trace into `directory` as `<date>.json` and returns its URL — nil when
    /// there is nothing to replay (Apple or a plain batch upload) or the write failed.
    public func write(into directory: URL) -> URL? {
        guard trace.isReplayable else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = directory.appendingPathComponent(formatter.string(from: trace.recordedAt) + ".json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try trace.encoded().write(to: url, options: .atomic)
            return url
        } catch {
            dlog("Trace", "could not write the trace: \(error.localizedDescription)", level: .error)
            return nil
        }
    }
}
