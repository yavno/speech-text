// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import SpeechTextCore

// MARK: - History

/// The main window's History: every dictation, grouped by day, with search and filters. A
/// row opens in place to show what was said beside what AI Rewrite made of it, with the
/// prompt it chose; a failed one retries from the audio kept for a week. Built in Home's
/// parts — the hairline tables, the app marks, the tags — so the two read as one window.
struct HistoryView: View {
    let actions: MainWindowActions
    var navigation: MainWindowNavigation?
    @State private var query = ""
    @State private var filter: HistoryFilter = .all
    @State private var narrowing = HistoryNarrowing()
    @AppStorage(SettingsKeys.historyRetention) private var retentionRaw = HistoryRetention.default.rawValue
    @AppStorage(SettingsKeys.failedAudioRetention) private var audioRetentionRaw = HistoryRetention.defaultAudio.rawValue
    @State private var expanded: UUID?
    /// The days opened past their first `HistoryDaySection.shown` dictations.
    @State private var openDays: Set<Date> = []
    @State private var confirmingClear = false
    /// The days and the counts, worked out again only when the records, the search, the
    /// filter, the narrowing or the day changes — not for a row opened or hovered.
    @State private var listings = HistoryListingCache()
    @FocusState private var searchFocused: Bool

    private var history: TranscriptionHistory { .shared }

    var body: some View {
        let records = history.records
        let listing = listings.listing(records: records, filter: filter, query: query, narrowing: narrowing)
        let days = listing.days
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                header(records)
                Section {
                    if days.isEmpty {
                        empty(nothingAtAll: records.isEmpty)
                            .padding(.top, 26)
                    }
                    ForEach(days) { day in
                        HistoryDaySection(day: day, expanded: $expanded,
                                          showsAll: Binding(get: { openDays.contains(day.id) },
                                                            set: { if $0 { openDays.insert(day.id) } else { openDays.remove(day.id) } }))
                            .padding(.top, 26)
                    }
                    if !records.isEmpty { footer.padding(.top, 34) }
                } header: {
                    toolbar(records, counts: listing.counts)
                }
            }
            .frame(maxWidth: HomeView.columnWidth)
            .padding(.horizontal, 48)
            .padding(.top, 32)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .background {
            // ⌘F finds, as it does in every list on the Mac.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .confirmationDialog("Clear all of History?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) {
                expanded = nil
                history.clear()
            }
        } message: {
            Text("Every dictation and the audio kept for a retry are deleted. This can't be undone.")
        }
        // A notice's Show: the window may be opening on History or already showing it.
        .onAppear(perform: takeRequestedNarrowing)
        .onChange(of: navigation?.historyNarrowing) { takeRequestedNarrowing() }
    }

    /// Narrows to what a notice asked for, with nothing else hiding it — and gives the
    /// request back, so the narrowing is the user's from here on.
    private func takeRequestedNarrowing() {
        guard let requested = navigation?.historyNarrowing else { return }
        navigation?.historyNarrowing = nil
        narrowing = requested
        filter = .all
        query = ""
    }

    // MARK: Title

    private func header(_ records: [TranscriptionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("History")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-1.2)
                    .foregroundStyle(MainColor.ink)
                Spacer(minLength: 12)
                if !records.isEmpty {
                    Text(records.count == 1 ? "1 dictation" : "\(HomeFormat.integer(records.count)) dictations")
                        .font(.system(size: 13))
                        .foregroundStyle(MainColor.ink3)
                        .monospacedDigit()
                }
                HistorySettingsButton { actions.openSettingsAt(.history) }
            }
            Text(MainPage.history.lead)
                .font(.system(size: 14))
                .foregroundStyle(MainColor.ink2)
        }
        .padding(.bottom, 20)
    }

    // MARK: Search and filters

    /// Pinned under the title while the days scroll past. `counts` are each filter's under
    /// the search, the app and the dates, from the same pass as the days.
    private func toolbar(_ records: [TranscriptionRecord], counts: [HistoryFilter: Int]) -> some View {
        let search = HStack(spacing: 8) {
            HistorySearchField(query: $query, focused: $searchFocused)
                .frame(minWidth: 150, maxWidth: 300)
            HistoryAppMenu(app: $narrowing.app, records: records)
            HistoryDatesMenu(dates: $narrowing.dates, records: records)
        }
        let filters = HistoryFilterSwitch(filter: $filter, counts: counts)
        // On one line while it fits; in a narrow window the filters go under the search.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                search
                Spacer(minLength: 6)
                filters
            }
            VStack(alignment: .leading, spacing: 8) {
                search
                filters
            }
        }
        .padding(.vertical, 10)
        .background(MainColor.card)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MainColor.separator).frame(height: 1)
        }
    }

    // MARK: Nothing to show

    @ViewBuilder
    private func empty(nothingAtAll: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if nothingAtAll {
                Text("Nothing dictated yet. Press \(shortcutText(for: .inline)) in any app, speak, and press it again — every dictation is kept here.")
            } else if query.isEmpty && narrowing.isEmpty {
                Text("No \(filter == .edits ? "edits" : filter == .failed ? "failed dictations" : "dictations rewritten by AI") yet.")
            } else if query.isEmpty {
                Text("Nothing \(filter == .all ? "" : "in \(filter.title) ")\(narrowingPhrase).")
            } else {
                Text("Nothing matches “\(query)”\(filter == .all ? "" : " in \(filter.title)")\(narrowing.isEmpty ? "" : " " + narrowingPhrase).")
            }
            if !nothingAtAll {
                HStack(spacing: 8) {
                    if !query.isEmpty {
                        Button("Clear search") { query = "" }
                            .buttonStyle(SetupButtonStyle(kind: .secondary, height: 30))
                    }
                    if !narrowing.isEmpty {
                        Button("Any app, any time") { narrowing = HistoryNarrowing() }
                            .buttonStyle(SetupButtonStyle(kind: .secondary, height: 30))
                    }
                    if filter != .all {
                        Button("Show all") { filter = .all }
                            .buttonStyle(SetupButtonStyle(kind: .secondary, height: 30))
                    }
                }
            }
        }
        .font(.system(size: 13.5))
        .foregroundStyle(MainColor.ink2)
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(MainColor.separator, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
    }

    /// "in Slack, in the last 7 days".
    private var narrowingPhrase: String {
        var parts: [String] = []
        if let app = narrowing.app { parts.append(app == "Not pasted" ? "that wasn't pasted" : "in \(app)") }
        switch narrowing.dates {
        case .anyTime: break
        case .today: parts.append("today")
        case .day(let day): parts.append("on " + HistoryFormat.formatter("d MMMM", calendar: .current).string(from: day))
        case let dates: parts.append("in the " + dates.title.lowercased())
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Foot

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(HistoryFormat.retentionSummary(history: HistoryRetention.stored(retentionRaw),
                                                audio: HistoryRetention.stored(audioRetentionRaw, default: .defaultAudio)))
                .font(.system(size: 12.5))
                .foregroundStyle(MainColor.ink3)
                .fixedSize(horizontal: false, vertical: true)
            HomeLink(title: "Change") { actions.openSettingsAt(.history) }
            Spacer(minLength: 12)
            HistoryQuietButton(title: "Clear History…", symbol: "trash", destructive: true) { confirmingClear = true }
        }
    }
}

