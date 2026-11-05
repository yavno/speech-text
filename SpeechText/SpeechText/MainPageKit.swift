// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// The parts the main window's pages share, in Home's language: a page's title, a
// section's header, Home's grey panel, its tray of white tiles and its hairline table, the
// display's squares for anything that rises, the capsule switch and the fields, the
// approved AI gradient, and the design's Canvas dot field, which Prompts' editing column
// sits on.

// MARK: - Title

/// A page's name in the size History's is, its lead under it, and whatever the page keeps
/// on the right — a switch, a count.
struct MainPageTitle<Trailing: View>: View {
    let page: MainPage
    @ViewBuilder var trailing: () -> Trailing

    init(_ page: MainPage, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.page = page
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(page.title)
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-1.2)
                    .foregroundStyle(MainColor.ink)
                Text(page.lead)
                    .font(.system(size: 14))
                    .foregroundStyle(MainColor.ink2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

// MARK: - Home's surfaces

/// A section's name over its content, as Home's are — outside the surface, not in a bar
/// across it — with a quieter note after it and whatever it keeps on the right.
struct MainSectionHeader<Trailing: View>: View {
    let title: Text
    var detail: Text?
    @ViewBuilder var trailing: () -> Trailing

    /// Words from the String Catalog.
    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.init(Text(title), detail: detail.map { Text($0) }, trailing: trailing)
    }

    /// A title or note built elsewhere, already a `Text`.
    init(_ title: Text, detail: Text? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            title
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.15)
                .foregroundStyle(MainColor.ink)
                .layoutPriority(1)
            if let detail {
                detail
                    .font(.system(size: 12.5))
                    .foregroundStyle(MainColor.ink3)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: 26)
    }
}

/// Home's grey surface (the week's card): content straight on it, no header bar.
struct MainPanel<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 18, leading: 22, bottom: 20, trailing: 22)
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MainColor.panel))
    }
}

/// Home's grey tray with white tiles in it (More ways to dictate): `MainTile`s side by
/// side, 6 pt apart.
struct MainTray<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 6, content: content)
            .fixedSize(horizontal: false, vertical: true)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MainColor.panel))
    }
}

/// A white tile in a tray.
struct MainTile<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 16, leading: 18, bottom: 18, trailing: 18)
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(MainColor.card)
                .shadow(color: Color(hex: 0x182C20).opacity(0.05), radius: 1, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(MainColor.panelBorder, lineWidth: 0.5))
    }
}

/// Home's hairline table (Engines, Recent): rows on the page's white inside a thin rule,
/// a rule between each.
struct MainTable<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MainColor.panelBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The rule between two rows.
struct MainRule: View {
    var body: some View { Rectangle().fill(MainColor.separator).frame(height: 1) }
}

/// A small name over a group of things, in capitals, as a panel's label.
struct MainKicker: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title)
            .textCase(.uppercase)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(MainColor.ink3)
    }
}

/// `PixelMatrix`'s squares as a column of a chart: 5 pt on a 7 pt pitch, the unlit ones
/// faint, the lit ones rising from the foot — the display's own way of drawing a level,
/// as Home's week draws its days.
struct MainPixelColumn: View {
    /// Lit squares per row, from the foot up: each a colour.
    let lit: [Color]
    var columns = 4
    var rows = 12

