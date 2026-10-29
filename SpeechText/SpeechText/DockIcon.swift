// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SpeechTextCore

/// When the app shows an icon in the Dock (and so in ⌘Tab).
///
/// The app is an `LSUIElement` agent, and an agent's windows have nowhere to be found
/// once another app covers them: no Dock icon, no ⌘Tab entry, no Window menu. The
/// default therefore keeps the app in the Dock all the time, as an ordinary app is;
/// `whileWindowOpen` gives it an icon only while one of its ordinary windows (the main
/// window, Settings, Debug Log) is open.
enum DockIconMode: String, CaseIterable, Identifiable {
    case never
    case whileWindowOpen
    case always

    static let `default` = DockIconMode.always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: return "Never"
        case .whileWindowOpen: return "While a window is open"
        case .always: return "Always"
        }
    }

    static var current: DockIconMode {
        UserDefaults.standard.string(forKey: SettingsKeys.dockIconMode).flatMap(DockIconMode.init) ?? .default
    }
}

extension Notification.Name {
    static let dockIconModeDidChange = Notification.Name("dockIconModeDidChange")
}

/// Switches the activation policy between `.accessory` and `.regular` as windows open
/// and close, or as the setting changes.
///
/// It watches every window rather than being told by each `open…` function, so a
/// window added later cannot forget to report itself.
@MainActor
final class DockIconController {
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // `didResignKey` is for a modal alert: `runModal` ends with an order-out, not a
        // close, and the alert resigning key is the one notification that follows it.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        // At `willClose` the window still reports itself visible, so decide once it is gone.
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let closing = note.object as? NSWindow
            DispatchQueue.main.async { [weak self] in self?.update(excluding: closing) }
        })
        observers.append(center.addObserver(forName: .dockIconModeDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
        update()
    }

    deinit {
        // Let go with the app delegate, on main.
        MainActor.assumeIsolated { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    /// The main window, Settings and the other titled windows — not the recording overlay, the
    /// status notice or the Record Window, which are panels floating over another app's
    /// work and must not pull a Dock icon in with them. Setup and Settings draw their own
    /// frame, so they are borderless, but they are ordinary windows the user leaves for a
    /// browser or System Settings and comes back to.
    ///
    /// A modal alert counts too, though it is a panel (`NSAlert`'s window is an
    /// `NSPanel`): while it runs every item of the status menu is disabled, so it is the
    /// one window the user *must* be able to find. Sparkle's update alerts are the case
    /// in point — the "Checking for updates…" window closes right before its error alert
    /// runs, and without this the icon was taken away under the alert.
    static func hasOpenWindow(excluding excluded: NSWindow? = nil) -> Bool {
        if let modal = NSApp.modalWindow, modal !== excluded { return true }
        return NSApp.windows.contains { window in
            window !== excluded
                && !(window is NSPanel)
                && (window.styleMask.contains(.titled) || window is OnboardingWindow || window is SettingsWindow)
                && (window.isVisible || window.isMiniaturized)
        }
    }

    private func update(excluding excluded: NSWindow? = nil) {
        let wantsDock: Bool
        switch DockIconMode.current {
        case .never: wantsDock = false
        case .always: wantsDock = true
        case .whileWindowOpen: wantsDock = Self.hasOpenWindow(excluding: excluded)
        }
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        dlog("App", "Dock icon \(wantsDock ? "shown" : "hidden") (\(DockIconMode.current.rawValue))")
    }
}
