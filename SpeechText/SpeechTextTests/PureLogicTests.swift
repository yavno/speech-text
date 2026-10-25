// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import AppKit
import AVFoundation
import Carbon.HIToolbox
@testable import SpeechTextCore

// These tests reach the app's logic through `@testable import SpeechTextCore`, the local
// package it lives in — never the app itself, which is an LSUIElement agent that prompts
// for microphone access at launch, so hosting tests inside it would hang a headless run.
// Everything exercised here must therefore be constructible without UserDefaults: the
// user's real API keys live in the app.speech-text.SpeechText domain and the tests never
// read or write it.


// MARK: - What the stop still has to deliver (InlineDelivery.stopResult)

/// This repo has shipped a doubled dictation twice, and pasting spans while the user
/// spoke added a third way to do it — the stop pasting the whole text again over what the
/// app already had — which a ledger subtraction guarded here. Nothing is pasted before
/// the stop any more, so what the stop owes is simply the whole dictation, once:
/// these pin down which text that is.
final class UndeliveredRemainderTests: XCTestCase {

    private func stop(final: String, recording: String, failed: Bool = false,
                      aiMode: Bool = false) -> InlineDelivery.StopResult {
        InlineDelivery.stopResult(finalText: final, failed: failed, aiMode: aiMode, recordingText: recording)
    }

    /// The ordinary shape: the whole text, once.
    func testTheWholeTextIsOwed() {
        XCTAssertEqual(stop(final: "Привіт, як справи?", recording: "Привіт, як справи?"),
                       .paste("Привіт, як справи?"))
    }

    /// A device change closed a segment mid-dictation, so `finalText` is only the last
    /// one: the stop owes the whole recording, not the part after the restart.
    func testTheWholeRecordingIsOwedNotItsLastSegment() {
        XCTAssertEqual(stop(final: "Третє речення.", recording: "Перше речення. Друге. Третє речення."),
                       .paste("Перше речення. Друге. Третє речення."))
    }

    /// Nothing transcribed: whatever ghost text the span layer still holds, a failed
    /// stream took back — nothing is owed.
    func testAnEmptyFinalTextOwesNothing() {
        XCTAssertEqual(stop(final: "  ", recording: "Зроблю це"), .noSpeech)
        XCTAssertEqual(stop(final: "", recording: ""), .noSpeech)
    }

    /// AI mode rewrites the whole recording too.
    func testAIModeRewritesTheWholeRecording() {
        XCTAssertEqual(stop(final: "Друге.", recording: "Перше. Друге.", aiMode: true),
                       .refine(input: "Перше. Друге."))
    }

    /// A failure pastes nothing, and hands the Record Window what there is — the whole
    /// recording, even when the final text came back empty.
    func testAFailureHandsOverWhatThereIs() {
        XCTAssertEqual(stop(final: "", recording: "Перше речення.", failed: true),
                       .failed(partial: "Перше речення."))
        XCTAssertEqual(stop(final: "Друге.", recording: "Перше. Друге.", failed: true),
                       .failed(partial: "Перше. Друге."))
        XCTAssertEqual(stop(final: "", recording: "", failed: true), .failed(partial: ""))
    }

    /// Every path upstream trims, and so does this — the one space `AppState.deliver`
    /// adds is its own.
    func testTheTextIsTrimmed() {
        XCTAssertEqual(stop(final: " Привіт. \n", recording: " Привіт. \n"), .paste("Привіт."))
    }
}

// MARK: - Where the stop pastes (InlineDelivery.destination)

/// the app in front at the stop, unless that is SpeechText itself.
final class PasteDestinationTests: XCTestCase {

    func testTheAppInFrontAtTheStopIsTheDestination() {
        XCTAssertEqual(InlineDelivery.destination(front: "Slack", frontIsSpeechText: false, origin: "Mail"), "Slack")
        XCTAssertEqual(InlineDelivery.destination(front: "Mail", frontIsSpeechText: false, origin: "Mail"), "Mail")
    }

    func testSpeechTextInFrontFallsBackToTheOrigin() {
        XCTAssertEqual(InlineDelivery.destination(front: "SpeechText", frontIsSpeechText: true, origin: "Mail"), "Mail")
    }

    /// No origin either — a dictation started from our own window: the Record Window.
    func testSpeechTextInFrontWithNoOriginIsNoDestination() {
        XCTAssertNil(InlineDelivery.destination(front: "SpeechText", frontIsSpeechText: true, origin: String?.none))
    }

    func testNothingInFrontFallsBackToTheOrigin() {
        XCTAssertEqual(InlineDelivery.destination(front: String?.none, frontIsSpeechText: false, origin: "Mail"), "Mail")
    }

    func testTheAppInFrontAtTheStartIsTheOrigin() {
        XCTAssertEqual(InlineDelivery.origin(front: "Mail", frontIsSpeechText: false), "Mail")
    }

