// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// What the main window's History page shows, worked out from the records — pure, so the
// grouping, the search and the filters are testable without a window. The page itself is
// HistoryView.swift.

// MARK: - Filters

/// The page's filters: every dictation, the ones AI Rewrite rewrote, the edits of a
/// selection, and the ones that did not come out as asked.
public enum HistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all, rewritten, edits, failed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .rewritten: "AI Rewrite"
        case .edits: "Edits"
        case .failed: "Failed"
        }
    }

    func includes(_ record: TranscriptionRecord) -> Bool {
        let edit = record.refinement?.isSelectionEdit == true
        switch self {
        case .all: return true
        case .rewritten: return record.refinement != nil && !edit
        case .edits: return edit
        // Nothing transcribed, nothing heard, or a rewrite that fell back to the dictated
        // text: each pasted something other than what was asked for, or nothing.
        case .failed: return record.status != .success || record.refinement?.succeeded == false
        }
    }
}

// MARK: - Search

enum HistorySearch {
    /// Every word of the query is somewhere in the record — what was said, what was pasted,
    /// the selection an edit rewrote, the error, the apps or the prompt — ignoring case and
    /// accents.
    static func matches(_ record: TranscriptionRecord, query: String) -> Bool {
        Query(query).matches(Text(record))
    }

    /// What a record is searched by.
    struct Fields: Equatable {
        let text: String
        let errorMessage, originApp, destinationApp: String?
        let inputText, outputText, presetName, contextApp, undeliveredApp: String?

        init(_ record: TranscriptionRecord) {
            text = record.text
            errorMessage = record.errorMessage
            originApp = record.originApp
            destinationApp = record.destinationApp
            inputText = record.refinement?.inputText
            outputText = record.refinement?.outputText
            presetName = record.refinement?.presetName
            contextApp = record.refinement?.context?.appName
            undeliveredApp = record.undelivered?.app
        }

        /// Every field there is, a line each — what a word is looked for in.
        var joined: String {
            [text, errorMessage, originApp, destinationApp, inputText, outputText, presetName, contextApp, undeliveredApp]
                .compactMap { $0 }.joined(separator: "\n")
        }
    }

    /// A record as the search reads it: its fields and, where `foldsFaithfully` says it
    /// changes nothing found, their join folded once — so a key typed in the search looks
    /// for bytes in it instead of folding every record again, which at 20,000 records took
    /// a second or two, and ran twice a keystroke.
    struct Text {
        let fields: Fields
        /// Nil when the join holds a character outside `foldsFaithfully`'s table; such a
        /// record is searched as it always was.
        let folded: String?

        init(_ record: TranscriptionRecord) { self.init(fields: Fields(record)) }

        init(fields: Fields) {
            self.fields = fields
            let joined = fields.joined
            folded = HistorySearch.foldsFaithfully(joined) ? HistorySearch.folded(joined) : nil
        }
    }

    /// A search's words, each folded as `Text` folds — unless it holds a character outside
    /// the table, when it is looked for as it always was.
    struct Query {
        struct Word {
            let typed: Substring
            let folded: String?
        }

        let words: [Word]

        init(_ query: String) {
            words = query.split(whereSeparator: \.isWhitespace).map { word in
                Word(typed: word, folded: HistorySearch.foldsFaithfully(word) ? HistorySearch.folded(String(word)) : nil)
            }
        }

        var isEmpty: Bool { words.isEmpty }

        func matches(_ text: Text) -> Bool {
            // The join is made only for a word that needs it, as it was for every one.
            var joined: String?
            for word in words {
                if let needle = word.folded, let haystack = text.folded {
                    guard HistorySearch.contains(haystack, needle) else { return false }
                    continue
                }
                if joined == nil { joined = text.fields.joined }
                guard joined?.range(of: word.typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
                    return false
                }
            }
            return true
        }
    }

    /// Every record's `Text`, kept from one keystroke to the next and worked out again only
    /// for a record that changed or is new; one deleted is let go.
    final class Index {
        private var records: [TranscriptionRecord] = []
        private var texts: [Text] = []

