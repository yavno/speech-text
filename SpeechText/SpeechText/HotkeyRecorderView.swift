// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import Carbon.HIToolbox
import SpeechTextCore

struct HotkeyRecorderView: View {
    let action: ShortcutAction
    /// How the shortcut is used, under its name, where that is not obvious.
    var detail: LocalizedStringKey?

    @State private var keyCode: Int
    @State private var modifierFlags: Int
    @State private var isRecording = false
    @State private var localMonitor: Any?
    /// Why the last combination pressed was not taken. Cleared by the next attempt.
    @State private var refusal: LocalizedStringResource?
    /// Read when the row appears; the user can change them in System Settings meanwhile,
    /// so a recording re-reads them before checking.
    @State private var systemShortcuts: Set<KeyShortcut> = []

    private let registration = HotkeyRegistrationStatus.shared

    init(action: ShortcutAction, detail: LocalizedStringKey? = nil) {
        self.action = action
        self.detail = detail
        let stored = action.stored(in: .standard)
        _keyCode = State(initialValue: Int(stored.keyCode))
        _modifierFlags = State(initialValue: Int(stored.modifiers.rawValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: action.title)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(SetupColor.label2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Button(action: toggleRecording) {
                    if isRecording {
                        Text("Press shortcut...")
                            .foregroundStyle(SetupColor.danger)
                            .frame(minWidth: 140)
                    } else {
                        // Drawn as keys, lit while held — as in setup — so pressing the
                        // shortcut here shows what it does.
                        LiveShortcutKeycaps(action: action, text: currentDisplayString, size: 18, ai: action == .ai)
                            .frame(minWidth: 140)
                    }
                }
            }
            if let warning {
                Label { Text(warning) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { systemShortcuts = HotkeyManager.enabledSystemShortcuts() }
        // Every global shortcut is off while this listens, so any way out of the window
        // has to end it — `onDisappear` alone does not fire when a window is closed.
        .onDisappear { stopListening() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in stopListening() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stopListening() }
    }

    private var currentShortcut: KeyShortcut {
        KeyShortcut(keyCode: UInt32(keyCode), modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifierFlags)))
    }

    private var currentDisplayString: String {
        shortcutDisplayString(keyCode: UInt16(keyCode), modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlags)))
    }

    /// The refusal of a combination just pressed, else a problem with the one in place:
    /// macOS would not register it, or it collides with a shortcut that takes it first.
    private var warning: LocalizedStringResource? {
        if let refusal { return refusal }
        // Before the registration status: one of ours twice fails with the same
        // `eventHotKeyExistsErr` another app's reservation does, and naming the
        // shortcut it collides with is the more useful answer.
        if let conflict = ShortcutConflict.find(currentShortcut, for: action,
                                                assigned: Self.assignedShortcuts(),
                                                system: systemShortcuts) {
            return Self.describe(conflict, display: currentDisplayString)
        }
        if let status = registration.failures[action] {
            return status == OSStatus(eventHotKeyExistsErr)
                ? "\(currentDisplayString) is reserved by another app, so it won't work. Choose another shortcut."
                : "macOS refused \(currentDisplayString) (error \(Int(status))). Choose another shortcut."
        }
        return nil
    }

    private static func describe(_ conflict: ShortcutConflict, display: String) -> LocalizedStringResource {
        switch conflict {
        case .action(let other):
            return "\(display) is already the \(other.title) shortcut. Choose another one."
        case .system:
            return "macOS also uses \(display) (System Settings › Keyboard › Keyboard Shortcuts), and may take it first."
        }
    }

    private static func assignedShortcuts() -> [ShortcutAction: KeyShortcut] {
        var assigned: [ShortcutAction: KeyShortcut] = [:]
        for action in ShortcutAction.allCases {
            let stored = action.stored(in: .standard)
            assigned[action] = KeyShortcut(keyCode: stored.keyCode, modifiers: stored.modifiers)
        }
        return assigned
    }

    private func toggleRecording() {
        if isRecording {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        isRecording = true
        refusal = nil
        systemShortcuts = HotkeyManager.enabledSystemShortcuts()
        // Our own shortcuts are unregistered while this listens, or pressing one of them
        // would start a dictation instead of arriving here as a duplicate.
        NotificationCenter.default.post(name: .hotkeyRecorderDidStart, object: nil)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let press = ShortcutKeyPress.decide(keyCode: event.keyCode, flags: event.modifierFlags)
            let mods: NSEvent.ModifierFlags
            switch press {
            case .ignore:
                return event
            case .giveUp:
                // Everything is paused until this stops listening.
                stopListening()
                return nil
            case .record(_, let recorded):
                mods = recorded
            }

            // One of our own shortcuts twice cannot work, so it is refused. A system
            // shortcut is only warned about (below the row, once saved): the ones macOS
            // really acts on never reach this monitor, so one that did is most likely
            // bound to a context it is not in, and refusing it would be a false alarm.
            let candidate = KeyShortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
            if let conflict = ShortcutConflict.find(candidate, for: action,
                                                    assigned: Self.assignedShortcuts(), system: []) {
                refusal = Self.describe(conflict, display: shortcutDisplayString(keyCode: event.keyCode, modifierFlags: mods))
                stopListening()
                return nil
            }

            self.keyCode = Int(event.keyCode)
            self.modifierFlags = Int(mods.rawValue)

            UserDefaults.standard.set(self.keyCode, forKey: action.keyCodeKey)
            UserDefaults.standard.set(self.modifierFlags, forKey: action.modifierFlagsKey)

            stopListening()
            NotificationCenter.default.post(name: .hotkeyDidChange, object: nil)

            return nil
        }
    }

    private func stopListening() {
        // Safe to call when not listening: localMonitor is nil, so this is a no-op.
        isRecording = false
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
            NotificationCenter.default.post(name: .hotkeyRecorderDidStop, object: nil)
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let hotkeyDidChange = Notification.Name("hotkeyDidChange")
    /// A shortcut recorder started or stopped listening; `HotkeyManager` stands aside
    /// in between.
    static let hotkeyRecorderDidStart = Notification.Name("hotkeyRecorderDidStart")
    static let hotkeyRecorderDidStop = Notification.Name("hotkeyRecorderDidStop")
}

