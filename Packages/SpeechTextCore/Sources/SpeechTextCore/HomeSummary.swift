// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// What the main window's Home says, worked out from History and the settings — pure, so
// the numbers and the intro card's animation are testable without a window.

// MARK: - The last 7 days

/// Home's week: what was dictated, the time it saved against typing, and roughly what the
/// speaking cost at the providers' list prices (`UsagePrices`) — then each day's words,
/// oldest first.
public struct HomeWeek: Equatable, Sendable {
    public struct Day: Equatable, Sendable {
        public let date: Date
        public let words: Int
        public let isToday: Bool
    }

    /// Words that ended up as text. An edit's instruction is a command, not text, and a
    /// failed or empty dictation produced none.
    public var words = 0
    public var dictations = 0
    /// Minutes of speech behind those words — first word to last, as Usage counts them.
    var speakingMinutes: Double = 0
    /// Typing the same words at `typingWordsPerMinute`, less the time spent saying them.
    public var savedMinutes: Double = 0
    var speechCost: Double = 0
    var aiCost: Double = 0
    /// AI passes this week priced from their words, not their tokens: written before the
    /// provider's usage was kept.
    var estimatedAIPasses = 0
    /// Cloud models used this week with no list price, by name, so `spent` leaves them
    /// out.
    public var unpricedModels: [String] = []
    public var days: [Day] = []

    public var spent: Double { speechCost + aiCost }

    /// An average typist, until the user sets their own speed (Usage › How this is
    /// counted).
    public static let typingWordsPerMinute = 40.0

    public init(records: [TranscriptionRecord], typingSpeed: Double = HomeWeek.typingWordsPerMinute,
         now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { return }
        var perDay = Array(repeating: 0, count: 7)
        var unpriced: [String] = []

        for record in records where record.date >= start && record.date <= now {
            dictations += 1
            let edit = record.refinement?.isSelectionEdit == true
            let cost = RecordCost(record)
            speechCost += cost.speech
            aiCost += cost.ai
            estimatedAIPasses += cost.estimatedAIPasses
            unpriced += cost.unpricedSpeech + cost.unpricedChat

            guard !edit, record.status == .success else { continue }
            let count = homeWordCount(record.deliveredText)
            words += count
            let speaking = (record.speakingDuration ?? record.duration) / 60
            speakingMinutes += speaking
            savedMinutes += max(0, Double(count) / typingSpeed - speaking)
            let day = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: record.date)).day ?? 0
            if (0..<7).contains(day) { perDay[day] += count }
        }

        var seen = Set<String>()
        unpricedModels = unpriced.filter { seen.insert($0).inserted }
        days = (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            return Day(date: date, words: perDay[offset], isToday: offset == 6)
        }
    }

    /// How many of `rows` dots a day's column lights: its share of the busiest day, never
    /// fewer than one for a day that has any words — the design's "a day is only as tall as
    /// its words".
    public func litRows(for day: Day, rows: Int) -> Int {
        let most = days.map(\.words).max() ?? 0
        guard day.words > 0, most > 0 else { return 0 }
        return max(1, Int((Double(day.words) / Double(most) * Double(rows)).rounded()))
    }
}

public func homeWordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
}

