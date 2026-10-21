// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Sparkle
import SpeechTextCore

/// **The only file that imports Sparkle** — the second and last third-party framework in
/// the app, and the same arrangement `LocalWhisperRuntime.swift` has with WhisperKit:
/// everything around it is Apple frameworks, so the standalone test bundle keeps
/// building and replacing the updater is one file rather than a rewrite.
///
/// SpeechText ships outside the App Store, so nothing updates it for us. Sparkle reads
/// an *appcast* — a small XML feed published as an asset of each GitHub release — finds
/// the newest version there, and (after the user agrees) downloads the disk image,
/// replaces the app and restarts it. Every update is signed with an EdDSA key that is
/// ours alone, separate from the Apple certificate: that is what makes the download
/// trustworthy even if the Developer ID team changes — a transfer to another account
/// would do it, though converting this one to an organization keeps its team ID.
///
/// Both halves of that setup live in `Info.plist` — `SUFeedURL` and `SUPublicEDKey` —
/// and `docs/releasing.md` says where the key comes from.
///
/// Not actor-isolated, like the rest of the app's AppKit glue: every caller — the status
/// menu's actions, the Settings form — is already on the main thread, which is where
/// Sparkle requires its updater to be used.
///
/// It is also the standard user driver's delegate, for one hook: see
/// `standardUserDriverWillShowModalAlert`. Sparkle holds that delegate weakly; `shared`
/// is what keeps it alive.
///
/// Main-actor, as Sparkle requires; its delegate methods are called on main, which the
/// `@preconcurrency` conformance checks as they come in.
@MainActor
final class UpdateChecker: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = UpdateChecker()

    /// Assigned after `super.init()`, because the controller is handed `self` as its
    /// delegate.
    private var controller: SPUStandardUpdaterController?

    /// Whether this build can check for updates at all. False in a source checkout that
    /// has no signing key yet: Sparkle's own answer to a missing key is a modal alert a
    /// second after launch, on every launch, which is worse than a menu item that isn't
    /// there. See `docs/releasing.md` for generating the key. Also false in a
    /// development build — see `isDevelopmentBuild`.
    var isConfigured: Bool { controller != nil }

    /// The feed the app follows, for the Debug Log and for the settings row's subtitle.
    var feedURL: String? { Self.infoValue("SUFeedURL") }

    /// Sparkle checks once a day on its own; the user can switch that off in Settings.
    /// Writing it goes into the app's own defaults domain, which is why a development
    /// build never touches it — see `isDevelopmentBuild`.
    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// When the last check happened, so Settings can say something more useful than a
    /// bare switch.
    var lastCheckDate: Date? { controller?.updater.lastUpdateCheckDate }

    /// A build that was not made by `scripts/rebuild.sh` or the release workflow: no
    /// commit stamped into `Info.plist`, and the build number Xcode leaves behind is 1.
    /// Such a build sees *every* release as newer than itself, and letting Sparkle
    /// replace a bundle sitting in DerivedData is not a thing anyone wants to debug — so
    /// no updater is started at all.
    ///
    /// Not merely "schedule off": every Sparkle setting is stored in the *host bundle's*
    /// defaults, and a ⌘R build and the installed copy share the bundle identifier. One
    /// Xcode run that wrote `SUEnableAutomaticChecks = false` would switch updates off
    /// for the app in `/Applications`, permanently and invisibly. Updates are exercised
    /// from a `rebuild.sh` install, which carries a commit and a real build number.
    static var isDevelopmentBuild: Bool { AppVersion.commit == nil || AppVersion.build == "1" }

    private override init() {
        super.init()
        guard Self.infoValue("SUFeedURL") != nil, Self.infoValue("SUPublicEDKey") != nil else {
            dlog("Update", "no SUFeedURL/SUPublicEDKey in Info.plist — updates are off in this build")
            return
        }
        guard !Self.isDevelopmentBuild else {
            dlog("Update", "development build — no updater started")
            return
        }
        // Sparkle's standard controller owns the updater, the update windows and the
        // background schedule; starting it here means the first check happens on its own.
        // A scheduled check that fails says nothing — Sparkle's default, kept on purpose:
        // `SPUScheduledUpdateDriver` aborts with `showErrorToUser: _showedUpdate`, so an
        // error reaches the user only once an update had already been put in front of them.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: self)
        dlog("Update", "updater started (feed \(feedURL ?? "?"), automatic \(checksAutomatically))")
    }

    /// The menu item. The app is an agent with no windows of its own, so nothing brings
    /// it forward when Sparkle opens one — without this the "an update is available"
    /// window can appear behind whatever the user was working in. Sparkle activates the
    /// app itself before its "Checking for updates…" window, but only while the app has
    /// no Dock icon (`SPUStandardUserDriver` asks `isBackgroundApplication`, which is
    /// `activationPolicy == .accessory`); with Settings open behind another app it has
    /// one, and only this call brings it forward.
    func checkForUpdates() {
        guard let controller else { return }
        Self.activateApp()
        controller.updater.checkForUpdates()
    }

    /// Sparkle's "Update Error!", "You're up to date!" and "Update Installed" alerts are
    /// all run *modally* (`SPUStandardUserDriver.showAlert:secondaryAction:` →
    /// `-[NSAlert runModal]`), and nothing on that path activates the app. The checking
    /// window the alert replaces was shown a network round trip earlier, and by now the
    /// app may well not be active: the alert then opens behind whatever the user is in,
    /// and the modal session it starts disables every item of the status menu, Quit
    /// included — the app looks hung, with the one window that would explain it out of
    /// sight.
    ///
    /// So the app is brought forward here, and — because an activation request is
    /// exactly what the system may decline — the alert is also ordered in front of every
    /// other app's windows, which does not depend on activation at all; a click on it
    /// then activates the app. `runModal` starts right after this returns, so the alert
    /// is not yet `NSApp.modalWindow`: the block runs on the modal run loop's first turn,
    /// which is in `.modalPanel` mode — hence a run-loop block that names that mode.
    func standardUserDriverWillShowModalAlert() {
        Self.activateApp()
        RunLoop.main.perform(inModes: [.modalPanel, .default]) {
            MainActor.assumeIsolated {
                let alert = NSApp.modalWindow
                alert?.orderFrontRegardless()
                dlog("Update", "modal alert \(alert == nil ? "not found" : "ordered front"), "
                     + "app \(NSApp.isActive ? "active" : "not active")")
            }
        }
    }

    /// The "A new version of SpeechText is available!" window, found by a check the user
    /// asked for. It is not modal, so nothing freezes, but Sparkle's only guarantee that
    /// it is seen is the activation it requests just before `showWindow` — the request
    /// the system may decline. Sparkle calls this synchronously right before both
    /// (`showUpdateFoundWithAppcastItem:state:reply:`), so the block runs once the window
    /// is at the front of the app's own windows and puts it in front of everyone else's.
    ///
    /// A *scheduled* check that finds an update passes through here too, and is left to
    /// Sparkle's own placement: for an agent that is behind other apps unless the app was
    /// just launched, which is a notice rather than an interruption.
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        guard state.userInitiated else { return }
        let version = update.displayVersionString
        RunLoop.main.perform(inModes: [.default, .modalPanel]) {
            MainActor.assumeIsolated {
                // `orderedWindows` leaves panels out, so the overlay cannot be taken for it.
                let window = NSApp.orderedWindows.first { $0.isVisible }
                window?.orderFrontRegardless()
                dlog("Update", "update \(version) window "
                     + "\(window == nil ? "not found" : "ordered front"), "
                     + "app \(NSApp.isActive ? "active" : "not active")")
            }
        }
    }

    /// The deprecated call, deliberately. Sparkle 2.10 makes the same choice in
    /// `SPUStandardUserDriver._activateApplication`: `NSApp.activate()`, its macOS 14
    /// replacement, "does not always work reliably from backgrounded apps when the user
    /// initiates checks for updates from e.g. a menu bar" (last tested there on macOS
    /// 26.5.1) — which is this app, every time.
    private static func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// An `Info.plist` string that is actually a value, with the same rule `AppVersion`
    /// uses: an unsubstituted `$(...)` placeholder is not one.
    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