// MARK: - Search field

private struct HistorySearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MainColor.ink3)
            TextField("Search what you said", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(MainColor.ink)
                .focused(focused)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(MainColor.ink3)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(shape.fill(MainColor.panel))
        .overlay(shape.strokeBorder(focused.wrappedValue ? MainColor.okInk.opacity(0.55) : MainColor.panelBorder,
                                    lineWidth: focused.wrappedValue ? 1.5 : 1))
        .animation(.easeOut(duration: 0.12), value: focused.wrappedValue)
    }
}

/// A narrowing beside the search, drawn as the search field is: its name, or what it is
/// set to — then on the soft green, with an ✕ to clear it. Opens a popover to choose.
private struct HistoryNarrowButton<Choices: View>: View {
    let symbol: String
    let title: String
    let isSet: Bool
    let clear: () -> Void
    @ViewBuilder var choices: (_ dismiss: @escaping () -> Void) -> Choices
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 6) {
            Button { showing.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isSet ? MainColor.okInk : MainColor.ink3)
                    Text(title)
                        .font(.system(size: 13, weight: isSet ? .medium : .regular))
                        .foregroundStyle(isSet ? MainColor.ink : MainColor.ink2)
                        .lineLimit(1)
                    if !isSet {
                        Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(MainColor.ink3)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isSet {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(MainColor.ink3)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(shape.fill(isSet ? MainColor.phosphorSoft : hovering ? MainColor.panel.opacity(0.7) : MainColor.panel))
        .overlay(shape.strokeBorder(isSet ? MainColor.okInk.opacity(0.35) : MainColor.panelBorder, lineWidth: 1))
        .onHover { hovering = $0 }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            choices { showing = false }
        }
    }
}