/// What Home and Usage price with: the list prices on the catalogues' descriptors
/// (`STTModelDescriptor.price`, `ChatModelDescriptor.price`), checked against the vendors'
/// pages on `checked` and refreshed by hand with a release (docs/prices.md). Every record
/// is priced at today's table from the units its ledger keeps — no price history, so an
/// update reprices everything — and every figure is shown as an estimate, never as the
/// vendor's bill. A model with no price is named, not guessed; one on the Mac is free.
public enum UsagePrices {
    /// When the table was last checked against every vendor's page.
    public static let checked = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 14)
    /// When every vendor's deprecations page was last read against both catalogues'
    /// `lifecycle` (docs/prices.md › Deprecations). Its own date: a price check and a
    /// deprecation check are separate passes.
    static let deprecationsChecked = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 16)

    /// "14 October 2026".
    public static var checkedText: String {
        let formatter = HistoryFormat.formatter("d MMMM yyyy", calendar: Calendar(identifier: .gregorian))
        return checked.date.map(formatter.string(from:)) ?? ""
    }

    /// The line beside every total: an estimate from the list prices the app knows, not the bill.
    /// The date they were checked is on Usage's How this is counted.
    public static var disclaimer: String { "estimated from known prices" }

    /// The speech model a ledger entry names.
    static func speech(vendor: Provider, model: String) -> ListPrice<SpeechRates> {
        sttModel(vendor: vendor, id: model).price
    }

    /// A record from before the ledger: its stored speech model, else its engine's — but
    /// only where every model of that engine costs the same, since which one ran is
    /// unknown and a price is never guessed.
    public static func speech(provider: String, model: String?) -> ListPrice<SpeechRates> {
        guard let engine = STTProviderType(rawValue: provider) else { return .notPriced }
        if let model { return speech(vendor: engine.vendor, model: model) }
        let prices = Set(knownSTTModels(of: engine.vendor).map(\.price))
        return prices.count == 1 ? prices.first! : .notPriced
    }

    /// A chat model's token prices, for the vendor a ledger entry names.
    static func chat(vendor: Provider, model: String) -> ListPrice<ChatRates> {
        if vendor == .ollama { return .free }
        guard let provider = LLMProviderType.allCases.first(where: { $0.vendor == vendor }) else { return .notPriced }
        return chatModel(provider: provider, id: model).price
    }

    /// A chat model's token prices, by `LLMProviderType` raw value and model ID.
    public static func chat(provider: String, model: String) -> ListPrice<ChatRates> {
        // A model Ollama ran on this Mac, recorded before AI Rewrite ran models itself.
        if provider == "ollama" { return .free }
        guard let provider = LLMProviderType(rawValue: provider) else { return .notPriced }
        return chatModel(provider: provider, id: model).price
    }

    /// The name Home and Usage give a model they could not price.
    static func speechName(vendor: Provider, model: String) -> String {
        plainModelName(sttModel(vendor: vendor, id: model).displayName)
    }

    static func chatName(provider: String, model: String) -> String {
        guard let provider = LLMProviderType(rawValue: provider) else { return model }
        return plainModelName(chatModel(provider: provider, id: model).displayName)
    }
}

/// A picker's model name without its note: "GPT-5.6 Luna — fastest" → "GPT-5.6 Luna",
/// "GPT-OSS 20B (fastest)" → "GPT-OSS 20B".
public func plainModelName(_ name: String) -> String {
    var name = name
    if let dash = name.range(of: " — ") { name = String(name[..<dash.lowerBound]) }
    if let paren = name.range(of: " (") { name = String(name[..<paren.lowerBound]) }
    return name
}

extension ListPrice {
    public var isFree: Bool { self == .free }

    /// The rates of a listed price; nil for a free model and an unpriced one.
    public var listed: Rates? {
        if case .listed(let rates) = self { rates } else { nil }
    }
}

extension SpeechRates {
    /// `seconds` of audio, with the keyterm surcharge when the request carried terms.
    func cost(seconds: Double, keyterms: Int?) -> Double {
        seconds / 60 * (perMinute + ((keyterms ?? 0) > 0 ? keytermSurchargePerMinute : 0))
    }
}

extension ChatRates {
    var isFree: Bool { inputPerToken == 0 && outputPerToken == 0 }

    /// Whether `cost(of:)` had to estimate this pass's price rather than count it.
    func isEstimate(_ refinement: TranscriptionRecord.Refinement) -> Bool {
        !isFree && refinement.usage == nil
    }

