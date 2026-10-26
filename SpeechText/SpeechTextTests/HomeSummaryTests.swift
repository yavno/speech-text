// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SpeechTextCore

/// The main window's Home: the week it counts from History, the Recent rows, and the
/// intro card's approved animation — built from records made here, never the user's own.
final class HomeSummaryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return calendar
    }()

    /// Wednesday 30 September 2026, 15:00 in Kyiv.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15))!

    private func record(daysAgo: Int = 0, text: String = "one two three four", duration: TimeInterval = 6,
                        status: TranscriptionRecord.Status = .success, provider: String = "groq",
                        refinement: TranscriptionRecord.Refinement? = nil, app: String? = nil) -> TranscriptionRecord {
        TranscriptionRecord(id: UUID(), date: calendar.date(byAdding: .day, value: -daysAgo, to: now)!,
                            text: text, status: status, errorMessage: status == .failed ? "Offline" : nil,
                            provider: provider, locale: "uk", duration: duration,
                            refinement: refinement, destinationApp: app)
    }

    private func refinement(input: String = "hello there", output: String = "Hello there.",
                            model: String = "claude-sonnet-5", provider: String = "anthropic",
                            preset: String? = "Email / Message", edit: Bool = false) -> TranscriptionRecord.Refinement {
        TranscriptionRecord.Refinement(inputText: input, outputText: output, presetName: preset,
                                       provider: provider, model: model, editsSelection: edit)
    }

    // MARK: The week

    func testTheWeekCountsTheLastSevenDaysOnly() {
        let week = HomeWeek(records: [record(), record(daysAgo: 6), record(daysAgo: 7)], now: now, calendar: calendar)
        XCTAssertEqual(week.dictations, 2)
        XCTAssertEqual(week.words, 8)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.last?.isToday, true)
        XCTAssertEqual(week.days.first?.words, 4, "six days ago is the week's first day")
    }

    func testAnEditsInstructionAndAFailureAreNotWords() {
        let week = HomeWeek(records: [
            record(text: "make it shorter", refinement: refinement(edit: true)),
            record(status: .failed),
            record(text: "a b c"),
        ], now: now, calendar: calendar)
        XCTAssertEqual(week.dictations, 3)
        XCTAssertEqual(week.words, 3)
    }

    func testTheWordsCountedAreTheOnesDelivered() {
        let week = HomeWeek(records: [record(text: "uh email olena", refinement: refinement(output: "Hi Olena, sorry I'm late."))],
                            now: now, calendar: calendar)
        XCTAssertEqual(week.words, 5)
    }

    func testTimeSavedIsTypingTheWordsLessSayingThem() {
        // 80 words: two minutes at 40 wpm, said in half a minute.
        let text = Array(repeating: "word", count: 80).joined(separator: " ")
        let week = HomeWeek(records: [record(text: text, duration: 30)], now: now, calendar: calendar)
        XCTAssertEqual(week.savedMinutes, 1.5, accuracy: 0.0001)
        XCTAssertEqual(week.speakingMinutes, 0.5, accuracy: 0.0001)
    }

    func testSpentPricesWhatItKnowsAndNamesWhatItDoesNot() {
        var turbo = record(duration: 60, provider: "groq")
        turbo.sttModel = "whisper-large-v3-turbo"
        var minimax = record(duration: 60, provider: "local",
                             refinement: refinement(model: "minimaxai/minimax-m2.7", provider: "groq"))
        minimax.sttModel = "parakeet-tdt-0.6b-v3"
        let week = HomeWeek(records: [
            turbo,
            minimax,
            record(duration: 60, provider: "groq"),
            record(duration: 60, provider: "openai", refinement: refinement(model: "gpt-9", provider: "openai")),
        ], now: now, calendar: calendar)
        XCTAssertEqual(week.speechCost, 0.04 / 60, accuracy: 1e-9)
        XCTAssertEqual(week.aiCost, 0)
        XCTAssertEqual(week.unpricedModels, ["MiniMax M2.7", "Groq", "OpenAI", "gpt-9"],
                       "named as the pages name them: a model with no list price, an engine whose models differ "
                       + "and the record named none, an ID the catalogue does not list")
    }

    func testAnOllamaRewriteCostsNothing() {
        let week = HomeWeek(records: [record(provider: "apple", refinement: refinement(model: "gemma4:12b", provider: "ollama"))],
                            now: now, calendar: calendar)
        XCTAssertEqual(week.spent, 0)
        XCTAssertTrue(week.unpricedModels.isEmpty)
    }

    func testADayIsOnlyAsTallAsItsWords() {
        let week = HomeWeek(records: [
            record(text: Array(repeating: "w", count: 120).joined(separator: " ")),
            record(daysAgo: 1, text: "w"),
        ], now: now, calendar: calendar)
        XCTAssertEqual(week.litRows(for: week.days[6], rows: 12), 12)
        XCTAssertEqual(week.litRows(for: week.days[5], rows: 12), 1, "a day with any words lights at least one row")
        XCTAssertEqual(week.litRows(for: week.days[0], rows: 12), 0)
    }

    func testDurationsAndMoney() {
        XCTAssertEqual(HomeFormat.durationText(minutes: 52.4), "52 min")
        XCTAssertEqual(HomeFormat.durationText(minutes: 65), "1 h 5 min")
        XCTAssertEqual(HomeFormat.durationText(minutes: 120), "2 h")
        XCTAssertEqual(HomeFormat.money(0), "$0")
        XCTAssertEqual(HomeFormat.money(0.004), "<$0.01")
        XCTAssertEqual(HomeFormat.money(0.2), "$0.20")
        XCTAssertEqual(HomeFormat.estimate(1.2), "≈ $1.20")
        XCTAssertEqual(HomeFormat.estimate(0), "$0", "nothing spent is exact")
        XCTAssertEqual(HomeFormat.integer(2831), "2,831")
    }

    // MARK: Recent

    func testARecentRowSaysWhereItWentAndWhatRewroteIt() {
        let entry = HomeRecentEntry(record(app: "Slack").withRefinement(refinement()))
        XCTAssertEqual(entry.text, "Hello there.")
        XCTAssertEqual(entry.app, "Slack")
        XCTAssertEqual(entry.tags, [.preset("Email / Message")])
        XCTAssertEqual(entry.timeText(now: now, calendar: calendar), "15:00")
    }

    func testAnEditIsMarkedAsOneAndAFailureSaysWhy() {
        XCTAssertEqual(HomeRecentEntry(record(refinement: refinement(edit: true))).tags, [.edit])
        let failed = HomeRecentEntry(record(status: .failed))
        XCTAssertEqual(failed.text, "Offline")
        XCTAssertEqual(failed.tags, [.failed])
    }

    // MARK: The intro card's picture

    func testThePictureHearsThenPastesOnce() {
        let words = HomeTalk.dictate.said.count
        XCTAssertEqual(HomeTalk(tick: 0, mode: .dictate, holdToTalk: false).phase, .idle)
        XCTAssertEqual(HomeTalk(tick: 0, mode: .dictate, holdToTalk: false).caption, .hidden,
                       "no glass before the first word — the overlay says no Listening…")
        let hearing = HomeTalk(tick: 8 + 4 * 5, mode: .dictate, holdToTalk: false)
        XCTAssertEqual(hearing.phase, .hear)
        XCTAssertEqual(hearing.heard, 6)
        XCTAssertEqual(hearing.partial.split(separator: " ").count, 2, "the last two words are the partial")
        XCTAssertEqual(HomeTalk(tick: 8 + 4 * words, mode: .dictate, holdToTalk: false).caption, .words)
        let done = HomeTalk(tick: 8 + 4 * words + 3, mode: .dictate, holdToTalk: false)
        XCTAssertEqual(done.phase, .done)
        XCTAssertEqual(done.caption, .pasted)
        XCTAssertEqual(done.display, .idle)
        // …and loops.
        XCTAssertEqual(HomeTalk(tick: 8 + 4 * words + 3 + 30, mode: .dictate, holdToTalk: false).phase, .idle)
    }

    func testTheAITabRewritesBeforeItPastes() {
        let words = HomeTalk.ai.said.count
        let work = HomeTalk(tick: 8 + 4 * words + 5, mode: .ai, holdToTalk: false)
        XCTAssertEqual(work.phase, .work)
        XCTAssertEqual(work.caption, .words, "the words stay while AI works; the comet says it is busy")
        XCTAssertEqual(work.display, .busy)
        XCTAssertEqual(HomeTalk(tick: 8 + 4 * words + 14, mode: .ai, holdToTalk: false).phase, .done)
    }

    func testTheKeysGoDownOneAfterAnotherAndTapWithoutHoldToTalk() {
        let words = HomeTalk.dictate.said.count
        let middle = 8 + 2 * words
        func lit(_ tick: Int, hold: Bool = false) -> Set<Int> {
            HomeTalk(tick: tick, mode: .dictate, holdToTalk: hold).litKeys
        }
        XCTAssertEqual(lit(5), [])
        XCTAssertEqual(lit(6), [0], "⌃ first")
        XCTAssertEqual(lit(7), [0, 1], "then ⇧")
        XCTAssertEqual(lit(8), [0, 1, 2], "the letter last, as the overlay starts listening")
        XCTAssertEqual(lit(middle), [])
        XCTAssertEqual(lit(8 + 4 * words - 3), [0], "pressed again to stop, key by key")
        XCTAssertEqual(lit(8 + 4 * words - 1), [0, 1, 2])
        XCTAssertEqual(lit(8 + 4 * words), [])
    }

    func testWithHoldToTalkOnlyTheLetterStaysDown() {
        let words = HomeTalk.dictate.said.count
        func lit(_ tick: Int) -> Set<Int> { HomeTalk(tick: tick, mode: .dictate, holdToTalk: true).litKeys }
        XCTAssertEqual(lit(8), [0, 1, 2])
        XCTAssertEqual(lit(11), [0, 1, 2])
        XCTAssertEqual(lit(12), [2], "⌃⇧ let go, the letter held")
        XCTAssertEqual(lit(8 + 2 * words), [2])
        XCTAssertEqual(lit(8 + 4 * words), [], "let go at the stop")
        XCTAssertEqual(HomeTalk(tick: 9, mode: .dictate, holdToTalk: true, keyCount: 4).litKeys, [0, 1, 2, 3])
        XCTAssertEqual(HomeTalk(tick: 13, mode: .dictate, holdToTalk: true, keyCount: 4).litKeys, [3])
    }

    func testTheEditTabReplacesTheSelectionAndNeverPastesTheInstruction() {
        let words = HomeTalk.edit.said.count
        let hearing = HomeTalk(tick: 8 + 4, mode: .edit, holdToTalk: false)
        XCTAssertTrue(hearing.isAI && hearing.isEdit)
        XCTAssertEqual(hearing.message, .selection(HomeTalk.edit.selection!), "the selection stays while the instruction is spoken")
        let work = HomeTalk(tick: 8 + 4 * words + 5, mode: .edit, holdToTalk: false)
        XCTAssertEqual(work.caption, .words)
        XCTAssertEqual(work.message, .caret, "cut once the instruction is over")
        let done = HomeTalk(tick: 8 + 4 * words + 14, mode: .edit, holdToTalk: false)
        XCTAssertEqual(done.message, .pasted)
        XCTAssertFalse(HomeTalk.edit.output.contains(HomeTalk.edit.said.joined(separator: " ")))
    }
}

