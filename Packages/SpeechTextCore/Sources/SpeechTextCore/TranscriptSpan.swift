// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Span

/// Identity of a span. A counter rather than a UUID: the layer is pure logic and its
/// tests read better when the third span is `#3`, and the debug log's span timeline is
/// the thing these numbers exist for.
public struct TranscriptSpanID: Hashable, CustomStringConvertible, Sendable {
    let rawValue: UInt64
    public var description: String { "#\(rawValue)" }
}

/// One piece of issued text with an identity and a state. A span is *not* a phase:
/// `RecordingPhase` describes the engine, a span describes a piece of text, and inside
/// one `.recording` there can be ten settled spans and one still moving.
public struct TranscriptSpan: Identifiable, Equatable, Sendable {
    enum State: Equatable {
        /// Shown, but the recogniser may still replace it.
        case provisional
        /// Final as far as the provider is concerned. May still be rewritten by the
        /// finalizing pass (phase C).
        case committed
        /// The finalizing pass changed it.
        case revised
        /// Nothing will touch it again.
        case settled
        /// The user edited it by hand. Never rewritten, by anything.
        case frozen
        /// Cancelled before it was ever committed. Kept in the timeline, excluded from text.
        case dropped

        /// Everything the provider considers final — the text a Tier B sink may receive.
        var isStable: Bool {
            switch self {
            case .committed, .revised, .settled, .frozen: return true
            case .provisional, .dropped: return false
            }
        }

        /// Whether the span contributes to the visible text.
        var isVisible: Bool { self != .dropped }

        /// Whether a rewrite (a new committed string, an authoritative segment text, the
        /// finalizing pass) is allowed to change this span. `settled` is terminal too:
        /// a span is settled only once the engine has decided nothing else is coming.
        var isRewritable: Bool {
            switch self {
            case .provisional, .committed, .revised: return true
            case .settled, .frozen, .dropped: return false
            }
        }
    }

    public let id: TranscriptSpanID
    /// Which recording segment produced it. A pause/resume opens the next one.
    let segment: Int
    /// Trimmed. Spans are joined with single spaces, the way `joinedTranscript` does it —
    /// except after a span the provider cut mid-word, see `joinsPrevious`.
    public var text: String
    var state: State
    /// This span continues the previous one's last word ("дани" | "х, звідки"), so
    /// nothing goes between them. Read off the provider's cumulative committed text,
    /// which `joinedSegments` already glued.
    var joinsPrevious = false

    /// What goes in front of this span when it follows another.
    var separator: String { joinsPrevious ? "" : " " }
}

/// Span texts joined the way the provider joined them: a space, or nothing after a word
/// it cut in two. The first span's own `joinsPrevious` is ignored — it has nothing here
/// to join.
func joinedSpanTexts(_ spans: [TranscriptSpan]) -> String {
    var text = ""
    for (index, span) in spans.enumerated() {
        text += index == 0 ? span.text : span.separator + span.text
    }
    return text
}

// MARK: - Layer

/// The layer between the recognition sessions and the sinks. Sessions report a
/// *cumulative* `committed` / `partial` pair (`RecognitionEvent.live`); the layer turns
/// that into spans with identity and state, so a sink can tell what has settled from
/// what is still moving instead of receiving one re-joined string per frame.
///
/// Pure logic on purpose: no engine, no view, no clock. Everything that depends on the
/// microphone stays in `SpeechEngine`, and this is covered by `PureLogicTests`.
public struct TranscriptSpanLayer: Sendable {
    private(set) var spans: [TranscriptSpan] = []
    /// Index of the segment being recorded. `beginSegment()` opens the next one.
    private(set) var segment: Int = 0

    private var nextID: UInt64 = 1
    /// The cumulative `committed` string this segment's session last reported, so the
    /// next one can be reduced to its increment.
    private var lastCommitted: String = ""
    /// The span this segment's `partial` is being written into, if there is one.
    private var provisionalID: TranscriptSpanID?

    public init() {}

    // MARK: Reading

    var visibleSpans: [TranscriptSpan] { spans.filter { $0.state.isVisible } }

    /// Everything issued in this recording, all segments.
    public var text: String { join(visibleSpans) }

    /// The current segment only — what `SpeechEngine.liveText` has always meant: a pause
    /// hands its segment's text over for insertion, and the ghost text starts again.
    public var segmentText: String { join(visibleSpans.filter { $0.segment == segment }) }