        /// The texts of `records`, in their order.
        func texts(for records: [TranscriptionRecord]) -> [Text] {
            // An unchanged History is the same array, which compares at once.
            guard records != self.records else { return texts }
            var known: [UUID: Text] = [:]
            known.reserveCapacity(texts.count)
            for (record, text) in zip(self.records, texts) { known[record.id] = text }
            texts = records.map { record in
                let fields = Fields(record)
                if let text = known[record.id], text.fields == fields { return text }
                return Text(fields: fields)
            }
            self.records = records
            return texts
        }
    }

    /// Whether folding `string` first — case and accents, as the search ignores them — and
    /// then looking for a folded word byte for byte finds exactly what
    /// `range(of:options: [.caseInsensitive, .diacriticInsensitive])` finds, for a word and a
    /// text that both pass. Measured, not derived: on macOS 26 the two agreed on every one of
    /// over 30 million random texts and words drawn from this table, accents and capitals
    /// included (`HistoryAndUsageCacheTests` repeats a seeded sample of it). Outside it they
    /// do not: ß and the ligatures fold to two letters, which the original search matches in
    /// its own way; an accent on a CJK character or a symbol, or on nothing, survives
    /// folding; and kana, Devanagari, Thai and emoji — a skin tone, a joiner — are matched
    /// by grapheme in ways a byte search does not repeat. Anything outside the table is
    /// searched as it always was.
    static func foldsFaithfully(_ string: some StringProtocol) -> Bool {
        // A combining accent counts only on a letter of the Latin, Greek or Cyrillic rows.
        var afterLetter = false
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x0300...0x036F:
                // U+0345 folds to a letter of its own.
                guard scalar.value != 0x0345, afterLetter else { return false }
            // ß and ŉ fold to two letters; a soft hyphen is invisible.
            case 0x00DF, 0x00AD, 0x0149:
                return false
            case 0x0000...0x007F, 0x00A0...0x0237, 0x0370...0x03FF, 0x0400...0x0482, 0x048A...0x04FF,
                 0x1E00...0x1E99, 0x1EA0...0x1EF9:
                afterLetter = scalar.properties.isAlphabetic
            // Punctuation, currency, №, arrows, symbols and dingbats, CJK and Hangul: no
            // accent may follow them.
            case 0x2010...0x2027, 0x2030...0x205E, 0x20A0...0x20C0, 0x2100...0x214F, 0x2190...0x22FF,
                 0x2500...0x257F, 0x25A0...0x27BF, 0x3000...0x3029, 0x3030...0x303F, 0x4E00...0x9FFF, 0xAC00...0xD7A3:
                afterLetter = false
            default:
                return false
            }
        }
        return true
    }

    /// Case and accents folded away, and in one run of UTF-8 so it is searched in place.
    static func folded(_ string: String) -> String {
        var folded = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        folded.makeContiguousUTF8()
        return folded
    }

    /// `needle`'s bytes somewhere in `haystack`'s.
    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        let found = haystack.utf8.withContiguousStorageIfAvailable { text in
            needle.utf8.withContiguousStorageIfAvailable { word in
                memmem(text.baseAddress, text.count, word.baseAddress, word.count) != nil
            }
        }
        return (found ?? nil) ?? (haystack.range(of: needle, options: .literal) != nil)
    }
}

// MARK: - App and date

/// The day range History is narrowed to, beside the search and the filters.
public enum HistoryDates: Equatable, Hashable, Sendable {
    case anyTime, today, last7Days, last30Days
    /// One day the user picked.
    case day(Date)

    public static let presets: [HistoryDates] = [.anyTime, .today, .last7Days, .last30Days]

    public var title: String {
        switch self {
        case .anyTime: "Any time"
        case .today: "Today"
        case .last7Days: "Last 7 days"
        case .last30Days: "Last 30 days"
        case .day(let day): HistoryFormat.formatter("d MMM yyyy", calendar: .current).string(from: day)
        }
    }

    func includes(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        matcher(now: now, calendar: calendar)(date)
    }

    /// `includes`, with the range's first day — or the one day's bounds — worked out once
    /// for a whole pass over History rather than again for every record.
    func matcher(now: Date = Date(), calendar: Calendar = .current) -> (Date) -> Bool {
        func since(_ days: Int) -> (Date) -> Bool {
            let today = calendar.startOfDay(for: now)
            let first = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
            return { $0 >= first }
        }
        switch self {
        case .anyTime: return { _ in true }
        case .today: return since(1)
        case .last7Days: return since(7)
        case .last30Days: return since(30)
        case .day(let day):
            guard let bounds = calendar.dateInterval(of: .day, for: day) else {
                return { calendar.isDate($0, inSameDayAs: day) }
            }
            return { bounds.start <= $0 && $0 < bounds.end }
        }
    }
}