private extension TranscriptionRecord {
    func withRefinement(_ refinement: Refinement) -> TranscriptionRecord {
        var copy = self
        copy.refinement = refinement
        return copy
    }
}

/// The list prices on the catalogues: every model has one or says it has none, and the
/// table is written out here, so a refreshed price is a deliberate two-line change
/// (docs/prices.md).
final class ListPriceTests: XCTestCase {
    /// Dollars a minute, and the keyterm surcharge a minute.
    private let speech: [String: (Double, Double)] = [
        "groq/whisper-large-v3-turbo": (0.04 / 60, 0),
        "groq/whisper-large-v3": (0.111 / 60, 0),
        "elevenLabs/scribe_v2": (0.22 / 60, 0.05 / 60),
        "elevenLabs/scribe_v2_realtime": (0.39 / 60, 0.08 / 60),
        "openAI/gpt-transcribe": (0.0045, 0),
        "openAI/gpt-4o-mini-transcribe": (0.003, 0),
        "openAI/gpt-live-transcribe": (0.017, 0),
    ]

    /// Dollars per million tokens: input, cached input, output; nil for not priced.
    private let chat: [String: (Double, Double, Double)?] = [
        "groq/openai/gpt-oss-120b": (0.15, 0.075, 0.60),
        "groq/openai/gpt-oss-20b": (0.075, 0.0375, 0.30),
        "groq/qwen/qwen3.8-27b": (0.80, 0.40, 4.00),
        "groq/minimaxai/minimax-m2.7": nil,
        "anthropic/claude-sonnet-5": (2, 0.20, 10),
        "anthropic/claude-opus-5": (5, 0.50, 25),
        "anthropic/claude-haiku-4-5": (1, 0.10, 5),
        "anthropic/claude-sonnet-5-5": (2, 0.10, 10),
        "anthropic/claude-opus-5-5": (4, 0.20, 20),
        "anthropic/claude-haiku-5-5": (0.10, 0.01, 0.50),
        "openai/gpt-5.6-luna": (0.20, 0.02, 1.20),
        "openai/gpt-5.6-terra": (2, 0.20, 12),
        "openai/gpt-5.6-sol": (4, 0.40, 20),
        "openai/gpt-6-luna": (0.10, 0.01, 0.50),
        "openai/gpt-6-sol": (2, 0.20, 10),
        "openai/gpt-6.1-sol": (2, 0.10, 10),
    ]

