// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import SpeechTextCore

// MARK: - Dictionary

/// The main window's Dictionary, in Home's language, one column: a word added in one step —
/// with the spellings it comes out as, if the user knows them, and a line saying what the
/// word will do as it is typed — and the names and terms History suggests right under;
/// then the words, four tiles to a row, that open to edit; then what a word does with the
/// engine in use. The logic is `Vocabulary`.
struct DictionaryView: View {
    let actions: MainWindowActions

    @State private var entries: [VocabularyEntry] = Vocabulary.load()
    @State private var newTerm = ""
    @State private var newSpellings = ""
    @State private var editing: UUID?
    @State private var showsAllWords = false
    /// What History says — suggestions, each word's uses — worked out again only when it
    /// changes, not on every keystroke in the fields below.
    @State private var historyCache = VocabularyHistoryCache()

    /// Three rows of four; the rest behind Show all.
    private static let wordsShown = 12

    private var history: TranscriptionHistory { .shared }

    var body: some View {
        // Read here, so the page follows History; worked through only when it changed.
        historyCache.refresh(from: history.records)
        return GeometryReader { proxy in
            ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    MainPageTitle(.dictionary)
                    adder(suggestions: historyCache.suggestions(excluding: entries))
                    words()
                    DictionaryReplacements()
                    DictionaryEffects(entries: entries)
                    HStack(spacing: 6) {
                        Image(systemName: "lock")
                        Text("Words are kept on this Mac. One reaches the speech engine or AI Rewrite only with a dictation — never on its own.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(MainColor.ink3)
                }
                .frame(maxWidth: HomeView.columnWidth)
                .padding(.horizontal, 48)
                .padding(.top, 32)
                .padding(.bottom, 44)
                .frame(width: proxy.size.width)
                .id("top")
            }
            .scrollIndicators(.automatic)
            .onAppear {
                // A window opened straight onto this page focuses a field, which scrolls the
                // page; it opens at its top, nothing focused.
                DispatchQueue.main.async {
                    if let window = NSApp.keyWindow, window.firstResponder is NSText {
                        window.makeFirstResponder(nil)
                    }
                    scroller.scrollTo("top", anchor: .top)
                }
            }
            }
        }
    }

    // MARK: Adding

    /// One step, read as a sentence: the word as it should be written, and — only if it
    /// comes out wrong — how it comes out. Under the fields, what the word will do, said
    /// as it is typed; Return in either field adds it. What History suggests sits under
    /// that, one click each.
    private func adder(suggestions: [(term: String, count: Int)]) -> some View {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        let spellings = parsedSpellings
        return VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader("Add a word")
            MainPanel(padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .bottom, spacing: 12) {
                        field("Word", optional: false) {
                            MainTextField(placeholder: "e.g. SpeechText", text: $newTerm, height: 36, fill: MainColor.card) { add() }
                        }
                        .frame(maxWidth: 260)
                        field("Often comes out as", optional: true) {
                            MainTextField(placeholder: example, text: $newSpellings, height: 36, fill: MainColor.card) { add() }
                        }
                        Button { add() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus").font(.system(size: 10.5, weight: .bold))
                                Text("Add word")
                            }
                        }
                        .buttonStyle(SetupButtonStyle(kind: .primary, height: 36))
                        .disabled(term.isEmpty)
                        .pointingHandCursor()
                    }
                    preview(term: term, spellings: spellings)
                }
            }
            if !suggestions.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Suggested from your dictations")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(MainColor.ink2)
                        .fixedSize()
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions, id: \.term) { suggestion in
                            DictionarySuggestionChip(term: suggestion.term, count: suggestion.count) {
                                add(term: suggestion.term)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func field<Content: View>(_ title: String, optional: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(MainColor.ink)
                if optional { Text("optional").font(.system(size: 12)).foregroundStyle(MainColor.ink3) }
            }
            content()
        }
        .frame(maxWidth: .infinity)
    }

    /// What adding the word will do, said before it is added: the spellings it puts
    /// right, or — with none — that the engines and AI Rewrite are told the word.
    private func preview(term: String, spellings: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: term.isEmpty ? "info.circle" : "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(term.isEmpty ? MainColor.ink3 : MainColor.okInk)
            Group {
                if term.isEmpty {
                    Text("Write the word the way it should appear. If SpeechText spells it wrong, add how it comes out — each of those will be replaced by it.")
                } else if spellings.isEmpty {
                    Text("“\(term)” will be given to the speech engine and AI Rewrite, so they spell it your way.")
                } else {
                    spellings.map { Text("“\($0)”").strikethrough(color: MainColor.ink3) }
                        .enumerated()
                        .reduce(Text(verbatim: "")) { text, item in text + (item.offset > 0 ? Text(", ") : Text(verbatim: "")) + item.element }
                        + Text(" will become ") + Text(term).fontWeight(.semibold).foregroundColor(MainColor.ink)
                        + Text(" in everything you dictate.")
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(MainColor.ink2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeOut(duration: 0.12), value: term.isEmpty)
    }

    private var parsedSpellings: [String] {
        newSpellings.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The word's own split into halves is the usual mishearing of a compound. Any other word has
    /// no mishearing to guess, and an invented one ("Man" → "mans") would be a real word replaced
    /// everywhere if copied, so the field only says what goes in it.
    private var example: String {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return "e.g. speech text, спіч текст" }
        let split = term.replacingOccurrences(of: #"(?<=\p{Ll})(?=\p{Lu})"#, with: " ", options: .regularExpression)
        return split != term ? "e.g. " + split.lowercased() : "how it comes out wrong — commas between"
    }

    private func add(term raw: String? = nil) {
        let term = (raw ?? newTerm).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let spellings = raw == nil ? parsedSpellings : []
        if raw == nil {
            newTerm = ""
            newSpellings = ""
        }
        withAnimation(.easeOut(duration: 0.2)) {
            if let index = entries.firstIndex(where: { $0.trimmedTerm.caseInsensitiveCompare(term) == .orderedSame }) {
                // A word already taught takes the new spellings rather than a second entry.
                for spelling in spellings where !entries[index].misheard.contains(where: {
                    $0.caseInsensitiveCompare(spelling) == .orderedSame }) {
                    entries[index].misheard.append(spelling)
                }
            } else {
                entries.insert(VocabularyEntry(term: term, misheard: spellings), at: 0)
            }
        }
        Vocabulary.save(entries)
    }

    // MARK: The words

    @ViewBuilder
    private func words() -> some View {
        let folded = !showsAllWords && entries.count > Self.wordsShown + 2
        let shown = folded ? Array(entries.prefix(Self.wordsShown)) : entries
        VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader("Your words", detail: entries.isEmpty ? nil : "\(entries.count)")
            if entries.isEmpty {
                MainEmptyNote {
                    Text("No words yet.").fontWeight(.semibold).foregroundStyle(MainColor.ink)
                    Text("Add the names and terms SpeechText gets wrong — a colleague's name, your product, a code identifier — and how they come out instead. They're put right after every dictation.")
                }
            } else {
                VStack(spacing: 0) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: 4),
                              spacing: 6) {
                        ForEach(shown) { entry in
                            DictionaryWordTile(entry: binding(entry.id), uses: historyCache.uses(of: entry),
                                               isEditing: Binding(get: { editing == entry.id },
                                                                  set: { editing = $0 ? entry.id : nil }),
                                               delete: { delete(entry.id) })
                        }
                    }
                    if entries.count > Self.wordsShown + 2 {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { showsAllWords.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Text(folded ? "Show all · \(entries.count - shown.count) more" : "Show fewer")
                                Image(systemName: folded ? "chevron.down" : "chevron.up").font(.system(size: 9.5, weight: .bold))
                            }
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(MainColor.ink2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .padding(.top, 4)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MainColor.panel))
            }
        }
    }

    private func binding(_ id: UUID) -> Binding<VocabularyEntry> {
        Binding(
            get: { entries.first { $0.id == id } ?? VocabularyEntry(term: "") },
            set: { value in
                guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
                entries[index] = value
                Vocabulary.save(entries)
            })
    }

    private func delete(_ id: UUID) {
        editing = nil
        withAnimation(.easeOut(duration: 0.18)) {
            entries.removeAll { $0.id == id }
        }
        Vocabulary.save(entries)
    }
}

