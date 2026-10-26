// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import SpeechTextCore

// MARK: - Usage

/// The main window's Usage, in Home's language — its grey surfaces, its tray of white tiles,
/// its hairline tables and the display's squares for anything that rises: how much faster
/// speaking was than typing, the period's four numbers, the words (or the cost) day by day,
/// what they were and where they went, which engines did the work, and how it is all
/// counted. Everything comes from History, counted on this Mac.
struct UsageView: View {
    @State private var period: UsagePeriod = .month
    @AppStorage(SettingsKeys.typingWordsPerMinute) private var storedTyping = 0.0
    /// Worked out again only when History, the typing speed or the day changes.
    @State private var summaries = UsageSummaryCache()

    private var history: TranscriptionHistory { .shared }
    private var typing: Double { storedTyping >= 10 ? storedTyping : HomeWeek.typingWordsPerMinute }

    /// A chat model's name from the catalogues, without its picker note; the ID itself for
    /// one no catalogue lists.
    static func chatModelName(_ id: String) -> String {
        HomeEngines.plainName(knownChatModelName(id: id))
    }

    var body: some View {
        let summary = summaries.summary(records: history.records, period: period, typingWordsPerMinute: typing)
        GeometryReader { proxy in
            let wide = proxy.size.width >= 1000
            ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    MainPageTitle(.usage) {
                        MainSwitch(items: UsagePeriod.allCases.map { ($0, $0.title) }, selection: $period)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        UsageSpeedPanel(summary: summary, typing: typing, typingIsMeasured: storedTyping >= 10,
                                        storedTyping: $storedTyping)
                        UsageNumbers(summary: summary)
                    }
                    UsageChart(summary: summary, period: period)

                    UsageKinds(summary: summary)
                    UsageEngines(summary: summary)
                    UsageRequests(summary: summary)
                    if !summary.overhead.isEmpty { UsageOverhead(overhead: summary.overhead) }
                    UsageLimits()
                    UsageApps(summary: summary)
                    UsageCounting(summary: summary, storedTyping: $storedTyping, wide: wide)
                }
                .frame(maxWidth: HomeView.columnWidth)
                .padding(.horizontal, 48)
                .padding(.top, 32)
                .padding(.bottom, 44)
                .frame(width: proxy.size.width)
                .id("top")
            }
            .scrollIndicators(.automatic)
            // The page opens at its top: built while the window settles its size, the
            // scroll view otherwise kept an offset from the foot.
            .onAppear { DispatchQueue.main.async { scroller.scrollTo("top", anchor: .top) } }
            }
        }
    }
}

// MARK: - Speaking vs typing

/// The page's opening, on Home's grey: how many times faster speaking was, said in words,
/// and the two speeds as columns of the display's squares.
private struct UsageSpeedPanel: View {
    let summary: UsageSummary
    let typing: Double
    let typingIsMeasured: Bool
    @Binding var storedTyping: Double
    @State private var editing = false

