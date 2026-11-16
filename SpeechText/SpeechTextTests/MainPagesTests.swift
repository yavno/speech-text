// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SpeechTextCore

/// The main window's Usage, Prompts and Dictionary pages: their numbers and the
/// Dictionary's effect on a dictation — built from records and words made here, never the
/// user's own.
final class MainPagesTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Wednesday 30 September 2026, 15:00 in Kyiv.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15))!

    private func record(daysAgo: Int = 0, text: String = "one two three four five six", provider: String = "groq",
                        duration: TimeInterval = 3, status: TranscriptionRecord.Status = .success,
                        refinement: TranscriptionRecord.Refinement? = nil, app: String? = "Slack") -> TranscriptionRecord {
        TranscriptionRecord(id: UUID(), date: calendar.date(byAdding: .day, value: -daysAgo, to: now)!,
                            text: text, status: status, errorMessage: status == .failed ? "No connection" : nil,
                            provider: provider, locale: "uk", duration: duration,
                            refinement: refinement, destinationApp: app)
    }

    private func refinement(output: String = "Hello there, Olena.", preset: String? = "Email / Message",
                            model: String = "claude-sonnet-5", edit: Bool = false) -> TranscriptionRecord.Refinement {
        TranscriptionRecord.Refinement(inputText: "hello there olena", outputText: output, presetName: preset,
                                       provider: "anthropic", model: model, editsSelection: edit)
    }

    // MARK: Dictionary

    func testAWrongSpellingIsReplacedAsAWholeWordIgnoringCase() {
        let entries = [VocabularyEntry(term: "SpeechText", misheard: ["speech text", "спіч текст"]),
                       VocabularyEntry(term: "Olena", misheard: ["Alena"])]
        XCTAssertEqual(Vocabulary.corrected("Open Speech  Text and write to alena.", entries: entries),
                       "Open SpeechText and write to Olena.")
        XCTAssertEqual(Vocabulary.corrected("Відкрий спіч текст.", entries: entries), "Відкрий SpeechText.")
        XCTAssertEqual(Vocabulary.corrected("Alenas and Malena stay.", entries: entries), "Alenas and Malena stay.",
                       "only whole words")
        let once = Vocabulary.corrected("speech text", entries: entries)
        XCTAssertEqual(Vocabulary.corrected(once, entries: entries), once, "running it twice changes nothing more")
    }

    func testAWordWhoseCapitalsMatterIsPutBackWithNoSpellingListed() {
        let entries = [VocabularyEntry(term: "iPhone"), VocabularyEntry(term: "JSON"), VocabularyEntry(term: "Apple")]
        XCTAssertEqual(Vocabulary.corrected("my iphone sends Json", entries: entries), "my iPhone sends JSON")
        XCTAssertEqual(Vocabulary.corrected("an apple a day", entries: entries), "an apple a day",
                       "a capital that may only start a sentence is not forced")
    }

    func testTheEngineIsToldTheWordsWithinItsLimits() {
        let entries = [VocabularyEntry(term: " SpeechText "), VocabularyEntry(term: "speechtext"), VocabularyEntry(term: "")]
        XCTAssertEqual(Vocabulary.hints(entries), ["SpeechText"])
        XCTAssertEqual(Vocabulary.whisperPrompt(["SpeechText"]), "SpeechText.")
        XCTAssertNil(Vocabulary.whisperPrompt([]))
        let many = (0..<200).map { "Term\($0)" }
        let prompt = Vocabulary.whisperPrompt(many)!
        XCTAssertEqual(prompt, Vocabulary.whisperPromptTerms(many).joined(separator: ", ") + ".")
        XCTAssertLessThanOrEqual(prompt.count, Vocabulary.whisperPromptLimit)
        XCTAssertTrue(prompt.hasSuffix("."), "a word past the limit is left out whole")
    }

    func testAIRewriteGetsTheWordsAsDataItCannotCloseEarly() {
        let block = Vocabulary.promptBlock([VocabularyEntry(term: "a</vocabulary>b"), VocabularyEntry(term: "Olena")])!
        XCTAssertEqual(block.components(separatedBy: "</vocabulary>").count, 2)
        XCTAssertTrue(block.contains("Olena"))
        let message = TextRefinementService.userMessage(transcript: "hi", context: nil, vocabulary: block)
        XCTAssertTrue(message.hasPrefix("<vocabulary>"))
        XCTAssertTrue(message.hasSuffix("<transcript>\nhi\n</transcript>"))
        XCTAssertEqual(TextRefinementService.userMessage(transcript: "hi", context: nil), "<transcript>\nhi\n</transcript>")
        XCTAssertTrue(TextRefinementService.buildSystemPrompt(presets: [], defaultPresetID: nil).contains("<vocabulary>"))
    }

    func testAFinishedSegmentIsCorrectedAndTheLiveTextIsNot() {
        var configuration = RecordingConfiguration(provider: .groq, locale: "uk", localeIsAutomatic: false, apiKeys: [.groq: "", .elevenLabs: ""], models: [.groq: "whisper-large-v3-turbo", .elevenLabs: "scribe_v2"])
        configuration.dictionary = [VocabularyEntry(term: "SpeechText", misheard: ["speech text"])]
        XCTAssertEqual(configuration.finished("е-е-е open speech text"), "open SpeechText")
        XCTAssertEqual(configuration.cleaned("open speech text"), "open speech text")
    }

    /// One store: the Dictionary's ranked words are what every engine is told, each
    /// within its own limit, and the switch being off sends none of them anywhere.
    func testEveryEngineIsToldTheDictionaryWithinItsLimit() {
        var apple = RecordingConfiguration(provider: .apple, locale: "uk", localeIsAutomatic: false, apiKeys: [.groq: "", .elevenLabs: ""], models: [.groq: "whisper-large-v3-turbo", .elevenLabs: "scribe_v2"])
        apple.vocabulary = (1...120).map { "term\($0)" }
        XCTAssertEqual(apple.liveVocabulary.count, 100)
        XCTAssertEqual(apple.liveVocabulary.first, "term1", "the ranked order is kept")
        XCTAssertNotNil(apple.whisperPrompt, "Apple's uploads go to Groq, which is given the prompt")

        var groq = RecordingConfiguration(provider: .groq, locale: "uk", localeIsAutomatic: false, apiKeys: [.groq: "", .elevenLabs: ""], models: [.groq: "whisper-large-v3-turbo", .elevenLabs: "scribe_v2"])
        groq.vocabulary = ["SpeechText", "Olena"]
        XCTAssertEqual(groq.whisperPrompt, "SpeechText, Olena.")
        XCTAssertEqual(groq.liveVocabulary, [], "Groq takes no term list")

        groq.vocabulary = []
        groq.dictionary = [VocabularyEntry(term: "SpeechText", misheard: ["speech text"])]
        XCTAssertNil(groq.whisperPrompt, "switch off: nothing is sent")
        XCTAssertEqual(groq.finished("open speech text"), "open SpeechText", "…but the text is still put right")
    }

    /// Launch writes are where `OnboardingGate` broke before: a new install must gain no
    /// key, and the old one must go.
    func testTheSettingsListMovesInAtLaunchOnlyWhenItExists() throws {
        let name = "MainPagesTests.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        CustomVocabulary.migrateLegacyStoreIfNeeded(defaults)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("vocabulary") || $0 == SettingsKeys.customVocabulary }.isEmpty,
                      "nothing stored, nothing written")

        defaults.set(try JSONEncoder().encode([VocabularyTerm]()), forKey: SettingsKeys.customVocabulary)
        CustomVocabulary.migrateLegacyStoreIfNeeded(defaults)
        XCTAssertNil(defaults.data(forKey: SettingsKeys.customVocabulary))
        XCTAssertNil(defaults.data(forKey: SettingsKeys.vocabulary), "an empty list adds no Dictionary")

        defaults.set(Vocabulary.encode([VocabularyEntry(term: "SpeechText")]), forKey: SettingsKeys.vocabulary)
        defaults.set(try JSONEncoder().encode([VocabularyTerm(text: "kubectl"), VocabularyTerm(text: "speechtext")]),
                     forKey: SettingsKeys.customVocabulary)
        CustomVocabulary.migrateLegacyStoreIfNeeded(defaults)
        XCTAssertNil(defaults.data(forKey: SettingsKeys.customVocabulary))
        XCTAssertEqual(Vocabulary.decode(defaults.data(forKey: SettingsKeys.vocabulary)).map(\.term), ["SpeechText", "kubectl"])
    }

    func testSuggestionsAreNamesAndTermsUsedMoreThanOnce() {
        let texts = ["Send it to Olena in Figma.", "Olena likes the JSON export.", "The JSON is fine. Figma too.",
                     "Hello there.", "Ask Olena first.", "Hello again.", "- Make it\n- Make sure", "Then All of it, all right.", "So All."]
        let suggestions = Vocabulary.suggestions(from: texts, excluding: [VocabularyEntry(term: "figma")])
        XCTAssertEqual(suggestions.map(\.term), ["Olena", "JSON"],
                       "a sentence's or a line's first word is no name, nor one also written in lower case, and a word already taught is not offered again")
        XCTAssertEqual(Vocabulary.uses(of: VocabularyEntry(term: "JSON"), in: texts), 2)
    }

    // MARK: Usage

    func testThePeriodCountsWordsTimeAndMoney() {
        let records = [record(), record(daysAgo: 3, refinement: refinement()), record(daysAgo: 10),
                       record(daysAgo: 1, refinement: refinement(edit: true)), record(daysAgo: 2, status: .failed)]
        let week = UsageSummary(records: records, period: .week, now: now, calendar: calendar)
        XCTAssertEqual(week.dictations, 4)
        XCTAssertEqual(week.words, 6 + 3, "the edit's instruction and the failure are not words")
        XCTAssertEqual(week.rewrites, 1)
        XCTAssertEqual(week.edits, 1)
        XCTAssertEqual(week.failed, 1)
        XCTAssertEqual(week.granularity, .day)
        XCTAssertEqual(week.buckets.count, 7)
        XCTAssertEqual(week.buckets.last?.dictatedWords, 6)
        XCTAssertEqual(week.buckets[3].rewrittenWords, 3, "a rewrite's bar counts what AI Rewrite wrote")
        XCTAssertEqual(week.kinds[.rewritten]?.count, 1)
        XCTAssertEqual(week.kinds[.edit]?.words, 0)
        XCTAssertGreaterThan(week.aiCost, 0)
        XCTAssertEqual(week.speechCost, 0, "Groq's two models differ in price and these records name neither")
        XCTAssertEqual(week.unpricedModels, ["Groq"])

        let all = UsageSummary(records: records, period: .all, now: now, calendar: calendar)
        XCTAssertEqual(all.dictations, 5)
        XCTAssertEqual(all.buckets.count, 11, "All runs from History's oldest day")
    }

    func testSpeakingIsComparedWithTheTypingSpeedGiven() {
        let text = Array(repeating: "word", count: 150).joined(separator: " ")
        let summary = UsageSummary(records: [record(text: text, duration: 60)], period: .week,
                                   typingWordsPerMinute: 50, now: now, calendar: calendar)
        XCTAssertEqual(summary.speakingWordsPerMinute ?? 0, 150, accuracy: 0.01)
        XCTAssertEqual(summary.speedup ?? 0, 3, accuracy: 0.01)
        XCTAssertEqual(summary.savedMinutes, 2, accuracy: 0.01)
        XCTAssertNil(UsageSummary(records: [], period: .week, now: now, calendar: calendar).speedup)
    }

    /// Silence before the first word and after the last is not speaking; a record from
    /// before it was measured counts whole. A rewrite's speed is what was said, its time
    /// saved what was delivered.
    func testSpeakingIsTimedFromTheFirstWordAndARewriteBySaidWords() {
        let text = Array(repeating: "word", count: 150).joined(separator: " ")
        var trimmed = record(text: text, duration: 90)
        trimmed.speakingDuration = 60
        let summary = UsageSummary(records: [trimmed, record(text: text, duration: 60)], period: .week,
                                   typingWordsPerMinute: 50, now: now, calendar: calendar)
        XCTAssertEqual(summary.speakingMinutes, 2, accuracy: 0.0001)
        XCTAssertEqual(summary.speakingWordsPerMinute ?? 0, 150, accuracy: 0.01)
        XCTAssertEqual(HomeWeek(records: [trimmed], typingSpeed: 50, now: now, calendar: calendar).savedMinutes,
                       2, accuracy: 0.01)

        let rewritten = record(text: text, duration: 60,
                               refinement: refinement(output: Array(repeating: "word", count: 30).joined(separator: " ")))
        let rewrite = UsageSummary(records: [rewritten], period: .week, typingWordsPerMinute: 50, now: now, calendar: calendar)
        XCTAssertEqual(rewrite.speakingWordsPerMinute ?? 0, 150, accuracy: 0.01, "what was said, not the summary")
        XCTAssertEqual(rewrite.words, 30)
        XCTAssertEqual(rewrite.savedMinutes, 0, accuracy: 0.01, "typing 30 words takes less than saying 150")
    }

    func testARecordFromBeforeSpeakingTimeWasKeptStillDecodes() throws {
        let record = try JSONDecoder().decode(TranscriptionRecord.self, from: Data("""
            {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":0,"text":"hello","status":"success",
             "provider":"groq","locale":"uk","duration":3}
            """.utf8))
        XCTAssertNil(record.speakingDuration)
        XCTAssertEqual(record.duration, 3)
    }

    func testEnginesAndAppsAreBrokenDownAndAnUnknownPriceIsNamed() {
        let records = [record(provider: "local", app: "Mail"), record(provider: "openai"),
                       record(refinement: refinement(model: "gpt-5.6-luna"))]
        let summary = UsageSummary(records: records, period: .month, now: now, calendar: calendar)
        let speech = summary.engines.filter { $0.step == .speech }
        XCTAssertEqual(Set(speech.map(\.key)), ["local", "openai", "groq"])
        XCTAssertEqual(speech.first { $0.key == "local" }?.isLocal, true)
        XCTAssertNil(speech.first { $0.key == "openai" }?.cost)
        XCTAssertEqual(summary.unpricedModels, ["OpenAI", "Groq", "gpt-5.6-luna"],
                       "engines whose models differ in price, with no model recorded, and a model Anthropic does not list")
        XCTAssertNil(summary.engines.first { $0.key == "gpt-5.6-luna" }?.cost)
        XCTAssertEqual(summary.apps.first?.app, "Slack")
        XCTAssertEqual(summary.apps.first?.dictations, 2)
    }

    func testEachSpeechModelIsItsOwnEngineAndAnOldRecordKeepsItsVendor() {
        var realtime = record(provider: "elevenlabs"); realtime.sttModel = "scribe_v2_realtime"
        var upload = record(provider: "elevenlabs"); upload.sttModel = "scribe_v2"
        var again = record(provider: "elevenlabs"); again.sttModel = "scribe_v2"
        let older = record(provider: "elevenlabs")
        let summary = UsageSummary(records: [realtime, upload, again, older], period: .month, now: now, calendar: calendar)
        let speech = summary.engines.filter { $0.step == .speech }
        XCTAssertEqual(speech.count, 3, "two models and the records that never named one")
        XCTAssertEqual(speech.first { $0.provider == "scribe_v2" }?.uses, 2)
        XCTAssertEqual(speech.first { $0.provider == nil }?.uses, 1)
    }

    func testAnEditWithNoInstructionIsNoSpeechEngine() {
        var edit = record(text: "", provider: TranscriptionRecord.noSpeechProvider, duration: 0,
                          refinement: refinement(edit: true), app: nil)
        edit.usageEvents = []
        var older = edit
        older.usageEvents = nil
        let summary = UsageSummary(records: [edit, older, record(refinement: refinement(model: "claude-sonnet-5"))],
                                   period: .week, now: now, calendar: calendar)
        XCTAssertEqual(summary.engines.filter { $0.step == .speech }.map(\.key), ["groq"],
                       "an edit sent with no spoken instruction was heard by no engine")
        XCTAssertFalse(summary.unpricedModels.contains("edit"))
        let ai = summary.engines.first { $0.step == .ai }
        XCTAssertEqual(ai?.uses, 3)
        XCTAssertEqual(ai?.edits, 2, "the selections it edited are counted apart from the dictations it rewrote")
    }

    func testTheChartStartsWhereHistoryDoesButKeepsThePeriodsScale() {
        let month = UsageSummary(records: [record(daysAgo: 2)], period: .month, now: now, calendar: calendar)
        XCTAssertEqual(month.granularity, .day)
        XCTAssertEqual(month.buckets.count, 7, "no empty bars before History began, but never under a week")
        XCTAssertNotNil(month.chartSince)

        let older = UsageSummary(records: [record(daysAgo: 12)], period: .month, now: now, calendar: calendar)
        XCTAssertEqual(older.buckets.count, 13)
        XCTAssertEqual(older.buckets.first?.words, 6)

        let quarter = UsageSummary(records: [record(daysAgo: 20)], period: .quarter, now: now, calendar: calendar)
        XCTAssertEqual(quarter.granularity, .week, "a short History does not turn 90 days into days")
        XCTAssertLessThan(quarter.buckets.count, 6)

        let full = UsageSummary(records: [record(daysAgo: 40)], period: .month, now: now, calendar: calendar)
        XCTAssertEqual(full.buckets.count, 30)
        XCTAssertNil(full.chartSince)
    }

    func testAQuarterIsCountedInWeeks() {
        let summary = UsageSummary(records: [record(daysAgo: 80)], period: .quarter, now: now, calendar: calendar)
        XCTAssertEqual(summary.granularity, .week)
        XCTAssertEqual(summary.buckets.reduce(0) { $0 + $1.words }, 6)
        XCTAssertEqual(UsageFormat.speedup(3.64), "3.6×")
        XCTAssertEqual(UsageFormat.speedup(12.4), "12×")
        XCTAssertEqual(UsageFormat.cents(0.003), "0.3¢")
    }

    // MARK: Prompts

    func testAPromptsUsesAreCountedWhateverCapitalsTheModelWrote() {
        let email = PromptPreset(name: "Email / Message", whenToUse: "", instructions: "")
        let records = [record(refinement: refinement()), record(daysAgo: 1, refinement: refinement(preset: "EMAIL / MESSAGE")),
                       record(refinement: refinement(preset: "Instruction", edit: true)),
                       record(refinement: refinement(preset: nil))]
        let uses = PresetUsage.uses(in: records)
        XCTAssertEqual(uses["email / message"]?.count, 2)
        XCTAssertNil(uses["instruction"], "an edit's mode is not a dictation's choice")
        XCTAssertEqual(PresetUsage.recent(email, in: records).count, 2)
        XCTAssertEqual(PresetUsage.unnamed(in: records), 1)
    }
}