    /// What one LLM pass cost: the tokens the provider reported billing, else — for a
    /// pass recorded before they were kept — the estimate from its words. Home and
    /// Usage both price a pass through here, so they cannot disagree.
    func cost(of refinement: TranscriptionRecord.Refinement) -> Double {
        if let usage = refinement.usage { return cost(usage) }
        return cost(inputWords: homeWordCount(refinement.inputText),
                    outputWords: homeWordCount(refinement.outputText))
    }

    /// The cached input tokens at the cached price, the rest of the input and every
    /// output token at theirs. Anthropic's cache writes are in `inputTokens` at the base
    /// price, though billed at 1.25× — harmless only because no request sets
    /// `cache_control`, so there are none.
    func cost(_ usage: ChatUsage) -> Double {
        let cached = min(usage.cachedInputTokens ?? 0, usage.inputTokens)
        return Double(usage.inputTokens - cached) * inputPerToken + Double(cached) * cachedInputPerToken
            + Double(usage.outputTokens) * outputPerToken
    }

    /// The design's estimate: the routing prompt (~1,100 tokens) plus the words sent,
    /// and the words returned, at 1.4 tokens a word. Only for passes recorded before
    /// the reply's usage was kept: it misses the presets, the context and vocabulary
    /// blocks, any reasoning, and Cyrillic's heavier tokenisation.
    func cost(inputWords: Int, outputWords: Int) -> Double {
        (1_100 + Double(inputWords) * 1.4) * inputPerToken + Double(outputWords) * 1.4 * outputPerToken
    }
}

/// What one History record cost, worked out the one way Home and Usage both count it.
/// A record with a ledger (`usageEvents`) is priced from its entries alone — every
/// request it made, a fallback upload and a retry included, the vendor's billed seconds
/// where it reported them, each at its own model's price. One from before the ledger is
/// priced by its length at its speech model's price (`UsagePrices.speech(provider:model:)`),
/// and its AI pass from `ChatRates.cost(of:)`.
public struct RecordCost: Equatable, Sendable {
    public var speech: Double = 0
    public var ai: Double = 0
    /// Speech and chat models used here with no price, by the names the pages give them.
    public var unpricedSpeech: [String] = []
    public var unpricedChat: [String] = []
    /// AI passes priced from their words rather than their tokens.
    public var estimatedAIPasses = 0

    var total: Double { speech + ai }

    public init(_ record: TranscriptionRecord) {
        guard let events = record.usageEvents else {
            if record.hasSpeech {
                // An edit with no instruction heard nothing, so has nothing to price.
                switch UsagePrices.speech(provider: record.provider, model: record.sttModel) {
                case .free: break
                case .listed(let rates): speech = rates.cost(seconds: record.duration, keyterms: nil)
                case .notPriced:
                    unpricedSpeech.append(record.sttModel.flatMap { model in
                        STTProviderType(rawValue: record.provider).map { UsagePrices.speechName(vendor: $0.vendor, model: model) }
                    } ?? HistoryFormat.engine(record.provider))
                }
            }
            if let refinement = record.refinement { price(refinement) }
            return
        }
        for event in events {
            if !event.kind.isSpeech {
                let rates: ChatRates
                switch UsagePrices.chat(vendor: event.vendor, model: event.model) {
                case .free: continue
                case .notPriced:
                    unpricedChat.append(chatName(vendor: event.vendor, model: event.model))
                    continue
                case .listed(let listed): rates = listed
                }
                if let tokens = event.tokens {
                    ai += rates.cost(tokens)
                } else if event.succeeded, let refinement = record.refinement {
                    // Answered, but its provider reported no tokens: the words are all
                    // there is to go on.
                    ai += rates.cost(inputWords: homeWordCount(refinement.inputText),
                                     outputWords: homeWordCount(refinement.outputText))
                    estimatedAIPasses += 1
                }
            } else if let seconds = event.billedSeconds ?? event.audioSeconds,
                      // A refused upload is not taken as billed (`UsageMeter.event`); a
                      // socket was used whatever became of its answer.
                      event.succeeded || event.kind == .stream {
                switch UsagePrices.speech(vendor: event.vendor, model: event.model) {
                case .free: break
                case .listed(let rates): speech += rates.cost(seconds: seconds, keyterms: event.keyterms)
                case .notPriced: unpricedSpeech.append(UsagePrices.speechName(vendor: event.vendor, model: event.model))
                }
            }
        }
    }

