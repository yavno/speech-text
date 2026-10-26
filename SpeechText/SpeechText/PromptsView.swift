// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import SpeechTextCore

// MARK: - Prompts

/// The main window's Prompts, laid out as Usage is: the title, then a banner on the
/// approved AI gradient saying how AI Rewrite picks a prompt — closable once it is
/// understood — then the Canvas's two columns: the prompts on the page's white, each with
/// how often History says it was chosen, and on the dot field the one selected, to edit,
/// with the dictations it was last chosen for. Last, across both, what else AI Rewrite is
/// told. Violet is kept for what AI Rewrite *did* (a prompt's tag) and its gradient;
/// everything else is the page's ink. Replaces the separate presets window.
struct PromptsView: View {
    let actions: MainWindowActions
    let go: (MainPage) -> Void

    @State private var presets: [PromptPreset] = PromptPresetStore.load()
    @State private var defaultID: UUID? = PromptPresetStore.defaultPreset(in: PromptPresetStore.load())?.id
    @State private var selection: UUID?
    @State private var confirmingRestore = false
    @State private var saveTask: Task<Void, Never>?
    /// How often History says each prompt was chosen, counted again only when it changes —
    /// not on every keystroke in the prompt being edited.
    @State private var usage = PresetUsage.Cache()
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = LLMProviderType.groq.rawValue
    @AppStorage(SettingsKeys.localLLMModel) private var localLLMModel = Provider.local.defaultChatModel
    @AppStorage(SettingsKeys.promptsIntroHidden) private var introHidden = false

    private var history: TranscriptionHistory { .shared }
    private static let top = "top"

    private var aiReady: Bool {
        _ = (llmProvider, localLLMModel)
        return LLMConfiguration.isConfigured
    }

    private var selectedIndex: Int? {
        presets.firstIndex { $0.id == selection } ?? (presets.isEmpty ? nil : 0)
    }

