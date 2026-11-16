// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import SpeechTextCore

// Settings › Models (#247): one page for both models, since a dictation passes through
// them in turn. At the top, the chain a shortcut's dictation takes — what it starts from,
// a frame for each model it passes through, and the result — drawn from what is in use;
// a frame is also the way to its model's choices, shown under the chain one at a time.
// Pictures more than words: the role names the frame, the place's glyph says where the
// model runs, and the model's name is the only other text.

struct ModelsPage: View {
    let openPresets: () -> Void

    @AppStorage(SettingsKeys.modelsPageShortcut) private var storedShortcut = ""
    @AppStorage(SettingsKeys.modelsPageRole) private var storedRole = ""

    private var selection: ModelsPageSelection {
        ModelsPageSelection(storedShortcut: storedShortcut, storedRole: storedRole)
    }

    /// Stores the page on `role`'s frame for the next time it shows — a link from another
    /// window or page, which the user means to land on rather than where they left it.
    static func open(_ role: ModelRole) {
        let defaults = UserDefaults.standard
        let next = ModelsPageSelection(storedShortcut: defaults.string(forKey: SettingsKeys.modelsPageShortcut) ?? "",
                                       storedRole: defaults.string(forKey: SettingsKeys.modelsPageRole) ?? "")
            .opening(role)
        defaults.set(next.shortcut.rawValue, forKey: SettingsKeys.modelsPageShortcut)
        defaults.set(next.role.rawValue, forKey: SettingsKeys.modelsPageRole)
    }

    private func store(_ next: ModelsPageSelection) {
        storedShortcut = next.shortcut.rawValue
        storedRole = next.role.rawValue
    }

    var body: some View {
        let selection = selection
        VStack(alignment: .leading, spacing: 14) {
            ModelChainTabs(selection: selection.shortcut) { shortcut in
                store(ModelsPageSelection(storedShortcut: shortcut.rawValue, storedRole: selection.role.rawValue))
            }
            ModelChain(shortcut: selection.shortcut, selected: selection.role) { role in
                store(ModelsPageSelection(shortcut: selection.shortcut, role: role))
            }
        }

        Group {
            switch selection.role {
            case .speech:
                SpeechEngineSettings()
            case .aiRewrite:
                AIEngineSettings()
                SettingsGroup(title: "Prompts") {
                    SettingsRow(title: "Prompts",
                                detail: "What a dictation can become. The model picks the one that fits.") {
                        Button("Edit Prompts…", action: openPresets)
                            .buttonStyle(SetupButtonStyle(kind: .secondary, height: 28))
                    }
                }
            }
        }
        .environment(\.setupTint, selection.role.tint)
        .tint(selection.role.tint.accent)
    }
}

// MARK: - Tabs

/// One tab per shortcut, with its keys: Dictate, AI Rewrite, Edit.
struct ModelChainTabs: View {
    let selection: ModelChainShortcut
    let choose: (ModelChainShortcut) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ModelChainShortcut.allCases, id: \.self) { shortcut in
                ModelChainTab(shortcut: shortcut, isSelected: shortcut == selection) { choose(shortcut) }
            }
        }
    }
}

