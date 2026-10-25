// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import AVFoundation
import SpeechTextCore

// MARK: - Home

/// Home: the shortcut to learn on a card of our glow, with a dictation playing out beside
/// it; then what does the work, the last seven days, the other shortcuts and the last
/// dictations.
struct HomeView: View {
    let actions: MainWindowActions
    let go: (MainPage) -> Void
    @AppStorage(SettingsKeys.homeIntroHidden) private var introHidden = false
    @AppStorage(SettingsKeys.onboardingCompleted) private var setupDone = true
    @State private var access = HomeAccess()

    /// Everything under the intro card is a centred column no wider than this.
    static let columnWidth: CGFloat = 1050

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ScrollView {
                let attention = !setupDone || !access.mic || !access.ax
                VStack(spacing: 34) {
                    // What still needs doing sits as close above the intro card as the
                    // card sits below the window's edge.
                    if attention || !introHidden {
                        VStack(spacing: 10) {
                            if attention {
                                HomeAttention(actions: actions, setupDone: setupDone, access: access)
                                    .frame(maxWidth: Self.columnWidth)
                                    .padding(.horizontal, 48)
                            }
                            // Hidden and shown again from Settings › Appearance, not from the card.
                            if !introHidden {
                                HomeIntroCard(pageWidth: width, actions: actions)
                                    .padding(.horizontal, 10)
                            }
                        }
                        .padding(.top, 10)
                    }
                    VStack(spacing: 34) {
                        HomeEngines(actions: actions, go: go)
                        HomeWeekCard(pageWidth: width) { go(.usage) }
                        HomeWays(actions: actions)
                        HomeRecent(go: go, openSettings: actions.openSettings)
                    }
                    .frame(maxWidth: Self.columnWidth)
                    .padding(.horizontal, 48)
                    .padding(.top, introHidden && !attention ? 32 : 0)
                }
                .padding(.bottom, 40)
                .frame(width: width)
            }
            .scrollIndicators(.automatic)
        }
        .onAppear { access.watch() }
        .onDisappear { access.unwatch() }
    }
}

// MARK: - What still needs doing

/// Above everything on Home, and only while something is missing: setup left unfinished —
/// its window closed half-way is easy to lose — with what it still lacks, Continue Setup
/// and Skip; and, once setup is done, a microphone or an Accessibility grant that is not
/// there (turned off later, or a rebuild that dropped it). Re-read every second, so a
/// grant made in System Settings shows here at once.
struct HomeAttention: View {
    let actions: MainWindowActions
    let setupDone: Bool
    let access: HomeAccess

    var body: some View {
        if !setupDone {
            setupCard(engineChosen: access.engineChosen, mic: access.mic, ax: access.ax)
        } else {
            permissionsRow(mic: access.mic, ax: access.ax)
        }
    }

    private func setupCard(engineChosen: Bool, mic: Bool, ax: Bool) -> some View {
        MainPanel {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Finish setting up SpeechText")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(MainColor.ink)
                    HStack(spacing: 18) {
                        item("Speech engine", done: engineChosen)
                        item("Microphone", done: mic)
                        item("Type for you", done: ax)
                    }
                }
                Spacer(minLength: 12)
                Button("Skip") { actions.skipSetup() }
                    .buttonStyle(SetupButtonStyle(kind: .secondary, height: 36))
                    .help("Mark setup as done. Everything it asks is in Settings.")
                Button("Continue Setup") { actions.openSetup() }
                    .buttonStyle(SetupButtonStyle(kind: .primary, height: 36))
            }
        }
    }

    private func permissionsRow(mic: Bool, ax: Bool) -> some View {
        MainPanel(padding: EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 16)) {
            VStack(alignment: .leading, spacing: 10) {
                if !mic {
                    problem("SpeechText can't hear you", "The microphone is off for SpeechText.") {
                        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                            AVCaptureDevice.requestAccess(for: .audio) { _ in }
                        } else {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    }
                }
                if !ax {
                    problem("SpeechText can't type for you", "Accessibility is off, so your text opens in the Record Window instead.") {
                        AccessibilityGuide.shared.start { _ in }
                    }
                }
            }
        }
    }

    private func item(_ title: String, done: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? MainColor.okInk : MainColor.ink3)
            Text(title).foregroundStyle(done ? MainColor.ink2 : MainColor.ink)
        }
        .font(.system(size: 13))
    }

    private func problem(_ title: String, _ detail: String, fix: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(MainColor.problem)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(MainColor.ink)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(MainColor.ink2)
            }
            Spacer(minLength: 12)
            Button("Turn On…", action: fix)
                .buttonStyle(SetupButtonStyle(kind: .primary, height: 32))
        }
    }
}

/// The microphone and Accessibility grants, and whether an engine was chosen, re-read every
/// second while Home is shown — nothing tells the app when one changes in System Settings.
@MainActor @Observable
final class HomeAccess {
    private(set) var mic = true
    private(set) var ax = true
    private(set) var engineChosen = true
    @ObservationIgnored private var timer: Timer?

    func watch() {
        read()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
    }

    func unwatch() {
        timer?.invalidate()
        timer = nil
    }

    private func read() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let ax = AXIsProcessTrusted()
        let engine = UserDefaults.standard.string(forKey: SettingsKeys.sttProvider) != nil
        if mic != self.mic { self.mic = mic }
        if ax != self.ax { self.ax = ax }
        if engine != engineChosen { engineChosen = engine }
    }
}

// MARK: - Section parts

/// A section's name and, on its right, where its link goes — quieter than the content.
struct HomeSectionHeader: View {
    let title: String
    var link: String?
    var action: () -> Void = {}

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.15)
                .foregroundStyle(MainColor.ink)
            Spacer(minLength: 12)
            if let link {
                HomeLink(title: link, action: action)
            }
        }
    }
}

/// "Open Models ›": grey until pointed at, then the page's green.
struct HomeLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .offset(x: hovering ? 2 : 0)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(hovering ? MainColor.okInk : MainColor.ink2)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(height: 24)
            .background(Capsule().fill(hovering ? MainColor.phosphorSoft : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.trailing, -6)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .pointingHandCursor()
    }
}

/// A shortcut as keys: white caps with a key's shadow under them, lit while the key is
/// down — in the phosphor, or on an AI shortcut in the AI violet.
struct HomeKeycaps: View {
    let keys: [String]
    var size: CGFloat = 26
    var radius: CGFloat = 7
    var fontSize: CGFloat = 12.5
    var weight: Font.Weight = .semibold
    var spacing: CGFloat = 4
    var lit = false
    /// Single keys lit while the rest wait — the ones the user is holding right now.
    var litKeys: Set<Int> = []
    var ai = false
    var muted = false