// MARK: - A word

/// A word as a white tile: how it is spelled, how often History has it, and the spellings
/// it replaces, struck through. Clicked, it opens to edit in a popover.
private struct DictionaryWordTile: View {
    @Binding var entry: VocabularyEntry
    let uses: Int
    @Binding var isEditing: Bool
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        Button { isEditing = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.trimmedTerm.isEmpty ? "Untitled" : entry.trimmedTerm)
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(MainColor.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if uses > 0 {
                        Text("\(uses)×")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(MainColor.ink2)
                            .monospacedDigit()
                            .help("In \(uses) \(uses == 1 ? "dictation" : "dictations") History keeps")
                    }
                }
                spellings
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(shape.fill(MainColor.card).shadow(color: Color(hex: 0x182C20).opacity(hovering ? 0.1 : 0.05),
                                                          radius: hovering ? 4 : 1, y: 1))
            .overlay(shape.strokeBorder(isEditing ? MainColor.okInk.opacity(0.5) : MainColor.panelBorder,
                                        lineWidth: isEditing ? 1.5 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            DictionaryWordEditor(entry: $entry, delete: delete)
        }
        .contextMenu {
            Button("Edit…") { isEditing = true }
            Button("Delete “\(entry.trimmedTerm)”", action: delete)
        }
    }