    private func chatName(vendor: Provider, model: String) -> String {
        LLMProviderType.allCases.first { $0.vendor == vendor }
            .map { UsagePrices.chatName(provider: $0.rawValue, model: model) } ?? model
    }

    private mutating func price(_ refinement: TranscriptionRecord.Refinement) {
        switch UsagePrices.chat(provider: refinement.provider, model: refinement.model) {
        case .free: break
        case .notPriced: unpricedChat.append(UsagePrices.chatName(provider: refinement.provider, model: refinement.model))
        case .listed(let rates):
            ai += rates.cost(of: refinement)
            if rates.isEstimate(refinement) { estimatedAIPasses += 1 }
        }
    }
}

// MARK: - Formatting

public enum HomeFormat {
    /// "1,234" — in English whatever the Mac's region, as everything else on the pages is.
    public static func integer(_ value: Int) -> String {
        integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Made once: every filter's count, day and popover row asks for one each time it is
    /// drawn, and a formatter is costly to build. Its locale is fixed, so nothing the user
    /// changes can leave it out of date.
    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    /// "52 min", "1 h 5 min", "2 h".
    public static func duration(minutes: Double) -> (hours: Int?, minutes: Int?) {
        let total = Int(minutes.rounded())
        guard total >= 60 else { return (nil, total) }
        let rest = total % 60
        return (total / 60, rest == 0 ? nil : rest)
    }

    public static func durationText(minutes: Double) -> String {
        let (h, m) = duration(minutes: minutes)
        return [h.map { "\($0) h" }, m.map { "\($0) min" }].compactMap { $0 }.joined(separator: " ")
    }

    public static func money(_ value: Double) -> String {
        if value <= 0 { return "$0" }
        if value < 0.01 { return "<$0.01" }
        if value >= 100 { return "$" + integer(Int(value.rounded())) }
        return String(format: "$%.2f", value)
    }

    /// A cost said as the estimate it is: "≈ $1.20" — "$0" stays exact.
    public static func estimate(_ value: Double) -> String {
        value > 0 ? "≈ " + money(value) : money(value)
    }
}

// MARK: - Recent

/// One row of Home's Recent and of History: what was said, where it went and when, and
/// what rewrote it.
public struct HomeRecentEntry: Equatable, Identifiable, Sendable {
    public enum Tag: Equatable, Sendable {
        case preset(String)
        case edit
        /// AI Rewrite or an edit did not work: the dictated text was pasted, or the
        /// selection left as it was.
        case rewriteFailed
        case failed
    }

    public let id: UUID
    public let text: String
    /// The app the text went to; nil when History does not know (the Record Window, a
    /// dictation that pasted nothing, and entries from before the stop recorded it).
    public let app: String?
    let date: Date
    public let status: TranscriptionRecord.Status
    public let tags: [Tag]
    public let canRetry: Bool

    public init(_ record: TranscriptionRecord) {
        id = record.id
        date = record.date
        status = record.status
        let edit = record.refinement?.isSelectionEdit == true
        switch record.status {
        case .success:
            // An edit that failed left the selection as it was — that is the text it is about.
            if edit, let refinement = record.refinement, !refinement.succeeded {
                text = refinement.inputText
            } else {
                text = record.deliveredText
            }
        case .empty:
            text = "Nothing was heard."
        case .failed:
            text = record.errorMessage ?? "Transcription failed."
        }
        app = Self.app(of: record)
        var tags: [Tag] = []
        if edit {
            tags.append(.edit)
        } else if let refinement = record.refinement, refinement.succeeded, let preset = refinement.presetName {
            tags.append(.preset(preset))
        }
        if let refinement = record.refinement, !refinement.succeeded { tags.append(.rewriteFailed) }
        if record.status == .failed { tags.append(.failed) }
        self.tags = tags
        canRetry = record.isRetryable
    }

