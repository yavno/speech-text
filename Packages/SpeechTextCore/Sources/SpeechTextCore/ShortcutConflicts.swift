// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon.HIToolbox

/// A key combination as Carbon's hotkey APIs see it: a virtual key code and the four
/// modifiers a global shortcut can carry. Anything else in the mask (Caps Lock, the
/// fn key) is dropped, so two routes to the same combination compare equal.
public struct KeyShortcut: Hashable, Sendable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32

    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers & Self.modifierMask
    }

    public init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: keyCode, carbonModifiers: Self.carbonModifiers(modifiers))
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

/// What the shortcut recorder does with a key pressed while it listens.
public enum ShortcutKeyPress: Equatable, Sendable {
    /// Take it. `modifiers` holds ⌘⌥⌃⇧ only, so what is stored and drawn is what Carbon
    /// registers.
    case record(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)
    /// A bare ⎋: leave the recorder, since every global shortcut is off meanwhile.
    case giveUp
    /// Not a shortcut: a modifier key on its own, or a key that needs a modifier and has none.
    case ignore

    /// The four modifiers a global shortcut can carry. `deviceIndependentFlagsMask`
    /// would also pass Caps Lock, fn, the numeric pad and help — flags a keyboard sets
    /// on its own (every arrow key and F-key carries fn) and Carbon drops, which
    /// registered a bare key no other app receives.
    static let shortcutModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Key codes of the modifier keys themselves (left and right ⌘⇧⌥⌃, Caps Lock, fn).
    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// F1–F20 by name: they type nothing, so unlike a letter they are usable as a shortcut
    /// alone — and the layout has no character to draw them with (it answers U+0010).
    public static let functionKeyNames: [UInt16: String] = {
        let codes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        return Dictionary(uniqueKeysWithValues: codes.enumerated().map { (UInt16($1), "F\($0 + 1)") })
    }()

    public static func decide(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> ShortcutKeyPress {
        guard !modifierKeyCodes.contains(keyCode) else { return .ignore }
        let modifiers = flags.intersection(shortcutModifiers)
        if modifiers.isEmpty {
            if keyCode == UInt16(kVK_Escape) { return .giveUp }
            guard functionKeyNames[keyCode] != nil else { return .ignore }
        }
        return .record(keyCode: keyCode, modifiers: modifiers)
    }
}

/// The app's four global shortcuts, with where each is stored and what it is until
/// the user changes it.
public enum ShortcutAction: CaseIterable, Hashable, Sendable {
    case inline
    case ai
    case edit
    case recordWindow

    public var title: String {
        switch self {
        case .inline: return "Inline Recording"
        case .ai: return "AI Recording"
        case .recordWindow: return "Record Window"
        case .edit: return "Edit Selection with AI"
        }
    }

    public var keyCodeKey: String {
        switch self {
        case .inline: return SettingsKeys.hotkeyKeyCode
        case .ai: return SettingsKeys.aiHotkeyKeyCode
        case .recordWindow: return SettingsKeys.recordWindowHotkeyKeyCode
        case .edit: return SettingsKeys.editHotkeyKeyCode
        }
    }

    public var modifierFlagsKey: String {
        switch self {
        case .inline: return SettingsKeys.hotkeyModifierFlags
        case .ai: return SettingsKeys.aiHotkeyModifierFlags
        case .recordWindow: return SettingsKeys.recordWindowHotkeyModifierFlags
        case .edit: return SettingsKeys.editHotkeyModifierFlags
        }
    }

    var defaultKeyCode: UInt32 {
        switch self {
        case .inline: return 12        // Q
        case .ai: return 0             // A
        case .recordWindow: return 13  // W
        case .edit: return 14          // E
        }
    }

    static let defaultModifiers: NSEvent.ModifierFlags = [.control, .shift]

    /// The stored combination, or the built-in one when none has been saved. Tests
    /// pass their own suite rather than the user's defaults.
    public func stored(in defaults: UserDefaults) -> (keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        guard defaults.object(forKey: keyCodeKey) != nil else {
            return (defaultKeyCode, Self.defaultModifiers)
        }
        return (UInt32(defaults.integer(forKey: keyCodeKey)),
                NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: modifierFlagsKey))))
    }
}

/// Who else already answers a combination.
public enum ShortcutConflict: Equatable, Sendable {
    /// Another of the app's own shortcuts. Carbon hands a combination to one
    /// registration only, so the second would never fire.
    case action(ShortcutAction)
    /// An enabled macOS shortcut (System Settings › Keyboard › Keyboard Shortcuts).
    /// The system takes those before any app sees them.
    case system

    /// What `candidate` would collide with if it became `action`'s shortcut. Only
    /// what can be known is checked: our own shortcuts and the system's. A global
    /// shortcut another app took through an event tap cannot be listed by anyone.
    public static func find(_ candidate: KeyShortcut,
                     for action: ShortcutAction,
                     assigned: [ShortcutAction: KeyShortcut],
                     system: Set<KeyShortcut>) -> ShortcutConflict? {
        for other in ShortcutAction.allCases where other != action {
            if assigned[other] == candidate { return .action(other) }
        }
        return system.contains(candidate) ? .system : nil
    }
}