    private static let capFill = Color.setup(0xFFFFFF, dark: 0xFFFFFF, 0.08)
    private static let capEdge = Color.setup(0x182C20, 0.18, dark: 0xFFFFFF, 0.14)
    private static let capShadow = Color.setup(0x182C20, 0.1, dark: 0x000000, 0.4)

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                let lit = lit || litKeys.contains(index)
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                Text(key)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundStyle(lit ? (ai ? Color.white : SetupColor.screen) : MainColor.ink)
                    .frame(minWidth: size, minHeight: size)
                    .padding(.horizontal, key.count > 1 ? size * 0.27 : 0)
                    .background {
                        if lit {
                            shape.fill(ai ? Color(hex: 0x9684E6) : SetupColor.phosphor)
                        } else {
                            shape.fill(Self.capFill)
                                .shadow(color: Self.capShadow, radius: 0, y: 1.5)
                        }
                    }
                    .overlay(shape.strokeBorder(lit ? Color(hex: 0x182C20).opacity(0.12) : Self.capEdge, lineWidth: 0.5))
                    .background {
                        if lit {
                            shape.fill(ai ? Color(hex: 0x9684E6).opacity(0.3) : SetupColor.phosphor.opacity(0.35))
                                .padding(-3)
                                .blur(radius: ai ? 0 : 4)
                        }
                    }
                    .offset(y: lit ? 1.5 : 0)
            }
        }
        .opacity(muted ? 0.5 : 1)
        .animation(.easeOut(duration: 0.12), value: lit)
        .animation(.easeOut(duration: 0.1), value: litKeys)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined(separator: " "))
    }
}

// MARK: - The intro card

/// The shortcut to learn, laid on its side: a tab for each shortcut that types — Dictate,
/// AI Rewrite and Edit — the words on a white with a breath of the green in it, and on the
/// green a dictation playing out — the techno overlay hearing it, then the text pasted once
/// into a message, or an edit replacing the selection. Settings › Appearance hides it.
struct HomeIntroCard: View {
    let pageWidth: CGFloat
    let actions: MainWindowActions

    enum Tab { case dictate, ai, edit }
    @State private var tab: Tab = .dictate
    @State private var start = Date()
    @State private var ready = HomeReadiness.current()
    @AppStorage(SettingsKeys.holdToTalk) private var holdToTalk = false
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = LLMProviderType.groq.rawValue
    @AppStorage(SettingsKeys.localLLMModel) private var localLLMModel = Provider.local.defaultChatModel

    /// The white under the words has a breath of the green in it; in Dark Mode, the card.
    private static let introBackground = Color.setup(0xF6FCF8, dark: 0x232624)

    private var cardWidth: CGFloat { pageWidth - 20 }
    /// The design's container widths: under 1000 the white gives up room with the words'
    /// column, and under 895 the message rises to the top of the green.
    private var roomy: Bool { pageWidth > 1000 }
    private var sideBySide: Bool { pageWidth > 895 }
    /// A window short of the screen's width: the card gives up height, so what is under it
    /// starts sooner. Full width keeps the design's proportions.
    private var compact: Bool { pageWidth < 1240 }
    /// The green keeps room for the message beside the overlay; the words give up to
    /// 68 pt of their column first, down to where the title still fits on one line.
    private var wordsWidth: CGFloat {
        sideBySide ? min(420, max(352, cardWidth - 532)) : min(420, cardWidth / 2)
    }

    private var aiConfigured: Bool {
        _ = llmProvider; _ = localLLMModel
        return LLMConfiguration.isConfigured
    }

    private var action: ShortcutAction {
        switch tab { case .dictate: .inline; case .ai: .ai; case .edit: .edit }
    }

    /// What the picture plays: without a provider the AI shortcut dictates plain text, and
    /// Edit — which cannot work without one — still shows what it would do.
    private var mode: HomeTalk.Mode {
        switch tab {
        case .dictate: .dictate
        case .ai: aiConfigured ? .ai : .dictate
        case .edit: .edit
        }
    }

    var body: some View {
        let isAI = tab != .dictate
        let keys = shortcutKeys(shortcutText(for: action))
        TimelineView(.periodic(from: start, by: HomeTalk.tickSeconds)) { context in
            let tick = max(0, Int(context.date.timeIntervalSince(start) / HomeTalk.tickSeconds))
            let talk = HomeTalk(tick: tick, mode: mode, holdToTalk: holdToTalk, keyCount: keys.count)
            ZStack(alignment: .topLeading) {
                art(isAI: isAI)
                HStack(spacing: 0) {
                    words(keys: keys, litKeys: talk.litKeys)
                        .frame(width: wordsWidth, alignment: .leading)
                    HomeTalkPicture(talk: talk, tick: tick, sideBySide: sideBySide)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                tabs.padding(8)
                HStack(spacing: 6) {
                    Spacer()
                    if ready { HomeReadyChip() }
                }
                .padding(11)
            }
            .frame(minHeight: sideBySide ? (compact ? 248 : 300) : (compact ? 320 : 380))
            .background(Self.introBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .onChange(of: tab) { start = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            ready = HomeReadiness.current()
        }
    }

    // MARK: The picture behind

    /// Our glow with the display's dots over it, fading into the white under the words:
    /// green on Dictate, the approved AI Rewrite gradient — a violet glow over the green —
    /// on Edit, and on AI Rewrite the green itself turned violet.
    private func art(isAI: Bool) -> some View {
        MainAIGlow(ai: isAI, violet: tab == .ai, fade: roomy
                   ? .init(dotsFrom: 300, dotsTo: 600, white: (330, 430, 540), whiteOpacity: 0.72, background: Self.introBackground)
                   : .init(dotsFrom: 250, dotsTo: 520, white: (300, 360, 450), whiteOpacity: 0.6, background: Self.introBackground))
    }

    // MARK: The words

    private var title: String {
        switch tab {
        case .dictate: "Speak, and it's typed"
        case .ai: aiConfigured ? "Speak it, get it polished" : "Rewrite needs a provider"
        case .edit: aiConfigured ? "Select it, say what to change" : "Edit needs a provider"
        }
    }

    private var text: String {
        switch tab {
        case .dictate:
            holdToTalk ? "Hold the shortcut and speak, then let go — the text lands wherever your cursor is, in any app."
                : "Press the shortcut, speak, press it again — the text lands wherever your cursor is, in any app."
        case .ai:
            aiConfigured ? "Just talk, or say what you want — “a polite reply, in English” — and AI Rewrite pastes the finished text."
                : "Needs an AI provider — a key, or a model on this Mac. Until then the shortcut dictates plain text."
        case .edit:
            aiConfigured ? "Select text in any app and tell AI how to improve it — “shorter”, “friendlier”, “in Spanish”."
                : "Needs an AI provider — a key, or a model on this Mac — to rewrite the text you select."
        }
    }

    private func words(keys: [String], litKeys: Set<Int>) -> some View {
        let isAI = tab != .dictate
        return VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: compact ? 28 : 32, weight: .bold))
                .tracking(compact ? -0.8 : -0.9)
                .foregroundStyle(MainColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.bottom, compact ? 8 : 10)
            Text(text)
                .font(.system(size: compact ? 14 : 15))
                .foregroundStyle(MainColor.ink2)
                .lineSpacing(compact ? 3.5 : 4.5)
                .frame(maxWidth: 350, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, compact ? 16 : 20)
            HStack(spacing: 16) {
                HomeKeycaps(keys: keys, size: 34, radius: 9, fontSize: 15,
                            weight: .medium, spacing: 5, litKeys: litKeys, ai: mode != .dictate)
                if isAI && !aiConfigured {
                    Button("Choose a provider") { actions.openSettings(.ai) }
                        .buttonStyle(SetupButtonStyle(kind: .primary, height: 36))
                        .environment(\.setupTint, .violet)
                        .pointingHandCursor()
                } else {
                    Button("Shortcuts") { actions.openSettings(.dictation) }
                        .buttonStyle(SetupButtonStyle(kind: .secondary, height: 36))
                        .pointingHandCursor()
                }
            }
        }
        .padding(.leading, 40)
        .padding(.trailing, sideBySide ? 16 : 24)
        .padding(.top, compact ? 40 : 52)
        .padding(.bottom, compact ? 32 : 52)
        .frame(maxHeight: .infinity)
    }