/// One choice in a narrowing's popover: a mark, its name, how many, and a tick when set.
private struct HistoryChoiceRow<Mark: View>: View {
    let title: String
    var count: Int?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var mark: () -> Mark
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                mark()
                Text(title).font(.system(size: 13)).foregroundStyle(MainColor.ink).lineLimit(1)
                Spacer(minLength: 12)
                if let count {
                    Text(HomeFormat.integer(count)).font(.system(size: 12)).foregroundStyle(MainColor.ink3).monospacedDigit()
                }
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(MainColor.okInk)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? MainColor.panel : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The app a dictation went to, as its row names it.
private struct HistoryAppMenu: View {
    @Binding var app: String?
    let records: [TranscriptionRecord]

    var body: some View {
        HistoryNarrowButton(symbol: "app.dashed", title: app ?? "App", isSet: app != nil, clear: { app = nil }) { dismiss in
            // Counted only while the popover is open, not on every key typed in the search.
            let apps = HistoryNarrowing.apps(in: records)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    HistoryChoiceRow(title: "Any app", selected: app == nil, action: { app = nil; dismiss() }) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(MainColor.ink3)
                            .frame(width: 20, height: 20)
                    }
                    ForEach(apps, id: \.app) { item in
                        HistoryChoiceRow(title: item.app, count: item.count, selected: app == item.app,
                                         action: { app = item.app; dismiss() }) {
                            HomeAppMark(app: item.app, size: 20, radius: 6)
                        }
                    }
                }
                .padding(6)
            }
            .frame(width: 250)
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A range of days, or one day picked on a calendar.
private struct HistoryDatesMenu: View {
    @Binding var dates: HistoryDates
    let records: [TranscriptionRecord]

    var body: some View {
        HistoryNarrowButton(symbol: "calendar", title: dates == .anyTime ? "Date" : dates.title,
                            isSet: dates != .anyTime, clear: { dates = .anyTime }) { dismiss in
            VStack(alignment: .leading, spacing: 1) {
                ForEach(HistoryDates.presets, id: \.self) { preset in
                    HistoryChoiceRow(title: preset.title, selected: dates == preset, action: { dates = preset; dismiss() }) {
                        EmptyView()
                    }
                }
                Rectangle().fill(MainColor.separator).frame(height: 1).padding(.vertical, 5)
                HistoryCalendar(selected: selectedDay, records: records) { day in
                    dates = .day(day)
                    dismiss()
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .padding(6)
            .frame(width: 250)
        }
    }

    private var selectedDay: Date? {
        if case .day(let day) = dates { return day }
        return nil
    }
}

/// One month as History draws it, in place of the system's calendar: the month and its
/// arrows, the weekdays in the user's order, and the days as round cells — the one picked
/// lit as a pressed key is, today ringed, a day with dictations marked by a dot under it, and the days
/// still to come (and the months after this one) out of reach.
private struct HistoryCalendar: View {
    let selected: Date?
    let records: [TranscriptionRecord]
    let pick: (Date) -> Void
    @State private var month: Date?

    private static let cell: CGFloat = 30
    private var calendar: Calendar { .current }

    var body: some View {
        let shown = month ?? calendar.startOfMonth(selected ?? Date())
        let thisMonth = calendar.startOfMonth(Date())
        let days = Set(records.map { calendar.startOfDay(for: $0.date) })
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text(HistoryFormat.formatter("LLLL yyyy", calendar: calendar).string(from: shown))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MainColor.ink)
                    .padding(.leading, 6)
                Spacer(minLength: 8)
                arrow("chevron.left", label: "Previous month", enabled: true) { move(shown, by: -1) }
                arrow("chevron.right", label: "Next month", enabled: shown < thisMonth) { move(shown, by: 1) }
            }
            .frame(height: 26)
            grid(month: shown, days: days)
        }
    }