/// What History is narrowed to besides the filter and the search: the app a dictation went
/// to — named as its row names it (`HomeRecentEntry.place`, so "Record Window" and "Not
/// pasted" are there too) — and a range of days.
public struct HistoryNarrowing: Equatable, Sendable {
    public var app: String?
    public var dates: HistoryDates = .anyTime

    public init(app: String? = nil, dates: HistoryDates = .anyTime) {
        self.app = app
        self.dates = dates
    }

    public var isEmpty: Bool { app == nil && dates == .anyTime }

    func includes(_ record: TranscriptionRecord, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        matcher(now: now, calendar: calendar)(record)
    }

    /// `includes` for a whole pass over History: the days worked out once.
    func matcher(now: Date = Date(), calendar: Calendar = .current) -> (TranscriptionRecord) -> Bool {
        let dates = dates.matcher(now: now, calendar: calendar)
        guard let app else { return { dates($0.date) } }
        return { HomeRecentEntry.place(of: $0) == app && dates($0.date) }
    }

    /// Every place dictations went, the busiest first, with how many went there.
    public static func apps(in records: [TranscriptionRecord]) -> [(app: String, count: Int)] {
        var counts: [String: Int] = [:]
        for record in records { counts[HomeRecentEntry.place(of: record), default: 0] += 1 }
        return counts.map { (app: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.app.localizedCompare($1.app) == .orderedAscending }
    }
}

/// Which app on this Mac a name History kept stands for, so its row can carry the app's
/// icon (`AppIcons`, HomeView.swift) after the app was renamed, moved or replaced.
public enum AppIdentity {
    /// The bundle identifier recorded with that name, newest record first — from where the
    /// dictation started or went, or from an AI pass's focus context, which kept it before
    /// the records did.
    public static func bundleID(forAppNamed name: String, in records: [TranscriptionRecord]) -> String? {
        for record in records {
            if record.destinationApp == name, let id = record.destinationBundleID { return id }
            if record.originApp == name, let id = record.originBundleID { return id }
            if let context = record.refinement?.context, context.appName == name, let id = context.bundleID {
                return id
            }
        }
        return nil
    }

    /// The name without a trailing parenthesised channel: "T3 Code (Alpha)" → "T3 Code".
    static func baseName(_ name: String) -> String {
        guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return name }
        let base = name[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? name : base
    }

    /// An installed app that is another channel of the same one, when the app itself is
    /// gone — "T3 Code (Alpha)" drawn with "T3 Code (Beta)"'s icon once Alpha was replaced.
    /// The plain name is preferred, then the first in order; nil when nothing shares it.
    public static func sibling(of name: String, among installed: [String]) -> String? {
        let base = baseName(name)
        let matches = installed.filter { $0 != name && baseName($0) == base }
        if matches.contains(base) { return base }
        return matches.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first
    }
}

// MARK: - How long History keeps dictations

/// How long something History holds is kept: not at all past this session, a span of
/// days or months, or for good — one scale, as a cache-size slider is, used twice: for the
/// dictations (`SettingsKeys.historyRetention`) and for the audio of a failed one, kept
/// for a retry (`SettingsKeys.failedAudioRetention`).
///
/// *Don't keep* still keeps what this session made until the app quits: the record is
/// what an AI pass attaches to, what the "No connection" notice's Retry and the offline
/// drain read, and where a failed dictation's audio waits for them. It goes at quit, and
/// at the next launch should the app not have quit cleanly.
public enum HistoryRetention: String, CaseIterable, Identifiable, Sendable {
    case session = "none"
    case days7 = "7d"
    case days30 = "30d"
    case months3 = "3m"
    case months6 = "6m"
    case year = "1y"
    case forever

    /// What History keeps on an install that never chose — and on one that chose a number
    /// of dictations, before the choice became a span of time: nothing is deleted by an
    /// update.
    public static let `default` = HistoryRetention.forever
    /// What the audio of a failed dictation was always kept for.
    public static let defaultAudio = HistoryRetention.days7

    public var id: String { rawValue }

