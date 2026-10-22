// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import SpeechTextCore

// MARK: - The main window

/// The app's main window: an icon rail on a near-black green frame — the display's glass,
/// its unlit dot matrix faint on it — and the open page on a white card that runs off the
/// frame's bottom edge.
///
/// An ordinary titled window with its title bar made transparent, rather than a borderless
/// one that draws its own: it resizes, zooms, goes full screen and keeps the system's
/// traffic lights, and none of that is worth redrawing. The frame is simply what shows
/// through the title bar.
@MainActor
final class MainWindow: NSWindow {
    static let defaultSize = NSSize(width: 1000, height: 680)
    static let minimumSize = NSSize(width: 860, height: 580)

    private let onClose: () -> Void
    let navigation = MainWindowNavigation()

    init(actions: MainWindowActions, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        title = "SpeechText"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = NSColor(srgbRed: 6 / 255, green: 11 / 255, blue: 8 / 255, alpha: 1)
        minSize = Self.minimumSize
        collectionBehavior.insert(.fullScreenPrimary)
        contentView = NSHostingView(rootView: MainWindowView(navigation: navigation, actions: actions))
        center()
        // The frame is remembered, as a window's is; the page is not — it opens on Home.
        setFrameAutosaveName("MainWindow")
    }

    func present(_ page: MainPage? = nil) {
        if let page { navigation.page = page }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    override func close() {
        super.close()
        onClose()
    }

    /// ⌘W and ⌘M: an agent's menu bar has no File or Window menu to carry them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers {
            if key == "w" { performClose(nil); return true }
            if key == "m" { miniaturize(nil); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// What the main window's pages ask of the rest of the app: Settings, which stays a window
/// of its own — the speech engine, AI Rewrite's provider and the API keys live there.
struct MainWindowActions {
    var openSettings: (SettingsCategory?) -> Void
    /// Settings scrolled to one group — the setting a page is talking about.
    var openSettingsAt: (SettingsAnchor) -> Void = { _ in }
}

@Observable
final class MainWindowNavigation {
    var page: MainPage = .home
    /// What History opens narrowed to, asked for by a notice; History takes it and sets
    /// this back to nil, so the narrowing is the user's to change from then on.
    var historyNarrowing: HistoryNarrowing?
}

// MARK: - Pages

/// The rail's pages, in the rail's order: what the app did, what does the work and how,
/// then what is coming. Settings sits apart at the rail's foot. There is no Models page:
/// the engines and their keys stay in Settings, at the user's call.
enum MainPage: String, CaseIterable, Identifiable {
    case home, history, usage, prompts, dictionary, notepad, notetaker, settings

    var id: String { rawValue }

    static let rail: [MainPage] = [.home, .history, .usage, .prompts, .dictionary, .notepad, .notetaker]

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .usage: "Usage"
        case .prompts: "Prompts"
        case .dictionary: "Dictionary"
        case .notepad: "Notepad"
        case .notetaker: "Notetaker"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .usage: "chart.bar.xaxis"
        case .prompts: "text.bubble"
        case .dictionary: "character.book.closed"
        case .notepad: "list.clipboard"
        case .notetaker: "person.wave.2"
        case .settings: "gearshape"
        }
    }

    /// Selected, the glyph is drawn filled where SF Symbols has a fill.
    var selectedSymbol: String {
        switch self {
        case .home: "house.fill"
        case .prompts: "text.bubble.fill"
        case .dictionary: "character.book.closed.fill"
        case .notepad: "list.clipboard.fill"
        case .notetaker: "person.wave.2.fill"
        case .settings: "gearshape.fill"
        default: symbol
        }
    }

    /// A glyph with no fill — History's clock, Usage's chart — is drawn heavier instead,
    /// so the selected one still stands out from the rest.
    var hasFill: Bool { selectedSymbol != symbol }

    var lead: String {
        switch self {
        case .home: ""
        case .history: "What you said, and what SpeechText did with it."
        case .usage: "What you dictated, what it cost, and the time it saved you."
        case .prompts: "The instructions AI Rewrite follows — one for each kind of text you dictate."
        case .dictionary: "Teach SpeechText the words it gets wrong — names, product terms, code identifiers."
        case .notepad: "Leave yourself a quick note — by voice or by keyboard — and SpeechText sorts it into categories for you."
        case .notetaker: "Record a conversation you're part of, then read who said what, get a summary and ask questions."
        case .settings: "How SpeechText behaves — shortcuts, the look of its windows, formatting and permissions."
        }
    }

    /// Not in the app yet, beyond this page's promise.
    var isComingLater: Bool { [.notepad, .notetaker].contains(self) }
}

// MARK: - Colours

/// The main window's palette: the setup window's, warmed with a breath of the brand green,
/// and one AI violet.
enum MainColor {
    static let card = Color.setup(0xFFFFFF, dark: 0x232624)
    static let panel = Color.setup(0xF6F7F5, dark: 0xFFFFFF, 0.04)
    static let panelBorder = Color.setup(0x182C20, 0.07, dark: 0xFFFFFF, 0.07)
    static let separator = Color.setup(0x182C20, 0.08, dark: 0xFFFFFF, 0.08)
    static let ink = Color.setup(0x16201A, dark: 0xFFFFFF, 0.92)
    static let ink2 = Color.setup(0x5B655F, dark: 0xFFFFFF, 0.6)
    static let ink3 = Color.setup(0x969F99, dark: 0xFFFFFF, 0.36)
    static let okInk = Color.setup(0x1E8E46, dark: 0x30D158)
    /// AI Rewrite: the approved gradient's violet, and the same hue deepened for text.
    static let ai = Color.setup(0x9684E6, dark: 0xA898F0)
    static let aiInk = Color.setup(0x7B6AC2, dark: 0xBDB1F5)
    static let aiSoft = Color.setup(0xF2F0FC, dark: 0xA898F0, 0.14)
    /// What a dictation's speech step is drawn in, wherever it is counted.
    static let speech = Color.setup(0x2F9E67, dark: 0x61C58C)
    static let phosphorSoft = Color.setup(0x61C58C, 0.16, dark: 0x61C58C, 0.16)
    /// What went wrong — a failed dictation, a delete. A calm deep teal-green rather than
    /// an alarm red: a failure here is kept and can be retried, and it should read as a
    /// note to look at, not as something on fire. Always with words or a symbol beside it,
    /// so it is never told apart from the green by colour alone.
    static let problem = Color.setup(0x2F7A70, dark: 0x6CC3B5)
    static let problemSoft = Color.setup(0x2F7A70, 0.1, dark: 0x6CC3B5, 0.15)
}

// MARK: - The window's content

struct MainWindowView: View {
    @Bindable var navigation: MainWindowNavigation
    let actions: MainWindowActions

