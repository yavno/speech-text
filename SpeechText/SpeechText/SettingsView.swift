// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import ServiceManagement
import AppKit
import AVFoundation
import Carbon
import SpeechTextCore

/// The Settings window's content: a category sidebar and the page it picks, inside the
/// setup window's frame. The parts are in SettingsWindow.swift.
struct SettingsView: View {
    let window: SetupWindowRef
    @State private var category: SettingsCategory

    init(window: SetupWindowRef, category: SettingsCategory = .general) {
        self.window = window
        _category = State(initialValue: category)
    }

    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = STTProviderType.apple.rawValue
    @AppStorage(SettingsKeys.removeDisfluencies) private var removeDisfluencies = true
    @AppStorage(SettingsKeys.dashStyle) private var dashStyle = DashStyle.default.rawValue

    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = LLMProviderType.groq.rawValue
    @AppStorage(SettingsKeys.localLLMModel) private var localLLMModel = Provider.local.defaultChatModel

    /// The API keys are not in UserDefaults (see `APIKeyStore`), so they are bound to the
    /// store rather than through `@AppStorage`; the store is observable, so the fields and
    /// the ready/needs-a-key statuses follow every edit.
    private var keys: APIKeyStore { APIKeyStore.shared }

    private func keyBinding(_ name: String) -> Binding<String> {
        Binding(get: { APIKeyStore.shared.value(for: name) },
                set: { APIKeyStore.shared.set($0, for: name) })
    }

    @AppStorage(SettingsKeys.holdToTalk) private var holdToTalk = false
    @AppStorage(SettingsKeys.escapeCancelsDictation) private var escapeCancelsDictation = false

    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.default.rawValue
    @AppStorage(SettingsKeys.accentColor) private var accentHex = AccentColor.neutral
    @AppStorage(SettingsKeys.technoPhosphor) private var technoRaw = TechnoPhosphor.green.rawValue
    @AppStorage(SettingsKeys.dockIconMode) private var dockIconRaw = DockIconMode.default.rawValue
    @AppStorage(SettingsKeys.homeIntroHidden) private var homeIntroHidden = false
    @AppStorage(SettingsKeys.promptsIntroHidden) private var promptsIntroHidden = false
    @AppStorage(SettingsKeys.historyRetention) private var historyRetentionRaw = HistoryRetention.default.rawValue
    @AppStorage(SettingsKeys.failedAudioRetention) private var audioRetentionRaw = HistoryRetention.defaultAudio.rawValue
    /// A shorter choice waiting for the user to agree to what it deletes.
    @State private var pendingRetention: PendingRetention?
    /// History's size on disk, read when the page opens and whenever the count changes.
    @State private var historyBytes: Int64 = 0

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    // Sparkle keeps this in its own defaults key, so it is read from the updater rather
    // than through @AppStorage.
    @State private var checksForUpdates = false
    // Read when the window opens and whenever the app comes back to the front — the user
    // grants both in System Settings, outside the app.
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityGranted = PasteService.isAccessibilityGranted

    // MARK: - Resolved selections
    //
    // Everything below reads through these instead of the raw strings, so a stored
    // value that no longer maps to a case can never leave a picker showing blank.

    private var stt: STTProviderType {
        STTProviderType(rawValue: sttProvider) ?? .apple
    }

    private var llm: LLMProviderType {
        LLMProviderType(rawValue: llmProvider) ?? .groq
    }

    /// The AI page is violet inside the card, as the setup window's AI step is; the
    /// frame's glow stays green.
    private var tint: SetupTint { category == .ai ? .violet : .green }

    var body: some View {
        SetupFrame {
            let card = RoundedRectangle(cornerRadius: 18, style: .continuous)
            HStack(spacing: 0) {
                SettingsSidebar(selection: $category, window: window)
                    .frame(width: Self.sidebarWidth)
                Rectangle().fill(SetupColor.separator).frame(width: 1)
                page
                    .frame(width: Self.pageWidth)
                    .frame(maxHeight: .infinity)
                    .environment(\.setupTint, tint)
                    .tint(tint.accent)
            }
            .background(card.fill(SettingsColor.background))
            .overlay(card.strokeBorder(SetupColor.cardRim, lineWidth: 0.5))
            .clipShape(card)
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
        }
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            checksForUpdates = UpdateChecker.shared.checksAutomatically
            refreshPermissions()
            // A value left behind by a removed engine would render the picker blank.
            normalizeStoredProviders()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        // The main window asked for a page while the window was already open.
        .onReceive(NotificationCenter.default.publisher(for: .settingsShowCategory)) { note in
            if let asked = note.object as? SettingsCategory { category = asked }
        }
    }

    // MARK: - Page