    // MARK: The corners

    /// The tabs, small, in the top-left corner: a capsule switch as macOS 26 draws them.
    private var tabs: some View {
        HStack(spacing: 0) {
            tabButton("Dictate", .dictate)
            tabButton("AI Rewrite", .ai)
            tabButton("Edit", .edit)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MainColor.ink.opacity(0.06)))
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        let selected = tab == value
        return Button { tab = value } label: {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? MainColor.ink : MainColor.ink2)
                .padding(.horizontal, 12)
                .frame(height: 24)
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

/// "Ready": only when it is true — the microphone and Accessibility are both allowed.
struct HomeReadyChip: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: 0x5FE39A))
                .frame(width: 6, height: 6)
                .shadow(color: Color(hex: 0x5FE39A), radius: 3)
            Text("Ready")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(Color(red: 16 / 255, green: 40 / 255, blue: 28 / 255).opacity(0.28)))
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }
}

enum HomeReadiness {
    static func current() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && AXIsProcessTrusted()
    }
}

// MARK: - The picture: a dictation playing out

/// A message waiting for text, and the techno overlay in the green's bottom-right corner
/// hearing the words as they are said; at the stop the text lands in the message once.
/// The look and the logic are the design's approved ones — see `HomeTalk`.
struct HomeTalkPicture: View {
    let talk: HomeTalk
    let tick: Int
    let sideBySide: Bool

    /// The overlay's transcript glass: its width sets the room the message keeps from it.
    private static let overlayWidth: CGFloat = 260

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if sideBySide {
                // Centred top to bottom, 24 pt left of the overlay's widest glass, so however
                // tall the transcript grows the two never meet.
                HStack {
                    Spacer(minLength: 0)
                    message.frame(maxWidth: 380)
                }
                .padding(.vertical, 24)
                .padding(.trailing, 16 + Self.overlayWidth + 24)
                .frame(maxHeight: .infinity)
            } else {
                // Too narrow for the two side by side: the message rises to the top of the
                // green, over the overlay's corner rather than beside it.
                message
                    .padding(.top, 48)
                    .padding(.trailing, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            overlay
                .padding(16)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(talk.isEdit ? "Selected text in \(talk.script.app) being rewritten"
                            : "A dictation being typed into \(talk.script.app)")
    }

    // MARK: The message

    private var message: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                HomeAppMark(app: talk.script.app, size: 20, radius: 6)
                Text(talk.script.app).fontWeight(.semibold).foregroundStyle(MainColor.ink)
                Text(talk.script.place).foregroundStyle(MainColor.ink3)
            }
            .font(.system(size: 12))

            Group {
                switch talk.message {
                case .pasted:
                    VStack(alignment: .leading, spacing: 6) {
                        Text(talk.script.output)
                        if talk.isEdit {
                            HomeTag(symbol: "pencil", title: "Edited", tint: .ai, size: 11)
                        } else if talk.isAI, let preset = talk.script.preset {
                            HomeTag(symbol: "sparkles", title: preset, tint: .ai, size: 11)
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: 3)))
                case .selection(let selection):
                    // Selected, as the Mac draws a selection, while the instruction is said.
                    Text(Self.selected(selection))
                case .caret:
                    // A caret blinking once a second, waiting for the paste.
                    Rectangle().fill(MainColor.ink)
                        .frame(width: 1.5, height: 16)
                        .opacity((tick / 5) % 2 == 0 ? 1 : 0)
                        .padding(.top, 2)
                }
            }
            .font(.system(size: 13.5))
            .lineSpacing(4)
            .foregroundStyle(MainColor.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 61, alignment: .topLeading)
            .animation(.easeOut(duration: 0.35), value: talk.message)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(MainColor.card.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color(hex: 0x182C20).opacity(0.12), lineWidth: 0.5))
        .shadow(color: Color(red: 16 / 255, green: 40 / 255, blue: 28 / 255).opacity(0.28), radius: 12, y: 9)
    }

    private static func selected(_ text: String) -> AttributedString {
        var selected = AttributedString(text)
        selected.backgroundColor = Color(nsColor: .selectedTextBackgroundColor)
        return selected
    }

    // MARK: The overlay

    private static let transcriptGlass = RoundedRectangle(cornerRadius: 20, style: .continuous)
    private static let stripGlass = RoundedRectangle(cornerRadius: 24, style: .continuous)
    private static let palette = TechnoPalette.green

    /// `RecordingOverlayView`'s techno strip at its real size: the transcript on a wider
    /// glass growing up out of the strip, as tall as its text — nothing faded or cut off.
    private var overlay: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // No glass before the first word, as the overlay has none.
            if talk.caption != .hidden {
                transcript
                    .contentTransition(.identity)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .frame(width: Self.overlayWidth)
                    .background(Self.transcriptGlass.fill(talk.isEdit ? TechnoSkin.editScreen : Self.palette.screen))
                    .overlay {
                        InnerShadow(shape: Self.transcriptGlass, width: 6.6, blur: 3.3)
                        InnerShadow(shape: Self.transcriptGlass, width: 4, blur: 2, offset: CGSize(width: 0, height: -1))
                    }
                    .clipShape(Self.transcriptGlass)
                    .transition(.opacity)
            }

            HStack(spacing: 6) {
                ZStack {
                    Self.stripGlass.fill(talk.isEdit ? TechnoSkin.editScreen : Self.palette.screen)
                    HomeTalkDisplay(display: talk.display, ai: talk.isAI)
                    if talk.isEdit {
                        // The Edit shortcut's mark in the glass's corner, as the overlay has it.
                        EditGlyph(size: 13)
                            .foregroundStyle(TechnoSkin.aiPeak.opacity(0.85))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.leading, 14)
                            .padding(.top, 10)
                    }
                    InnerShadow(shape: Self.stripGlass, width: 6.6, blur: 3.3)
                    InnerShadow(shape: Self.stripGlass, width: 4, blur: 2, offset: CGSize(width: 0, height: -1))
                }
                .frame(width: 100, height: 56)
                .clipShape(Self.stripGlass)
                ButtonRail {
                    PlasticButton(systemImage: "xmark", label: "Cancel", action: {})
                }
            }
            .frame(height: 56)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: talk.heard)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: talk.caption)
        .environment(\.technoPalette, Self.palette)
        .opacity(talk.phase == .done ? 0.9 : 1)
        .animation(.easeInOut(duration: 0.4), value: talk.phase == .done)
    }

    /// Settled words bright, the partial dimmer; the app's phosphor green, and its violet
    /// while the dictation is going to AI Rewrite.
    @ViewBuilder
    private var transcript: some View {
        let ink = talk.isAI ? TechnoSkin.aiText : Self.palette.phosphorText
        switch talk.caption {
        case .hidden, .words:
            let partial = talk.partial.isEmpty ? Text(verbatim: "")
                : Text(verbatim: (talk.settled.isEmpty ? "" : " ") + talk.partial).foregroundStyle(ink.opacity(0.45))
            Text(verbatim: talk.settled).foregroundStyle(ink.opacity(0.9)) + partial
        case .pasted:
            Text(Image(systemName: "checkmark")).font(.system(size: 10, weight: .semibold)).foregroundStyle(ink)
                + Text(verbatim: talk.isEdit ? "  Selection replaced" : "  Pasted into \(talk.script.app)")
                    .foregroundStyle(ink.opacity(0.9))
        }
    }
}

