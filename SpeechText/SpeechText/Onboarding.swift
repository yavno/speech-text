// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement
import SpeechTextCore

// MARK: - The Try it step's sink

/// Where a dictation made from setup's Try it step ends up. `AppState` writes the result
/// here instead of pasting it — the app never pastes into its own windows, and the test's
/// point is to show the user their words, not to type them somewhere.
@Observable
final class DictationTest {
    enum Outcome: Equatable {
        case typed(String)
        case nothingHeard
        case failed(String)
    }

    enum Rewrite: Equatable {
        case wrote(said: String, text: String)
        case failed(said: String, reason: String)
    }

    /// The Try it step is on screen.
    var isActive = false
    /// The speech model is not ready yet: the shortcuts do nothing rather than start a
    /// recording that can only fail.
    var isBlocked = false
    private(set) var outcome: Outcome?
    private(set) var rewrite: Rewrite?

    func began(ai: Bool) {
        rewrite = nil
        if !ai { outcome = nil }
    }

    func finished(_ result: Outcome, ai: Bool) {
        if ai {
            let reason: String
            switch result {
            case .typed(let text):
                rewrite = .wrote(said: text, text: text)
                return
            case .nothingHeard: reason = "We didn't hear anything."
            case .failed(let message): reason = message
            }
            rewrite = .failed(said: "", reason: reason)
        } else {
            outcome = result
        }
    }

    func rewritten(said: String, result: Result<String, Error>) {
        switch result {
        case .success(let text): rewrite = .wrote(said: said, text: text)
        case .failure(let error): rewrite = .failed(said: said, reason: error.localizedDescription)
        }
        // An AI dictation is also a dictation that worked.
        if outcome == nil || outcome == .nothingHeard { outcome = .typed(said) }
    }

    func reset() {
        outcome = nil
        rewrite = nil
    }

    /// Try again after an AI dictation failed: back to the AI shortcut's offer, with the
    /// plain dictation that worked kept.
    func resetRewrite() {
        rewrite = nil
    }
}

// MARK: - Model

/// Everything the setup window decides and does. Choices live here until a step's
/// Continue writes them, so switching between the two answers keeps what was entered in
/// each, and nothing half-chosen reaches the app.
@Observable
@MainActor
final class OnboardingModel {
    enum SpeechPath { case local, online }
    enum AIPath { case none, local, online }

    enum KeyStatus: Equatable {
        case empty
        /// "Get your key" was clicked; the clipboard is read when the app comes back.
        case waiting
        case found
        case checking
        case valid
        case invalid
        /// Couldn't ask — offline or the service is down. The user may go on.
        case offline

        var isUsable: Bool { self == .valid || self == .offline }
        var isLocked: Bool { [.found, .checking, .valid, .offline].contains(self) }
    }

    struct KeyEntry: Equatable {
        var value = ""
        var status = KeyStatus.empty
    }

    enum AccessibilityChoice { case idle, waiting, skipped }

    let appState: AppState
    let store = LocalModelStore.shared
    let chatStore = LocalChatStore.shared
    let capabilities: SystemCapabilities

    var step: OnboardingStep {
        didSet { stepChanged() }
    }

    // ① Welcome — the languages are written as they change, as Settings writes them: the
    // Speech step's rows and recommendation read them at once.
    var spokenLanguages: [String] {
        didSet {
            guard spokenLanguages != oldValue else { return }
            UserDefaults.standard.set(encodeSpokenLanguages(spokenLanguages), forKey: SettingsKeys.spokenLanguages)
            dlog("Setup", "spoken languages: \(spokenLanguages.count)")
            // The recommendation follows the languages until the user picks a model.
            if !speechModelChosen, let recommended = recommendedSpeechModel { speechModelID = recommended.id }
        }
    }

    // ② Speech
    var speechPath = SpeechPath.local
    var speechModelID: String
    /// A model the user picked, or one an earlier run of setup stored: a language added
    /// afterwards no longer moves the pick to the recommended model.
    private var speechModelChosen = false
    /// On this Mac, Apple Dictation rather than a downloaded model: nothing to download,
    /// and `speechModelID` keeps the model a switch back would pick.
    var speechUsesApple = false
    var speechService = Provider.groq
    /// A model picked while another was still downloading, waiting for "Switch".
    var pendingSpeechSwitch: String?

    // ③ AI
    var aiPath = AIPath.none
    var aiService = Provider.groq
    var aiModelID: String

    // Keys
    private(set) var keys: [Provider: KeyEntry] = [:]
    private var awaitingKey: Provider?
    private var checks: [Provider: Task<Void, Never>] = [:]

