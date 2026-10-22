// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What one press or release of the Edit shortcut does.
public enum EditHotkeyAction: Equatable, Sendable {
    /// Read the selection and open the microphone for an instruction.
    case start
    /// Close the microphone and rewrite the selection as the instruction says.
    case send
    /// Rewrite the selection now, with no instruction; whatever was recorded is dropped.
    case sendWithoutInstruction
    case cancel(EditCancelReason)
    case ignore
}

/// Why an edit was cancelled — what its notice says. No cancel is silent, as for a
/// dictation: the selection may already have been cut and put back, and with
/// nothing on screen the text blinking out and in again reads as a fault.
public enum EditCancelReason: Equatable, Sendable {
    /// The Edit shortcut pressed while the instruction was transcribed or rewritten.
    case shortcut
    /// Hold to talk: a lone tap.
    case tap
    case escape
    /// The overlay's ✕.
    case closeButton
    /// A dictation shortcut, the Record Window's, or a dictation menu item: the user
    /// wants something else.
    case otherShortcut
    /// The menu's Edit item.
    case menu

    /// The notice's title and detail. `textPutBack`: the selection had been cut and was
    /// pasted back where it was. The detail fits the notice's two lines.
    public func notice(textPutBack: Bool) -> (title: String, detail: String) {
        switch self {
        case .tap:
            return ("Edit cancelled", "A quick tap cancels. Hold the shortcut while you speak, or double-tap to polish.")
        case .shortcut, .escape, .closeButton, .otherShortcut, .menu:
            return ("Edit cancelled", textPutBack ? "Nothing was changed. The text was put back." : "Nothing was changed.")
        }
    }
}

/// Turns presses and releases of the Edit shortcut (⌃⇧E) into actions.
///
/// The Edit shortcut rewrites the text selected in the app in front, optionally told how
/// by a spoken instruction. A double press means "just do it": no instruction.
///
/// Neither form waits to find out whether a second press is coming. The first press
/// always opens the microphone, so a spoken instruction never loses its first syllable,
/// and the second press is read retroactively:
///
/// - Toggle (hold-to-talk off): a second press within `doubleTapWindow` of the first is
///   a double press — the fraction of a second recorded is dropped and the selection goes
///   out with no instruction. A later second press is the ordinary stop.
/// - Hold to talk: letting go after a hold sends the instruction. Letting go within
///   `DictationHotkeyGesture.tapThreshold` is a tap; a second press within
///   `doubleTapWindow` of that release makes it a double press, and no second press at
///   all cancels, when `tapWindowExpired` is called — a lone tap does nothing, as a lone
///   tap of a dictation shortcut does nothing with hold-to-talk on.
///
/// Once the audio is closed (transcribing the instruction, rewriting) a press cancels.
///
/// Its own type rather than a third case of `DictationHotkey`: the two dictation modes
/// switch into each other mid-recording, and an edit switches into neither — its
/// recording is an instruction, and pasting it as a dictation would be nonsense.
/// `AppState` keeps the two apart: a dictation shortcut pressed during an edit cancels
/// the edit, and the Edit shortcut is ignored while a dictation runs.
///
/// Pure logic; `AppState` supplies the phase and performs the action.
public struct EditHotkeyGesture: Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The microphone is not open yet.
        case starting
        case recording
        /// Transcribing the instruction, reading the selection, or rewriting.
        case busy
    }

    /// How close two presses have to be to count as one double press.
    public static let doubleTapWindow: TimeInterval = 0.35

    public var holdToTalk = false

    /// When the press that started this edit arrived. Nil once a second press has
    /// been judged, or for an edit started from the menu, which has no key to double.
    private var startedAt: TimeInterval?
    /// Hold to talk: the key that started the edit is still down.
    public private(set) var isHeld = false
    /// Hold to talk: when a tap ended, while it may still become a double press.
    private var tapReleasedAt: TimeInterval?
    /// The release of the press that made a double press — it must not act again.
    private var swallowsRelease = false

    public init(holdToTalk: Bool = false) {
        self.holdToTalk = holdToTalk
    }

    /// A tap that has not yet been told apart from the first half of a double press.
    /// `AppState` calls `tapWindowExpired` `doubleTapWindow` after the release.
    public var awaitsSecondTap: Bool { tapReleasedAt != nil }

    public mutating func press(in phase: Phase, at time: TimeInterval) -> EditHotkeyAction {
        switch phase {
        case .idle:
            reset()
            startedAt = time
            isHeld = holdToTalk
            return .start
        case .busy:
            reset()
            return .cancel(.shortcut)
        case .starting, .recording:
            break
        }

        if holdToTalk {
            if let released = tapReleasedAt, time - released <= Self.doubleTapWindow {
                reset()
                swallowsRelease = true
                return .sendWithoutInstruction
            }
            // The key is down again with no tap pending: its release was missed, or the
            // edit came from the menu. A press of the key that started it stops it.
            reset()
            swallowsRelease = true
            return .send
        }

        if let startedAt, time - startedAt <= Self.doubleTapWindow {
            reset()
            return .sendWithoutInstruction
        }
        reset()
        return .send
    }

    public mutating func release(in phase: Phase, at time: TimeInterval) -> EditHotkeyAction {
        if swallowsRelease {
            swallowsRelease = false
            return .ignore
        }
        guard holdToTalk, isHeld else { return .ignore }
        isHeld = false
        switch phase {
        case .starting, .recording:
            if let startedAt, time - startedAt < DictationHotkeyGesture.tapThreshold {
                tapReleasedAt = time
                return .ignore
            }
            reset()
            return .send
        case .idle, .busy:
            reset()
            return .ignore
        }
    }

    /// `doubleTapWindow` after a tap's release, with no second press: the tap was all
    /// there was, and cancels.
    public mutating func tapWindowExpired(in phase: Phase, at time: TimeInterval) -> EditHotkeyAction {
        guard let released = tapReleasedAt, time - released >= Self.doubleTapWindow * 0.9 else { return .ignore }
        reset()
        switch phase {
        case .starting, .recording: return .cancel(.tap)
        case .idle, .busy: return .ignore
        }
    }

    /// A menu item: no key is held, and none will be pressed twice.
    public mutating func click(in phase: Phase) -> EditHotkeyAction {
        reset()
        switch phase {
        case .idle: return .start
        case .starting, .recording: return .send
        case .busy: return .cancel(.menu)
        }
    }

    public mutating func reset() {
        startedAt = nil
        isHeld = false
        tapReleasedAt = nil
        swallowsRelease = false
    }
}