    func testEverySpeechModelIsPricedFreeOrSaysItIsNot() {
        for model in sttModelCatalog {
            let key = "\(model.vendor.rawValue)/\(model.id)"
            switch model.vendor {
            case .apple, .local:
                XCTAssertEqual(model.price, .free, "\(key) runs on the Mac")
            default:
                guard let expected = speech[key] else { return XCTFail("\(key) has no row here: add its price") }
                guard case .listed(let rates) = model.price else { return XCTFail("\(key) is not priced") }
                XCTAssertEqual(rates.perMinute, expected.0, accuracy: 1e-12, key)
                XCTAssertEqual(rates.keytermSurchargePerMinute, expected.1, accuracy: 1e-12, key)
            }
        }
        let cloud = sttModelCatalog.filter { ![.apple, .local].contains($0.vendor) }
        XCTAssertEqual(Set(cloud.map { "\($0.vendor.rawValue)/\($0.id)" }), Set(speech.keys), "a row for a model that is gone")
    }

    func testEveryChatModelIsPricedFreeOrSaysItIsNot() {
        for model in chatModelCatalog {
            let key = "\(model.provider.rawValue)/\(model.id)"
            if model.provider == .local {
                XCTAssertEqual(model.price, .free, "\(key) runs on the Mac")
                continue
            }
            guard let row = chat[key] else { XCTFail("\(key) has no row here: add its price"); continue }
            guard let expected = row else {
                XCTAssertEqual(model.price, .notPriced, "\(key) is written down as not priced")
                continue
            }
            guard case .listed(let rates) = model.price else { XCTFail("\(key) is not priced"); continue }
            XCTAssertEqual(rates.inputPerToken * 1e6, expected.0, accuracy: 1e-9, key)
            XCTAssertEqual(rates.cachedInputPerToken * 1e6, expected.1, accuracy: 1e-9, key)
            XCTAssertEqual(rates.outputPerToken * 1e6, expected.2, accuracy: 1e-9, key)
            XCTAssertLessThanOrEqual(rates.cachedInputPerToken, rates.inputPerToken, key)
        }
        let cloud = chatModelCatalog.filter { $0.provider != .local }
        XCTAssertEqual(Set(cloud.map { "\($0.provider.rawValue)/\($0.id)" }), Set(chat.keys), "a row for a model that is gone")
    }

    /// An ID the catalogue does not list is never charged at another model's rate.
    func testAnUnlistedModelIsNotPricedUnlessItRunsOnTheMac() {
        XCTAssertEqual(UsagePrices.speech(vendor: .groq, model: "whisper-next"), .notPriced)
        XCTAssertEqual(UsagePrices.speech(vendor: .local, model: "some-local-model"), .free)
        XCTAssertEqual(UsagePrices.chat(provider: "anthropic", model: "claude-next"), .notPriced)
        XCTAssertEqual(UsagePrices.chat(provider: "ollama", model: "llama9:1b"), .free)
        XCTAssertEqual(UsagePrices.chat(vendor: .ollama, model: "gemma4:12b"), .free)
        XCTAssertEqual(UsagePrices.chat(provider: "local", model: "gemma-4-12b-it-qat-q4_0"), .free)
        XCTAssertEqual(UsagePrices.chat(vendor: .local, model: "some-local-model"), .free)
        XCTAssertEqual(UsagePrices.chat(provider: "not-a-provider", model: "x"), .notPriced)
        XCTAssertEqual(UsagePrices.speech(provider: "not-an-engine", model: nil), .notPriced)
        XCTAssertEqual(UsagePrices.speech(provider: "apple", model: nil), .free)
    }

    func testTheTableSaysWhenItWasChecked() {
        XCTAssertEqual(UsagePrices.checkedText, "26 October 2026")
        XCTAssertEqual(UsagePrices.disclaimer, "estimated from known prices")
    }
}

/// History's and Usage's pages work out what they show once per change instead of on every
/// redraw: the search folded once a record, the days, the counts and Usage's summary kept
/// until History, the search, the filter, the narrowing, the period, the typing speed or
/// the day changes, and the formatters made once. Each is held here to what the code it
/// replaced gave — copied below as it was, in `Before` — over generated records, never the
/// user's own.
final class HistoryAndUsageCacheTests: XCTestCase {
    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private let kyiv = calendar("Europe/Kyiv")
    /// Brazil's clocks went forward at midnight on 4 November 2018, so that day began at 01:00.
    private let saoPaulo = calendar("America/Sao_Paulo")
    private let losAngeles = calendar("America/Los_Angeles")