    // ④ Permissions
    private(set) var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private(set) var accessibilityGranted = AXIsProcessTrusted()
    var accessibilityChoice = AccessibilityChoice.idle
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// macOS Dictation, read only while Apple Dictation is the engine — the one engine
    /// that is that recogniser and fails without it (kLSRErrorDomain 201).
    private(set) var dictationOn = true
    /// Bumped when a permission turns on, so its row can glow once.
    private(set) var justGranted: (row: String, count: Int) = ("", 0)
    private var accessibilityPoll: Timer?
    private var helper: AccessibilityHelperPanel?

    /// When the local speech model was downloaded from this window, so the task pill and
    /// the Try it step follow that one.
    private(set) var speechDownloadID: String?
    private(set) var aiDownloadID: String?

    private var observers: [NSObjectProtocol] = []

    init(appState: AppState) {
        self.appState = appState
        let defaults = UserDefaults.standard
        let caps = SystemCapabilities.current()
        capabilities = caps
        // A new install learns the shortcuts held: Try it opens on Hold to talk. Only
        // when nothing is stored — a choice made before stays, and an install that never
        // saw setup keeps the app's own default.
        if defaults.object(forKey: SettingsKeys.holdToTalk) == nil {
            defaults.set(true, forKey: SettingsKeys.holdToTalk)
        }
        let saved = defaults.string(forKey: SettingsKeys.onboardingStep).flatMap(OnboardingStep.init) ?? .welcome
        step = saved == .done ? .tryIt : saved

        let spoken = storedSpokenLanguages()
        spokenLanguages = spoken
        speechModelID = recommendedLocalSTTModel(for: caps, languages: spoken)?.id
            ?? Provider.local.defaultSpeechModel
        aiModelID = recommendedLocalChatModel(for: caps)?.id ?? Provider.local.defaultChatModel

        // Setup run again: open on what is set up now.
        let storedEngine = STTProviderType(rawValue: defaults.string(forKey: SettingsKeys.sttProvider) ?? "")
        if let engine = storedEngine, let card = SetupCards.speechCard(reopening: engine) {
            speechPath = .online
            speechService = card.service
        } else if storedEngine == .local,
                  let stored = defaults.string(forKey: SettingsKeys.localSTTModel), localSTTModel(id: stored) != nil {
            speechModelID = stored
            speechModelChosen = true
        } else if storedEngine == .apple {
            speechUsesApple = true
        }

        // The AI step, likewise — but only a pick that works: `llmProvider` reads as Groq
        // when nothing was stored, and a Groq card with no key is no choice at all.
        if LLMConfiguration.isConfigured {
            let pick = LLMConfiguration.providerType
            if let card = SetupCards.aiCard(reopening: pick) {
                aiPath = .online
                aiService = card.service
            } else if pick == .local {
                aiPath = .local
                aiModelID = LLMConfiguration.model(for: .local)
            }
        }

        for service in Provider.allCases {
            guard let apiKey = service.descriptor.apiKey else { continue }
            let stored = APIKeyStore.shared.value(for: apiKey.settingsKey).trimmingCharacters(in: .whitespacesAndNewlines)
            keys[service] = KeyEntry(value: stored, status: stored.isEmpty ? .empty : .valid)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        })
        stepChanged()
    }

    func tearDown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        stopWatchingAccessibility()
        checks.values.forEach { $0.cancel() }
        appState.dictationTest.isActive = false
        appState.dictationTest.isBlocked = false
    }

    // MARK: Navigation

    func go(_ target: OnboardingStep) {
        step = target
    }

    private func stepChanged() {
        let defaults = UserDefaults.standard
        if step == .done {
            // Reaching Done is finishing: closing the window from here should not bring
            // setup back at the next launch.
            defaults.set(true, forKey: SettingsKeys.onboardingCompleted)
            defaults.removeObject(forKey: SettingsKeys.onboardingStep)
        } else if !defaults.bool(forKey: SettingsKeys.onboardingCompleted) {
            defaults.set(step.rawValue, forKey: SettingsKeys.onboardingStep)
        }
        if step == .permissions {
            // On by default, like every install before setup existed — turned on here, on
            // the screen whose switch turns it off, rather than silently at launch.
            if !defaults.bool(forKey: SettingsKeys.hasRegisteredLaunchAtLogin) { setLaunchAtLogin(true) }
            refreshPermissions()
        }
        if step != .tryIt { appState.dictationTest.reset() }
        appState.dictationTest.isActive = step == .tryIt
        refreshTestBlock()
        dlog("Setup", "step: \(step.rawValue)")
    }

    // MARK: ② Speech

    var recommendedSpeechModel: LocalSTTModel? {
        recommendedLocalSTTModel(for: capabilities, languages: spokenLanguages)
    }
    var bestSpeechModel: LocalSTTModel? {
        bestQualityLocalSTTModel(for: capabilities, languages: spokenLanguages)
    }

    /// The model the Continue button would install: the pick, unless a switch is pending.
    var selectedSpeechModel: LocalSTTModel {
        localSTTModel(id: speechModelID) ?? recommendedSpeechModel ?? localSTTModel(id: parakeetV3ModelID)!
    }

    func pickSpeechModel(_ id: String) {
        speechUsesApple = false
        speechModelChosen = true
        if let busy = speechDownloadID, busy != id, case .downloading = store.state(for: busy) {
            pendingSpeechSwitch = id
            return
        }
        pendingSpeechSwitch = nil
        speechModelID = id
    }

    /// Apple Dictation: nothing to download, so nothing pending is switched away from.
    func pickAppleDictation() {
        pendingSpeechSwitch = nil
        speechUsesApple = true
    }

    func confirmSpeechSwitch() {
        guard let id = pendingSpeechSwitch else { return }
        if let busy = speechDownloadID, let model = localSTTModel(id: busy) { store.cancelInstall(model) }
        speechDownloadID = nil
        pendingSpeechSwitch = nil
        speechModelID = id
    }

    var speechPrimaryTitle: String {
        guard speechPath == .local, !speechUsesApple else { return "Continue" }
        switch store.state(for: speechModelID) {
        case .notInstalled: return "Download and continue"
        case .failed: return "Retry and continue"
        default: return "Continue"
        }
    }

    var speechCanContinue: Bool {
        speechPath == .local || key(speechService).status.isUsable
    }

    func continueFromSpeech() {
        let defaults = UserDefaults.standard
        // Accepted, the recommendation included: a language added on going back to
        // Welcome must not move it under a download.
        speechModelChosen = true
        switch speechPath {
        case .local where speechUsesApple:
            defaults.set(STTProviderType.apple.rawValue, forKey: SettingsKeys.sttProvider)
        case .local:
            let model = selectedSpeechModel
            if !store.state(for: model.id).isBusy && !store.isInstalled(model.id) {
                store.install(model)
            }
            speechDownloadID = model.id
            defaults.set(STTProviderType.local.rawValue, forKey: SettingsKeys.sttProvider)
            defaults.set(model.id, forKey: SettingsKeys.localSTTModel)
        case .online:
            saveKey(speechService)
            let card = SetupCards.speech(for: speechService)
            defaults.set(card.engine.rawValue, forKey: SettingsKeys.sttProvider)
            // What the card promises: the words while speaking.
            if let model = card.savedModel, let key = card.service.descriptor.speechModel?.settingsKey {
                defaults.set(model, forKey: key)
            } else if let setting = card.service.descriptor.speechModel, let key = setting.settingsKey,
                      defaults.string(forKey: key) == clearedModelChoice {
                // Setup shows no model picker, so picking the card is the pick: a choice the
                // launch cleared takes the service's default, or Try it is refused.
                defaults.set(setting.defaultID, forKey: key)
            }
        }
        dlog("Setup", "speech: \(speechPath == .online ? speechService.rawValue : speechUsesApple ? "apple" : "local \(speechModelID)")")
        go(.ai)
    }

    // MARK: ③ AI

    /// The service's key was connected on the Speech step, so AI polish is one click
    /// away: a provider that serves both steps has one key for both.
    func keyReadyFromSpeech(_ service: Provider) -> Bool {
        let engine = STTProviderType(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.sttProvider) ?? "")
        return engine?.vendor == service && service.descriptor.roles.contains(.chat)
            && key(service).status.isUsable
    }

    var recommendedAIModel: LocalChatModel? { recommendedLocalChatModel(for: capabilities) }
    var bestAIModel: LocalChatModel? { bestQualityLocalChatModel(for: capabilities) }

    func chooseAIPath(_ path: AIPath) {
        aiPath = path
    }

    var aiPrimaryTitle: String {
        guard aiPath == .local, let chat = localChatModel(id: aiModelID) else { return "Continue" }
        switch chatStore.state(for: chat) {
        case .installed, .downloading, .optimizing: return "Continue"
        case .failed: return "Retry and continue"
        case .notInstalled: return "Download and continue"
        }
    }

    var aiCanContinue: Bool {
        switch aiPath {
        case .none: return false
        case .online: return key(aiService).status.isUsable
        case .local: return localChatModel(id: aiModelID) != nil
        }
    }

    func continueFromAI() {
        let defaults = UserDefaults.standard
        switch aiPath {
        case .none:
            return
        case .online:
            saveKey(aiService)
            defaults.set(SetupCards.ai(for: aiService).pick.rawValue, forKey: SettingsKeys.llmProvider)
            if let setting = aiService.descriptor.chatModel, let key = setting.settingsKey,
               defaults.string(forKey: key) == clearedModelChoice {
                defaults.set(setting.defaultID, forKey: key)
            }
        case .local:
            let id = aiModelID
            if let chat = localChatModel(id: id), !chatStore.state(for: chat).isBusy, !isLocalChatModelInstalled(chat) {
                chatStore.install(chat)
            }
            aiDownloadID = id
            defaults.set(LLMProviderType.local.rawValue, forKey: SettingsKeys.llmProvider)
            defaults.set(id, forKey: SettingsKeys.localLLMModel)
        }
        dlog("Setup", "AI: \(aiPath == .local ? "on this Mac \(aiModelID)" : aiService.rawValue)")
        go(.permissions)
    }

    /// "Skip for now" writes nothing.
    func skipAI() {
        dlog("Setup", "AI skipped")
        go(.permissions)
    }

    // MARK: Keys

    func key(_ service: Provider) -> KeyEntry { keys[service] ?? KeyEntry() }

    /// Opens the vendor's key page and waits for the key to come back on the clipboard.
    func getKey(_ service: Provider) {
        guard let page = service.descriptor.apiKey?.keysPage else { return }
        NSWorkspace.shared.open(page)
        awaitingKey = service
        if !key(service).status.isLocked { keys[service]?.status = .waiting }
    }

    /// The Paste button.
    func pasteKey(_ service: Provider) -> Bool {
        let text = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        setKey(service, text)
        return true
    }

    /// Typing in the field: checked half a second after the last change.
    func typeKey(_ service: Provider, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        keys[service]?.value = trimmed
        if trimmed.isEmpty {
            checks[service]?.cancel()
            keys[service]?.status = .empty
            return
        }
        verify(service, after: 0.5)
    }

    func changeKey(_ service: Provider) {
        checks[service]?.cancel()
        keys[service] = KeyEntry()
    }

    func setKey(_ service: Provider, _ value: String, found: Bool = false) {
        awaitingKey = nil
        keys[service] = KeyEntry(value: value.trimmingCharacters(in: .whitespacesAndNewlines),
                                 status: found ? .found : .checking)
        verify(service, after: found ? 0.7 : 0)
    }

    func verify(_ service: Provider, after delay: TimeInterval = 0) {
        checks[service]?.cancel()
        let value = key(service).value
        guard !value.isEmpty else { keys[service]?.status = .empty; return }
        if delay == 0 { keys[service]?.status = .checking }
        checks[service] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.keys[service]?.status = .checking
            let verdict = await Self.check(service, value)
            guard let self, !Task.isCancelled, self.key(service).value == value else { return }
            self.keys[service]?.status = switch verdict {
            case .valid: .valid
            case .invalid: .invalid
            case .unreachable: .offline
            }
            dlog("Setup", "\(service.displayName) key: \(verdict)")
        }
    }

    private static func check(_ service: Provider, _ key: String) async -> KeyVerdict {
        guard let request = service.verificationRequest(key: key) else { return .unreachable }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return Provider.verdict(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        } catch {
            return .unreachable
        }
    }

    private func saveKey(_ service: Provider) {
        guard let apiKey = service.descriptor.apiKey else { return }
        APIKeyStore.shared.set(key(service).value, for: apiKey.settingsKey)
    }

    /// Back from the browser: the clipboard is read once for a key of the awaited shape.
    private func appBecameActive() {
        if let service = awaitingKey,
           let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           service.looksLikeKey(text), text != key(service).value {
            setKey(service, text, found: true)
        }
        if step == .permissions { refreshPermissions() }
    }

    // MARK: ④ Permissions

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic == .authorized && micStatus != .authorized { flash("mic") }
        micStatus = mic
        let ax = AXIsProcessTrusted()
        if ax && !accessibilityGranted { flash("ax") }
        accessibilityGranted = ax
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let dictation = Self.macDictationIsOn()
        if dictation && !dictationOn && needsMacDictation { flash("dictation") }
        dictationOn = dictation
    }

    /// The Permissions step shows a Dictation row: Apple Dictation is the engine chosen.
    var needsMacDictation: Bool { speechPath == .local && speechUsesApple }

    /// Whether macOS Dictation is on for this account, as System Settings › Keyboard
    /// stores it. A new account has no value until it is turned on, which reads as off.
    static func macDictationIsOn() -> Bool {
        let value = CFPreferencesCopyAppValue("Dictation Enabled" as CFString, "com.apple.assistant.support" as CFString)
        return (value as? Bool) ?? false
    }

    /// System Settings › Keyboard, where Dictation is turned on.
    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    private func flash(_ row: String) {
        justGranted = (row, justGranted.count + 1)
    }

    func allowMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.refreshPermissions()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    /// Accessibility has no system dialog of its own to grant it: the user turns
    /// SpeechText on in System Settings. The prompt goes first so SpeechText is already
    /// in the list; then the pane opens, a helper points at the switch, and the grant is
    /// polled for every second.
    func openAccessibilitySettings() {
        let options = [PasteService.trustedCheckOptionPrompt: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        accessibilityChoice = .waiting
        showHelper()
        startWatchingAccessibility()
    }

    func skipAccessibility() {
        stopWatchingAccessibility()
        accessibilityChoice = .skipped
    }

    private func startWatchingAccessibility() {
        accessibilityPoll?.invalidate()
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.stopWatchingAccessibility()
                self.accessibilityChoice = .idle
                self.refreshPermissions()
                // Back to setup, the next step in view.
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func stopWatchingAccessibility() {
        accessibilityPoll?.invalidate()
        accessibilityPoll = nil
        helper?.close()
        helper = nil
    }

    private func showHelper() {
        helper?.close()
        let panel = AccessibilityHelperPanel { [weak self] in
            // Done: the user says they're finished; setup comes back and re-checks.
            self?.helper?.close()
            self?.helper = nil
            NSApp.activate(ignoringOtherApps: true)
            self?.refreshPermissions()
        }
        helper = panel
        panel.showBesideSystemSettings()
    }

    /// Registered or unregistered on change, not on Continue.
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            dlog("Setup", "login item: \(error.localizedDescription)", level: .error)
        }
        UserDefaults.standard.set(true, forKey: SettingsKeys.hasRegisteredLaunchAtLogin)
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var micGranted: Bool { micStatus == .authorized }

    func continueFromPermissions() {
        guard micGranted else { return }
        if !accessibilityGranted { skipAccessibility() }
        go(.tryIt)
    }

    // MARK: ⑤ Try it

    /// The speech model the app will use, while it is still arriving. Nil once it is
    /// ready — or when the engine is not the local one.
    var pendingSpeechModel: (model: LocalSTTModel, state: LocalModelStore.InstallState)? {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: SettingsKeys.sttProvider) == STTProviderType.local.rawValue,
              let id = defaults.string(forKey: SettingsKeys.localSTTModel),
              let model = localSTTModel(id: id) else { return nil }
        let state = store.state(for: id)
        return state == .installed ? nil : (model, state)
    }

    /// Called by the view whenever the model's state may have moved.
    func refreshTestBlock() {
        appState.dictationTest.isBlocked = step == .tryIt && pendingSpeechModel != nil
    }

    func retrySpeechDownload() {
        guard let model = pendingSpeechModel?.model else { return }
        store.install(model)
        speechDownloadID = model.id
    }

    var aiIsSetUp: Bool { TextRefinementService.isConfigured }

    /// The AI model the app will use, while it is still downloading.
    var pendingAIFraction: Double? {
        guard LLMConfiguration.providerType == .local,
              let chat = localChatModel(id: LLMConfiguration.model(for: .local)),
              case .downloading(let fraction) = chatStore.state(for: chat) else { return nil }
        return fraction
    }

    // MARK: Done

    /// "Start using SpeechText". A model still getting ready is watched after the window
    /// closes, and the app says when dictation can start.
    func finish() {
        UserDefaults.standard.set(true, forKey: SettingsKeys.onboardingCompleted)
        UserDefaults.standard.removeObject(forKey: SettingsKeys.onboardingStep)
        if let pending = pendingSpeechModel, pending.state.isBusy {
            let id = pending.model.id
            let store = store
            let appState = appState
            Task { @MainActor in
                while store.state(for: id).isBusy {
                    try? await Task.sleep(for: .seconds(1))
                }
                guard store.state(for: id) == .installed else { return }
                appState.showStatus(icon: "checkmark.circle.fill", title: "SpeechText is ready",
                                    detail: "Press \(shortcutText(for: .inline)) to dictate.",
                                    tint: Semantic.confirmation, duration: 8)
            }
        }
    }
}

/// A shortcut as the user sees it ("⌃⇧Q") — the stored one, or the built-in.
func shortcutText(for action: ShortcutAction) -> String {
    let stored = action.stored(in: .standard)
    return shortcutDisplayString(keyCode: UInt16(stored.keyCode), modifierFlags: stored.modifiers)
}