    /// Started from the main window or Settings: no origin — not the app an earlier
    /// dictation was in — so a stop there too goes to the Record Window.
    func testADictationStartedInSpeechTextHasNoOrigin() {
        XCTAssertNil(InlineDelivery.origin(front: "SpeechText", frontIsSpeechText: true))
        let origin = InlineDelivery.origin(front: "SpeechText", frontIsSpeechText: true)
        XCTAssertNil(InlineDelivery.destination(front: "SpeechText", frontIsSpeechText: true, origin: origin))
        XCTAssertEqual(InlineDelivery.destination(front: "Notes", frontIsSpeechText: false, origin: origin), "Notes")
    }

    /// The ⌘V goes to whatever is in front, so it is posted only when that is the app the
    /// text is for — and the focused element is asked about only then.
    func testAPasteIsPostedOnlyIntoTheAppInFront() {
        XCTAssertEqual(InlineDelivery.pasteCheck(quit: false, inFront: true, menuOpen: false, takesText: true), .paste)
        XCTAssertEqual(InlineDelivery.pasteCheck(quit: false, inFront: true, menuOpen: false, takesText: false), .takesNoText)
        XCTAssertEqual(InlineDelivery.pasteCheck(quit: false, inFront: false, menuOpen: false, takesText: true), .notInFront)
        XCTAssertEqual(InlineDelivery.pasteCheck(quit: true, inFront: false, menuOpen: false, takesText: true), .quit)
        var asked = false
        _ = InlineDelivery.pasteCheck(quit: false, inFront: false, menuOpen: { asked = true; return false }(),
                                      takesText: { asked = true; return true }())
        XCTAssertFalse(asked, "an app not in front was asked about its menus or its focused element")
    }

    /// Control Center open over the app in front has the keyboard, though the app is still
    /// the frontmost one: a ⌘V posted then is lost, and "Pasted into TextEdit" was a lie
    /// (22.10). Activation does not close it, so nothing is pasted.
    func testAPasteIsNotPostedWhileAMenuBarMenuHasTheKeyboard() {
        XCTAssertEqual(InlineDelivery.pasteCheck(quit: false, inFront: true, menuOpen: true, takesText: true), .menuOpen)
        var asked = false
        _ = InlineDelivery.pasteCheck(quit: false, inFront: true, menuOpen: true, takesText: { asked = true; return true }())
        XCTAssertFalse(asked, "the focused element was asked about with a menu holding the keyboard")
    }
}

// MARK: - Finalizing pass (FinalizePass.swift)

/// A single write over text a sink recorded — the Record Window's ✨ writes a refined
/// segment over the one it came from this way. The plan must find the recorded text as
/// one range and refuse — leaving the document exactly as it is — whenever it cannot be
/// sure the whole range is still ours.
final class FinalizePassTests: XCTestCase {

    private func span(_ id: UInt64) -> TranscriptSpanID { TranscriptSpanID(rawValue: id) }

    /// "Олек" / "сандр прийде" — a cut through the middle of a name, pasted as it committed.
    private func badlyCut() -> InsertionLedger {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 6, length: 4), text: "Олек")
        ledger.insert(span: span(2), range: NSRange(location: 11, length: 12), text: "сандр прийде")
        return ledger
    }
    private let cutDocument = "Нотат Олек сандр прийде\nкінець"

    func testABadCutIsReplacedAsOneRangeCoveringEveryRecord() {
        let plan = FinalizePass.plan(ledger: badlyCut(), document: cutDocument,
                                     replacement: "Олександр прийде.")
        XCTAssertEqual(plan, TextReplacement(range: NSRange(location: 6, length: 17), text: "Олександр прийде."))
    }

    func testTheUserTypingBetweenTwoRecordsRefusesThePass() {
        let edited = "Нотат Олек, мабуть, сандр прийде"
        XCTAssertNil(FinalizePass.plan(ledger: badlyCut(), document: edited, replacement: "Олександр прийде."))
    }

    func testARecordTheUserEditedOverRefusesThePassRatherThanSkippingIt() {
        let edited = "Нотат Олек Петро прийде"
        XCTAssertNil(FinalizePass.plan(ledger: badlyCut(), document: edited, replacement: "Олександр прийде."))
    }

    func testTextThatMovedIsStillFoundAndReplaced() {
        let moved = "Нове. Нотат Олек сандр прийде"
        let plan = FinalizePass.plan(ledger: badlyCut(), document: moved, replacement: "Олександр прийде.")
        XCTAssertEqual(plan?.range, NSRange(location: 12, length: 17))
    }

    /// A paste whose landing could not be read is found by its text, when it is there
    /// exactly once — 17.09, a click on the menu bar mid-paste left one piece untracked,
    /// and that alone refused the whole correction.
    func testAnUntrackedPieceIsFoundByItsText() {
        var ledger = badlyCut()
        ledger.insert(span: nil, range: NSRange(location: NSNotFound, length: 0), text: "завтра.")
        let document = "Нотат Олек сандр прийде завтра.\nкінець"
        XCTAssertEqual(FinalizePass.plan(ledger: ledger, document: document, replacement: "Олександр прийде завтра."),
                       TextReplacement(range: NSRange(location: 6, length: 25), text: "Олександр прийде завтра."))
    }

    /// …and refused when the text appears twice: which one is ours is a guess.
    func testAnUntrackedPieceThatAppearsTwiceRefusesThePass() {
        var ledger = InsertionLedger()
        ledger.insert(span: nil, range: NSRange(location: NSNotFound, length: 0), text: "Так.")
        XCTAssertNil(FinalizePass.plan(ledger: ledger, document: "Так. Ні. Так.", replacement: "Так, так."))
    }

    func testNothingToWriteWhenTheDocumentAlreadyHoldsTheFinalText() {
        var ledger = InsertionLedger()
        ledger.insert(span: span(1), range: NSRange(location: 0, length: 9), text: "Олександр")
        XCTAssertNil(FinalizePass.plan(ledger: ledger, document: "Олександр", replacement: "Олександр"))
    }
}

