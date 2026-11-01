// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SpeechTextCore

// MARK: - Insertion ledger (InsertionLedger.swift)

/// The ledger is what lets a later pass find its own text again. Everything here is
/// about the guard: it must find the span where it left it, follow it when the document
/// shifted around it, and refuse — rather than guess — when it cannot be sure.
final class InsertionLedgerTests: XCTestCase {

    private func span(_ id: UInt64) -> TranscriptSpanID { TranscriptSpanID(rawValue: id) }

    /// The recorded range wins outright when the text there still matches — which is
    /// also what makes a repeated word resolvable at all: the search fallback would
    /// refuse this document as ambiguous, and it never has to run.
    func testTheRecordedRangeIsPreferredOverSearchingForTheText() {
        var ledger = InsertionLedger()
        let range = NSRange(location: 0, length: 4)
        ledger.insert(span: span(1), range: range, text: "світ")
        XCTAssertEqual(ledger.resolve(span: span(1), in: "світ і світ"), range)
    }

    /// The user typed above the insertion, so it is no longer where it was recorded —
    /// but it is still there, untouched, and exactly once.
    func testASpanThatMovedIsFoundByItsText() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 4), text: "світ")
        let resolved = ledger.resolve(span: span(1), in: "Привіт світ")
        XCTAssertEqual(resolved, NSRange(location: 7, length: 4))
    }

    /// The whole point of the guard: the user edited over it, so nothing may be replaced.
    func testASpanTheUserEditedOverIsNotResolved() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 4), text: "світ")
        XCTAssertNil(ledger.resolve(span: span(1), in: "Привіт усім"))
    }

    /// Two identical occurrences make "the last one" a guess, and a guess is not
    /// allowed to rewrite the user's document.
    func testAnAmbiguousSpanIsRefusedRatherThanGuessed() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 99, length: 4), text: "світ")
        XCTAssertNil(ledger.resolve(span: span(1), in: "світ і ще раз світ"))
    }

    /// A paste whose landing could not be read is recorded at `NSNotFound` (`Int.max`).
    /// The next paste that does land used to shift it along with everything else and
    /// trap on the overflow — the crash after a pause in inline dictation (17.09).
    func testARecordWithNoRangeIsNotShiftedByALaterInsertion() {
        var ledger = InsertionLedger()
        ledger.insert(span: nil, range: NSRange(location: NSNotFound, length: 0), text: "Один")
        ledger.insert(span: span(2), range: NSRange(location: 5, length: 3), text: "два")
        ledger.replaced(span: span(2), at: NSRange(location: 5, length: 3), with: "двоє")
        XCTAssertEqual(ledger.records.first?.range.location, NSNotFound)
        XCTAssertEqual(ledger.records.map(\.text), ["Один", "двоє"])
    }

    func testAnUnknownSpanResolvesToNothing() {
        let ledger = InsertionLedger()
        XCTAssertNil(ledger.resolve(span: span(7), in: "Привіт"))
    }

    /// An insertion before an earlier one pushes it along, so its recorded range keeps
    /// describing where its text actually is.
    func testAnEarlierRecordShiftsWhenTextIsInsertedAboveIt() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 4), text: "світ")
        ledger.insert(span: span(2), range: NSRange(location: 0, length: 7), text: "Привіт ")
        XCTAssertEqual(ledger.record(for: span(1))?.range, NSRange(location: 7, length: 4))
    }

    /// A replacement of a different length moves everything after it, and only that.
    func testAReplacementShiftsWhatFollowsButNotWhatPrecedes() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 3), text: "Два")
        ledger.insert(span: span(2), range: NSRange(location: 4, length: 3), text: "три")
        ledger.insert(span: span(3), range: NSRange(location: 8, length: 7), text: "чотири!")
        ledger.replaced(span: span(2), at: NSRange(location: 4, length: 3), with: "тринадцять")
        XCTAssertEqual(ledger.record(for: span(1))?.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(ledger.record(for: span(2))?.text, "тринадцять")
        XCTAssertEqual(ledger.record(for: span(3))?.range.location, 15)
    }

    func testClearingLeavesNothingToResolve() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 6), text: "Привіт")
        ledger.clear()
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertNil(ledger.resolve(span: span(1), in: "Привіт"))
    }

    /// Untracked text (an Apple pause hands back its own joined string) still occupies
    /// room in the document, so it must still move the records that follow it.
    func testUntrackedTextStillShiftsTheRecordsAroundIt() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 4), text: "світ")
        ledger.insert(span: nil, range: NSRange(location: 0, length: 7), text: "Привіт ")
        XCTAssertEqual(ledger.record(for: span(1))?.range.location, 7)
    }
}

