// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Carbon.HIToolbox

/// fn (🌐) pressed on its own, as a shortcut.
///
/// Carbon cannot register it — `RegisterEventHotKey` has no flag for fn — so the app
/// watches the key itself with a passive monitor, which needs only the Accessibility
/// permission the app already holds (measured 2026-11-16, macOS 26.6.2: the monitor saw
/// every press with SpeechText absent from Input Monitoring). Passive means it swallows
/// nothing: whatever macOS does with 🌐 still happens beside the shortcut.
public enum FnKey {
    /// `kVK_Function`: what the flags-changed event of fn itself carries.
    public static let keyCode = UInt16(kVK_Function)

    /// A shortcut stored as fn's key code with no modifiers is fn on its own.
    public static let shortcut = KeyShortcut(keyCode: UInt32(keyCode), carbonModifiers: 0)

    /// System Settings › Keyboard › "Press 🌐 key to", stored as `AppleFnUsageType` in
    /// `com.apple.HIToolbox`. The values were read after choosing each option in turn
    /// (2026-11-16, macOS 26.6.2). The double-press dictation shortcut (Keyboard ›
    /// Dictation) writes the same key, as 3, and turning it off removed the key.
    public enum SystemAction: Equatable, Sendable {
        case doNothing
        case changeInputSource
        case showEmojiAndSymbols
        case startDictation
        /// A value macOS did not write when this was measured.
        case other(Int)

        /// An absent key is what a Mac that never changed the setting has, and there
        /// 🌐 switched the input source.
        public init(appleFnUsageType: Int?) {
            switch appleFnUsageType {
            case 0: self = .doNothing
            case nil, 1: self = .changeInputSource
            case 2: self = .showEmojiAndSymbols
            case 3: self = .startDictation
            case let value?: self = .other(value)
            }
        }

        /// macOS acts on a press of 🌐 too, so a dictation on fn would come with it.
        public var takesThePress: Bool { self != .doNothing }
    }
}

/// Turns fn's own presses and releases into the press and release of the shortcut it is.
///
/// fn is also a modifier — fn+← is Home, fn+F5 is F5, fn+E opens the emoji viewer — and a
/// press of fn is the shortcut only when no other key goes down before it comes up. The
/// monitor reports only *that* another key went down, never which one.
///
/// Starting a dictation cannot wait for fn to come up: the microphone needs the head
/// start, as it does for every shortcut. So with nothing running the press goes through
/// at once, and another key arriving while fn is still down takes it back (`abort`).
/// While something runs, the press waits for the release instead — fn+← in the middle
/// of a dictation is someone moving the cursor, not a stop.
///
/// The keyboard reports no other key while Secure Input is on (a password field), so
/// there fn+← reads as fn alone; kept at the owner's call (2026-11-16) rather than
/// turning fn off in password fields.
///
/// Pure logic; the monitor feeds it and the hotkey code performs what it returns.
public struct FnKeyFilter: Sendable {
    public enum Event: Equatable, Sendable {
        case press
        case release
        /// Another key went down while fn was held: the press already sent was not a
        /// shortcut. `notify` is false within `DictationHotkeyGesture.tapThreshold` of
        /// the press, the usual fn+arrow, where a "canceled" notice on every Home or End
        /// would be noise (owner's call, 2026-11-16).
        case abort(notify: Bool)
    }

    private enum State: Sendable {
        case up
        /// Down, and its press already sent.
        case pressed(at: TimeInterval)
        /// Down, its press held back until the release.
        case deferred
        /// Down, and another key went down with it.
        case modifier
    }

    private var state = State.up

    public init() {}

    /// `idle`: nothing the shortcut would act on is running, so its press starts something.
    public mutating func fnDown(at time: TimeInterval, idle: Bool) -> [Event] {
        // A second press with no release between means the release was missed: start over.
        state = idle ? .pressed(at: time) : .deferred
        return idle ? [.press] : []
    }

    public mutating func otherKeyDown(at time: TimeInterval) -> [Event] {
        switch state {
        case .pressed(let pressedAt):
            state = .modifier
            return [.abort(notify: time - pressedAt >= DictationHotkeyGesture.tapThreshold)]
        case .deferred:
            state = .modifier
            return []
        case .up, .modifier:
            return []
        }
    }

    public mutating func fnUp() -> [Event] {
        defer { state = .up }
        switch state {
        case .pressed: return [.release]
        case .deferred: return [.press, .release]
        case .up, .modifier: return []
        }
    }
}