/// What the Edit shortcut found selected in the app in front.
public struct CapturedSelection: Equatable, Sendable {
    public let text: String
    /// Where it is, when the AX API could say (Tier A): these words are found again and
    /// re-selected before the cut. Nil when it was read with ⌘C — the cut then takes what
    /// is selected, and is checked by what it took.
    public let record: InsertionRecord?

    public init(text: String, record: InsertionRecord?) {
        self.text = text
        self.record = record
    }
}

/// The pure half of reading and replacing a selection; `PasteService` does the I/O.
public enum SelectionEdit {
    /// What the edit works on once the instruction is over: the selection as it
    /// is *then*, read again, not the one read at the first press — the user may have
    /// selected other text while speaking, and the text they can see selected is the
    /// text they mean. The first read still stops an edit with nothing selected at once.
    public enum Target: Equatable, Sendable {
        /// The same text, where it was.
        case unchanged(CapturedSelection)
        /// Other text is selected now; this is what gets rewritten.
        case changed(CapturedSelection)
        case nothingSelected
        case tooLong
    }

    /// Whether the selection may be read again and cut once the instruction is over: only
    /// while the app the edit began in is still the one in front. A ⌘C and a ⌘X go to
    /// whichever app is in front, and the rewrite is pasted into the app the edit began
    /// in — so with another app in front (⌘Tab works while the shortcut is held) the
    /// edit would cut text out of one app and paste its rewrite into the other. Generic
    /// over the process identifier, so a test needs no running app.
    public static func takesSelection<ID: Equatable>(editing app: ID?, front: ID?) -> Bool {
        guard let app else { return false }
        return app == front
    }

    public static func target(read: CapturedSelection, current: CapturedSelection?) -> Target {
        guard let current else { return .nothingSelected }
        guard current.text.count <= maxCharacters else { return .tooLong }
        let same = current.text == read.text && current.record?.range == read.record?.range
        return same ? .unchanged(current) : .changed(current)
    }

    /// Longer than this, a selection is refused rather than sent: the rewrite would be
    /// slow and expensive on a cloud model and beyond a small local one, and the whole
    /// of it comes back as one paste the user waits for.
    public static let maxCharacters = 20_000