    var body: some View {
        Canvas { context, size in
            let pitch = TechnoSkin.pixelPitch, cell = TechnoSkin.pixel
            for row in 0..<rows {
                let color = row < lit.count ? lit[row] : MainColor.ink.opacity(0.05)
                for column in 0..<columns {
                    let rect = CGRect(x: CGFloat(column) * pitch, y: size.height - cell - CGFloat(row) * pitch,
                                      width: cell, height: cell)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(columns) * TechnoSkin.pixelPitch - 2, height: CGFloat(rows) * TechnoSkin.pixelPitch - 2)
        .accessibilityHidden(true)
    }
}

// MARK: - Small parts

/// "Nothing yet": a dashed box, as History's empty state is.
struct MainEmptyNote<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .font(.system(size: 13))
            .foregroundStyle(MainColor.ink2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(MainColor.separator, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
    }
}

/// A small capsule label: "Default", "Free", "Speech".
struct MainChip: View {
    enum Tint { case green, ai, grey, problem }
    let title: String
    var symbol: String?
    var tint: Tint = .grey

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
            Text(title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(fill))
        .fixedSize()
        // The symbol only decorates the title.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private var ink: Color {
        switch tint {
        case .green: MainColor.okInk
        case .ai: MainColor.aiInk
        case .grey: MainColor.ink2
        case .problem: MainColor.problem
        }
    }

    private var fill: Color {
        switch tint {
        case .green: MainColor.phosphorSoft
        case .ai: MainColor.aiSoft
        case .grey: MainColor.ink.opacity(0.06)
        case .problem: MainColor.problemSoft
        }
    }
}

// MARK: - The switch

/// The intro card's tabs and History's filters, for any set of choices: a capsule switch
/// as macOS 26 draws them.
struct MainSwitch<Item: Hashable>: View {
    let items: [(Item, String)]
    @Binding var selection: Item
    var height: CGFloat = 26
    /// What VoiceOver calls the switch; empty for none.
    var label = ""

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let selected = selection == item.0
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = item.0 } } label: {
                    Text(item.1)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? MainColor.ink : MainColor.ink2)
                        .padding(.horizontal, 11)
                        .frame(height: height)
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
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MainColor.ink.opacity(0.06)))
        .fixedSize()
        // VoiceOver gets the segmented control the capsule is drawn after: one element,
        // the selected choice as its value.
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in Text(item.1).tag(item.0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Fields

/// A text field drawn as History's search field is: grey, a hairline, the green ring
/// while it is typed in.
struct MainTextField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var symbol: String?
    var height: CGFloat = 34
    var fill: Color = MainColor.panel
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MainColor.ink3)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(MainColor.ink)
                .focused($focused)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 11)
        .frame(height: height)
        .background(shape.fill(fill))
        .overlay(shape.strokeBorder(focused ? MainColor.okInk.opacity(0.55) : MainColor.panelBorder,
                                    lineWidth: focused ? 1.5 : 1))
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// A multi-line field in the same dress, for a prompt's longer texts.
struct MainTextEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 80
    var tint: Color = MainColor.okInk
    var fill: Color = MainColor.panel
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        TextEditor(text: $text)
            .font(.system(size: 13))
            .lineSpacing(3)
            .foregroundStyle(MainColor.ink)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 7)
            .padding(.vertical, 8)
            .frame(minHeight: minHeight)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(focused ? tint.opacity(0.55) : MainColor.panelBorder, lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

// MARK: - The dot field

/// The dot field: the welcome step's pattern in the frame's dark green at a low strength —
/// strongest at the foot, fading as it rises — over a breath of green.
struct MainDotField: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            MainColor.card
            SetupColor.phosphor.opacity(scheme == .dark ? 0.03 : 0.05)
            Canvas(rendersAsynchronously: false) { context, size in
                let pitch: CGFloat = 8, radius: CGFloat = 1
                var dots = Path()
                var y = pitch / 2
                while y < size.height {
                    var x = pitch / 2
                    while x < size.width {
                        dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                        x += pitch
                    }
                    y += pitch
                }
                context.fill(dots, with: .color(scheme == .dark ? SetupColor.phosphor.opacity(0.14)
                                               : SetupColor.brandDeep.opacity(0.2)))
            }
            .mask(LinearGradient(colors: [.black.opacity(0.35), .black], startPoint: .top, endPoint: .bottom))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - The AI glow

/// The approved AI Rewrite gradient — Home's intro card's picture: our green aura, a
/// violet glow over it, and the display's dots in white. `fade` lays the page's white over
/// its leading side, under words, as the intro card does; without one it fills its frame.
struct MainAIGlow: View {
    struct Fade {
        /// Where the dots fade in, from the leading edge.
        var dotsFrom: CGFloat
        var dotsTo: CGFloat
        /// The white: solid to the first, at `whiteOpacity` by the second, gone by the third.
        var white: (CGFloat, CGFloat, CGFloat)
        var whiteOpacity: Double
        var background: Color
    }

    var ai = true
    /// The green itself turned violet as well, not only glowed over — the intro card's AI
    /// Rewrite tab, set apart from Edit, which keeps the green under its violet.
    var violet = false
    var fade: Fade?
    var dotOpacity = 0.55

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack {
                ZStack {
                    Color.setup(0xB9DCC7, dark: 0x0E2419)
                    // The design's glow is drawn on a swirl 1.7 times the frame, its blobs sized
                    // against that, not against the frame.
                    SetupAura()
                        .frame(width: proxy.size.width * 1.7, height: proxy.size.height * 1.7)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                // 120° takes the green's hue (about 145°) onto `MainColor.ai`'s (252°).
                .hueRotation(.degrees(violet ? 120 : 0))
                .animation(.easeInOut(duration: 0.4), value: violet)
                ZStack {
                    RadialGradient(colors: [Color(red: 150 / 255, green: 132 / 255, blue: 230 / 255).opacity(0.95), .clear],
                                   center: UnitPoint(x: 0.8, y: 0.32), startRadius: 0, endRadius: width * 0.36)
                        .scaleEffect(x: 1, y: 1.4, anchor: UnitPoint(x: 0.8, y: 0.32))
                    RadialGradient(colors: [Color(red: 190 / 255, green: 176 / 255, blue: 255 / 255).opacity(0.7), .clear],
                                   center: UnitPoint(x: 0.56, y: 0.16), startRadius: 0, endRadius: width * 0.21)
                        .scaleEffect(x: 1, y: 1.6, anchor: UnitPoint(x: 0.56, y: 0.16))
                }
                .opacity(ai ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: ai)

                Canvas { context, size in
                    let pitch: CGFloat = 9, radius: CGFloat = 1.55
                    var dots = Path()
                    var y = pitch / 2
                    while y < size.height {
                        var x = pitch / 2
                        while x < size.width {
                            dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                            x += pitch
                        }
                        y += pitch
                    }
                    context.fill(dots, with: .color(.white.opacity(dotOpacity)))
                }
                .mask {
                    if let fade {
                        LinearGradient(stops: [.init(color: .clear, location: fade.dotsFrom / width),
                                               .init(color: .black, location: min(1, fade.dotsTo / width))],
                                       startPoint: .leading, endPoint: .trailing)
                    } else {
                        Color.black
                    }
                }

                if let fade {
                    LinearGradient(stops: [.init(color: fade.background, location: fade.white.0 / width),
                                           .init(color: fade.background.opacity(fade.whiteOpacity), location: fade.white.1 / width),
                                           .init(color: fade.background.opacity(0), location: fade.white.2 / width)],
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A frosted white pill laid on the glow: a word said, a message, a prompt picked.
struct MainGlassPill<Content: View>: View {
    var height: CGFloat = 30
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 6, content: content)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(MainColor.ink)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(MainColor.card.opacity(0.78), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(hex: 0x182C20).opacity(0.1), lineWidth: 0.5))
            .shadow(color: Color(red: 16 / 255, green: 40 / 255, blue: 28 / 255).opacity(0.2), radius: 8, y: 5)
    }
}
