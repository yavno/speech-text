// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One write into a sink: select `range`, put `text` there.
public struct TextReplacement: Equatable, Sendable {
    public let range: NSRange
    public let text: String
}

/// Replacing text a sink already holds by *one* write — or not touching it at all.
///
/// The name is the stop's: this was the pass that brought text pasted into another app
/// while the user spoke in line with the authoritative text. Nothing is pasted into
/// another app before the stop any more, so the inline stop has nothing to correct; what
/// is left is the plan, which the Record Window's ✨ uses to write a refined segment over
/// the one it came from.
///
/// Pure logic. The sink does the I/O and hands its document in here;
/// everything that decides whether and where to write is below, where `PureLogicTests`
/// can reach it.
public enum FinalizePass {
    /// Where the recorded text is in `document` right now, as one range, and what goes
    /// there. Nil — leave the document alone — unless every step checks out:
    ///
    /// 1. Every record resolves (`InsertionLedger.resolve`): at its recorded range, or as
    ///    the one unambiguous occurrence of its text. The spec lets an unresolvable
    ///    record be *skipped*; here it refuses the whole pass instead, because the write
    ///    is a single range across all records, and a skipped one inside it is text the
    ///    user changed that the write would overwrite — and a skipped one at an end is
    ///    words the replacement would put into the document a second time.
    /// 2. The resolved records sit next to each other, with nothing but whitespace
    ///    between them — what the sink inserted as separators. Anything else between two
    ///    records is the user's typing, and it is not ours to replace.
    public static func plan(ledger: InsertionLedger, document: String, replacement: String) -> TextReplacement? {
        guard !ledger.isEmpty else { return nil }
        let text = document as NSString

        var ranges: [NSRange] = []
        for record in ledger.records {
            guard let range = ledger.resolve(record, in: document) else { return nil }
            ranges.append(range)
        }
        ranges.sort { $0.location < $1.location }

        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            let gapStart = NSMaxRange(previous)
            guard next.location >= gapStart else { return nil } // overlapping records
            let gap = text.substring(with: NSRange(location: gapStart, length: next.location - gapStart))
            guard gap.allSatisfy(\.isWhitespace) else { return nil }
        }

        let first = ranges[0], last = ranges[ranges.count - 1]
        let covering = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let final = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty, text.substring(with: covering) != final else { return nil }
        return TextReplacement(range: covering, text: final)
    }
}