    /// Whether a ⌘C put a whole *line* on the pasteboard because nothing was selected.
    /// VS Code (and editors built on Monaco) copy the caret's line on an empty selection
    /// and say so in their own pasteboard type; taking that line for a selection would
    /// rewrite text the user never chose.
    public static func isEmptySelectionLineCopy(_ pasteboardStrings: [String: String]) -> Bool {
        for (type, value) in pasteboardStrings where type.localizedCaseInsensitiveContains("vscode") {
            if value.replacingOccurrences(of: " ", with: "").contains("\"isFromEmptySelection\":true") {
                return true
            }
        }
        return false
    }

    /// The selection's words: `range` (UTF-16, as the AX API reports it) of `document`,
    /// less the whitespace at either end, with the text it covers. A model trims its
    /// answer, so a selection taken with its trailing newline would otherwise have that
    /// newline replaced away and the next paragraph glued on. Nil when the range is empty,
    /// outside the document, or only whitespace — nothing to rewrite.
    public static func words(in range: NSRange, of document: String) -> InsertionRecord? {
        let text = document as NSString
        guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        let selected = text.substring(with: range)
        let lead = selected.prefix { $0.isWhitespace }.utf16.count
        guard lead < selected.utf16.count else { return nil }
        let trail = String(selected.reversed().prefix { $0.isWhitespace }).utf16.count
        let core = NSRange(location: range.location + lead, length: range.length - lead - trail)
        return InsertionRecord(span: nil, range: core, text: text.substring(with: core))
    }

    /// Whether a ⌘X took the selection that was read, and not something the user selected
    /// since — or, in VS Code with the selection gone, the caret's whole line. Edges aside:
    /// a Tier A selection is recorded trimmed to its words. Markup and whitespace aside
    /// too: an editor that renders Markdown (T3 Code's composer) reports the rendered text
    /// through AX — no backticks, one newline between paragraphs — while its ⌘X copies the
    /// source, and the two are the same selection.
    ///
    /// `selectionConfirmed` is a Tier A cut whose range the field itself confirmed as its
    /// selection just before the ⌘X: the cut is then the user's selection by construction,
    /// and a difference can only be AX's value disagreeing with its own offsets. Chromium's
    /// does at a paragraph ending in a space — the value keeps the space, the offsets skip
    /// it — so the words read are the selection shifted by a character or two (T3 Code
    /// and Claude, 2026-10-06: a 128-character read of a 129-character selection, its
    /// last letter missing). Such a cut counts when it is the read shifted by at most
    /// `maxConfirmedShift` characters at its edges.
    public static func cutMatches(_ cut: String, selection: String, selectionConfirmed: Bool = false) -> Bool {
        let core = markupInsensitive(cut)
        guard !core.isEmpty else { return false }
        let read = markupInsensitive(selection)
        if core == read { return true }
        guard selectionConfirmed else { return false }
        return isShifted(Array(core.unicodeScalars), Array(read.unicodeScalars))
            || isShifted(Array(read.unicodeScalars), Array(core.unicodeScalars))
    }

    /// How far a confirmed selection's read may be off its cut, per edge.
    static let maxConfirmedShift = 8

    /// Whether `b` is `a` moved along the document: `a` less a few characters at its start
    /// is `b` less a few at its end, and what they share is most of both.
    private static func isShifted(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Bool {
        for head in 0...maxConfirmedShift where head < a.count {
            for tail in 0...maxConfirmedShift where tail < b.count {
                let shared = a.count - head
                guard shared == b.count - tail, shared * 2 > max(a.count, b.count) else { continue }
                if a[head...] == b[..<shared] { return true }
            }
        }
        return false
    }

    /// What the edit rewrites once the selection is cut: the cut text, edges trimmed. It is
    /// what is in the document — Markdown source where AX read the rendering — so the
    /// rewrite keeps its backticks and paragraphs.
    public static func cutSource(_ cut: String) -> String {
        cut.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Characters Markdown spends on markup, which a rendering drops.
    private static let markupCharacters = CharacterSet(charactersIn: "`*_~#>")

    private static func markupInsensitive(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !markupCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }))
    }

    /// Whether the rewrite changes anything worth writing back.
    public static func changes(_ selection: String, to output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != selection.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The rewrite, carrying the whitespace the cut selection had around it. A model trims
    /// its answer, and a selection cut with its trailing newline or space would otherwise
    /// glue the next paragraph or word onto the result.
    public static func preservingEdges(of selection: String, _ output: String) -> String {
        let core = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = selection.prefix { $0.isWhitespace || $0.isNewline }
        let trailing = String(selection.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
        guard leading.count < selection.count else { return core }
        return String(leading) + core + trailing
    }
}