/// The strip's dot matrix, fed a voice rather than a microphone: syllables at about five a
/// second inside words, a breath between phrases — the design's `voice()`.
private struct HomeTalkDisplay: View {
    let display: HomeTalk.Display
    let ai: Bool
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: display != .level)) { context in
            let seconds = context.date.timeIntervalSince(start)
            PixelWaveform(levels: [CGFloat(Self.voice(seconds))],
                          columns: 16, rows: 8,
                          mode: display == .level ? .level : display == .busy ? .busy : .idle,
                          palette: ai ? .ai : .phosphor(.green))
        }
    }

    static func voice(_ s: Double) -> Double {
        let phrase = max(0, sin(s * 1.9) + 0.35)
        let syllable = 0.55 + 0.45 * abs(sin(s * 15.7 + sin(s * 3.1)))
        return min(1, 0.62 * min(1, phrase) * syllable)
    }
}

// MARK: - App marks and tags

/// An app, as the Dock marks it: its own icon when it is on this Mac; otherwise Slack's
/// mark on white, or its first letter on its colour. "Not pasted" — History's place for a
/// dictation that went nowhere — is a grey tile, never the Record Window's mark. History keeps an app's name, not its
/// icon, so the icon is looked up by that name (`AppIcons`).
struct HomeAppMark: View {
    let app: String?
    var size: CGFloat = 30
    var radius: CGFloat = 8

    private static let tints: [String: UInt32] = [
        "Slack": 0x611F69, "Mail": 0x1F7CF5, "Pages": 0xF28A1B, "Notes": 0xE8B400,
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if app == "Not pasted" {
                NotPastedMark(size: size, radius: radius)
            } else if let app, app != "Record Window", let icon = AppIcons.icon(named: app) {
                // An app icon keeps a margin round its tile; drawn a little larger, the tile
                // itself is the mark's size.
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 1.22, height: size * 1.22)
                    .frame(width: size, height: size)
            } else if app == nil || app == "Record Window" {
                RecordWindowMark(size: size, radius: radius)
            } else if app == "Slack" {
                SlackMark()
                    .frame(width: size * 0.62, height: size * 0.62)
                    .frame(width: size, height: size)
                    .background(shape.fill(.white))
                    .overlay(shape.strokeBorder(Color(hex: 0x182C20).opacity(0.18), lineWidth: 0.5))
            } else {
                let tint = Color(hex: Self.tints[app ?? ""] ?? 0x8A938D)
                Text(String((app ?? "").prefix(1)).uppercased())
                    .font(.system(size: size * 0.43, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(shape.fill(tint).overlay(shape.fill(LinearGradient(
                        colors: [.white.opacity(0.2), .clear],
                        startPoint: UnitPoint(x: 0.35, y: 0), endPoint: UnitPoint(x: 0.65, y: 1)))))
                    .overlay(shape.strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            }
        }
        .accessibilityHidden(true)
    }
}

/// An app's icon by its name, as History records it — found as `lookUp` says. Looked up
/// once per name, and nothing found is remembered too, so a list of rows costs a few file
/// checks at most.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(named name: String) -> NSImage? {
        if let known = cache[name] { return known }
        let found = lookUp(name).map(small)
        cache[name] = found
        return found
    }

    /// The icon drawn once into a 48 pt bitmap at twice the pixels: the workspace's icon
    /// carries every size up to 1024, which each row drawing it would otherwise scale down
    /// again on every frame of a scroll. No mark is drawn larger than about 40 pt.
    private static func small(_ icon: NSImage) -> NSImage {
        let side: CGFloat = 48
        let pixels = Int(side * 2)
        // Drawn in pixels into a plain CGContext: an NSGraphicsContext made on a bitmap rep
        // takes its points from the rep, and however the rep's size was set it drew the icon
        // into the bottom-left quarter — a mark half its size and off its centre.
        var proposed = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        guard let source = icon.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return icon }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let drawn = context.makeImage() else { return icon }
        return NSImage(cgImage: drawn, size: NSSize(width: side, height: side))
    }

    private static let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                                  "/Applications/Utilities", NSHomeDirectory() + "/Applications"]

    /// The running app of that name, else the app History recorded under that name by its
    /// bundle identifier (found wherever it is installed, and under a new name), else the
    /// bundle of that name, else another channel of it — "T3 Code (Beta)" for a record of
    /// "T3 Code (Alpha)" once Alpha was replaced (`AppIdentity`).
    private static func lookUp(_ name: String) -> NSImage? {
        let workspace = NSWorkspace.shared
        if let running = workspace.runningApplications.first(where: { $0.localizedName == name }),
           let url = running.bundleURL {
            return workspace.icon(forFile: url.path)
        }
        if let id = AppIdentity.bundleID(forAppNamed: name, in: TranscriptionHistory.shared.records),
           let url = workspace.urlForApplication(withBundleIdentifier: id) {
            return workspace.icon(forFile: url.path)
        }
        for folder in folders {
            let path = "\(folder)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return workspace.icon(forFile: path) }
        }
        for folder in folders {
            let apps = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            let names = apps.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
            if let sibling = AppIdentity.sibling(of: name, among: names) {
                return workspace.icon(forFile: "\(folder)/\(sibling).app")
            }
        }
        return nil
    }
}