    @ViewBuilder
    private var spellings: some View {
        let replacements = entry.replacements
        if replacements.isEmpty {
            Text(entry.fixesCapitals ? "Its capitals are put back as written" : "Given to the engine and AI Rewrite")
                .font(.system(size: 12))
                .foregroundStyle(MainColor.ink3)
        } else {
            FlowLayout(spacing: 5) {
                ForEach(replacements.prefix(4), id: \.self) { spelling in
                    Text(spelling)
                        .font(.system(size: 11.5))
                        .strikethrough(color: MainColor.ink3)
                        .foregroundStyle(MainColor.ink2)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(MainColor.panel))
                        .fixedSize()
                }
                if replacements.count > 4 {
                    Text("+\(replacements.count - 4)").font(.system(size: 11.5)).foregroundStyle(MainColor.ink3).frame(height: 20)
                }
            }
        }
    }
}

/// The word open for editing: its spelling, the spellings it replaces, and Delete.
private struct DictionaryWordEditor: View {
    @Binding var entry: VocabularyEntry
    let delete: () -> Void
    @State private var newSpelling = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                MainKicker(title: "Spelled")
                MainTextField(placeholder: "The word, as it should be written", text: $entry.term, height: 32)
            }
            VStack(alignment: .leading, spacing: 6) {
                MainKicker(title: "Comes out as")
                Text("Each is replaced by the word, as a whole word, whatever its capitals.")
                    .font(.system(size: 12))
                    .foregroundStyle(MainColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.misheard.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(entry.misheard.enumerated()), id: \.offset) { index, spelling in
                            HStack(spacing: 4) {
                                Text(spelling).font(.system(size: 12, weight: .medium)).foregroundStyle(MainColor.ink)
                                Button {
                                    entry.misheard.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(MainColor.ink3)
                                        .frame(width: 14, height: 14)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove “\(spelling)”")
                            }
                            .padding(.leading, 9)
                            .padding(.trailing, 4)
                            .frame(height: 24)
                            .background(Capsule().fill(MainColor.panel))
                            .overlay(Capsule().strokeBorder(MainColor.panelBorder, lineWidth: 1))
                        }
                    }
                }
                MainTextField(placeholder: "Add a spelling, then Return", text: $newSpelling, symbol: "plus", height: 30) {
                    addSpelling()
                }
            }
            HStack {
                Spacer()
                HistoryQuietButton(title: "Delete word", symbol: "trash", destructive: true, action: delete)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func addSpelling() {
        let spellings = newSpelling.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for spelling in spellings where !entry.misheard.contains(where: { $0.caseInsensitiveCompare(spelling) == .orderedSame }) {
            entry.misheard.append(spelling)
        }
        newSpelling = ""
    }
}

// MARK: - Replacements