    /// A stored value; anything unknown (the old "300" and "1000" included) is `fallback`.
    public static func stored(_ raw: String?, default fallback: HistoryRetention = .default) -> HistoryRetention {
        raw.flatMap(HistoryRetention.init(rawValue:)) ?? fallback
    }

    /// The slider's label.
    public var title: String {
        switch self {
        case .session: "Don't keep"
        case .days7: "7 days"
        case .days30: "30 days"
        case .months3: "3 months"
        case .months6: "6 months"
        case .year: "1 year"
        case .forever: "Forever"
        }
    }

    /// The end of "History keeps …" / "Counted from …".
    public var phrase: String {
        switch self {
        case .session: "this session's dictations"
        case .days7: "the last 7 days of dictations"
        case .days30: "the last 30 days of dictations"
        case .months3: "the last 3 months of dictations"
        case .months6: "the last 6 months of dictations"
        case .year: "the last year of dictations"
        case .forever: "every dictation"
        }
    }

    /// The span, on the calendar; nil for the two that are not one.
    private var span: DateComponents? {
        switch self {
        case .session, .forever: nil
        case .days7: DateComponents(day: 7)
        case .days30: DateComponents(day: 30)
        case .months3: DateComponents(month: 3)
        case .months6: DateComponents(month: 6)
        case .year: DateComponents(year: 1)
        }
    }

    /// The oldest date it keeps; nil keeps everything. `sessionStart` is when this run of
    /// the app began — what *Don't keep* keeps from (`.distantFuture` at quit keeps nothing).
    func cutoff(now: Date = Date(), sessionStart: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .forever: return nil
        case .session: return sessionStart
        default:
            var back = span!
            back.day = back.day.map { -$0 }
            back.month = back.month.map { -$0 }
            back.year = back.year.map { -$0 }
            return calendar.date(byAdding: back, to: now) ?? now
        }
    }

    /// Until when something made at `date` is kept; nil for `forever` and `session`.
    func keptUntil(_ date: Date, calendar: Calendar = .current) -> Date? {
        span.flatMap { calendar.date(byAdding: $0, to: date) }
    }

    /// How many of `records` — newest first — it keeps: the rest are older than it allows.
    func keptCount(of records: [TranscriptionRecord], now: Date = Date(), sessionStart: Date,
                   calendar: Calendar = .current) -> Int {
        guard let cutoff = cutoff(now: now, sessionStart: sessionStart, calendar: calendar) else { return records.count }
        return records.firstIndex { $0.date < cutoff } ?? records.count
    }

    /// Whether audio kept this long is ever kept longer than History keeps its dictation —
    /// the audio goes with the record, so the shorter of the two is what counts.
    public func outlasts(_ other: HistoryRetention) -> Bool {
        guard let mine = Self.allCases.firstIndex(of: self),
              let theirs = Self.allCases.firstIndex(of: other) else { return false }
        return mine > theirs
    }
}

// MARK: - Days

/// One day of History: its records newest first, and what they came to.
public struct HistoryDay: Identifiable, Equatable, Sendable {
    let start: Date
    public let records: [TranscriptionRecord]

    public var id: Date { start }

    /// Words that ended up as text, counted as Home's week counts them.
    public var words: Int {
        records.reduce(0) { total, record in
            guard record.status == .success, record.refinement?.isSelectionEdit != true else { return total }
            return total + homeWordCount(record.deliveredText)
        }
    }

    /// The records that pass `filter`, `query` and `narrowing`, one day each, newest day
    /// first. History is kept newest first, and so is each day.
    static func group(_ records: [TranscriptionRecord], filter: HistoryFilter = .all, query: String = "",
                      narrowing: HistoryNarrowing = HistoryNarrowing(), now: Date = Date(),
                      calendar: Calendar = .current) -> [HistoryDay] {
        HistoryListing(records: records, filter: filter, query: query, narrowing: narrowing, now: now, calendar: calendar).days
    }

    /// "Today", "Yesterday", a weekday within the week, then "28 September" — with the year
    /// once it is not this one.
    public func title(now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
        let format = days > 1 && days < 7 ? "EEEE" : sameYear ? "d MMMM" : "d MMMM yyyy"
        return HistoryFormat.formatter(format, calendar: calendar).string(from: start)
    }

    /// The date under a title that does not already say it: "Monday" → "28 September".
    public func subtitle(now: Date = Date(), calendar: Calendar = .current) -> String? {
        let days = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day ?? 0
        guard days < 7 else { return nil }
        return HistoryFormat.formatter(days < 2 ? "EEEE, d MMMM" : "d MMMM", calendar: calendar).string(from: start)
    }
}