/// The Record Window's mark: the window itself, in the techno skin, small on the soft
/// green — where a dictation went when it went to our own window.
struct RecordWindowMark: View {
    var size: CGFloat = 30
    var radius: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        RecordWindowPicture.icon
            .frame(width: size * 0.8, height: size * 0.8 / RecordWindowPicture.aspect)
            .frame(width: size, height: size)
            .background(shape.fill(MainColor.phosphorSoft))
            .overlay(shape.strokeBorder(MainColor.okInk.opacity(0.14), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// The Record Window as the techno skin draws it — the shell, the notched glass with a
/// line of text and the display's dots, the knob, the button rail and the ✕ — built from
/// the panel's own parts at their real size, still. Drawn once into an image: a list of
/// History rows would otherwise lay out a whole moulded window per row.
@MainActor
struct RecordWindowPicture: View {
    static let size = CGSize(width: 362, height: 284)
    static var aspect: CGFloat { size.width / size.height }

    static let icon: Image = renderIcon()

    private static func renderIcon() -> Image {
        let renderer = ImageRenderer(content: RecordWindowPicture()
            .environment(\.technoPalette, .green)
            .environment(\.colorScheme, .light))
        renderer.scale = 0.4
        renderer.isOpaque = false
        if let image = renderer.nsImage { return Image(nsImage: image).resizable().interpolation(.high) }
        return Image(systemName: "macwindow").resizable()
    }

    private static let levels: [CGFloat] = (0..<47).map { column in
        let x = Double(column)
        return CGFloat(max(0.2, 0.7 + 0.3 * sin(x * 0.55) * cos(x * 0.21)))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ShellBackground()
            LCDScreen(size: CGSize(width: 338, height: 259.108)) {
                // Thick enough to stay lines at the size of an icon.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach([180.0, 150, 104], id: \.self) { width in
                        Capsule().fill(TechnoPalette.green.phosphorText).frame(width: width, height: 16)
                    }
                }
                .offset(x: 26, y: 34)
                PixelMatrix(levels: Self.levels, rows: 6, mode: .level, palette: .phosphor(.green))
                    .offset(x: 4, y: 215)
            }
            .offset(x: 12, y: 12)
            TransportKnob(systemImage: "play", label: "Record", action: {})
                .offset(x: 294.5 - TransportKnob.diameter / 2, y: 56 - TransportKnob.diameter / 2)
            ButtonRail {
                PlasticButton(systemImage: "sparkles", label: "AI Rewrite", action: {})
                PlasticButton(systemImage: "text.insert", label: "Insert", action: {})
                PlasticButton(systemImage: "doc.on.doc", label: "Copy", action: {})
            }
            .offset(x: 304.5, y: 213 - (3 * PlasticButton.size + 2 * 4 + 8))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: TechnoSkin.shellRadius, style: .continuous))
    }
}

/// Slack's mark (slack.com's brand assets): one piece — a bar and its tab — turned four
/// times, each turn in its own colour.
struct SlackMark: View {
    var body: some View {
        GeometryReader { proxy in
            let s = proxy.size.width / 122.8
            ZStack {
                ForEach(Array([0xE01E5A, 0x36C5F0, 0x2EB67D, 0xECB22E].enumerated()), id: \.offset) { index, hex in
                    piece(scale: s)
                        .fill(Color(hex: UInt32(hex)))
                        .rotationEffect(.degrees(Double(index) * 90))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.width)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// The bottom-left piece, in the mark's 122.8-unit square.
    private func piece(scale s: CGFloat) -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 32.3 * s, y: 64.7 * s, width: 25.8 * s, height: 58.1 * s),
                            cornerSize: CGSize(width: 12.9 * s, height: 12.9 * s))
        path.addPath(UnevenRoundedRectangle(topLeadingRadius: 12.9 * s, bottomLeadingRadius: 12.9 * s,
                                            bottomTrailingRadius: 12.9 * s, topTrailingRadius: 0)
            .path(in: CGRect(x: 0, y: 64.7 * s, width: 25.8 * s, height: 25.8 * s)))
        return path
    }
}

/// A small tag in a row: the preset that rewrote it, an edit, a failure.
struct HomeTag: View {
    /// `neutral`: a fact rather than something AI did or something that went wrong.
    enum Tint { case ai, problem, neutral }
    var symbol: String?
    let title: String
    let tint: Tint
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: size - 1.5, weight: .medium))
            }
            Text(title).font(.system(size: size, weight: .medium))
        }
        .foregroundStyle(ink)
        .padding(.leading, 6)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7).fill(soft))
        .fixedSize()
    }

    private var ink: Color {
        switch tint {
        case .ai: MainColor.aiInk
        case .problem: MainColor.problem
        case .neutral: MainColor.ink2
        }
    }

    private var soft: Color {
        switch tint {
        case .ai: MainColor.aiSoft
        case .problem: MainColor.problemSoft
        case .neutral: MainColor.ink2.opacity(0.1)
        }
    }
}

// MARK: - Engines

/// What does the work: a hairline table, the step's name in a column of its own, then what
/// runs it. A row opens the settings that choose it.
struct HomeEngines: View {
    let actions: MainWindowActions
    let go: (MainPage) -> Void

    // Read so a change in Settings redraws the rows.
    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = STTProviderType.apple.rawValue
    @AppStorage(SettingsKeys.groqModel) private var groqModel = Provider.groq.defaultSpeechModel
    @AppStorage(SettingsKeys.elevenLabsModel) private var elevenLabsModel = Provider.elevenLabs.defaultSpeechModel
    @AppStorage(SettingsKeys.openAISTTModel) private var openAISTTModel = Provider.openAI.defaultSpeechModel
    @AppStorage(SettingsKeys.localSTTModel) private var localSTTModelID = Provider.local.defaultSpeechModel
    @AppStorage(SettingsKeys.spokenLanguages) private var spokenLanguages = ""
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = LLMProviderType.groq.rawValue
    @AppStorage(SettingsKeys.groqLLMModel) private var groqLLMModel = Provider.groq.defaultChatModel
    @AppStorage(SettingsKeys.anthropicModel) private var anthropicModel = Provider.anthropic.defaultChatModel
    @AppStorage(SettingsKeys.openAIModel) private var openAIModel = Provider.openAI.defaultChatModel
    @AppStorage(SettingsKeys.localLLMModel) private var localLLMModel = Provider.local.defaultChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "Engines", link: "Open Settings") { actions.openSettings(.speech) }
            VStack(spacing: 0) {
                HomeEngineRow(symbol: "waveform", title: "Speech", ai: false,
                              value: Text(speechEngine), detail: languages) { actions.openSettings(.speech) }
                Rectangle().fill(MainColor.separator).frame(height: 1)
                HomeEngineRow(symbol: "sparkles", title: "AI Rewrite", ai: true,
                              value: aiEngine, detail: nil) { actions.openSettings(.ai) }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MainColor.panelBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var speechEngine: String {
        let provider = STTProviderType(rawValue: sttProvider) ?? .apple
        switch provider {
        case .apple: return "Apple · On-device"
        case .local:
            return "On this Mac · \(localSTTModel(id: localSTTModelID)?.displayName ?? (localSTTModelID.isEmpty ? "Choose a model" : localSTTModelID))"
        case .groq: return cloudEngine(provider, model: groqModel)
        case .elevenlabs: return cloudEngine(provider, model: elevenLabsModel)
        case .openai: return cloudEngine(provider, model: openAISTTModel)
        }
    }

    private func cloudEngine(_ provider: STTProviderType, model id: String) -> String {
        guard id != clearedModelChoice else { return "\(provider.vendor.displayName) · Choose a model" }
        return "\(provider.vendor.displayName) · \(Self.plainName(sttModel(vendor: provider.vendor, id: id).displayName))"
    }

    private var languages: String {
        let names = parseSpokenLanguages(spokenLanguages).compactMap { id in
            spokenLanguageCatalog.first { $0.id == id }?.displayName
        }
        return names.isEmpty ? "Any language" : names.joined(separator: ", ")
    }

    private var aiEngine: Text {
        let type = LLMProviderType(rawValue: llmProvider) ?? .groq
        _ = (groqLLMModel, anthropicModel, openAIModel, localLLMModel)
        guard LLMConfiguration.isConfigured else {
            return Text("Off").foregroundStyle(MainColor.ink2).fontWeight(.regular)
                + Text(" · ").foregroundStyle(MainColor.ink2).fontWeight(.regular)
                + Text("Choose a provider").foregroundStyle(MainColor.aiInk)
        }
        let id = LLMConfiguration.model(for: type)
        let listed = id == clearedModelChoice ? "Choose a model" : chatModel(provider: type, id: id).displayName
        let (vendor, name): (String, String) = switch type {
        case .anthropic: ("Claude", Self.plainName(listed).replacingOccurrences(of: "Claude ", with: ""))
        case .groq: ("Groq", Self.plainName(listed))
        case .openai: ("OpenAI", Self.plainName(listed))
        case .local: ("On this Mac", listed)
        }
        return Text("\(vendor) · \(name)")
    }

    /// A catalogue name without its picker note: "Scribe v2 Realtime — live text" and
    /// "Claude Haiku 4.5 (fastest)" read here as the model's name alone.
    static func plainName(_ name: String) -> String { plainModelName(name) }
}