/// What an AI pass cost: the tokens each provider's reply says it billed, read into one
/// meaning whatever the wire said, and priced the same way by Home and Usage.
final class ChatUsageTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testOpenAIsDetailsArePartsOfItsTotals() throws {
        let reply = try decode(ChatCompletionResponse.self, """
            {"choices":[{"message":{"content":"Hi."}}],
             "usage":{"prompt_tokens":1432,"completion_tokens":87,"total_tokens":1519,
                      "prompt_tokens_details":{"cached_tokens":1024},
                      "completion_tokens_details":{"reasoning_tokens":40}}}
            """)
        XCTAssertEqual(reply.chatUsage, ChatUsage(inputTokens: 1432, outputTokens: 87,
                                                  cachedInputTokens: 1024, reasoningTokens: 40))
    }

    func testGroqSendsTheTotalsAlone() throws {
        let groq = try decode(ChatCompletionResponse.self, """
            {"choices":[{"message":{"content":"Hi."}}],
             "usage":{"queue_time":0.01,"prompt_tokens":900,"prompt_time":0.02,"completion_tokens":30,
                      "completion_time":0.05,"total_tokens":930,"total_time":0.07},
             "x_groq":{"id":"req_1"}}
            """)
        XCTAssertEqual(groq.chatUsage, ChatUsage(inputTokens: 900, outputTokens: 30))
        let none = try decode(ChatCompletionResponse.self, #"{"choices":[{"message":{"content":"Hi."}}]}"#)
        XCTAssertNil(none.chatUsage, "a reply without usage is estimated, not counted as free")
    }

    func testAnthropicsCacheTokensAreAddedToItsInput() throws {
        let reply = try decode(AnthropicChatClient.MessagesResponse.self, """
            {"content":[{"type":"text","text":"Hi."}],"stop_reason":"end_turn",
             "usage":{"input_tokens":200,"output_tokens":50,
                      "cache_creation_input_tokens":300,"cache_read_input_tokens":1000}}
            """)
        XCTAssertEqual(reply.usage?.chatUsage, ChatUsage(inputTokens: 1500, outputTokens: 50, cachedInputTokens: 1000))
    }

    func testAPassRecordedBeforeUsageWasKeptStillDecodes() throws {
        let refinement = try decode(TranscriptionRecord.Refinement.self, """
            {"inputText":"hello","outputText":"Hello.","provider":"groq","model":"openai/gpt-oss-120b"}
            """)
        XCTAssertNil(refinement.usage)
        let measured = TranscriptionRecord.Refinement(inputText: "hello", outputText: "Hello.", presetName: nil,
                                                      provider: "groq", model: "openai/gpt-oss-120b",
                                                      usage: ChatUsage(inputTokens: 10, outputTokens: 2))
        let roundTrip = try JSONDecoder().decode(TranscriptionRecord.Refinement.self,
                                                 from: JSONEncoder().encode(measured))
        XCTAssertEqual(roundTrip, measured)
    }

    func testAPassIsPricedAtItsTokensAndEstimatedOnlyWithoutThem() throws {
        let price = ChatRates(inputPerToken: 1 / 1e6, outputPerToken: 10 / 1e6)
        var pass = TranscriptionRecord.Refinement(inputText: "one two", outputText: "One, two.", presetName: nil,
                                                  provider: "groq", model: "m")
        XCTAssertTrue(price.isEstimate(pass))
        XCTAssertEqual(price.cost(of: pass), price.cost(inputWords: 2, outputWords: 2), accuracy: 1e-12)

        pass.usage = ChatUsage(inputTokens: 3000, outputTokens: 500, cachedInputTokens: 1000, reasoningTokens: 400)
        XCTAssertFalse(price.isEstimate(pass))
        XCTAssertEqual(price.cost(of: pass), 3000 / 1e6 + 5000 / 1e6, accuracy: 1e-12,
                       "every input and output token, the cached and reasoning ones not counted twice")
        let cached = ChatRates(inputPerToken: 1 / 1e6, cachedInputPerToken: 0.1 / 1e6, outputPerToken: 10 / 1e6)
        XCTAssertEqual(cached.cost(of: pass), 2000 / 1e6 + 100 / 1e6 + 5000 / 1e6, accuracy: 1e-12,
                       "the cached part of the input at the cached price, the rest at the input price")
        XCTAssertFalse(ChatRates(inputPerToken: 0, outputPerToken: 0).isEstimate(
            TranscriptionRecord.Refinement(inputText: "a", outputText: "b", presetName: nil, provider: "ollama", model: "m")),
                       "a free model has nothing to estimate")
    }

    func testHomeAndUsagePriceTheSameRecordsAlike() throws {
        let now = Date()
        func record(_ usage: ChatUsage?) -> TranscriptionRecord {
            var record = TranscriptionRecord(id: UUID(), date: now.addingTimeInterval(-60), text: "hello there olena",
                                             status: .success, errorMessage: nil, provider: "apple", locale: "uk",
                                             duration: 3, audioFileName: nil)
            record.refinement = TranscriptionRecord.Refinement(inputText: "hello there olena", outputText: "Hello there, Olena.",
                                                               presetName: nil, provider: "anthropic",
                                                               model: "claude-sonnet-5", usage: usage)
            return record
        }
        let records = [record(ChatUsage(inputTokens: 2400, outputTokens: 30)), record(nil)]
        let week = HomeWeek(records: records, now: now)
        let usage = UsageSummary(records: records, period: .week, now: now)
        XCTAssertEqual(week.aiCost, usage.aiCost, accuracy: 1e-12)
        XCTAssertEqual(week.estimatedAIPasses, 1)
        XCTAssertEqual(usage.estimatedAIPasses, 1)
        let price = try XCTUnwrap(UsagePrices.chat(provider: "anthropic", model: "claude-sonnet-5").listed)
        XCTAssertEqual(usage.aiCost, price.cost(ChatUsage(inputTokens: 2400, outputTokens: 30))
                       + price.cost(inputWords: 3, outputWords: 3), accuracy: 1e-12)
    }
}