    /// Wednesday 30 September 2026, 15:00 in Kyiv; a week after the midnight that was skipped
    /// in São Paulo.
    private func now(in calendar: Calendar) -> Date {
        calendar.timeZone.identifier == "America/Sao_Paulo"
            ? calendar.date(from: DateComponents(year: 2018, month: 11, day: 10, hour: 12))!
            : calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15))!
    }

    private static let queries = [
        "", "  ", "зустріч", "ЗУСТРІЧ", "олена", "Олена п'ятниця", "п’ятниця", "їжак", "ИЖАК", "cafe", "CAFÉ", "café",
        "cafe\u{301}", "résumé", "naive", "zurich", "straße", "strasse", "STRASSE", "ss", "s", "ß", "file", "fi", "ﬁ",
        "👍", "👍🏽", "नमस", "नमस्ते", "οδος", "ΟΔΌΣ", "da", "nang", "会議", "회의", "lodz", "istanbul", "slack", "mail",
        "email", "Clean-up", "connection", "Ошибка", "ошибка", "x", "\u{301}", "ガ", "№", "№5", "✓", "☕", "notfoundanywhere",
    ]

    private func narrowings(_ records: [TranscriptionRecord], calendar: Calendar) -> [HistoryNarrowing] {
        let picked = [records[3].date, records[records.count / 2].date,
                      calendar.date(from: DateComponents(year: 2018, month: 11, day: 4, hour: 9))!]
        return [HistoryNarrowing(), HistoryNarrowing(app: "Slack"), HistoryNarrowing(app: "Not pasted"),
                HistoryNarrowing(app: "Record Window"), HistoryNarrowing(app: "Café ☕"),
                HistoryNarrowing(dates: .today), HistoryNarrowing(dates: .last7Days), HistoryNarrowing(dates: .last30Days),
                HistoryNarrowing(app: "Mail", dates: .last30Days)]
            + picked.map { HistoryNarrowing(dates: .day($0)) }
    }

    // MARK: History's page

    func testTheListingIsWhatTheDaysAndTheCountsWere() {
        for calendar in [kyiv, saoPaulo] {
            let now = now(in: calendar)
            let records = GeneratedHistory.records(count: 260, now: now, calendar: calendar, seed: 7)
            var cases: [(HistoryFilter, String, HistoryNarrowing)] = Self.queries.map { (.all, $0, HistoryNarrowing()) }
            for filter in HistoryFilter.allCases {
                for narrowing in narrowings(records, calendar: calendar) {
                    for query in ["", "зустріч", "CAFE", "s"] { cases.append((filter, query, narrowing)) }
                }
            }
            let cache = HistoryListingCache()
            for (filter, query, narrowing) in cases {
                let days = Before.group(records, filter: filter, query: query, narrowing: narrowing, now: now, calendar: calendar)
                let counts = Before.counts(records, query: query, narrowing: narrowing, now: now, calendar: calendar)
                let label = "\(calendar.timeZone.identifier) \(filter) “\(query)” \(narrowing)"
                let listing = HistoryListing(records: records, filter: filter, query: query, narrowing: narrowing,
                                             now: now, calendar: calendar)
                XCTAssertEqual(listing.days, days, label)
                XCTAssertEqual(listing.counts, counts, label)
                let cached = cache.listing(records: records, filter: filter, query: query, narrowing: narrowing,
                                           now: now, calendar: calendar)
                XCTAssertEqual(cached, listing, "kept between keystrokes: " + label)
                XCTAssertEqual(HistoryDay.group(records, filter: filter, query: query, narrowing: narrowing,
                                                now: now, calendar: calendar), days, label)
            }
            XCTAssertGreaterThan(Set(records.map { calendar.startOfDay(for: $0.date) }).count, 100, "the records span many days")
        }
    }

    /// The day a record belongs to is found once a day, not once a record — under a day that
    /// began at 01:00 too, and for records out of order, which start a day of their own.
    func testDaysAreGroupedAsTheyWere() {
        let calendar = saoPaulo
        let skipped = calendar.date(from: DateComponents(year: 2018, month: 11, day: 4, hour: 1))!
        XCTAssertEqual(calendar.startOfDay(for: skipped.addingTimeInterval(3600)), skipped, "the day began at 01:00")
        let hours: [Double] = [30, 29, 26, 25, 23.5, 23, 22, 6, 5, 2, 1, 0.5, 0, -0.5, -1, -2, -20, -23, -24, -25, -48]
        var records = hours.map { GeneratedHistory.record(at: skipped.addingTimeInterval($0 * 3600)) }
        records.swapAt(3, 9)
        records.append(GeneratedHistory.record(at: skipped.addingTimeInterval(28 * 3600)))
        XCTAssertEqual(HistoryDay.group(records, calendar: calendar), Before.group(records, now: skipped, calendar: calendar))
        XCTAssertGreaterThan(HistoryDay.group(records, calendar: calendar).count,
                             Set(records.map { calendar.startOfDay(for: $0.date) }).count, "a record out of order starts a day")
    }

    func testTheSearchFindsWhatItFound() {
        let records = GeneratedHistory.records(count: 400, now: now(in: kyiv), calendar: kyiv, seed: 11)
        let texts = HistorySearch.Index().texts(for: records)
        XCTAssertTrue(texts.contains { $0.folded == nil } && texts.contains { $0.folded != nil },
                      "some records are searched folded, some as before")
        for query in Self.queries {
            let search = HistorySearch.Query(query)
            for (record, text) in zip(records, texts) {
                let before = Before.matches(record, query: query)
                XCTAssertEqual(HistorySearch.matches(record, query: query), before, "“\(query)” in “\(record.text)”")
                XCTAssertEqual(search.matches(text), before, "“\(query)” in “\(record.text)”, kept")
            }
        }
    }

    /// A seeded sample of what `foldsFaithfully` was measured on: random texts and words
    /// drawn from its table, accents on letters, decomposed and capitalised.
    func testTheFoldedSearchAgreesWithTheOriginalOverItsTable() {
        var generator = SeededGenerator(seed: 2026)
        let alphabet = GeneratedHistory.tableAlphabet
        let marks = (0x300...0x36F).filter { $0 != 0x345 }.compactMap { Unicode.Scalar(UInt32($0)) }
        var compared = 0
        for index in 0..<40_000 {
            var text = String.UnicodeScalarView()
            for _ in 0..<Int.random(in: 1...10, using: &generator) {
                text.append(index % 3 == 0 && Bool.random(using: &generator)
                    ? marks.randomElement(using: &generator)! : alphabet.randomElement(using: &generator)!)
            }
            var word = String.UnicodeScalarView()
            if index % 2 == 0 {
                let scalars = Array(text)
                let start = Int.random(in: 0..<scalars.count, using: &generator)
                word.append(contentsOf: scalars[start..<min(scalars.count, start + Int.random(in: 1...3, using: &generator))])
            } else {
                for _ in 0..<Int.random(in: 1...3, using: &generator) { word.append(alphabet.randomElement(using: &generator)!) }
            }
            var haystack = String(text), needle = String(word)
            switch index % 6 {
            case 1: needle = needle.uppercased()
            case 2: haystack = haystack.uppercased()
            case 3: needle = needle.decomposedStringWithCanonicalMapping
            case 4: haystack = haystack.decomposedStringWithCanonicalMapping
            default: break
            }
            guard !needle.isEmpty, !needle.contains(where: \.isWhitespace),
                  HistorySearch.foldsFaithfully(haystack), HistorySearch.foldsFaithfully(needle) else { continue }
            let record = GeneratedHistory.record(at: Date(timeIntervalSince1970: 0), text: haystack)
            let searched = HistorySearch.Text(record)
            XCTAssertNotNil(searched.folded)
            let expected = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            XCTAssertEqual(HistorySearch.Query(needle).matches(searched), expected,
                           "\(needle.debugDescription) in \(haystack.debugDescription)")
            compared += 1
        }
        XCTAssertGreaterThan(compared, 20_000)
    }

    func testWhatFallsOutsideTheTableIsSearchedAsBefore() {
        let cases: [(text: String, word: String)] = [
            ("Straße", "s"), ("Straße", "ss"), ("Straße", "strasse"), ("Sп", "ß"), ("рß2", "S"), ("ﬃ", "ff"),
            ("👍🏽 great", "👍"), ("नमस्ते", "नमस"), ("नमस्ते", "नमस्त"), ("ガ", "カ\u{3099}"), ("ガ", "カ"),
            ("Ⱥ\u{337}\u{34D}", "Ⱥ\u{34D}"), ("\u{301}abc", "abc"), ("\u{345}α", "ι"),
        ]
        for (text, word) in cases {
            XCTAssertFalse(HistorySearch.foldsFaithfully(text) && HistorySearch.foldsFaithfully(word), "\(text) / \(word)")
            let record = GeneratedHistory.record(at: Date(timeIntervalSince1970: 0), text: text)
            XCTAssertEqual(HistorySearch.matches(record, query: word), Before.matches(record, query: word), "\(text) / \(word)")
        }
        // A field after the first that opens with an accent sends the whole record the old way.
        var record = GeneratedHistory.record(at: Date(timeIntervalSince1970: 0), text: "plain")
        record.destinationApp = "\u{301}Slack"
        XCTAssertNil(HistorySearch.Text(record).folded)
        XCTAssertNotNil(HistorySearch.Text(GeneratedHistory.record(at: Date(timeIntervalSince1970: 0), text: "Café")).folded)
    }

    func testTheKeptListingFollowsEveryChange() {
        let calendar = kyiv, now = now(in: kyiv)
        var records = GeneratedHistory.records(count: 120, now: now, calendar: calendar, seed: 3)
        let cache = HistoryListingCache()
        func check(_ label: String, query: String = "cafe", filter: HistoryFilter = .all) {
            XCTAssertEqual(cache.listing(records: records, filter: filter, query: query, narrowing: HistoryNarrowing(),
                                         now: now, calendar: calendar),
                           HistoryListing(records: records, filter: filter, query: query, now: now, calendar: calendar),
                           label)
            XCTAssertEqual(cache.listing(records: records, filter: filter, query: query, narrowing: HistoryNarrowing(),
                                         now: now, calendar: calendar).days,
                           Before.group(records, filter: filter, query: query, now: now, calendar: calendar), label)
        }
        check("first")
        check("again")
        records[5].text += " cafe"
        check("what was said, changed")
        records[9] = records[9].withRefinement(TranscriptionRecord.Refinement(
            inputText: records[9].text, outputText: "Café later", presetName: "Notes", provider: "groq", model: "openai/gpt-oss-120b"))
        check("a rewrite attached")
        records[12].destinationApp = "CAFE bar"
        check("the app it went to, changed")
        records.remove(at: 2)
        check("one deleted")
        records.insert(GeneratedHistory.record(at: now, text: "café au lait"), at: 0)
        check("one added")
        check("another search", query: "лист")
        check("another filter", filter: .rewritten)
        check("no search", query: "")
        // The kept answer is the same one while nothing changed.
        let first = cache.listing(records: records, filter: .all, query: "cafe", narrowing: HistoryNarrowing(), now: now, calendar: calendar)
        XCTAssertEqual(cache.listing(records: records, filter: .all, query: "cafe", narrowing: HistoryNarrowing(),
                                     now: now.addingTimeInterval(60), calendar: calendar), first)
        // A new day counts "Today" from it.
        let tomorrow = now.addingTimeInterval(86_400)
        XCTAssertEqual(cache.listing(records: records, filter: .all, query: "", narrowing: HistoryNarrowing(dates: .today),
                                     now: tomorrow, calendar: calendar).days,
                       Before.group(records, narrowing: HistoryNarrowing(dates: .today), now: tomorrow, calendar: calendar))
    }

    func testAPlaceIsWhatTheRowSaysAndTheAppsAreCountedAsBefore() {
        let records = GeneratedHistory.records(count: 400, now: now(in: kyiv), calendar: kyiv, seed: 5)
        for record in records { XCTAssertEqual(HomeRecentEntry.place(of: record), HomeRecentEntry(record).place) }
        XCTAssertEqual(HistoryNarrowing.apps(in: records).map { "\($0.app) \($0.count)" },
                       Before.apps(in: records).map { "\($0.app) \($0.count)" })
        XCTAssertTrue(Set(records.map(HomeRecentEntry.place(of:))).isSuperset(of: ["Not pasted", "Record Window", "Slack"]))
    }

    func testTheDatesAreWhatTheyWere() {
        for calendar in [kyiv, saoPaulo, losAngeles] {
            let now = now(in: calendar)
            let ranges: [HistoryDates] = HistoryDates.presets + [
                .day(now), .day(now.addingTimeInterval(-3 * 86_400 - 3_600)),
                .day(calendar.date(from: DateComponents(year: 2018, month: 11, day: 4, hour: 13))!),
                .day(calendar.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 2))!),
            ]
            for range in ranges {
                let matcher = range.matcher(now: now, calendar: calendar)
                for hour in stride(from: -24.0 * 40, through: 24 * 2, by: 0.75) {
                    let date = now.addingTimeInterval(hour * 3600)
                    let before = Before.includes(range, date, now: now, calendar: calendar)
                    XCTAssertEqual(matcher(date), before, "\(range) \(date) \(calendar.timeZone.identifier)")
                    XCTAssertEqual(range.includes(date, now: now, calendar: calendar), before)
                }
                // Around the days the clocks moved in Brazil, Ukraine and California.
                let moved = [DateComponents(year: 2018, month: 11, day: 4, hour: 12), DateComponents(year: 2026, month: 3, day: 29, hour: 12),
                             DateComponents(year: 2026, month: 3, day: 8, hour: 12)].compactMap(calendar.date(from:))
                for day in moved {
                    for hour in stride(from: -36.0, through: 36, by: 0.25) {
                        let date = day.addingTimeInterval(hour * 3600)
                        XCTAssertEqual(matcher(date), Before.includes(range, date, now: now, calendar: calendar),
                                       "\(range) \(date) \(calendar.timeZone.identifier)")
                    }
                }
            }
        }
    }

    // MARK: Usage

    func testTheKeptUsageSummaryIsTheSummary() {
        let calendar = kyiv, now = now(in: kyiv)
        var records = GeneratedHistory.records(count: 300, now: now, calendar: calendar, seed: 13)
        let cache = UsageSummaryCache()
        func check(_ label: String, typing: Double = 40, at time: Date? = nil) {
            for period in UsagePeriod.allCases {
                XCTAssertEqual(cache.summary(records: records, period: period, typingWordsPerMinute: typing,
                                             now: time ?? now, calendar: calendar),
                               UsageSummary(records: records, period: period, typingWordsPerMinute: typing,
                                            now: time ?? now, calendar: calendar), "\(label), \(period)")
            }
        }
        check("first")
        check("again")
        check("another typing speed", typing: 72)
        records[4].text = "a few more words than before"
        check("a record changed")
        records.removeFirst()
        check("one deleted")
        check("the next day", at: now.addingTimeInterval(86_400))
        XCTAssertGreaterThan(UsageSummary(records: records, period: .all, now: now, calendar: calendar).apps.count, 3)
    }

    // MARK: Rows

    func testTheRowFitsKeepTheLastFewWidths() {
        var fits = HistoryRowFits()
        let ids = (0..<20).map { _ in UUID() }
        for width in 300...899 {
            for (index, id) in ids.enumerated() { fits[id, width] = index.isMultiple(of: 2) }
        }
        XCTAssertEqual(fits.count, HistoryRowFits.widthsKept * ids.count, "a resize through 600 widths keeps only the last few")
        XCTAssertEqual(fits[ids[0], 899], true)
        XCTAssertEqual(fits[ids[1], 896], false)
        XCTAssertNil(fits[ids[0], 895])
        XCTAssertNil(fits[ids[0], 300])
        // Answering at a width already kept keeps the others.
        fits[UUID(), 896] = true
        XCTAssertEqual(fits[ids[0], 896], true)
        XCTAssertEqual(fits.count, HistoryRowFits.widthsKept * ids.count + 1)
    }

    // MARK: Formatting

    func testTheFormattersSayWhatTheyDid() {
        for value in [Int.min + 1, -1_234_567, -1, 0, 7, 999, 1_000, 2_831, 1_234_567, Int.max] {
            XCTAssertEqual(HomeFormat.integer(value), Before.integer(value))
        }
        XCTAssertEqual(UsagePrices.checkedText, Before.checkedText)
        // Two calendars in turn, so a formatter kept for one is never used for the other.
        let now = now(in: kyiv)
        for hour in stride(from: -24.0 * 12, through: 30, by: 1.5) {
            let date = now.addingTimeInterval(hour * 3600)
            for calendar in [kyiv, losAngeles, saoPaulo] {
                XCTAssertEqual(HomeRecentEntry.relativeDay(date, now: now, calendar: calendar),
                               Before.relativeDay(date, now: now, calendar: calendar), "\(date) \(calendar.timeZone.identifier)")
            }
        }
        let yesterday = Date().addingTimeInterval(-86_400)
        XCTAssertEqual(HomeRecentEntry.relativeDay(yesterday, now: now, calendar: kyiv),
                       Before.relativeDay(yesterday, now: now, calendar: kyiv))
    }

    // MARK: At 20,000 records

    /// What the pages paid before they kept what they work out, and pay now, at the History a
    /// few years of dictations reach (it is kept forever unless the user chose otherwise).
    /// Printed, never asserted; `SPEECHTEXT_PERF=1` runs it.
    func testTimingsAtTwentyThousandRecords() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPEECHTEXT_PERF"] == "1",
                          "set SPEECHTEXT_PERF=1 to time History and Usage at scale")
        let calendar = Calendar.current, now = Date()
        let records = GeneratedHistory.records(count: 20_000, now: now, calendar: calendar, seed: 1, everyday: true)
        var lines: [String] = []
        func report(_ label: String, _ milliseconds: Double) {
            lines.append(label.padding(toLength: 64, withPad: " ", startingAt: 0) + String(format: "%9.1f ms", milliseconds))
        }

        // History: one key typed in the search, as the body ran before — the days, the
        // counts and the app list, each searching every record.
        for query in ["cafe", "зустріч", "Олена звіт", "straße"] {
            report("History, a key typed (“\(query)”), before", timed {
                _ = Before.group(records, query: query, now: now, calendar: calendar)
                _ = Before.counts(records, query: query, narrowing: HistoryNarrowing(), now: now, calendar: calendar)
                _ = Before.apps(in: records)
            })
            let cache = HistoryListingCache()
            report("  now: the first key, folding every record once", timed {
                _ = cache.listing(records: records, filter: .all, query: String(query.prefix(2)), narrowing: HistoryNarrowing())
            })
            report("  now: each key after it", timed {
                _ = cache.listing(records: records, filter: .all, query: query, narrowing: HistoryNarrowing())
            })
            report("  now: a redraw with nothing changed (a row opened)", timed {
                _ = cache.listing(records: records, filter: .all, query: query, narrowing: HistoryNarrowing())
            })
        }
        // A record holding a character outside the folding table — an emoji, say — is
        // searched as before: one in twenty of them.
        var emoji = records
        for index in stride(from: 0, to: emoji.count, by: 20) { emoji[index].text += " 👍" }
        let mixed = HistoryListingCache()
        _ = mixed.listing(records: emoji, filter: .all, query: "ca", narrowing: HistoryNarrowing())
        report("  now: each key, one record in twenty with an emoji (“cafe”)", timed {
            _ = mixed.listing(records: emoji, filter: .all, query: "cafe", narrowing: HistoryNarrowing())
        })
        // A dictation landing while a search is open: its record folded, the rest kept.
        let open = HistoryListingCache()
        _ = open.listing(records: records, filter: .all, query: "cafe", narrowing: HistoryNarrowing())
        var landed = records
        landed.insert(GeneratedHistory.record(at: now, text: "Новий запис про каву"), at: 0)
        report("  now: a dictation landing while a search is open", timed {
            _ = open.listing(records: landed, filter: .all, query: "cafe", narrowing: HistoryNarrowing())
        })
        report("History, no search, before", timed {
            _ = Before.group(records, now: now, calendar: calendar)
            _ = Before.counts(records, query: "", narrowing: HistoryNarrowing(), now: now, calendar: calendar)
            _ = Before.apps(in: records)
        })
        report("  now: worked out (a filter switched)", timed {
            _ = HistoryListingCache().listing(records: records, filter: .rewritten, query: "", narrowing: HistoryNarrowing())
        })
        report("History, the app list (now only in its popover), before", timed { _ = Before.apps(in: records) })
        report("  now", timed { _ = HistoryNarrowing.apps(in: records) })

        // Usage: the summary, worked out on every body before.
        let usage = UsageSummaryCache()
        for period in [UsagePeriod.month, .all] {
            report("Usage (\(period.title)), every redraw before", timed {
                _ = UsageSummary(records: records, period: period, typingWordsPerMinute: 40)
            })
        }
        report("  of it, each record's place as a whole row", timed { _ = records.map { HomeRecentEntry($0).place } })
        report("  now: each record's place alone", timed { _ = records.map(HomeRecentEntry.place(of:)) })
        _ = usage.summary(records: records, period: .month, typingWordsPerMinute: 40)
        report("  now: a redraw with nothing changed", timed {
            _ = usage.summary(records: records, period: .month, typingWordsPerMinute: 40)
        })

        // What keeping the array costs: History's next write copies it.
        let kept = records
        var written = records
        report("History's next write, copying the array the pages keep", timed { written[0].text += " " })
        _ = kept.count

        // Formatters, ten thousand calls — about what a scroll through History asks for.
        report("10,000 integers, a formatter each (before)", timed { for value in 0..<10_000 { _ = Before.integer(value) } })
        report("  now", timed { for value in 0..<10_000 { _ = HomeFormat.integer(value) } })
        report("10,000 relative days, a formatter each (before)", timed {
            for index in 0..<10_000 { _ = Before.relativeDay(records[index].date, now: now, calendar: calendar) }
        })
        report("  now", timed { for index in 0..<10_000 { _ = HomeRecentEntry.relativeDay(records[index].date, now: now, calendar: calendar) } })

        // A window resized through 600 widths with 20 rows on screen.
        var fits = HistoryRowFits()
        var unbounded: [String: Bool] = [:]
        let ids = (0..<20).map { _ in UUID() }
        for width in 300..<900 { for id in ids { fits[id, width] = true; unbounded["\(id)|\(width)"] = true } }
        lines.append("Row fits kept after resizing through 600 widths: before \(unbounded.count), now \(fits.count)")
        print("\n" + lines.joined(separator: "\n") + "\n")
    }

    private func timed(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}