    var body: some View {
        // Read here, so the page follows History; counted only when it changed.
        usage.refresh(from: history.records)
        let uses = usage.uses
        return GeometryReader { proxy in
            ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    MainPageTitle(.prompts)
                    // Hidden from Settings › Appearance. Off, the banner carries the way to turn
                    // AI Rewrite on, so it shows whatever that setting says.
                    if !introHidden || !aiReady {
                        PromptsBanner(presets: presets, aiReady: aiReady,
                                      choose: { actions.openSettings(.ai) })
                    }
                    HStack(alignment: .top, spacing: 24) {
                        list(uses: uses)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        editor(uses: uses)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    PromptsToldCard(go: go)
                }
                .frame(maxWidth: HomeView.columnWidth)
                .padding(.horizontal, 48)
                .padding(.top, 32)
                .padding(.bottom, 44)
                .frame(width: proxy.size.width)
                .id(Self.top)
            }
            .scrollIndicators(.automatic)
            .onAppear {
                // A window opened straight onto this page makes the prompt's name field the
                // first responder, which scrolls the page down to it and would take the
                // next keystroke as an edit. The page opens at its top, nothing focused.
                DispatchQueue.main.async {
                    if let window = NSApp.keyWindow, window.firstResponder is NSText {
                        window.makeFirstResponder(nil)
                    }
                    scroller.scrollTo(Self.top, anchor: .top)
                }
            }
            }
        }
        .onDisappear { persist() }
        .confirmationDialog("Restore the built-in prompts?", isPresented: $confirmingRestore) {
            Button("Restore Built-in Prompts", role: .destructive) {
                saveTask?.cancel()
                PromptPresetStore.resetToDefaults()
                presets = PromptPresetStore.builtInDefaults
                defaultID = PromptPresetStore.defaultPreset(in: presets)?.id
                selection = presets.first?.id
            }
        } message: {
            Text("Your own prompts and changes are replaced by the six that come with SpeechText.")
        }
    }

    // MARK: The prompt open

    /// The Canvas's right column: the selected prompt on the dot field, to edit, and what
    /// it was last chosen for.
    private func editor(uses: [String: PresetUsage.Use]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader("Edit prompt", detail: "saved as you type")
            VStack(alignment: .leading, spacing: 14) {
                if let index = selectedIndex {
                    PromptEditorCard(preset: binding(index), isDefault: presets[index].id == defaultID,
                                     canDelete: presets.count > 1, use: uses[presets[index].name.lowercased()],
                                     makeDefault: { makeDefault(presets[index].id) },
                                     delete: { delete(presets[index].id) })
                        .id(presets[index].id)
                    PromptRecentCard(preset: presets[index], records: usage.recent(presets[index]))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(MainDotField().clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
        }
    }

    // MARK: The list

    /// The Canvas's left column: Home's grey with the prompts on it; the one open on the
    /// right is lifted onto white, as a selected tab is.
    private func list(uses: [String: PresetUsage.Use]) -> some View {
        return VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader("Your prompts", detail: "\(presets.count)") {
                Button { add() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("New prompt")
                    }
                }
                .buttonStyle(SetupButtonStyle(kind: .secondary, height: 28))
                .pointingHandCursor()
            }
            VStack(spacing: 2) {
                ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                    PromptRow(preset: preset, symbol: Self.symbol(for: preset),
                              isDefault: preset.id == defaultID,
                              isSelected: index == selectedIndex,
                              use: uses[preset.name.lowercased()]) {
                        selection = preset.id
                    }
                    .contextMenu {
                        if preset.id != defaultID {
                            Button("Use as Default") { makeDefault(preset.id) }
                        }
                        Button("Duplicate") { duplicate(preset) }
                        Divider()
                        Button("Move Up") { move(preset.id, by: -1) }.disabled(index == 0)
                        Button("Move Down") { move(preset.id, by: 1) }.disabled(index == presets.count - 1)
                        Divider()
                        Button("Delete") { delete(preset.id) }.disabled(presets.count <= 1)
                    }
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MainColor.panel))

            HStack(spacing: 12) {
                Text("Right-click a prompt to make it the default, duplicate or move it.")
                    .font(.system(size: 12))
                    .foregroundStyle(MainColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                HistoryQuietButton(title: "Restore built-in…", symbol: "arrow.counterclockwise") {
                    confirmingRestore = true
                }
            }
        }
    }

    /// A built-in prompt's symbol, by its fixed id; anyone else's by what its name says.
    /// How often History says AI Rewrite chose a prompt, in words.
    static func usedTimes(_ count: Int) -> String {
        count == 1 ? "Used once" : "Used \(HomeFormat.integer(count)) times"
    }

    static func symbol(for preset: PromptPreset) -> String {
        let builtIn: [String: String] = [
            "01": "wand.and.stars", "02": "pencil.line", "03": "envelope",
            "04": "character.bubble", "05": "list.bullet", "06": "chevron.left.forwardslash.chevron.right",
        ]
        if PromptPresetStore.builtInDefaults.contains(where: { $0.id == preset.id }),
           let symbol = builtIn[String(preset.id.uuidString.suffix(2))] {
            return symbol
        }
        let name = preset.name.lowercased()
        if name.contains("mail") || name.contains("message") || name.contains("лист") { return "envelope" }
        if name.contains("translat") || name.contains("переклад") { return "character.bubble" }
        if name.contains("note") || name.contains("list") || name.contains("bullet") { return "list.bullet" }
        if name.contains("code") || name.contains("tech") || name.contains("commit") { return "chevron.left.forwardslash.chevron.right" }
        return "text.bubble"
    }

    // MARK: Editing

    private func binding(_ index: Int) -> Binding<PromptPreset> {
        Binding(
            get: { index < presets.count ? presets[index] : PromptPreset(name: "", whenToUse: "", instructions: "") },
            set: {
                guard index < presets.count else { return }
                presets[index] = $0
                persistSoon()
            })
    }

    private func add() {
        let new = PromptPreset(name: "New prompt", whenToUse: "", instructions: "")
        presets.append(new)
        selection = new.id
        persist()
    }

    private func duplicate(_ preset: PromptPreset) {
        let copy = PromptPreset(name: preset.name + " copy", whenToUse: preset.whenToUse, instructions: preset.instructions)
        if let index = presets.firstIndex(of: preset) { presets.insert(copy, at: index + 1) } else { presets.append(copy) }
        selection = copy.id
        persist()
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = presets.firstIndex(where: { $0.id == id }),
              presets.indices.contains(index + offset) else { return }
        presets.swapAt(index, index + offset)
        persist()
    }

    private func delete(_ id: UUID) {
        guard presets.count > 1, let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets.remove(at: index)
        if id == defaultID {
            defaultID = presets.first?.id
            if let first = defaultID { PromptPresetStore.setDefaultPreset(first) }
        }
        selection = presets[min(index, presets.count - 1)].id
        persist()
    }

    private func makeDefault(_ id: UUID) {
        defaultID = id
        PromptPresetStore.setDefaultPreset(id)
    }

    /// Typing writes on every keystroke and every write encodes all the prompts, so the
    /// text fields settle first; anything structural saves at once.
    private func persistSoon() {
        let snapshot = presets
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            PromptPresetStore.save(snapshot)
        }
    }

    private func persist() {
        saveTask?.cancel()
        saveTask = nil
        PromptPresetStore.save(presets)
    }
}