    private func move(_ shown: Date, by months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: shown)
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HistoryCalendarArrow(symbol: symbol, enabled: enabled, action: action)
            .accessibilityLabel(label)
    }

    private func grid(month: Date, days: Set<Date>) -> some View {
        // In English, as the rest of History, two letters each: "Mo Tu We".
        var english = calendar
        english.locale = Locale(identifier: "en_GB")
        let symbols = english.shortStandaloneWeekdaySymbols.map { String($0.prefix(2)) }
        let first = calendar.firstWeekday - 1
        let weekdays = Array(symbols[first...] + symbols[..<first])
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let slots: [Date?] = Array(repeating: nil, count: lead)
            + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: month) }
        let weeks = stride(from: 0, to: slots.count, by: 7).map { Array(slots[$0..<min($0 + 7, slots.count)]) }
        let today = calendar.startOfDay(for: Date())
        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(MainColor.ink3)
                        .frame(width: Self.cell, height: 20)
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { index in
                        if index < week.count, let day = week[index] {
                            HistoryCalendarDay(
                                number: calendar.component(.day, from: day),
                                isSelected: selected.map { calendar.isDate($0, inSameDayAs: day) } ?? false,
                                isToday: day == today,
                                hasDictations: days.contains(day),
                                isFuture: day > today,
                                size: Self.cell) { pick(day) }
                        } else {
                            Color.clear.frame(width: Self.cell, height: Self.cell)
                        }
                    }
                }
            }
        }
    }
}

private struct HistoryCalendarArrow: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(enabled ? MainColor.ink2 : MainColor.ink3.opacity(0.5))
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering && enabled ? MainColor.panel : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

private struct HistoryCalendarDay: View {
    let number: Int
    let isSelected: Bool
    let isToday: Bool
    let hasDictations: Bool
    let isFuture: Bool
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("\(number)")
                .font(.system(size: 12.5, weight: isSelected || isToday ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(ink)
                .frame(width: size, height: size)
                .background {
                    if isSelected {
                        Circle().fill(SetupColor.phosphor)
                    } else if hovering && !isFuture {
                        Circle().fill(MainColor.panel)
                    }
                }
                .overlay {
                    if isToday && !isSelected { Circle().strokeBorder(MainColor.okInk.opacity(0.55), lineWidth: 1) }
                }
                .overlay(alignment: .bottom) {
                    if hasDictations {
                        Circle().fill(isSelected ? SetupColor.screen.opacity(0.7) : MainColor.speech)
                            .frame(width: 3.5, height: 3.5)
                            .padding(.bottom, 3.5)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .onHover { hovering = $0 }
    }

    private var ink: Color {
        if isSelected { return SetupColor.screen }
        if isFuture { return MainColor.ink3.opacity(0.5) }
        if isToday { return MainColor.okInk }
        return hasDictations ? MainColor.ink : MainColor.ink3
    }
}

private extension Calendar {
    func startOfMonth(_ date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }
}

/// The gear beside History's count: Settings, at how much History keeps.
private struct HistorySettingsButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? MainColor.ink : MainColor.ink3)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? MainColor.panel : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("How much History keeps")
        .accessibilityLabel("History settings")
    }
}

