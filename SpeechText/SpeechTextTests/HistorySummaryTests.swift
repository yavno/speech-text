// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SpeechTextCore

/// The main window's History: its days, its filters and its search — built from records
/// made here, never the user's own.
final class HistorySummaryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return calendar
    }()

    /// Wednesday 30 September 2026, 15:00 in Kyiv.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15))!

    private func record(daysAgo: Int = 0, hoursAgo: Int = 0, text: String = "one two three",
                        status: TranscriptionRecord.Status = .success,
                        refinement: TranscriptionRecord.Refinement? = nil, app: String? = nil) -> TranscriptionRecord {
        let date = calendar.date(byAdding: .hour, value: -hoursAgo, to: calendar.date(byAdding: .day, value: -daysAgo, to: now)!)!
        return TranscriptionRecord(id: UUID(), date: date, text: text, status: status,
                                   errorMessage: status == .failed ? "No connection" : nil,
                                   provider: "groq", locale: "uk", duration: 6,
                                   refinement: refinement, destinationApp: app)
    }

    private func refinement(output: String = "Hello there.", preset: String? = "Email / Message",
                            failed: Bool = false, edit: Bool = false) -> TranscriptionRecord.Refinement {
        TranscriptionRecord.Refinement(inputText: "hello there", outputText: failed ? "" : output, presetName: preset,
                                       provider: "anthropic", model: "claude-sonnet-5",
                                       errorMessage: failed ? "HTTP 529" : nil, editsSelection: edit)
    }

    // MARK: App icons

    func testAnAppIsFoundByTheBundleIDRecordedWithItsName() {
        var older = record(daysAgo: 1, app: "T3 Code (Alpha)")
        older.destinationBundleID = "com.t3tools.t3code.old"
        var newer = record(app: "T3 Code (Alpha)")
        newer.destinationBundleID = "com.t3tools.t3code"
        var started = record(app: "Mail")
        started.originApp = "Notes"
        started.originBundleID = "com.apple.Notes"
        var edit = record(refinement: refinement(edit: true))
        edit.refinement?.context = FocusContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let records = [newer, older, started, edit, record(app: "Pages")]

        XCTAssertEqual(AppIdentity.bundleID(forAppNamed: "T3 Code (Alpha)", in: records), "com.t3tools.t3code")
        XCTAssertEqual(AppIdentity.bundleID(forAppNamed: "Notes", in: records), "com.apple.Notes")
        XCTAssertEqual(AppIdentity.bundleID(forAppNamed: "Slack", in: records), "com.tinyspeck.slackmacgap")
        XCTAssertNil(AppIdentity.bundleID(forAppNamed: "Pages", in: records), "written before bundle IDs were kept")
        XCTAssertNil(AppIdentity.bundleID(forAppNamed: "Mail", in: records))
    }

    func testAnAppThatIsGoneIsDrawnWithAnotherChannelOfIt() {
        XCTAssertEqual(AppIdentity.baseName("T3 Code (Alpha)"), "T3 Code")
        XCTAssertEqual(AppIdentity.baseName("Visual Studio Code"), "Visual Studio Code")
        XCTAssertEqual(AppIdentity.baseName("(Beta)"), "(Beta)")

        let installed = ["Mail", "T3 Code (Nightly)", "T3 Code (Beta)", "Xcode"]
        XCTAssertEqual(AppIdentity.sibling(of: "T3 Code (Alpha)", among: installed), "T3 Code (Beta)")
        XCTAssertEqual(AppIdentity.sibling(of: "T3 Code (Alpha)", among: installed + ["T3 Code"]), "T3 Code",
                       "the plain name before any channel")
        XCTAssertEqual(AppIdentity.sibling(of: "Cursor", among: ["Cursor (Nightly)"]), "Cursor (Nightly)")
        XCTAssertNil(AppIdentity.sibling(of: "T3 Code (Alpha)", among: ["Mail", "T3"]))
        XCTAssertNil(AppIdentity.sibling(of: "Mail", among: ["Mail", "Mailbird"]), "only another channel, never itself")
    }

    // MARK: App and date

    func testHistoryIsNarrowedToAnAppAsItsRowNamesIt() {
        let records = [record(app: "Slack"), record(hoursAgo: 1, app: "Slack"), record(daysAgo: 1, app: "Mail"),
                       record(daysAgo: 2), record(daysAgo: 3, status: .empty)]
        XCTAssertEqual(HistoryNarrowing.apps(in: records).map(\.app), ["Slack", "Mail", "Not pasted", "Record Window"])
        XCTAssertEqual(HistoryNarrowing.apps(in: records).first?.count, 2)
        let slack = HistoryDay.group(records, narrowing: HistoryNarrowing(app: "Slack"), now: now, calendar: calendar)
        XCTAssertEqual(slack.flatMap(\.records).count, 2)
        let unpasted = HistoryDay.group(records, narrowing: HistoryNarrowing(app: "Not pasted"), now: now, calendar: calendar)
        XCTAssertEqual(unpasted.flatMap(\.records).map(\.status), [.empty])
    }

    func testHistoryIsNarrowedToARangeOfDaysOrOneDay() {
        let records = [record(), record(daysAgo: 1), record(daysAgo: 6), record(daysAgo: 7), record(daysAgo: 40)]
        func count(_ dates: HistoryDates) -> Int {
            HistoryDay.group(records, narrowing: HistoryNarrowing(dates: dates), now: now, calendar: calendar)
                .flatMap(\.records).count
        }
        XCTAssertEqual(count(.anyTime), 5)
        XCTAssertEqual(count(.today), 1)
        XCTAssertEqual(count(.last7Days), 3, "today and the six days before it")
        XCTAssertEqual(count(.last30Days), 4)
        XCTAssertEqual(count(.day(calendar.date(byAdding: .day, value: -7, to: now)!)), 1)
    }

    // MARK: How long History keeps dictations

    func testHistoryKeepsASpanOfTimeThisSessionOrEverything() {
        let records = (0..<1200).map { record(hoursAgo: $0 * 12) }
        let launch = calendar.date(byAdding: .hour, value: -30, to: now)!
        func kept(_ retention: HistoryRetention) -> Int {
            retention.keptCount(of: records, now: now, sessionStart: launch, calendar: calendar)
        }
        XCTAssertEqual(kept(.forever), 1200)
        XCTAssertEqual(kept(.days7), 15, "two a day for seven days, and the one right on the line")
        XCTAssertEqual(kept(.days30), 61)
        XCTAssertEqual(kept(.months3), 185, "back to 30 June: 92 days, on the calendar")
        XCTAssertEqual(kept(.months6), 369, "back to 30 March: 184 days")
        XCTAssertEqual(kept(.year), 731)
        XCTAssertEqual(kept(.session), 3, "what this run of the app made: 0, 12 and 24 hours ago")
        XCTAssertEqual(HistoryRetention.session.keptCount(of: records, now: now, sessionStart: .distantFuture,
                                                          calendar: calendar), 0, "nothing past quit")
    }

    func testAnUpdateDeletesNothing() {
        XCTAssertEqual(HistoryRetention.default, .forever)
        XCTAssertEqual(HistoryRetention.stored(nil), .forever)
        XCTAssertEqual(HistoryRetention.stored("300"), .forever, "the count History once kept by")
        XCTAssertEqual(HistoryRetention.stored("1000"), .forever)
        XCTAssertEqual(HistoryRetention.stored("1y"), .year)
        XCTAssertEqual(HistoryRetention.defaultAudio, .days7, "what a failed dictation's audio always got")
        XCTAssertEqual(HistoryRetention.stored(nil, default: .defaultAudio), .days7)
        XCTAssertEqual(HistoryRetention.stored("none", default: .defaultAudio), .session)
    }

    func testAFailedDictationsAudioGoesWithItsRecord() {
        let failed = record()
        XCTAssertEqual(HistoryFormat.audioKept(failed, audio: .days7, history: .forever, calendar: calendar),
                       "until Wednesday 7 October")
        XCTAssertEqual(HistoryFormat.audioKept(failed, audio: .forever, history: .days30, calendar: calendar),
                       "until Friday 30 October", "History's shorter span decides")
        XCTAssertEqual(HistoryFormat.audioKept(failed, audio: .days7, history: .session, calendar: calendar),
                       "until SpeechText quits")
        XCTAssertEqual(HistoryFormat.audioKept(failed, audio: .forever, history: .forever, calendar: calendar),
                       "for as long as History keeps it")
        XCTAssertEqual(HistoryFormat.storageSummary(count: 125, since: calendar.date(byAdding: .day, value: -16, to: now),
                                                    bytes: 0, calendar: calendar).prefix(35),
                       "125 dictations since 14 September ·")
        XCTAssertEqual(HistoryFormat.storageSummary(count: 0, since: nil, bytes: 0), "No dictations kept yet.")
        XCTAssertEqual(HistoryFormat.retentionSummary(history: .forever, audio: .days7),
                       "History keeps every dictation on this Mac. A failed one's audio is kept for 7 days, for a retry.")
        XCTAssertEqual(HistoryFormat.retentionSummary(history: .days30, audio: .year),
                       "History keeps the last 30 days of dictations on this Mac. A failed one's audio is kept for 30 days, for a retry.")
        XCTAssertEqual(HistoryFormat.retentionSummary(history: .session, audio: .days7),
                       "History keeps this session's dictations, until SpeechText quits. A failed one's audio is kept until SpeechText quits, for a retry.")
    }

    // MARK: Days

    func testRecordsAreGroupedByDayNewestFirst() {
        let records = [record(), record(hoursAgo: 2), record(daysAgo: 1), record(daysAgo: 9)]
        let days = HistoryDay.group(records, calendar: calendar)
        XCTAssertEqual(days.map(\.records.count), [2, 1, 1])
        XCTAssertEqual(days.map { $0.title(now: now, calendar: calendar) }, ["Today", "Yesterday", "21 September"])
    }

    func testADayWithinTheWeekIsNamedAndDatedAndAnOlderYearSaysSo() {
        let monday = HistoryDay.group([record(daysAgo: 2)], calendar: calendar)[0]
        XCTAssertEqual(monday.title(now: now, calendar: calendar), "Monday")
        XCTAssertEqual(monday.subtitle(now: now, calendar: calendar), "28 September")
        let lastYear = HistoryDay.group([record(daysAgo: 400)], calendar: calendar)[0]
        XCTAssertEqual(lastYear.title(now: now, calendar: calendar), "26 August 2025")
        XCTAssertNil(lastYear.subtitle(now: now, calendar: calendar))
    }

    func testADayCountsTheWordsDeliveredNotAnEditsInstruction() {
        let day = HistoryDay.group([
            record(text: "uh hello", refinement: refinement(output: "Hello, Olena — sorry.")),
            record(text: "shorter", refinement: refinement(edit: true)),
            record(status: .failed),
        ], calendar: calendar)[0]
        XCTAssertEqual(day.words, 4)
    }

    // MARK: Filters

    func testEachFilterKeepsItsOwn() {
        let plain = record(), rewritten = record(refinement: refinement()), edit = record(refinement: refinement(edit: true))
        let failed = record(status: .failed), empty = record(status: .empty), fellBack = record(refinement: refinement(failed: true))
        let all = [plain, rewritten, edit, failed, empty, fellBack]
        func ids(_ filter: HistoryFilter) -> [UUID] { all.filter(filter.includes).map(\.id) }
        XCTAssertEqual(ids(.all).count, 6)
        XCTAssertEqual(ids(.rewritten), [rewritten.id, fellBack.id])
        XCTAssertEqual(ids(.edits), [edit.id])
        XCTAssertEqual(ids(.failed), [failed.id, empty.id, fellBack.id], "a rewrite that fell back did not come out as asked")
    }

    // MARK: Search

    func testSearchFindsEveryWordAnywhereIgnoringCaseAndAccents() {
        let rewritten = record(text: "лист Олені", refinement: refinement(output: "Привіт, Олено!"), app: "Mail")
        XCTAssertTrue(HistorySearch.matches(rewritten, query: "олено"), "the rewrite is searched")
        XCTAssertTrue(HistorySearch.matches(rewritten, query: "ЛИСТ mail"), "what was said, and the app")
        XCTAssertTrue(HistorySearch.matches(rewritten, query: "email"), "the prompt's name")
        XCTAssertFalse(HistorySearch.matches(rewritten, query: "лист slack"), "every word has to be found")
        XCTAssertTrue(HistorySearch.matches(record(text: "Café"), query: "cafe"))
        XCTAssertTrue(HistorySearch.matches(record(status: .failed), query: "connection"), "the error is searched")
        XCTAssertTrue(HistorySearch.matches(record(), query: "  "))
    }

    func testGroupingAppliesTheFilterAndTheSearch() {
        let days = HistoryDay.group([record(text: "buy milk"), record(daysAgo: 1, text: "milk", status: .failed),
                                     record(daysAgo: 2, text: "bread")],
                                    filter: .all, query: "milk", calendar: calendar)
        XCTAssertEqual(days.map(\.records.count), [1, 1])
        XCTAssertEqual(HistoryDay.group([record(), record(status: .failed)], filter: .failed, calendar: calendar)
            .flatMap(\.records).count, 1)
    }

    // MARK: Rows

    func testARowSaysARewriteFellBackAndWhereNothingWasPasted() {
        XCTAssertEqual(HomeRecentEntry(record(refinement: refinement(failed: true))).tags, [.rewriteFailed])
        let failedEdit = HomeRecentEntry(record(text: "shorter", refinement: refinement(failed: true, edit: true)))
        XCTAssertEqual(failedEdit.tags, [.edit, .rewriteFailed])
        XCTAssertEqual(failedEdit.text, "hello there", "the selection that was left as it was")
        XCTAssertEqual(HomeRecentEntry(record(status: .failed)).place, "Not pasted")
        XCTAssertEqual(HomeRecentEntry(record()).place, "Record Window")
        XCTAssertEqual(HomeRecentEntry(record(app: "Slack")).place, "Slack")
    }

    // MARK: Saved with no connection

    private func offline(_ status: TranscriptionRecord.Status, app: String? = "Slack", rewrite: Bool = false,
                         refinement: TranscriptionRecord.Refinement? = nil) -> TranscriptionRecord {
        var saved = record(text: status == .success ? "buy milk" : "", status: status, refinement: refinement)
        saved.undelivered = TranscriptionRecord.Undelivered(
            app: app, rewrite: rewrite, context: app.map { FocusContext(appName: $0) })
        return saved
    }

    /// A dictation saved offline reached no app, before its retry and after it — even once
    /// the retry's rewrite records a context naming the app it was going to — so it stays
    /// under "Not pasted", where the back-online notice's Show opens History.
    func testADictationSavedOfflineIsNotPastedWhateverItsRetryDid() {
        var told = refinement(output: "Buy milk.")
        told.context = FocusContext(appName: "Slack")
        let records = [offline(.failed), offline(.success), offline(.success, refinement: told), offline(.success, app: nil)]
        for saved in records {
            XCTAssertEqual(HomeRecentEntry(saved).place, HomeRecentEntry.notPasted)
            XCTAssertEqual(HomeRecentEntry.place(of: saved), HomeRecentEntry.notPasted)
            XCTAssertNil(HomeRecentEntry(saved).app)
        }
        XCTAssertEqual(HistoryNarrowing.apps(in: records).map(\.app), ["Not pasted"])
        XCTAssertEqual(HistoryDay.group(records, narrowing: HistoryNarrowing(app: "Not pasted"), now: now, calendar: calendar)
            .flatMap(\.records).count, 4)
        XCTAssertEqual(HomeRecentEntry(records[0]).tags, [.failed, .notPasted("Slack")])
        XCTAssertEqual(HomeRecentEntry(records[2]).tags, [.preset("Email / Message"), .notPasted("Slack")])
        XCTAssertEqual(HomeRecentEntry(records[3]).tags, [.notPasted(nil)])
        XCTAssertEqual(HomeRecentEntry(records[2]).text, "Buy milk.", "what the rewrite made of it, to copy")
    }

    func testAnOfflineDictationIsFoundByTheAppItWasFor() {
        XCTAssertEqual(HistoryDay.group([offline(.success), record(app: "Mail")], filter: .all, query: "slack",
                                        calendar: calendar).flatMap(\.records).count, 1)
    }

    /// The mark survives `history.json`, and a record written before it reads as delivered.
    func testTheOfflineMarkIsStoredAndAnOlderRecordDecodesWithoutIt() throws {
        let saved = offline(.failed, rewrite: true)
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionRecord.self, from: data), saved)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "undelivered")
        let older = try JSONDecoder().decode(TranscriptionRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(older.undelivered)
        XCTAssertFalse(older.retryRewrites)
    }

    /// Only a dictation made with the AI shortcut is rewritten by its retry.
    func testOnlyAnAIDictationSavedOfflineIsRewrittenOnRetry() {
        XCTAssertTrue(offline(.failed, rewrite: true).retryRewrites)
        XCTAssertFalse(offline(.failed).retryRewrites)
        XCTAssertFalse(record(status: .failed).retryRewrites)
    }

    func testARowShowsALettersParagraphsOnOneLine() {
        let letter = "Hi Amie!\n\nOkay, thanks for the information.  Yes, I’ve learned Spanish.\n"
        let entry = HomeRecentEntry(record(text: letter))
        XCTAssertEqual(entry.preview, "Hi Amie! Okay, thanks for the information. Yes, I’ve learned Spanish.")
        XCTAssertEqual(entry.text, letter, "Copy keeps the line breaks")
    }

    // MARK: Formatting

    func testTheFactsAreWrittenAsAPersonWould() {
        XCTAssertEqual(HistoryFormat.clock(now, calendar: calendar), "15:00")
        XCTAssertEqual(HistoryFormat.full(now, calendar: calendar), "Wednesday 30 September 2026, 15:00")
        XCTAssertEqual(HistoryFormat.length(8.4), "8 s")
        XCTAssertEqual(HistoryFormat.length(65), "1:05")
        XCTAssertNil(HistoryFormat.length(0))
        XCTAssertEqual(HistoryFormat.engine("local"), "On this Mac")
        XCTAssertEqual(HistoryFormat.engine("elevenlabs"), "ElevenLabs")
        XCTAssertEqual(HistoryFormat.language("uk"), "Ukrainian")
        XCTAssertNil(HistoryFormat.language("auto"))
    }
}