private struct ModelChainTab: View {
    let shortcut: ModelChainShortcut
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var title: LocalizedStringKey {
        switch shortcut {
        case .dictate: "Dictate"
        case .aiRewrite: "AI Rewrite"
        case .edit: "Edit"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isSelected ? SetupColor.label : SetupColor.label2)
                HomeKeycaps(keys: shortcutKeys(shortcutText(for: shortcut.action)), size: 16, radius: 4,
                            fontSize: 9.5, spacing: 2, muted: !isSelected)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(isSelected ? SettingsColor.panel : hovering ? SettingsColor.panel.opacity(0.6) : .clear))
            .overlay(Capsule().strokeBorder(isSelected ? SettingsColor.panelBorder : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - The chain

/// Input → a frame per model → result, for one shortcut. The selected frame is lit and
/// the other dimmed; tapping a frame selects it.
struct ModelChain: View {
    let shortcut: ModelChainShortcut
    let selected: ModelRole
    let select: (ModelRole) -> Void

    var body: some View {
        HStack(spacing: 0) {
            input
            ForEach(shortcut.roles, id: \.self) { role in
                ModelChainWire(tint: role.tint)
                ModelChainFrame(role: role, isSelected: role == selected) { select(role) }
            }
            ModelChainWire(tint: shortcut.roles.last?.tint ?? .green)
            result
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var input: some View {
        if shortcut.startsFromSelection {
            HStack(spacing: 4) {
                ModelChainDisc(symbol: "highlighter", size: 30)
                    .accessibilityLabel("Selected text")
                Text(verbatim: "+").font(.system(size: 13, weight: .semibold)).foregroundStyle(SetupColor.label3)
                ModelChainDisc(symbol: "mic", size: 30)
                    .accessibilityLabel("Your voice")
            }
        } else {
            ModelChainDisc(symbol: "mic", size: 38)
                .accessibilityLabel("Your voice")
        }
    }

    /// The text at the cursor, or the selection replaced; marked with AI's sparkle when AI
    /// Rewrite wrote it, so it reads as more than the words said.
    private var result: some View {
        ModelChainDisc(symbol: shortcut == .edit ? "text.badge.checkmark" : "text.cursor", size: 38,
                       sparkle: shortcut.roles.contains(.aiRewrite))
            .accessibilityLabel(shortcut == .edit ? Text("The selection, replaced") : Text("Text at your cursor"))
    }
}

/// A round well with one symbol: what a chain starts from and what it ends in.
private struct ModelChainDisc: View {
    let symbol: String
    let size: CGFloat
    var sparkle = false

    var body: some View {
        Circle()
            .fill(SetupColor.control)
            .overlay(Circle().strokeBorder(sparkle ? SetupTint.violet.accent.opacity(0.45) : SettingsColor.panelBorder, lineWidth: 1))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(SetupColor.label)
            }
            .overlay(alignment: .topTrailing) {
                if sparkle {
                    Circle()
                        .fill(LinearGradient(colors: SetupTint.violet.glyph, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Circle().strokeBorder(SettingsColor.background, lineWidth: 2))
                        .frame(width: 19, height: 19)
                        .overlay {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(SetupTint.violet.glyphInk)
                        }
                        .offset(x: 5, y: -5)
                }
            }
            .accessibilityElement(children: .ignore)
    }
}

/// The arrow between two parts, with a dot that runs along it — the dictation moving on.
/// Still, under Reduce Motion.
private struct ModelChainWire: View {
    let tint: SetupTint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One run of the dot, end to end, as the design has it.
    private static let period: Double = 2.4

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(SetupColor.label3).frame(height: 1.5)
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(SetupColor.label3)
                    .offset(x: width - 5)
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                        Circle()
                            .fill(tint.accent)
                            .frame(width: 5, height: 5)
                            .offset(x: (width - 5) * phase)
                            // In and out at the ends, so the dot is not seen to jump back.
                            .opacity(min(phase / 0.15, (1 - phase) / 0.15, 1) * 0.9)
                    }
                }
            }
            .frame(height: proxy.size.height)
        }
        .frame(minWidth: 14, maxWidth: 24)
        .frame(height: 8)
        .padding(.horizontal, 3)
        .accessibilityHidden(true)
    }
}

/// A model in its role: the role's name on the frame's edge, the place's glyph and the
/// model's name inside.
private struct ModelChainFrame: View {
    let role: ModelRole
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    // Read so a pick below the chain redraws the frame (`ModelInUse` reads the defaults).
    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = ""
    @AppStorage(SettingsKeys.localSTTModel) private var localSTTModelID = ""
    @AppStorage(SettingsKeys.groqModel) private var groqModel = ""
    @AppStorage(SettingsKeys.elevenLabsModel) private var elevenLabsModel = ""
    @AppStorage(SettingsKeys.openAISTTModel) private var openAISTTModel = ""
    @AppStorage(SettingsKeys.serverSpeechModel) private var serverSpeechModel = ""
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = ""
    @AppStorage(SettingsKeys.groqLLMModel) private var groqLLMModel = ""
    @AppStorage(SettingsKeys.anthropicModel) private var anthropicModel = ""
    @AppStorage(SettingsKeys.openAIModel) private var openAIModel = ""
    @AppStorage(SettingsKeys.localLLMModel) private var localLLMModel = ""
    @AppStorage(SettingsKeys.serverChatModel) private var serverChatModel = ""

    private var model: ModelInUse {
        _ = (sttProvider, localSTTModelID, groqModel, elevenLabsModel, openAISTTModel, serverSpeechModel)
        _ = (llmProvider, groqLLMModel, anthropicModel, openAIModel, localLLMModel, serverChatModel)
        return ModelInUse.current(role)
    }

