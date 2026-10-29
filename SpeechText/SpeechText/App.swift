// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import ServiceManagement
import SpeechTextCore

@main
struct SpeechTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// The Settings window is `SettingsWindow`, drawn in the setup window's frame, which
    /// a `Settings` scene cannot wear. The scene stays, empty, because an app needs one;
    /// its menu item — Settings… (⌘,), in the app menu whenever the Dock icon is shown —
    /// is replaced by one that opens our window, so the scene itself never opens.
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SpeechText") { appDelegate.showAbout() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

// MARK: - Build identity

/// What this build is, in one line: the release version, and — when the rebuild
/// skill produced it — which commit it came from and when.
///
/// `CFBundleShortVersionString` is the semver in CHANGELOG.md and moves only on a
/// release. The rest is stamped at build time: `scripts/rebuild.sh` passes
/// `CURRENT_PROJECT_VERSION`, `SPT_GIT_COMMIT` and `SPT_BUILD_DATE` on the
/// `xcodebuild` line, and `Info.plist` carries `$(...)` placeholders for them.
/// A plain Xcode ⌘R build defines none of those, so the app says "dev" instead —
/// which is the honest answer, not a missing feature.
enum AppVersion {
    static var marketing: String { string(for: "CFBundleShortVersionString") ?? "?" }
    static var build: String { string(for: "CFBundleVersion") ?? "?" }
    static var commit: String? { string(for: "SPTGitCommit") }
    static var builtAt: String? { string(for: "SPTBuildDate") }

    /// e.g. `0.9.0 (build 47 · a18a7d1 · 2026-09-16 14:20)`, or `0.9.0 (dev)`.
    static var displayString: String {
        guard let commit else { return "\(marketing) (dev)" }
        var parts = ["build \(build)", commit]
        if let builtAt { parts.append(builtAt) }
        return "\(marketing) (\(parts.joined(separator: " · ")))"
    }

    /// An Info.plist string that is actually a value. Xcode substitutes an *empty*
    /// string for a build setting it was never given, so the unstamped case is ""
    /// rather than a missing key; a placeholder left verbatim would mean the key in
    /// Info.plist and the variable on the build line disagree, and showing the user
    /// `$(SPT_GIT_COMMIT)` is worse than showing nothing.
    private static func string(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}

/// The project's pages, named once for About SpeechText and Settings › General.
enum ProjectLinks {
    static let website = URL(string: "https://speech-text.app")!
    static let repository = URL(string: "https://github.com/yavno/speech-text")!
    static let issues = URL(string: "https://github.com/yavno/speech-text/issues")!
}

/// The About panel's credits: the update status, then the links. Centred, small, in
/// the label colours so Dark Mode reads.
@MainActor
enum AboutCredits {
    static func make() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(string: updateStatus + "\n", attributes: base)
        let links: [(String, URL?)] = [
            ("speech-text.app", ProjectLinks.website),
            ("Report a problem", ProjectLinks.issues),
            ("Acknowledgements", Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")),
        ]
        for (index, (title, url)) in links.enumerated() where url != nil {
            if index > 0 { text.append(NSAttributedString(string: "  ·  ", attributes: base)) }
            var attributes = base
            attributes[.link] = url
            text.append(NSAttributedString(string: title, attributes: attributes))
        }
        return text
    }

    /// Whether this copy updates itself, and when it last looked.
    static var updateStatus: String {
        let updater = UpdateChecker.shared
        guard updater.isConfigured else {
            return UpdateChecker.isDevelopmentBuild
                ? "Development build — it does not update itself."
                : "This build does not update itself."
        }
        let schedule = updater.checksAutomatically
            ? "Checks for updates once a day."
            : "Automatic update checks are off."
        guard let last = updater.lastCheckDate else { return schedule + " Not checked yet." }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return schedule + " Last checked " + formatter.string(from: last) + "."
    }
}

/// Lets `CustomVocabulary.ranked` count how often each term appears in History, so
/// the terms a model is sent when it cannot take them all are the ones actually used.
/// The counts are kept between dictations (`HistoryTermCounts`), since every start asks.
/// History is written on the main thread; read from anywhere else it gives nothing, the
/// kept counts are left alone, and the terms keep their date order.
func registerVocabularyHistory() {
    // Touched only on main, behind the guard below, which is what makes the unchecked
    // capture safe.
    nonisolated(unsafe) let counts = HistoryTermCounts()
    CustomVocabulary.historyUses = { needles in
        guard Thread.isMainThread else { return [:] }
        return MainActor.assumeIsolated {
            counts.uses(of: needles, in: TranscriptionHistory.shared.records.lazy.map { (id: $0.id, text: $0.text) })
        }
    }
}

// MARK: - AppDelegate with NSStatusItem

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let appState = AppState()
    private var settingsWindow: SettingsWindow?
    /// A Settings window built ahead, while the main window is open, so its Settings opens
    /// at once: building and laying one out costs about a third of a second.
    private var preparedSettingsWindow: SettingsWindow?
    private var mainWindow: MainWindow?
    private var debugLogWindow: DebugLogWindow?
    private var dockIcon: DockIconController?
    private var setupWindow: OnboardingWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if MainActor.assumeIsolated({ LocalChatSmoke.runIfAsked() }) { return }
        #endif
        // Opened straight from the disk image: move to Applications and start again from
        // there, before this copy writes a setting, registers a login item or opens setup.
        if MainActor.assumeIsolated({ AppInstaller.moveIfRunningFromDiskImage() }) { return }

        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon(recording: false)

        // Carry the pre-rename settings over, then drop provider values left over from
        // removed engines — both before any UI reads them. The setup gate is decided in
        // between: settings a renamed install brings with it are evidence of an earlier
        // launch, but the migrations below write settings on a new install too
        // (`spokenLanguages`, always), and read after them every new install looked like
        // an old one — setup never opened, and the two permission alerts did instead.
        adoptPreRenameDefaults()
        openAPIKeyStore()
        let setupGate = decideSetupGate()
        migrateSelectedLanguageIfNeeded()
        CustomVocabulary.migrateLegacyStoreIfNeeded()
        normalizeStoredProviders()

        // Build the menu
        rebuildMenu()

        // Dictations saved to History with no network are transcribed once it is back.
        MainActor.assumeIsolated {
            OfflineRetry.shared.onDrained = { [weak appState] transcribed, failed in
                appState?.showNotPastedOnceOnline(transcribed: transcribed, failed: failed)
            }
            OfflineRetry.shared.start()
        }

        if setupGate == .show {
            // Setup asks for the microphone and Accessibility itself, on a screen that
            // says what they are for — not in two unexplained alerts at launch.
            DispatchQueue.main.async { [weak self] in self?.openSetup() }
        } else {
            // Request microphone access on launch — but not for an end-to-end run, which
            // records from a file and whose prompt would take the focus from the document
            // the script dictates into.
            if E2EMode.audioInputs == nil {
                appState.speechEngine.requestMicrophoneAccess { granted in
                    if !granted {
                        dlog("App", "Microphone access denied", level: .error)
                    }
                }
            }

            // No alert at launch for a missing Accessibility grant: Home says so, and a
            // dictation that could not be pasted offers the way to turn it on. Listed
            // quietly, so the switch is there to find.
            if !PasteService.isAccessibilityGranted {
                SystemSettingsGuide.registerQuietly()
            }
        }

        registerLocalSTT()
        registerLocalChat()
        prewarmSelectedLocalModel()
        registerSpellCheckedJoins()
        registerVocabularyHistory()
        registerVoiceActivity()
        dockIcon = DockIconController()
        migrateHotkeyLayoutIfNeeded()

        // Starts Sparkle's background schedule. Nothing happens in a build with no
        // signing key, or in a development build — see UpdateChecker.
        _ = UpdateChecker.shared

        // Set up hotkeys
        appState.hotkeyManager.onDictationKey = { [weak self] key, isDown in
            DispatchQueue.main.async {
                if isDown {
                    self?.appState.hotkeyPressed(key)
                } else {
                    self?.appState.hotkeyReleased(key)
                }
                self?.updateIcon()
                self?.rebuildMenu()
            }
        }
        appState.hotkeyManager.onEscape = { [weak self] in
            self?.appState.escapePressed()
            self?.updateIcon()
            self?.rebuildMenu()
        }
        appState.hotkeyManager.onEditKey = { [weak self] isDown in
            DispatchQueue.main.async {
                if isDown {
                    self?.appState.editHotkeyPressed()
                } else {
                    self?.appState.editHotkeyReleased()
                }
                self?.updateIcon()
            }
        }
        appState.hotkeyManager.onRecordWindowToggle = { [weak self] in
            DispatchQueue.main.async {
                self?.appState.toggleOrShowDirectRecordingPanel()
            }
        }
        appState.hotkeyManager.start()