    var body: some View {
        MainPanel(padding: EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26)) {
            HStack(alignment: .bottom, spacing: 32) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: "bolt").font(.system(size: 11.5)).foregroundStyle(MainColor.okInk)
                        Text("Speaking vs typing").font(.system(size: 13.5, weight: .medium)).foregroundStyle(MainColor.ink)
                    }
                    if let speedup = summary.speedup {
                        (Text(UsageFormat.speedup(speedup)).font(.system(size: 50, weight: .bold)).tracking(-2)
                            .foregroundColor(MainColor.ink)
                            + Text(" faster").font(.system(size: 26, weight: .semibold)).foregroundColor(MainColor.okInk))
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                        line
                    } else {
                        Text("Speak, and see")
                            .font(.system(size: 32, weight: .bold))
                            .tracking(-1.1)
                            .foregroundStyle(MainColor.ink)
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                        Text("Once you've dictated for a minute or so, this says how much faster speaking is than typing — and how much time it saved you.")
                            .font(.system(size: 14))
                            .foregroundStyle(MainColor.ink2)
                            .lineSpacing(4)
                            .frame(maxWidth: 480, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button { editing = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "keyboard").font(.system(size: 12))
                            Text(typingIsMeasured ? "You type at \(Int(typing)) wpm" : "Measure your typing speed")
                        }
                    }
                    .buttonStyle(SetupButtonStyle(kind: .secondary, height: 32))
                    .pointingHandCursor()
                    .padding(.top, 18)
                    .popover(isPresented: $editing, arrowEdge: .bottom) {
                        UsageTypingSpeedEditor(storedTyping: $storedTyping)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                columns
            }
        }
    }

    private var line: some View {
        let talk = Int((summary.speakingWordsPerMinute ?? 0).rounded())
        return (Text("You speak at ") + Text("\(talk)").fontWeight(.semibold).foregroundColor(MainColor.ink)
                + Text(" words a minute and type at ") + Text("\(Int(typing))").fontWeight(.semibold).foregroundColor(MainColor.ink)
                + Text(typingIsMeasured ? "." : " — an average, until you set yours.")
                + Text(" In this period that's ")
                + Text("≈ \(HomeFormat.durationText(minutes: summary.savedMinutes))").fontWeight(.semibold).foregroundColor(MainColor.ink)
                + Text(" you didn't spend typing."))
            .font(.system(size: 14))
            .foregroundStyle(MainColor.ink2)
            .lineSpacing(4)
            .frame(maxWidth: 520, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Speaking in the speech green, typing in grey, each as tall as its speed.
    private var columns: some View {
        let talk = summary.speakingWordsPerMinute ?? 0
        let most = max(talk, typing, 1)
        let rows = 18
        return HStack(alignment: .bottom, spacing: 26) {
            column(value: talk, label: "Speaking", lit: Int((talk / most * Double(rows)).rounded()),
                   color: MainColor.speech.opacity(0.7), rows: rows)
            column(value: typing, label: "Typing", lit: max(1, Int((typing / most * Double(rows)).rounded())),
                   color: MainColor.ink.opacity(0.28), rows: rows)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speaking \(Int(talk)) words a minute, typing \(Int(typing))")
    }

    private func column(value: Double, label: String, lit: Int, color: Color, rows: Int) -> some View {
        VStack(spacing: 8) {
            (Text(value > 0 ? "\(Int(value.rounded()))" : "—").font(.system(size: 18, weight: .bold))
                + Text(" wpm").font(.system(size: 11, weight: .medium)).foregroundColor(MainColor.ink3))
                .foregroundStyle(MainColor.ink)
                .monospacedDigit()
            MainPixelColumn(lit: Array(repeating: color, count: min(rows, lit)), columns: 6, rows: rows)
                .animation(.easeOut(duration: 0.3), value: lit)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(MainColor.ink2)
        }
    }
}

// MARK: - Your typing speed

/// The typing speed, measured: a sentence to copy, the clock starting with the first key
/// and stopping at its end — then the result to keep, or another go. Words are counted the
/// standard way, five characters each, and only the characters typed right count. Under
/// it, the number set by hand for anyone who knows theirs.
private struct UsageTypingSpeedEditor: View {
    @Binding var storedTyping: Double

    /// Prose on no particular subject, with the capitals, commas and longer words real
    /// writing has — an easy line of short words would measure a speed nobody types at.
    private static let sentences = [
        "Curiosity rarely arrives on schedule; it tends to show up halfway through something else, uninvited and oddly persistent.",
        "Somewhere between the third draft and the fourth, the original question quietly changed, and nobody noticed until much later.",
        "Old maps were confident about coastlines and vague about interiors, which is roughly how most of us describe our own plans.",
        "A good explanation feels obvious afterwards, as if the idea had been waiting patiently for someone to say it out loud.",
        "Weather, traffic and the price of coffee: three things everyone discusses, few understand, and nobody can change before Tuesday.",
        "The quietest rooms are seldom silent; listen carefully and there's a refrigerator humming, a clock ticking, a neighbor's piano.",
    ]

    @State private var sentence = Self.sentences.randomElement() ?? Self.sentences[0]
    @State private var typed = ""
    @State private var started: Date?
    @State private var result: Int?
    @FocusState private var focused: Bool

    private var value: Int { Int(storedTyping >= 10 ? storedTyping : HomeWeek.typingWordsPerMinute) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How fast do you type?")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MainColor.ink)
                Text("Type the sentence below. The clock starts with your first key.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(MainColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let result {
                outcome(result)
            } else {
                test
            }

            Rectangle().fill(MainColor.separator).frame(height: 1)

            HStack(spacing: 8) {
                Text("Or set it yourself")
                    .font(.system(size: 12))
                    .foregroundStyle(MainColor.ink2)
                Spacer(minLength: 6)
                stepButton("minus", by: -5)
                Text("\(value) wpm")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MainColor.ink)
                    .monospacedDigit()
                    .frame(minWidth: 58)
                stepButton("plus", by: 5)
            }
            if storedTyping >= 10 {
                Button("Use the average, 40 wpm") { storedTyping = 0 }
                    .buttonStyle(SetupInlineLinkStyle(size: 12))
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    /// The sentence, each character coloured as it is typed: done in ink, a mistake
    /// marked, the rest waiting in grey.
    private var test: some View {
        VStack(alignment: .leading, spacing: 10) {
            sentenceText
                .font(.system(size: 14))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MainColor.panel))
            TextField("Start typing here", text: $typed, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(MainColor.ink)
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MainColor.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? MainColor.okInk.opacity(0.55) : MainColor.panelBorder, lineWidth: focused ? 1.5 : 1))
                .onChange(of: typed) { _, text in take(text) }
                .onSubmit { finish() }
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(started.map { "\(Int(context.date.timeIntervalSince($0)))s" } ?? "Not started")
                        .font(.system(size: 11.5))
                        .foregroundStyle(MainColor.ink3)
                        .monospacedDigit()
                }
                Spacer()
                Text("\(min(typed.count, sentence.count)) / \(sentence.count)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(MainColor.ink3)
                    .monospacedDigit()
            }
        }
    }

    private var sentenceText: Text {
        let target = Array(sentence), input = Array(typed)
        var text = Text(verbatim: "")
        for (index, character) in target.enumerated() {
            let piece = Text(verbatim: String(character))
            if index < input.count {
                text = text + (input[index] == character
                    ? piece.foregroundColor(MainColor.ink)
                    : piece.foregroundColor(MainColor.problem).underline(color: MainColor.problem))
            } else {
                text = text + piece.foregroundColor(MainColor.ink3)
            }
        }
        return text
    }

    private func outcome(_ wpm: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(wpm)")
                    .font(.system(size: 40, weight: .bold))
                    .tracking(-1.5)
                    .foregroundStyle(MainColor.ink)
                    .monospacedDigit()
                Text("words a minute")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MainColor.ink2)
            }
            HStack(spacing: 8) {
                Button("Use \(wpm) wpm") { storedTyping = Double(wpm) }
                    .buttonStyle(SetupButtonStyle(kind: .primary, height: 30))
                    .disabled(storedTyping == Double(wpm))
                Button("Try again") { reset() }
                    .buttonStyle(SetupButtonStyle(kind: .secondary, height: 30))
                if storedTyping == Double(wpm) {
                    Label("Saved", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MainColor.okInk)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MainColor.panel))
    }

    private func take(_ text: String) {
        if text.contains("\n") {
            typed = text.replacingOccurrences(of: "\n", with: "")
            finish()
            return
        }
        if started == nil, !text.isEmpty { started = Date() }
        if text.count >= sentence.count { finish() }
    }

    /// Characters typed right, five to a word, over the minutes since the first key.
    private func finish() {
        guard let started, !typed.isEmpty else { return }
        let seconds = max(Date().timeIntervalSince(started), 1)
        let right = zip(typed, sentence).filter { $0 == $1 }.count
        result = max(1, Int((Double(right) / 5 / (seconds / 60)).rounded()))
    }

    private func reset() {
        let others = Self.sentences.filter { $0 != sentence }
        sentence = others.randomElement() ?? sentence
        typed = ""
        started = nil
        result = nil
        focused = true
    }

    private func stepButton(_ symbol: String, by step: Int) -> some View {
        Button {
            storedTyping = Double(min(160, max(10, value + step)))
        } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 12, height: 12)
        }
        .buttonStyle(SetupButtonStyle(kind: .secondary, height: 26))
    }
}