// MARK: - Delivery tiers (DeliveryTier.swift)

/// The tier decides how the Edit shortcut reads a selection: through AX, with its range,
/// or with a ⌘C. It comes from what the Accessibility API proved it can do — and the
/// proof is the read-back, not the return code.
final class DeliveryTierTests: XCTestCase {

    private let correctable = AXTextProbe(valueReadable: true, rangeReadable: true, rangeReadsBack: true)

    func testOurOwnSurfaceIsTierAWithoutProbingAnything() {
        let tier = DeliveryTier.resolve(isOwnSurface: true, probe: .unavailable)
        XCTAssertEqual(tier, .a)
    }

    func testAnAppThatReadsAndReselectsItsTextIsTierA() {
        let tier = DeliveryTier.resolve(isOwnSurface: false, probe: correctable)
        XCTAssertEqual(tier, .a)
    }

    /// The Chromium shape: the range write is accepted and then reads back as something
    /// else. Trusting the return code alone is what would put VS Code in Tier A.
    func testAnAppWhoseRangeDoesNotReadBackIsTierB() {
        var probe = correctable
        probe.rangeReadsBack = false
        XCTAssertEqual(DeliveryTier.resolve(isOwnSurface: false, probe: probe), .b)
    }

    /// The Terminal shape: nothing answers at all.
    func testAnAppThatAnswersNothingIsTierB() {
        XCTAssertEqual(DeliveryTier.resolve(isOwnSurface: false, probe: .unavailable), .b)
    }

    func testAnAppThatWillNotGiveUpItsValueIsTierB() {
        var probe = correctable
        probe.valueReadable = false
        XCTAssertEqual(DeliveryTier.resolve(isOwnSurface: false, probe: probe), .b)
    }
}

/// The keystroke a simulated ⌘V / ⌘C / ⌘X is posted as. Chrome 156 pastes nothing for a
/// V whose flags alone say ⌘ (measured 2026-11-01), so ⌘ itself has to go down first and
/// come up last.
final class CommandKeystrokeTests: XCTestCase {
    private let command: UInt16 = 0x37
    private let v: UInt16 = 0x09

    func testCommandIsPressedAroundTheLetter() {
        XCTAssertEqual(CommandKeystroke.steps(letterKeyCode: v), [
            .init(keyCode: command, isDown: true, commandHeld: true),
            .init(keyCode: v, isDown: true, commandHeld: true),
            .init(keyCode: v, isDown: false, commandHeld: true),
            .init(keyCode: command, isDown: false, commandHeld: false),
        ])
    }

    func testTheLetterIsTheOneTheLayoutNames() {
        // Dvorak's ⌘V is not the ANSI position; whatever key the layout gives is posted.
        let dvorakV: UInt16 = 0x2F
        let letters = CommandKeystroke.steps(letterKeyCode: dvorakV).filter { $0.keyCode != command }
        XCTAssertEqual(letters.map(\.keyCode), [dvorakV, dvorakV])
        XCTAssertEqual(letters.map(\.isDown), [true, false])
    }

    func testTheStepsKeepTheMeasuredSpacing() {
        XCTAssertEqual(CommandKeystroke.stepMicroseconds, 20_000)
    }
}