        // Rebuild menu when shortcuts change so display strings update
        NotificationCenter.default.addObserver(
            forName: .hotkeyDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildMenu() }
        }

        // The status overlay asks for History via notification (AppState doesn't own windows)
        NotificationCenter.default.addObserver(
            forName: .openHistoryWindow, object: nil, queue: .main
        ) { [weak self] note in
            // A notice may name the place to narrow to — "Not pasted" for what waited offline.
            let place = note.object as? String
            MainActor.assumeIsolated {
                self?.showMainWindow(on: .history, historyNarrowing: place.map { HistoryNarrowing(app: $0) })
            }
        }
        // Settings' Edit Prompts… asks for the main window's Prompts page the same way.
        NotificationCenter.default.addObserver(
            forName: .openMainWindowPage, object: nil, queue: .main
        ) { [weak self] note in
            let page = (note.object as? String).flatMap(MainPage.init(rawValue:))
            MainActor.assumeIsolated { self?.showMainWindow(on: page) }
        }
        // A notice's way to a Settings page — the microphone notice's Change.
        NotificationCenter.default.addObserver(
            forName: .openSettingsPage, object: nil, queue: .main
        ) { [weak self] note in
            let category = note.object as? SettingsCategory
            MainActor.assumeIsolated { self?.showSettings(category: category) }
        }

        // Auto-register as login item on first launch (default: ON) — unless setup is
        // open, whose Permissions step turns it on where the switch for it is, rather
        // than with a "Login Item Added" notification before anything was explained.
        if setupGate != .show, !UserDefaults.standard.bool(forKey: SettingsKeys.hasRegisteredLaunchAtLogin) {
            UserDefaults.standard.set(true, forKey: SettingsKeys.hasRegisteredLaunchAtLogin)
            try? SMAppService.mainApp.register()
        }
    }

    /// Whether the setup window opens at launch — see `OnboardingGate`. Read before the
    /// login item is registered below, which is one of the signs of an earlier launch.
    private func decideSetupGate() -> OnboardingGate {
        let defaults = UserDefaults.standard
        let usedBefore = defaults.bool(forKey: SettingsKeys.hasRegisteredLaunchAtLogin)
            || SettingsKeys.portable.contains { defaults.object(forKey: $0) != nil }
            || APIKeyStore.shared.hasAnyKey
        let gate = OnboardingGate.decide(
            completed: defaults.object(forKey: SettingsKeys.onboardingCompleted) as? Bool,
            hasUsedTheAppBefore: usedBefore)
        switch gate {
        case .markCompleted:
            defaults.set(true, forKey: SettingsKeys.onboardingCompleted)
            dlog("Setup", "an existing install — setup marked as done")
        case .show:
            // Written down at once: setup's own steps store settings (and the login item)
            // that would otherwise make the next launch take an unfinished setup for an
            // old install and mark it done.
            defaults.set(false, forKey: SettingsKeys.onboardingCompleted)
        case .skip:
            break
        }
        return gate
    }

    @objc private func openSetup() {
        MainActor.assumeIsolated {
            if setupWindow == nil {
                setupWindow = OnboardingWindow(appState: appState, onClose: { [weak self] in
                    self?.setupWindow = nil
                    self?.rebuildMenu()
                }, onFinish: { [weak self] in
                    self?.showMainWindow()
                })
            }
            setupWindow?.present()
        }
    }

    /// Home's Skip: setup counts as done — everything it asks is in Settings — and its
    /// window and menu item go.
    private func skipSetup() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: SettingsKeys.onboardingCompleted)
        defaults.removeObject(forKey: SettingsKeys.onboardingStep)
        setupWindow?.close()
        setupWindow = nil
        rebuildMenu()
        dlog("Setup", "skipped from Home")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A copy on the disk image that moved itself never opened History.
        guard !AppInstaller.isLeaving else { return }
        // History writes are coalesced; a record made in the last quarter second is
        // still pending here. What *Don't keep* kept for this session goes first.
        TranscriptionHistory.shared.applyRetentionAtQuit()
        TranscriptionHistory.shared.flush()
    }

    /// A click on the Dock icon with nothing on screen opens the main window — otherwise
    /// the icon the user asked for would do nothing at all when clicked.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !DockIconController.hasOpenWindow() {
            openMainWindow()
        }
        return true
    }

    /// Moves existing installs onto the current shortcut layout (Inline ⌃⇧Q,
    /// Record Window ⌃⇧W, AI ⌃⇧A). Clearing the stored values lets the new built-in
    /// defaults take effect; this runs once, so later customisations are kept.
    private func migrateHotkeyLayoutIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: SettingsKeys.hotkeyLayoutVersion) < 1 else { return }

        for key in [
            SettingsKeys.hotkeyKeyCode, SettingsKeys.hotkeyModifierFlags,
            SettingsKeys.recordWindowHotkeyKeyCode, SettingsKeys.recordWindowHotkeyModifierFlags,
            SettingsKeys.aiHotkeyKeyCode, SettingsKeys.aiHotkeyModifierFlags,
        ] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(1, forKey: SettingsKeys.hotkeyLayoutVersion)
        dlog("App", "migrated shortcuts to the ⌃⇧Q / ⌃⇧W / ⌃⇧A layout")
    }

    /// The wordmark is wider than it is tall, so it gets a fixed height and its own
    /// aspect ratio rather than being squeezed into a square.
    private static func menuBarIcon(recording: Bool) -> NSImage? {
        guard let icon = NSImage(named: "MenuBarIcon") else { return nil }
        let height: CGFloat = 18
        icon.size = NSSize(width: (height * icon.size.width / icon.size.height).rounded(), height: height)
        // A template image is tinted by the system; recording needs its own colour.
        icon.isTemplate = !recording
        return icon
    }

    private func updateIcon() {
        statusItem.button?.image = Self.menuBarIcon(recording: appState.speechEngine.isRecording)
        statusItem.button?.appearsDisabled = false
        if appState.speechEngine.isRecording {
            statusItem.button?.contentTintColor = .red
        } else {
            statusItem.button?.contentTintColor = nil
        }
    }

    private static let recordingItemTag = 1
    private static let aiItemTag = 2

    /// The two recording items say what a click does now. Retitled each time the menu
    /// opens, too: the phase moves on by itself (a rewrite finishing), and a menu built
    /// while it was busy would otherwise offer to cancel a dictation that is over.
    private func updateRecordingItemTitles(in menu: NSMenu) {
        let shortcut = StoredShortcut.dictation
        let aiShortcut = StoredShortcut.ai
        let (title, aiTitle): (String, String)
        switch appState.dictationPhase {
        case .idle:
            (title, aiTitle) = ("Start Recording", "AI Recording")
        case .busy:
            // Transcribing or rewriting: either item cancels.
            (title, aiTitle) = ("Cancel Dictation", "Cancel Dictation")
        case .starting(let ai), .recording(let ai):
            // During a dictation, the other mode's item switches it over rather than stopping it.
            let own = appState.speechEngine.isRecording ? "Stop" : "Cancel"
            (title, aiTitle) = ai
                ? ("Switch to Plain Text", "\(own) AI Recording")
                : ("\(own) Recording", "Switch to AI")
        }
        menu.item(withTag: Self.recordingItemTag).map { shortcut.apply(to: $0, title: title) }
        menu.item(withTag: Self.aiItemTag).map { aiShortcut.apply(to: $0, title: aiTitle) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateRecordingItemTitles(in: menu)
    }

    /// Whether the status menu is open, so the pause and resume below stay paired even
    /// when `rebuildMenu` swaps the menu out from under itself.
    private var isMenuOpen = false

    /// While the menu is open the global shortcuts are off and its items' key
    /// equivalents take the keys: a Carbon hotkey's event waits until the menu closes,
    /// so a press made with the menu open used to start the dictation only after it
    /// closed, and a second press stopped it the same instant.
    func menuWillOpen(_ menu: NSMenu) {
        guard !isMenuOpen else { return }
        isMenuOpen = true
        appState.hotkeyManager.pause()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard isMenuOpen else { return }
        isMenuOpen = false
        appState.hotkeyManager.resume()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let mainItem = NSMenuItem(title: "Open SpeechText", action: #selector(openMainWindow), keyEquivalent: "")
        mainItem.target = self
        menu.addItem(mainItem)

        menu.addItem(.separator())

        let recordingItem = NSMenuItem(title: "", action: #selector(toggleRecording), keyEquivalent: "")
        recordingItem.target = self
        recordingItem.tag = Self.recordingItemTag
        menu.addItem(recordingItem)

        let aiItem = NSMenuItem(title: "", action: #selector(toggleAIRecording), keyEquivalent: "")
        aiItem.target = self
        aiItem.tag = Self.aiItemTag
        menu.addItem(aiItem)
        updateRecordingItemTitles(in: menu)

        let editItem = NSMenuItem(title: "", action: #selector(toggleEdit), keyEquivalent: "")
        StoredShortcut.edit.apply(to: editItem, title: "Edit Selection with AI")
        editItem.target = self
        editItem.toolTip = "Rewrites the text selected in the app in front. Speak an instruction, or double-press the shortcut to just polish it."
        menu.addItem(editItem)

        menu.addItem(.separator())

        let recordItem = NSMenuItem(title: "", action: #selector(openRecordPanel), keyEquivalent: "")
        StoredShortcut.recordWindow.apply(to: recordItem, title: "Record Window")
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let historyItem = NSMenuItem(title: "History...", action: #selector(openHistory), keyEquivalent: "y")
        historyItem.target = self
        menu.addItem(historyItem)

        // Setup is a first-run flow: once finished, everything it asks lives in Settings,
        // so the menu offers it only to pick up an unfinished one where it was left.
        if !UserDefaults.standard.bool(forKey: SettingsKeys.onboardingCompleted) {
            let setupItem = NSMenuItem(title: "Continue Setup...", action: #selector(openSetup), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)
        }

        let debugItem = NSMenuItem(title: "Debug Log...", action: #selector(openDebugLog), keyEquivalent: "")
        debugItem.target = self
        menu.addItem(debugItem)

        // Only where an update could actually be found: a build with no signing key has
        // no feed to check, and an item that always answers "no updates" is a lie.
        if UpdateChecker.shared.isConfigured {
            let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SpeechText", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func checkForUpdates() {
        UpdateChecker.shared.checkForUpdates()
    }

    @objc private func toggleRecording() {
        appState.toggleRecording()
        updateIcon()
        rebuildMenu()
    }

    @objc private func toggleAIRecording() {
        appState.toggleRecording(aiMode: true)
        updateIcon()
        rebuildMenu()
    }

    @objc private func toggleEdit() {
        appState.toggleEdit()
        updateIcon()
    }

    @objc private func openRecordPanel() {
        appState.showDirectRecordingPanel()
    }

    @objc private func openSettings() {
        showSettings()
    }

    /// Reached from the status menu, the app menu's Settings… and the main window, all on
    /// main. A closed window is let go, so the next one opens on General — or the page the
    /// main window asked for — with every status read afresh.
    func showSettings(category: SettingsCategory? = nil) {
        MainActor.assumeIsolated { presentSettings(category: category) }
    }

    /// The app menu's About SpeechText: the standard panel, given what it cannot find on
    /// its own — the whole build line the status menu shows (commit and date included,
    /// for a bug report), whether this copy updates itself, and where to go next. The
    /// copyright is `NSHumanReadableCopyright` in Info.plist. Built on every opening, so
    /// the last update check is never stale.
    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: AppVersion.displayString,
            // Empty hides the panel's own "(CFBundleVersion)", which the line above has.
            .version: "",
            .credits: AboutCredits.make(),
        ])
    }

    /// Settings on the page that holds `anchor`, scrolled to it.
    func showSettings(at anchor: SettingsAnchor) {
        MainActor.assumeIsolated {
            SettingsAnchor.pending = anchor
            presentSettings(category: anchor.category)
            NotificationCenter.default.post(name: .settingsScrollToAnchor, object: nil)
        }
    }

    @MainActor
    private func presentSettings(category: SettingsCategory?) {
        if let settingsWindow {
            if let category {
                NotificationCenter.default.post(name: .settingsShowCategory, object: category)
            }
            settingsWindow.present()
            return
        }
        if let window = preparedSettingsWindow {
            preparedSettingsWindow = nil
            settingsWindow = window
            window.present()
            if let category, category != .general {
                NotificationCenter.default.post(name: .settingsShowCategory, object: category)
            }
            return
        }
        let window = SettingsWindow(category: category ?? .general) { [weak self] in
            self?.settingsWindow = nil
            self?.prepareSettingsWindowSoon()
        }
        settingsWindow = window
        window.present()
    }

    /// Builds the next Settings window a moment after the main window has drawn — and again
    /// after Settings closes while the main window is still open — so it is read afresh
    /// for each opening, as before, only earlier.
    private func prepareSettingsWindowSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.mainWindow?.isVisible == true,
                      self.settingsWindow == nil, self.preparedSettingsWindow == nil else { return }
                let window = SettingsWindow(category: .general) { [weak self] in
                    self?.settingsWindow = nil
                    self?.prepareSettingsWindowSoon()
                }
                window.contentView?.layoutSubtreeIfNeeded()
                self.preparedSettingsWindow = window
            }
        }
    }

    /// The main window: from the status menu and a click on the Dock icon. Let go when
    /// closed, like Settings, so it opens again on Home.
    @objc private func openMainWindow() {
        showMainWindow()
    }

    /// History is a page of the main window: the status menu's History…, and a notice's
    /// way to a dictation it saved, open the window on it.
    @objc private func openHistory() {
        showMainWindow(on: .history)
    }

    private func showMainWindow(on page: MainPage? = nil, historyNarrowing: HistoryNarrowing? = nil) {
        MainActor.assumeIsolated {
            if mainWindow == nil {
                let actions = MainWindowActions(
                    openSettings: { [weak self] category in self?.showSettings(category: category) },
                    openSettingsAt: { [weak self] anchor in self?.showSettings(at: anchor) },
                    openSetup: { [weak self] in self?.openSetup() },
                    skipSetup: { [weak self] in self?.skipSetup() })
                mainWindow = MainWindow(actions: actions) { [weak self] in
                    self?.mainWindow = nil
                    self?.preparedSettingsWindow = nil
                }
            }
            if let historyNarrowing { mainWindow?.navigation.historyNarrowing = historyNarrowing }
            mainWindow?.present(page)
            prepareSettingsWindowSoon()
        }
    }

    @objc private func openDebugLog() {
        if let existing = debugLogWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = DebugLogWindow()
        window.makeKeyAndOrderFront(nil)
        debugLogWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One of the four global shortcuts as stored, for the status menu.
private struct StoredShortcut {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    static var dictation: StoredShortcut { read(SettingsKeys.hotkeyKeyCode, SettingsKeys.hotkeyModifierFlags, 12) }  // Q
    static var ai: StoredShortcut { read(SettingsKeys.aiHotkeyKeyCode, SettingsKeys.aiHotkeyModifierFlags, 0) }  // A
    static var edit: StoredShortcut { read(SettingsKeys.editHotkeyKeyCode, SettingsKeys.editHotkeyModifierFlags, 14) }  // E
    static var recordWindow: StoredShortcut {
        read(SettingsKeys.recordWindowHotkeyKeyCode, SettingsKeys.recordWindowHotkeyModifierFlags, 13)  // W
    }

    /// The stored shortcut, or the built-in one (⌃⇧ + `defaultKeyCode`, matching
    /// `HotkeyManager`'s defaults) when none has been saved.
    private static func read(_ keyCodeKey: String, _ modifiersKey: String, _ defaultKeyCode: UInt16) -> StoredShortcut {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeKey) != nil else {
            return StoredShortcut(keyCode: defaultKeyCode, modifiers: [.control, .shift])
        }
        return StoredShortcut(keyCode: UInt16(defaults.integer(forKey: keyCodeKey)),
                              modifiers: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: modifiersKey))))
    }

    /// Draws the shortcut in the menu's right-hand column, where ⌘, and ⌘Q are. A status
    /// menu matches its equivalents only while it is open, and that is when they act:
    /// the Carbon hotkeys are paused for as long as the menu is open (`menuWillOpen`),
    /// since their events would wait for it to close. A key a menu cannot draw stays in
    /// the title, as before — and with the menu open, that shortcut does nothing.
    func apply(to item: NSMenuItem, title: String) {
        if let key = menuKeyEquivalent(keyCode: keyCode) {
            item.title = title
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = modifiers.intersection([.control, .option, .shift, .command])
        } else {
            item.title = "\(title) (\(shortcutDisplayString(keyCode: keyCode, modifierFlags: modifiers)))"
            item.keyEquivalent = ""
        }
    }
}

extension Notification.Name {
    /// Posted when something (menu item, status overlay tap) wants History — a page of the
    /// main window. AppDelegate owns the window, so AppState signals rather than opening it directly.
    static let openHistoryWindow = Notification.Name("openHistoryWindow")
    /// A page of the main window, by `MainPage` raw value as the object.
    static let openMainWindowPage = Notification.Name("openMainWindowPage")
    /// The Settings window, on the `SettingsCategory` given as the object.
    static let openSettingsPage = Notification.Name("openSettingsPage")
}

// MARK: - AppState

@MainActor @Observable
final class AppState {
    let speechEngine = SpeechEngine()
    let hotkeyManager = HotkeyManager()

    init() {
        speechEngine.onMicrophoneSubstituted = { [weak self] resolution in
            self?.showMicrophoneNoticeOnce(resolution)
        }
    }

    private var overlayPanel: RecordingOverlayPanel?
    /// The overlay of a dictation or an edit that has ended, kept up to say where its text
    /// went — see `beginOverlayConfirmation`. Apart from `overlayPanel`, so ⎋ is let go and
    /// the next dictation opens a panel of its own.
    private var confirmationPanel: RecordingOverlayPanel?
    private var confirmation: OverlayConfirmation?
    private var confirmationDismissal: DispatchWorkItem?
    private var statusPanel: StatusOverlayPanel?
    private var statusDismissItem: DispatchWorkItem?
    private var directRecordingPanel: DirectRecordingPanelWindow?
    private var directRecordingSpeechEngine: SpeechEngine?
    /// The open Record Window's text view, for a dictation handed to it while it is open.
    private var directRecordingInsertion: TextInsertionHandler?
    /// The block observer on the Record Window's `willClose`. Kept so it can be removed:
    /// `removeObserver(self, …)` does nothing for a block observer, and a leaked one from
    /// a previous panel cleared the *new* panel's references when the old one closed.
    private var directRecordingCloseObserver: NSObjectProtocol?
    /// The app the user was last in when a recording started — the Edit shortcut's and
    /// the Record Window's target, which they paste into. Kept when a recording starts in
    /// SpeechText's own window, so the Record Window's Insert keeps its app.
    var previousApp: NSRunningApplication?
    /// Where the current inline dictation started (`InlineDelivery.origin`): pasted into
    /// only when the stop found SpeechText's own window in front. Nil when the dictation
    /// started there too — it then goes to the Record Window, not to `previousApp`, the
    /// app of some earlier recording.
    private var dictationOrigin: NSRunningApplication?
    /// Where the current inline dictation goes: the app in front when the user stopped,
    /// fixed at the stop (`InlineDelivery.destination`). Every step after the stop is
    /// handed this app, not `dictationOrigin` — the paste, the AI prompt's `<context>`,
    /// History and the trace. Nil until the stop.
    private var pasteDestination: NSRunningApplication?

    /// Setup's Try it step. While it is on screen a dictation's result goes to it
    /// instead of being pasted — the app never pastes into its own windows.
    let dictationTest = DictationTest()
    /// The current inline dictation was started from the Try it step. Captured at the
    /// start, so leaving the step mid-dictation cannot send the test's text anywhere.
    private var isTestDictation = false

    /// True when the current inline session is in AI mode — started with the AI hotkey or
    /// switched to it — so the transcription gets routed through `TextRefinementService`
    /// before pasting.
    private(set) var isAIMode = false
    /// Where the text is going: for an AI dictation, read at the stop from
    /// `pasteDestination`; for an edit, at its start from the app in front. Sent only with
    /// an AI rewrite.
    private var focusContext: FocusContext?
    /// The current recording's tier reports text while the user speaks (a stream, or
    /// Apple's on-device recogniser), so the overlay shows it. Nothing is pasted before
    /// the stop either way.
    private(set) var showsLiveTranscript = false
    /// True while the LLM is rewriting the transcription — keeps the overlay spinning.
    private(set) var isRefining = false
    private var refinementTask: Task<Void, Never>?
    /// The task parked in `waitForTranscription()`. Cancelling the inline flow cancels
    /// it too: `cancelRecording()` moves the engine off `.finishing`, which resumes the
    /// waiter, and without the cancel it would run `handleTranscriptionResult()` over
    /// the cleared texts and pop "No speech detected" for an action the user asked for.
    private var transcriptionWaitTask: Task<Void, Never>?

    /// Presses and releases of the two dictation shortcuts, and whether the one that
    /// started a dictation is still held.
    private var hotkeyGesture = DictationHotkeyGesture()

    /// Where the inline flow is, in the terms the shortcuts care about.
    var dictationPhase: DictationHotkeyGesture.Phase {
        if speechEngine.isTranscribing || isRefining { return .busy }
        if speechEngine.isStartingEngine { return .starting(ai: isAIMode) }
        if speechEngine.isRecording { return .recording(ai: isAIMode) }
        return .idle
    }

    /// Without an AI provider the AI shortcut is simply a second dictation shortcut: a
    /// dictation that ends in "AI processing skipped" every time teaches the user nothing.
    private func effectiveKey(_ key: DictationHotkey) -> DictationHotkey {
        key == .ai && !TextRefinementService.isConfigured ? .inline : key
    }

    /// A dictation shortcut went down.
    func hotkeyPressed(_ pressed: DictationHotkey) {
        // An edit's recording is an instruction, not a dictation: there is nothing for
        // a dictation shortcut to switch or stop, and the likeliest meaning of the press
        // is "not this, I want to dictate". It cancels the edit and does nothing more.
        if isEditMode {
            dlog("Hotkey", "\(pressed) pressed during an edit → cancel the edit")
            cancelEdit(.otherShortcut)
            return
        }
        if dictationTest.isBlocked && dictationPhase == .idle {
            dlog("Hotkey", "\(pressed) pressed while setup waits for the speech model → ignored")
            return
        }
        let key = effectiveKey(pressed)
        hotkeyGesture.holdToTalk = UserDefaults.standard.bool(forKey: SettingsKeys.holdToTalk)
        let phase = dictationPhase
        let action = hotkeyGesture.press(key, in: phase, at: ProcessInfo.processInfo.systemUptime)
        dlog("Hotkey", "\(key) pressed in \(phase) → \(action)")
        perform(action)
        if case .start = action, hotkeyGesture.owner != nil {
            beginHoldTip(pressed == .ai ? .ai : .inline, canSwitch: TextRefinementService.isConfigured)
        } else if hotkeyGesture.owner == nil {
            endHoldTip()
        }
    }

    /// A dictation shortcut came back up. Only acts with hold-to-talk on, and only for the
    /// shortcut that started the dictation.
    func hotkeyReleased(_ released: DictationHotkey) {
        guard !isEditMode else { return }
        let key = effectiveKey(released)
        let phase = dictationPhase
        let action = hotkeyGesture.release(key, in: phase, at: ProcessInfo.processInfo.systemUptime)
        dlog("Hotkey", "\(key) released in \(phase) → \(action)")
        perform(action)
        if hotkeyGesture.owner == nil { endHoldTip() }
        if hotkeyGesture.awaitsSecondTap {
            scheduleDictationTapTimer()
        }
    }

    /// Cancels a tapped dictation unless a second tap locks it on first.
    private var dictationTapTimer: DispatchWorkItem?

    private func scheduleDictationTapTimer() {
        dictationTapTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dictationTapTimer = nil
            // The microphone is an edit's now: `dictationPhase` would read its recording
            // as the tapped dictation's, and the cancel would end the edit's instead.
            guard !self.isEditMode else { return }
            let action = self.hotkeyGesture.tapWindowExpired(in: self.dictationPhase, at: ProcessInfo.processInfo.systemUptime)
            dlog("Hotkey", "dictation tap stood alone → \(action)")
            self.perform(action)
        }
        dictationTapTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationHotkeyGesture.doubleTapWindow, execute: timer)
    }

    /// Drops a tap still waiting for its second half, with its timer: the dictation it
    /// belonged to is over, and the timer would otherwise cancel whatever records next —
    /// an edit started within the window, whose recording it took for the dictation's.
    private func cancelDictationTap() {
        dictationTapTimer?.cancel()
        dictationTapTimer = nil
        hotkeyGesture.reset()
    }

    /// The menu's items: a press with nothing held.
    func toggleRecording(aiMode: Bool = false) {
        if isEditMode {
            cancelEdit(.otherShortcut)
            return
        }
        dlog("App", "toggleRecording: isRecording=\(speechEngine.isRecording), isTranscribing=\(speechEngine.isTranscribing), isStartingEngine=\(speechEngine.isStartingEngine)")
        perform(hotkeyGesture.click(effectiveKey(aiMode ? .ai : .inline), in: dictationPhase))
    }

    private func perform(_ action: DictationHotkeyAction) {
        switch action {
        case .start(let ai):
            isAIMode = ai
            startRecording()
        case .switchTo(let ai):
            switchMode(toAI: ai)
        case .stop:
            // A stop before the microphone opened has nothing to transcribe.
            if speechEngine.isRecording {
                stopRecording()
            } else {
                cancelInlineFlow(.shortcut)
            }
        case .cancel(let reason):
            cancelInlineFlow(reason)
        case .lock:
            dlog("App", "double tap — the dictation stays on hands-free")
            dictationTapTimer?.cancel()
            dictationTapTimer = nil
        case .ignore:
            break
        }
    }

    /// The dictation carries on in the other mode. What is said stays one dictation;
    /// only its handling at the stop changes — nothing has been pasted yet, in either
    /// direction, so there is nothing to take back.
    private func switchMode(toAI: Bool) {
        dlog("App", "switching the dictation to \(toAI ? "AI" : "plain text")")
        isAIMode = toAI
        if toAI { LLMConfiguration.prewarmIfLocal() }
        DictationTraceRecorder.record(.modeSwitch, text: toAI ? "ai" : "inline")
    }

    /// Aborts recording, transcription and any in-flight LLM call, drops the overlay, and
    /// says so: no cancel is silent.
    func cancelInlineFlow(_ reason: DictationCancelReason) {
        // Written at the stop, before the LLM: a cancel during the rewrite leaves it there.
        let savedInHistory = isRefining && speechEngine.lastRecordID != nil
        dlog("App", "cancelling mid-flight (\(reason)\(savedInHistory ? ", the transcript stays in History" : ""))")
        cancelDictationTap()
        transcriptionWaitTask?.cancel()
        transcriptionWaitTask = nil
        refinementTask?.cancel()
        refinementTask = nil
        isRefining = false
        pasteDestination = nil
        DictationTraceRecorder.current = nil
        speechEngine.cancelRecording()
        hideOverlay()
        let notice = reason.notice(savedInHistory: savedInHistory)
        showStatus(icon: "xmark.circle", title: notice.title, detail: notice.detail, tint: .secondary,
                   duration: savedInHistory ? 5 : 3)
    }

    private func startRecording() {
        let began = ProcessInfo.processInfo.systemUptime
        // A choice the launch cleared is the user's to make again: the dictation is
        // refused with the picker on offer, before the overlay or the microphone opens.
        let engine = UserDefaults.standard.string(forKey: SettingsKeys.sttProvider).flatMap(STTProviderType.init) ?? .apple
        if let key = engine.vendor.descriptor.speechModel?.settingsKey,
           UserDefaults.standard.string(forKey: key) == clearedModelChoice {
            dlog("App", "startRecording: no model chosen for \(key) — refused", level: .notice)
            show(modelChoiceNotice(settingsKey: key, role: .speech,
                                   migrations: storedModelMigrations(in: .standard)))
            return
        }
        isTestDictation = dictationTest.isActive
        let front = NSWorkspace.shared.frontmostApplication
        if isTestDictation {
            // The result goes to the setup window; there is no app to paste into.
            previousApp = nil
            dictationOrigin = nil
            dictationTest.began(ai: isAIMode)
        } else {
            dictationOrigin = InlineDelivery.origin(
                front: front, frontIsSpeechText: front?.bundleIdentifier == Bundle.main.bundleIdentifier)
            if let dictationOrigin { previousApp = dictationOrigin }
        }
        pasteDestination = nil
        focusContext = nil
        let locale = resolvedLocale()
        // The same settings the engine snapshots a moment later, read the same way.
        showsLiveTranscript = RecordingConfiguration.current(locale: locale).hasLiveText
        dlog("App", "startRecording: origin=\(dictationOrigin?.localizedName ?? "nil"), locale=\(locale), aiMode=\(isAIMode), liveTranscript=\(showsLiveTranscript)")
        if isAIMode { LLMConfiguration.prewarmIfLocal() }

        speechEngine.recordsEmptyOutcomes = true
        beginTrace()
        showOverlay()

        // A start that fails (microphone refused, no input device, a stream that could
        // not open) never reaches a stop, and the "preparing" overlay used to sit there
        // until the next hotkey press.
        speechEngine.onStartFailure = { [weak self] message in
            self?.handleStartFailure(message)
        }
        // Nor did a recogniser that failed before any text: the overlay listened on until
        // the user stopped. The engine has stopped by now; the result is the stop's.
        speechEngine.onRecognitionFailure = { [weak self] message in
            self?.handleRecognitionFailure(message)
        }
        // Nor did a microphone that went away mid-dictation: the engine stopped and wrote
        // the History row, and nothing was pasted.
        speechEngine.onMicrophoneLost = { [weak self] message in
            self?.handleMicrophoneLost(message)
        }
        // Retried by itself once the network is back — but not a test dictation, whose
        // result belongs to the setup window that has long moved on by then.
        speechEngine.onSavedOffline = isTestDictation ? nil : { id in MainActor.assumeIsolated { OfflineRetry.shared.enqueue(id) } }
        speechEngine.startRecording(locale: locale)
        // Not over a start that failed at once: its notice is the one to read, and this
        // one would be spent unseen.
        if speechEngine.isStartingEngine || speechEngine.isRecording { showModelNoticeOnce() }
        // The overlay was ordered front above, but draws only once this returns.
        let held = ProcessInfo.processInfo.systemUptime - began
        dlog("App", "\(held > 0.25 ? "⚠ " : "")startRecording held the main thread \(Int(held * 1000)) ms — the overlay draws after it", level: held > 0.25 ? .notice : .info)
    }

    /// The engine ended the dictation itself: the rest of an ordinary stop, without a
    /// second engine stop, and without a paste target or a focus context — the result
    /// is a failure, which goes to neither.
    private func handleRecognitionFailure(_ message: String) {
        dlog("App", "recognition failed before any text — ending the dictation: \(message)", level: .error)
        DictationTraceRecorder.record(.stop)
        waitForTranscription()
    }

    /// The engine ended the dictation itself — its microphone went away — and is finishing
    /// it as a stop does. The rest of an ordinary stop follows, in `stopRecording`'s order:
    /// the text goes to the app in front now, as if the user had stopped there, and the
    /// result is handled as any stop's is.
    private func handleMicrophoneLost(_ message: String) {
        dlog("App", "the microphone was lost — ending the dictation: \(message)", level: .error)
        choosePasteDestination()
        DictationTraceRecorder.record(.stop)
        if isAIMode {
            readFocusContext(of: pasteDestination)
        }
        waitForTranscription()
    }

    private func handleStartFailure(_ message: String) {
        dlog("App", "startRecording failed: \(message)", level: .error)
        DictationTraceRecorder.current = nil
        hideOverlay()
        // Setup's Try it says it in its own panel, with Try again, rather than in a
        // notice in the corner of the screen.
        if isTestDictation {
            dictationTest.finished(.failed(friendlySTTError(message)), ai: isAIMode)
            return
        }
        showStatus(
            icon: "exclamationmark.triangle.fill",
            title: "Couldn't start recording",
            detail: friendlySTTError(message),
            tint: .orange
        )
    }

    /// Starts this dictation's trace, when Debug Log › Record traces is on.
    private func beginTrace() {
        DictationTraceRecorder.current = DictationTraceRecorder.isEnabled
            ? DictationTraceRecorder(setup: DictationTrace.Setup(
                aiMode: isAIMode,
                removesDisfluencies: UserDefaults.standard.object(forKey: SettingsKeys.removeDisfluencies) as? Bool ?? true,
                dashStyle: .current,
                app: dictationOrigin?.localizedName))
            : nil
    }

    private func stopRecording() {
        dlog("App", "stopRecording")
        // First, while the app the user stopped in is certainly the one in front.
        choosePasteDestination()
        DictationTraceRecorder.record(.stop)
        speechEngine.stopRecording()
        // After the engine stop, not before: these are round trips to another process, and
        // only the LLM pass reads the answer. The mode cannot change past this point —
        // every press while the stop is transcribing cancels.
        if isAIMode {
            readFocusContext(of: pasteDestination)
        }
        waitForTranscription()
    }

    /// Fixes where this dictation goes: the app in front now, unless that is SpeechText
    /// itself (`InlineDelivery.destination`). A test dictation goes nowhere — its result
    /// belongs to the setup window.
    private func choosePasteDestination() {
        let front = NSWorkspace.shared.frontmostApplication
        pasteDestination = isTestDictation ? nil : InlineDelivery.destination(
            front: front,
            frontIsSpeechText: front?.bundleIdentifier == Bundle.main.bundleIdentifier,
            origin: dictationOrigin)
        let destination = pasteDestination?.localizedName ?? "nil"
        if pasteDestination?.processIdentifier != dictationOrigin?.processIdentifier {
            dlog("App", "paste target: \(destination) (started in \(dictationOrigin?.localizedName ?? "nil"))")
        } else {
            dlog("App", "paste target: \(destination)")
        }
        DictationTraceRecorder.recordDestination(pasteDestination?.localizedName)
    }

    /// Reads what the AI prompt is told about where the text is going. Never with a nil
    /// app: `readFocusContext(in: nil)` would describe whatever is frontmost.
    private func readFocusContext(of app: NSRunningApplication?) {
        focusContext = app.flatMap { PasteService.readFocusContext(in: $0) }
        if let focusContext {
            // The window title stays out of the system log — it can be a mail subject.
            dlog("Refine", "focus context: \(focusContext.appName ?? "?") (\(focusContext.bundleID ?? "?")), window title \(focusContext.windowTitle == nil ? "absent" : "present")")
        }
    }

    /// Suspends until the engine reports that transcription has finished, then handles
    /// the result. The engine resumes us from the same place it flips `isTranscribing`
    /// off, which is always after `finalText` / `errorMessage` / `lastRecordID` are set,
    /// so the ordering the old 50ms poll relied on is preserved without the polling.
    private func waitForTranscription() {
        transcriptionWaitTask?.cancel()
        transcriptionWaitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            await speechEngine.awaitTranscription()
            // A cancel resumed us by moving the engine to `.idle` — there is no result
            // to handle, and reporting the cleared texts would claim "No speech detected".
            guard !Task.isCancelled else { return }
            dlog("App", "waitForTranscription: done (\(String(format: "%.2f", Date().timeIntervalSince(started)))s)")
            handleTranscriptionResult()
        }
    }

    private func handleTranscriptionResult() {
        let text = speechEngine.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        dlog("App", "handleTranscriptionResult: text=\(text.count) chars, destination=\(pasteDestination?.localizedName ?? "nil"), aiMode=\(isAIMode)")

        let result = InlineDelivery.stopResult(finalText: text,
                                               failed: speechEngine.errorMessage != nil,
                                               aiMode: isAIMode,
                                               recordingText: speechEngine.spanLayer.text)
        if isTestDictation, reportTestResult(result) {
            finishTrace()
            return
        }
        switch result {
        case .failed(let partial):
            // A failed transcription used to end here silently — the user just saw nothing
            // happen and lost everything they said. Always surface it.
            let rawError = speechEngine.errorMessage ?? ""
            dlog("App", "handleTranscriptionResult: error — \(rawError)", level: .error)
            hideOverlay()
            if let recordID = speechEngine.offlineRecordID {
                // Not an error to read: nothing is lost, it is waiting in History — with
                // where it was going and, for an AI dictation, what its rewrite is told.
                if !isTestDictation {
                    TranscriptionHistory.shared.recordUndelivered(id: recordID, TranscriptionRecord.Undelivered(
                        app: pasteDestination?.localizedName, bundleID: pasteDestination?.bundleIdentifier,
                        rewrite: isAIMode, context: isAIMode ? focusContext : nil))
                }
                showSavedOffline(recordID)
            } else if speechEngine.failedForModel {
                // Not "switched off": the same reply means a key without access. The
                // vendor's words are in History (a tap opens it), with the audio to retry
                // once a model is chosen.
                showStatus(
                    icon: "exclamationmark.triangle.fill",
                    title: "This model isn't available",
                    detail: "The service won't serve it to your key. The recording is in History.",
                    tint: .orange,
                    duration: 10,
                    action: StatusOverlayAction(title: "Choose") { [weak self] in
                        self?.perform(.openSettings(.speech))
                    }
                )
            } else if let missing = LocalModelStore.shared.missingSelectedModel(
                engine: UserDefaults.standard.string(forKey: SettingsKeys.sttProvider) ?? "",
                modelID: UserDefaults.standard.string(forKey: SettingsKeys.localSTTModel)
                    ?? Provider.local.defaultSpeechModel) {
                // The model this Mac transcribes with is not on it: Install starts the
                // download and opens the page that shows it; the recording waits in History.
                showStatus(
                    icon: "exclamationmark.triangle.fill",
                    title: "\(speechModelName(missing)) isn't installed",
                    detail: "Install it, then retry from History.",
                    tint: .orange,
                    duration: 10,
                    action: StatusOverlayAction(title: "Install") { [weak self] in
                        LocalModelStore.shared.install(missing)
                        self?.perform(.openSettings(.speech))
                    }
                )
            } else {
                showStatus(
                    icon: "exclamationmark.triangle.fill",
                    title: "Transcription failed",
                    detail: friendlySTTError(rawError),
                    tint: .orange
                )
            }
            // Any partial text is better than nothing — hand it to the Record Window.
            // Refinement is skipped: there is no trustworthy transcript to rewrite.
            if let partial, !partial.isEmpty {
                showDirectRecordingPanel(withText: partial.trimmingCharacters(in: .whitespaces))
            }

        case .noSpeech:
            dlog("App", "handleTranscriptionResult: empty text")
            hideOverlay()
            showStatus(
                icon: "waveform.slash",
                title: "No speech detected",
                detail: "Nothing was transcribed from that recording.",
                tint: .secondary
            )

        case .paste(let text):
            beginOverlayConfirmation()
            recordApps()
            deliver(text)

        case .refine(let aiInput):
            recordApps()
            // The trace is finished once the rewrite has been delivered.
            refine(aiInput)
            return
        }
        finishTrace()
    }

    /// Writes where the dictation started and where it is going to History — only for one
    /// that is about to be pasted: a failure or an empty result went nowhere.
    private func recordApps() {
        guard !isTestDictation, let id = speechEngine.lastRecordID else { return }
        TranscriptionHistory.shared.recordApps(id: id, origin: dictationOrigin?.localizedName,
                                               originBundleID: dictationOrigin?.bundleIdentifier,
                                               destination: pasteDestination?.localizedName,
                                               destinationBundleID: pasteDestination?.bundleIdentifier)
    }

    /// Takes back the destination `recordApps` wrote, once `deliver` hands the text to the
    /// Record Window instead: History then says where it went, not where it was meant to.
    private func recordNotPasted() {
        guard !isTestDictation, let id = speechEngine.lastRecordID else { return }
        TranscriptionHistory.shared.recordApps(id: id, origin: dictationOrigin?.localizedName,
                                               originBundleID: dictationOrigin?.bundleIdentifier,
                                               destination: nil)
    }

    /// Hands a test dictation's result to setup instead of pasting it or raising a notice:
    /// the Try it step says in its own words what happened. False for an AI rewrite,
    /// which `refine` reports once the model has answered.
    private func reportTestResult(_ result: InlineDelivery.StopResult) -> Bool {
        let outcome: DictationTest.Outcome
        switch result {
        case .failed:
            outcome = .failed(friendlySTTError(speechEngine.errorMessage ?? ""))
        case .noSpeech:
            outcome = .nothingHeard
        case .paste(let text):
            outcome = .typed(text)
        case .refine:
            return false
        }
        hideOverlay()
        dictationTest.finished(outcome, ai: isAIMode)
        return true
    }

    /// Writes the dictation's trace, when one is being recorded.
    private func finishTrace() {
        guard let recorder = DictationTraceRecorder.current else { return }
        DictationTraceRecorder.current = nil
        if let url = recorder.write(into: DictationTraceRecorder.directory) {
            dlog("Trace", "trace written: \(url.lastPathComponent)")
        }
    }

    /// AI mode's half of the stop: the LLM rewrites `aiInput`, and the result is pasted,
    /// sent, or — on any failure — replaced by the raw transcript.
    private func refine(_ aiInput: String) {
        guard TextRefinementService.isConfigured else {
            dlog("App", "handleTranscriptionResult: AI mode but LLM not configured — pasting raw transcript", level: .notice)
            hideOverlay()
            let type = LLMConfiguration.providerType
            showStatus(
                icon: "key.slash",
                title: "AI processing skipped",
                detail: type.needsAPIKey
                    ? "No API key for \(type.displayName). Pasted the raw transcription."
                    : "No \(type.displayName) model selected. Pasted the raw transcription.",
                tint: .orange
            )
            DictationTraceRecorder.record(.refinement, error: "not configured")
            deliver(aiInput)
            finishTrace()
            return
        }

        // Keep the overlay up (now in its loading state) while the LLM rewrites the text.
        isRefining = true
        let recordID = speechEngine.lastRecordID
        let context = focusContext
        let isTest = isTestDictation
        refinementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var output = aiInput
            var rewritten = false
            do {
                let result = try await TextRefinementService.refine(aiInput, context: context)
                rewritten = true
                if Task.isCancelled { return }
                output = result.text
                DictationTraceRecorder.record(.refinement, text: result.text)
                if let recordID {
                    TranscriptionHistory.shared.recordRefinement(
                        id: recordID, input: aiInput, output: result.text,
                        presetName: result.presetName,
                        provider: result.provider, model: result.model,
                        context: context, usage: result.usage, latency: result.latency
                    )
                }
            } catch {
                if Task.isCancelled { return }
                if let recordID {
                    let type = LLMConfiguration.providerType
                    TranscriptionHistory.shared.recordRefinementFailure(
                        id: recordID, input: aiInput, error: error.localizedDescription,
                        provider: type.rawValue, model: LLMConfiguration.model(for: type),
                        context: context
                    )
                }
                DictationTraceRecorder.record(.refinement, error: error.localizedDescription)
                if isTest {
                    self.isRefining = false
                    self.refinementTask = nil
                    self.hideOverlay()
                    self.dictationTest.rewritten(said: aiInput, result: .failure(error))
                    return
                }
                // Never lose the dictation: fall back to the raw transcript, but say so
                // rather than pasting unrewritten text with no explanation.
                dlog("App", "refinement failed (\(error.localizedDescription)) — pasting raw transcript", level: .error)
                if case LLMError.noModelChosen? = error as? LLMError,
                   let key = LLMConfiguration.providerType.vendor.descriptor.chatModel?.settingsKey {
                    let notice = modelChoiceNotice(settingsKey: key, role: .chat,
                                                   migrations: storedModelMigrations(in: .standard))
                    self.show(notice, detail: "\(notice.detail) Pasted the raw transcription.")
                } else {
                    self.showStatus(
                        icon: "sparkles.slash",
                        title: "AI processing failed",
                        detail: (error as? LLMError)?.needsModelChoice == true
                            ? "The model isn't available to your key. Pasted the raw transcription."
                            : "\(error.localizedDescription) Pasted the raw transcription.",
                        tint: .orange,
                        duration: (error as? LLMError)?.needsModelChoice == true ? 10 : 5,
                        action: (error as? LLMError)?.needsModelChoice == true
                            ? StatusOverlayAction(title: "Choose") { [weak self] in self?.perform(.openSettings(.chat)) }
                            : nil
                    )
                }
            }
            self.isRefining = false
            self.refinementTask = nil
            // A rewrite that failed has its notice; only one that worked says where it went.
            if rewritten && !isTest {
                self.beginOverlayConfirmation()
            } else {
                self.hideOverlay()
            }
            if isTest {
                self.dictationTest.rewritten(said: aiInput, result: .success(output))
                self.finishTrace()
                return
            }
            self.deliver(output)
            self.finishTrace()
        }
    }

    /// Pastes into the app the dictation ended in (`pasteDestination`), falling back to
    /// the Record Window when that isn't possible.
    private func deliver(_ dictation: String) {
        // A trailing space, so a dictation continued into the same field does not start
        // glued to this one — every path upstream trims. It is added here, at the paste,
        // so History and the span layer keep the transcript as it was recognised, and before the trace is written so a recorded dictation
        // replays into the text that really went out — which the Record Window fallback
        // below inherits, where a trailing space costs nothing.
        let text = dictation + " "
        DictationTraceRecorder.record(.stopPaste, text: text)
        if !PasteService.isAccessibilityGranted {
            dlog("App", "deliver: no accessibility, showing record panel", level: .notice)
            recordNotPasted()
            dismissOverlayConfirmation()
            showDirectRecordingPanel(withText: text)
            showStatus(icon: "hand.raised.fill", title: "Not pasted — Accessibility is off",
                       detail: "Your text is in the Record Window. Turn on Accessibility so SpeechText can type for you.",
                       tint: .orange, duration: 8, action: Self.allowAccessibilityAction)
            return
        }

        // The origin only when the stop chose nothing — the engine ended the recording on
        // its own, which does not pass through `stopRecording`.
        guard let app = pasteDestination ?? dictationOrigin else {
            dlog("App", "deliver: no destination, showing record panel", level: .notice)
            dismissOverlayConfirmation()
            showDirectRecordingPanel(withText: text)
            return
        }

        // Paste into the destination — once it is the app in front: the ⌘V goes to whatever
        // is. If it quit, would not come forward, or its focused element is a known
        // non-text role (button, table, list, etc.), fall back to the Record Window instead.
        let alreadyFocused = app.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier

        let tryPaste = { [weak self] in
            let front = NSWorkspace.shared.frontmostApplication
            var menu: String?
            let check = InlineDelivery.pasteCheck(quit: app.isTerminated,
                                                  inFront: front?.processIdentifier == app.processIdentifier,
                                                  menuOpen: { menu = PasteService.openMenuBarMenu(); return menu != nil }(),
                                                  takesText: PasteService.canLikelyPasteText(in: app))
            guard check == .paste else {
                dlog("App", "deliver: not pasting into \(app.localizedName ?? "?") (\(check), \(front?.localizedName ?? "nil") in front\(menu.map { ", \($0) open" } ?? "")) — showing record panel", level: .notice)
                self?.recordNotPasted()
                self?.dismissOverlayConfirmation()
                self?.showDirectRecordingPanel(withText: text)
                let detail: String? = switch check {
                case .quit: "It quit before the text was ready. The text is in the Record Window."
                case .notInFront: "It didn't come to the front. The text is in the Record Window."
                case .menuOpen: "\(menu ?? "A menu") was open and had the keyboard. The text is in the Record Window."
                case .takesNoText, .paste: nil
                }
                if let detail {
                    self?.showStatus(icon: "exclamationmark.triangle.fill",
                                     title: "Couldn't paste into \(app.localizedName ?? "the app")",
                                     detail: detail, tint: .orange)
                }
                return
            }
            PasteService.pasteAtCursor(text)
            self?.confirmOverlay(app.localizedName.map { "Pasted into \($0)" } ?? "Pasted")
        }

        if alreadyFocused || app.isTerminated {
            tryPaste()
        } else {
            PasteService.activateApp(app)
            // Blind wait on purpose: activation completes in the other app, which gives
            // us no signal for when it can take a ⌘V. Do not replace with a callback.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                tryPaste()
            }
        }
    }

    func pasteTextToTarget(_ text: String) {
        dlog("App", "pasteTextToTarget: \(text.count) chars, previousApp=\(previousApp?.localizedName ?? "nil")")

        // With no app to bring back, the ⌘V would land in the Record Window itself — the
        // app in front — and double its text.
        guard let app = previousApp, !app.isTerminated else {
            dlog("App", "pasteTextToTarget: no app to insert into (\(previousApp == nil ? "none saved" : "it quit"))", level: .notice)
            showStatus(icon: "exclamationmark.triangle.fill", title: "No app to insert into",
                       detail: "The app the Record Window was opened from is gone. Copy the text instead.",
                       tint: .orange)
            return
        }

        // Re-activate the app the user was in before recording
        PasteService.activateApp(app)

        // Wait for the app to regain focus, then paste. A blind wait on purpose: focus
        // moves in another process and nothing tells us when its text field is ready
        // for ⌘V. No completion can replace this 0.5s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let front = NSWorkspace.shared.frontmostApplication
            var menu: String?
            let check = InlineDelivery.pasteCheck(quit: app.isTerminated,
                                                  inFront: front?.processIdentifier == app.processIdentifier,
                                                  menuOpen: { menu = PasteService.openMenuBarMenu(); return menu != nil }(),
                                                  takesText: true)
            guard check == .paste else {
                dlog("App", "pasteTextToTarget: not pasting into \(app.localizedName ?? "?") (\(check), \(front?.localizedName ?? "nil") in front)", level: .notice)
                self?.showStatus(icon: "exclamationmark.triangle.fill",
                                 title: "Couldn't insert into \(app.localizedName ?? "the app")",
                                 detail: check == .quit
                                     ? "It quit. The text is still in the Record Window."
                                     : check == .menuOpen
                                         ? "\(menu ?? "A menu") was open and had the keyboard. The text is still in the Record Window."
                                         : "It didn't come to the front. The text is still in the Record Window.",
                                 tint: .orange)
                return
            }
            PasteService.pasteAtCursor(text)
        }
    }

    // MARK: - Editing the selection

    /// Where the edit's selected text is.
    private enum EditRemoval {
        /// Still in the document, selected.
        case inPlace
        /// The ⌘X is on its way.
        case removing
        /// Cut. `original` is the pasteboard as the ⌘X left it, formatting included, so an
        /// edit that fails or is cancelled puts back exactly what was there.
        case removed(original: [NSPasteboardItem], text: String)
        /// The ⌘X changed nothing — a read-only field. The rewrite ends on the clipboard.
        case notRemovable
    }

    /// The spoken instruction, from the microphone to the text the LLM is given.
    private enum EditInstruction {
        case listening
        case transcribing
        /// Nil text: none was given (a double press, or nothing said).
        case ready(String?, recordID: UUID?)
    }

    /// True from the Edit shortcut's first press until its rewrite is written or dropped.
    /// The overlay turns violet-filled with the pencil glyph; the dictation shortcuts
    /// cancel instead of acting.
    private(set) var isEditMode = false
    private var editGesture = EditHotkeyGesture()
    /// The selection being edited, once it has been read.
    private var editSelection: CapturedSelection?
    private var isReadingSelection = false
    /// `editSelection` was read after the instruction ended, so it is the selection the
    /// edit works on; otherwise it is read again before the cut.
    private var selectionIsCurrent = false
    private var editRemoval = EditRemoval.inPlace
    /// The instruction is over: the selection goes as soon as it has been read.
    private var removesSelection = false
    private var editInstruction = EditInstruction.listening
    /// Fires `doubleTapWindow` after a hold-to-talk tap, which cancels unless a second
    /// press came first.
    private var editTapTimer: DispatchWorkItem?
    /// Bumped whenever an edit ends, so a callback from the one before — a ⌘C or ⌘X poll,
    /// a transcription, an LLM reply — cannot act on the next.
    private var editGeneration = 0

    /// Where the edit is, in the terms the Edit shortcut cares about.
    private var editPhase: EditHotkeyGesture.Phase {
        guard isEditMode else { return .idle }
        if speechEngine.isStartingEngine { return .starting }
        if speechEngine.isRecording { return .recording }
        return .busy
    }

    /// The Edit shortcut went down.
    func editHotkeyPressed() {
        guard isEditMode || dictationPhase == .idle else {
            dlog("Hotkey", "edit pressed during a dictation → ignored")
            return
        }
        if !isEditMode {
            editGesture.holdToTalk = UserDefaults.standard.bool(forKey: SettingsKeys.holdToTalk)
        }
        let phase = editPhase
        let action = editGesture.press(in: phase, at: ProcessInfo.processInfo.systemUptime)
        dlog("Hotkey", "edit pressed in \(phase) → \(action)")
        perform(action)
        if case .start = action, editGesture.isHeld, isEditMode {
            beginHoldTip(.edit, canSwitch: false)
        } else if !editGesture.isHeld {
            endHoldTip()
        }
    }

    /// The Edit shortcut came back up.
    func editHotkeyReleased() {
        guard isEditMode else { return }
        let phase = editPhase
        let action = editGesture.release(in: phase, at: ProcessInfo.processInfo.systemUptime)
        dlog("Hotkey", "edit released in \(phase) → \(action)")
        perform(action)
        if !editGesture.isHeld { endHoldTip() }
        if editGesture.awaitsSecondTap {
            scheduleEditTapTimer()
        }
    }

    /// The menu's item: a press with nothing held.
    func toggleEdit() {
        guard isEditMode || dictationPhase == .idle else { return }
        perform(editGesture.click(in: editPhase))
    }

    private func scheduleEditTapTimer() {
        editTapTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.editTapTimer = nil
            let action = self.editGesture.tapWindowExpired(in: self.editPhase, at: ProcessInfo.processInfo.systemUptime)
            dlog("Hotkey", "edit tap stood alone → \(action)")
            self.perform(action)
        }
        editTapTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + EditHotkeyGesture.doubleTapWindow, execute: timer)
    }

    private func perform(_ action: EditHotkeyAction) {
        switch action {
        case .start:
            startEdit()
        case .send:
            sendEdit()
        case .sendWithoutInstruction:
            dlog("Edit", "double press — no instruction")
            editTapTimer?.cancel()
            editTapTimer = nil
            // A microphone still starting may yet fail; that no longer concerns this edit.
            speechEngine.onStartFailure = nil
            speechEngine.onRecognitionFailure = nil
            speechEngine.onMicrophoneLost = nil
            speechEngine.cancelRecording()
            editInstruction = .ready(nil, recordID: nil)
            removesSelection = true
            advanceEdit()
        case .cancel(let reason):
            cancelEdit(reason)
        case .ignore:
            break
        }
    }

    /// Reads the selection and opens the microphone for an instruction, together.
    private func startEdit() {
        // A dictation tapped and cancelled (⎋, ✕) just before this press may still be
        // waiting for its second tap: once its window ran out it would cancel this
        // edit's recording, which it takes for its own.
        cancelDictationTap()
        let front = NSWorkspace.shared.frontmostApplication
        guard front?.bundleIdentifier != Bundle.main.bundleIdentifier else {
            editGesture.reset()
            showStatus(icon: "character.cursor.ibeam", title: "Nothing to edit here",
                       detail: "Select text in another app, then press the Edit shortcut.", tint: .secondary)
            return
        }
        LLMConfiguration.prewarmIfLocal()
        guard PasteService.isAccessibilityGranted else {
            editGesture.reset()
            showStatus(icon: "hand.raised.fill", title: "Accessibility access needed",
                       detail: "SpeechText needs it to read the selected text and replace it.", tint: .orange,
                       duration: 8, action: Self.allowAccessibilityAction)
            return
        }
        previousApp = front
        editGeneration += 1
        let generation = editGeneration
        isEditMode = true
        isAIMode = false
        editSelection = nil
        selectionIsCurrent = false
        isReadingSelection = true
        editRemoval = .inPlace
        removesSelection = false
        editInstruction = .listening
        // Nothing of the instruction is ever pasted, and it is not traced.
        DictationTraceRecorder.current = nil
        let locale = resolvedLocale()
        showsLiveTranscript = RecordingConfiguration.current(locale: locale).streams
        dlog("Edit", "start: app=\(front?.localizedName ?? "nil"), holdToTalk=\(editGesture.holdToTalk), liveTranscript=\(showsLiveTranscript)")
        showOverlay()

        // Read first, while the app is certainly in front and before the engine's start
        // competes with the ⌘C. The answer is handled on a later turn of the run loop even
        // when AX gave it at once, so the engine below has started by then and a "nothing
        // selected" cancel stops it rather than running ahead of it.
        PasteService.readSelection(in: front) { [weak self] read in
            DispatchQueue.main.async {
                guard let self, self.isEditMode, self.editGeneration == generation else { return }
                self.selectionRead(read)
            }
        }
        // An instruction transcribed later has no selection left to apply to.
        speechEngine.onSavedOffline = nil
        speechEngine.onStartFailure = { [weak self] message in
            guard let self, self.isEditMode, self.editGeneration == generation else { return }
            dlog("Edit", "microphone failed to start: \(message)", level: .error)
            self.abortEdit(icon: "exclamationmark.triangle.fill", title: "Couldn't start recording",
                           detail: self.friendlySTTError(message))
        }
        // The recogniser failed before any of the instruction was heard, and the engine
        // stopped. Nothing has been cut yet — that waits for the instruction to end — so
        // the edit just ends, once the stop has written its History row.
        speechEngine.onRecognitionFailure = { [weak self] message in
            guard let self, self.isEditMode, self.editGeneration == generation else { return }
            dlog("Edit", "recognition failed before any instruction: \(message)", level: .error)
            self.abortEditOnceStopped(generation: generation, message: message)
        }
        // So did a microphone that went away while the instruction was spoken. The edit
        // ends the same way rather than rewriting the selection to half an instruction.
        speechEngine.onMicrophoneLost = { [weak self] message in
            guard let self, self.isEditMode, self.editGeneration == generation else { return }
            dlog("Edit", "the microphone was lost during the instruction: \(message)", level: .error)
            self.abortEditOnceStopped(generation: generation, message: message)
        }
        // Saying nothing is a request to polish, and the edit writes its own record.
        speechEngine.recordsEmptyOutcomes = false
        speechEngine.startRecording(locale: locale)
        focusContext = PasteService.readFocusContext(in: front)
    }

    /// The engine stopped the instruction's recording itself: the edit ends once that
    /// stop has written its History row.
    private func abortEditOnceStopped(generation: Int, message: String) {
        transcriptionWaitTask?.cancel()
        transcriptionWaitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.speechEngine.awaitTranscription()
            guard !Task.isCancelled, self.isEditMode, self.editGeneration == generation else { return }
            self.transcriptionWaitTask = nil
            self.abortEdit(icon: "exclamationmark.triangle.fill", title: "Couldn't hear the instruction",
                           detail: self.friendlySTTError(message))
        }
    }

    private func selectionRead(_ read: PasteService.SelectionRead) {
        isReadingSelection = false
        // Read after the instruction was already over: this is the selection at the
        // send, and needs no second read.
        selectionIsCurrent = removesSelection
        switch read {
        case .nothingSelected:
            abortEdit(icon: "character.cursor.ibeam", title: "No text selected",
                      detail: "Select the text to rework, then press the Edit shortcut.", tint: .secondary)
        case .selected(let selection):
            guard selection.text.count <= SelectionEdit.maxCharacters else {
                abortEdit(icon: "text.badge.xmark", title: "Selection too long",
                          detail: "Select up to \(SelectionEdit.maxCharacters.formatted()) characters to edit with AI.")
                return
            }
            editSelection = selection
            advanceEdit()
        }
    }

    /// Closes the microphone and takes the selection out while the instruction is
    /// transcribed.
    private func sendEdit() {
        guard speechEngine.isRecording else {
            // Stopped before the microphone opened: whatever was said went nowhere, and a
            // rewrite without it would not be what was asked for.
            abortEdit(icon: "mic.slash", title: "The microphone wasn't ready",
                      detail: "Nothing was changed. Try again — or double-press to edit without an instruction.")
            return
        }
        let generation = editGeneration
        editInstruction = .transcribing
        removesSelection = true
        speechEngine.stopRecording()
        advanceEdit()
        transcriptionWaitTask?.cancel()
        transcriptionWaitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.speechEngine.awaitTranscription()
            guard !Task.isCancelled, self.isEditMode, self.editGeneration == generation else { return }
            self.transcriptionWaitTask = nil
            if let error = self.speechEngine.errorMessage {
                dlog("Edit", "instruction failed: \(error)", level: .error)
                self.abortEdit(icon: "exclamationmark.triangle.fill", title: "Couldn't understand the instruction",
                               detail: self.friendlySTTError(error))
                return
            }
            let instruction = self.speechEngine.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing said is the same as a double press: polish.
            self.editInstruction = .ready(instruction.isEmpty ? nil : instruction,
                                          recordID: instruction.isEmpty ? nil : self.speechEngine.lastRecordID)
            self.advanceEdit()
        }
    }

    /// Moves the edit on as far as what has arrived allows: once the instruction is over
    /// and the selection read, the selection is cut; once it is cut and the instruction
    /// transcribed, the LLM gets both. Called whenever one of those lands.
    private func advanceEdit() {
        guard isEditMode, let selection = editSelection else { return }
        if removesSelection, case .inPlace = editRemoval {
            takeSelection(selection)
            return
        }
        guard case .ready(let instruction, let recordID) = editInstruction, refinementTask == nil else { return }
        switch editRemoval {
        case .inPlace, .removing: return
        case .removed, .notRemovable: runEdit(selection, instruction: instruction, recordID: recordID)
        }
    }

    /// The instruction is over: the selection is read again — the text selected
    /// *now* is the one rewritten, whatever was selected at the first press — and cut, so
    /// nothing the user does while the LLM works can make the rewrite land on the wrong
    /// text. The rewrite is then pasted at the caret the cut leaves.
    private func takeSelection(_ selection: CapturedSelection) {
        guard editAppIsInFront() else { return }
        guard !selectionIsCurrent else {
            removeSelection(selection)
            return
        }
        // Held here so `advanceEdit` does not start a second read meanwhile.
        editRemoval = .removing
        let generation = editGeneration
        PasteService.readSelection(in: previousApp) { [weak self] read in
            DispatchQueue.main.async {
                guard let self, self.isEditMode, self.editGeneration == generation else { return }
                self.selectionIsCurrent = true
                var current: CapturedSelection?
                if case .selected(let now) = read { current = now }
                switch SelectionEdit.target(read: selection, current: current) {
                case .nothingSelected:
                    self.abortEdit(icon: "character.cursor.ibeam", title: "No text selected",
                                   detail: "Nothing was selected when the instruction ended. Nothing was edited.",
                                   tint: .secondary)
                case .tooLong:
                    self.abortEdit(icon: "text.badge.xmark", title: "Selection too long",
                                   detail: "Select up to \(SelectionEdit.maxCharacters.formatted()) characters to edit with AI.")
                case .unchanged(let now):
                    self.editSelection = now
                    self.removeSelection(now)
                case .changed(let now):
                    dlog("Edit", "the selection changed while the instruction was spoken — editing the one selected now (\(now.text.count) chars, was \(selection.text.count))")
                    self.editSelection = now
                    self.removeSelection(now)
                }
            }
        }
    }

    /// Cuts the selection, and checks that what was cut is what was read: a click
    /// elsewhere since then would otherwise have taken other text out of the document.
    private func removeSelection(_ selection: CapturedSelection) {
        // Again: the read before this takes up to 0.6 s, time enough for a ⌘Tab.
        guard editAppIsInFront() else { return }
        editRemoval = .removing
        let generation = editGeneration
        var confirmed = false
        if let record = selection.record, let app = previousApp {
            switch PasteService.select(record, in: app) {
            case .changed:
                abortEdit(icon: "text.badge.xmark", title: "Couldn't find the selection again",
                          detail: "The selected words aren't where they were read. Nothing was edited.")
                return
            case .selected: confirmed = true
            case .unconfirmed: break
            }
        }
        let app = previousApp
        let isSelection = { [confirmed] (cut: String) in
            SelectionEdit.cutMatches(cut, selection: selection.text, selectionConfirmed: confirmed)
        }
        PasteService.cutSelection(isSelection: isSelection, landedLate: { [weak self] items in
            self?.putBackLateCut(items, in: app)
        }) { [weak self] cut in
            guard let self, self.isEditMode, self.editGeneration == generation else {
                // The edit was cancelled while the ⌘X was landing: nothing may go missing.
                if case .cut(let items, _) = cut { PasteService.pasteItems(items) }
                return
            }
            switch cut {
            case .nothing:
                dlog("Edit", "the selection could not be cut — the rewrite will go to the clipboard", level: .notice)
                self.editRemoval = .notRemovable
            case .cut(let items, let text):
                guard SelectionEdit.cutMatches(text, selection: selection.text, selectionConfirmed: confirmed) else {
                    dlog("Edit", "cut \(text.count) chars that are not the selection (read \(selection.record == nil ? "with ⌘C" : "through AX")), read \(selection.text.count) — putting them back", level: .notice)
                    PasteService.pasteItems(items)
                    self.abortEdit(icon: "text.badge.xmark", title: "Couldn't confirm the selection",
                                   detail: "What was cut wasn't the text that was read, so it was put back. Nothing was edited.")
                    return
                }
                let source = SelectionEdit.cutSource(text)
                if source != selection.text {
                    dlog("Edit", "the cut differs from the text read\(confirmed ? "" : " only in markup or spacing") — rewriting the cut (\(source.count) chars, read \(selection.text.count))")
                    self.editSelection = CapturedSelection(text: source, record: selection.record)
                }
                dlog("Edit", "selection cut (\(text.count) chars)")
                self.editRemoval = .removed(original: items, text: text)
            }
            self.advanceEdit()
        }
    }

    /// A ⌘X that landed after the edit had taken the field for one that cannot be cut: its
    /// text is out of the document, while the edit — running on, finished or cancelled —
    /// takes it for still there. It goes back where it was cut, the one write that is right
    /// in every one of those states; the rewrite still ends on the clipboard, as for a
    /// read-only field. Only into its app still in front — never by bringing that app back
    /// seconds later — and otherwise onto the clipboard, with a notice.
    private func putBackLateCut(_ items: [NSPasteboardItem], in app: NSRunningApplication?) {
        let front = NSWorkspace.shared.frontmostApplication
        if let app, InlineDelivery.pasteCheck(quit: app.isTerminated,
                                              inFront: front?.processIdentifier == app.processIdentifier,
                                              menuOpen: PasteService.openMenuBarMenu() != nil,
                                              takesText: true) == .paste {
            dlog("Edit", "the late cut goes back where it was")
            PasteService.pasteItems(items)
            return
        }
        dlog("Edit", "the late cut stays on the clipboard — \(app?.localizedName ?? "its app") is not in front")
        PasteService.copyToClipboard(items: items)
        showStatus(icon: "doc.on.clipboard", title: "The selected text is on the clipboard",
                   detail: "\(app?.localizedName ?? "The app") took it out late, once it wasn't in front. Paste it back with ⌘V.",
                   tint: .orange, duration: 10)
    }

    /// Whether the app the edit began in is still in front, so a ⌘C or ⌘X reaches it. If
    /// the user switched to another app while speaking, the edit ends here without
    /// touching either app's text — nothing has been cut yet — and says so.
    private func editAppIsInFront() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        guard !SelectionEdit.takesSelection(editing: previousApp?.processIdentifier,
                                            front: front?.processIdentifier) else { return true }
        dlog("Edit", "\(front?.localizedName ?? "nil") is in front, not \(previousApp?.localizedName ?? "nil") — the selection is not taken")
        abortEdit(icon: "character.cursor.ibeam", title: "The selection was in another app",
                  detail: "\(previousApp?.localizedName ?? "Its app") wasn't in front when the instruction ended. Nothing was edited.",
                  tint: .secondary)
        return false
    }

    /// Sends the selection to the LLM and writes the answer where it was.
    private func runEdit(_ selection: CapturedSelection, instruction: String?, recordID: UUID?) {
        guard TextRefinementService.isConfigured else {
            let type = LLMConfiguration.providerType
            abortEdit(icon: "key.slash", title: "AI isn't set up",
                      detail: type.needsAPIKey
                          ? "Add a \(type.displayName) API key in Settings to edit text with AI."
                          : "Choose a \(type.displayName) model in Settings to edit text with AI.")
            return
        }

        dlog("Edit", "rewriting \(selection.text.count) chars, instruction: \(instruction == nil ? "none" : "\(instruction!.count) chars")")
        isRefining = true
        let context = focusContext
        let generation = editGeneration
        refinementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await TextRefinementService.edit(selection.text, instruction: instruction, context: context)
                guard !Task.isCancelled, self.editGeneration == generation else { return }
                TranscriptionHistory.shared.recordSelectionEdit(
                    recordID: recordID, selection: selection.text, output: result.text, error: nil,
                    presetName: result.presetName, provider: result.provider, model: result.model,
                    context: context, usage: result.usage, latency: result.latency)
                let removal = self.editRemoval
                let app = self.previousApp
                self.refinementTask = nil
                self.beginOverlayConfirmation()
                self.finishEdit()
                self.writeEdit(result.text, over: selection, removal: removal, in: app)
            } catch {
                guard !Task.isCancelled, self.editGeneration == generation else { return }
                let type = LLMConfiguration.providerType
                TranscriptionHistory.shared.recordSelectionEdit(
                    recordID: recordID, selection: selection.text, output: "", error: error.localizedDescription,
                    presetName: nil, provider: type.rawValue, model: LLMConfiguration.model(for: type),
                    context: context)
                dlog("Edit", "rewrite failed: \(error.localizedDescription)", level: .error)
                self.refinementTask = nil
                self.abortEdit(icon: "sparkles", title: "AI edit failed", detail: error.localizedDescription)
            }
        }
    }

    /// Pastes the rewrite where the selection was cut. The caret is wherever the cut left
    /// it, unless the user has moved it since — then that is where the text goes.
    private func writeEdit(_ output: String, over selection: CapturedSelection,
                           removal: EditRemoval, in app: NSRunningApplication?) {
        switch removal {
        case .removed(let original, let cutText):
            guard SelectionEdit.changes(selection.text, to: output) else {
                dismissOverlayConfirmation()
                putBack(original, in: app)
                showStatus(icon: "checkmark", title: "Nothing to change",
                           detail: "The AI left the selected text as it was.", tint: .secondary)
                return
            }
            let text = SelectionEdit.preservingEdges(of: cutText, output)
            deliverToEditTarget(app, fallback: { [weak self] in
                self?.dismissOverlayConfirmation()
                PasteService.copyToClipboard(text)
            }) { [weak self] in
                dlog("Edit", "pasting the rewrite where the selection was")
                PasteService.pasteAtCursor(text)
                self?.confirmOverlay("Selection replaced")
            }
        case .notRemovable, .inPlace, .removing:
            dismissOverlayConfirmation()
            guard SelectionEdit.changes(selection.text, to: output) else {
                showStatus(icon: "checkmark", title: "Nothing to change",
                           detail: "The AI left the selected text as it was.", tint: .secondary)
                return
            }
            PasteService.copyToClipboard(output)
            showStatus(icon: "doc.on.clipboard", title: "Copied instead of replaced",
                       detail: "\(app?.localizedName ?? "The app") wouldn't let the selected text be removed. The new version is on the clipboard.",
                       tint: .orange, duration: 8)
        }
    }

    /// Puts the cut selection back, formatting and all.
    private func putBack(_ original: [NSPasteboardItem], in app: NSRunningApplication?) {
        dlog("Edit", "putting the selected text back")
        deliverToEditTarget(app, fallback: { PasteService.copyToClipboard(items: original) }) {
            PasteService.pasteItems(original)
        }
    }

    /// Runs `paste` in the edit's app, bringing it back to the front first if it has to.
    /// With the app gone, or still not in front once it was asked to come back — the ⌘V
    /// would go to whichever app is — `fallback` leaves the text on the clipboard instead.
    private func deliverToEditTarget(_ app: NSRunningApplication?, fallback: @escaping () -> Void,
                                     paste: @escaping () -> Void) {
        guard let app, !app.isTerminated else {
            fallback()
            showStatus(icon: "doc.on.clipboard", title: "The text is on the clipboard",
                       detail: "The app it came from is gone.", tint: .orange, duration: 8)
            return
        }
        let tryPaste = { [weak self] in
            let front = NSWorkspace.shared.frontmostApplication
            var menu: String?
            let check = InlineDelivery.pasteCheck(quit: app.isTerminated,
                                                  inFront: front?.processIdentifier == app.processIdentifier,
                                                  menuOpen: { menu = PasteService.openMenuBarMenu(); return menu != nil }(),
                                                  takesText: true)
            guard check == .paste else {
                dlog("Edit", "not pasting into \(app.localizedName ?? "?") (\(check), \(front?.localizedName ?? "nil") in front) — the text goes to the clipboard", level: .notice)
                fallback()
                self?.showStatus(icon: "doc.on.clipboard", title: "The text is on the clipboard",
                                 detail: check == .quit
                                     ? "The app it came from is gone."
                                     : check == .menuOpen
                                         ? "\(menu ?? "A menu") was open and had the keyboard, so nothing was pasted into \(app.localizedName ?? "the app")."
                                         : "\(app.localizedName ?? "The app") didn't come back to the front, so nothing was pasted into it.",
                                 tint: .orange, duration: 8)
                return
            }
            paste()
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            tryPaste()
            return
        }
        PasteService.activateApp(app)
        // Blind wait, as for every paste into an app brought back to the front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tryPaste() }
    }

    /// Abandons the edit wherever it is — cancelled, and says so.
    func cancelEdit(_ reason: EditCancelReason) {
        guard isEditMode else { return }
        var textPutBack = false
        if case .removed = editRemoval { textPutBack = true }
        dlog("Edit", "cancelled (\(reason))\(textPutBack ? ", putting the cut text back" : "")")
        let notice = reason.notice(textPutBack: textPutBack)
        abortEdit(icon: "xmark.circle", title: notice.title, detail: notice.detail, tint: .secondary,
                  notesPutBack: false)
    }

    /// Ends the edit without a rewrite. Text already cut goes back where it was; `title`,
    /// when given, says why.
    private func abortEdit(icon: String = "", title: String? = nil, detail: String = "",
                           tint: Color = .orange, notesPutBack: Bool = true) {
        let removal = editRemoval
        let app = previousApp
        transcriptionWaitTask?.cancel()
        transcriptionWaitTask = nil
        refinementTask?.cancel()
        refinementTask = nil
        speechEngine.cancelRecording()
        finishEdit()
        var detail = detail
        if case .removed(let original, _) = removal {
            putBack(original, in: app)
            if title != nil, notesPutBack { detail += " The text was put back." }
        }
        if let title {
            showStatus(icon: icon, title: title, detail: detail, tint: tint)
        }
    }

    /// Ends the edit's state and takes the overlay down; the engine is already idle.
    private func finishEdit() {
        editGeneration += 1
        editTapTimer?.cancel()
        editTapTimer = nil
        editGesture.reset()
        isRefining = false
        isEditMode = false
        editSelection = nil
        isReadingSelection = false
        selectionIsCurrent = false
        editRemoval = .inPlace
        removesSelection = false
        editInstruction = .listening
        hideOverlay()
    }

    private func showOverlay() {
        // Close any existing panel first to prevent orphaned overlays
        hideOverlay()
        dismissOverlayConfirmation(animated: false)

        let panel = RecordingOverlayPanel(showsTranscript: showsLiveTranscript)
        panel.host(ObservedOverlay(speechEngine: speechEngine, appState: self, layout: panel.layout,
                                   onTranscriptHeight: { [weak panel] in panel?.setTranscriptHeight($0) },
                                   onCancel: { [weak self, weak panel] in
            if self?.isEditMode == true {
                self?.cancelEdit(.closeButton)
                return
            }
            self?.cancelInlineFlow(.closeButton)
            // A stale panel, one `overlayPanel` no longer points to, is closed too.
            panel?.close()
        }))
        panel.orderFrontRegardless()
        overlayPanel = panel
        updateEscapeShortcut()
    }

    /// ⎋ is ours only while the overlay is up, and only if the user asked for it.
    private func updateEscapeShortcut() {
        let wanted = overlayPanel != nil && UserDefaults.standard.bool(forKey: SettingsKeys.escapeCancelsDictation)
        hotkeyManager.setEscapeShortcut(active: wanted)
    }

    /// ⎋, while the overlay is up: what its ✕ does.
    func escapePressed() {
        dlog("Hotkey", "⎋ → cancel")
        if isEditMode {
            cancelEdit(.escape)
        } else {
            cancelInlineFlow(.escape)
        }
    }

    private func hideOverlay() {
        endHoldTip()
        overlayPanel?.close()
        overlayPanel = nil
        updateEscapeShortcut()
    }

    // MARK: - Saying where the text went

    /// How long the overlay says where the text went before it fades.
    private static let confirmationSeconds: TimeInterval = 1
    /// The longest the ended overlay waits for the paste to report back — an app brought to
    /// the front takes 0.5 s — before it goes anyway.
    private static let confirmationWaitSeconds: TimeInterval = 3

    /// The dictation or the edit is over and its text is about to be pasted: the overlay
    /// stops being the recording's — ⎋ and its ✕ no longer cancel anything — and stays
    /// up, still, with the words it showed and the comet, until `confirmOverlay` says where
    /// the text went or `dismissOverlayConfirmation` takes it down.
    private func beginOverlayConfirmation() {
        guard let panel = overlayPanel else { return }
        endHoldTip()
        overlayPanel = nil
        updateEscapeShortcut()
        dismissOverlayConfirmation(animated: false)

        let state = OverlayConfirmation()
        panel.showTranscriptArea()
        panel.host(ConfirmationOverlay(
            state: state, layout: panel.layout,
            barLevels: speechEngine.barLevels.map { _ in 0 },
            isAIMode: isAIMode, isEditMode: isEditMode,
            settledText: showsLiveTranscript ? speechEngine.spanLayer.stableText : "",
            onTranscriptHeight: { [weak panel] in panel?.setTranscriptHeight($0) },
            onCancel: { [weak self] in self?.dismissOverlayConfirmation() }))
        confirmationPanel = panel
        confirmation = state
        scheduleConfirmationDismissal(after: Self.confirmationWaitSeconds)
    }

    /// The text landed: the overlay says where, for a second.
    private func confirmOverlay(_ text: String) {
        guard let state = confirmation else { return }
        state.text = text
        scheduleConfirmationDismissal(after: Self.confirmationSeconds)
    }

    private func scheduleConfirmationDismissal(after seconds: TimeInterval) {
        confirmationDismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismissOverlayConfirmation() }
        confirmationDismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Takes the ended overlay down — faded, unless a new one is about to take its place.
    private func dismissOverlayConfirmation(animated: Bool = true) {
        confirmationDismissal?.cancel()
        confirmationDismissal = nil
        confirmation = nil
        guard let panel = confirmationPanel else { return }
        confirmationPanel = nil
        if animated { panel.fadeOutAndClose() } else { panel.close() }
    }

    // MARK: - Hold tip

    /// The shortcut whose letter holds the current hold recording, while it does.
    private var holdTipAction: ShortcutAction?
    private var holdTipStage: HoldTip.Stage = .none
    /// During the last hold recording the modifiers were let go with the letter still
    /// down — the tip was followed. Kept after the recording, for setup's practice step.
    private(set) var holdTipFollowed = false
    private var holdTipTimer: Timer?
    private var holdTipPanel: HoldTipPanel?
    private var holdTipObservers: [Any] = []

    /// A hold recording started: watch whether the modifiers are let go, and show the
    /// tip while the user has yet to learn that they may be.
    private func beginHoldTip(_ action: ShortcutAction, canSwitch: Bool) {
        endHoldTip()
        holdTipAction = action
        holdTipFollowed = false
        let count = UserDefaults.standard.integer(forKey: SettingsKeys.holdTipFollowedCount)
        // Setup's Try it teaches the same thing on its own screen.
        holdTipStage = dictationTest.isActive ? .none : HoldTip.stage(count: count, canSwitch: canSwitch)
        let keys = shortcutKeys(shortcutText(for: action))
        // Scheduled on the main run loop, so it fires on main.
        holdTipTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let action = self.holdTipAction, !self.holdTipFollowed else { return }
                if modifiersOfHeldShortcutLetGo(keys: keys, letterDown: HeldShortcuts.shared.down.contains(action)) {
                    self.holdTipFollowed = true
                    dlog("Hotkey", "hold: modifiers let go, \(action.title) still held")
                    self.refreshHoldTipPanel()
                }
            }
        }
        guard holdTipStage != .none else { return }
        // Not for a tap: a lone tap cancels, and a tip that flashed up for it would be noise.
        DispatchQueue.main.asyncAfter(deadline: .now() + DictationHotkeyGesture.tapThreshold) { [weak self] in
            guard let self, self.holdTipAction == action, self.holdTipPanel == nil else { return }
            self.showHoldTipPanel()
        }
        dlog("Hotkey", "hold tip: \(holdTipStage), count \(count)")
    }

    private func showHoldTipPanel() {
        guard let overlay = overlayPanel else { return }
        let panel = HoldTipPanel()
        holdTipPanel = panel
        refreshHoldTipPanel()
        panel.place(beside: overlay.frame)
        panel.orderFrontRegardless()
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            holdTipObservers.append(center.addObserver(forName: name, object: overlay, queue: .main) { [weak self, weak overlay] _ in
                MainActor.assumeIsolated {
                    guard let overlay else { return }
                    self?.holdTipPanel?.place(beside: overlay.frame)
                }
            })
        }
    }

    private func refreshHoldTipPanel() {
        guard let panel = holdTipPanel, let action = holdTipAction else { return }
        let other: ShortcutAction? = switch action {
        case .inline: .ai
        case .ai: .inline
        case .edit, .recordWindow: nil
        }
        panel.contentView = NSHostingView(rootView: HoldTipView(action: action, stage: holdTipStage,
                                                                other: other, followed: holdTipFollowed))
    }

    /// The hold is over, however it ended: the tip goes, and a followed tip counts.
    private func endHoldTip() {
        guard holdTipAction != nil else { return }
        holdTipTimer?.invalidate()
        holdTipTimer = nil
        for observer in holdTipObservers { NotificationCenter.default.removeObserver(observer) }
        holdTipObservers = []
        holdTipPanel?.close()
        holdTipPanel = nil
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: SettingsKeys.holdTipFollowedCount)
        let next = HoldTip.count(after: count, stage: holdTipStage, followed: holdTipFollowed)
        if next != count { defaults.set(next, forKey: SettingsKeys.holdTipFollowedCount) }
        holdTipAction = nil
        holdTipStage = .none
    }

    // MARK: - No connection

    /// A dictation that could not be transcribed for want of a network. Its audio is in
    /// History, so the notice says where it is instead of reading like a loss, and offers
    /// the retry. Stays up longer than a notice with nothing to act on.
    private func showSavedOffline(_ recordID: UUID) {
        // Every dictation this outage saved, the one just stopped included.
        let waiting = max(OfflineRetry.shared.pendingCount, 1)
        showStatus(
            icon: "wifi.slash",
            title: "No connection — saved to History",
            detail: waiting == 1
                ? "It will be transcribed once you're back online."
                : "\(waiting) dictations will be transcribed once you're back online.",
            tint: .orange,
            duration: 15,
            action: StatusOverlayAction(title: "Retry") { [weak self] in
                self?.retrySavedOffline(recordID)
            }
        )
    }

    private func retrySavedOffline(_ recordID: UUID) {
        showStatus(icon: "arrow.clockwise", title: "Retrying…", detail: nil, tint: .secondary,
                   duration: STTTuning.batchResourceTimeoutSeconds)
        Task { @MainActor [weak self] in
            let result = await HistoryRetry.shared.retry(recordID)
            self?.reportRetry(result, recordID: recordID)
        }
    }

    /// What a retry of a saved recording came to. A result stays in History — never pasted
    /// into an app, where the user may by now be typing something else entirely, and never
    /// put on the clipboard over whatever they copied meanwhile.
    private func reportRetry(_ result: HistoryRetry.Result, recordID: UUID) {
        switch result {
        case .succeeded:
            showStatus(icon: "checkmark.circle", title: "Transcribed — not pasted",
                       detail: "It's in History, ready to copy.", tint: Semantic.confirmation, duration: 8,
                       action: StatusOverlayAction(title: "Show") { [weak self] in
                           self?.openNotPasted()
                       }, historyPlace: HomeRecentEntry.notPasted)
        case .offline:
            showSavedOffline(recordID)
        case .failed(let error):
            showStatus(icon: "exclamationmark.triangle.fill", title: "Retry failed",
                       detail: friendlySTTError(error), tint: .orange)
        case .alreadyRunning:
            hideStatus()
        }
    }

    /// Dictations saved offline, once the network came back and a retry went through them:
    /// how many are waiting in History, unpasted. One notice for the whole outage, whose
    /// Show opens History on them. Nothing is pasted or copied — the user decides where each
    /// one goes, and the app each was meant for is on its row.
    func showNotPastedOnceOnline(transcribed: Int, failed: Int) {
        let total = transcribed + failed
        // The title sits beside Show, so it stays short; "back online" goes in the detail.
        let title = total == 1 ? "1 dictation not pasted" : "\(total) dictations not pasted"
        let detail: String
        if failed == 0 {
            detail = "Back online — transcribed, waiting in History."
        } else if transcribed == 0 {
            detail = "Back online, but couldn't transcribe — retry in History."
        } else {
            detail = "Back online — \(transcribed) transcribed, \(failed) couldn't be. All in History."
        }
        showStatus(icon: "tray.full", title: title, detail: detail,
                   tint: failed == 0 ? Semantic.confirmation : .orange, duration: 15,
                   action: StatusOverlayAction(title: "Show") { [weak self] in
                       self?.openNotPasted()
                   }, historyPlace: HomeRecentEntry.notPasted)
    }

    /// History, narrowed to the dictations that reached no app.
    private func openNotPasted() {
        hideStatus()
        openHistoryWindow(narrowedTo: HomeRecentEntry.notPasted)
    }

    // MARK: - Model lifecycle

    /// The next notice the model lifecycle owes (`pendingModelNotice`): a model the launch
    /// moved off one its vendor is retiring, or a newer one on offer. One per dictation,
    /// each once; not during setup's Try it.
    private func showModelNoticeOnce() {
        guard !isTestDictation else { return }
        let defaults = UserDefaults.standard
        let shown = defaults.stringArray(forKey: SettingsKeys.modelNoticesShown) ?? []
        guard let notice = pendingModelNotice(inUse: ModelSettingsInUse(defaults),
                                              stored: { defaults.string(forKey: $0) },
                                              migrations: storedModelMigrations(in: defaults),
                                              shown: Set(shown)) else { return }
        dlog("App", "model notice: \(notice.id)")
        defaults.set(shown + [notice.id], forKey: SettingsKeys.modelNoticesShown)
        show(notice, tint: .secondary)
    }

    private func show(_ notice: ModelNotice, detail: String? = nil, tint: Color = .orange) {
        showStatus(icon: "cpu", title: notice.title, detail: detail ?? notice.detail, tint: tint, duration: 10,
                   action: StatusOverlayAction(title: notice.actionTitle) { [weak self] in
                       self?.perform(notice.action)
                   })
    }

    private func perform(_ action: ModelNotice.Action) {
        hideStatus()
        switch action {
        case .openSettings(let role):
            NotificationCenter.default.post(name: .openSettingsPage,
                                            object: role == .speech ? SettingsCategory.speech : SettingsCategory.ai)
        case .switchModel(let key, let id):
            dlog("App", "model notice: \(key) switched to \(id)")
            UserDefaults.standard.set(id, forKey: key)
        }
    }

    // MARK: - Microphone

    /// The first time Automatic records from the Mac's microphone instead of Bluetooth
    /// headphones, a notice says so and where to change it — then never again. Not
    /// during setup's Try it, whose own screen is what the user is reading.
    private func showMicrophoneNoticeOnce(_ resolution: MicrophoneResolution) {
        let defaults = UserDefaults.standard
        guard !isTestDictation, !defaults.bool(forKey: SettingsKeys.microphoneNoticeShown),
              let device = resolution.device, let avoided = resolution.avoided else { return }
        defaults.set(true, forKey: SettingsKeys.microphoneNoticeShown)
        showStatus(icon: "mic", title: "Recording with \(device.name)",
                   detail: "So \(avoided.name) keeps playing at full quality.",
                   tint: .secondary, duration: 8,
                   action: StatusOverlayAction(title: "Change") {
                       NotificationCenter.default.post(name: .openSettingsPage, object: SettingsCategory.dictation)
                   })
    }

    // MARK: - Status Overlay

    /// `historyPlace`: what a click on the notice narrows History to, as History's row names it.
    /// A notice's way to Accessibility: the pane and the helper, never macOS's alert.
    static let allowAccessibilityAction = StatusOverlayAction(title: "Turn On…") {
        SystemSettingsGuide.accessibility.start { _ in }
    }

    func showStatus(icon: String, title: String, detail: String?, tint: Color, duration: TimeInterval = 5,
                    action: StatusOverlayAction? = nil, historyPlace: String? = nil) {
        hideStatus()

        let panel = StatusOverlayPanel()
        panel.contentView = NSHostingView(rootView: StatusOverlayView(
            icon: icon,
            title: title,
            detail: detail,
            tint: tint,
            action: action,
            onTap: { [weak self] in
                self?.hideStatus()
                self?.openHistoryWindow(narrowedTo: historyPlace)
            }
        ))
        panel.place(beside: (overlayPanel ?? confirmationPanel).flatMap { $0.isVisible ? $0.frame : nil })
        panel.orderFrontRegardless()
        statusPanel = panel

        let dismiss = DispatchWorkItem { [weak self, weak panel] in
            guard let self, self.statusPanel === panel else { return }
            self.hideStatus()
        }
        statusDismissItem = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismiss)
    }

    func openHistoryWindow(narrowedTo place: String? = nil) {
        NotificationCenter.default.post(name: .openHistoryWindow, object: place)
    }

    func hideStatus() {
        statusDismissItem?.cancel()
        statusDismissItem = nil
        statusPanel?.close()
        statusPanel = nil
    }

    /// Turn a raw provider error into something that tells the user what to actually do.
    private func friendlySTTError(_ raw: String) -> String {
        if raw.contains("413") || raw.localizedCaseInsensitiveContains("too large") {
            return "That recording was too large for the provider. Try a shorter one."
        }
        if raw.contains("429") {
            return "Rate limited by the provider. Wait a moment and retry from History."
        }
        if raw.contains("401") || raw.contains("403") {
            return "The API key was rejected. Check it in Settings."
        }
        if raw.localizedCaseInsensitiveContains("timed out") || raw.contains("-1001") {
            return "The request timed out. Retry from History."
        }
        if raw.localizedCaseInsensitiveContains("offline") || raw.contains("-1009") {
            return "No internet connection. Retry from History once you're back online."
        }
        return raw
    }

    func toggleOrShowDirectRecordingPanel() {
        // Mid-edit the Record Window would take over `previousApp` from under the edit.
        if isEditMode {
            dlog("Hotkey", "record window pressed during an edit → cancel the edit")
            cancelEdit(.otherShortcut)
            return
        }
        if directRecordingPanel != nil {
            toggleDirectRecordingState()
        } else {
            showDirectRecordingPanel()
        }
    }

    func toggleDirectRecordingState() {
        guard let engine = directRecordingSpeechEngine else { return }
        // The panel's knob is disabled meanwhile, and the shortcut is the same knob: a
        // resume while a paused segment was still uploading cancelled the upload, and
        // the segment was gone — no text in the panel, no History row.
        guard !engine.isTranscribing, !engine.isStartingEngine else {
            dlog("Hotkey", "record window pressed while its engine is busy → ignored")
            return
        }
        let locale = resolvedLocale()
        let spring = Animation.spring(response: 0.35, dampingFraction: 0.75)
        if engine.isRecording {
            withAnimation(spring) { engine.pauseRecording() }
        } else if engine.isPaused {
            withAnimation(spring) { engine.resumeRecording(locale: locale) }
        } else {
            withAnimation(spring) { engine.startRecording(locale: locale) }
        }
    }

    /// Opens the Record Window — with `text`, a dictation that could not be pasted, and
    /// no recording; without, recording at once. One already open is never replaced: what
    /// was dictated or typed there lives only in it, and a recording may be running.
    /// `text` is added after what it holds, and it comes forward.
    func showDirectRecordingPanel(withText text: String? = nil) {
        if let panel = directRecordingPanel {
            if let text {
                dlog("App", "record window already open — \(text.count) chars added after its text")
                appendToDirectRecordingPanel(text)
            } else {
                dlog("App", "record window already open — brought forward")
            }
            panel.orderFrontRegardless()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Save the app the user was in before opening the panel
        if text == nil {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
                previousApp = front
            }
        }

        let engine = SpeechEngine()
        engine.onSavedOffline = { id in MainActor.assumeIsolated { OfflineRetry.shared.enqueue(id) } }
        if let text {
            engine.editedText = text
        }
        directRecordingSpeechEngine = engine
        let insertion = TextInsertionHandler()
        directRecordingInsertion = insertion

        let panel = DirectRecordingPanelWindow()
        let hostingView = NSHostingView(rootView: DirectRecordingPanelView(
            speechEngine: engine,
            appState: self,
            insertionHandler: insertion,
            autoStartRecording: text == nil,
            onDismiss: { [weak self] in
                self?.hideDirectRecordingPanel()
            }
        ))
        panel.contentView = hostingView
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        directRecordingPanel = panel

        // Silent save on close: stop recording / let transcription finish, but don't paste
        directRecordingCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, self.directRecordingPanel === panel else { return }
                self.releaseDirectRecordingEngine()
                self.removeDirectRecordingCloseObserver()
                self.directRecordingPanel = nil
                self.directRecordingInsertion = nil
            }
        }
    }

    /// Adds `text` after what the open Record Window holds, spaced as its own segments
    /// are, as one undoable step.
    private func appendToDirectRecordingPanel(_ text: String) {
        guard !text.isEmpty, directRecordingInsertion?.append(text) == nil,
              let engine = directRecordingSpeechEngine else { return }
        // No text view to insert into yet: the text the editor will be built from.
        let existing = engine.editedText
        let gap = existing.last.map { !$0.isWhitespace } == true ? " " : ""
        engine.editedText = existing + gap + text
    }

    private func hideDirectRecordingPanel() {
        releaseDirectRecordingEngine()
        removeDirectRecordingCloseObserver()
        if let panel = directRecordingPanel {
            panel.close()
        }
        directRecordingPanel = nil
        directRecordingInsertion = nil
    }

    /// Lets the Record Window's engine finish what it is doing and forgets it: a live
    /// recording is stopped (its text is written to History, nothing is pasted), a
    /// transcription in flight is left to land, and an engine still *starting* is
    /// cancelled — it has no result to wait for, and forgetting it mid-start left the
    /// tap running into a session nobody would ever finish.
    private func releaseDirectRecordingEngine() {
        if let engine = directRecordingSpeechEngine {
            if engine.isRecording || engine.isPaused {
                engine.stopRecording()
            } else if engine.isStartingEngine {
                engine.cancelRecording()
            }
        }
        directRecordingSpeechEngine = nil
    }

    private func removeDirectRecordingCloseObserver() {
        if let observer = directRecordingCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            directRecordingCloseObserver = nil
        }
    }
}