    var body: some View {
        HStack(spacing: 0) {
            MainSidebar(page: $navigation.page) { actions.openSettings(nil) }
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MainColor.card)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 9, y: -2)
                .overlay {
                    UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)
                        .strokeBorder(.black.opacity(0.2), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .padding(.top, 6)
                .padding(.trailing, 6)
        }
        .background(MainFrame())
        .ignoresSafeArea()
        .frame(minWidth: MainWindow.minimumSize.width, minHeight: MainWindow.minimumSize.height)
    }

    @ViewBuilder
    private var page: some View {
        switch navigation.page {
        case .home:
            HomeView(actions: actions) { navigation.page = $0 }
        case .history:
            HistoryView(actions: actions, navigation: navigation)
        case .usage:
            UsageView()
        case .prompts:
            PromptsView(actions: actions) { navigation.page = $0 }
        case .dictionary:
            DictionaryView(actions: actions)
        default:
            MainPlaceholderPage(page: navigation.page)
        }
    }
}

// MARK: - Frame

/// The frame: near-black green, green light at the top and the phosphor's glow at the
/// foot, the side against the page falling into shadow — and over it the display's dot
/// matrix unlit, 5 pt squares on a 7 pt pitch as `PixelMatrix` draws them, barely there.
struct MainFrame: View {
    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(rect), with: .linearGradient(
                Gradient(stops: [.init(color: Color(hex: 0x0A130E), location: 0),
                                 .init(color: Color(hex: 0x060B08), location: 0.48),
                                 .init(color: Color(hex: 0x040705), location: 1)]),
                startPoint: CGPoint(x: size.width * 0.43, y: 0),
                endPoint: CGPoint(x: size.width * 0.57, y: size.height)))

            // Pools of light, each an ellipse sized against the window as the design's are.
            func pool(_ color: Color, rx: CGFloat, ry: CGFloat, at x: CGFloat, _ y: CGFloat, stop: CGFloat = 0.7) {
                var layer = context
                layer.translateBy(x: x * size.width, y: y * size.height)
                layer.scaleBy(x: rx * size.width, y: ry * size.height)
                layer.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                           with: .radialGradient(Gradient(stops: [.init(color: color, location: 0),
                                                                  .init(color: color.opacity(0), location: stop)]),
                                                 center: .zero, startRadius: 0, endRadius: 1))
            }
            pool(TechnoSkin.phosphor.opacity(0.28), rx: 0.6, ry: 0.34, at: 0, 1.08)
            pool(Color(red: 38 / 255, green: 140 / 255, blue: 90 / 255).opacity(0.2), rx: 0.26, ry: 0.16, at: 0.04, 0.88)
            pool(.black.opacity(0.45), rx: 0.4, ry: 0.22, at: 0.1, 0.72)
            pool(.black.opacity(0.4), rx: 0.34, ry: 0.18, at: 0.14, 0.36)
            pool(Color(red: 52 / 255, green: 130 / 255, blue: 84 / 255).opacity(0.22), rx: 0.24, ry: 0.14, at: 0.02, 0.22)
            pool(Color(red: 40 / 255, green: 112 / 255, blue: 70 / 255).opacity(0.5), rx: 0.64, ry: 0.36, at: 0, -0.06, stop: 0.72)

            // The side against the page falls into shadow.
            context.fill(Path(rect), with: .linearGradient(
                Gradient(stops: [.init(color: .clear, location: 0.04), .init(color: .black.opacity(0.3), location: 0.14)]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))

            // The unlit dots — only where the frame shows: the rail, and the edges the
            // page leaves above and to its right.
            let pitch = TechnoSkin.pixelPitch, cell = TechnoSkin.pixel
            let rail = MainSidebar.width + 7
            let columns = Int(size.width / pitch) + 1, rows = Int(size.height / pitch) + 1
            for column in 0..<columns {
                let x = CGFloat(column) * pitch + 1
                let edge = x < rail || x > size.width - 7
                for row in 0..<rows {
                    let y = CGFloat(row) * pitch + 1
                    guard edge || y < 6 else { continue }
                    let depth = y / max(size.height, 1)
                    context.fill(Path(roundedRect: CGRect(x: x, y: y, width: cell, height: cell), cornerRadius: 1),
                                 with: .color(.white.opacity(0.01 + 0.006 * depth)))
                    // Towards the foot they catch a little of the phosphor, as if the level
                    // were about to rise.
                    if depth > 0.6 {
                        context.fill(Path(roundedRect: CGRect(x: x, y: y, width: cell, height: cell), cornerRadius: 1),
                                     with: .color(TechnoSkin.phosphor.opacity(0.05 * (depth - 0.6) / 0.4)))
                    }
                }
            }
            // The glass's own edge.
            context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(0.08)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Sidebar

/// An icon rail on the frame: a symbol over a short name, one list with no rules in it.
/// The open page gets a white tile — the same white as the card it opens. Settings, at the
/// foot, is not a page: it opens the Settings window, which stays a window of its own.
struct MainSidebar: View {
    static let width: CGFloat = 88

    @Binding var page: MainPage
    let openSettings: () -> Void
    @State private var settingsOpen = false

    var body: some View {
        GeometryReader { proxy in
            // A short window: the rail tightens rather than scrolling its pages out of sight.
            let compact = proxy.size.height < 650
            VStack(spacing: 0) {
                // Room for the traffic lights, which the window draws.
                Color.clear.frame(height: compact ? 38 : 40)

                // The mark takes you home, as a site's logo does.
                Button { page = .home } label: {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: compact ? 42 : 52, height: compact ? 42 : 52)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Home")
                .accessibilityLabel("Home")
                .padding(.top, compact ? 2 : 4)
                .padding(.bottom, compact ? 8 : 14)

                VStack(spacing: compact ? 2 : 6) {
                    ForEach(MainPage.rail) { item($0, compact: compact) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

                Spacer(minLength: 0)

                // Settings is a window, not a page: its glyph fills while that window is
                // open, and the tile lights the moment it is pressed.
                MainSidebarItem(page: .settings, isSelected: false, isOpen: settingsOpen, compact: compact,
                                action: openSettings)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
            .frame(width: Self.width)
        }
        .frame(width: Self.width)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if note.object is SettingsWindow { settingsOpen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if note.object is SettingsWindow { settingsOpen = false }
        }
        .onAppear { settingsOpen = NSApp.windows.contains { $0 is SettingsWindow && $0.isVisible } }
    }

    private func item(_ target: MainPage, compact: Bool) -> some View {
        MainSidebarItem(page: target, isSelected: page == target, compact: compact) { page = target }
    }
}

private struct MainSidebarItem: View {
    let page: MainPage
    let isSelected: Bool
    /// Settings: its window is open.
    var isOpen = false
    let compact: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(MainSidebarItemStyle(page: page, isSelected: isSelected, isOpen: isOpen,
                                              hovering: hovering, compact: compact))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .help(page.isComingLater ? "\(page.title) — coming soon" : page.title)
            .accessibilityLabel(page.title)
            .accessibilityValue(isOpen ? "Open" : "")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The rail's item, drawn from the button's own pressed state so a press shows at once —
/// Settings' window takes a moment to come up, and the tile lighting under the pointer
/// says the click was taken.
private struct MainSidebarItemStyle: ButtonStyle {
    let page: MainPage
    let isSelected: Bool
    let isOpen: Bool
    let hovering: Bool
    let compact: Bool
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let lit = isSelected || configuration.isPressed
        let filled = lit || isOpen
        return VStack(spacing: compact ? 1 : 3) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(lit ? (scheme == .dark ? Color.white.opacity(0.16) : .white)
                      : hovering || isOpen ? Color.white.opacity(0.1) : .clear)
                .shadow(color: .black.opacity(lit && scheme != .dark ? 0.45 : 0), radius: 6, y: 4)
                .frame(width: 48, height: compact ? 28 : 32)
                .overlay {
                    Image(systemName: filled ? page.selectedSymbol : page.symbol)
                        .font(.system(size: 15, weight: filled && !page.hasFill ? .semibold : .regular))
                        .foregroundStyle(lit ? (scheme == .dark ? SetupColor.phosphor : SetupColor.brandDeep)
                                         : .white.opacity(hovering || isOpen ? 1 : 0.8))
                }
            Text(page.title)
                .font(.system(size: 11.5, weight: lit ? .semibold : .medium))
                .foregroundStyle(.white.opacity(lit || hovering || isOpen ? 1 : 0.66))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.top, compact ? 2 : 3)
        .padding(.bottom, compact ? 3 : 5)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - Pages not built yet

/// A page the window has a place for but that is not built yet — Notepad and Notetaker:
/// what it will hold.
struct MainPlaceholderPage: View {
    let page: MainPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(page.title)
                        .font(.system(size: 32, weight: .bold))
                        .tracking(-1.2)
                        .foregroundStyle(MainColor.ink)
                    Text("Soon")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MainColor.ink2)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 10).fill(MainColor.separator))
                }
                .padding(.top, 6)
                Text(page.lead)
                    .font(.system(size: 14))
                    .foregroundStyle(MainColor.ink2)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                Text("This part of SpeechText is on its way.")
                    .font(.system(size: 13))
                    .foregroundStyle(MainColor.ink3)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(MainColor.separator, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                    .padding(.top, 22)
            }
            .padding(.horizontal, 36)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