// MARK: - The page

/// What History's page shows for a filter, a search and a narrowing: the days, and beside
/// the search each filter's count — worked out together in one pass, since the page needs
/// both on every key typed. The search runs once a record, and the days' bounds once a day.
public struct HistoryListing: Equatable, Sendable {
    public var days: [HistoryDay] = []
    public var counts: [HistoryFilter: Int] = Dictionary(uniqueKeysWithValues: HistoryFilter.allCases.map { ($0, 0) })

    /// `texts` are the records' search texts in their order, kept between keystrokes
    /// (`HistorySearch.Index`); without them a record is folded as it is searched.
    init(records: [TranscriptionRecord], filter: HistoryFilter = .all, query: String = "",
         narrowing: HistoryNarrowing = HistoryNarrowing(), now: Date = Date(), calendar: Calendar = .current,
         texts: [HistorySearch.Text]? = nil) {
        let search = HistorySearch.Query(query)
        let narrowed = narrowing.matcher(now: now, calendar: calendar)
        let filters = HistoryFilter.allCases
        var tally = Array(repeating: 0, count: filters.count)
        // The day being gathered, and when it starts and ends.
        var gathered: [TranscriptionRecord] = []
        var start = Date.distantPast, end = Date.distantPast
        for (index, record) in records.enumerated() where narrowed(record) {
            if !search.isEmpty {
                let found = if let texts { search.matches(texts[index]) } else { search.matches(HistorySearch.Text(record)) }
                guard found else { continue }
            }
            for (position, item) in filters.enumerated() where item.includes(record) { tally[position] += 1 }
            guard filter.includes(record) else { continue }
            if !gathered.isEmpty, start <= record.date, record.date < end {
                gathered.append(record)
                continue
            }
            let bounds = calendar.dateInterval(of: .day, for: record.date)
            let recordStart = bounds?.start ?? calendar.startOfDay(for: record.date)
            if !gathered.isEmpty, recordStart == start {
                gathered.append(record)
                continue
            }
            // A record out of order starts a day of its own, as it always did.
            if !gathered.isEmpty { days.append(HistoryDay(start: start, records: gathered)) }
            gathered = [record]
            start = recordStart
            end = bounds?.end ?? recordStart
        }
        if !gathered.isEmpty { days.append(HistoryDay(start: start, records: gathered)) }
        counts = Dictionary(uniqueKeysWithValues: zip(filters, tally))
    }
}

/// History's page as it was last worked out, kept until something it is worked out from
/// changes: the page's body runs again for every key typed in the search, every row opened
/// and every busy day unfolded, and each time that was every record searched twice and
/// grouped. Now a key typed searches each record once, and a redraw that changed none of
/// them works nothing out.
public final class HistoryListingCache {
    private struct Key: Equatable {
        let records: [TranscriptionRecord]
        let filter: HistoryFilter
        let query: String
        let narrowing: HistoryNarrowing
        /// What "Today" and "Last 7 days" count from.
        let today: Date
        let calendar: Calendar
    }

    private var key: Key?
    private var last = HistoryListing(records: [])
    /// Apart from the listing: a key typed changes the search and leaves every text as it was.
    private let index = HistorySearch.Index()

    public init() {}

    public func listing(records: [TranscriptionRecord], filter: HistoryFilter, query: String, narrowing: HistoryNarrowing,
                 now: Date = Date(), calendar: Calendar = .current) -> HistoryListing {
        // An unchanged History is the same array, which compares at once.
        let key = Key(records: records, filter: filter, query: query, narrowing: narrowing,
                      today: calendar.startOfDay(for: now), calendar: calendar)
        guard key != self.key else { return last }
        let texts = HistorySearch.Query(query).isEmpty ? nil : index.texts(for: records)
        last = HistoryListing(records: records, filter: filter, query: query, narrowing: narrowing,
                              now: now, calendar: calendar, texts: texts)
        self.key = key
        return last
    }
}

/// Whether a plain dictation's whole text fits its closed History row, by the width of
/// that text, for the last few widths the rows were laid out at. The page keeps it past the
/// rows themselves (`HistoryRowFit`, HistoryView.swift) — and kept every width a window
/// was ever resized through, a frame at a time, for good.
public struct HistoryRowFits: Sendable {
    /// The width the rows have now, the one a row has while its Copy says Copied, and the
    /// last ones before a resize stopped.
    static let widthsKept = 4