// MARK: - The four numbers

/// Home's tray: four white tiles, each a number named, measured and explained.
private struct UsageNumbers: View {
    let summary: UsageSummary

    var body: some View {
        MainTray {
            tile(symbol: "text.alignleft", title: "Words dictated",
                 value: [.number(HomeFormat.integer(summary.words))],
                 label: "in \(HomeFormat.integer(summary.dictations)) \(summary.dictations == 1 ? "dictation" : "dictations")")
            tile(symbol: "clock", title: "Time saved", value: saved,
                 label: "vs typing at \(Int(summary.typingWordsPerMinute)) wpm")
            tile(symbol: "creditcard", title: "Spent",
                 value: summary.spent > 0 ? [.approx, .number(HomeFormat.money(summary.spent))] : [.number("$0")],
                 label: spentLabel)
            tile(symbol: "sparkles", title: "Rewritten by AI",
                 value: [.number(HomeFormat.integer(summary.rewrites)), .unit(summary.rewrites == 1 ? "dictation" : "dictations")],
                 label: aiLabel)
        }
    }

    private var saved: [HomeStat.Part] {
        let (hours, minutes) = HomeFormat.duration(minutes: summary.savedMinutes)
        var parts: [HomeStat.Part] = [.approx]
        if let hours { parts += [.number("\(hours)"), .unit("h")] }
        if let minutes { parts += [.number(hours == nil ? "\(minutes)" : " \(minutes)"), .unit("min")] }
        if hours == nil && minutes == nil { parts += [.number("0"), .unit("min")] }
        return parts
    }