/// The filters as the intro card's tabs are drawn: a capsule switch, each with its count.
private struct HistoryFilterSwitch: View {
    @Binding var filter: HistoryFilter
    let counts: [HistoryFilter: Int]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HistoryFilter.allCases) { item in
                button(item)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MainColor.ink.opacity(0.06)))
    }

    private func button(_ item: HistoryFilter) -> some View {
        let selected = filter == item
        let count = counts[item] ?? 0
        return Button { filter = item } label: {
            HStack(spacing: 5) {
                Text(item.title)
                    .foregroundStyle(selected ? MainColor.ink : MainColor.ink2)
                Text(HomeFormat.integer(count))
                    .monospacedDigit()
                    .foregroundStyle(item == .failed && count > 0 ? MainColor.problem : MainColor.ink3)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MainColor.card)
                        .shadow(color: Color(hex: 0x182C20).opacity(0.12), radius: 1.5, y: 1)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color(hex: 0x182C20).opacity(0.12), lineWidth: 0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - A day

/// A day's name, what it came to, and its dictations in one hairline table — Home's Recent,
/// a day at a time. A busy day shows its latest few and keeps the rest behind Show all, so
/// the days after it are a short scroll away; a search or a filter that leaves a few shows
/// them all.
private struct HistoryDaySection: View {
    let day: HistoryDay
    @Binding var expanded: UUID?
    @Binding var showsAll: Bool

    /// Enough for a morning's dictations, and about a screen.
    static let shown = 8

    private var records: [TranscriptionRecord] {
        // Never fold away the dictation that is open.
        let openIndex = day.records.firstIndex { $0.id == expanded } ?? 0
        guard !showsAll, day.records.count > Self.shown + 2, openIndex < Self.shown else { return day.records }
        return Array(day.records.prefix(Self.shown))
    }

    var body: some View {
        let records = records
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(day.title())
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.15)
                    .foregroundStyle(MainColor.ink)
                if let subtitle = day.subtitle() {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(MainColor.ink3)
                }
                Spacer(minLength: 12)
                Text(summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(MainColor.ink3)
                    .monospacedDigit()
            }
            VStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Rectangle().fill(MainColor.separator).frame(height: 1) }
                    HistoryRow(record: record, isExpanded: expanded == record.id) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            expanded = expanded == record.id ? nil : record.id
                        }
                    }
                }
                if records.count < day.records.count || (showsAll && day.records.count > Self.shown + 2) {
                    Rectangle().fill(MainColor.separator).frame(height: 1)
                    HistoryShowAllRow(hidden: day.records.count - records.count, showsAll: showsAll) {
                        withAnimation(.easeOut(duration: 0.2)) { showsAll.toggle() }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MainColor.panelBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var summary: String {
        let count = day.records.count
        let words = day.words
        return (count == 1 ? "1 dictation" : "\(count) dictations")
            + (words > 0 ? " · \(HomeFormat.integer(words)) \(words == 1 ? "word" : "words")" : "")
    }
}

/// The foot of a busy day: how many more there are, or a way to fold them back.
private struct HistoryShowAllRow: View {
    let hidden: Int
    let showsAll: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(showsAll ? "Show fewer" : "Show all · \(hidden) more")
                Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(hovering ? MainColor.okInk : MainColor.ink2)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(hovering ? MainColor.panel : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - A dictation

/// One dictation: closed, Home's Recent row with its time; open, everything History knows
/// about it under the row.
private struct HistoryRow: View {
    let record: TranscriptionRecord
    let isExpanded: Bool
    let toggle: () -> Void
    /// Worked out once per row, not on every redraw of it.
    private let entry: HomeRecentEntry
    @State private var hovering = false
    @State private var copied = false
    /// The row's text as it is laid out, and the whole text measured unseen beside it —
    /// only until `HistoryRowFit` knows the answer for this width.
    @State private var textSize: CGSize = .zero
    @State private var fullTextHeight: CGFloat = 0

    init(record: TranscriptionRecord, isExpanded: Bool, toggle: @escaping () -> Void) {
        self.record = record
        self.isExpanded = isExpanded
        self.toggle = toggle
        entry = HomeRecentEntry(record)
    }

    /// A plain dictation that fits the row's two lines has nothing more to show, so it
    /// does not open at all; one cut short opens to its whole text.
    private var canExpand: Bool { !showsWholeText || HistoryRowFit.fits[record.id, fitWidth] == false }
    private var fitWidth: Int { Int(textSize.width.rounded()) }
    private var isOpen: Bool { isExpanded && canExpand }

    /// A dictation pasted as it was heard: AI Rewrite and the Edit shortcut have two texts
    /// to show side by side under the row, a plain dictation only the one the row holds.
    private var showsWholeText: Bool { record.status == .success && record.refinement == nil }

    var body: some View {
        let entry = entry
        let isOpen = isOpen
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: { if canExpand { toggle() } }) {
                    HStack(spacing: 14) {
                        HomeEntryMark(entry: entry)
                        VStack(alignment: .leading, spacing: 5) {
                            // Closed, the row is the preview on one run of lines; open, a
                            // plain dictation's whole text with its line breaks.
                            Text(isOpen && showsWholeText ? entry.text : entry.preview)
                                .font(textFont)
                                .foregroundStyle(entry.status == .success ? MainColor.ink : MainColor.ink2)
                                // Open, a plain dictation's row is its whole text: there is no
                                // second text to set beside it, so a pane would only repeat it.
                                .lineLimit(isOpen && showsWholeText ? nil : 2)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: isOpen && showsWholeText)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                                    textSize = size
                                    settleFit()
                                }
                                .background(alignment: .topLeading) {
                                    // Only a plain dictation needs to know whether it is cut
                                    // short; anything else always opens. Measured once per
                                    // width, and only while closed, when the text is the two lines.
                                    if showsWholeText, !isOpen, textSize.width > 0,
                                       HistoryRowFit.fits[record.id, fitWidth] == nil {
                                        textMeasure(entry)
                                    }
                                }
                            HStack(spacing: 6) {
                                Text(entry.place).fontWeight(.medium).foregroundStyle(MainColor.ink)
                                Text("·")
                                Text(HistoryFormat.clock(record.date)).monospacedDigit()
                                if let length = HistoryFormat.length(record.duration) {
                                    Text("·")
                                    Text(length).monospacedDigit()
                                }
                                HomeEntryTags(tags: entry.tags)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(MainColor.ink2)
                            .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(HistoryFactsTip(facts: canExpand ? nil : { facts }))
                .accessibilityHint(canExpand ? (isOpen ? "Hides the details" : "Shows the details") : "")

                HStack(spacing: 6) {
                    quickAction(entry)
                    // Built only while it can be seen — a button with its own hover and
                    // tooltip in every row cost the scroll — and its place held meanwhile,
                    // so the text beside it never reflows.
                    if hovering || isOpen {
                        HistoryDeleteButton(record: record)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { HistoryRowFit.deleteWidth = $0 }
                    } else {
                        Color.clear.frame(width: HistoryRowFit.deleteWidth, height: 28)
                    }
                }
                .fixedSize()
                // Kept in place when the row cannot open, so every row's buttons line up.
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering || isOpen ? MainColor.ink2 : MainColor.ink3)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .opacity(canExpand ? 1 : 0)
                    .onTapGesture { if canExpand { toggle() } }
                    .accessibilityHidden(true)
            }
            .padding(.leading, 14)
            .padding(.trailing, 16)
            .padding(.vertical, 14)

            if isOpen {
                HistoryDetail(record: record)
                    .transition(.opacity)
            }
        }
        // Only the grey under the row fades: an animation on the whole row ran its every
        // view again for each row the pointer crossed while scrolling.
        .background {
            Rectangle().fill(hovering || isOpen ? MainColor.panel : .clear)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        // The whole row is the hover's, its empty right side and the places held for
        // Copy and Delete included — they draw nothing, so nothing would take the pointer.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if !record.deliveredText.isEmpty {
                Button("Copy") { HistoryClipboard.copy(record.deliveredText) }
            }
            if record.refinement?.succeeded == true, !record.text.isEmpty, record.text != record.deliveredText {
                Button(record.refinement?.isSelectionEdit == true ? "Copy Instruction" : "Copy What You Said") {
                    HistoryClipboard.copy(record.text)
                }
            }
            if record.isRetryable {
                Button("Retry") { Task { @MainActor in await HistoryRetry.shared.retry(record.id) } }
            }
            Divider()
            Button("Delete", role: .destructive) { TranscriptionHistory.shared.delete(record) }
        }
    }

    private var textFont: Font { .system(size: entry.status == .success ? 14 : 13) }

    /// The whole text measured unseen, as the open row shows it, beside the closed row's
    /// two lines — so the row knows whether opening it would show anything more.
    private func textMeasure(_ entry: HomeRecentEntry) -> some View {
        Text(entry.text).font(textFont)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                fullTextHeight = height
                settleFit()
            }
            .hidden()
            .accessibilityHidden(true)
    }

    /// Writes down whether the whole text fits the closed row, once both heights are in.
    private func settleFit() {
        guard showsWholeText, !isOpen, textSize.width > 0, fullTextHeight > 0,
              HistoryRowFit.fits[record.id, fitWidth] == nil else { return }
        HistoryRowFit.fits[record.id, fitWidth] = fullTextHeight <= textSize.height + 1
    }

    /// For a row that cannot open: the facts it would have shown, as its tooltip.
    private var facts: String {
        var parts: [String] = [HistoryFormat.full(record.date)]
        if let length = HistoryFormat.length(record.duration) { parts.append(length) }
        let engine = historyEngine(record)
        if !engine.isEmpty { parts.append(engine) }
        if let origin = record.originApp, let destination = record.destinationApp, origin != destination {
            parts.append("started in \(origin), pasted into \(destination)")
        }
        if let undelivered = record.undelivered {
            parts.append(undelivered.app.map { "no connection, so not pasted into \($0)" } ?? "no connection, so not pasted")
        }
        return parts.joined(separator: "  ·  ")
    }

    /// What the row offers on the right: Retry for a closed failure, Copy otherwise — on
    /// hover, and always while the row is open. Copy stays in the row when it opens, so
    /// the text beside it keeps its width and does not reflow.
    @ViewBuilder
    private func quickAction(_ entry: HomeRecentEntry) -> some View {
        if entry.status != .success {
            if entry.canRetry && !isOpen { HomeRetryButton(id: record.id) }
        } else {
            if hovering || isOpen || copied {
                HomeCopyButton(text: record.deliveredText, copied: $copied)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                        if !copied { HistoryRowFit.copyWidth = width }
                    }
            } else {
                Color.clear.frame(width: HistoryRowFit.copyWidth, height: 28)
            }
        }
    }
}