// MARK: - Segment joins (TranscriptMerge.swift, TranscriptSpan.swift, InlineDelivery.swift)

/// 17.09: Scribe closed a segment inside a word — "…база дани" | "х, звідки…".
/// Every boundary used to get a space, so History read "дани х" and the live paste would
/// too. A boundary is glued only when a dictionary says the halves are one word.
final class SegmentJoinTests: XCTestCase {

    /// A stand-in for the spell checker: only these are words.
    private let dictionary: Set<String> = ["даних", "база", "звідки", "привіт", "віт", "дані", "поки"]
    private func isWord(_ word: String) -> Bool { dictionary.contains(word.lowercased()) }

    override func tearDown() {
        TranscriptJoin.isWord = { _ in false }
        super.tearDown()
    }

    func testAWordCutInTwoIsGluedBack() {
        XCTAssertEqual(segmentSeparator("Ось нова база дани", "х, звідки ми", isWord: isWord), "")
    }

    /// Punctuation closed the first segment: that was a pause between words. ("в..." is
    /// judged as "в" by `joinedSegments`, and "вmain" is no word either.)
    func testAPunctuatedBoundaryKeepsItsSpace() {
        XCTAssertEqual(segmentSeparator("попадає в...", "main сесію", isWord: isWord), " ")
        XCTAssertEqual(segmentSeparator("база дани.", "х", isWord: isWord), " ")
    }

    /// A capital opens a new sentence, not the rest of a word.
    func testACapitalisedSegmentKeepsItsSpace() {
        XCTAssertEqual(segmentSeparator("база дани", "Х звідки", isWord: isWord), " ")
    }

    /// Both halves standing as words means two words were said.
    func testASecondHalfThatIsAWordKeepsItsSpace() {
        XCTAssertEqual(segmentSeparator("скажу при", "віт усім", isWord: isWord), " ")
    }

    /// A spell checker accepts every single letter, so real one-letter words are listed —
    /// "і" is a word, "х" is not.
    func testOneLetterFragmentsAreJudgedByTheListNotTheChecker() {
        let acceptsAnything: (String) -> Bool = { _ in true }
        XCTAssertEqual(segmentSeparator("дані", "і ще щось", isWord: acceptsAnything), " ")
        // Found running the rule over History: "Чи | я" must not become "Чия".
        XCTAssertEqual(segmentSeparator("Чи", "я щось не розумію", isWord: acceptsAnything), " ")
        XCTAssertEqual(segmentSeparator("база дани", "х, звідки", isWord: acceptsAnything), "")
    }

    /// Nothing registered — the test target, or no dictionary for the language: the old
    /// behaviour, a space everywhere.
    func testWithNoDictionaryEveryBoundaryKeepsItsSpace() {
        XCTAssertEqual(segmentSeparator("база дани", "х, звідки"), " ")
    }

    // Scribe trails a segment closed inside a word off into "..." and opens the
    // next with a capital — "перфо..." | "Ратор.".

    private let cutBeforeDots: Set<String> = ["перфоратор", "нова", "версія", "даних"]
    private func isWordAfterDots(_ word: String) -> Bool { cutBeforeDots.contains(word.lowercased()) }

    func testAWordCutBeforeTrailingDotsIsGluedAndLowercased() {
        TranscriptJoin.isWord = isWordAfterDots
        XCTAssertEqual(joinedSegments("а сусід знову вмикає перфо...", "Ратор. А це нова..."),
                       "а сусід знову вмикає перфоратор. А це нова...")
        XCTAssertEqual(joinedSegments("вмикає перфо…", "Ратор."), "вмикає перфоратор.")
        XCTAssertEqual(joinedSegments("база дани...", "х, звідки"), "база даних, звідки")
    }

    /// A capital after the dots that continues no cut word keeps its case and its space:
    /// the model's capitals are not rewritten (the owner's decision).
    func testACapitalAfterTrailingDotsThatIsAWordKeepsItsCase() {
        TranscriptJoin.isWord = isWordAfterDots
        XCTAssertEqual(joinedSegments("А це нова...", "Версія."), "А це нова... Версія.")
    }