    var body: some View {
        let tint = role.tint
        let model = model
        Button(action: action) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(model.place == nil
                          ? AnyShapeStyle(SetupColor.panel)
                          : AnyShapeStyle(LinearGradient(colors: tint.glyph, startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: model.place?.symbol ?? role.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(model.place == nil ? SetupColor.label2 : tint.glyphInk)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: model.name ?? String(localized: "Choose a model"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(model.name == nil ? tint.accent : SetupColor.label)
                    Text(verbatim: model.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(SetupColor.label2)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 11).fill(SetupColor.control))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(SettingsColor.panelBorder, lineWidth: 1))
            .padding(EdgeInsets(top: 13, leading: 7, bottom: 7, trailing: 7))
            .background(RoundedRectangle(cornerRadius: 15).fill(tint.accent.opacity(0.07)))
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(tint.accent.opacity(isSelected ? 1 : hovering ? 0.55 : 0.35), lineWidth: isSelected ? 1.5 : 1)
            }
            .background {
                if isSelected { RoundedRectangle(cornerRadius: 19).fill(tint.glow.opacity(0.32)).padding(-4) }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    Image(systemName: role.symbol).font(.system(size: 9, weight: .semibold))
                    Text(role.title).font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(tint.accent)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(SettingsColor.background))
                .overlay(Capsule().strokeBorder(tint.accent.opacity(isSelected ? 1 : 0.35), lineWidth: 1))
                .fixedSize()
                .offset(x: 10, y: -9)
            }
            .opacity(isSelected || hovering ? 1 : 0.6)
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 140, maxWidth: .infinity)
        .padding(.top, 9)
        .onHover { hovering = $0 }
        // A long name is cut to fit beside the other frame; the pointer shows it whole.
        .help(Text(verbatim: model.name ?? ""))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(role.title))
        .accessibilityValue(Text(verbatim: [model.name ?? String(localized: "Choose a model"), model.detail].joined(separator: ", ")))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - What is in use

/// A frame's model: where it runs, its name, and the line under it — the service, or the
/// place. `place` is nil while AI Rewrite has nothing it can use, and `name` while a model
/// is still to be chosen.
struct ModelInUse {
    let place: EnginePlace?
    let name: String?
    let detail: String

    static func current(_ role: ModelRole) -> ModelInUse {
        role == .speech ? speech : aiRewrite
    }

    private static func stored(_ key: String, _ fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }

    private static var speech: ModelInUse {
        let engine = STTProviderType(rawValue: stored(SettingsKeys.sttProvider, "")) ?? .apple
        switch engine {
        case .apple:
            return ModelInUse(place: .thisMac, name: String(localized: "Apple Dictation"), detail: EnginePlace.thisMac.name)
        case .local:
            let id = stored(SettingsKeys.localSTTModel, Provider.local.defaultSpeechModel)
            let name = localSTTModel(id: id)?.displayName ?? (id.isEmpty ? nil : id)
            return ModelInUse(place: .thisMac, name: name, detail: EnginePlace.thisMac.name)
        case .server:
            let id = stored(SettingsKeys.serverSpeechModel, "")
            return ModelInUse(place: .server, name: id.isEmpty ? nil : id, detail: EnginePlace.server.name)
        case .groq, .elevenlabs, .openai:
            let key = switch engine {
            case .groq: SettingsKeys.groqModel
            case .elevenlabs: SettingsKeys.elevenLabsModel
            default: SettingsKeys.openAISTTModel
            }
            let id = stored(key, engine.vendor.defaultSpeechModel)
            let name = id == clearedModelChoice ? nil : plainModelName(sttModel(vendor: engine.vendor, id: id).displayName)
            return ModelInUse(place: .online, name: name, detail: engine.vendor.displayName)
        }
    }

    private static var aiRewrite: ModelInUse {
        guard LLMConfiguration.isConfigured else {
            return ModelInUse(place: nil, name: nil, detail: String(localized: "Off"))
        }
        let type = LLMProviderType(rawValue: stored(SettingsKeys.llmProvider, "")) ?? .groq
        let id = LLMConfiguration.model(for: type)
        let name = id == clearedModelChoice ? nil : plainModelName(chatModel(provider: type, id: id).displayName)
        switch type {
        case .local: return ModelInUse(place: .thisMac, name: name, detail: EnginePlace.thisMac.name)
        case .server: return ModelInUse(place: .server, name: id.isEmpty ? nil : id, detail: EnginePlace.server.name)
        case .groq, .anthropic, .openai: return ModelInUse(place: .online, name: name, detail: type.vendor.displayName)
        }
    }
}