/// A random number generator that gives the same numbers every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Records made up for the tests: dictated, rewritten, edited, failed and empty, sent to
/// several apps, over more than a year — their words in the scripts and spellings a search
/// has to fold, and some it must leave to the original search.
private enum GeneratedHistory {
    static let words = [
        "Добрий", "день", "зустріч", "Олена", "п'ятниця", "п’ятниця", "ЗВІТ", "звіт", "їжак", "Йосип", "ґанок", "лист",
        "meeting", "Thursday", "agenda", "Café", "cafe\u{301}", "résumé", "NAÏVE", "Zürich", "Zu\u{308}rich",
        "Straße", "STRASSE", "Fuß", "ﬁle", "👍🏽", "👨‍👩‍👧", "नमस्ते", "Οδός", "Đà", "Nẵng", "会議", "회의", "Łódź",
        "İstanbul", "ılık", "x", "s", "№5", "✓", "→", "☕️",
    ]
    /// What most of a real History says: Ukrainian and English, accents and all.
    static let everydayWords = [
        "Добрий", "день", "сьогодні", "ми", "обговорили", "план", "на", "наступний", "тиждень", "і", "домовилися",
        "що", "Олена", "надішле", "звіт", "до", "п'ятниці", "а", "я", "перевірю", "цифри", "та", "підготую",
        "презентацію", "для", "клієнта", "зустріч", "Let's", "move", "the", "call", "to", "Thursday", "at", "three",
        "I'll", "send", "agenda", "tonight", "so", "everyone", "has", "a", "look", "before", "we", "meet", "café",
    ]
    static let apps: [String?] = ["Slack", "Mail", "Notes", "T3 Code (Alpha)", "Café ☕", "Термінал", nil, nil]
    static let everydayApps: [String?] = ["Slack", "Mail", "Notes", "T3 Code (Alpha)", "Telegram", "Google Chrome", nil, nil]
    static let presets = ["Clean-up", "Email / Message", "Notes", "Bullets", "Translate", "Technical / Prompt"]
    static let errors = ["No connection — saved to History", "Groq couldn't transcribe the recording: Ошибка (HTTP 400)"]