    /// The current segment's settled half, in order: what a sink that cannot take back
    /// what it was given (Tier B) is allowed to receive, and what a sink that records
    /// ranges keys its insertions by.
    public var segmentStableSpans: [TranscriptSpan] {
        visibleSpans.filter { $0.segment == segment && $0.state.isStable }
    }

    /// The text of those spans.
    public var segmentStableText: String { join(segmentStableSpans) }

    /// Everything settled in this recording, all segments — what the inline overlay draws
    /// at full brightness, ahead of `segmentProvisionalText`.
    public var stableText: String { join(visibleSpans.filter { $0.state.isStable }) }

    /// The current segment's moving half. At most one span, but joined the same way.
    public var segmentProvisionalText: String {
        join(visibleSpans.filter { $0.segment == segment && $0.state == .provisional })
    }

    public func span(_ id: TranscriptSpanID) -> TranscriptSpan? { spans.first { $0.id == id } }

    // MARK: Lifecycle

    /// A new recording. Everything from the previous one is gone.
    public mutating func reset() {
        spans = []
        segment = 0
        nextID = 1
        lastCommitted = ""
        provisionalID = nil
    }

    /// The next segment (a resume, or a restart after an audio device change). The
    /// previous segment's still-provisional span is committed rather than dropped: its
    /// session is gone, so nothing will ever confirm those words, but they were spoken
    /// and the engine has already handed them on for insertion.
    public mutating func beginSegment() {
        if let id = provisionalID, let index = index(of: id), spans[index].state == .provisional {
            spans[index].state = .committed
            log("commit \(id) (segment closed), \(spans[index].text.count) chars")
        }
        segment += 1
        lastCommitted = ""
        provisionalID = nil
    }

    // MARK: Ingesting a session's events

    /// One `RecognitionEvent.live(committed:partial:)`. Both strings are cumulative for
    /// the segment, which is why the increment — not the string — becomes the span.
    public mutating func ingest(committed: String, partial: String) {
        ingestCommitted(committed)
        ingestPartial(partial)
    }

    private mutating func ingestCommitted(_ committed: String) {
        guard committed != lastCommitted else { return }
        defer { lastCommitted = committed }

        guard committed.hasPrefix(lastCommitted) else {
            // The provider rewrote what it had already committed (Apple's chunk rotation
            // can, after an early `isFinal`). Nothing was promised to a sink about the
            // shape of the split, so the segment's committed text collapses into one span.
            rewriteSegmentStable(to: trimmed(committed), reason: "committed rewritten")
            return
        }

        let raw = String(committed.dropFirst(lastCommitted.count))
        let delta = trimmed(raw)
        guard !delta.isEmpty else { return }
        // The cumulative text carries no space here: the provider cut a word.
        let glued = !lastCommitted.isEmpty
            && raw.first.map { !$0.isWhitespace } == true
            && lastCommitted.last.map { !$0.isWhitespace } == true

        // The partial that was showing these words *is* this commit: keeping its id lets
        // a sink that already drew it replace it in place instead of appending a second copy.
        if let id = provisionalID, let index = index(of: id), spans[index].state == .provisional {
            spans[index].text = delta
            spans[index].state = .committed
            spans[index].joinsPrevious = glued
            provisionalID = nil
            log("commit \(id)\(glued ? " (joins previous)" : ""), \(delta.count) chars")
        } else {
            var span = append(text: delta, state: .committed)
            if glued, let index = index(of: span.id) {
                spans[index].joinsPrevious = true
                span.joinsPrevious = true
            }
            log("commit \(span.id)\(glued ? " (joins previous)" : ""), \(delta.count) chars")
        }
    }

    private mutating func ingestPartial(_ partial: String) {
        let text = trimmed(partial)

        guard !text.isEmpty else {
            if let id = provisionalID, let index = index(of: id), spans[index].state == .provisional {
                spans[index].state = .dropped
                log("drop \(id) (partial cleared)")
            }
            provisionalID = nil
            return
        }

        if let id = provisionalID, let index = index(of: id), spans[index].state == .provisional {
            guard spans[index].text != text else { return }
            spans[index].text = text
            log("partial \(id), \(text.count) chars", level: .debug)
        } else {
            let span = append(text: text, state: .provisional)
            provisionalID = span.id
            log("partial \(span.id), \(text.count) chars", level: .debug)
        }
    }