    /// An estimate, always said so: the date of the list prices, and any model they do
    /// not cover, by name.
    private var spentLabel: String {
        let unpriced = summary.unpricedModels.isEmpty ? ""
            : "not counting \(summary.unpricedModels.joined(separator: ", "))"
        if summary.spent > 0 {
            let estimate = UsagePrices.disclaimer.prefix(1).uppercased() + UsagePrices.disclaimer.dropFirst()
            return unpriced.isEmpty ? estimate : estimate + " · " + unpriced
        }
        if !unpriced.isEmpty { return unpriced.prefix(1).uppercased() + unpriced.dropFirst() }
        return summary.dictations > 0 ? "Models on this Mac cost nothing" : "Nothing dictated yet"
    }

    /// The words AI Rewrite delivered, and the selections edited — what it did, rather than
    /// a share of every dictation, which reads as a verdict.
    private var aiLabel: String {
        let words = summary.kinds[.rewritten]?.words ?? 0
        let edits = summary.edits > 0
            ? "\(HomeFormat.integer(summary.edits)) \(summary.edits == 1 ? "selection" : "selections") edited" : nil
        guard summary.rewrites > 0 else { return edits.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Nothing rewritten yet" }
        let written = "\(HomeFormat.integer(words)) \(words == 1 ? "word" : "words") written"
        return edits.map { written + ", and \($0)" } ?? written
    }

    private func tile(symbol: String, title: String, value: [HomeStat.Part], label: String) -> some View {
        MainTile {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MainColor.okInk)
                        .frame(width: 14)
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MainColor.ink)
                        .lineLimit(1)
                }
                HomeStat(symbol: symbol, title: title, value: value, label: label).number(size: 28)
                    .foregroundStyle(MainColor.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(MainColor.ink3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - The chart

/// The period day by day — weeks for 90 days, months for a long History — each a column of
/// the display's squares on Home's grey: what was pasted as said in the speech green, what
/// AI Rewrite wrote in its violet on top. The same columns can show the cost instead.
private struct UsageChart: View {
    let summary: UsageSummary
    let period: UsagePeriod
    @State private var showsCost = false
    @State private var hovered: Int?

    private static let rows = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader(title, detail: detail) {
                MainSwitch(items: [(false, "Words"), (true, "Cost")], selection: $showsCost, height: 22)
            }
            MainPanel(padding: EdgeInsets(top: 22, leading: 22, bottom: 16, trailing: 22)) {
                VStack(alignment: .leading, spacing: 14) {
                    chart
                    HStack(spacing: 16) {
                        legendItem(MainColor.speech.opacity(0.7), showsCost ? "Speech to text" : "Dictated")
                        legendItem(MainColor.ai, showsCost ? "AI Rewrite" : "Rewritten by AI")
                        Spacer(minLength: 8)
                        Text("Tallest: " + (showsCost ? HomeFormat.estimate(summary.mostCost)
                                                    : "\(HomeFormat.integer(summary.mostWords)) words"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(MainColor.ink3)
                            .monospacedDigit()
                    }
                }
            }
        }
        .onChange(of: period) { hovered = nil }
    }

    private var title: String {
        let unit = switch summary.granularity { case .day: "day"; case .week: "week"; case .month: "month" }
        return (showsCost ? "Spending" : "Words") + " by " + unit
    }

    /// The bar pointed at, or the period's total.
    private var detail: String {
        if let hovered, summary.buckets.indices.contains(hovered) {
            let bucket = summary.buckets[hovered]
            return UsageFormat.title(bucket.start, granularity: summary.granularity) + " · "
                + (showsCost ? HomeFormat.estimate(bucket.cost) : "\(HomeFormat.integer(bucket.words)) words")
        }
        let total = showsCost ? "\(HomeFormat.estimate(summary.spent)) in all · \(UsagePrices.disclaimer)"
            : "\(HomeFormat.integer(summary.words)) words in all"
        guard let since = summary.chartSince else { return total }
        return total + " · since " + HistoryFormat.formatter("d MMM", calendar: .current).string(from: since) + ", when History starts"
    }

    private func legendItem(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 12)).foregroundStyle(MainColor.ink2)
        }
    }