private struct HomeEngineRow: View {
    let symbol: String
    let title: String
    let ai: Bool
    let value: Text
    let detail: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ai ? MainColor.aiInk : MainColor.okInk)
                        .frame(width: 16)
                    Text(title).font(.system(size: 14)).foregroundStyle(MainColor.ink2)
                }
                .padding(.horizontal, 16)
                .frame(width: 170, alignment: .leading)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) { Rectangle().fill(MainColor.separator).frame(width: 1) }

                HStack(spacing: 10) {
                    value.font(.system(size: 14, weight: .medium)).foregroundStyle(MainColor.ink)
                    if let detail {
                        Text(detail).font(.system(size: 14)).foregroundStyle(MainColor.ink3)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? MainColor.okInk : MainColor.ink3)
                    .offset(x: hovering ? 2 : 0)
                    .padding(.horizontal, 14)
            }
            .frame(minHeight: 46)
            .background(hovering ? MainColor.panel : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Last 7 days

/// The week: a grey card — three numbers down the left, the seven days as columns of the
/// display's squares on the right. A wide page sets the numbers side by side instead.
struct HomeWeekCard: View {
    let pageWidth: CGFloat
    let openUsage: () -> Void

    @AppStorage(SettingsKeys.typingWordsPerMinute) private var storedTyping = 0.0
    private var history: TranscriptionHistory { .shared }

    private var typing: Double { storedTyping >= 10 ? storedTyping : HomeWeek.typingWordsPerMinute }

    var body: some View {
        let week = HomeWeek(records: history.records, typingSpeed: typing)
        let wide = pageWidth >= 1100
        VStack(alignment: .leading, spacing: 8) {
            HomeSectionHeader(title: "Last 7 days", link: "Open Usage", action: openUsage)
            HStack(alignment: .bottom, spacing: 48) {
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(stats(week).enumerated()), id: \.offset) { index, stat in
                            if index > 0 {
                                Rectangle().fill(MainColor.separator).frame(width: 1)
                                    .frame(minWidth: 56, maxWidth: 80)
                            }
                            HomeStatColumn(stat: stat)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(stats(week).enumerated()), id: \.offset) { index, stat in
                            if index > 0 { Rectangle().fill(MainColor.separator).frame(height: 1) }
                            HomeStatRow(stat: stat)
                        }
                    }
                    .frame(minWidth: 300, maxWidth: .infinity)
                }
                HomeWeekDays(week: week)
                    .padding(.bottom, 11)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MainColor.panel))
    }

    private func stats(_ week: HomeWeek) -> [HomeStat] {
        let (hours, minutes) = HomeFormat.duration(minutes: week.savedMinutes)
        var saved: [HomeStat.Part] = [.approx]
        if let hours { saved += [.number("\(hours)"), .unit("h")] }
        if let minutes { saved += [.number(hours == nil ? "\(minutes)" : " \(minutes)"), .unit("min")] }
        if hours == nil && minutes == nil { saved += [.number("0"), .unit("min")] }

        // Always an estimate: the date of the list prices, and any model they do not cover.
        let spent: String
        if week.spent > 0 {
            spent = UsagePrices.disclaimer.prefix(1).uppercased() + UsagePrices.disclaimer.dropFirst()
        } else if week.dictations > 0 {
            spent = week.unpricedModels.isEmpty ? "Models on this Mac cost nothing" : "Nothing priced yet"
        } else {
            spent = "Nothing dictated yet"
        }
        let unpriced = week.unpricedModels.isEmpty ? ""
            : " · not counting \(week.unpricedModels.joined(separator: ", "))"

        let third = HomeStat(symbol: "creditcard", title: "Spent",
                             value: week.spent > 0 ? [.approx, .number(HomeFormat.money(week.spent))] : [.number("$0")],
                             label: spent + unpriced)

        return [
            HomeStat(symbol: "text.alignleft", title: "Dictated",
                     value: [.number(HomeFormat.integer(week.words)), .unit("words")],
                     label: "in \(HomeFormat.integer(week.dictations)) dictations"),
            HomeStat(symbol: "clock", title: "Time saved", value: saved,
                     label: storedTyping >= 10 ? "vs typing at \(Int(typing)) wpm"
                        : "vs an average typist (\(Int(typing)) wpm)"),
            third,
        ]
    }
}

struct HomeStat {
    enum Part { case approx, number(String), unit(String) }
    let symbol: String
    let title: String
    let value: [Part]
    let label: String

    func number(size: CGFloat) -> Text {
        value.reduce(Text(verbatim: "")) { text, part in
            switch part {
            case .approx:
                text + Text(verbatim: "≈").font(.system(size: size * 0.7, weight: .medium)).foregroundStyle(MainColor.ink3)
            case .number(let n):
                text + Text(verbatim: n).font(.system(size: size, weight: .bold)).tracking(-size * 0.04)
            case .unit(let u):
                text + Text(verbatim: " " + u).font(.system(size: size * 0.52, weight: .semibold))
            }
        }
    }
}

private struct HomeStatKicker: View {
    let stat: HomeStat

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: stat.symbol)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(MainColor.okInk)
                .frame(width: 14)
            Text(stat.title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(MainColor.ink)
        }
    }
}