    /// The characters `HistorySearch.foldsFaithfully` was measured on, but its accents.
    static let tableAlphabet: [Unicode.Scalar] = {
        let ranges: [ClosedRange<UInt32>] = [0x00...0x7F, 0xA0...0x237, 0x370...0x3FF, 0x400...0x4FF, 0x1E00...0x1EF9,
                                              0x2010...0x205E, 0x20A0...0x20C0, 0x2100...0x214F, 0x2190...0x22FF,
                                              0x2500...0x257F, 0x25A0...0x27BF, 0x3000...0x303F]
        let sampled: [ClosedRange<UInt32>] = [0x4E00...0x9FFF, 0xAC00...0xD7A3]
        var scalars = ranges.flatMap { $0 }.compactMap(Unicode.Scalar.init)
        scalars += sampled.flatMap { $0 }.filter { $0 % 211 == 0 }.compactMap(Unicode.Scalar.init)
        return scalars.filter { $0.properties.generalCategory != .unassigned && HistorySearch.foldsFaithfully(String($0)) }
    }()

    static func record(at date: Date, text: String = "one two") -> TranscriptionRecord {
        TranscriptionRecord(id: UUID(), date: date, text: text, status: .success, provider: "groq", locale: "uk", duration: 5)
    }

    /// `count` records, newest first but for a few out of order, the newest at `now`.
    static func records(count: Int, now: Date, calendar: Calendar, seed: UInt64, everyday: Bool = false) -> [TranscriptionRecord] {
        var generator = SeededGenerator(seed: seed)
        func pick<T>(_ items: [T]) -> T { items.randomElement(using: &generator)! }
        func chance(_ percent: Int) -> Bool { Int.random(in: 0..<100, using: &generator) < percent }
        func sentence(_ range: ClosedRange<Int>) -> String {
            (0..<Int.random(in: range, using: &generator)).map { _ in pick(everyday ? everydayWords : words) }
                .joined(separator: chance(5) ? "\n" : " ")
        }
        // Over about 420 days, a few minutes to a few hours apart.
        let step = 420 * 86_400 / Double(max(count, 1))
        var records: [TranscriptionRecord] = (0..<count).map { index in
            let date = now.addingTimeInterval(-Double(index) * step - Double.random(in: 0..<step * 0.9, using: &generator))
            let roll = Int.random(in: 0..<100, using: &generator)
            let status: TranscriptionRecord.Status = roll < 80 ? .success : roll < 88 ? .empty : .failed
            var text = status == .success ? sentence(everyday ? 20...60 : 2...12) : ""
            if status == .success, !everyday, chance(1) { text = "\u{301}" + text }
            let provider = pick(["groq", "elevenlabs", "apple", "local", "openai"])
            let apps = everyday ? everydayApps : apps
            var record = TranscriptionRecord(
                id: UUID(), date: date, text: text, status: status,
                errorMessage: status == .failed ? pick(errors) : nil, provider: provider,
                locale: pick(["uk", "en", "auto"]), duration: Double.random(in: 1...90, using: &generator),
                originApp: pick(apps), destinationApp: pick(apps))
            record.sttModel = chance(50) ? pick(["whisper-large-v3-turbo", "scribe_v2", "parakeet-tdt-0.6b-v3"]) : nil
            if status == .success, chance(30) {
                let kind = Int.random(in: 0..<100, using: &generator)
                let edit = kind >= 60 && kind < 85, failed = kind >= 85
                var refinement = TranscriptionRecord.Refinement(
                    inputText: edit ? sentence(3...12) : text, outputText: failed ? "" : sentence(3...20),
                    presetName: edit || failed ? nil : pick(presets + ["email", "Technical"]),
                    provider: pick(["groq", "anthropic", "openai", "local"]),
                    model: pick(["openai/gpt-oss-120b", "claude-sonnet-5", "gpt-5.6-luna", "gemma-4-12b-it-qat-q4_0"]),
                    errorMessage: failed ? pick(errors) : nil,
                    context: chance(50) ? FocusContext(appName: pick(apps.compactMap { $0 })) : nil,
                    editsSelection: edit ? true : nil)
                if edit, chance(30) {
                    record.text = ""
                    record.provider = TranscriptionRecord.noSpeechProvider
                }
                if !failed, chance(60) { refinement.usage = ChatUsage(inputTokens: 900, outputTokens: 60, cachedInputTokens: 300) }
                record.refinement = refinement
            }
            if chance(40) {
                record.usageEvents = [UsageEvent(date: date, kind: chance(20) ? .stream : .upload, vendor: pick([.groq, .elevenLabs, .openAI]),
                                                 model: pick(["whisper-large-v3-turbo", "scribe_v2", "gpt-transcribe"]),
                                                 succeeded: chance(90), audioSeconds: record.duration,
                                                 billedSeconds: chance(50) ? max(10, record.duration) : nil, latency: 0.8)]
            }
            return record
        }
        // A few out of order, as an import or a clock that moved would leave them.
        for _ in 0..<max(1, count / 80) {
            let index = Int.random(in: 1..<max(2, count - 1), using: &generator)
            records.swapAt(index, index - 1)
        }
        return records
    }
}