    private var chart: some View {
        let buckets = summary.buckets
        let count = max(buckets.count, 1)
        let labelEvery = buckets.count > 16 ? 5 : 1
        let height = CGFloat(Self.rows) * TechnoSkin.pixelPitch
        return VStack(spacing: 8) {
            GeometryReader { proxy in
                let slot = proxy.size.width / CGFloat(count)
                let columns = max(1, min(4, Int((slot - 4) / TechnoSkin.pixelPitch)))
                Canvas { context, size in
                    let pitch = TechnoSkin.pixelPitch, cell = TechnoSkin.pixel
                    for (index, bucket) in buckets.enumerated() {
                        let (lower, upper) = rows(bucket)
                        let dim = hovered != nil && hovered != index
                        let barWidth = CGFloat(columns) * pitch - 2
                        let x0 = (CGFloat(index) + 0.5) * slot - barWidth / 2
                        for row in 0..<Self.rows {
                            let color: Color = row < lower ? MainColor.speech.opacity(dim ? 0.3 : 0.7)
                                : row < lower + upper ? MainColor.ai.opacity(dim ? 0.4 : 1)
                                : MainColor.ink.opacity(0.045)
                            for column in 0..<columns {
                                let rect = CGRect(x: x0 + CGFloat(column) * pitch, y: size.height - cell - CGFloat(row) * pitch,
                                                  width: cell, height: cell)
                                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = min(buckets.count - 1, max(0, Int(point.x / slot)))
                    case .ended: hovered = nil
                    }
                }
            }
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(detail)

            HStack(spacing: 0) {
                ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
                    Text((buckets.count - 1 - index) % labelEvery == 0
                         ? UsageFormat.label(bucket.start, granularity: summary.granularity, dayCount: buckets.count) : " ")
                        .font(.system(size: 10.5, weight: index == hovered ? .semibold : .regular))
                        .foregroundStyle(index == hovered ? MainColor.ink : MainColor.ink3)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// A bar's squares: how many in the speech green, how many in violet above them. A
    /// bar with anything in it keeps at least one square, and so does its AI part.
    private func rows(_ bucket: UsageSummary.Bucket) -> (Int, Int) {
        let lower = showsCost ? bucket.speechCost : Double(bucket.dictatedWords)
        let upper = showsCost ? bucket.aiCost : Double(bucket.rewrittenWords)
        let top = showsCost ? max(summary.mostCost, 0.0001) : Double(max(summary.mostWords, 1))
        let total = lower + upper
        guard total > 0 else { return (0, 0) }
        let lit = min(Self.rows, max(1, Int((total / top * Double(Self.rows)).rounded())))
        let ai = upper > 0 ? min(lit, max(1, Int((Double(lit) * upper / total).rounded()))) : 0
        return (lit - ai, ai)
    }
}

// MARK: - By kind

/// What the dictations were, as Home's hairline table: a row each, its share as a bar.
private struct UsageKinds: View {
    let summary: UsageSummary

    var body: some View {
        let mostWords = max(1, UsageSummary.Kind.allCases.map { summary.kinds[$0]?.words ?? 0 }.max() ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader("By kind", detail: "words · ≈ cost")
            MainTable {
                ForEach(Array(UsageSummary.Kind.allCases.enumerated()), id: \.offset) { index, kind in
                    if index > 0 { MainRule() }
                    row(kind, use: summary.kinds[kind] ?? .init(), mostWords: mostWords)
                }
            }
        }
    }

    private func row(_ kind: UsageSummary.Kind, use: UsageSummary.KindUse, mostWords: Int) -> some View {
        let (title, symbol, ai, noun): (String, String, Bool, String) = switch kind {
        case .dictated: ("Dictated", "mic", false, "dictations")
        case .rewritten: ("Rewritten by AI", "sparkles", true, "dictations")
        case .edit: ("Edit selection", "pencil", true, "edits")
        }
        return HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ai ? MainColor.aiInk : MainColor.okInk)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(MainColor.ink)
                    Text("\(HomeFormat.integer(use.count)) \(use.count == 1 ? String(noun.dropLast()) : noun)"
                         + (kind == .edit ? "" : " · \(HomeFormat.integer(use.words)) words"))
                        .font(.system(size: 12))
                        .foregroundStyle(MainColor.ink3)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(use.cost > 0 ? HomeFormat.money(use.cost) : use.count > 0 ? "$0" : "—")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MainColor.ink)
                        .monospacedDigit()
                }
                UsageBar(fraction: kind == .edit ? 0 : CGFloat(use.words) / CGFloat(mostWords),
                         color: ai ? MainColor.ai : MainColor.speech.opacity(0.7), minimum: use.count > 0 ? 5 : 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

/// A thin bar on a faint track.
private struct UsageBar: View {
    let fraction: CGFloat
    let color: Color
    var minimum: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(MainColor.ink.opacity(0.06))
                Capsule().fill(color).frame(width: max(minimum, proxy.size.width * min(1, fraction)))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

// MARK: - Where the words went

private struct UsageApps: View {
    let summary: UsageSummary

    var body: some View {
        let shown = Array(summary.apps.prefix(8))
        let most = max(1, shown.first?.words ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader("Where your words went",
                              detail: summary.apps.count > shown.count ? "top \(shown.count) of \(summary.apps.count)" : nil)
            MainTable {
                if shown.isEmpty {
                    Text("Nothing pasted in this period.")
                        .font(.system(size: 13))
                        .foregroundStyle(MainColor.ink2)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { MainRule() }
                    HStack(spacing: 12) {
                        HomeAppMark(app: app.app, size: 24, radius: 7)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(app.app).font(.system(size: 13.5, weight: .medium)).foregroundStyle(MainColor.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\(HomeFormat.integer(app.words)) words")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(MainColor.ink2)
                                    .monospacedDigit()
                            }
                            UsageBar(fraction: CGFloat(app.words) / CGFloat(most), color: MainColor.speech.opacity(0.55))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }
}

// MARK: - By engine

/// Every engine that did the work in the period, as Home's Engines table: the step in a
/// column of its own, then what ran it, how much of it, and what it cost at its list price
/// — or that it ran on this Mac, or has no price here.
private struct UsageEngines: View {
    let summary: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader("By engine", detail: "≈ " + UsagePrices.disclaimer)
            MainTable {
                if summary.engines.isEmpty {
                    Text("Nothing dictated in this period.")
                        .font(.system(size: 13))
                        .foregroundStyle(MainColor.ink2)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(summary.engines.enumerated()), id: \.element.id) { index, engine in
                    if index > 0 { MainRule() }
                    row(engine)
                }
            }
        }
    }

    private func row(_ engine: UsageSummary.EngineUse) -> some View {
        let ai = engine.step == .ai
        return HStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: ai ? "sparkles" : "waveform")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ai ? MainColor.aiInk : MainColor.okInk)
                    .frame(width: 16)
                Text(ai ? "AI Rewrite" : "Speech").font(.system(size: 14)).foregroundStyle(MainColor.ink2)
            }
            .padding(.horizontal, 16)
            .frame(width: 170, alignment: .leading)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .trailing) { Rectangle().fill(MainColor.separator).frame(width: 1) }

            HStack(spacing: 10) {
                Text(name(engine)).font(.system(size: 14, weight: .medium)).foregroundStyle(MainColor.ink)
                Text(vendor(engine)).font(.system(size: 13)).foregroundStyle(MainColor.ink3)
                // Beside the name rather than in a column of its own, so the amounts line
                // up whether a row has it or not.
                if engine.isLocal {
                    MainChip(title: "Free on this Mac", tint: .green)
                }
            }
            .lineLimit(1)
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ai ? aiUses(engine) : "\(minutes(engine.minutes)) of audio")
                .font(.system(size: 13))
                .foregroundStyle(MainColor.ink2)
                .monospacedDigit()
                .frame(width: 140, alignment: .leading)

            Group {
                if engine.isLocal {
                    Text("$0").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(MainColor.ink)
                } else if let cost = engine.cost {
                    Text(HomeFormat.money(cost)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(MainColor.ink)
                } else {
                    Text("Not priced").font(.system(size: 12.5)).foregroundStyle(MainColor.ink3)
                        .help("SpeechText has no list price for this model, so it isn't counted in Spent.")
                }
            }
            .monospacedDigit()
            .frame(width: 120, alignment: .trailing)
            .padding(.trailing, 16)
        }
        .frame(minHeight: 48)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func name(_ engine: UsageSummary.EngineUse) -> String {
        switch engine.step {
        case .speech:
            if let model = engine.provider, let type = STTProviderType(rawValue: engine.key) {
                HomeEngines.plainName(sttModel(vendor: type.vendor, id: model).displayName)
            } else {
                HistoryFormat.engine(engine.key)
            }
        case .ai: UsageView.chatModelName(engine.key)
        }
    }

    private func vendor(_ engine: UsageSummary.EngineUse) -> String {
        switch engine.step {
        case .speech:
            switch STTProviderType(rawValue: engine.key) {
            case .apple: "On-device recognizer"
            case .local: "Model on this Mac"
            case .some(let type) where engine.provider != nil: type.vendor.displayName
            // Written before History kept the model, so only the engine is known.
            default: "model not recorded"
            }
        case .ai:
            switch LLMProviderType(rawValue: engine.provider ?? "") {
            case .anthropic: "Anthropic"
            case .groq: "Groq"
            case .openai: "OpenAI"
            case .local: "On this Mac"
            // Before AI Rewrite ran models itself (2026-10-16).
            case nil where engine.provider == "ollama": "Ollama · on this Mac"
            case nil: engine.provider ?? ""
            }
        }
    }

    /// "7 rewrites · 2 edits": the dictations it rewrote and the selections it edited.
    private func aiUses(_ engine: UsageSummary.EngineUse) -> String {
        let rewrites = engine.uses - engine.edits
        var parts: [String] = []
        if rewrites > 0 || engine.edits == 0 {
            parts.append("\(HomeFormat.integer(rewrites)) \(rewrites == 1 ? "rewrite" : "rewrites")")
        }
        if engine.edits > 0 {
            parts.append("\(HomeFormat.integer(engine.edits)) \(engine.edits == 1 ? "edit" : "edits")")
        }
        return parts.joined(separator: " · ")
    }

    private func minutes(_ value: Double) -> String {
        value < 1 ? "\(max(1, Int((value * 60).rounded()))) s" : HomeFormat.durationText(minutes: value)
    }
}

// MARK: - Requests

/// Every request the period's dictations made, by model, in the vendors' own units: audio
/// sent and billed, tokens, refusals, and how long an answer typically took. Counted from
/// History's ledger (`UsageEvent`), so a dictation that fell back or was retried counts
/// each request it paid for.
private struct UsageRequests: View {
    let summary: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader("Requests", detail: detail)
            MainTable {
                if summary.requests.isEmpty {
                    Text(summary.ledgerSince == nil && summary.dictations > 0
                         ? "Requests are counted from this update on."
                         : "No requests to a provider in this period.")
                        .font(.system(size: 13))
                        .foregroundStyle(MainColor.ink2)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(summary.requests.enumerated()), id: \.element.id) { index, use in
                    if index > 0 { MainRule() }
                    row(use)
                }
            }
        }
    }

    private var detail: String? {
        guard let since = summary.ledgerSince, let oldest = summary.since, oldest < since else {
            return "as the providers' replies count them"
        }
        return "counted since " + HistoryFormat.formatter("d MMMM", calendar: .current).string(from: since)
    }

    private func row(_ use: UsageSummary.RequestUse) -> some View {
        let ai = use.step == .ai
        return HStack(spacing: 12) {
            Image(systemName: ai ? "sparkles" : "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ai ? MainColor.aiInk : MainColor.okInk)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(name(use)).font(.system(size: 13.5, weight: .medium)).foregroundStyle(MainColor.ink)
                    Text(use.vendor.displayName).font(.system(size: 12.5)).foregroundStyle(MainColor.ink3)
                }
                .lineLimit(1)
                Text(units(use))
                    .font(.system(size: 12))
                    .foregroundStyle(MainColor.ink2)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(HomeFormat.integer(use.requests)) \(use.requests == 1 ? "request" : "requests")")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MainColor.ink)
                if use.failed > 0 {
                    Text("\(use.failed) refused")
                        .font(.system(size: 12))
                        .foregroundStyle(MainColor.problem)
                }
            }
            .monospacedDigit()
            .frame(width: 110, alignment: .trailing)

            Text(use.typicalLatency.map(UsageFormat.wait) ?? "—")
                .font(.system(size: 13))
                .foregroundStyle(MainColor.ink2)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
                .help("A typical wait for an answer: half were faster, half slower.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func name(_ use: UsageSummary.RequestUse) -> String {
        switch use.step {
        case .speech: HomeEngines.plainName(sttModel(vendor: use.vendor, id: use.model).displayName)
        case .ai: UsageView.chatModelName(use.model)
        }
    }

    /// "12 min sent · 14 min billed", "48.2k tokens in · 3.1k out".
    private func units(_ use: UsageSummary.RequestUse) -> String {
        switch use.step {
        case .ai:
            guard use.inputTokens + use.outputTokens > 0 else { return "no token counts reported" }
            return "\(UsageFormat.tokens(use.inputTokens)) tokens in · \(UsageFormat.tokens(use.outputTokens)) out"
        case .speech:
            let sent = "\(UsageFormat.audio(use.audioSeconds)) sent"
            guard use.billedRequests > 0 else { return sent }
            let billed = "\(UsageFormat.audio(use.billedSeconds)) billed"
                + (use.billedRequests < use.requests ? " (\(use.billedRequests) of \(use.requests) reported)" : "")
            return sent + " · " + billed
        }
    }
}

// MARK: - Overhead

/// What was paid for without becoming text, and what was never sent — Home's tray.
private struct UsageOverhead: View {
    let overhead: UsageSummary.Overhead

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader("Overhead", detail: "beyond one request a dictation")
            MainTray {
                tile("arrow.triangle.2.circlepath", "Paid twice", UsageFormat.audio(overhead.paidTwiceSeconds),
                     "streamed, then uploaded again when the stream broke or came back empty")
                tile("arrow.clockwise", "Retries", "\(overhead.retries)",
                     overhead.retries > 0 ? "\(UsageFormat.audio(overhead.retrySeconds)) sent again from History" : "none from History")
                tile("exclamationmark.triangle", "Refused", "\(overhead.failedRequests)",
                     "requests a provider refused or that broke off")
                tile("speaker.slash", "Not sent", UsageFormat.audio(overhead.notSentSeconds),
                     "of silence a cloud engine was never sent")
            }
        }
    }

    private func tile(_ symbol: String, _ title: String, _ value: String, _ label: String) -> some View {
        MainTile {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 11.5)).foregroundStyle(MainColor.okInk).frame(width: 14)
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(MainColor.ink).lineLimit(1)
                }
                Text(value)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(MainColor.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(MainColor.ink3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Limits

/// What each provider's last reply said is left of its rate limits — a free tier is
/// spent against these, not dollars. This session only; hidden until a reply has said.
private struct UsageLimits: View {
    private var store: RateLimitStore { .shared }

    var body: some View {
        let snapshots = store.snapshots
        if !snapshots.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                MainSectionHeader("Limits right now", detail: "from each provider's last reply")
                MainTable {
                    ForEach(Array(snapshots.enumerated()), id: \.offset) { index, snapshot in
                        if index > 0 { MainRule() }
                        row(snapshot)
                    }
                }
            }
        }
    }

    private func row(_ snapshot: RateLimitSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name(snapshot)).font(.system(size: 13.5, weight: .medium)).foregroundStyle(MainColor.ink)
                Text(snapshot.vendor.displayName).font(.system(size: 12.5)).foregroundStyle(MainColor.ink3)
            }
            .lineLimit(1)
            .frame(width: 210, alignment: .leading)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(snapshot.windows, id: \.name) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(window.name.replacingOccurrences(of: "-", with: " ").capitalized)
                                .font(.system(size: 12.5))
                                .foregroundStyle(MainColor.ink2)
                            Spacer(minLength: 6)
                            Text(left(window))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(MainColor.ink)
                                .monospacedDigit()
                        }
                        if let used = window.used {
                            UsageBar(fraction: CGFloat(used), color: used > 0.9 ? MainColor.problem : MainColor.speech.opacity(0.7),
                                     minimum: used > 0 ? 4 : 0)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func name(_ snapshot: RateLimitSnapshot) -> String {
        snapshot.vendor.descriptor.roles.contains(.speech) && knownSTTModels(of: snapshot.vendor).contains { $0.id == snapshot.model }
            ? HomeEngines.plainName(sttModel(vendor: snapshot.vendor, id: snapshot.model).displayName)
            : UsageView.chatModelName(snapshot.model)
    }

    /// "13,999 of 14,400 left · resets in 3 min".
    private func left(_ window: RateLimitWindow) -> String {
        var text = window.remaining.map { HomeFormat.integer($0) } ?? "?"
        if let limit = window.limit { text += " of \(HomeFormat.integer(limit))" }
        text += " left"
        if let reset = window.resetsAt, reset > Date() {
            let seconds = reset.timeIntervalSinceNow
            text += " · resets in " + (seconds < 60 ? "\(max(1, Int(seconds))) s" : HomeFormat.durationText(minutes: seconds / 60))
        }
        return text
    }
}

