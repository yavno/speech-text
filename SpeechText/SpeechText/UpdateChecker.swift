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
/// It is also the standard user driver's delegate, for the two hooks that bring Sparkle's
/// alerts and its "available" window forward. Sparkle holds that delegate weakly; `shared`
/// is what keeps it alive. The stages after Install Update have no delegate hook at all,
/// which is what `ReportingUserDriver` below is for.
///
/// Main-actor, as Sparkle requires; its delegate methods are called on main, which the
/// `@preconcurrency` conformance checks as they come in.
@MainActor
final class UpdateChecker: NSObject, ObservableObject, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = UpdateChecker()

    /// Assigned after `super.init()`, because the user driver is handed `self` as its
    /// delegate.
    private var updater: SPUUpdater?
    private var userDriver: ReportingUserDriver?

    /// What Settings shows about an update the user agreed to.
    @Published private(set) var installStatus: UpdateInstallStatus = .idle

    /// Whether this build can check for updates at all. False in a source checkout that
    /// has no signing key yet: Sparkle's own answer to a missing key is a modal alert a
    /// second after launch, on every launch, which is worse than a menu item that isn't
    /// there. See `docs/releasing.md` for generating the key. Also false in a
    /// development build — see `isDevelopmentBuild`.
    var isConfigured: Bool { updater != nil }

    /// The feed the app follows, for the Debug Log and for the settings row's subtitle.
    var feedURL: String? { Self.infoValue("SUFeedURL") }

    /// Sparkle checks once a day on its own; the user can switch that off in Settings.
    /// Writing it goes into the app's own defaults domain, which is why a development
    /// build never touches it — see `isDevelopmentBuild`.
    var checksAutomatically: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    /// When the last check happened, so Settings can say something more useful than a
    /// bare switch.
    var lastCheckDate: Date? { updater?.lastUpdateCheckDate }

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
        // What `SPUStandardUpdaterController` builds, built here because it cannot be
        // given another user driver. Starting the updater here means the first check
        // happens on its own.
        // A scheduled check that fails says nothing — Sparkle's default, kept on purpose:
        // `SPUScheduledUpdateDriver` aborts with `showErrorToUser: _showedUpdate`, so an
        // error reaches the user only once an update had already been put in front of them.
        let driver = ReportingUserDriver(hostBundle: .main, delegate: self)
        driver.onStatusChange = { [weak self] status in self?.installStatus = status }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do {
            try updater.start()
        } catch {
            // The controller's answer is a modal alert a second after launch. As for a
            // missing key above: no menu item is better, and the log says why.
            dlog("Update", "updater failed to start (\((error as NSError).code)) — updates are off in this build")
            return
        }
        self.updater = updater
        userDriver = driver
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
        guard let updater else { return }
        Self.activateApp()
        updater.checkForUpdates()
    }

    /// Settings' Install and Relaunch: the same answer as the button in Sparkle's window.
    func installReadyUpdate() {
        userDriver?.installReadyUpdate()
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
    ///
    /// Ordered front once is not enough, though: a click into another app covered it
    /// again, and Hide (⌘H, or Hide Others from another app) took it off screen — the
    /// menu stayed dead with nothing visible to answer. So the alert floats above every
    /// ordinary window, stays when the app is hidden or deactivated, and follows the user
    /// across Spaces until its button is pressed: closing it is the only way out of the
    /// modal session, so it must never be out of sight.
    func standardUserDriverWillShowModalAlert() {
        Self.activateApp()
        RunLoop.main.perform(inModes: [.modalPanel, .default]) {
            MainActor.assumeIsolated {
                let alert = NSApp.modalWindow
                if let alert {
                    alert.level = .floating
                    alert.hidesOnDeactivate = false
                    alert.canHide = false
                    alert.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
                }
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

/// Sparkle's own windows, reporting as they go. Bytes received and the "ready to install"
/// reply reach only the user driver: no delegate of either kind is told them.
///
/// A subclass rather than a wrapper around the standard driver: `SPUUpdater` also probes
/// its driver for private selectors (the gentle-reminder timing, 2.10), which a wrapper
/// would silently lose. Every override calls `super`, so the windows behave as before.
@MainActor
private final class ReportingUserDriver: SPUStandardUserDriver {
    var onStatusChange: ((UpdateInstallStatus) -> Void)?

    private var progress = UpdateInstallProgress() {
        didSet {
            guard progress.status != oldValue.status else { return }
            onStatusChange?(progress.status)
        }
    }
    /// Sparkle's reply to "ready to install", until one of the two buttons has used it.
    private var installReply: ((SPUUserUpdateChoice) -> Void)?
    /// Sparkle keeps one status window through all three stages and reports none of them.
    private weak var statusWindow: NSWindow?

    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        bringingStatusWindowForward { super.showDownloadInitiated(cancellation: cancellation) }
        progress.downloadStarted()
    }

    override func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        super.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
        progress.expectedLengthReceived(expectedContentLength)
    }

    override func showDownloadDidReceiveData(ofLength length: UInt64) {
        super.showDownloadDidReceiveData(ofLength: length)
        progress.dataReceived(length)
    }

    override func showDownloadDidStartExtractingUpdate() {
        bringingStatusWindowForward { super.showDownloadDidStartExtractingUpdate() }
        progress.extractionStarted()
    }

    override func showExtractionReceivedProgress(_ progress: Double) {
        super.showExtractionReceivedProgress(progress)
        self.progress.extractionProgressed(progress)
    }

    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installReply = reply
        // Sparkle's button goes through the same one-shot as Settings', so a click on each
        // answers Sparkle once.
        bringingStatusWindowForward {
            super.showReady { [weak self] _ in self?.installReadyUpdate() }
        }
        progress.readyToInstall()
    }

    override func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                       retryTerminatingApplication: @escaping () -> Void) {
        super.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
                                   retryTerminatingApplication: retryTerminatingApplication)
        progress.installationStarted()
    }

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        progress.reset()
        super.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    override func dismissUpdateInstallation() {
        installReply = nil
        statusWindow = nil
        progress.reset()
        super.dismissUpdateInstallation()
    }

    func installReadyUpdate() {
        guard let reply = installReply else { return }
        installReply = nil
        reply(.install)
    }

    /// The stages after Install Update, which Sparkle opens with a plain `orderFront` when
    /// the app is not active, so behind whatever the user went back to; and the later two
    /// reuse the window and do not order it at all.
    ///
    /// Ordered in front of everyone else's windows without activating the app, on purpose:
    /// these stages arrive on their own while the user may be typing or dictating into
    /// another app, and taking focus from it would move the paste. A click on the window
    /// activates the app as usual. The window is told from the others by being the one the
    /// call created, and left alone if the user minimized it.
    private func bringingStatusWindowForward(_ show: () -> Void) {
        let known = Set(NSApp.windows.map(ObjectIdentifier.init))
        show()
        if let created = NSApp.windows.first(where: { !known.contains(ObjectIdentifier($0)) }) {
            statusWindow = created
        }
        guard let statusWindow, !statusWindow.isMiniaturized else {
            dlog("Update", "status window \(statusWindow == nil ? "not found" : "minimized")")
            return
        }
        statusWindow.orderFrontRegardless()
        dlog("Update", "status window ordered front, app \(NSApp.isActive ? "active" : "not active")")
    }
}