/// Replace / With pairs, as macOS's own Text Replacements lays them out: the entry row,
/// then the pairs, newest first. Unlike a word they reach no engine and no prompt — they
/// only correct the final text (`TextReplacementRules`).
private struct DictionaryReplacements: View {
    @State private var pairs: [TextReplacementPair] = TextReplacements.load()
    @State private var replace = ""
    @State private var with = ""
    @State private var problem: TextReplacements.EntryProblem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader("Replacements", detail: pairs.isEmpty ? nil : "\(pairs.count)")
            MainPanel(padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Write something your way whenever it is said — “кома” as “,”, “mail sign” as your signature. Whole words, any capitals. Unlike a word above, a replacement isn't sent to the engine or AI Rewrite; it only puts the text right.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(MainColor.ink2)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        MainTextField(placeholder: "Replace", text: $replace, height: 36, fill: MainColor.card) { add() }
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MainColor.ink3)
                        MainTextField(placeholder: "With", text: $with, height: 36, fill: MainColor.card) { add() }
                        Button { add() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus").font(.system(size: 10.5, weight: .bold))
                                Text("Add")
                            }
                        }
                        .buttonStyle(SetupButtonStyle(kind: .secondary, height: 36))
                        .disabled(replace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || with.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .pointingHandCursor()
                    }
                    .onChange(of: replace) { problem = nil }
                    .onChange(of: with) { problem = nil }
                    if let problem {
                        Text(message(for: problem))
                            .font(.system(size: 12.5))
                            .foregroundStyle(SetupColor.warn)
                    }
                    if !pairs.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(pairs.reversed().enumerated()), id: \.element.id) { index, pair in
                                if index > 0 { MainRule() }
                                row(pair)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ pair: TextReplacementPair) -> some View {
        HStack(spacing: 10) {
            Text(pair.replace)
                .strikethrough(color: MainColor.ink3)
                .foregroundStyle(MainColor.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MainColor.ink3)
            Text(pair.with)
                .fontWeight(.medium)
                .foregroundStyle(MainColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                remove(pair)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(MainColor.ink3)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove “\(pair.replace)”")
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.vertical, 9)
    }

    private func add() {
        if let found = TextReplacements.entryProblem(replace: replace, with: with, existing: pairs) {
            problem = found
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            pairs.append(TextReplacements.normalized(replace: replace, with: with))
        }
        TextReplacements.save(pairs)
        replace = ""
        with = ""
    }

    private func remove(_ pair: TextReplacementPair) {
        withAnimation(.easeOut(duration: 0.18)) { pairs.removeAll { $0.id == pair.id } }
        TextReplacements.save(pairs)
    }

    private func message(for problem: TextReplacements.EntryProblem) -> String {
        switch problem {
        case .emptyReplace: "Type what is recognized now."
        case .emptyWith: "Type how it should be written."
        case .noWord: "Replace needs at least one letter or digit."
        case .duplicate: "That already has a replacement."
        }
    }
}

// MARK: - What a word does