    private var answers: [Int: [UUID: Bool]] = [:]
    /// The widths answered for, oldest first.
    private var widths: [Int] = []

    public init() {}

    public subscript(id: UUID, width: Int) -> Bool? {
        get { answers[width]?[id] }
        set {
            guard let newValue else {
                answers[width]?[id] = nil
                return
            }
            if answers[width] == nil {
                widths.append(width)
                if widths.count > Self.widthsKept { answers[widths.removeFirst()] = nil }
            }
            answers[width, default: [:]][id] = newValue
        }
    }

    /// How many answers are kept, over every width.
    var count: Int { answers.values.reduce(0) { $0 + $1.count } }
}

// MARK: - Formatting

public enum HistoryFormat {
    /// Made once per format and calendar: a `DateFormatter` is costly to build, and every
    /// History row asks for its clock each time it is drawn. Under `formattersLock`, which
    /// is what makes the unchecked access safe.
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    private static let formattersLock = NSLock()

    public static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let key = "\(format)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        formattersLock.lock()
        defer { formattersLock.unlock() }
        if let known = formatters[key] { return known }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        formatters[key] = formatter
        return formatter
    }

    /// "14:02" — a row's day is its section's.
    public static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("HH:mm", calendar: calendar).string(from: date)
    }

    /// "Wednesday 30 September 2026, 14:02".
    public static func full(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("EEEE d MMMM yyyy, HH:mm", calendar: calendar).string(from: date)
    }

    /// "8 s", "1:05".
    public static func length(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }
        let total = max(1, Int(seconds.rounded()))
        return total < 60 ? "\(total) s" : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// How long a failed dictation's audio is kept for a retry, as the end of "The audio is
    /// kept …": "until Thursday 8 October", "until SpeechText quits". The shorter of the two
    /// settings decides, since the audio goes with its record.
    public static func audioKept(_ record: TranscriptionRecord, audio: HistoryRetention, history: HistoryRetention,
                          calendar: Calendar = .current) -> String {
        let rule = audio.outlasts(history) ? history : audio
        if rule == .session { return "until SpeechText quits" }
        guard let until = rule.keptUntil(record.date, calendar: calendar) else { return "for as long as History keeps it" }
        return "until " + formatter("EEEE d MMMM", calendar: calendar).string(from: until)
    }

    /// What History holds now, under its settings: "125 dictations since 14 September · 70 KB".
    public static func storageSummary(count: Int, since: Date?, bytes: Int64, calendar: Calendar = .current) -> String {
        guard count > 0 else { return "No dictations kept yet." }
        let dictations = count == 1 ? "1 dictation" : "\(HomeFormat.integer(count)) dictations"
        let start = since.map { " since " + formatter("d MMMM", calendar: calendar).string(from: $0) } ?? ""
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return dictations + start + " · " + size
    }

    /// What History keeps, in a sentence or two — History's foot.
    public static func retentionSummary(history: HistoryRetention, audio: HistoryRetention) -> String {
        let kept = history == .session
            ? "History keeps this session's dictations, until SpeechText quits."
            : "History keeps \(history.phrase) on this Mac."
        let rule = audio.outlasts(history) ? history : audio
        let audioKept: String = switch rule {
        case .session: "until SpeechText quits"
        case .forever: "as long as the dictation"
        case .year: "for a year"
        default: "for " + rule.title
        }
        return kept + " A failed one's audio is kept \(audioKept), for a retry."
    }

    /// The speech engine a record names, as a person would: "Groq", "On this Mac".
    public static func engine(_ provider: String) -> String {
        switch STTProviderType(rawValue: provider) {
        case .apple: "Apple"
        case .local: "On this Mac"
        case .some(let type): type.vendor.displayName
        case nil: provider
        }
    }

    /// The language a record was dictated in, by name; nil when the model chose.
    public static func language(_ locale: String?) -> String? {
        guard let locale, locale != autoLanguageID, !locale.isEmpty else { return nil }
        let code = String(locale.prefix { $0 != "-" && $0 != "_" })
        return spokenLanguageCatalog.first { $0.id == code }?.displayName ?? locale
    }
}