    /// Only dots straight after a letter are a trailing-off; nothing registered glues nothing.
    func testOnlyDotsAfterALetterAreReadPast() {
        TranscriptJoin.isWord = { _ in true }
        XCTAssertEqual(joinedSegments("перфо?..", "Ратор."), "перфо?.. Ратор.")
        XCTAssertEqual(joinedSegments("перфо....", "ратор."), "перфо.... ратор.")
        TranscriptJoin.isWord = { _ in false }
        XCTAssertEqual(joinedSegments("перфо...", "Ратор."), "перфо... Ратор.")
    }

    /// The span layer, fed the cleaned cumulative text as the engine feeds it: the dots go
    /// with cleanup, the glued half continues the span before it, nothing is redrawn.
    func testTheSpanLayerGluesAWordCutBeforeTrailingDots() {
        TranscriptJoin.isWord = isWordAfterDots
        var committed = "а сусід знову вмикає перфо..."
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: cleanedTranscript(committed), partial: "")
        committed = joinedSegments(committed, "Ратор. А це нова...")
        layer.ingest(committed: cleanedTranscript(committed), partial: "")
        committed = joinedSegments(committed, "Версія.")
        layer.ingest(committed: cleanedTranscript(committed), partial: "")

        XCTAssertEqual(layer.visibleSpans.map(\.text), ["а сусід знову вмикає перфо", "ратор. А це нова", "Версія."])
        XCTAssertEqual(layer.visibleSpans.map(\.joinsPrevious), [false, true, false])
        XCTAssertEqual(layer.text, "а сусід знову вмикає перфоратор. А це нова Версія.")
    }

    /// The streaming merge uses it, so the cumulative committed text — and History — read
    /// the word whole.
    func testTheStreamingMergeGluesACutWord() {
        TranscriptJoin.isWord = isWord
        XCTAssertEqual(mergedTranscript("Ось нова база дани", "х, звідки ми"),
                       "Ось нова база даних, звідки ми")
    }

    /// The span layer reads the glue off the cumulative text: the second span continues
    /// the first, and the layer's text keeps the word whole.
    func testTheSpanLayerMarksASpanThatContinuesAWord() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "Ось нова база дани", partial: "")
        layer.ingest(committed: "Ось нова база даних, звідки ми", partial: "")
        XCTAssertEqual(layer.visibleSpans.map(\.text), ["Ось нова база дани", "х, звідки ми"])
        XCTAssertEqual(layer.visibleSpans.map(\.joinsPrevious), [false, true])
        XCTAssertEqual(layer.text, "Ось нова база даних, звідки ми")
    }

    /// An ordinary boundary is not mistaken for a glued one.
    func testTheSpanLayerKeepsAnOrdinaryBoundarySpaced() {
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "Привіт.", partial: "")
        layer.ingest(committed: "Привіт. Як справи?", partial: "")
        XCTAssertEqual(layer.visibleSpans.map(\.joinsPrevious), [false, false])
        XCTAssertEqual(layer.text, "Привіт. Як справи?")
    }

    /// The stop pastes the layer's text, so a word the stream cut goes into the document
    /// whole.
    func testTheStopPastesACutWordWhole() {
        TranscriptJoin.isWord = isWord
        var layer = TranscriptSpanLayer()
        layer.ingest(committed: "Ось нова база дани", partial: "")
        layer.ingest(committed: "Ось нова база даних, звідки ми", partial: "")
        XCTAssertEqual(InlineDelivery.stopResult(finalText: "Ось нова база даних, звідки ми", failed: false,
                                                 aiMode: false, recordingText: layer.text),
                       .paste("Ось нова база даних, звідки ми"))
    }
}

// MARK: - Overlay placement