/// What History has learnt about its rows' layout, kept past the rows themselves: a lazy
/// list drops a row's state when it scrolls away, and measuring every row again each time
/// it came back cost the scroll.
@MainActor
enum HistoryRowFit {
    /// Whether a plain dictation's whole text fits its closed row, at a width of text — for
    /// the last few widths only, so resizing the window does not keep one per width.
    static var fits = HistoryRowFits()
    /// The widths of the Copy and Delete buttons, whose places a row holds while they are
    /// not built; measured whenever one is shown.
    static var copyWidth: CGFloat = 47
    static var deleteWidth: CGFloat = 46
}

/// A row that cannot open carries its facts as a tooltip; a row that can carries none —
/// and so no tooltip to track — and its facts are not worked out at all.
private struct HistoryFactsTip: ViewModifier {
    let facts: (() -> String)?

    func body(content: Content) -> some View {
        if let facts { content.help(facts()) } else { content }
    }
}

/// Delete as a compact button beside Copy, drawn and hovered like it.
private struct HistoryDeleteButton: View {
    let record: TranscriptionRecord
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { TranscriptionHistory.shared.delete(record) }
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MainColor.ink)
                .frame(minWidth: 14)
        }
        .buttonStyle(SetupButtonStyle(kind: .secondary, height: 28, hovered: hovering))
        .onHover { hovering = $0 }
        .help("Delete")
        .accessibilityLabel("Delete")
    }
}