    /// The text as a row shows it: every run of whitespace — a paragraph break above all —
    /// one space, so a letter's "Hi Amie!" and blank line do not leave the row's second
    /// line empty. `text` keeps the line breaks for Copy.
    public var preview: String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Where the row says the text went: its app, the Record Window for a success that
    /// names none — or that nothing was pasted.
    public var place: String { Self.place(app: app, status: status) }

    /// `place` of a record, without the rest of its row — History narrows by it and Usage
    /// counts by it for every record, and the row's text and tags were worked out for nothing.
    public static func place(of record: TranscriptionRecord) -> String {
        place(app: app(of: record), status: record.status)
    }

    private static func app(of record: TranscriptionRecord) -> String? {
        record.destinationApp ?? record.refinement?.context?.appName ?? record.originApp
    }

    private static func place(app: String?, status: TranscriptionRecord.Status) -> String {
        app ?? (status == .success ? "Record Window" : "Not pasted")
    }

    /// "14:02" today, "Yesterday", a weekday within the week, a date before that.
    public func timeText(now: Date = Date(), calendar: Calendar = .current) -> String {
        Self.relativeDay(date, now: now, calendar: calendar)
    }

    /// `timeText` for any date.
    public static func relativeDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let format: String
        if calendar.isDate(date, inSameDayAs: now) {
            format = "HH:mm"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                                     to: calendar.startOfDay(for: now)).day, days < 7 {
            format = "EEEE"
        } else {
            format = "d MMM"
        }
        // Made once per format and calendar, as History's own are.
        return HistoryFormat.formatter(format, calendar: calendar).string(from: date)
    }
}

// MARK: - The intro card's picture