final class OverlayPlacementTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944)
    /// An external display to the laptop's right.
    private let external = CGRect(x: 1512, y: 0, width: 2560, height: 1415)
    /// The minimal skin with a transcript: a 300×44 strip, text growing to 112 above it.
    private let minimal = OverlayGeometry(strip: CGSize(width: 300, height: 44),
                                          transcriptWidth: 300, maxTranscriptHeight: 112)
    /// Techno: the transcript is wider than the strip, which hangs at its right end.
    private let techno = OverlayGeometry(strip: CGSize(width: 142, height: 56),
                                         transcriptWidth: 260, maxTranscriptHeight: 104, gap: 6)
    private let m = OverlayPlacement.margin

    func testNothingSavedGoesToTheBottomRightCorner() {
        let placed = OverlayPlacement.placement(saved: nil, minimal, screens: [laptop], main: laptop)
        XCTAssertEqual(placed, .init(strip: CGPoint(x: 1512 - m - 300, y: m), growth: .up))
    }

    func testASavedSpotOnScreenIsKept() {
        let saved = CGPoint(x: 400, y: 300)
        XCTAssertEqual(OverlayPlacement.placement(saved: saved, minimal, screens: [laptop], main: laptop)?.strip, saved)
    }

    // MARK: Growing

    /// The panel starts as the strip alone and grows upward around it: the strip does not
    /// move while the transcript appears.
    func testTheTranscriptGrowsOutOfAStripThatStaysPut() {
        let strip = CGPoint(x: 400, y: 100)
        XCTAssertEqual(OverlayPlacement.frame(strip: strip, minimal, growth: .up, transcriptHeight: 0),
                       CGRect(x: 400, y: 100, width: 300, height: 44))
        XCTAssertEqual(OverlayPlacement.frame(strip: strip, minimal, growth: .up, transcriptHeight: 40),
                       CGRect(x: 400, y: 100, width: 300, height: 84))
        XCTAssertEqual(OverlayPlacement.frame(strip: strip, minimal, growth: .down, transcriptHeight: 40),
                       CGRect(x: 400, y: 60, width: 300, height: 84))
    }

    /// Techno's wider glass reaches out to the left of the strip, and only once it has a
    /// height — before that the panel is the strip.
    func testTechnoTranscriptReachesLeftOfTheStrip() {
        let strip = CGPoint(x: 400, y: 100)
        XCTAssertEqual(OverlayPlacement.frame(strip: strip, techno, growth: .up, transcriptHeight: 0),
                       CGRect(x: 400, y: 100, width: 142, height: 56))
        XCTAssertEqual(OverlayPlacement.frame(strip: strip, techno, growth: .up, transcriptHeight: 30),
                       CGRect(x: 400 + 142 - 260, y: 100, width: 260, height: 56 + 6 + 30))
    }

    /// In the top half the transcript grows down, so the strip can sit at the top edge
    /// instead of being held a transcript's height below it.
    func testATopStripGrowsDownAndSitsAtTheTop() {
        let placed = OverlayPlacement.settled(strip: CGPoint(x: 400, y: 944 - m - 44), minimal, in: laptop)
        XCTAssertEqual(placed, .init(strip: CGPoint(x: 400, y: 944 - m - 44), growth: .down))
    }

    /// Room is kept for the transcript at its full height, whichever way it grows.
    func testRoomIsKeptForTheWholeTranscript() {
        // Bottom half, dragged right down to the edge: the strip may touch it.
        XCTAssertEqual(OverlayPlacement.settled(strip: CGPoint(x: 400, y: -50), minimal, in: laptop).strip.y, 0)
        // A short screen whose midline is low: growing up from y 60 must still fit.
        let short = CGRect(x: 0, y: 0, width: 800, height: 200)
        let placed = OverlayPlacement.settled(strip: CGPoint(x: 100, y: 60), minimal, in: short)
        XCTAssertEqual(placed.growth, .up)
        XCTAssertEqual(placed.strip.y, 200 - 44 - 112)
    }

    // MARK: Keeping it on screen

    /// A drag past the edge stops at the edge — there is no half-off-screen position.
    func testADragPastTheEdgeStopsAtIt() {
        let placed = OverlayPlacement.settled(strip: CGPoint(x: 1400, y: 300), minimal, in: laptop)
        XCTAssertEqual(placed.strip.x, 1512 - 300)
        let left = OverlayPlacement.settled(strip: CGPoint(x: -150, y: 300), minimal, in: laptop)
        XCTAssertEqual(left.strip.x, 0)
    }

    /// Straddling two displays, it opens on the one holding most of it.
    func testAStraddlingStripOpensOnTheScreenHoldingMostOfIt() {
        let placed = OverlayPlacement.placement(saved: CGPoint(x: 1450, y: 100), minimal,
                                                screens: [laptop, external], main: laptop)
        XCTAssertEqual(placed?.strip, CGPoint(x: 1512, y: 100))
    }

    /// The external display it was dragged to is unplugged: the default corner, not a
    /// spot clamped against wherever the laptop's edge happens to be.
    func testAnUnpluggedDisplayFallsBackToTheDefaultCorner() {
        let placed = OverlayPlacement.placement(saved: CGPoint(x: 3000, y: 600), minimal,
                                                screens: [laptop], main: laptop)
        XCTAssertEqual(placed?.strip, CGPoint(x: 1512 - m - 300, y: m))
    }

    func testNoScreensMeansNoPlacement() {
        XCTAssertNil(OverlayPlacement.placement(saved: nil, minimal, screens: [], main: nil))
    }

    func testTheStoredValueRoundTrips() {
        let origin = CGPoint(x: -1200, y: 37)
        XCTAssertEqual(OverlayPlacement.decode(OverlayPlacement.encode(origin)), origin)
        XCTAssertNil(OverlayPlacement.decode(""))
        XCTAssertNil(OverlayPlacement.decode("12"))
        XCTAssertNil(OverlayPlacement.decode("a,b"))
    }

    // MARK: Notices

    private let notice = CGSize(width: 340, height: 60)

    /// In the bottom half a notice opens above the overlay, right-aligned with it.
    func testANoticeOpensAboveAnOverlayInTheBottomHalf() {
        let overlay = CGRect(x: 1192, y: 20, width: 300, height: 44)
        XCTAssertEqual(OverlayPlacement.noticeOrigin(notice, beside: overlay, in: laptop),
                       CGPoint(x: 1492 - 340, y: 64 + 8))
    }

    /// In the top half it opens below, so it never covers the overlay nor leaves the screen.
    func testANoticeOpensBelowAnOverlayInTheTopHalf() {
        let overlay = CGRect(x: 600, y: 880, width: 300, height: 44)
        XCTAssertEqual(OverlayPlacement.noticeOrigin(notice, beside: overlay, in: laptop),
                       CGPoint(x: 900 - 340, y: 880 - 8 - 60))
    }

    /// An overlay too tall to leave room on either side holds the notice at the screen's edge.
    func testANoticeWithNoRoomIsHeldAtTheEdge() {
        let tall = CGRect(x: 600, y: 20, width: 300, height: 860)
        XCTAssertEqual(OverlayPlacement.noticeOrigin(notice, beside: tall, in: laptop).y, 944 - 60)
    }

    /// A strip at the left edge keeps the wider notice on the screen.
    func testANoticeStaysOnTheScreen() {
        let overlay = CGRect(x: 0, y: 20, width: 142, height: 56)
        XCTAssertEqual(OverlayPlacement.noticeOrigin(notice, beside: overlay, in: laptop).x, 0)
    }

    /// The overlay's bright half spans segments, unlike `segmentStableText`: a pause does
    /// not wipe the transcript the user is reading.
    func testStableTextSpansSegments() {
        var layer = TranscriptSpanLayer()
        layer.beginSegment()
        layer.ingest(committed: "Перше.", partial: "")
        layer.commitSegment("Перше.")
        layer.settleSegment()
        layer.beginSegment()
        layer.ingest(committed: "Друге.", partial: "ще")
        XCTAssertEqual(layer.stableText, "Перше. Друге.")
        XCTAssertEqual(layer.segmentStableText, "Друге.")
        XCTAssertEqual(layer.segmentProvisionalText, "ще")
    }
}