/// What heard it: "ElevenLabs · Ukrainian".
private func historyEngine(_ record: TranscriptionRecord) -> String {
    guard record.hasSpeech else { return "" }
    return [HistoryFormat.engine(record.provider), HistoryFormat.language(record.locale)]
        .compactMap { $0 }.joined(separator: " · ")
}

enum HistoryClipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - What History knows about it

/// An open row: what was said beside what AI Rewrite made of it, with the prompt it chose;
/// what went wrong and the way to retry; where it went, what heard it, and the actions.
private struct HistoryDetail: View {
    let record: TranscriptionRecord
    @State private var copiedSaid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch record.status {
            case .failed: problem(record.errorMessage ?? "Transcription failed.", danger: true)
            case .empty: problem("Nothing was heard in this recording — a muted microphone, or the shortcut pressed with nothing said.",
                                 danger: false)
            case .success: texts
            }
            facts
            if let said = saidText {
                HomeCopyButton(text: said, title: record.refinement?.isSelectionEdit == true ? "Copy instruction" : "Copy what you said",
                               copied: $copiedSaid, height: 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 58)
        .padding(.trailing, 16)
        .padding(.bottom, 16)
    }

    // MARK: The texts

    @ViewBuilder
    private var texts: some View {
        if let refinement = record.refinement {
            let edit = refinement.isSelectionEdit
            if edit {
                (Text("Instruction  ").foregroundStyle(MainColor.ink3)
                 + Text(record.text.isEmpty ? "None — polished" : record.text).foregroundStyle(MainColor.ink))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 10) {
                HistoryTextPane(title: edit ? "Selected text" : "Dictated", symbol: edit ? "text.cursor" : "waveform",
                                text: refinement.inputText, ai: false, model: edit ? nil : engine)
                if refinement.succeeded {
                    HistoryTextPane(title: edit ? "Rewritten" : "AI output", symbol: "sparkles",
                                    text: refinement.outputText, ai: true,
                                    note: edit ? "Replaced the selection" : "Pasted",
                                    model: modelName(refinement))
                } else {
                    HistoryTextPane(title: edit ? "Rewritten" : "AI output", symbol: "sparkles",
                                    text: "", ai: true, model: modelName(refinement),
                                    failure: (edit ? "Didn't work — the selection was left as it was." : "Didn't work — the dictated text was pasted instead.")
                                        + (refinement.errorMessage.map { "\n\($0)" } ?? ""))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        // A plain dictation has no pane: the open row above already shows its whole text,
        // and its engine is named in the facts below.
    }

    private var engine: String { historyEngine(record) }

    private func modelName(_ refinement: TranscriptionRecord.Refinement) -> String {
        let name = LLMProviderType(rawValue: refinement.provider)
            .map { chatModel(provider: $0, id: refinement.model).displayName }
        return HomeEngines.plainName(name ?? refinement.model)
    }

    // MARK: A failure

    private func problem(_ message: String, danger: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(danger ? MainColor.problem : MainColor.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(record.isRetryable
                     ? "The audio is kept \(HistoryFormat.audioKept(record, audio: TranscriptionHistory.shared.audioRetention, history: TranscriptionHistory.shared.retention)), for a retry with the settings you have now."
                     : "The audio is no longer kept, so this one can't be retried.")
                    .font(.system(size: 12))
                    .foregroundStyle(MainColor.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if record.isRetryable {
                HomeRetryButton(id: record.id, title: "Retry", height: 30)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(danger ? MainColor.problem.opacity(0.07) : MainColor.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(danger ? MainColor.problem.opacity(0.18) : MainColor.panelBorder, lineWidth: 1))
    }

    // MARK: Where, when, what heard it

    private var facts: some View {
        var parts: [String] = [HistoryFormat.full(record.date)]
        if let length = HistoryFormat.length(record.duration) { parts.append(length) }
        // A rewrite names its engine under what it heard; anything else names it here.
        if record.status != .success || record.refinement == nil || record.refinement?.isSelectionEdit == true,
           !engine.isEmpty {
            parts.append(engine)
        }
        if let origin = record.originApp, let destination = record.destinationApp, origin != destination {
            parts.append("started in \(origin), pasted into \(destination)")
        }
        if let undelivered = record.undelivered {
            parts.append(undelivered.app.map { "no connection, so not pasted into \($0)" } ?? "no connection, so not pasted")
        }
        let context = record.refinement?.context?.summary
        return VStack(alignment: .leading, spacing: 4) {
            Text(parts.joined(separator: "  ·  "))
            if let context, !context.isEmpty {
                (Text("AI Rewrite was told it was for ") + Text(context).foregroundStyle(MainColor.ink2))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(record.refinement?.context?.promptBlock ?? "")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(MainColor.ink3)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    // What was pasted is copied, and the record deleted, from the row's own buttons, which
    // stay in place while the row is open; only what was said, when it differs, has a
    // button down here.

    /// What reached the app: the rewrite, or what was said when there was none — and for
    /// an edit that failed, nothing new.
    private var pastedText: String {
        guard let refinement = record.refinement, refinement.isSelectionEdit else { return record.deliveredText }
        return refinement.succeeded ? refinement.outputText : ""
    }

    /// What was said, when it is not already what the Copy button copies.
    private var saidText: String? {
        guard record.status == .success, !record.text.isEmpty, record.text != pastedText,
              record.refinement != nil else { return nil }
        return record.text
    }
}

/// A text with its name above it and what produced it below: what was said on white with
/// the engine that heard it, AI Rewrite's on its violet with the model that ran it — the
/// prompt it chose is the row's tag, just above.
private struct HistoryTextPane: View {
    let title: String
    let symbol: String
    let text: String
    let ai: Bool
    var note: String?
    var model: String?
    var failure: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ai ? MainColor.aiInk : MainColor.okInk)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MainColor.ink)
                if let note {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MainColor.ink3)
                }
                Spacer(minLength: 6)
            }
            if let failure {
                Text(failure)
                    .font(.system(size: 12.5))
                    .foregroundStyle(MainColor.problem)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(text.isEmpty ? "No text" : text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(text.isEmpty ? MainColor.ink3 : MainColor.ink)
                    .lineSpacing(3.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let model {
                Text(model)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MainColor.ink3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(ai ? MainColor.aiSoft : MainColor.card))
        .overlay(shape.strokeBorder(ai ? MainColor.ai.opacity(0.22) : MainColor.panelBorder, lineWidth: 1))
    }
}

/// A button that stays out of the way until pointed at: Delete, Clear History…
struct HistoryQuietButton: View {
    let title: String
    let symbol: String
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(hovering ? (destructive ? MainColor.problem : MainColor.ink) : MainColor.ink2)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(hovering ? (destructive ? MainColor.problemSoft : MainColor.panel) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
