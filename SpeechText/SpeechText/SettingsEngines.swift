// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import SpeechTextCore

// Settings › Speech to text and Settings › AI Rewrite: the same question setup asks —
// on this Mac, or an online service — answered with the same two cards, and under them
// the choices as rows that say what each one is. A row commits a choice only when it can
// work: a service without a key opens for its key instead of being selected, so a tap in
// Settings never leaves the next dictation failing.

/// Where a step runs: on this Mac, or at an online service.
enum EnginePlace: Hashable {
    case thisMac, online
}

/// The two cards at the top of both pages. Which one is open is the page's own state; the
/// card holding what is in use says so.
struct EnginePlaceCards: View {
    @Binding var place: EnginePlace
    let inUse: EnginePlace
    let macFacts: String
    let onlineFacts: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SetupChoiceCard(glyph: .mac, name: "On this Mac", badge: inUse == .thisMac ? "In use" : nil,
                            facts: macFacts, isSelected: place == .thisMac) { place = .thisMac }
            SetupChoiceCard(glyph: .cloud, name: "Online service", badge: inUse == .online ? "In use" : nil,
                            facts: onlineFacts, isSelected: place == .online) { place = .online }
        }
        .padding(4)
    }
}

/// A choice under its service's row — a model, or the key — indented to the row's text.
private struct NestedUnderRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { content }
            .padding(.leading, 30)
            .padding(.trailing, 10)
            .padding(.bottom, 10)
    }
}

