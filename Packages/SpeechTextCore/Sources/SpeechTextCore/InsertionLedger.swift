// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where one span's text landed in a sink, and what the sink actually holds there.
///
/// `text` is deliberately *the sink's* copy, not the string we sent: a text view with
/// smart quotes on, or a foreign app that normalises line endings, stores something
/// slightly different from what was pasted. A replacement guards on "is what I inserted
/// still there, untouched", and that guard has to compare against the document's
/// version or it refuses every correction it is asked to make.
public struct InsertionRecord: Equatable, Sendable {
    /// The span this text came from. `nil` for text a sink was handed that the span
    /// layer could not account for — it is tracked for offsets, never rewritten.
    public let span: TranscriptSpanID?
    /// UTF-16 range, because every sink this talks to (`NSTextView`, the AX API) is
    /// UTF-16 indexed.
    public var range: NSRange
    public var text: String

    public init(span: TranscriptSpanID?, range: NSRange, text: String) {
        self.span = span
        self.range = range
        self.text = text
    }
}

/// The record of what has already been handed to one sink, so a later pass can find its
/// own text again and replace exactly that.
///
/// Pure logic — no text view, no AX, no app state. The Record Window's
/// `TextInsertionHandler` keeps one for the segments it inserts, and the Edit shortcut
/// builds a one-record ledger for the selection it read; the deciding is here, where
/// `PureLogicTests` can reach it. An inline dictation keeps none: nothing is handed to
/// another app before its stop, and the stop pastes once.
public struct InsertionLedger: Sendable {
    private(set) var records: [InsertionRecord] = []

    public init() {}

    var isEmpty: Bool { records.isEmpty }

    public func record(for span: TranscriptSpanID) -> InsertionRecord? {
        records.last { $0.span == span }
    }

    // MARK: Writing

    /// Text landed at `range`. Records made earlier that sit at or after it move by its
    /// length — the user can put the caret anywhere between two insertions.
    public mutating func insert(span: TranscriptSpanID?, range: NSRange, text: String) {
        shift(from: range.location, by: range.length)
        records.append(InsertionRecord(span: span, range: range, text: text))
    }

    /// A span's text was replaced in the sink. Its own record takes the new text, and
    /// everything after it moves by the difference.
    public mutating func replaced(span: TranscriptSpanID, at range: NSRange, with text: String) {
        guard let index = records.lastIndex(where: { $0.span == span }) else { return }
        let new = NSRange(location: range.location, length: (text as NSString).length)
        let delta = new.length - range.length
        records[index].range = new
        records[index].text = text
        for other in records.indices where other != index
            && records[other].range.location != NSNotFound
            && records[other].range.location >= range.location + range.length {
            records[other].range.location += delta
        }
    }

    public mutating func clear() { records = [] }

    /// A record with no range (`NSNotFound`, a paste whose landing could not be read) has
    /// no position to move — and `NSNotFound` is `Int.max`, so moving it would trap.
    private mutating func shift(from location: Int, by delta: Int) {
        guard delta != 0, location != NSNotFound else { return }
        for index in records.indices
        where records[index].range.location != NSNotFound && records[index].range.location >= location {
            records[index].range.location += delta
        }
    }

    // MARK: Reading

    /// Where this span's text is in `document` *right now*, or nil if it is not there
    /// untouched. Three steps, in order: the recorded
    /// range if the substring still matches exactly; otherwise the last occurrence of
    /// that text anywhere in the document (it moved — the user typed above it);
    /// otherwise nothing at all, and the caller must leave the document alone.
    public func resolve(span: TranscriptSpanID, in document: String) -> NSRange? {
        guard let record = record(for: span) else { return nil }
        return resolve(record, in: document)
    }

    /// The same three steps for any record — including one with no span and no range,
    /// a paste whose landing could not be read. It skips straight to the search, and the
    /// search still refuses text that is not there exactly once.
    public func resolve(_ record: InsertionRecord, in document: String) -> NSRange? {
        guard !record.text.isEmpty else { return nil }
        let text = document as NSString

        if record.range.location != NSNotFound,
           NSMaxRange(record.range) <= text.length,
           text.substring(with: record.range) == record.text {
            return record.range
        }

        let found = text.range(of: record.text, options: .backwards)
        guard found.location != NSNotFound else { return nil }
        // Ambiguous: the same words appear more than once, so "the last occurrence" is a
        // guess, and a guess is not allowed to rewrite the user's document.
        let head = NSRange(location: 0, length: found.location)
        guard text.range(of: record.text, options: .backwards, range: head).location == NSNotFound else {
            return nil
        }
        return found
    }
}