// MARK: - The minimal skin's transparency (GlassTransparency)

final class GlassTransparencyTests: XCTestCase {
    /// Nobody who never moved the slider sees their overlay change: the default is the
    /// material exactly as it was on macOS 14 and 15, and untinted `.regular` — the glass
    /// nearest it, measured — on 26.
    func testTheDefaultLooksAsTheSkinDidBefore() {
        XCTAssertEqual(GlassTransparency.default, .standard)
        XCTAssertEqual(GlassTransparency(stored: nil), .standard)
        XCTAssertEqual(GlassTransparency(stored: ""), .standard)
        XCTAssertEqual(GlassTransparency(stored: "opaque"), .standard)
        XCTAssertEqual(GlassTransparency(stored: "least"), .least)
        XCTAssertEqual(GlassTransparency.standard.glass, .regular)
        XCTAssertEqual(GlassTransparency.standard.material, MaterialFill(materialOpacity: 1, backgroundOpacity: 0))
    }

    /// The slider runs from most to least transparent, and each stop lets through less
    /// than the one before. On 26 that is the tint on `.clear`, with untinted `.regular`
    /// between 0.2 and 0.5 — where it measured in a window that is not key (backdrop kept
    /// 0.14, 0.11, 0.10, 0.07, 0.02 of its detail).
    func testEachStopLetsThroughLessThanTheOneBefore() {
        XCTAssertEqual(GlassTransparency.allCases, [.most, .more, .standard, .less, .least])
        let tints = GlassTransparency.allCases.map { stop -> Double? in
            if case .clear(let tint) = stop.glass { return tint }
            return nil
        }
        XCTAssertEqual(tints, [0, 0.2, nil, 0.5, 0.8])

        let fills = GlassTransparency.allCases.map(\.material)
        for (thinner, thicker) in zip(fills, fills.dropFirst()) {
            XCTAssertLessThanOrEqual(thinner.materialOpacity, thicker.materialOpacity)
            XCTAssertLessThanOrEqual(thinner.backgroundOpacity, thicker.backgroundOpacity)
            XCTAssertNotEqual(thinner, thicker)
        }
        for fill in fills {
            XCTAssert((0...1).contains(fill.materialOpacity) && (0...1).contains(fill.backgroundOpacity))
        }
    }

    /// With Reduce transparency every stop draws the same solid surface: `.clear` turns a
    /// dark grey under it even in light mode, and a thinned material lets the desktop in.
    func testReduceTransparencyLeavesNothingToAdjust() {
        for stop in GlassTransparency.allCases {
            XCTAssertEqual(stop.glass(reduceTransparency: true), .regular)
            XCTAssertEqual(stop.material(reduceTransparency: true), GlassTransparency.standard.material)
            XCTAssertEqual(stop.glass(reduceTransparency: false), stop.glass)
            XCTAssertEqual(stop.material(reduceTransparency: false), stop.material)
        }
    }

    func testEveryStopHasItsOwnName() {
        let titles = GlassTransparency.allCases.map(\.title)
        XCTAssertEqual(titles, ["Most", "More", "Default", "Less", "Least"])
    }
}

// MARK: - Shortcut conflicts

final class ShortcutConflictTests: XCTestCase {
    private let ctrlShift: NSEvent.ModifierFlags = [.control, .shift]

    private func shortcut(_ keyCode: UInt32, _ modifiers: NSEvent.ModifierFlags) -> KeyShortcut {
        KeyShortcut(keyCode: keyCode, modifiers: modifiers)
    }