// MARK: - How this is counted

/// The page's small print, on Home's grey: three notes side by side on a wide page.
private struct UsageCounting: View {
    let summary: UsageSummary
    @Binding var storedTyping: Double
    let wide: Bool
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MainSectionHeader("How this is counted")
            MainPanel {
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 28))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                layout {
                    note("keyboard", "Your typing speed",
                         (storedTyping >= 10 ? "\(Int(storedTyping)) wpm. Time saved is typing the words less saying them."
                          : "40 wpm, an average. Measure yours for a fair comparison.")
                         + " Speaking is timed from your first word to your last; a pause to think counts.") {
                        Button(storedTyping >= 10 ? "Measure again…" : "Measure…") { editing = true }
                            .buttonStyle(SetupInlineLinkStyle(size: 12.5))
                            .pointingHandCursor()
                            .popover(isPresented: $editing, arrowEdge: .bottom) {
                                UsageTypingSpeedEditor(storedTyping: $storedTyping)
                            }
                    }
                    note("creditcard", "An estimate, not your bill",
                         "Each vendor's pay-as-you-go list price as of \(UsagePrices.checkedText), applied to the minutes and tokens their replies reported. Free tiers, plans and price changes since then change what you pay — your provider's billing page has the real figure. Models on this Mac cost nothing."
                         + estimatedNote) { EmptyView() }
                    note("lock", "On this Mac",
                         "Counted from \(HistoryRetention.stored(UserDefaults.standard.string(forKey: SettingsKeys.historyRetention)).phrase), as History keeps them"
                         + (summary.since.map { ", since " + HistoryFormat.formatter("d MMMM", calendar: .current).string(from: $0) } ?? "")
                         + ". Everything stays on your Mac.") { EmptyView() }
                }
            }
        }
    }

    /// The rewrites priced from their words, because they predate the vendor's token count.
    private var estimatedNote: String {
        switch summary.estimatedAIPasses {
        case 0: ""
        case 1: " One older rewrite is estimated from its words."
        case let n: " \(n) older rewrites are estimated from their words."
        }
    }

    private func note<Accessory: View>(_ symbol: String, _ title: String, _ detail: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11.5)).foregroundStyle(MainColor.okInk).frame(width: 14)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(MainColor.ink)
            }
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(MainColor.ink2)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 21)
            accessory().padding(.leading, 21)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