// MARK: - Display Helpers

func shortcutDisplayString(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> String {
    var parts: [String] = []
    if modifierFlags.contains(.control) { parts.append("\u{2303}") }
    if modifierFlags.contains(.option) { parts.append("\u{2325}") }
    if modifierFlags.contains(.shift) { parts.append("\u{21E7}") }
    if modifierFlags.contains(.command) { parts.append("\u{2318}") }
    parts.append(keyCodeToString(keyCode))
    return parts.joined()
}

/// A key code as an `NSMenuItem.keyEquivalent`, so a menu draws a global shortcut in its
/// right-hand column as it draws ⌘Q. Read from the ASCII-capable layout, not the current
/// one: a menu equivalent is a character, and on a Ukrainian layout Q's would be "й".
/// Nil for a key with no character a menu can draw, which keeps its title as it was.
func menuKeyEquivalent(keyCode: UInt16) -> String? {
    switch keyCode {
    case 49: return " "
    case 36: return "\r"
    case 48: return "\t"
    case 51: return "\u{8}"
    case 53: return "\u{1b}"
    case 123: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    case 124: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
    case 125: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
    case 126: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
    default:
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0
        layoutData.withUnsafeBytes { ptr in
            let layoutPtr = ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            UCKeyTranslate(layoutPtr, keyCode, UInt16(kUCKeyActionDisplay), 0,
                           UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                           &deadKeyState, chars.count, &length, &chars)
        }
        guard length > 0 else { return nil }
        // Lowercase: an uppercase equivalent would add a ⇧ the shortcut may not have.
        let character = String(utf16CodeUnits: chars, count: length).lowercased()
        return character.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 }) ? character : nil
    }
}

func keyCodeToString(_ keyCode: UInt16) -> String {
    switch keyCode {
    case 49: return "Space"
    case 36: return "Return"
    case 48: return "Tab"
    case 51: return "Delete"
    case 53: return "Escape"
    case 123: return "\u{2190}"
    case 124: return "\u{2192}"
    case 125: return "\u{2193}"
    case 126: return "\u{2191}"
    case let code where ShortcutKeyPress.functionKeyNames[code] != nil:
        return ShortcutKeyPress.functionKeyNames[code]!
    default:
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source, let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key\(keyCode)"
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        layoutData.withUnsafeBytes { ptr in
            let layoutPtr = ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            UCKeyTranslate(
                layoutPtr,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }

        if length > 0 {
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
        return "Key\(keyCode)"
    }
}