    private var defaults: [ShortcutAction: KeyShortcut] {
        [.inline: shortcut(12, ctrlShift), .ai: shortcut(0, ctrlShift), .recordWindow: shortcut(13, ctrlShift)]
    }

    func testAnotherOfOurShortcutsIsAConflict() {
        XCTAssertEqual(ShortcutConflict.find(shortcut(0, ctrlShift), for: .inline, assigned: defaults, system: []),
                       .action(.ai))
        XCTAssertEqual(ShortcutConflict.find(shortcut(12, ctrlShift), for: .recordWindow, assigned: defaults, system: []),
                       .action(.inline))
    }

    func testReassigningTheSameShortcutToItselfIsNot() {
        XCTAssertNil(ShortcutConflict.find(shortcut(12, ctrlShift), for: .inline, assigned: defaults, system: []))
    }

    func testSameKeyWithOtherModifiersIsNot() {
        XCTAssertNil(ShortcutConflict.find(shortcut(0, [.control, .option]), for: .inline, assigned: defaults, system: []))
    }

    func testEnabledSystemShortcutIsAConflict() {
        let spotlight = KeyShortcut(keyCode: 49, carbonModifiers: UInt32(cmdKey))
        XCTAssertEqual(ShortcutConflict.find(shortcut(49, .command), for: .ai, assigned: defaults, system: [spotlight]),
                       .system)
    }

    func testOurOwnShortcutWinsOverTheSystemInTheMessage() {
        let system: Set<KeyShortcut> = [shortcut(0, ctrlShift)]
        XCTAssertEqual(ShortcutConflict.find(shortcut(0, ctrlShift), for: .inline, assigned: defaults, system: system),
                       .action(.ai))
    }

    func testModifierBitsBeyondTheFourAreIgnored() {
        // Caps Lock and fn ride along in the Cocoa flags; Carbon's system list never has them.
        XCTAssertEqual(shortcut(49, [.command, .capsLock, .function]),
                       KeyShortcut(keyCode: 49, carbonModifiers: UInt32(cmdKey) | UInt32(alphaLock)))
    }

    func testStoredFallsBackToTheBuiltInShortcut() {
        let suiteName = "ShortcutConflictTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(ShortcutAction.ai.stored(in: suite).keyCode, 0)
        XCTAssertEqual(ShortcutAction.recordWindow.stored(in: suite).modifiers, ctrlShift)
        suite.set(7, forKey: ShortcutAction.ai.keyCodeKey)
        suite.set(Int(NSEvent.ModifierFlags.command.rawValue), forKey: ShortcutAction.ai.modifierFlagsKey)
        XCTAssertEqual(ShortcutAction.ai.stored(in: suite).keyCode, 7)
        XCTAssertEqual(ShortcutAction.ai.stored(in: suite).modifiers, .command)
    }
}

final class ShortcutKeyPressTests: XCTestCase {
    private let ctrlShift: NSEvent.ModifierFlags = [.control, .shift]
    private let letterQ = UInt16(kVK_ANSI_Q)

    private func decide(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) -> ShortcutKeyPress {
        ShortcutKeyPress.decide(keyCode: UInt16(keyCode), flags: flags)
    }

    func testControlShiftLetterIsRecordedWithTheSameCarbonModifiers() {
        guard case .record(let keyCode, let modifiers) = decide(kVK_ANSI_Q, ctrlShift) else {
            return XCTFail("⌃⇧Q must be recorded")
        }
        XCTAssertEqual(keyCode, letterQ)
        XCTAssertEqual(KeyShortcut(keyCode: UInt32(keyCode), modifiers: modifiers),
                       KeyShortcut(keyCode: UInt32(letterQ), carbonModifiers: UInt32(controlKey | shiftKey)))
    }

    func testStrayFlagsAreDroppedFromWhatIsRecorded() {
        let flags: NSEvent.ModifierFlags = [.control, .shift, .capsLock, .function, .numericPad, .help]
        XCTAssertEqual(decide(kVK_ANSI_Q, flags), .record(keyCode: letterQ, modifiers: ctrlShift))
    }

    func testCapsLockAloneDoesNotMakeALetterAShortcut() {
        XCTAssertEqual(decide(kVK_ANSI_Q, .capsLock), .ignore)
        XCTAssertEqual(decide(kVK_ANSI_Q, [.capsLock, .function, .numericPad, .help]), .ignore)
    }

    func testBareEscapeGivesUpEvenWithCapsLockOn() {
        XCTAssertEqual(decide(kVK_Escape, []), .giveUp)
        XCTAssertEqual(decide(kVK_Escape, .capsLock), .giveUp)
        XCTAssertEqual(decide(kVK_Escape, [.capsLock, .function]), .giveUp)
    }

    func testEscapeWithARealModifierIsAShortcut() {
        XCTAssertEqual(decide(kVK_Escape, .command), .record(keyCode: UInt16(kVK_Escape), modifiers: .command))
    }

