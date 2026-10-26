// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import SpeechTextCore

// MARK: - Skins

/// Which chassis the recording surfaces wear.
///
/// A skin changes only the chrome. Both skins expose exactly the same actions, because
/// switching appearance must never quietly take a feature away — anything you can do
/// in one you can do in the other, and `RecordingOverlayView` / `DirectRecordingPanelView`
/// keep both variants side by side in the same file so the two can't drift apart.
///
/// Adding a third skin means: a case here, its two sizes, and a `body` branch in each
/// of those two views.
/// The cases are in the order Settings lists them, the default first.
enum AppSkin: String, CaseIterable, Identifiable {
    /// The moulded handset with the dark-green dot-matrix LCD, drawn to the design file.
    case techno
    /// Native macOS: material panels, SF Symbols, a bar waveform. Neutral by default.
    case minimal

    /// What an install that never picked a skin wears — and what an unreadable stored
    /// value reads as.
    static let `default` = AppSkin.techno

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .techno: return "Techno"
        }
    }

    var detail: String {
        switch self {
        case .minimal: return "Native macOS panels on glass. Tint them if you want to."
        case .techno: return "A molded handset with a dot-matrix LCD."
        }
    }

    /// Whether the free accent colour applies. Techno is drawn to a design — every colour
    /// in it was matched against the design file, so letting any colour loose in there
    /// would only break it; its colour is a whole `TechnoPalette` instead (DesignKit.swift).
    var supportsAccent: Bool { self == .minimal }

    /// Size of the inline overlay's strip — the meter and the cancel button.
    var overlayStripSize: CGSize {
        switch self {
        case .minimal: return CGSize(width: 300, height: 44)
        // Glass (100 × 56) + gap (6) + the cancel button in its rail (36).
        case .techno: return CGSize(width: 142, height: 56)
        }
    }

    /// The inline overlay's shape. `showsTranscript`: a streaming recording, whose text is
    /// built on the overlay and pasted once at the stop.
    func overlayGeometry(showsTranscript: Bool) -> OverlayGeometry {
        let strip = overlayStripSize
        guard showsTranscript else { return OverlayGeometry(strip: strip) }
        switch self {
        // The transcript sits inside the same glass as the strip.
        case .minimal:
            return OverlayGeometry(strip: strip, transcriptWidth: strip.width, maxTranscriptHeight: 112)
        // Techno's strip is drawn to the design and too narrow to read from, so the
        // transcript is a wider glass of its own, beside which the strip hangs at the right.
        case .techno:
            return OverlayGeometry(strip: strip, transcriptWidth: 260, maxTranscriptHeight: 104, gap: 6)
        }
    }

    /// Size of the record window.
    var recordPanelSize: CGSize {
        switch self {
        case .minimal: return CGSize(width: 380, height: 260)
        case .techno: return CGSize(width: 362, height: 284)
        }
    }

    /// The skin as stored. Read this from AppKit code; SwiftUI views should use
    /// `@AppStorage` instead so they redraw when it changes.
    static var current: AppSkin {
        AppSkin(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.appSkin) ?? "")
            ?? .default
    }
}

// MARK: - Accent

/// The colour the minimal skin is tinted with — if the user wants one at all.
///
/// Stored as `#RRGGBB` because UserDefaults has no colour type, and a hex string stays
/// readable in `defaults read` and survives the rename migration like any other setting.
enum AccentColor {
    /// Stored value meaning "no accent": ink on glass with a red record button, which
    /// is what the app has always looked like and what it still starts as. Tinting the
    /// whole panel is opt-in, because an accent applied to everything turns a quiet
    /// sliver of glass into a coloured object.
    static let neutral = ""

    /// Used when a stored colour can't be parsed.
    static let fallback = "#FF453A"

    static func isNeutral(_ hex: String) -> Bool {
        hex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let presets: [(name: String, hex: String)] = [
        ("Default — glass", neutral),
        ("Red", "#FF453A"),
        ("Orange", "#FF9F0A"),
        ("Yellow", "#FFD60A"),
        ("Green", "#30D158"),
        ("Teal", "#40C8E0"),
        ("Blue", "#0A84FF"),
        ("Purple", "#BF5AF2"),
        ("Pink", "#FF375F"),
        ("Graphite", "#98989D"),
    ]

    /// What the level meter and the language badge are drawn in: ink on the glass,
    /// unless the user asked for a colour.
    ///
    /// `.primary`, not a hard-coded white — the strip floats over whatever the user is
    /// working in and inherits the system appearance, so white would be white-on-white
    /// in light mode. In dark mode it resolves to the white this has always been.
    static func meter(_ hex: String) -> Color {
        isNeutral(hex) ? .primary : color(from: hex)
    }

    /// The record transport. Red until the user picks something else — it reads as a
    /// record button first and a brand colour second.
    static func transport(_ hex: String) -> Color {
        isNeutral(hex) ? Color(hex: 0xFF453A) : color(from: hex)
    }

    static func color(from hex: String) -> Color {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            // Not `color(from: fallback)` — a bad fallback would recurse forever.
            return Color(hex: 0xFF453A)
        }
        return Color(hex: value)
    }

    static func hex(from color: Color) -> String {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return fallback }
        return String(
            format: "#%02X%02X%02X",
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded())
        )
    }
}

// MARK: - Semantic colours

/// Colours that mean something rather than decorate something, so they hold across
/// every skin and are deliberately not the user's accent.
enum Semantic {
    /// AI mode. Fixed on purpose: if it followed the accent, a user who picked violet
    /// would have no way to tell a rewritten dictation from a plain one.
    static let ai = Color(hex: 0x9E7BFF)
    /// The momentary flash after copy / paste / send. Green means "that worked",
    /// whatever colour the rest of the panel happens to be.
    static let confirmation = Color(hex: 0x30D158)
}

// MARK: - Cursor

extension View {
    /// Shows the pointing-hand cursor while the pointer is over this view.
    ///
    /// `NSCursor.push()`/`pop()` is what this replaces: a view dismissed under the
    /// pointer (the overlay closing mid-hover) never sees the exit, so the push is
    /// never popped and the whole app keeps a hand cursor. `set()` is reapplied by
    /// AppKit on the next cursor update, so a missed exit corrects itself.
    ///
    /// `onHover` is forwarded before `enabled` is consulted, so a disabled control
    /// still drives its own hover animation.
    func pointingHandCursor(enabled: Bool = true, onHover: @escaping (Bool) -> Void = { _ in }) -> some View {
        modifier(PointingHandCursor(enabled: enabled, onHoverChange: onHover))
    }
}

private struct PointingHandCursor: ViewModifier {
    let enabled: Bool
    let onHoverChange: (Bool) -> Void

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                onHoverChange(hovering)
                guard enabled else { return }
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onDisappear {
                if isHovering, enabled { NSCursor.arrow.set() }
                isHovering = false
            }
    }
}

extension Notification.Name {
    /// Posted when the appearance changes. SwiftUI content reflows on its own through
    /// `@AppStorage`, but the `NSPanel` around it has to be resized by hand.
    static let skinDidChange = Notification.Name("skinDidChange")
}
