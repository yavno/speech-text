// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the Accessibility API will actually let us do to the focused text element.
///
/// Read-back is the load-bearing field. Chromium and Electron answer `.success` to a
/// selected-range *write* and then hand back a different range when asked, so anything
/// that trusts the return code alone classifies VS Code and Slack as correctable and
/// then scribbles over the user's text.
public struct AXTextProbe: Equatable, Sendable {
    /// `kAXValueAttribute` could be read as a string.
    public var valueReadable: Bool = false
    /// `kAXSelectedTextRangeAttribute` could be read.
    public var rangeReadable: Bool = false
    /// Writing it was accepted *and* reading it back returned what was written.
    public var rangeReadsBack: Bool = false

    public init(valueReadable: Bool = false, rangeReadable: Bool = false, rangeReadsBack: Bool = false) {
        self.valueReadable = valueReadable
        self.rangeReadable = rangeReadable
        self.rangeReadsBack = rangeReadsBack
    }

    /// Nothing is known — no accessibility permission, or no focused element at all.
    public static let unavailable = AXTextProbe()

    /// Everything needed to find text again and re-select it.
    var supportsReplacement: Bool { valueReadable && rangeReadable && rangeReadsBack }

    /// Whether writing back the selection a field reports can prove anything: only a range
    /// inside text the field actually holds. A caret at 0 of a field with text is how
    /// Chromium answers when it knows nothing. An empty value is how VS Code answers: the
    /// focused element is Monaco's hidden textarea, which holds no text and reports 0+0
    /// whatever is selected in the editor, and reads 0+0 back. Taken for Tier A, the
    /// selection read through AX held no words and the Edit shortcut said "No text
    /// selected" with text selected (VS Code 1.146, 2026-11-13); refused here, it is read
    /// with a ⌘C.
    public static func canTestSelection(location: Int, length: Int, documentLength: Int) -> Bool {
        guard documentLength > 0, location >= 0, length >= 0 else { return false }
        guard location + length <= documentLength else { return false }
        return !(location == 0 && length == 0)
    }
}

/// How far the Accessibility API can be trusted in the field in front. The Edit shortcut
/// asks when it reads the selection: Tier A's selection is read directly, with its range,
/// and re-selected before it is cut; everything else is read with a ⌘C.
///
/// Pure logic, so the decision is testable without an app to focus: `PasteService` does
/// the Accessibility I/O and hands the answers in as an `AXTextProbe`.
///
/// It used to decide much more — whether an inline dictation was pasted span by span
/// while the user spoke, and whether the stop could correct what was already pasted.
/// Every inline dictation is now shown on the overlay and pasted once, at the stop, so
/// only the selection read is left.
public enum DeliveryTier: String, Equatable, CustomStringConvertible, Sendable {
    /// Our own surface, or a foreign app whose text the Accessibility API can read and
    /// re-select. Text there can be found again and replaced.
    case a
    /// Everything else: Chromium and Electron, which answer inconsistently for
    /// `contenteditable`, and terminals, which never answer at all.
    case b

    public var description: String {
        switch self {
        case .a: return "A (correctable)"
        case .b: return "B (append-only)"
        }
    }

    /// The decision, in order: our own surface needs no probing, and a
    /// foreign app is Tier A only if it proved it.
    public static func resolve(isOwnSurface: Bool, probe: AXTextProbe) -> DeliveryTier {
        if isOwnSurface { return .a }
        return probe.supportsReplacement ? .a : .b
    }
}