    /// The segment's authoritative text — a batch upload's result, or what a stream hands
    /// back at `finish()`. Replaces only what differs: when the spans already spell it,
    /// they are left where they stand, so a sink is not asked to redraw text that did not
    /// change. Settling is a separate call, because phase C's finalizing pass belongs
    /// between the two.
    public mutating func commitSegment(_ text: String) {
        let authoritative = trimmed(text)

        // An empty result against non-empty spans is not a correction into nothing: the
        // live text stands (a stream that committed words and then failed its final call).
        guard !authoritative.isEmpty else { return }

        if segmentStableText != authoritative {
            rewriteSegmentStable(to: authoritative, reason: "segment result")
        }
        // Whatever the ghost text was still showing, the authoritative result is not it.
        dropProvisional()
    }

    /// Nothing else will change this segment's text.
    public mutating func settleSegment() {
        for index in spans.indices where spans[index].segment == segment {
            if spans[index].state == .committed || spans[index].state == .revised {
                spans[index].state = .settled
            }
        }
    }

    /// The recording was cancelled, or an authoritative result superseded the ghost text:
    /// what was never committed disappears. Text already handed to a sink is not taken
    /// back — un-inserting into a foreign app is not possible.
    mutating func dropProvisional() {
        for index in spans.indices where spans[index].state == .provisional {
            spans[index].state = .dropped
            log("drop \(spans[index].id)")
        }
        provisionalID = nil
    }

    // MARK: Later phases

    /// The finalizing pass changed a committed span (phase C). Frozen spans are refused.
    @discardableResult
    mutating func revise(_ id: TranscriptSpanID, text: String) -> Bool {
        guard let index = index(of: id), spans[index].state.isRewritable else { return false }
        let new = trimmed(text)
        guard spans[index].text != new else {
            spans[index].state = .settled
            return false
        }
        spans[index].text = new
        spans[index].state = .revised
        log("revise \(id), \(new.count) chars")
        return true
    }

    /// The user edited this span by hand. From here nothing rewrites it — not the
    /// finalizing pass, not a provider that changed its mind.
    mutating func freeze(_ id: TranscriptSpanID) {
        guard let index = index(of: id), spans[index].state.isVisible else { return }
        spans[index].state = .frozen
        if provisionalID == id { provisionalID = nil }
        log("freeze \(id)")
    }

    // MARK: Internals

    private mutating func rewriteSegmentStable(to text: String, reason: String) {
        let stable = spans.indices.filter { spans[$0].segment == segment && spans[$0].state.isStable }
        // Frozen text is the user's own edit, and a rewrite is one string for the whole
        // segment: with a frozen span *and* a rewritable one, the frozen words would stay
        // where they are and be spelled a second time inside the rewritten sibling. A
        // correction that would overlap frozen text is refused, not partially applied.
        guard !stable.contains(where: { spans[$0].state == .frozen }) else {
            log("skip rewrite (\(reason)): segment has frozen text")
            return
        }
        var replaced = false
        for index in stable where spans[index].state.isRewritable {
            if replaced {
                spans[index].state = .dropped
            } else {
                spans[index].text = text
                spans[index].state = .committed
                replaced = true
                log("rewrite \(spans[index].id) (\(reason)), \(text.count) chars")
            }
        }
        guard !replaced else { return }
        // Nothing stable to rewrite: the authoritative text is this segment's first
        // committed span (the batch tier's ordinary path — it has no live text at all).
        // But if the segment *does* have stable spans, every one of them is settled —
        // nothing else will change this segment's text, and a second copy is not a
        // correction.
        guard stable.isEmpty else {
            log("skip rewrite (\(reason)): segment is settled")
            return
        }
        let span = append(text: text, state: .committed)
        log("commit \(span.id) (\(reason)), \(text.count) chars")
    }

    private mutating func append(text: String, state: TranscriptSpan.State) -> TranscriptSpan {
        let span = TranscriptSpan(id: TranscriptSpanID(rawValue: nextID), segment: segment,
                                  text: text, state: state)
        nextID += 1
        spans.append(span)
        return span
    }

    private func index(of id: TranscriptSpanID) -> Int? { spans.firstIndex { $0.id == id } }

    private func join(_ spans: [TranscriptSpan]) -> String {
        joinedSpanTexts(spans.filter { !$0.text.isEmpty })
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func log(_ message: String, level: DebugLog.Level = .info) { dlog("Span", message, level: level) }
}