/// A number in the list: named and measured on the left, the figure on the right.
private struct HomeStatRow: View {
    let stat: HomeStat

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HomeStatKicker(stat: stat)
                Text(stat.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(MainColor.ink3)
                    .padding(.leading, 21)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            stat.number(size: 24)
                .foregroundStyle(MainColor.ink)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 11)
    }
}

/// A number on a wide page: named, the figure, then what it is measured against.
private struct HomeStatColumn: View {
    let stat: HomeStat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeStatKicker(stat: stat)
            stat.number(size: 30)
                .foregroundStyle(MainColor.ink)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .padding(.top, 12)
                .padding(.bottom, 8)
            Text(stat.label)
                .font(.system(size: 12.5))
                .foregroundStyle(MainColor.ink3)
                .lineSpacing(2)
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
    }
}

/// Each day a column of `PixelMatrix`'s squares (5 pt on a 7 pt pitch), straight on the
/// card, as Usage draws its days: the day's words lit in the speech green from the foot,
/// the rest of the column unlit and faint, so every day stands at the same height.
private struct HomeWeekDays: View {
    let week: HomeWeek
    private static let rows = 12

    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 8) {
                    MainPixelColumn(lit: Array(repeating: MainColor.speech.opacity(0.7),
                                               count: min(Self.rows, week.litRows(for: day, rows: Self.rows))),
                                    columns: 4, rows: Self.rows)
                    Text(day.isToday ? "Today" : Self.weekday(day.date))
                        .font(.system(size: 11, weight: day.isToday ? .semibold : .regular))
                        .foregroundStyle(day.isToday ? MainColor.ink2 : MainColor.ink3)
                        .fixedSize()
                }
                .frame(width: 26)
                .help("\(HomeFormat.integer(day.words)) words")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words dictated each day this week")
    }

    private static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
}

// MARK: - More ways to dictate

/// The other shortcuts: white tiles in a grey tray. The keys light as they go down on the
/// keyboard, one at a time (`HomeKeyboard`), never the tile; an AI shortcut's in violet.
struct HomeWays: View {
    let actions: MainWindowActions
    @AppStorage(SettingsKeys.llmProvider) private var llmProvider = LLMProviderType.groq.rawValue
    @AppStorage(SettingsKeys.localLLMModel) private var localLLMModel = Provider.local.defaultChatModel
    // The stored combinations, so a change in Settings redraws the keys.
    @AppStorage(SettingsKeys.aiHotkeyKeyCode) private var aiKey = -1
    @AppStorage(SettingsKeys.editHotkeyKeyCode) private var editKey = -1
    @AppStorage(SettingsKeys.recordWindowHotkeyKeyCode) private var recordKey = -1

    private var aiReady: Bool {
        _ = (llmProvider, localLLMModel)
        return LLMConfiguration.isConfigured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "More ways to dictate", link: "Change shortcuts") { actions.openSettings(.dictation) }
            HStack(alignment: .top, spacing: 6) {
                HomeWayTile(action: .ai, symbol: .sparkles, name: "Dictate with AI Rewrite",
                            description: "Just talk, or say what you want — AI pastes the finished text.",
                            off: aiReady ? nil : "Works as plain Dictate until you", actions: actions)
                HomeWayTile(action: .edit, symbol: .pencil, name: "Edit selection",
                            description: "Select text, then tell AI how to improve it.",
                            off: aiReady ? nil : "Needs AI Rewrite —", actions: actions)
                HomeWayTile(action: .recordWindow, symbol: .record, name: "Record Window",
                            description: "Dictate into a window of its own, then copy or insert.",
                            off: nil, actions: actions)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MainColor.panel))
        }
        .onAppear { HomeKeyboard.shared.start() }
        .onDisappear { HomeKeyboard.shared.stop() }
    }
}

/// The keys held down while Home is in front, one at a time: ⌃ lights every ⌃ on the
/// tiles as it goes down, then ⇧, then the letter — so the shortcut can be tried out on the
/// card before it is used. Read from the window's own key events; a combination that is
/// one of ours never arrives as a key event (Carbon takes it), so the whole shortcut lights
/// from `HeldShortcuts` instead.
@MainActor @Observable
final class HomeKeyboard {
    static let shared = HomeKeyboard()