private func hasKey(_ service: Provider) -> Bool {
    guard let key = service.descriptor.apiKey else { return true }
    return !APIKeyStore.shared.value(for: key.settingsKey).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func keyBinding(_ service: Provider) -> Binding<String> {
    let name = service.descriptor.apiKey?.settingsKey ?? ""
    return Binding(get: { APIKeyStore.shared.value(for: name) },
                   set: { APIKeyStore.shared.set($0, for: name) })
}

/// "Recommended for your M1 Pro, 32 GB".
func macDescription(_ caps: SystemCapabilities) -> String {
    let chip = caps.chipName.replacingOccurrences(of: "Apple ", with: "")
    return "\(chip), \(Int(caps.memoryGB.rounded())) GB"
}

// The rows' words — every line, and the language notes they carry — are ModelRowWords.swift.

/// The models a page's two badges go to, worked out once a render and handed to each row.
private struct LocalPicks {
    let recommended: String?
    let bestQuality: String?
}

/// A row's "No Spanish" badge, in the warning kind, while the model lacks one of the user's
/// languages — on every row, not only the selected one, since tapping a local row
/// starts a download. Apple's answer is asked of macOS.
@MainActor
func languageBadge(_ coverage: LanguageCoverage, spoken: [String]) -> SetupBadge? {
    missingLanguageBadgeText(spoken: spoken, coverage: coverage, onDevice: AppleOnDeviceLanguages.supports)
        .map { SetupBadge(text: $0, kind: .warn) }
}

// MARK: - Speech to text

struct SpeechEngineSettings: View {
    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = STTProviderType.apple.rawValue
    @AppStorage(SettingsKeys.localSTTModel) private var localModelID = Provider.local.defaultSpeechModel
    // Each service's stored model, observed so the rows follow a pick.
    @AppStorage(SettingsKeys.groqModel) private var groqModel = Provider.groq.defaultSpeechModel
    @AppStorage(SettingsKeys.elevenLabsModel) private var elevenLabsModel = Provider.elevenLabs.defaultSpeechModel
    @AppStorage(SettingsKeys.openAISTTModel) private var openAIModel = Provider.openAI.defaultSpeechModel

    @State private var place: EnginePlace
    /// A service opened for its key without being selected.
    @State private var opened: Provider?
    @State private var store = LocalModelStore.shared
    @State private var capabilities = SystemCapabilities.current()
    /// A model being downloaded to be used: the engine switches to it once it is usable,
    /// never before — a dictation meanwhile would fail.
    @State private var waitingFor: String?
    /// The model in use, about to be removed — asked first.
    @State private var removing: LocalSTTModel?
    @State private var showHeavyModels = false

    init() {
        let stored = STTProviderType(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.sttProvider) ?? "") ?? .apple
        _place = State(initialValue: Self.place(of: stored))
    }

    private static func place(of engine: STTProviderType) -> EnginePlace {
        engine == .apple || engine == .local ? .thisMac : .online
    }

    private var engine: STTProviderType { STTProviderType(rawValue: sttProvider) ?? .apple }

    var body: some View {
        EnginePlaceCards(
            place: $place, inUse: Self.place(of: engine),
            macFacts: capabilities.isAppleSilicon
                ? "Private and free. Your voice stays on your Mac, and works offline."
                : "Private and free, but slow on this Mac.",
            onlineFacts: "Works on any Mac. Needs internet and an account; your recording is sent to the service.")

        switch place {
        case .thisMac: thisMac
        case .online: online
        }
    }

    // MARK: On this Mac

    @AppStorage(SettingsKeys.spokenLanguages) private var spokenLanguages = ""
    private var spoken: [String] { parseSpokenLanguages(spokenLanguages) }
    private var recommended: LocalSTTModel? {
        recommendedLocalSTTModel(for: capabilities, languages: parseSpokenLanguages(spokenLanguages))
    }
    private var bestQuality: LocalSTTModel? {
        bestQualityLocalSTTModel(for: capabilities, languages: parseSpokenLanguages(spokenLanguages))
    }

    private var thisMac: some View {
        SettingsGroup(title: "Models on this Mac", trailing: AnyView(
            Text("For your \(macDescription(capabilities))")
                .font(.system(size: 11.5))
                .foregroundStyle(SetupColor.label2)), inset: 5) {
            // A model this Mac cannot hold waits behind a link, as AI Rewrite's do — unless
            // it is the one in use or on disk, which must stay in sight to be changed or removed.
            let listing = localSTTListing(for: capabilities, languages: spoken) { model in
                (engine == .local && localModelID == model.id) || store.state(for: model.id) != .notInstalled
            }
            let heavy = listing.heavy
            // Once a render, not twice a row: a download renders the page ten times a second.
            let picks = LocalPicks(recommended: recommended?.id, bestQuality: bestQuality?.id)
            ForEach(listing.picks) { localRow($0, picks: picks) }
            SetupRow(title: "Apple Dictation", subtitle: "Built in",
                     languageBadge: languageBadge(sttModel(vendor: .apple, id: appleSpeechModelID).languages, spoken: spoken),
                     detail: appleDictationLine,
                     isSelected: engine == .apple) { sttProvider = STTProviderType.apple.rawValue }
            ForEach(listing.others + listing.lackingLanguage) { localRow($0, picks: picks) }
            if !heavy.isEmpty {
                Button(showHeavyModels ? "Hide models too heavy for this Mac"
                                       : "Show \(heavy.count) \(heavy.count == 1 ? "model" : "models") too heavy for this Mac") {
                    withAnimation(.easeOut(duration: 0.2)) { showHeavyModels.toggle() }
                }
                .buttonStyle(SetupInlineLinkStyle())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                if showHeavyModels { ForEach(heavy) { localRow($0, picks: picks) } }
            }
            HStack {
                Text(store.hasAnyModel
                     ? "\(ByteCountFormatter.string(fromByteCount: store.installedBytes, countStyle: .file)) of models on this Mac"
                     : "No models downloaded yet")
                Spacer()
                if store.hasAnyModel {
                    Button("Show in Finder") {
                        let url = LocalModelStore.modelsDirectory
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(SetupInlineLinkStyle())
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(SetupColor.label2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .onAppear {
            store.refresh()
            capabilities = SystemCapabilities.current()
            AppleOnDeviceLanguages.refresh()
        }
        .onChange(of: waitingIsUsable) { _, usable in
            guard usable, let id = waitingFor else { return }
            waitingFor = nil
            localModelID = id
            sttProvider = STTProviderType.local.rawValue
        }
        // A model picked here is loaded now, not in front of the next dictation's paste.
        .onChange(of: localModelID) { _, id in
            if engine == .local { LocalSTT.prewarm(id) }
        }
        .onChange(of: sttProvider) { _, _ in
            if engine == .local { LocalSTT.prewarm(localModelID) }
        }
        .confirmationDialog("Remove \(removing.map(speechModelName) ?? "")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let model = removing { remove(model) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("It is the model in use. Dictation switches to \(fallbackName) until you pick another.")
        }
    }

    private var waitingIsUsable: Bool {
        waitingFor.map { store.state(for: $0).isUsable } ?? false
    }

    /// What a removed model in use gives way to: another one on this Mac, else Apple's.
    private var fallback: LocalSTTModel? {
        localSTTModels.first { $0.id != removing?.id && store.state(for: $0.id).isUsable }
    }

    private var fallbackName: String { fallback.map(speechModelName) ?? "Apple Dictation" }

    private func remove(_ model: LocalSTTModel) {
        let inUse = engine == .local && localModelID == model.id
        let next = fallback
        store.remove(model)
        guard inUse else { return }
        if let next {
            localModelID = next.id
        } else {
            sttProvider = STTProviderType.apple.rawValue
        }
    }

    private func localRow(_ model: LocalSTTModel, picks: LocalPicks) -> some View {
        let state = store.state(for: model.id)
        let badge: SetupBadge? = if picks.recommended == model.id {
            SetupBadge(text: "Recommended", kind: .recommended)
        } else if picks.bestQuality == model.id {
            SetupBadge(text: "Best quality", kind: .quality)
        } else if !localModelFitsMemory(model.memoryFloorBytes, capabilities) {
            SetupBadge(text: "Too heavy for this Mac", kind: .warn)
        } else {
            nil
        }
        return SetupRow(title: speechModelName(model), badge: badge,
                        languageBadge: languageBadge(model.languages, spoken: spoken), facts: speechModelSubtitle(model),
                        detail: speechModelLine(model, spoken: spoken),
                        isSelected: engine == .local && localModelID == model.id,
                        action: { pickLocal(model) }, extra: {
            HStack(spacing: 8) {
                switch state {
                case .notInstalled:
                    Text("Not downloaded").rowNote()
                case .downloading(let fraction):
                    SetupProgressBar(fraction: fraction).frame(maxWidth: 160)
                    Text("Downloading · \(Int(fraction * 100))%" + (waitingFor == model.id ? " — used once it's ready" : ""))
                        .rowNote()
                    Button("Cancel") {
                        store.cancelInstall(model)
                        if waitingFor == model.id { waitingFor = nil }
                    }
                    .buttonStyle(SetupInlineLinkStyle())
                case .optimizing:
                    SetupProgressBar(fraction: nil).frame(maxWidth: 160)
                    Text("Getting ready for your Mac — first time only").rowNote()
                case .installed:
                    Text("✓ Downloaded").rowNote(ok: true)
                    if let next = newerLocalVersion(of: model) {
                        // Never downloaded for the user: a newer version is recommended,
                        // and choosing it downloads it and switches once it is ready.
                        Button("Newer version: \(speechModelName(next))") { pickLocal(next) }
                            .buttonStyle(SetupInlineLinkStyle())
                    }
                    Button("Remove") {
                        if engine == .local && localModelID == model.id { removing = model } else { remove(model) }
                    }
                    .buttonStyle(SetupInlineLinkStyle())
                case .failed(let message):
                    Text(message).rowNote(bad: true).lineLimit(2)
                    Button("Retry") { store.install(model) }.buttonStyle(SetupInlineLinkStyle())
                }
            }
            .padding(.top, 4)
        })
    }

    /// The local model that supersedes this one, when it is not on the Mac already — the
    /// row then offers it; once both are, the old one's Remove is what is left to do.
    private func newerLocalVersion(of model: LocalSTTModel) -> LocalSTTModel? {
        guard case .superseded(let id) = model.lifecycle, let next = localSTTModel(id: id),
              !store.state(for: id).isUsable else { return nil }
        return next
    }

    /// Choosing a model that is not on this Mac yet downloads it, and the engine switches
    /// to it once it is usable (`waitingFor`) — not before, since a dictation during the
    /// download would fail. Settings closed first, nothing switches; the row is tapped again.
    private func pickLocal(_ model: LocalSTTModel) {
        let state = store.state(for: model.id)
        guard state.isUsable else {
            if !state.isBusy { store.install(model) }
            waitingFor = model.id
            return
        }
        waitingFor = nil
        localModelID = model.id
        sttProvider = STTProviderType.local.rawValue
    }

    // MARK: Online

    private var online: some View {
        SettingsGroup(title: "Online services", inset: 5) {
            // Every cloud engine, not only the ones setup offers a card for; a card only
            // lends its words.
            ForEach(STTProviderType.allCases.filter { $0.vendor.descriptor.apiKey != nil }) { engine in
                serviceRow(SetupCards.speechCard(reopening: engine)
                    ?? SpeechServiceCard(service: engine.vendor, engine: engine, title: engine.vendor.displayName,
                                         subtitle: "", detail: "", promisesLiveWords: false))
            }
        }
    }

    private func storedModel(_ service: Provider) -> String {
        switch service {
        case .groq: groqModel
        case .elevenLabs: elevenLabsModel
        case .openAI: openAIModel
        default: service.defaultSpeechModel
        }
    }

    private func setStoredModel(_ id: String, for service: Provider) {
        switch service {
        case .groq: groqModel = id
        case .elevenLabs: elevenLabsModel = id
        case .openAI: openAIModel = id
        default: break
        }
    }

    @ViewBuilder
    private func serviceRow(_ card: SpeechServiceCard) -> some View {
        let selected = engine == card.engine
        let keyed = hasKey(card.service)
        SetupRow(title: card.title, subtitle: card.subtitle.isEmpty ? nil : card.subtitle,
                 badge: keyed ? nil : SetupBadge(text: "No key", kind: selected ? .warn : .quality),
                 detail: onlineSpeechServiceLine(card.service), isSelected: selected) {
            if keyed { sttProvider = card.engine.rawValue } else { opened = card.service }
        }
        if selected || opened == card.service {
            NestedUnderRow {
                ForEach(pickerSTTModels(of: card.service, selected: storedModel(card.service))) { model in
                    SetupRow(title: onlineSpeechModelName(model), subtitle: languageCountLabel(model.languages),
                             badge: lifecycleBadge(model.lifecycle)
                                ?? (model.id == card.service.defaultSpeechModel
                                    ? SetupBadge(text: "Recommended", kind: .recommended) : nil),
                             languageBadge: languageBadge(model.languages, spoken: spoken),
                             detail: onlineSpeechModelLine(model, spoken: spoken),
                             isSelected: storedModel(card.service) == model.id, compact: true) {
                        setStoredModel(model.id, for: card.service)
                        if keyed { sttProvider = card.engine.rawValue }
                    }
                }
                ModelChoiceNote(stored: storedModel(card.service),
                                successor: { offeredSuccessor(of: $0, among: offeredSTTModels(of: card.service).map(\.id),
                                                              lifecycle: sttModel(vendor: card.service, id: $0).lifecycle) },
                                name: { onlineSpeechModelName(sttModel(vendor: card.service, id: $0)) },
                                choose: { setStoredModel($0, for: card.service) })
                // The provider's own note (what its server is asked to leave out) and the
                // selected model's (how a realtime stream falls back), from the catalogue.
                let note = [card.service.descriptor.speechModel?.caption,
                            sttModel(vendor: card.service, id: storedModel(card.service)).settingsNote]
                    .compactMap { $0 }.joined(separator: " ")
                if !note.isEmpty {
                    Text(note).rowNote()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                }
                SettingsKeyField(service: card.service, value: keyBinding(card.service), showsHeader: false)
                    .padding(.top, 6)
                if !selected && keyed {
                    Button("Use \(card.title)") { sttProvider = card.engine.rawValue }
                        .buttonStyle(SetupButtonStyle(kind: .primary, height: 28))
                        .padding(.top, 6)
                } else if !keyed {
                    Text(selected
                         ? "Dictations fail until you add a key."
                         : "Add a key to use \(card.title).")
                        .rowNote(bad: selected)
                }
            }
        }
    }
}

// MARK: - AI Rewrite

struct AIEngineSettings: View {
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = LLMProviderType.groq.rawValue
    @AppStorage(SettingsKeys.localLLMModel) private var localModelID = Provider.local.defaultChatModel
    @AppStorage(SettingsKeys.groqLLMModel) private var groqModel = Provider.groq.defaultChatModel
    @AppStorage(SettingsKeys.anthropicModel) private var anthropicModel = Provider.anthropic.defaultChatModel
    @AppStorage(SettingsKeys.openAIModel) private var openAIModel = Provider.openAI.defaultChatModel

    @State private var place: EnginePlace
    @State private var opened: Provider?
    @State private var store = LocalChatStore.shared
    @State private var capabilities = SystemCapabilities.current()
    @State private var showHeavyModels = false
    @AppStorage(SettingsKeys.spokenLanguages) private var spokenLanguages = ""
    /// A model being downloaded to be used: AI Rewrite switches to it once it is on this
    /// Mac, never before — a rewrite meanwhile would fall back to the transcript.
    @State private var waitingFor: String?
    /// The model in use, about to be removed — asked first.
    @State private var removing: LocalChatModel?

    init() {
        let stored = LLMProviderType(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.llmProvider) ?? "") ?? .groq
        _place = State(initialValue: stored == .local ? .thisMac : .online)
    }

    private var pick: LLMProviderType { LLMProviderType(rawValue: llmProvider) ?? .groq }

    var body: some View {
        EnginePlaceCards(
            place: $place, inUse: pick == .local ? .thisMac : .online,
            macFacts: capabilities.isAppleSilicon
                ? "Private and free. Your text stays on your Mac, and works offline."
                : "Private and free, but slow on this Mac.",
            onlineFacts: "Fast on any Mac. Needs internet and an account; your text is sent to the service.")

        switch place {
        case .thisMac: thisMac
        case .online: online
        }
    }

    // MARK: On this Mac

    private var recommended: LocalChatModel? { recommendedLocalChatModel(for: capabilities) }
    private var bestQuality: LocalChatModel? { bestQualityLocalChatModel(for: capabilities) }

    private var thisMac: some View {
        SettingsGroup(title: "Models on this Mac", trailing: AnyView(
            Text("For your \(macDescription(capabilities))")
                .font(.system(size: 11.5))
                .foregroundStyle(SetupColor.label2)), inset: 5) {
            if !capabilities.isAppleSilicon {
                Text(intelChatWarning).rowNote(bad: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            let fitting = localChatModels.filter { localModelFitsMemory($0.memoryFloorBytes, capabilities) }
            let heavy = localChatModels.filter { !localModelFitsMemory($0.memoryFloorBytes, capabilities) }
            let picks = LocalPicks(recommended: recommended?.id, bestQuality: bestQuality?.id)
            ForEach(fitting) { localRow($0, heavy: false, picks: picks) }
            if !heavy.isEmpty {
                Button(showHeavyModels ? "Hide models too heavy for this Mac"
                                       : "Show \(heavy.count) \(heavy.count == 1 ? "model" : "models") too heavy for this Mac") {
                    withAnimation(.easeOut(duration: 0.2)) { showHeavyModels.toggle() }
                }
                .buttonStyle(SetupInlineLinkStyle())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                if showHeavyModels { ForEach(heavy) { localRow($0, heavy: true, picks: picks) } }
            }
            HStack {
                Text(store.installedModels.isEmpty
                     ? "No models downloaded yet"
                     : "\(ByteCountFormatter.string(fromByteCount: store.installedBytes, countStyle: .file)) of models on this Mac")
                Spacer()
                if !store.installedModels.isEmpty {
                    Button("Show in Finder") {
                        let url = LocalModelStore.modelsDirectory.appendingPathComponent("llm", isDirectory: true)
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(SetupInlineLinkStyle())
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(SetupColor.label2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .onAppear {
            store.refresh()
            capabilities = SystemCapabilities.current()
        }
        .onChange(of: waitingIsReady) { _, ready in
            guard ready, let id = waitingFor else { return }
            waitingFor = nil
            useLocal(id)
        }
        .confirmationDialog("Remove \(removing?.displayName ?? "")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let model = removing { remove(model) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text(fallback.map { "It is the model in use. AI Rewrite switches to \($0.displayName)." }
                 ?? "It is the model in use. AI Rewrite pastes your words as said until you download another.")
        }
    }

    private var waitingIsReady: Bool {
        waitingFor.flatMap(localChatModel(id:)).map { store.state(for: $0) == .installed } ?? false
    }

    /// What a removed model in use gives way to: another one on this Mac.
    private var fallback: LocalChatModel? {
        store.installedModels.first { $0.id != removing?.id }
    }

    private func useLocal(_ id: String) {
        localModelID = id
        llmProvider = LLMProviderType.local.rawValue
        if let model = localChatModel(id: id) { LocalChat.prewarm(model) }
    }

    private func remove(_ model: LocalChatModel) {
        let inUse = pick == .local && localModelID == model.id
        let next = fallback
        store.remove(model)
        if inUse, let next { useLocal(next.id) }
    }

    /// Choosing a model not on this Mac yet downloads it; AI Rewrite switches to it once it
    /// is ready (`waitingFor`). Settings closed first, nothing switches.
    private func pickLocal(_ model: LocalChatModel) {
        let state = store.state(for: model)
        guard state == .installed else {
            if !state.isBusy { store.install(model) }
            waitingFor = model.id
            return
        }
        waitingFor = nil
        useLocal(model.id)
    }

    private func localRow(_ model: LocalChatModel, heavy: Bool, picks: LocalPicks) -> some View {
        let state = store.state(for: model)
        let badge: SetupBadge? = if picks.recommended == model.id {
            SetupBadge(text: "Recommended", kind: .recommended)
        } else if picks.bestQuality == model.id {
            SetupBadge(text: "Best quality", kind: .quality)
        } else if heavy {
            SetupBadge(text: "Too heavy for this Mac", kind: .warn)
        } else {
            nil
        }
        return SetupRow(title: model.displayName, subtitle: model.downloadSizeDescription, badge: badge,
                        detail: aiModelLine(model, heavy: heavy, spoken: parseSpokenLanguages(spokenLanguages)),
                        isSelected: pick == .local && localModelID == model.id,
                        action: { pickLocal(model) }) {
            HStack(spacing: 8) {
                switch state {
                case .notInstalled:
                    Text("Not downloaded").rowNote()
                case .downloading(let fraction):
                    SetupProgressBar(fraction: fraction).frame(maxWidth: 160)
                    Text("Downloading · \(Int(fraction * 100))%" + (waitingFor == model.id ? " — used once it's ready" : ""))
                        .rowNote()
                    Button("Cancel") {
                        store.cancelInstall(model)
                        if waitingFor == model.id { waitingFor = nil }
                    }
                    .buttonStyle(SetupInlineLinkStyle())
                case .optimizing:
                    SetupProgressBar(fraction: nil).frame(maxWidth: 160)
                    Text("Checking the download").rowNote()
                case .installed:
                    Text("✓ Downloaded").rowNote(ok: true)
                    Button("Remove") {
                        if pick == .local && localModelID == model.id { removing = model } else { remove(model) }
                    }
                    .buttonStyle(SetupInlineLinkStyle())
                case .failed(let message):
                    Text(message).rowNote(bad: true).lineLimit(2)
                    Button("Retry") { store.install(model) }.buttonStyle(SetupInlineLinkStyle())
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Online

    private var online: some View {
        SettingsGroup(title: "Online services", inset: 5) {
            ForEach(LLMProviderType.allCases.filter { $0.needsAPIKey }) { pick in
                serviceRow(SetupCards.ai.first { $0.pick == pick }
                    ?? AIServiceCard(service: pick.vendor, pick: pick, title: pick.vendor.displayName,
                                     subtitle: ""))
            }
        }
    }

    private func storedModel(_ pick: LLMProviderType) -> String {
        switch pick {
        case .groq: groqModel
        case .anthropic: anthropicModel
        case .openai: openAIModel
        case .local: localModelID
        }
    }

    private func setStoredModel(_ id: String, for pick: LLMProviderType) {
        switch pick {
        case .groq: groqModel = id
        case .anthropic: anthropicModel = id
        case .openai: openAIModel = id
        case .local: localModelID = id
        }
    }

    @ViewBuilder
    private func serviceRow(_ card: AIServiceCard) -> some View {
        let selected = pick == card.pick
        let keyed = hasKey(card.service)
        SetupRow(title: card.title, subtitle: card.subtitle.isEmpty ? nil : card.subtitle,
                 badge: keyed ? nil : SetupBadge(text: "No key", kind: selected ? .warn : .quality),
                 detail: onlineAIServiceLine(card.service), isSelected: selected) {
            if keyed { llmProvider = card.pick.rawValue } else { opened = card.service }
        }
        if selected || opened == card.service {
            NestedUnderRow {
                ForEach(pickerChatModels(of: card.pick, selected: storedModel(card.pick)), id: \.id) { model in
                    SetupRow(title: chatModelName(model),
                             badge: lifecycleBadge(model.lifecycle)
                                ?? (model.id == card.service.defaultChatModel
                                    ? SetupBadge(text: "Recommended", kind: .recommended) : nil),
                             detail: chatModelLine(model).isEmpty ? nil : chatModelLine(model),
                             isSelected: storedModel(card.pick) == model.id, compact: true) {
                        setStoredModel(model.id, for: card.pick)
                        if keyed { llmProvider = card.pick.rawValue }
                    }
                }
                ModelChoiceNote(stored: storedModel(card.pick),
                                successor: { offeredSuccessor(of: $0, among: offeredChatModels(of: card.pick).map(\.id),
                                                              lifecycle: chatModel(provider: card.pick, id: $0).lifecycle) },
                                name: { chatModelName(chatModel(provider: card.pick, id: $0)) },
                                choose: { setStoredModel($0, for: card.pick) })
                SettingsKeyField(service: card.service, value: keyBinding(card.service), showsHeader: false)
                    .padding(.top, 6)
                if !selected && keyed {
                    Button("Use \(card.title)") { llmProvider = card.pick.rawValue }
                        .buttonStyle(SetupButtonStyle(kind: .primary, height: 28))
                        .padding(.top, 6)
                } else if !keyed {
                    Text(selected
                         ? "AI Rewrite pastes your words as said until you add a key."
                         : "Add a key to use \(card.title).")
                        .rowNote(bad: selected)
                }
            }
        }
    }
}

/// A model the vendor is retiring says so, with the date, in place of any other badge. It
/// is listed only while it is still the one selected (`pickerSTTModels`).
private func lifecycleBadge(_ lifecycle: ModelLifecycle) -> SetupBadge? {
    if case .superseded = lifecycle { return SetupBadge(text: "Newer model available", kind: .quality) }
    return lifecycle.status(on: Date()).map { SetupBadge(text: $0, kind: .warn) }
}

/// The offered model a superseded one points to, or nil.
private func offeredSuccessor(of id: String, among offered: [String], lifecycle: ModelLifecycle) -> String? {
    guard case .superseded(let next) = lifecycle, offered.contains(next) else { return nil }
    return next
}

/// Under a service's models: what the stored choice needs from the user — a model to be
/// chosen when the launch cleared one that leads nowhere, or the switch to the
/// model a newer one supersedes it with. Nothing otherwise.
private struct ModelChoiceNote: View {
    let stored: String
    let successor: (String) -> String?
    let name: (String) -> String
    let choose: (String) -> Void

    var body: some View {
        if stored == clearedModelChoice {
            Text("Choose a model — the one you had is no longer available, and dictation waits for your pick.")
                .rowNote(bad: true)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.top, 2)
        } else if let next = successor(stored) {
            HStack(spacing: 8) {
                Text("\(name(next)) is newer.").rowNote()
                Button("Switch to it") { choose(next) }
                    .buttonStyle(SetupInlineLinkStyle())
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
        }
    }
}

private extension Text {
    func rowNote(ok: Bool = false, bad: Bool = false) -> some View {
        font(.system(size: 11, weight: ok ? .medium : .regular))
            .foregroundStyle(ok ? SetupColor.ok : bad ? SetupColor.danger : SetupColor.label2)
    }
}