/// Where an ended dictation's text went, once the paste says — nil while it is on its way.
@MainActor @Observable
final class OverlayConfirmation {
    var text: String?
}

/// The overlay once its dictation or edit has ended: no longer the engine's, so nothing on
/// it moves but the comet until the paste, then the line saying where the text went.
struct ConfirmationOverlay: View {
    let state: OverlayConfirmation
    let layout: OverlayLayout
    let barLevels: [CGFloat]
    let isAIMode: Bool
    let isEditMode: Bool
    let settledText: String
    let onTranscriptHeight: (CGFloat) -> Void
    let onCancel: () -> Void

    var body: some View {
        RecordingOverlayView(
            barLevels: barLevels,
            isLoading: state.text == nil,
            isPreparing: false,
            isAIMode: isAIMode,
            isEditMode: isEditMode,
            showsTranscript: true,
            growsDown: layout.growsDown,
            transcriptHeight: layout.transcriptHeight,
            settledText: settledText,
            confirmation: state.text,
            onTranscriptHeight: onTranscriptHeight,
            onCancel: onCancel
        )
    }
}

/// A wrapper view that observes the SpeechEngine to update the waveform overlay
struct ObservedOverlay: View {
    @Bindable var speechEngine: SpeechEngine
    @Bindable var appState: AppState
    let layout: OverlayLayout
    let onTranscriptHeight: (CGFloat) -> Void
    let onCancel: () -> Void

    var body: some View {
        RecordingOverlayView(
            barLevels: speechEngine.barLevels,
            isLoading: speechEngine.isTranscribing || appState.isRefining,
            isPreparing: speechEngine.isStartingEngine,
            isAIMode: appState.isAIMode,
            isEditMode: appState.isEditMode,
            showsTranscript: appState.showsLiveTranscript,
            growsDown: layout.growsDown,
            transcriptHeight: layout.transcriptHeight,
            settledText: appState.showsLiveTranscript ? speechEngine.spanLayer.stableText : "",
            movingText: appState.showsLiveTranscript ? speechEngine.spanLayer.segmentProvisionalText : "",
            onTranscriptHeight: onTranscriptHeight,
            onCancel: onCancel
        )
    }
}