/// `history.json` read and written entry by entry: an entry this build cannot decode costs
/// nothing — it is written back as it was read — and a file that cannot be read at all is
/// copied aside before it is replaced. Every file here is in a temporary folder.
final class HistoryFileTests: XCTestCase {
    private var folder: URL!
    private var url: URL { folder.appendingPathComponent("history.json") }
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func record(hoursAgo: Double, text: String = "one two three",
                        status: TranscriptionRecord.Status = .success,
                        events: [UsageEvent]? = nil) -> TranscriptionRecord {
        TranscriptionRecord(id: UUID(), date: base.addingTimeInterval(-hoursAgo * 3600), text: text, status: status,
                            errorMessage: nil, provider: "groq", locale: "uk", duration: 6,
                            audioFileName: status == .success ? nil : "\(UUID().uuidString).flac",
                            sttModel: "whisper-large-v3-turbo", usageEvents: events)
    }

    private func event(_ kind: UsageEvent.Kind, _ vendor: Provider) -> UsageEvent {
        UsageEvent(date: base, kind: kind, vendor: vendor, model: "whisper-large-v3-turbo", succeeded: true,
                   audioSeconds: 6, billedSeconds: 10)
    }

    /// What the app writes with nothing kept: the whole array through `JSONEncoder`, keys
    /// sorted as `HistoryFile.encode` sorts them.
    private func encoded(_ records: [TranscriptionRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(records)
    }

    private func decodesAlone(_ json: Data) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(TranscriptionRecord.self, from: json)) != nil
    }

    private func ids(in data: Data) throws -> [String] {
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return array.map { $0["id"] as? String ?? "?" }
    }

    /// Replaces the one occurrence of `old`, so a fixture cannot quietly alter nothing.
    private func replacingOnce(_ old: String, with new: String, in text: String) -> String {
        XCTAssertEqual(text.components(separatedBy: old).count, 2, "exactly one \(old)")
        return text.replacingOccurrences(of: old, with: new)
    }

    private struct Fixture {
        let file: Data
        let decodable: [TranscriptionRecord]
        let all: [TranscriptionRecord]
    }

    /// Seven records as this build writes them, three of them then given a value it does
    /// not know: a status, a vendor in the ledger (`TranscriptionRecord.provider` is a plain
    /// string and would decode), and a ledger kind.
    private func fixture() throws -> Fixture {
        let a = record(hoursAgo: 0)
        let newStatus = record(hoursAgo: 1, status: .empty)
        let c = record(hoursAgo: 2, events: [event(.upload, .groq)])
        let newVendor = record(hoursAgo: 3, events: [event(.upload, .ollama)])
        let d = record(hoursAgo: 4, status: .failed)
        let newKind = record(hoursAgo: 5, events: [event(.edit, .groq)])
        let e = record(hoursAgo: 6)
        let all = [a, newStatus, c, newVendor, d, newKind, e]
        var text = try XCTUnwrap(String(data: encoded(all), encoding: .utf8))
        text = replacingOnce(#""status" : "empty""#, with: #""status" : "queued""#, in: text)
        text = replacingOnce(#""vendor" : "ollama""#, with: #""vendor" : "deepgram""#, in: text)
        text = replacingOnce(#""kind" : "edit""#, with: #""kind" : "diarize""#, in: text)
        return Fixture(file: Data(text.utf8), decodable: [a, c, d, e], all: all)
    }

    func testAnEntryThisBuildCannotDecodeCostsOnlyItself() throws {
        let fixture = try fixture()
        let contents = try XCTUnwrap(HistoryFile.decode(fixture.file))
        XCTAssertEqual(contents.records, fixture.decodable)
        XCTAssertEqual(contents.undecodable.count, 3)
        for entry in contents.undecodable {
            XCTAssertFalse(decodesAlone(entry.json), "the fixture really is undecodable")
        }
        XCTAssertEqual(contents.undecodable.map(\.place), [fixture.all[1], fixture.all[3], fixture.all[5]].map(\.date))
        XCTAssertNotNil(fixture.all[1].audioFileName)
        XCTAssertEqual(contents.undecodable[0].audioFileName, fixture.all[1].audioFileName,
                       "its audio is still known, for Clear History")
    }

    func testAnEntryThisBuildCannotDecodeIsWrittenBackAsItWasRead() throws {
        let fixture = try fixture()
        let contents = try XCTUnwrap(HistoryFile.decode(fixture.file))
        let written = try HistoryFile.encode(contents.records, keeping: contents.undecodable)
        XCTAssertEqual(String(decoding: written, as: UTF8.self), String(decoding: fixture.file, as: UTF8.self),
                       "the same bytes, in the same places")
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.file) as? NSArray)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? NSArray)
        XCTAssertEqual(before, after)
        XCTAssertEqual(HistoryFile.decode(written), contents, "and read again, nothing changed")
    }

    func testANewDictationGoesOnTopAndTheKeptEntriesKeepTheirPlace() throws {
        let fixture = try fixture()
        let contents = try XCTUnwrap(HistoryFile.decode(fixture.file))
        let new = record(hoursAgo: -1)
        // A new dictation, and the one after the first kept entry deleted.
        let records = [new] + contents.records.filter { $0.id != fixture.all[2].id }
        let written = try HistoryFile.encode(records, keeping: contents.undecodable)
        let order = [new] + fixture.all.filter { $0.id != fixture.all[2].id }
        XCTAssertEqual(try ids(in: written), order.map(\.id.uuidString))
        for entry in contents.undecodable {
            XCTAssertNotNil(written.range(of: entry.json), "kept byte for byte")
        }
        let again = try XCTUnwrap(HistoryFile.decode(written))
        XCTAssertEqual(again.records, records)
        XCTAssertEqual(again.undecodable.map(\.json), contents.undecodable.map(\.json))
    }

    func testWithNothingKeptTheFileIsWhatTheEncoderAlwaysWrote() throws {
        let records = [record(hoursAgo: 0), record(hoursAgo: 1, status: .failed)]
        XCTAssertEqual(try HistoryFile.encode(records, keeping: []), try encoded(records))
        XCTAssertEqual(try HistoryFile.encode([], keeping: []), try encoded([]))
        XCTAssertEqual(HistoryFile.decode(try encoded(records)), HistoryFile.Contents(records: records))
    }

    /// Only kept entries: the records' array is empty and theirs is the whole file.
    func testAFileOfOnlyUndecodableEntriesSurvivesASaveWithNoRecords() throws {
        let fixture = try fixture()
        let contents = try XCTUnwrap(HistoryFile.decode(fixture.file))
        let written = try HistoryFile.encode([], keeping: contents.undecodable)
        XCTAssertEqual(try ids(in: written), [1, 3, 5].map { fixture.all[$0].id.uuidString })
    }

    /// A dictation holds every character JSON gives a meaning to.
    func testStringsAreSkippedWholeWhenTheFileIsSplit() throws {
        let tricky = #"He said "stop", then ] and } and [ { , — a path C:\Users\ — Привіт 👋🏽 \"#
        let words = record(hoursAgo: 0, text: tricky)
        let other = record(hoursAgo: 1, status: .empty)
        var text = try XCTUnwrap(String(data: encoded([words, other]), encoding: .utf8))
        text = replacingOnce(#""status" : "empty""#, with: #""status" : "queued""#, in: text)
        let contents = try XCTUnwrap(HistoryFile.decode(Data(text.utf8)))
        XCTAssertEqual(contents.records, [words])
        XCTAssertEqual(contents.records.first?.text, tricky)
        XCTAssertEqual(contents.undecodable.count, 1)

        let array = Array(#"[ "a,]}\\", {"t":"\\\"]"} , [1,[2]],3 ]"#.utf8)
        let ranges = try XCTUnwrap(HistoryFile.elementRanges(in: array))
        XCTAssertEqual(ranges.map { String(decoding: array[$0], as: UTF8.self) },
                       [#""a,]}\\""#, #"{"t":"\\\"]"}"#, "[1,[2]]", "3"])
        XCTAssertEqual(HistoryFile.elementRanges(in: Array("  [ ]\n".utf8)), [])
        // `JSONDecoder` takes a trailing comma, so such a file reads whole by the fast path;
        // only one that also holds an undecodable entry reaches the split, which refuses it.
        XCTAssertNil(HistoryFile.elementRanges(in: Array("[1,]".utf8)))
    }

    func testAFileThatIsNotOneWholeArrayIsUnreadable() throws {
        let good = try XCTUnwrap(String(data: encoded([record(hoursAgo: 0)]), encoding: .utf8))
        let goodElement = good.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        let broken = [
            "[ \(goodElement), {\"id\":\"x\",\"te",   // cut off inside a string
            "[ \(goodElement)",                       // no closing bracket
            "[ \(goodElement), ",                     // cut off between entries
            "[ \(goodElement) } ]",                   // a brace closing nothing
            "[ \(goodElement), {\"status\": nope} ]", // an entry that is not JSON
            "[ \(goodElement) ] trailing",
            "{\"records\": []}",
            "garbage",
        ]
        for text in broken {
            XCTAssertNil(HistoryFile.decode(Data(text.utf8)), text)
            try Data(text.utf8).write(to: url)
            guard case .unreadable = HistoryFile.read(url) else {
                XCTFail("read as something: \(text)")
                continue
            }
        }
    }

    func testNoFileIsAFreshStart() throws {
        XCTAssertEqual(HistoryFile.read(url), .missing)
        XCTAssertEqual(HistoryFile.read(folder.appendingPathComponent("gone/history.json")), .missing)
        try Data().write(to: url)
        XCTAssertEqual(HistoryFile.read(url), .missing, "an empty file holds nothing to keep")
        XCTAssertTrue(HistoryFile.unreadableCopies(of: url).isEmpty)
    }

    func testAnUnreadableFileIsCopiedAsideBeforeTheFirstWrite() throws {
        let garbage = Data("[ {\"id\": \"cut off".utf8)
        try garbage.write(to: url)
        guard case .unreadable = HistoryFile.read(url) else { return XCTFail("read as something") }

        let new = record(hoursAgo: 0)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let owed = HistoryFile.write([new], keeping: [], to: url, copyingUnreadableFirst: true, now: now)
        XCTAssertFalse(owed)
        let copies = HistoryFile.unreadableCopies(of: url)
        XCTAssertEqual(copies.map(\.lastPathComponent), ["history.json.unreadable-2027-01-15T080000Z"])
        XCTAssertEqual(try Data(contentsOf: copies[0]), garbage)
        XCTAssertEqual(HistoryFile.read(url), .read(HistoryFile.Contents(records: [new])), "and the write went ahead")

        // Another copy at the same moment never replaces the first.
        let second = try HistoryFile.preserveUnreadable(url, now: now)
        XCTAssertEqual(second.lastPathComponent, "history.json.unreadable-2027-01-15T080000Z-2")
        XCTAssertEqual(try Data(contentsOf: copies[0]), garbage)
        XCTAssertEqual(HistoryFile.unreadableCopies(of: url).count, 2)
    }

    func testTheCopyIsOwedUntilItIsMadeOrTheOriginalIsReplaced() throws {
        // Neither a copy nor a write can be made in a folder that is not there.
        let nowhere = folder.appendingPathComponent("gone/history.json")
        XCTAssertTrue(HistoryFile.write([record(hoursAgo: 0)], keeping: [], to: nowhere, copyingUnreadableFirst: true))
        XCTAssertFalse(HistoryFile.write([record(hoursAgo: 0)], keeping: [], to: nowhere, copyingUnreadableFirst: false))
        // No original to copy, but the write replaced whatever was owed.
        XCTAssertFalse(HistoryFile.write([record(hoursAgo: 0)], keeping: [], to: url, copyingUnreadableFirst: true))
    }
}