    private static let sidebarWidth: CGFloat = 196
    /// The window, less the frame's rim, the sidebar and the hairline beside it.
    private static let pageWidth = SettingsWindow.size.width - 16 - sidebarWidth - 1

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(category.title).setupTitle(26)
                Text(category.lead).setupLead(13)
            }
            .frame(width: Self.pageWidth - 56, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 18)

            // A vertical ScrollView takes its width from its content, so the content is
            // given the page's width outright; otherwise a long caption widens the page
            // past the window.
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        content
                    }
                    .frame(width: Self.pageWidth - 56, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
                // A new page starts at its top, not where the last one was scrolled to —
                // unless another window linked to a group further down.
                .id(category)
                .onAppear { scrollToPendingAnchor(scroller) }
                // Settings already open on another page: the link turns it first.
                .onChange(of: category) { scrollToPendingAnchor(scroller) }
                .onReceive(NotificationCenter.default.publisher(for: .settingsScrollToAnchor)) { _ in
                    scrollToPendingAnchor(scroller)
                }
            }
        }
    }

    /// Scrolls to the group a link asked for, once its page is the one showing; a page still
    /// to appear takes it in its own `onAppear`.
    private func scrollToPendingAnchor(_ scroller: ScrollViewProxy) {
        guard let anchor = SettingsAnchor.pending, anchor.category == category else { return }
        SettingsAnchor.pending = nil
        // A turn later, once the page has been laid out.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { scroller.scrollTo(anchor, anchor: .top) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch category {
        case .general: generalPage
        case .appearance: appearancePage
        case .dictation: dictationPage
        case .speech: speechPage
        case .ai: aiPage
        case .privacy: privacyPage
        case .apiKeys: apiKeysPage
        }
    }

    // MARK: - General

    @ViewBuilder
    private var generalPage: some View {
        SettingsGroup(title: "Startup") {
            SettingsRow(title: "Launch at login",
                        detail: launchAtLogin
                            ? "SpeechText starts when you log in, so the shortcuts always work."
                            : "Open SpeechText yourself after you log in — until then the shortcuts do nothing.") {
                SettingsSwitch(isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        guard newValue != (SMAppService.mainApp.status == .enabled) else { return }
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            SettingsDivider()
            SettingsRow(title: "Show in Dock", detail: "Also puts SpeechText in ⌘Tab, so a covered window can be found.") {
                Picker("Show in Dock", selection: $dockIconRaw) {
                    ForEach(DockIconMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: dockIconRaw) { _, _ in
                    NotificationCenter.default.post(name: .dockIconModeDidChange, object: nil)
                }
            }
        }

        SettingsGroup(title: UpdateChecker.shared.isConfigured ? "Updates" : "About") {
            // Absent in a build with no signing key, where the updater never starts.
            if UpdateChecker.shared.isConfigured {
                SettingsRow(title: "Check for updates automatically",
                            detail: checksForUpdates
                                ? "Once a day. Nothing is installed until you agree."
                                : "Only when you click Check Now.") {
                    SettingsSwitch(isOn: $checksForUpdates)
                        .onChange(of: checksForUpdates) { _, newValue in
                            UpdateChecker.shared.checksAutomatically = newValue
                        }
                }
                SettingsDivider()
            }
            VersionRow()
            SettingsDivider()
            // The licences the bundled third-party code requires to travel with every copy
            // (scripts/third-party-notices.sh); opened in the system's text viewer.
            SettingsRow(title: "Acknowledgements",
                        detail: "The open-source code SpeechText is built on, and its licences.") {
                if let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
                    Button("Show") { NSWorkspace.shared.open(notices) }
                        .buttonStyle(SetupButtonStyle(kind: .secondary, height: 28))
                }
            }
        }
    }

    // MARK: - History

    /// A shorter choice for one of the two scales, and how much it would delete.
    private struct PendingRetention {
        let audio: Bool
        let choice: HistoryRetention
        let count: Int
    }

    private var historyRetention: HistoryRetention { HistoryRetention.stored(historyRetentionRaw) }
    private var audioRetention: HistoryRetention { HistoryRetention.stored(audioRetentionRaw, default: .defaultAudio) }

    /// How long History keeps dictations, and the audio of a failed one. A choice that
    /// would delete what is already kept asks first, as Messages does — it cannot be
    /// brought back.
    private var historyGroup: some View {
        let records = TranscriptionHistory.shared.records
        let stored = HistoryFormat.storageSummary(count: records.count, since: records.last?.date, bytes: historyBytes)
        return SettingsGroup(title: "History", trailing: AnyView(
            Text(stored)
                .font(.system(size: 11.5))
                .foregroundStyle(SetupColor.label2)
                .monospacedDigit())) {
            retentionRow(title: "Dictations", detail: historyRetentionDetail, selection: historyRetention) { choice in
                let count = TranscriptionHistory.shared.droppedCount(under: choice)
                if count > 0 {
                    pendingRetention = PendingRetention(audio: false, choice: choice, count: count)
                } else {
                    historyRetentionRaw = choice.rawValue
                }
            }
            SettingsDivider()
            retentionRow(title: "Audio of failed dictations", detail: audioRetentionDetail, selection: audioRetention) { choice in
                let count = TranscriptionHistory.shared.droppedAudioCount(under: choice)
                if count > 0 {
                    pendingRetention = PendingRetention(audio: true, choice: choice, count: count)
                } else {
                    audioRetentionRaw = choice.rawValue
                }
            }
        }
        .id(SettingsAnchor.history)
        .task(id: TranscriptionHistory.shared.records.count) {
            historyBytes = TranscriptionHistory.shared.diskBytes()
        }
        .confirmationDialog(pendingRetention.map(retentionQuestion) ?? "",
                            isPresented: Binding(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } })) {
            Button("Delete", role: .destructive) {
                if let pending = pendingRetention {
                    if pending.audio {
                        audioRetentionRaw = pending.choice.rawValue
                    } else {
                        historyRetentionRaw = pending.choice.rawValue
                    }
                    TranscriptionHistory.shared.applyRetention()
                }
                pendingRetention = nil
            }
            Button("Cancel", role: .cancel) { pendingRetention = nil }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func retentionRow(title: String, detail: String, selection: HistoryRetention,
                              choose: @escaping (HistoryRetention) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SetupColor.label)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SetupColor.label2)
            }
            SettingsStepSlider(values: HistoryRetention.allCases, selection: selection, title: \.title,
                               label: title, onChoose: choose)
        }
        .padding(.vertical, 14)
    }

    private func retentionQuestion(_ pending: PendingRetention) -> String {
        let count = HomeFormat.integer(pending.count)
        if pending.audio {
            return pending.count == 1 ? "Delete the audio of 1 failed dictation?" : "Delete the audio of \(count) failed dictations?"
        }
        return pending.count == 1 ? "Delete 1 dictation?" : "Delete \(count) dictations?"
    }

    private var historyRetentionDetail: String {
        switch historyRetention {
        case .session: "Kept until SpeechText quits. Home and Usage count only this session."
        case .forever: "Kept on this Mac until you delete them."
        default: "Older ones are deleted from this Mac."
        }
    }

    private var audioRetentionDetail: String {
        if audioRetention.outlasts(historyRetention) {
            return "Kept for a retry, and deleted with its dictation."
        }
        return audioRetention == .session
            ? "Kept for a retry until SpeechText quits."
            : "Kept so a dictation that failed can be retried."
    }

    // MARK: - Appearance

    private var skin: AppSkin { AppSkin(rawValue: skinRaw) ?? .default }

    @ViewBuilder
    private var appearancePage: some View {
        SettingsGroup(title: "Style", inset: 5) {
            ForEach(AppSkin.allCases) { option in
                SettingsPreviewRow(title: option.displayName, detail: option.detail, isSelected: skin == option) {
                    guard skinRaw != option.rawValue else { return }
                    skinRaw = option.rawValue
                    NotificationCenter.default.post(name: .skinDidChange, object: nil)
                } preview: {
                    SkinPreview(skin: option, accentHex: accentHex, technoRaw: technoRaw)
                }
            }
        }

        SettingsGroup(title: "Colour") {
            if skin.supportsAccent {
                SettingsRow(title: "Accent",
                            detail: AccentColor.isNeutral(accentHex)
                                ? "Default — ink on glass, with a red record button."
                                : "Tints the level meter and the record button.") {
                    HStack(spacing: 8) {
                        ForEach(AccentColor.presets, id: \.hex) { preset in
                            swatch(preset)
                        }
                        ColorPicker(
                            "Colour",
                            selection: Binding(
                                get: { AccentColor.meter(accentHex) },
                                set: { accentHex = AccentColor.hex(from: $0) }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        .help("Any colour")
                    }
                }
            } else {
                SettingsRow(title: "Display", detail: technoColorDetail) {
                    HStack(spacing: 8) {
                        ForEach(TechnoPhosphor.allCases) { option in
                            phosphorSwatch(option, selected: option == selectedPhosphor)
                        }
                        ColorPicker(
                            "Colour",
                            selection: Binding(
                                get: { TechnoPalette(stored: technoRaw).phosphor },
                                set: { technoRaw = AccentColor.hex(from: $0) }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        .help("Any colour — the glass and the shell follow its hue")
                    }
                }
            }
        }

        // The cards that explain a page, for anyone who has learnt it: shown or hidden
        // only here, so a card closed by mistake is never gone for good.
        SettingsGroup(title: "Main window") {
            SettingsRow(title: "Shortcut card on Home",
                        detail: "The card at the top of Home that plays each shortcut — Dictate, AI Rewrite and Edit.") {
                SettingsSwitch(isOn: Binding(get: { !homeIntroHidden }, set: { homeIntroHidden = !$0 }))
            }
            SettingsDivider()
            SettingsRow(title: "How AI Rewrite picks a prompt",
                        detail: "The card at the top of the Prompts page, with examples of what you say and the prompt it fits.") {
                SettingsSwitch(isOn: Binding(get: { !promptsIntroHidden }, set: { promptsIntroHidden = !$0 }))
            }
        }
    }

    /// The recommended set the stored value names; nil for a colour of the user's own.
    /// A value that is neither reads as green, as the display does.
    private var selectedPhosphor: TechnoPhosphor? {
        if let preset = TechnoPhosphor(rawValue: technoRaw) { return preset }
        return TechnoPhosphor.customHex(technoRaw) == nil ? .green : nil
    }

    private var technoColorDetail: String {
        if let hex = TechnoPhosphor.customHex(technoRaw) {
            return TechnoPalette.isCloseToAI(hex)
                ? "Close to AI mode's violet — a plain dictation will be hard to tell from an AI one."
                : "Your colour, on glass of the same hue. AI mode stays violet."
        }
        switch selectedPhosphor {
        case .green, nil: return "Default — the green of the design."
        case let preset?: return "\(preset.displayName) dots and text on matching glass. AI mode stays violet."
        }
    }

    /// A display colour as the glass would show it: a lit dot on its own screen.
    private func phosphorSwatch(_ option: TechnoPhosphor, selected: Bool) -> some View {
        Button {
            technoRaw = option.rawValue
        } label: {
            Circle().fill(option.palette.screen)
                .overlay(Circle().fill(option.palette.phosphor).padding(4))
                .frame(width: 18, height: 18)
                .overlay {
                    Circle().strokeBorder(
                        selected ? AnyShapeStyle(SetupTint.green.accent) : AnyShapeStyle(SetupColor.label3),
                        lineWidth: selected ? 2 : 1
                    )
                }
        }
        .buttonStyle(.plain)
        .help(option.displayName)
    }

    private func swatch(_ preset: (name: String, hex: String)) -> some View {
        let selected = accentHex.caseInsensitiveCompare(preset.hex) == .orderedSame
        return Button {
            accentHex = preset.hex
        } label: {
            Group {
                // The neutral swatch shows the glass itself, because
                // that is literally what choosing it gets you.
                if AccentColor.isNeutral(preset.hex) {
                    Circle().fill(.ultraThinMaterial)
                } else {
                    Circle().fill(AccentColor.color(from: preset.hex))
                }
            }
            .frame(width: 18, height: 18)
            .overlay {
                Circle().strokeBorder(
                    selected ? AnyShapeStyle(SetupTint.green.accent) : AnyShapeStyle(SetupColor.label3),
                    lineWidth: selected ? 2 : 1
                )
            }
        }
        .buttonStyle(.plain)
        .help(preset.name)
    }

    // MARK: - Speech to text

    /// The page's own state — which place is open, which service is opened for its key —
    /// lives in the view, so it starts from what is in use each time the page opens.
    private var speechPage: some View {
        SpeechEngineSettings()
    }

    // MARK: - Dictation

    /// How a dictation is given — the shortcuts, the microphone, the languages — and how
    /// its text is written, which applies to AI Rewrite's output too.
    @ViewBuilder
    private var dictationPage: some View {
        shortcutGroups

        SettingsGroup(title: "Microphone") {
            MicrophoneField()
        }
        .id(SettingsAnchor.microphone)

        SettingsGroup(title: "Language") {
            SpokenLanguagesField(stt: stt)
        }

        SettingsGroup(title: "Text") {
            SettingsRow(title: "Remove hesitation sounds",
                        detail: removeDisfluencies
                            ? "Drops “um”, “е-е-е” and the like, stretched letters (“тооо”) and a trailing “...”. Filler words such as “ну” are kept — AI Rewrite removes those."
                            : "Transcripts are pasted as the engine wrote them, “um” and “е-е-е” included.") {
                SettingsSwitch(isOn: $removeDisfluencies)
            }
            SettingsDivider()
            SettingsRow(title: "Dashes",
                        detail: "How the long dash speech models write is drawn, in dictations and AI output alike.") {
                Picker("Dashes", selection: $dashStyle) {
                    ForEach(DashStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: - AI

    @ViewBuilder
    private var aiPage: some View {
        AIEngineSettings()

        SettingsGroup(title: "Prompts") {
            SettingsRow(title: "Prompts",
                        detail: "What a dictation can become. The model picks the one that fits.") {
                Button("Edit Prompts…") { openPresets() }
                    .buttonStyle(SetupButtonStyle(kind: .secondary, height: 28))
            }
        }
    }

    // MARK: - API Keys

    /// Every key the app can use, in pipeline order (speech first). The ones the current
    /// choices use come first, marked with whether they are filled in; the rest stay
    /// below, so a key can be entered before the engine that needs it is picked.
    @ViewBuilder
    private var apiKeysPage: some View {
        let keys = apiKeys
        let inUse = keys.filter { !$0.active.isEmpty }
        let others = keys.filter { $0.active.isEmpty }
        SettingsGroup(title: "In use") {
            if inUse.isEmpty {
                SettingsRow(title: "Nothing to enter", detail: "Everything you've selected runs on this Mac.")
            } else {
                ForEach(inUse.indices, id: \.self) { index in
                    if index > 0 { SettingsDivider() }
                    inUse[index].field(inUse: true)
                }
            }
        }
        if !others.isEmpty {
            SettingsGroup(title: "Other keys") {
                ForEach(others.indices, id: \.self) { index in
                    if index > 0 { SettingsDivider() }
                    others[index].field(inUse: false)
                }
            }
        }
    }

    private struct APIKey {
        let service: Provider
        let value: Binding<String>
        /// Everything the key can be used for.
        let roles: [SettingsKeyRole]
        /// The roles the current choices use it for; empty when nothing does.
        let active: Set<SettingsKeyRole>

        /// The tags say what the key does; a caption is left for the one case they
        /// don't spell out — a single key serving both steps at once.
        var uses: String? {
            active.count > 1 ? "One key, used for both." : nil
        }

        func field(inUse: Bool) -> SettingsKeyField {
            SettingsKeyField(service: service, value: value, roles: roles, activeRoles: active,
                             uses: uses, inUse: inUse)
        }
    }

    /// Every provider with a key, speech before AI Rewrite (`APIKeyPage.order`). A key is
    /// in use for the step whose pick that provider serves — the selected engine, not where
    /// its uploads go, so Apple's engine does not mark Groq's key.
    private var apiKeys: [APIKey] {
        APIKeyPage.order.compactMap { provider in
            guard let key = provider.descriptor.apiKey else { return nil }
            let roles = provider.descriptor.roles
            var active: Set<SettingsKeyRole> = []
            if stt.vendor == provider { active.insert(.speech) }
            if llm.vendor == provider { active.insert(.aiRewrite) }
            return APIKey(service: provider, value: keyBinding(key.settingsKey),
                          roles: (roles.contains(.speech) ? [.speech] : []) + (roles.contains(.chat) ? [.aiRewrite] : []),
                          active: active)
        }
    }

    // MARK: - Shortcuts (on the General page)

    @ViewBuilder
    private var shortcutGroups: some View {
        SettingsGroup(title: "Shortcuts") {
            ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { SettingsDivider() }
                HotkeyRecorderView(action: action, detail: shortcutDetail(action))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SetupColor.label)
                    .buttonStyle(SetupButtonStyle(kind: .secondary, height: 28))
                    .padding(.vertical, 9)
            }
        }
        SettingsNote("Click a shortcut, then press the new key combination.")
            .padding(.horizontal, 4)
            .padding(.top, -12)

        SettingsGroup(title: "Recording") {
            RecordingModePicker(holdToTalk: $holdToTalk, shortcut: shortcutKeys(shortcutText(for: .inline)))
                .padding(.top, 12)
            GestureDemoList(holdToTalk: holdToTalk, showsSwitch: hasLLMKey)
                .padding(.vertical, 12)
            SettingsDivider()
            SettingsRow(title: "Esc cancels a dictation",
                        detail: escapeCancelsDictation
                            ? "While the overlay is up, Esc cancels the dictation — and reaches no other app until it is gone."
                            : "Esc works in your apps as usual. To cancel a dictation, click ✕ on the overlay.") {
                SettingsSwitch(isOn: $escapeCancelsDictation)
            }
        }
    }

    /// The one thing about the Edit shortcut its name does not say.
    private func shortcutDetail(_ action: ShortcutAction) -> String? {
        action == .edit ? "Double-press to just polish it." : nil
    }

    // MARK: - Privacy & Data

    @AppStorage(SettingsKeys.sendVocabularyToEngine) private var sendVocabulary = true

    /// Where a dictation's audio goes with the engine in use — said from the settings,
    /// never assumed, since this group is the disclosure.
    private var speechSentDetail: String {
        switch stt {
        case .apple:
            // Apple's recogniser cannot take an archived file, so History retries it
            // through the stored Groq model (`batchUpload: .selectedModel(of: .groq)`).
            let groqKey = Provider.groq.descriptor.apiKey.map { !APIKeyStore.shared.value(for: $0.settingsKey).isEmpty } ?? false
            return "Stays on this Mac: Apple Dictation runs on-device."
                + (groqKey ? " A retry from History is sent to Groq, since Apple can't transcribe a saved recording." : "")
        case .local:
            return "Stays on this Mac. A model is downloaded once; after that nothing goes online."
        case .groq, .elevenlabs, .openai:
            let vendor = stt.vendor.displayName
            let words = sendVocabulary ? ", with your Dictionary's words where the model takes them" : ""
            return "Each recording is sent to \(vendor) to be transcribed\(words). A retry from History sends it again."
        }
    }

    /// Where AI Rewrite's text goes, and what is sent with it.
    private var aiSentDetail: String {
        let context = "With it go your Dictionary's words and the app, window title and field the text is for — a window title can show an email subject. Password managers and password fields are never read."
        guard hasLLMKey else { return "AI Rewrite is off, so nothing is sent." }
        if llm == .local {
            return "Stays on this Mac. A model is downloaded once; after that nothing goes online."
        }
        return "AI dictations and edits are sent to \(llm.vendor.displayName). " + context
    }

    /// What is kept on this Mac, what leaves it, and what macOS allows.
    @ViewBuilder
    private var privacyPage: some View {
        historyGroup

        SettingsGroup(title: "What leaves this Mac") {
            SettingsRow(title: "Your voice", detail: speechSentDetail)
            SettingsDivider()
            SettingsRow(title: "Your text", detail: aiSentDetail)
        }

        SettingsGroup(title: "Permissions") {
            SettingsPermissionRow(symbol: "mic", title: "Microphone", detail: micDetail,
                                  granted: micStatus == .authorized) {
                if micStatus == .notDetermined {
                    Button("Allow") {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            DispatchQueue.main.async { refreshPermissions() }
                        }
                    }
                    .buttonStyle(SetupLinkButtonStyle(height: 28))
                } else if micStatus == .denied {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                    .buttonStyle(SetupLinkButtonStyle(height: 28))
                }
            }
            SettingsDivider()
            SettingsPermissionRow(symbol: "keyboard", title: "Accessibility",
                                  detail: accessibilityGranted
                                      ? "So your words appear where your cursor is."
                                      : "Without it your text opens in the Record Window, ready to copy.",
                                  granted: accessibilityGranted) {
                Button("Grant Access") { PasteService.promptAccessibility() }
                    .buttonStyle(SetupLinkButtonStyle(height: 28))
            }
        }
    }

    private var micDetail: String {
        switch micStatus {
        case .denied: "Microphone is turned off for SpeechText."
        case .restricted: "Your Mac's settings don't allow microphone use. Ask whoever manages this Mac."
        default: "So SpeechText can hear you."
        }
    }

    private func refreshPermissions() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = PasteService.isAccessibilityGranted
    }

    // MARK: - Helpers

    /// Mirrors `LLMConfiguration.isConfigured`, but off the observed store and
    /// `@AppStorage`, so the status updates live while the key is being typed or a model
    /// is picked.
    private var hasLLMKey: Bool {
        _ = (llmProvider, localLLMModel)
        let value = llm.vendor.descriptor.apiKey.map { keys.value(for: $0.settingsKey) }
            ?? LLMConfiguration.model(for: llm)
        return !value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The prompts are a page of the main window now.
    private func openPresets() {
        NotificationCenter.default.post(name: .openMainWindowPage, object: MainPage.prompts.rawValue)
    }

}



// MARK: - Microphone

/// Which microphone a dictation records from, and a caption saying what that comes to
/// right now — Automatic's whole point is a substitution the user would not otherwise see.
private struct MicrophoneField: View {
    @AppStorage(SettingsKeys.microphone) private var stored = ""
    @AppStorage(SettingsKeys.microphoneName) private var storedName = ""
    @State private var monitor = AudioInputMonitor()

    private var choice: MicrophoneChoice { MicrophoneChoice(stored: stored) }

    private var resolution: MicrophoneResolution {
        MicrophoneResolution.resolve(choice, devices: monitor.devices, defaultUID: monitor.defaultUID)
    }

    private var systemDevice: AudioInputDevice? {
        monitor.devices.first { $0.uid == monitor.defaultUID }
    }

    /// The device actually recording under the current choice.
    private var inUse: AudioInputDevice? { resolution.device ?? systemDevice }

    var body: some View {
        SettingsRow(title: "Microphone", detail: caption) {
            Picker("Microphone", selection: selection) {
                Text("Automatic").tag(MicrophoneChoice.automatic.stored)
                Text("System Default").tag(MicrophoneChoice.systemDefault.stored)
                Divider()
                ForEach(monitor.devices) { device in
                    Text(device.name).tag(device.uid)
                }
                // A picked device that is not connected keeps its row, so the picker
                // never renders blank.
                if case .device(let uid) = choice, !monitor.devices.contains(where: { $0.uid == uid }) {
                    Text("\(storedName.isEmpty ? "Microphone" : storedName) (not connected)").tag(uid)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var selection: Binding<String> {
        Binding(get: { stored }, set: { value in
            stored = value
            if let device = monitor.devices.first(where: { $0.uid == value }) {
                storedName = device.name
            }
        })
    }

    private var caption: String {
        let now = inUse.map { "Now: \($0.name)." } ?? "No microphone is connected."
        switch choice {
        case .automatic:
            if let avoided = resolution.avoided {
                return "\(now) Used instead of \(avoided.name), so they keep playing at full quality."
            }
            if systemDevice?.transport == .bluetooth {
                return "\(now) With the lid closed, these headphones drop to call quality while you dictate."
            }
            return "\(now) Bluetooth headphones are skipped for the Mac's own microphone, so they keep playing."
        case .systemDefault:
            return "\(now) As set in System Settings › Sound."
        case .device:
            if resolution.pickedIsMissing {
                return "Not connected — Automatic decides until it is. \(now)"
            }
            if resolution.device?.transport == .bluetooth {
                return "These headphones drop to call quality while you dictate."
            }
            return now
        }
    }
}

// MARK: - Spoken languages

/// "Languages I speak": the stated languages as chips, in the user's order — the order
/// Apple's recogniser falls back to — with Add for the rest, and a caption that says what
/// the list does with the engine in use.
///
/// The caption is not decoration. Naming one language forces it on every engine; naming
/// several cannot be passed to most providers (their APIs take one language), so it only
/// narrows the guess Apple has to make — except GPT Live Transcribe, which takes the set.
private struct SpokenLanguagesField: View {
    @AppStorage(SettingsKeys.spokenLanguages) private var stored = ""
    @AppStorage(SettingsKeys.openAISTTModel) private var openAISTTModel = Provider.openAI.defaultSpeechModel
    // Every engine's stored model, so the warning below follows a pick on any of them.
    @AppStorage(SettingsKeys.localSTTModel) private var localSTTModelID = Provider.local.defaultSpeechModel
    @AppStorage(SettingsKeys.groqModel) private var groqModel = Provider.groq.defaultSpeechModel
    @AppStorage(SettingsKeys.elevenLabsModel) private var elevenLabsModel = Provider.elevenLabs.defaultSpeechModel
    let stt: STTProviderType
    @State private var adding = false

    private var selected: [String] { parseSpokenLanguages(stored) }

    /// The one engine that takes a *set* rather than a single language, so the only one
    /// where naming several changes what is sent — see `OpenAIRealtimeTranscriber`.
    private var narrowsToTheSet: Bool {
        stt == .openai && openAISTTModel == openAIRealtimeSTTModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Languages I speak")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SetupColor.label)
                Text(caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SetupColor.label2)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning = modelWarning {
                    // Where a language is added, the user is not thinking of the engine.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("⚠︎ " + warning)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(SetupColor.warn)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Choose another model…") {
                            NotificationCenter.default.post(name: .settingsShowCategory, object: SettingsCategory.speech)
                        }
                        .buttonStyle(SetupInlineLinkStyle())
                    }
                    .padding(.top, 4)
                }
            }
            FlowLayout(spacing: 6) {
                if selected.isEmpty {
                    LanguageChip(title: "Any language", symbol: "globe", placeholder: true)
                }
                ForEach(selected, id: \.self) { code in
                    LanguageChip(title: spokenLanguage(id: code)?.displayName ?? code,
                                 remove: { stored = encodeSpokenLanguages(selected.filter { $0 != code }) })
                        .draggable(code)
                        .dropDestination(for: String.self) { codes, _ in
                            // Only a chip of ours: text dragged in from another app is not a language.
                            guard let moved = codes.first, moved != code, selected.contains(moved) else { return false }
                            move(moved, before: code)
                            return true
                        }
                        .help(selected.count > 1 ? "Drag to reorder" : "")
                }
                Button { adding = true } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(SetupTint.green.accent)
                .popover(isPresented: $adding, arrowEdge: .bottom) {
                    LanguagePicker(selected: selected) { code in
                        // Appended: the user's own order is what `resolveLocale` falls
                        // back to when the keyboard layout matches none of them.
                        stored = encodeSpokenLanguages(selected + [code])
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func move(_ code: String, before target: String) {
        var codes = selected.filter { $0 != code }
        let index = codes.firstIndex(of: target) ?? codes.endIndex
        codes.insert(code, at: index)
        stored = encodeSpokenLanguages(codes)
    }

    /// The language Apple's recogniser will be given, by name.
    private var appleLanguage: String {
        let locale = resolvedLocale()
        return HistoryFormat.language(locale) ?? locale
    }

    /// The selected speech model by name and what it knows — nil for a choice the launch
    /// cleared, which waits for a pick and so warns about nothing.
    private var selectedModel: (name: String, languages: LanguageCoverage)? {
        switch stt {
        case .apple:
            return ("Apple Dictation", sttModel(vendor: .apple, id: appleSpeechModelID).languages)
        case .local:
            return localSTTModel(id: localSTTModelID).map { (speechModelName($0), $0.languages) }
        case .groq, .elevenlabs, .openai:
            let id = switch stt {
            case .groq: groqModel
            case .elevenlabs: elevenLabsModel
            default: openAISTTModel
            }
            guard id != clearedModelChoice else { return nil }
            let model = sttModel(vendor: stt.vendor, id: id)
            return (onlineSpeechModelName(model), model.languages)
        }
    }

    /// "Phonon-2 can't take Ukrainian." while the selected model lacks a listed language.
    private var modelWarning: String? {
        selectedModel.flatMap {
            spokenLanguagesWarning(modelName: $0.name, spoken: selected, coverage: $0.languages,
                                   onDevice: AppleOnDeviceLanguages.supports)
        }
    }

    private var caption: String {
        switch selected.count {
        case 0:
            return stt == .apple
                ? "Apple can't detect a language, so your keyboard layout picks one — now \(appleLanguage)."
                : "Detected every time from what you say."
        case 1:
            let name = spokenLanguage(id: selected[0])?.displayName ?? selected[0]
            return "Always transcribed as \(name) — the most accurate. Speech in another language may come back translated."
        default:
            if narrowsToTheSet {
                return "GPT Live Transcribe picks among these."
            }
            return stt == .apple
                ? "Your keyboard layout picks one of these, else the first — now \(appleLanguage)."
                : "Detected every time: this engine can't be limited to a list. Keep one to force it."
        }
    }
}

/// One stated language — or, with none stated, what that means.
private struct LanguageChip: View {
    let title: String
    var symbol: String?
    var placeholder = false
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
            Text(title).font(.system(size: 12.5, weight: .semibold))
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(SetupColor.label.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("Remove \(title)")
            }
        }
        .foregroundStyle(placeholder ? SetupColor.label2 : SetupColor.label)
        .padding(.leading, 11)
        .padding(.trailing, remove == nil ? 11 : 5)
        .frame(height: 26)
        .background {
            if placeholder {
                Capsule().strokeBorder(SetupColor.label3, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            } else {
                Capsule().fill(SetupColor.control)
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
            }
        }
        .fixedSize()
    }
}

/// Add's popover: a search field over the languages not stated yet, the ones this Mac
/// has a keyboard for first.
private struct LanguagePicker: View {
    let selected: [String]
    let add: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var available: [SpokenLanguage] {
        spokenLanguageCatalog.filter { !selected.contains($0.id) }
    }

    private var matches: [SpokenLanguage] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return available }
        return available.filter {
            $0.displayName.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
                || $0.id.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    var body: some View {
        let keyboards = keyboardLanguageCodes()
        let suggested = matches.filter { keyboards.contains($0.id) }
        let rest = matches.filter { !keyboards.contains($0.id) }
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search languages", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
                .onSubmit { if let first = suggested.first ?? rest.first { pick(first) } }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !suggested.isEmpty {
                        section("On your keyboards")
                        ForEach(suggested) { row($0) }
                    }
                    if !rest.isEmpty {
                        if !suggested.isEmpty { section("All languages") }
                        ForEach(rest) { row($0) }
                    }
                    if suggested.isEmpty && rest.isEmpty {
                        Text("No match")
                            .font(.system(size: 12))
                            .foregroundStyle(SetupColor.label2)
                            .padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 240, height: 300)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SetupColor.label2)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(_ language: SpokenLanguage) -> some View {
        LanguagePickerRow(title: language.displayName) { pick(language) }
    }

    private func pick(_ language: SpokenLanguage) {
        add(language.id)
        dismiss()
    }
}

private struct LanguagePickerRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(SetupColor.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? SettingsColor.panel : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
    }
}

/// The languages of the keyboards enabled on this Mac, as ISO 639-1 codes.
private func keyboardLanguageCodes() -> Set<String> {
    let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                  kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
    var codes = Set<String>()
    for source in list {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { continue }
        let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String] ?? []
        if let first = languages.first {
            codes.insert(String(first.prefix { $0 != "-" && $0 != "_" }))
        }
    }
    return codes
}

/// Settings › Recording: how a dictation shortcut records, as two segments side by side —
/// press it to start and again to paste, or hold it while speaking — each named and drawn
/// with the user's own shortcut. Stored as `holdToTalk`.
private struct RecordingModePicker: View {
    @Binding var holdToTalk: Bool
    let shortcut: [String]

    var body: some View {
        HStack(spacing: 4) {
            segment(hold: false, title: "Press to toggle", caption: "press again to paste")
            segment(hold: true, title: "Hold to talk", caption: "hold while you speak")
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(SetupColor.separator.opacity(0.55)))
    }

    private func segment(hold: Bool, title: String, caption: String) -> some View {
        let selected = holdToTalk == hold
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { holdToTalk = hold }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? SetupColor.label : SetupColor.label2)
                HStack(spacing: 6) {
                    SetupKeycaps(keys: shortcut, size: 17, litKeys: selected ? Set(shortcut.indices) : [])
                    Text(caption)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SetupColor.label2)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SettingsColor.background)
                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(shortcut.joined()), \(caption)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Settings › Recording: each gesture of the chosen mode played on a loop, the way System
/// Settings shows a trackpad gesture — the user's own keys going down one after another
/// and what the dictation does — beside its name (`HoldTip.demoFrame`). With hold to
/// talk: the hold, whose modifiers may be let go once the letter is down, the double tap
/// of the letter that locks it on, and the switch while the letter is held. Without: a
/// press to start and one to paste, and the switch by the other shortcut. The switch is
/// left out while AI Rewrite has no provider: the AI shortcut is then a second dictation
/// shortcut (`AppState.effectiveKey`), with nothing to switch to. Indented behind a rule,
/// so the gestures read as part of the mode rather than as settings of their own.
private struct GestureDemoList: View {
    let holdToTalk: Bool
    let showsSwitch: Bool
    @State private var windowVisible = true

    private struct Demo {
        let gesture: HoldTip.DemoGesture
        let title: String
        let detail: String
    }

    var body: some View {
        let inline = shortcutKeys(shortcutText(for: .inline))
        let ai = shortcutKeys(shortcutText(for: .ai))
        let modifiers = inline.filter(isModifierCap)
        let aiModifiers = ai.filter(isModifierCap)
        let shared = modifiers == aiModifiers
        let layout = HoldTip.DemoLayout(modifiers: modifiers.count, otherModifiers: aiModifiers.count,
                                        sharesModifiers: shared)
        let switchKeys = shared ? inline + [ai.last ?? ""] : inline + ai
        let demos = demos(letter: inline.last ?? "", modifiers: modifiers.joined(), inline: inline.joined(), ai: ai.joined())
        let gestures = demos.map(\.gesture)
        // The demos move in steps, so they are redrawn only when a step changes — at 30
        // frames a second the whole Settings page was laid out again each frame, about 40%
        // of a core.
        TimelineView(DemoSchedule(paused: !windowVisible) { time in
            gestures.map { HoldTip.demoFrame($0, layout: layout, at: time) }
        }) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                ForEach(Array(demos.enumerated()), id: \.offset) { index, demo in
                    let frame = HoldTip.demoFrame(demo.gesture, layout: layout, at: time)
                    if index > 0 { SettingsDivider().gridCellColumns(3) }
                    row(keys: demo.gesture.usesOtherShortcut ? switchKeys : inline, frame: frame,
                        ai: demo.gesture.usesOtherShortcut && frame.state == .ai,
                        title: demo.title, detail: demo.detail)
                }
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Capsule().fill(SetupColor.separator).frame(width: 2)
        }
        .background(WindowVisibilityReader(isVisible: $windowVisible))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(demos.map { "\($0.title). \($0.detail)" }.joined(separator: " "))
    }

    private func demos(letter: String, modifiers: String, inline: String, ai: String) -> [Demo] {
        var demos: [Demo]
        if holdToTalk {
            demos = [
                Demo(gesture: .hold, title: "Hold to record",
                     detail: modifiers.isEmpty
                        ? "It records while \(letter) is down. Let go of \(letter) to paste."
                        : "Once it records, let go of \(modifiers) — \(letter) alone keeps it going. Let go of \(letter) to paste."),
                Demo(gesture: .lock, title: "Double-tap to lock",
                     detail: (modifiers.isEmpty ? "Tap \(letter) twice" : "Hold \(modifiers) and tap \(letter) twice")
                        + ": it records with nothing held, until you press \(inline) again."),
            ]
            if showsSwitch {
                demos.append(Demo(gesture: .holdSwitch, title: "Switch to AI Rewrite",
                                  detail: "While holding \(letter), press \(ai) to switch to AI Rewrite, and again to switch back. Started with \(ai), \(inline) switches the other way."))
            }
        } else {
            demos = [
                Demo(gesture: .toggle, title: "Press to start, again to paste",
                     detail: "Press \(inline) and let go — it records with nothing held. Press \(inline) again to paste."),
            ]
            if showsSwitch {
                demos.append(Demo(gesture: .toggleSwitch, title: "Switch to AI Rewrite",
                                  detail: "While it records, press \(ai) to switch to AI Rewrite and \(inline) to switch back. Started with \(ai), it works the other way round."))
            }
        }
        return demos
    }

    private func row(keys: [String], frame: HoldTip.DemoFrame, ai: Bool, title: String, detail: String) -> some View {
        GridRow(alignment: .center) {
            SetupKeycaps(keys: keys, size: 22,
                         litKeys: frame.caps.indexes(of: .down), fadedKeys: frame.caps.indexes(of: .notNeeded),
                         ringKeys: frame.ringed, ai: ai)
            DemoStatus(state: frame.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SetupColor.label)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SetupColor.label2)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            // On the cell, not the row: a modified GridRow stops being a row.
            .padding(.vertical, 8)
        }
    }
}

/// A timeline for a demo drawn in steps: it looks at the demo's frame every 1/30 s, as an
/// animation schedule would, but gives SwiftUI a date only when the frame changes. While
/// paused it gives the start and nothing more.
private struct DemoSchedule<Frame: Equatable>: TimelineSchedule {
    let paused: Bool
    let frame: (TimeInterval) -> Frame

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(time: startDate.timeIntervalSinceReferenceDate, paused: paused, frame: frame)
    }

    struct Entries: Sequence, IteratorProtocol {
        var time: TimeInterval
        let paused: Bool
        let frame: (TimeInterval) -> Frame
        var shown: Frame?

        mutating func next() -> Date? {
            guard let last = shown else {
                shown = frame(time)
                return Date(timeIntervalSinceReferenceDate: time)
            }
            if paused { return nil }
            // A minute without a change is no demo; give SwiftUI a date anyway.
            for _ in 0..<1800 {
                time += 1 / 30
                let next = frame(time)
                if next != last {
                    shown = next
                    break
                }
            }
            return Date(timeIntervalSinceReferenceDate: time)
        }
    }
}

/// What a gesture demo's dictation is doing, as a small tag beside its keys; empty, with
/// its place kept, while nothing is.
private struct DemoStatus: View {
    let state: HoldTip.DemoState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let green = scheme == .dark ? SetupColor.phosphor : SetupColor.brand
        let (symbol, title, tint): (String, String, Color) = switch state {
        case .idle, .recording: ("mic.fill", "Recording", green)
        case .locked: ("lock.fill", "Locked on", green)
        case .ai: ("sparkles", "AI Rewrite", SetupColor.ai)
        case .pasted: ("checkmark", "Pasted", SetupColor.label2)
        }
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(title)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(tint.opacity(0.13)))
        .opacity(state == .idle ? 0 : 1)
        .frame(width: 86, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: state)
    }
}

/// Settings › General › Version: the build in one line, copied when clicked — shown here
/// and in About SpeechText since the status menu stopped showing it, and the line a
/// bug report wants.
private struct VersionRow: View {
    @State private var copied = false
    @State private var resetCopied: DispatchWorkItem?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Version")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SetupColor.label)
                Button(action: copy) {
                    HStack(spacing: 5) {
                        Text(AppVersion.displayString)
                        // Both glyphs stay laid out, one hidden: they are
                        // different heights, and swapping them moved the row.
                        ZStack {
                            Image(systemName: "doc.on.doc").opacity(copied ? 0 : 1)
                            Image(systemName: "checkmark").opacity(copied ? 1 : 0)
                        }
                        .font(.system(size: 10, weight: .medium))
                        if copied { Text("Copied") }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(SetupColor.label2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Copy this build's version")
            }
            Spacer(minLength: 12)
            if UpdateChecker.shared.isConfigured {
                Button("Check Now…") { UpdateChecker.shared.checkForUpdates() }
                    .buttonStyle(SetupButtonStyle(kind: .secondary, height: 28))
            }
        }
        .padding(.vertical, 11)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("SpeechText \(AppVersion.displayString)", forType: .string)
        copied = true
        resetCopied?.cancel()
        let reset = DispatchWorkItem { copied = false }
        resetCopied = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
    }
}