/// The code the pages ran before, as it was, to hold the new to.
private enum Before {
    static func matches(_ record: TranscriptionRecord, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let fields: [String?] = [
            record.text, record.errorMessage, record.originApp, record.destinationApp,
            record.refinement?.inputText, record.refinement?.outputText,
            record.refinement?.presetName, record.refinement?.context?.appName,
        ]
        let haystack = fields.compactMap { $0 }.joined(separator: "\n")
        return words.allSatisfy {
            haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func includes(_ dates: HistoryDates, _ date: Date, now: Date, calendar: Calendar) -> Bool {
        let today = calendar.startOfDay(for: now)
        func since(_ days: Int) -> Bool {
            date >= (calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today)
        }
        switch dates {
        case .anyTime: return true
        case .today: return since(1)
        case .last7Days: return since(7)
        case .last30Days: return since(30)
        case .day(let day): return calendar.isDate(date, inSameDayAs: day)
        }
    }

    static func includes(_ narrowing: HistoryNarrowing, _ record: TranscriptionRecord, now: Date, calendar: Calendar) -> Bool {
        if let app = narrowing.app, HomeRecentEntry(record).place != app { return false }
        return includes(narrowing.dates, record.date, now: now, calendar: calendar)
    }

    static func group(_ records: [TranscriptionRecord], filter: HistoryFilter = .all, query: String = "",
                      narrowing: HistoryNarrowing = HistoryNarrowing(), now: Date, calendar: Calendar) -> [HistoryDay] {
        var days: [HistoryDay] = []
        var current: (start: Date, records: [TranscriptionRecord])?
        for record in records where filter.includes(record) && matches(record, query: query)
            && includes(narrowing, record, now: now, calendar: calendar) {
            let start = calendar.startOfDay(for: record.date)
            if current?.start == start {
                current?.records.append(record)
            } else {
                if let current { days.append(HistoryDay(start: current.start, records: current.records)) }
                current = (start, [record])
            }
        }
        if let current { days.append(HistoryDay(start: current.start, records: current.records)) }
        return days
    }

    /// HistoryView's `counts`, with its `now` and calendar passed in.
    static func counts(_ records: [TranscriptionRecord], query: String, narrowing: HistoryNarrowing,
                       now: Date, calendar: Calendar) -> [HistoryFilter: Int] {
        var counts = Dictionary(uniqueKeysWithValues: HistoryFilter.allCases.map { ($0, 0) })
        for record in records where includes(narrowing, record, now: now, calendar: calendar) && matches(record, query: query) {
            for filter in HistoryFilter.allCases where filter.includes(record) { counts[filter, default: 0] += 1 }
        }
        return counts
    }

    static func apps(in records: [TranscriptionRecord]) -> [(app: String, count: Int)] {
        var counts: [String: Int] = [:]
        for record in records { counts[HomeRecentEntry(record).place, default: 0] += 1 }
        return counts.map { (app: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.app.localizedCompare($1.app) == .orderedAscending }
    }

    static func integer(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func relativeDay(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                                     to: calendar.startOfDay(for: now)).day, days < 7 {
            formatter.dateFormat = "EEEE"
        } else {
            formatter.dateFormat = "d MMM"
        }
        return formatter.string(from: date)
    }

    static var checkedText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "d MMMM yyyy"
        return UsagePrices.checked.date.map(formatter.string(from:)) ?? ""
    }
}