    private(set) var modifiers: NSEvent.ModifierFlags = []
    private(set) var keyCodes: Set<UInt16> = []
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resign: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.take(event)
            return event
        }
        // Keys let go in another app never come back up here.
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resign { NotificationCenter.default.removeObserver(resign) }
        monitor = nil
        resign = nil
        clear()
    }

    private func clear() {
        if !modifiers.isEmpty { modifiers = [] }
        if !keyCodes.isEmpty { keyCodes = [] }
    }

    private func take(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if flags != modifiers { modifiers = flags }
        switch event.type {
        case .keyDown: keyCodes.insert(event.keyCode)
        case .keyUp: keyCodes.remove(event.keyCode)
        default: break
        }
    }

    /// Which of a shortcut's caps are down: its modifiers by their glyphs, its key by code.
    func litKeys(_ keys: [String], of action: ShortcutAction) -> Set<Int> {
        let glyphs: [(String, NSEvent.ModifierFlags)] = [("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command)]
        var lit = Set<Int>()
        for (index, key) in keys.enumerated() {
            if let flag = glyphs.first(where: { $0.0 == key })?.1 {
                if modifiers.contains(flag) { lit.insert(index) }
            } else if keyCodes.contains(UInt16(action.stored(in: .standard).keyCode)) {
                lit.insert(index)
            }
        }
        return lit
    }
}

private struct HomeWayTile: View {
    enum Symbol { case sparkles, pencil, record }
    let action: ShortcutAction
    let symbol: Symbol
    let name: String
    let description: String
    /// Set when the shortcut cannot do its job without an AI provider: what the line says
    /// before its "choose a provider" link.
    let off: String?
    let actions: MainWindowActions

    private var isAI: Bool { action != .recordWindow }
    private var muted: Bool { off != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isAI ? MainColor.aiSoft : MainColor.phosphorSoft)
                    .frame(width: 34, height: 34)
                    .overlay { glyph.foregroundStyle(isAI ? MainColor.aiInk : MainColor.okInk) }
                    .saturation(muted ? 0 : 1)
                    .opacity(muted ? 0.5 : 1)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                let keys = shortcutKeys(shortcutText(for: action))
                HomeKeycaps(keys: keys, lit: HeldShortcuts.shared.down.contains(action),
                            litKeys: HomeKeyboard.shared.litKeys(keys, of: action),
                            ai: isAI, muted: muted)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(muted ? MainColor.ink2 : MainColor.ink)
                if let off {
                    (Text(off + " ") + Text("choose a provider").fontWeight(.semibold).foregroundStyle(MainColor.aiInk) + Text("."))
                        .font(.system(size: 13))
                        .foregroundStyle(MainColor.ink2)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { actions.openSettings(.ai) }
                        .pointingHandCursor()
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { actions.openSettings(.ai) }
                } else {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(MainColor.ink2)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(MainColor.card)
            .shadow(color: Color(hex: 0x182C20).opacity(0.05), radius: 1, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(MainColor.panelBorder, lineWidth: 0.5))
    }

    @ViewBuilder
    private var glyph: some View {
        switch symbol {
        case .sparkles: Image(systemName: "sparkles").font(.system(size: 15, weight: .medium))
        case .pencil: Image(systemName: "pencil").font(.system(size: 15, weight: .medium))
        case .record: RecordWindowPicture.icon.frame(width: 26, height: 26 / RecordWindowPicture.aspect)
        }
    }
}

// MARK: - Recent

/// The last dictations: what was said, then where it went and when — one line each,
/// marked by its app.
struct HomeRecent: View {
    let go: (MainPage) -> Void
    let openSettings: (SettingsCategory?) -> Void
    private var history: TranscriptionHistory { .shared }

    var body: some View {
        let entries = history.records.prefix(4).map(HomeRecentEntry.init)
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionHeader(title: "Recent", link: "Open History") { go(.history) }
            VStack(spacing: 0) {
                if entries.isEmpty {
                    Text("Nothing dictated yet. Press \(shortcutText(for: .inline)) in any app, speak, and press it again.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(MainColor.ink2)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Rectangle().fill(MainColor.separator).frame(height: 1) }
                    HomeRecentRow(entry: entry, openSettings: openSettings)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MainColor.panelBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct HomeRecentRow: View {
    let entry: HomeRecentEntry
    let openSettings: (SettingsCategory?) -> Void
    @State private var hovering = false
    @State private var copied = false

    private var failed: Bool { entry.status != .success }

    var body: some View {
        HStack(spacing: 14) {
            HomeEntryMark(entry: entry)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.preview)
                    .font(.system(size: failed ? 13 : 14))
                    .foregroundStyle(failed ? MainColor.ink2 : MainColor.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(entry.place).fontWeight(.medium).foregroundStyle(MainColor.ink)
                    Text("·")
                    Text(entry.timeText()).monospacedDigit()
                    HomeEntryTags(tags: entry.tags)
                }
                .font(.system(size: 12))
                .foregroundStyle(MainColor.ink2)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actionButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 15)
        .background(hovering ? MainColor.panel : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var actionButton: some View {
        if failed {
            if entry.canRetry { HomeRetryButton(id: entry.id, openSettings: openSettings) }
        } else {
            HomeCopyButton(text: entry.text, copied: $copied)
                .opacity(hovering || copied ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// A row's mark: the app the text went to — or, for a dictation that pasted nothing, a
/// grey tile saying so.
struct HomeEntryMark: View {
    let entry: HomeRecentEntry
    var size: CGFloat = 30

    var body: some View {
        if entry.app == nil && entry.status != .success {
            NotPastedMark(symbol: entry.status == .failed ? "exclamationmark" : "waveform.slash",
                          tint: entry.status == .failed ? MainColor.problem : MainColor.ink3, size: size)
        } else {
            HomeAppMark(app: entry.app, size: size, radius: size * 0.27)
        }
    }
}

/// Nothing pasted: a grey tile with a symbol on it — a row's why, or, where dictations
/// are counted by app, "Not pasted" itself.
struct NotPastedMark: View {
    var symbol = "text.badge.xmark"
    var tint = MainColor.ink3
    var size: CGFloat = 30
    var radius: CGFloat?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? size * 0.27, style: .continuous)
        shape.fill(MainColor.panel)
            .overlay(shape.strokeBorder(MainColor.panelBorder, lineWidth: 1))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A row's tags, after its place and time: the prompt that rewrote it, an edit, a rewrite
/// that fell back, a failure.
struct HomeEntryTags: View {
    let tags: [HomeRecentEntry.Tag]

    var body: some View {
        ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
            switch tag {
            case .preset(let name): HomeTag(symbol: "sparkles", title: name, tint: .ai).padding(.leading, 8)
            case .edit: HomeTag(symbol: "pencil", title: "Edit", tint: .ai).padding(.leading, 8)
            case .rewriteFailed: HomeTag(symbol: "sparkles", title: "Rewrite failed", tint: .problem).padding(.leading, 8)
            case .failed: HomeTag(symbol: "exclamationmark.circle", title: "Failed", tint: .problem).padding(.leading, 8)
            // Saved with no connection: where it was going, since the row's mark says "Not pasted".
            case .notPasted(let app):
                HomeTag(symbol: "wifi.slash", title: app.map { "For \($0)" } ?? "Offline", tint: .neutral)
                    .padding(.leading, 8)
            }
        }
    }
}

/// Retry a failed dictation from its saved audio — whoever else is retrying it, the
/// spinner shows. While the local model the settings select is not on this Mac a retry
/// could only fail on it again, so the button is Install instead: it starts the download
/// and opens Settings › Speech to text, where the model's row shows how it goes, and
/// turns back into Retry once the model is usable.
struct HomeRetryButton: View {
    let id: UUID
    var title = "Retry"
    var height: CGFloat = 28
    let openSettings: (SettingsCategory?) -> Void
    @AppStorage(SettingsKeys.sttProvider) private var sttProvider = STTProviderType.apple.rawValue
    @AppStorage(SettingsKeys.localSTTModel) private var localModelID = Provider.local.defaultSpeechModel
    @State private var hovering = false

    var body: some View {
        let store = LocalModelStore.shared
        if let missing = store.missingSelectedModel(engine: sttProvider, modelID: localModelID) {
            let installing = store.state(for: missing.id).isBusy
            Button {
                if !installing { store.install(missing) }
                openSettings(.speech)
            } label: {
                HStack(spacing: 5) {
                    if installing { SetupSpinner(size: 10) } else { Image(systemName: "arrow.down.circle") }
                    Text(installing ? "Installing…" : "Install")
                }
                .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(SetupButtonStyle(kind: .secondary, height: height, hovered: hovering))
            .onHover { hovering = $0 }
            .help("Download \(speechModelName(missing)) (\(missing.downloadSizeDescription)) and show it in Settings — then retry")
        } else {
            let running = HistoryRetry.shared.inFlight.contains(id)
            Button {
                Task { @MainActor in await HistoryRetry.shared.retry(id) }
            } label: {
                HStack(spacing: 5) {
                    if running { SetupSpinner(size: 10) } else { Image(systemName: "arrow.clockwise") }
                    Text(running ? "Retrying…" : title)
                }
                .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(SetupButtonStyle(kind: .secondary, height: height, hovered: hovering))
            .onHover { hovering = $0 }
            .disabled(running)
            .help("Transcribe the saved audio again, with the settings you have now")
        }
    }
}

/// Copy, then "Copied" for a moment.
struct HomeCopyButton: View {
    let text: String
    var title: String?
    @Binding var copied: Bool
    var height: CGFloat = 28
    @State private var hovering = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium))
                if copied { Text("Copied") } else if let title { Text(title) }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(copied ? MainColor.okInk : MainColor.ink)
            .frame(minWidth: 14)
        }
        .buttonStyle(SetupButtonStyle(kind: .secondary, height: height, hovered: hovering))
        .onHover { hovering = $0 }
        .help(title ?? "Copy")
        .disabled(text.isEmpty)
    }
}