/// Usage's Requests and Overhead, counted from History's ledger.
final class UsageRequestsTests: XCTestCase {
    private let now = Date()

    private func record(_ events: [UsageEvent]?, provider: String = "elevenlabs", status: TranscriptionRecord.Status = .success,
                        duration: TimeInterval = 30, minutesAgo: Double = 1) -> TranscriptionRecord {
        TranscriptionRecord(id: UUID(), date: now.addingTimeInterval(-minutesAgo * 60), text: status == .success ? "hello" : "",
                            status: status, errorMessage: nil, provider: provider, locale: "uk", duration: duration,
                            audioFileName: nil, usageEvents: events)
    }

    private func speech(_ kind: UsageEvent.Kind, _ model: String, succeeded: Bool = true, seconds: Double = 30,
                        billed: Double? = nil, latency: Double? = nil) -> UsageEvent {
        UsageEvent(date: now, kind: kind, vendor: .elevenLabs, model: model, succeeded: succeeded,
                   audioSeconds: seconds, billedSeconds: billed, latency: latency)
    }

    func testEachModelsRequestsAreCountedInItsOwnUnits() throws {
        let rewrite = UsageEvent(date: now, kind: .rewrite, vendor: .anthropic, model: "claude-sonnet-5", succeeded: true,
                                 tokens: ChatUsage(inputTokens: 2000, outputTokens: 50), latency: 1.5)
        let summary = UsageSummary(records: [
            record([speech(.upload, "scribe_v2", billed: 31, latency: 0.8)]),
            record([speech(.upload, "scribe_v2", latency: 1.2), rewrite]),
            record([speech(.upload, "scribe_v2", succeeded: false, latency: 9)]),
        ], period: .week, now: now)

        let scribe = try XCTUnwrap(summary.requests.first)
        XCTAssertEqual(scribe.model, "scribe_v2")
        XCTAssertEqual(scribe.requests, 3)
        XCTAssertEqual(scribe.failed, 1)
        XCTAssertEqual(scribe.audioSeconds, 90)
        XCTAssertEqual(scribe.billedSeconds, 31)
        XCTAssertEqual(scribe.billedRequests, 1, "the rest are only known as sent")
        XCTAssertEqual(scribe.typicalLatency, 1.0, "the middle of the answered ones; a refusal's wait is not an answer")

        let sonnet = try XCTUnwrap(summary.requests.last)
        XCTAssertEqual(sonnet.step, .ai)
        XCTAssertEqual(sonnet.inputTokens, 2000)
        XCTAssertEqual(sonnet.outputTokens, 50)
        XCTAssertEqual(summary.overhead.failedRequests, 1)
    }