/// The three things a word does, each said for the engine and AI provider in use — so the
/// page never promises a hint an engine is not given. Home's hairline table; a step that
/// does nothing with the engine in use is greyed. The first row carries the one switch
/// that sends the words to the speech engine, and says how many the selected model takes
/// — counted by the same functions that build the request.
private struct DictionaryEffects: View {
    let entries: [VocabularyEntry]

    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = STTProviderType.apple.rawValue
    @AppStorage(SettingsKeys.groqModel) private var groqModel = Provider.groq.defaultSpeechModel
    @AppStorage(SettingsKeys.elevenLabsModel) private var elevenLabsModel = Provider.elevenLabs.defaultSpeechModel
    @AppStorage(SettingsKeys.openAISTTModel) private var openAISTTModel = Provider.openAI.defaultSpeechModel
    @AppStorage(SettingsKeys.localSTTModel) private var localSTTModel = Provider.local.defaultSpeechModel
    @AppStorage(SettingsKeys.sendVocabularyToEngine) private var sends = true
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = LLMProviderType.groq.rawValue
    @AppStorage(SettingsKeys.localLLMModel) private var localLLMModel = Provider.local.defaultChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader("What a word does")
            MainTable {
                row(symbol: "waveform", title: engine.title, detail: engine.detail, on: sends && engine.on) {
                    Toggle("Tell the speech engine", isOn: $sends)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .help("Send your words to the speech engine with every dictation")
                }
                MainRule()
                row(symbol: "arrow.left.arrow.right", title: "Wrong spellings are replaced",
                    detail: "With the Replacements, in what every engine writes before it's pasted or rewritten, in AI Rewrite's and Edit's replies, and in History.", on: true)
                MainRule()
                row(symbol: "sparkles", title: "AI Rewrite keeps them as written",
                    detail: aiReady ? "It's given your words with every AI dictation and told to spell them your way."
                    : "Once AI Rewrite has a provider, it's given your words with every AI dictation.",
                    on: aiReady, ai: true)
            }
        }
    }

    private var aiReady: Bool {
        _ = (llmProvider, localLLMModel)
        return LLMConfiguration.isConfigured
    }

    private var provider: STTProviderType { STTProviderType(rawValue: sttProvider) ?? .apple }

    /// The speech model the current choices select.
    private var model: STTModelDescriptor {
        let id = switch provider {
        case .apple: appleSpeechModelID
        case .groq: groqModel
        case .elevenlabs: elevenLabsModel
        case .openai: openAISTTModel
        case .local: localSTTModel
        }
        return sttModel(vendor: provider.vendor, id: id)
    }

    private var engine: (title: String, detail: String, on: Bool) {
        let terms = CustomVocabulary.ranked(entries, now: Date(), rankByUse: false, historyTexts: { [] })
        let vendor = model.vendor.displayName
        guard sends else {
            return ("The speech engine isn't told them",
                    "Turned off. Wrong spellings are still replaced, and AI Rewrite still keeps them as written.", false)
        }
        if let limits = model.vocabulary.limits {
            let title = provider == .apple ? "Apple's recognizer listens for them" : "\(vendor) is given them"
            var detail = Self.count(sent: CustomVocabulary.selected(terms, limits: limits).count,
                                    of: terms.count, model: model.displayName)
            if let surcharge = model.price.listed?.keytermSurchargePerMinute, surcharge > 0 {
                detail += " \(vendor) charges about \(HomeFormat.money(surcharge * 60)) an hour more for a transcription that carries them."
            }
            return (title, detail, true)
        }
        switch provider {
        case .groq:
            return ("Groq's Whisper is given them as a hint",
                    Self.count(sent: Vocabulary.whisperPromptTerms(terms).count, of: terms.count, model: model.displayName)
, true)
        case .local:
            return ("The model on this Mac isn't given them",
                    "Local models take no list of words — the replacements still put them right.", false)
        default:
            return ("\(model.displayName) isn't given them",
                    "It takes no list of words — the replacements still put them right. GPT Transcribe and GPT Live Transcribe do.", false)
        }
    }

    /// "All 12 go to GPT Transcribe…" or "50 of 73 …", with what decides which.
    private static func count(sent: Int, of total: Int, model: String) -> String {
        if total == 0 { return "Your words go to \(model) with every dictation." }
        if sent == total { return "All \(total) go to \(model) with every dictation." }
        return "\(sent) of \(total) go to \(model) — it takes no more. The ones you use most, and anything added this week, go first."
    }

    private func row(symbol: String, title: String, detail: String, on: Bool, ai: Bool = false) -> some View {
        row(symbol: symbol, title: title, detail: detail, on: on, ai: ai) { EmptyView() }
    }

    private func row<Control: View>(symbol: String, title: String, detail: String, on: Bool, ai: Bool = false,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(!on ? MainColor.ink3 : ai ? MainColor.aiInk : MainColor.okInk)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(on ? MainColor.ink : MainColor.ink2)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(MainColor.ink2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

// MARK: - A suggestion

private struct DictionarySuggestionChip: View {
    let term: String
    let count: Int
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: add) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? MainColor.okInk : MainColor.ink3)
                Text(term).font(.system(size: 12.5, weight: .medium)).foregroundStyle(MainColor.ink)
                Text("\(count)×").font(.system(size: 11)).foregroundStyle(MainColor.ink3).monospacedDigit()
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(hovering ? MainColor.phosphorSoft : MainColor.card))
            .overlay(Capsule().strokeBorder(hovering ? MainColor.okInk.opacity(0.4) : MainColor.panelBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add “\(term)” — used in \(count) dictations")
    }
}

// MARK: - Flow

/// Chips laid out as words are: along the line, onto the next when it is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