/// The intro card's picture, as a function of time: one dictation playing out on a loop —
/// the overlay hears it word by word, then the stop pastes it, once, into a message
/// (rewritten first on the AI tab; on the Edit tab a selection is replaced by what the
/// instruction asked for). Its phases, the comet while AI works and the one paste at the
/// stop are the design's approved animation. The keys press one after another, quickly,
/// and with hold to talk the modifiers are let go while the letter stays down — changed at
/// the owner's call on 2026-10-12, so the card teaches what the hold tip does.
public struct HomeTalk: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, hear, work, done }
    public enum Mode: Equatable, Sendable { case dictate, ai, edit }

    public struct Script: Equatable, Sendable {
        public let app: String
        public let place: String
        let said: [String]
        public let output: String
        /// The preset the rewrite reports, shown beside the pasted text.
        public let preset: String?
        /// The text selected before an edit, which its output replaces.
        var selection: String? = nil
    }

    static let dictate = Script(
        app: "Slack", place: "#design",
        said: "Let's move the call to Thursday at three — I'll send the agenda tonight so everyone has a look before we meet".split(separator: " ").map(String.init),
        output: "Let's move the call to Thursday at three — I'll send the agenda tonight so everyone has a look before we meet.",
        preset: nil)

    static let ai = Script(
        app: "Mail", place: "To: Olena",
        said: "uh email to Olena running late start without me sorry".split(separator: " ").map(String.init),
        output: "Hi Olena, I'm running a few minutes late — please start without me. Sorry!",
        preset: "Email / Message")

    static let edit = Script(
        app: "Notes", place: "Trip plan",
        said: "make it sound more sure".split(separator: " ").map(String.init),
        output: "Let's go on Friday — it works for everyone.",
        preset: nil,
        selection: "i think maybe we could go on friday if thats ok for everyone")

    /// One tick is 100 ms.
    public static let tickSeconds = 0.1

    public let script: Script
    let mode: Mode
    public let phase: Phase
    /// Words heard so far.
    public let heard: Int
    /// Which of the shortcut's caps are down, by index — the modifiers first, the letter
    /// last, as the caps are drawn.
    public let litKeys: Set<Int>

    /// The text goes to AI — a rewrite or an edit; the overlay is violet.
    public var isAI: Bool { mode != .dictate }
    public var isEdit: Bool { mode == .edit }
    /// Every key is down.
    var keysDown: Bool { !litKeys.isEmpty }

    public init(tick: Int, mode: Mode, holdToTalk: Bool, keyCount: Int = 3) {
        let script = switch mode { case .dictate: Self.dictate; case .ai: Self.ai; case .edit: Self.edit }
        let idle = 8, hear = script.said.count * 4, work = mode == .dictate ? 3 : 14, show = 30
        let k = tick % (idle + hear + work + show)
        let phase: Phase = k < idle ? .idle : k < idle + hear ? .hear : k < idle + hear + work ? .work : .done
        self.script = script
        self.mode = mode
        self.phase = phase
        heard = switch phase {
        case .idle: 0
        case .hear: (k - idle) / 4 + 1
        case .work, .done: script.said.count
        }
        litKeys = Self.keys(at: k, idle: idle, hear: hear, holdToTalk: holdToTalk, count: keyCount)
    }

    /// The keys go down one after another, a tick apart, the letter last and just as the
    /// overlay starts listening. With hold to talk the modifiers come up shortly after —
    /// only the letter has to stay down — and the letter at the stop; otherwise the whole
    /// shortcut is tapped at the start and again at the stop.
    static func keys(at k: Int, idle: Int, hear: Int, holdToTalk: Bool, count: Int) -> Set<Int> {
        let count = max(1, min(count, idle))
        let letter = count - 1
        let pressed = idle - letter
        let stop = idle + hear
        func cascade(from start: Int, until end: Int) -> Set<Int> {
            guard k >= start, k < end else { return [] }
            return Set((0..<count).filter { k >= start + $0 })
        }
        if holdToTalk {
            let modifiersUp = idle + 4
            if k < modifiersUp { return cascade(from: pressed, until: modifiersUp) }
            return k < stop ? [letter] : []
        }
        return cascade(from: pressed, until: idle + 2).union(cascade(from: stop - count, until: stop))
    }

    /// The transcript on the overlay's glass: the settled words, then the last two — the
    /// partial the engine may still take back — while it is hearing.
    public var settled: String {
        let words = script.said.prefix(heard)
        let cut = phase == .hear ? max(0, words.count - 2) : words.count
        return words.prefix(cut).joined(separator: " ")
    }

    public var partial: String {
        guard phase == .hear else { return "" }
        let words = script.said.prefix(heard)
        return words.suffix(from: max(0, words.count - 2)).joined(separator: " ")
    }

    /// What the transcript glass holds: nothing before the first word (it has no height
    /// until then, as the overlay's has none), the words — kept while AI Rewrite works,
    /// with the comet on the display saying it is busy — and, once the text has landed,
    /// where it went, as the overlay says it for a few seconds after the paste.
    public enum Caption: Equatable, Sendable { case hidden, words, pasted }

    public var caption: Caption {
        switch phase {
        case .idle: .hidden
        case .hear, .work: .words
        case .done: .pasted
        }
    }

    /// What the message holds: the selection waiting to be edited, nothing but the caret
    /// (before a paste, and once an edit's instruction is over and the selection is cut),
    /// or the text pasted.
    public enum Message: Equatable, Sendable {
        case caret, pasted
        case selection(String)
    }

    public var message: Message {
        if phase == .done { return .pasted }
        if let selection = script.selection, phase != .work { return .selection(selection) }
        return .caret
    }

    /// The dot matrix — `PixelDisplayMode`, which this file cannot name: the voice while
    /// it hears, the comet while AI Rewrite works, at rest before and after.
    public enum Display: Equatable, Sendable { case idle, level, busy }

    public var display: Display {
        phase == .hear ? .level : phase == .work && isAI ? .busy : .idle
    }
}