    func testOverheadIsWhatWasPaidForWithoutBecomingText() {
        let summary = UsageSummary(records: [
            record([speech(.stream, "scribe_v2_realtime", succeeded: false, seconds: 20), speech(.upload, "scribe_v2", seconds: 20)]),
            record([speech(.stream, "scribe_v2_realtime", seconds: 10)]),
            record([speech(.upload, "scribe_v2", succeeded: false, seconds: 5), speech(.retry, "scribe_v2", seconds: 5)]),
            record([], status: .empty, duration: 4),
            record([], provider: "apple", status: .empty, duration: 6),
            record([speech(.stream, "scribe_v2_realtime", seconds: 7), speech(.upload, "scribe_v2", seconds: 7)]),
        ], period: .week, now: now)

        XCTAssertEqual(summary.overhead.paidTwiceSeconds, 27,
                       "every stream an upload replaced — broken or answering with nothing — and no other")
        XCTAssertEqual(summary.overhead.retries, 1)
        XCTAssertEqual(summary.overhead.retrySeconds, 5)
        XCTAssertEqual(summary.overhead.failedRequests, 2, "the broken socket and the refused upload, not the empty stream")
        XCTAssertEqual(summary.overhead.notSentSeconds, 4, "silence a cloud engine was spared; Apple sends nothing anyway")
    }