    func testAnArrowAloneIsRefusedWhateverTheKeyboardFlags() {
        // Arrow keys carry fn and the numeric-pad flag on their own.
        XCTAssertEqual(decide(kVK_LeftArrow, [.function, .numericPad]), .ignore)
        XCTAssertEqual(decide(kVK_Home, .function), .ignore)
        XCTAssertEqual(decide(kVK_PageDown, [.function, .capsLock]), .ignore)
        XCTAssertEqual(decide(kVK_Space, []), .ignore)
    }

    func testControlShiftArrowIsRecorded() {
        XCTAssertEqual(decide(kVK_RightArrow, [.control, .shift, .function, .numericPad]),
                       .record(keyCode: UInt16(kVK_RightArrow), modifiers: ctrlShift))
    }

    func testFunctionKeysAreTheOneBareException() {
        XCTAssertEqual(decide(kVK_F5, .function), .record(keyCode: UInt16(kVK_F5), modifiers: []))
        XCTAssertEqual(decide(kVK_F20, []), .record(keyCode: UInt16(kVK_F20), modifiers: []))
        XCTAssertEqual(ShortcutKeyPress.functionKeyNames.count, 20)
        XCTAssertEqual(ShortcutKeyPress.functionKeyNames[UInt16(kVK_F5)], "F5")
        XCTAssertEqual(ShortcutKeyPress.functionKeyNames[UInt16(kVK_F13)], "F13")
        XCTAssertEqual(ShortcutKeyPress.functionKeyNames[UInt16(kVK_F20)], "F20")
    }

    func testAModifierKeyOnItsOwnIsIgnored() {
        XCTAssertEqual(decide(kVK_Shift, .shift), .ignore)
        XCTAssertEqual(decide(kVK_CapsLock, .capsLock), .ignore)
    }
}

// MARK: - Debug Log levels (DebugLog)

/// The Debug Log's levels: their order, what the window's filter keeps, what Copy writes,
/// and which entries the in-memory buffer keeps. Each test logs into a fresh `DebugLog`
/// on the main thread, where `log` appends at once.
@MainActor
final class DebugLogLevelTests: XCTestCase {

    func testTheLevelsRunFromDebugToFaultAndMapOntoTheSystemLogs() {
        XCTAssertEqual(DebugLog.Level.allCases, [.debug, .info, .notice, .error, .fault])
        XCTAssertEqual(DebugLog.Level.allCases.sorted(), DebugLog.Level.allCases)
        XCTAssertEqual(DebugLog.Level.allCases.map(\.osLogType), [.debug, .info, .default, .error, .fault])
    }

    func testAnEntryWithNoLevelIsInfo() {
        let log = DebugLog()
        log.log("Engine", "phase: idle → starting")
        XCTAssertEqual(log.entries.map(\.level), [.info])
    }

    func testDebugEntriesAreKeptOnlyWhileAskedFor() {
        let log = DebugLog()
        log.keepsDebugEntries = false
        log.log("Span", "partial", level: .debug)
        log.log("Engine", "phase", level: .info)
        log.log("Groq", "HTTP 500", level: .error)
        XCTAssertEqual(log.entries.map(\.category), ["Engine", "Groq"], "a debug line is dropped")

        log.keepsDebugEntries = true
        log.log("Span", "partial", level: .debug)
        XCTAssertEqual(log.entries.last?.level, .debug)
    }

    func testTheWindowsFilterKeepsALevelAndAboveThatMatchTheQuery() {
        let log = DebugLog()
        log.keepsDebugEntries = true
        log.log("Span", "partial 3", level: .debug)
        log.log("Engine", "phase: idle → starting")
        log.log("Engine", "⚠ slow start", level: .notice)
        log.log("Groq", "transcribe: HTTP 500", level: .error)
        log.log("Engine", "no configuration", level: .fault)

        func shown(_ level: DebugLog.Level, _ query: String = "") -> [String] {
            DebugLog.filtered(log.entries, minimumLevel: level, matching: query).map(\.message)
        }
        XCTAssertEqual(shown(.debug).count, 5)
        XCTAssertEqual(shown(.info).count, 4, "Hide debug")
        XCTAssertEqual(shown(.notice), ["⚠ slow start", "transcribe: HTTP 500", "no configuration"])
        XCTAssertEqual(shown(.error), ["transcribe: HTTP 500", "no configuration"])
        XCTAssertEqual(shown(.debug, "groq"), ["transcribe: HTTP 500"], "the category matches, ignoring case")
        XCTAssertEqual(shown(.error, "slow"), [], "a match below the level stays hidden")
    }

    func testCopyWritesTheLevelBesideTheCategory() {
        let log = DebugLog()
        log.log("Engine", "phase: idle → starting")
        log.log("Groq", "transcribe: HTTP 500", level: .error)
        let lines = log.formatted().components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix(" INFO   [Engine] phase: idle → starting"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix(" ERROR  [Groq] transcribe: HTTP 500"), lines[1])
        XCTAssertNotNil(lines[1].range(of: #"^\d\d:\d\d:\d\d\.\d{3} "#, options: .regularExpression))
        // A filtered Copy is written the same way.
        XCTAssertEqual(DebugLog.formatted(DebugLog.filtered(log.entries, minimumLevel: .error, matching: "")),
                       lines[1])
    }
}