// MARK: - How it picks

/// How AI Rewrite picks a prompt, as Usage's opening panel says how fast speaking is: the
/// point in a sentence large, what it means under it, and beside it a few examples in
/// turn on the approved gradient — what was said, and the prompt it fitted (each only
/// while the user still has that prompt). Closable for good once AI Rewrite works; until
/// then it carries the way to a provider.
private struct PromptsBanner: View {
    let presets: [PromptPreset]
    let aiReady: Bool
    let choose: () -> Void

    /// Under the words, white with a breath of the violet in it; in Dark Mode, the card.
    private static let background = Color.setup(0xF8F6FE, dark: 0x232624)

    private struct Example {
        let builtIn: String
        let said: String
    }

    /// Keyed by the built-in prompts' fixed ids' last two digits.
    private static let examples: [Example] = [
        Example(builtIn: "03", said: "uh email to Olena running late start without me"),
        Example(builtIn: "05", said: "list for the trip passport charger the blue jacket"),
        Example(builtIn: "04", said: "translate to English дякую що прийшли"),
        Example(builtIn: "06", said: "fix the bug where the token expires too early"),
    ]

    private var shown: [(said: String, preset: PromptPreset)] {
        Self.examples.compactMap { example in
            presets.first { $0.id.uuidString.hasSuffix(example.builtIn) }.map { (example.said, $0) }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let words = min(460, max(330, width * 0.46))
            ZStack(alignment: .topLeading) {
                MainAIGlow(ai: true, fade: .init(dotsFrom: words - 40, dotsTo: words + 200,
                                                 white: (words - 90, words + 10, words + 150),
                                                 whiteOpacity: 0.7, background: Self.background))
                HStack(spacing: 0) {
                    text.frame(width: words, alignment: .leading)
                    examples.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(height: 230)
        .background(Self.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.system(size: 11.5)).foregroundStyle(MainColor.aiInk)
                Text("How AI Rewrite picks a prompt").font(.system(size: 13.5, weight: .medium)).foregroundStyle(MainColor.ink)
            }
            Text("Talk, or say what you want")
                .font(.system(size: 30, weight: .bold))
                .tracking(-1)
                .foregroundStyle(MainColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 14)
                .padding(.bottom, 8)
            Text(aiReady
                 ? "Words to tidy up, or a request like “make it a list, in English”: it picks the prompt whose “When to use” fits and does what else you asked. Nothing fits? The Default does."
                 : "Once AI Rewrite has a provider — a key, or a model on this Mac — it reads what you said, or what you asked for, and picks the prompt whose “When to use” fits.")
                .font(.system(size: 14))
                .foregroundStyle(MainColor.ink2)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if !aiReady {
                Button("Choose a provider", action: choose)
                    .buttonStyle(SetupButtonStyle(kind: .primary, height: 32))
                    .environment(\.setupTint, .violet)
                    .pointingHandCursor()
                    .padding(.top, 16)
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 12)
        .padding(.vertical, 24)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    /// On the gradient, an example in turn: what was said, then the prompt it fits.
    private var examples: some View {
        TimelineView(.periodic(from: .now, by: 3)) { context in
            let examples = shown
            if !examples.isEmpty {
                let index = Int(context.date.timeIntervalSinceReferenceDate / 3) % examples.count
                let example = examples[index]
                VStack(alignment: .leading, spacing: 10) {
                    MainGlassPill(height: 34) {
                        Image(systemName: "mic").font(.system(size: 11)).foregroundStyle(MainColor.ink2)
                        Text("“\(example.said)”").italic().foregroundStyle(MainColor.ink2)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                            .padding(.leading, 14)
                        MainGlassPill(height: 32) {
                            Image(systemName: PromptsView.symbol(for: example.preset))
                                .font(.system(size: 11)).foregroundStyle(MainColor.aiInk)
                            Text(example.preset.name).foregroundStyle(MainColor.aiInk)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .id(index)
                .transition(.opacity.combined(with: .offset(y: 4)))
                .animation(.easeOut(duration: 0.35), value: index)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("An example: what you say, and the prompt it fits")
    }
}

// MARK: - A prompt in the list

/// A prompt on the grey: its symbol, name and when it fits, and how often it was chosen.
/// The one open on the right sits on white, lifted, as a selected tab does.
private struct PromptRow: View {
    let preset: PromptPreset
    let symbol: String
    let isDefault: Bool
    let isSelected: Bool
    let use: PresetUsage.Use?
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        Button(action: select) {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? MainColor.panel : MainColor.card)
                    .frame(width: 32, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MainColor.panelBorder, lineWidth: 0.5))
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? MainColor.ink : MainColor.ink2)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(preset.name.isEmpty ? "Untitled" : preset.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(MainColor.ink)
                            .lineLimit(1)
                        if isDefault { MainChip(title: "Default", tint: .green) }
                    }
                    Text(preset.whenToUse.isEmpty ? "No “When to use” yet — AI Rewrite can't tell when it fits."
                         : preset.whenToUse.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 12.5))
                        .foregroundStyle(preset.whenToUse.isEmpty ? MainColor.problem : MainColor.ink2)
                        .lineLimit(2)
                        .lineSpacing(1.5)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Said in words: a bare "7×" read as a multiplier, not as a count of uses.
                VStack(alignment: .trailing, spacing: 2) {
                    Text(use.map { PromptsView.usedTimes($0.count) } ?? "Not used yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(use == nil ? MainColor.ink3 : MainColor.ink2)
                        .monospacedDigit()
                    if let last = use?.last {
                        Text("last " + HomeRecentEntry.relativeDay(last).lowercased())
                            .font(.system(size: 11))
                            .foregroundStyle(MainColor.ink3)
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .help(use.map { "Chosen for \($0.count) \($0.count == 1 ? "dictation" : "dictations") in History" }
                      ?? "Not chosen in History yet")
            }
            .padding(.leading, 11)
            .padding(.trailing, 14)
            .padding(.vertical, 11)
            .background {
                if isSelected {
                    shape.fill(MainColor.card)
                        .shadow(color: Color(hex: 0x182C20).opacity(0.1), radius: 3, y: 1.5)
                        .overlay(shape.strokeBorder(MainColor.panelBorder, lineWidth: 0.5))
                } else if hovering {
                    shape.fill(MainColor.card.opacity(0.55))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - The prompt being edited

/// The prompt open for editing: its name written in the header itself, then its two texts
/// each in a grey well with a small label, as a panel's sections are.
private struct PromptEditorCard: View {
    @Binding var preset: PromptPreset
    let isDefault: Bool
    let canDelete: Bool
    let use: PresetUsage.Use?
    let makeDefault: () -> Void
    let delete: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(MainColor.panel)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: PromptsView.symbol(for: preset))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(MainColor.ink)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Name", text: $preset.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(MainColor.ink)
                    Text(use.map { PromptsView.usedTimes($0.count) + " · last \(($0.last.map { HomeRecentEntry.relativeDay($0) } ?? "").lowercased())" }
                         ?? "Not used yet")
                        .font(.system(size: 12))
                        .foregroundStyle(MainColor.ink3)
                }
                Spacer(minLength: 8)
                if isDefault {
                    MainChip(title: "Default", symbol: "checkmark", tint: .green)
                        .help("Used when nothing else clearly fits what you said")
                }
            }

            section("When to use", hint: "The situation AI Rewrite recognizes from what you said — distinct from every other prompt's.") {
                MainTextEditor(text: $preset.whenToUse, minHeight: 64, tint: MainColor.ink2, fill: MainColor.card)
            }
            section("Instructions", hint: "What it does to the text once this prompt is picked.") {
                MainTextEditor(text: $preset.instructions, minHeight: 130, tint: MainColor.ink2, fill: MainColor.card)
            }

            HStack(spacing: 10) {
                if !isDefault {
                    Button("Use as default", action: makeDefault)
                        .buttonStyle(SetupButtonStyle(kind: .secondary, height: 28))
                        .help("Used when nothing else clearly fits what you said")
                }
                Spacer(minLength: 8)
                if canDelete {
                    HistoryQuietButton(title: "Delete", symbol: "trash", destructive: true, action: delete)
                }
            }
        }
        .padding(16)
        .background(shape.fill(MainColor.card).shadow(color: Color(hex: 0x182C20).opacity(0.1), radius: 12, y: 8))
        .overlay(shape.strokeBorder(MainColor.panelBorder, lineWidth: 1))
    }

    private func section<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                MainKicker(title: title)
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(MainColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            content()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MainColor.panel))
    }
}

// MARK: - Last chosen for

/// The dictations this prompt was last chosen for: where each went, what was said, and
/// what came out.
private struct PromptRecentCard: View {
    let preset: PromptPreset
    let records: [TranscriptionRecord]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            MainKicker(title: "Last chosen for").padding(.horizontal, 4)
            VStack(spacing: 0) {
                if records.isEmpty {
                    Text("Not chosen yet. Say something that fits its “When to use” with \(shortcutText(for: .ai)), and it shows up here.")
                        .font(.system(size: 13))
                        .foregroundStyle(MainColor.ink2)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { MainRule() }
                    row(record)
                }
            }
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(MainColor.card))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(MainColor.panelBorder, lineWidth: 0.5))
        }
        .padding(10)
        .padding(.top, 4)
        .background(shape.fill(MainColor.panel))
        .background(shape.fill(MainColor.card))
    }

    private func row(_ record: TranscriptionRecord) -> some View {
        let entry = HomeRecentEntry(record)
        return HStack(alignment: .top, spacing: 12) {
            HomeEntryMark(entry: entry, size: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.deliveredText)
                    .font(.system(size: 13))
                    .foregroundStyle(MainColor.ink)
                    .lineLimit(2)
                    .lineSpacing(1.5)
                Text("from “\(record.text)”")
                    .font(.system(size: 12))
                    .foregroundStyle(MainColor.ink3)
                    .lineLimit(1)
                Text("\(entry.place) · \(entry.timeText())")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(MainColor.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - What else it is told

/// The page's close, across both columns: the two things every AI dictation carries
/// besides the prompt, as Home's tray of white tiles — each drawn: where the words are
/// going (the same words a chat message in Slack and a letter in Mail) and the
/// Dictionary's words, spelled as written.
private struct PromptsToldCard: View {
    let go: (MainPage) -> Void

    /// Under this the two tiles side by side squeeze their words into a narrow column, so
    /// they stack, each keeping its picture beside its words.
    private static let sideBySideWidth: CGFloat = 860

    var body: some View {
        let words = Vocabulary.hints(Vocabulary.load())
        let tiles = Group {
            cell(title: "Where you're dictating",
                 detail: "The app, its window and the field — so the same words become a chat message in Slack and a letter in Mail. Never a password manager's.") {
                PromptsPlacesPicture()
            }
            cell(title: "Your Dictionary",
                 detail: words.isEmpty ? "Names and terms you add there are spelled exactly as you write them."
                 : "\(words.count) \(words.count == 1 ? "word" : "words"), spelled exactly as you write them.",
                 link: ("Open Dictionary", { go(.dictionary) })) {
                PromptsWordsPicture(words: words)
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader("What else AI Rewrite is told", detail: "besides the prompt, with every AI dictation")
            // Decided by the width the tray is offered as it is laid out, not by a width
            // measured into state afterwards: that one stayed side by side in a narrow window.
            PromptsToldLayout(sideBySideWidth: Self.sideBySideWidth - 12, spacing: 6) { tiles }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MainColor.panel))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cell<Picture: View>(title: String, detail: String, link: (String, () -> Void)? = nil,
                                     @ViewBuilder picture: () -> Picture) -> some View {
        let picture = picture()
        return MainTile(padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 18)) {
            HStack(alignment: .center, spacing: 16) {
                picture
                    .frame(width: 176, height: 112)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MainColor.panel))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(MainColor.ink)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(MainColor.ink2)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    if let link {
                        HomeLink(title: link.0, action: link.1).padding(.leading, -8).padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The tiles side by side, as tall as the taller, from `sideBySideWidth`; one under the
/// other below it.
private struct PromptsToldLayout: Layout {
    let sideBySideWidth: CGFloat
    let spacing: CGFloat

    private func sideBySide(_ width: CGFloat) -> Bool { width >= sideBySideWidth }

    private func tileWidth(_ width: CGFloat, count: Int) -> CGFloat {
        (width - spacing * CGFloat(max(0, count - 1))) / CGFloat(max(1, count))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? sideBySideWidth
        if sideBySide(width) {
            let each = tileWidth(width, count: subviews.count)
            let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: each, height: nil)).height }.max() ?? 0
            return CGSize(width: width, height: height)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if sideBySide(bounds.width) {
            let each = tileWidth(bounds.width, count: subviews.count)
            for (index, subview) in subviews.enumerated() {
                subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (each + spacing), y: bounds.minY),
                              proposal: ProposedViewSize(width: each, height: bounds.height))
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
                y += height + spacing
            }
        }
    }
}

/// Slack's short line and Mail's letter, from the same words.
private struct PromptsPlacesPicture: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            place(app: "Slack", lines: [0.8, 0.45])
            place(app: "Mail", lines: [0.55, 0.95, 0.85, 0.6])
        }
        .accessibilityHidden(true)
    }

    private func place(app: String, lines: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HomeAppMark(app: app, size: 20, radius: 6)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, width in
                    Capsule().fill(MainColor.ink.opacity(0.13)).frame(width: 54 * width, height: 4)
                }
            }
        }
        .padding(9)
        .frame(width: 74, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MainColor.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MainColor.panelBorder, lineWidth: 0.5))
    }
}

/// The user's own words as chips — or, before there are any, the kind of word they are.
private struct PromptsWordsPicture: View {
    let words: [String]

    var body: some View {
        let shown = words.isEmpty ? ["SpeechText", "Olena", "JSON"] : Array(words.prefix(3))
        VStack(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, word in
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(MainColor.okInk)
                    Text(word).font(.system(size: 12, weight: .medium)).foregroundStyle(MainColor.ink).lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(MainColor.card))
                .overlay(Capsule().strokeBorder(MainColor.panelBorder, lineWidth: 0.5))
                .offset(x: CGFloat(index - 1) * 10)
                .opacity(words.isEmpty ? 0.55 : 1)
            }
        }
        .accessibilityHidden(true)
    }
}