    func testRecordsFromBeforeTheLedgerAddNoRequests() {
        let summary = UsageSummary(records: [record(nil, minutesAgo: 60), record([speech(.upload, "scribe_v2")])],
                                   period: .week, now: now)
        XCTAssertEqual(summary.requests.map(\.requests), [1])
        XCTAssertEqual(summary.ledgerSince, now.addingTimeInterval(-60))
        XCTAssertTrue(UsageSummary(records: [record(nil)], period: .week, now: now).requests.isEmpty)
    }

    func testUnitsAreWrittenAsAPersonWould() {
        XCTAssertEqual(UsageFormat.tokens(820), "820")
        XCTAssertEqual(UsageFormat.tokens(4_820), "4.8k")
        XCTAssertEqual(UsageFormat.tokens(48_200), "48k")
        XCTAssertEqual(UsageFormat.tokens(1_300_000), "1.3M")
        XCTAssertEqual(UsageFormat.wait(0.42), "0.4 s")
        XCTAssertEqual(UsageFormat.wait(12.4), "12 s")
        XCTAssertEqual(UsageFormat.audio(45), "45 s")
        XCTAssertEqual(UsageFormat.audio(720), "12 min")
    }
}

/// The Dictionary and Prompts pages keep what they read from History until it changes,
/// since their bodies run on every keystroke in their fields. What they keep must be what
/// reading History afresh gives — after a dictation is added, a rewrite attached to one in
/// place, a retry, a delete — and the words being typed must change only the cheap half.
final class MainPagesHistoryCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func record(_ text: String, minutesAgo: Double = 0, status: TranscriptionRecord.Status = .success,
                        refinement: TranscriptionRecord.Refinement? = nil) -> TranscriptionRecord {
        TranscriptionRecord(id: UUID(), date: now.addingTimeInterval(-minutesAgo * 60), text: text, status: status,
                            errorMessage: status == .failed ? "No connection" : nil, provider: "groq", locale: "uk",
                            duration: 3, refinement: refinement)
    }

    private func rewrite(_ output: String, preset: String?, edit: Bool = false) -> TranscriptionRecord.Refinement {
        TranscriptionRecord.Refinement(inputText: "input", outputText: output, presetName: preset,
                                       provider: "anthropic", model: "claude-sonnet-5", editsSelection: edit)
    }

    private func texts(_ records: [TranscriptionRecord]) -> [String] {
        records.filter { $0.status == .success }.map(\.deliveredText)
    }

    // MARK: Dictionary

    func testTheDictionaryPageKeepsWhatAFreshReadGives() {
        var records = [record("Send it to Olena in Figma."), record("Olena likes the JSON export."),
                       record("The JSON is fine. Figma too."), record("", status: .failed), record("Ask Olena first.")]
        let entries = [VocabularyEntry(term: "JSON"), VocabularyEntry(term: "Olena"), VocabularyEntry(term: "Petro")]
        let cache = VocabularyHistoryCache()
        func check(_ step: String, taught: [VocabularyEntry] = []) {
            cache.refresh(from: records)
            XCTAssertEqual(cache.suggestions(excluding: taught).map(\.term),
                           Vocabulary.suggestions(from: texts(records), excluding: taught).map(\.term), step)
            XCTAssertEqual(cache.suggestions(excluding: taught).map(\.count),
                           Vocabulary.suggestions(from: texts(records), excluding: taught).map(\.count), step)
            for entry in entries {
                XCTAssertEqual(cache.uses(of: entry), Vocabulary.uses(of: entry, in: texts(records)), "\(step): \(entry.term)")
            }
        }
        check("the first look")
        check("a word taught, nothing else", taught: [VocabularyEntry(term: "olena")])
        records.insert(record("Petro and Olena, then Petro again. Ask Petro."), at: 0)
        check("a dictation added")
        records[1].refinement = rewrite("Write to Petro about the JSON.", preset: "Email / Message")
        check("a rewrite attached in place")
        records[4].text = "Petro said the JSON is late."
        records[4].status = .success
        check("a retry succeeded in place")
        records.remove(at: 2)
        check("a dictation deleted")
    }

    func testATaughtWordLetsTheNextSuggestionUp() {
        // Nine names, each said a different number of times, never at a sentence's start.
        let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India"]
        let texts = names.enumerated().flatMap { index, name in
            Array(repeating: "Ask \(name) now.", count: 10 - index)
        }
        XCTAssertEqual(Vocabulary.suggestions(from: texts, excluding: []).map(\.term), Array(names.prefix(8)))
        XCTAssertEqual(Vocabulary.suggestions(from: texts, excluding: [VocabularyEntry(term: "charlie")]).map(\.term),
                       ["Alpha", "Bravo", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India"])
        // A taught word said first takes no place from a tie after it.
        let tie = ["Ask Figma, then Olena, then Petro.", "Then Petro and Olena and Figma."]
        XCTAssertEqual(Vocabulary.suggestions(from: tie, excluding: [VocabularyEntry(term: "Figma")]).map(\.term),
                       ["Olena", "Petro"])
    }

    func testAWordsUsesMindItsCapitals() {
        let cache = VocabularyHistoryCache()
        cache.refresh(from: [record("The JSON export."), record("A json file."), record("JSON again.")])
        XCTAssertEqual(cache.uses(of: VocabularyEntry(term: "JSON")), 2)
        XCTAssertEqual(cache.uses(of: VocabularyEntry(term: "json")), 1)
        XCTAssertEqual(cache.uses(of: VocabularyEntry(term: " ")), 0)
    }

    // MARK: Prompts

    func testThePromptsPageKeepsWhatAFreshCountGives() {
        let email = PromptPreset(name: "Email / Message", whenToUse: "", instructions: "")
        var records = [record("a", minutesAgo: 1, refinement: rewrite("A.", preset: "EMAIL / MESSAGE")),
                       record("b", minutesAgo: 2, refinement: rewrite("B.", preset: "Notes")),
                       record("c", minutesAgo: 3, refinement: rewrite("C.", preset: "Email / Message")),
                       record("d", minutesAgo: 4, refinement: rewrite("D.", preset: "Instruction", edit: true)),
                       record("e", minutesAgo: 5, refinement: rewrite("E.", preset: "email / message")),
                       record("f", minutesAgo: 6, refinement: rewrite("F.", preset: "Email / Message")),
                       record("g", minutesAgo: 7)]
        let cache = PresetUsage.Cache()
        func check(_ step: String) {
            cache.refresh(from: records)
            XCTAssertEqual(cache.uses, PresetUsage.uses(in: records), step)
            XCTAssertEqual(cache.recent(email).map(\.id), PresetUsage.recent(email, in: records).map(\.id), step)
        }
        check("the first look")
        // History is newest first, so the first three found are the latest three.
        XCTAssertEqual(PresetUsage.recent(email, in: records).map(\.text), ["a", "c", "e"])
        records.insert(record("h", refinement: rewrite("H.", preset: "Email / Message")), at: 0)
        check("a rewrite added")
        XCTAssertEqual(cache.recent(email).map(\.text), ["h", "a", "c"])
        records[7].refinement = rewrite("G.", preset: "Email / Message")
        check("a rewrite attached in place")
        records[1].refinement = rewrite("A.", preset: "Notes")
        check("a rewrite replaced in place")
        records.remove(at: 0)
        check("a dictation deleted")
    }

    // MARK: Timings

    /// What the two pages paid on every keystroke before they kept what History says, and
    /// pay now, at the History a year or two of dictations reaches. Printed, never asserted.
    func testTimingsAtTwentyThousandRecords() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPEECHTEXT_PERF"] == "1",
                          "set SPEECHTEXT_PERF=1 to time History at scale")
        let presets = ["Clean-up", "Email / Message", "Notes", "Bullets", "Translate", "Technical / Prompt"]
        var records = SyntheticHistory.texts(count: 20_000).enumerated().map { index, text in
            record(text, minutesAgo: Double(index),
                   refinement: index % 4 == 0 ? rewrite(text, preset: presets[index % presets.count]) : nil)
        }
        let entries = SyntheticHistory.terms.prefix(12).map { VocabularyEntry(term: $0) }

        // The Dictionary page, as its body read History on every keystroke.
        let (_, dictionaryBefore) = SyntheticHistory.timed {
            let texts = records.filter { $0.status == .success }.map(\.deliveredText)
            _ = Vocabulary.suggestions(from: texts, excluding: entries)
            _ = entries.map { Vocabulary.uses(of: $0, in: texts) }
        }
        // The same words found with the trimming set made once a word, as before.
        let words = records.flatMap { $0.deliveredText.split(whereSeparator: \.isWhitespace) }
        let (_, setEachWord) = SyntheticHistory.timed {
            words.forEach { _ = $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
        }
        let madeOnce = CharacterSet.alphanumerics.inverted
        let (_, setOnce) = SyntheticHistory.timed { words.forEach { _ = $0.trimmingCharacters(in: madeOnce) } }

        let dictionary = VocabularyHistoryCache()
        let (_, dictionaryChange) = SyntheticHistory.timed {
            dictionary.refresh(from: records)
            _ = dictionary.suggestions(excluding: entries)
            _ = entries.map { dictionary.uses(of: $0) }
        }
        // Typing a word to add changes nothing History is read for; renaming one in its
        // editor makes one new word to look for.
        let (_, dictionaryKeystroke) = SyntheticHistory.timed {
            dictionary.refresh(from: records)
            _ = dictionary.suggestions(excluding: entries)
            _ = entries.map { dictionary.uses(of: $0) }
        }
        let renamed = VocabularyEntry(term: "Spee")
        let (_, dictionaryRename) = SyntheticHistory.timed {
            dictionary.refresh(from: records)
            _ = dictionary.suggestions(excluding: entries + [renamed])
            _ = (entries + [renamed]).map { dictionary.uses(of: $0) }
        }

        // The Prompts page, as its body counted History on every keystroke.
        let email = PromptPreset(name: "Email / Message", whenToUse: "", instructions: "")
        let (_, promptsBefore) = SyntheticHistory.timed {
            _ = PresetUsage.uses(in: records)
            _ = Array(records.filter { $0.refinement?.presetName?.caseInsensitiveCompare(email.name) == .orderedSame }
                .sorted { $0.date > $1.date }.prefix(3))
        }
        let prompts = PresetUsage.Cache()
        let (_, promptsChange) = SyntheticHistory.timed {
            prompts.refresh(from: records)
            _ = prompts.recent(email)
        }
        let (_, promptsKeystroke) = SyntheticHistory.timed {
            prompts.refresh(from: records)
            _ = prompts.recent(email)
        }
        records.insert(record("Olena sent the JSON."), at: 0)
        let (_, promptsAdded) = SyntheticHistory.timed { prompts.refresh(from: records) }

        print(String(format: """
            perf Dictionary page (20000 records, 12 words shown): each keystroke before %.1f ms \
            (of which the trimming set made once a word %.1f ms, made once %.1f ms); \
            now a History change %.1f ms, a keystroke adding a word %.2f ms, renaming one %.1f ms
            """, dictionaryBefore, setEachWord, setOnce, dictionaryChange, dictionaryKeystroke, dictionaryRename))
        print(String(format: """
            perf Prompts page (20000 records): each keystroke before %.1f ms; now a History change %.1f ms \
            (a dictation added %.1f ms), a keystroke %.2f ms
            """, promptsBefore, promptsChange, promptsAdded, promptsKeystroke))
    }

    // MARK: - Settings › Models (#247)

    func testEachShortcutPassesThroughItsModels() {
        XCTAssertEqual(ModelChainShortcut.dictate.roles, [.speech])
        XCTAssertEqual(ModelChainShortcut.aiRewrite.roles, [.speech, .aiRewrite])
        // Edit's instruction is spoken, so it is transcribed before it is carried out.
        XCTAssertEqual(ModelChainShortcut.edit.roles, [.speech, .aiRewrite])
        XCTAssertTrue(ModelChainShortcut.edit.startsFromSelection)
        XCTAssertFalse(ModelChainShortcut.aiRewrite.startsFromSelection)
    }

    func testTheModelsPageOpensWhereItWasLeft() {
        XCTAssertEqual(ModelsPageSelection(storedShortcut: "", storedRole: ""), .initial)
        XCTAssertEqual(ModelsPageSelection(storedShortcut: "edit", storedRole: "aiRewrite"),
                       ModelsPageSelection(shortcut: .edit, role: .aiRewrite))
        // Dictate draws no AI Rewrite frame, so it cannot be the one open.
        XCTAssertEqual(ModelsPageSelection(storedShortcut: "dictate", storedRole: "aiRewrite"),
                       ModelsPageSelection(shortcut: .dictate, role: .speech))
        XCTAssertEqual(ModelsPageSelection(storedShortcut: "gone", storedRole: "gone"), .initial)
    }

    func testALinkToAFrameTurnsToATabThatHasIt() {
        let dictate = ModelsPageSelection(shortcut: .dictate, role: .speech)
        XCTAssertEqual(dictate.opening(.aiRewrite), ModelsPageSelection(shortcut: .aiRewrite, role: .aiRewrite))
        XCTAssertEqual(dictate.opening(.speech), dictate)
        let edit = ModelsPageSelection(shortcut: .edit, role: .speech)
        XCTAssertEqual(edit.opening(.aiRewrite), ModelsPageSelection(shortcut: .edit, role: .aiRewrite))
    }
}
