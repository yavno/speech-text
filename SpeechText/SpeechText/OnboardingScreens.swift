// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import AVFoundation
import SpeechTextCore

// The setup window's steps — the design is docs/design/setup/0N-*.html, variant C.

/// The window's own actions, held weakly: the window owns the view that owns this.
final class SetupWindowRef {
    weak var window: NSWindow?
    init(_ window: NSWindow) { self.window = window }
}

// MARK: - Root

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let window: SetupWindowRef

    private var tint: SetupTint { model.step == .ai ? .violet : .green }

    var body: some View {
        SetupFrame {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(tint.card)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SetupColor.cardRim, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)

                VStack(spacing: 0) {
                    screen
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(model.step)
                        .transition(.opacity)
                    footer
                }

                SetupTrafficLights(onClose: { window.window?.close() },
                                   onMinimize: { window.window?.miniaturize(nil) })
                    .padding(14)

                SetupTaskPill(model: model)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 9)
                    .padding(.trailing, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .environment(\.setupTint, tint)
        .animation(.easeInOut(duration: 0.3), value: model.step)
        .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height)
    }

    @ViewBuilder
    private var screen: some View {
        switch model.step {
        case .welcome: WelcomeScreen(model: model)
        case .speech: SpeechScreen(model: model)
        case .ai: AIScreen(model: model)
        case .permissions: PermissionsScreen(model: model)
        case .tryIt: TryItScreen(model: model)
        case .done: DoneScreen(model: model)
        }
    }

    // MARK: Footer

    private struct Primary {
        let title: String
        let enabled: Bool
        let action: () -> Void
    }

    private var back: OnboardingStep? {
        switch model.step {
        case .welcome, .done: nil
        case .speech: .welcome
        case .ai: .speech
        case .permissions: .ai
        case .tryIt: .permissions
        }
    }

    private var primary: Primary {
        switch model.step {
        case .welcome:
            Primary(title: "Get started", enabled: true) { model.go(.speech) }
        case .speech:
            Primary(title: model.speechPrimaryTitle, enabled: model.speechCanContinue) { model.continueFromSpeech() }
        case .ai:
            Primary(title: model.aiPrimaryTitle, enabled: model.aiCanContinue) { model.continueFromAI() }
        case .permissions:
            Primary(title: "Continue", enabled: model.permissionsComplete) { model.continueFromPermissions() }
        case .tryIt:
            // Without AI the step moves on by itself after a success; with it, Continue
            // waits for the dictation, and "Skip AI test" is the way past the rest.
            Primary(title: "Continue", enabled: model.appState.dictationTest.outcome.isTyped && model.aiIsSetUp) {
                model.go(.done)
            }
        case .done:
            Primary(title: "Start using SpeechText", enabled: true) {
                if let setup = window.window as? OnboardingWindow {
                    setup.finishAndOpenApp()
                } else {
                    model.finish()
                    window.window?.close()
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            SetupStepsBar(current: model.step) { model.go($0) }
            if let back {
                Button("Back") { model.go(back) }
                    .buttonStyle(SetupButtonStyle(kind: .secondary))
                    .keyboardShortcut("[", modifiers: .command)
            }
            let primary = primary
            Button(primary.title, action: primary.action)
                .buttonStyle(SetupButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!primary.enabled)
        }
        .padding(.horizontal, 14)
        .frame(height: 64)
        .overlay(alignment: .top) { Rectangle().fill(SetupColor.separator).frame(height: 1) }
    }
}

private extension Optional where Wrapped == DictationTest.Outcome {
    var isTyped: Bool {
        if case .typed? = self { return true }
        return false
    }
}

/// The two columns every step shares: the step's words on the left, its box on the right.
private struct StepColumns<Copy: View, Panel: View>: View {
    var copyWidth: CGFloat = 310
    var spacing: CGFloat = 24
    var insets = EdgeInsets(top: 44, leading: 36, bottom: 24, trailing: 24)
    var copyAlignment: Alignment = .bottomLeading
    @ViewBuilder let copy: Copy
    @ViewBuilder let panel: Panel

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            copy.frame(width: copyWidth, alignment: copyAlignment).frame(maxHeight: .infinity, alignment: copyAlignment)
            panel.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(insets)
    }
}

// MARK: - ① Welcome

private struct WelcomeScreen: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        StepColumns(copyWidth: 320, spacing: 36, insets: EdgeInsets(top: 44, leading: 40, bottom: 24, trailing: 32),
                    copyAlignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 3)
                    .padding(.leading, -4)
                    .padding(.bottom, 14)
                Text("Talk instead of typing").setupTitle(44).padding(.bottom, 12)
                Text("Press a shortcut, say what you want to write, and your words appear wherever your cursor is — in any app.")
                    .setupLead(15)
                    .padding(.bottom, 18)
                WelcomeLanguages(model: model)
            }
        } panel: {
            SetupPanel { WelcomeDemo() }
                .accessibilityLabel("How SpeechText works")
        }
    }
}

/// *Languages I speak*, asked early but not required: with none stated every dictation's
/// language is detected, and the Speech step marks the models that lack a stated one.
private struct WelcomeLanguages: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Your languages, for better accuracy")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(SetupColor.label)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Optional").font(.system(size: 11)).foregroundStyle(SetupColor.label3)
            }
            SpokenLanguagesChips(selected: model.spokenLanguages) { model.spokenLanguages = $0 }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(SetupColor.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SetupColor.panelBorder, lineWidth: 1))
    }
}

/// A scripted loop, not the recording flow: the shortcut lights up → the recording strip
/// appears in the corner → words type themselves into a message field → the strip goes.
private struct WelcomeDemo: View {
    private static let sentence = "Running ten minutes late – start without me."
    private var words: [Substring] { Self.sentence.split(separator: " ") }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var litKeys = 0
    @State private var stripShown = false
    @State private var listening = false
    @State private var typedWords = 0
    @State private var sent: String?
    @State private var composerActive = false
    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.default.rawValue

    private var skin: AppSkin { AppSkin(rawValue: skinRaw) ?? .default }

    var body: some View {
        ZStack {
            background
            chat.padding(.horizontal, 28).offset(y: 12)
            VStack {
                hud.padding(.top, 18)
                Spacer()
            }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    DemoStrip(skin: skin, listening: listening)
                        .scaleEffect(0.62, anchor: .bottomTrailing)
                        .frame(width: skin.overlayStripSize.width * 0.62,
                               height: skin.overlayStripSize.height * 0.62, alignment: .bottomTrailing)
                        .opacity(stripShown ? 1 : 0)
                        .offset(y: stripShown ? 0 : 9)
                        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: stripShown)
                }
            }
            .padding(14)
        }
        .task {
            if reduceMotion { finalFrame(); return }
            await loop()
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x134A33), SetupColor.brandDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(hex: 0x1F6A48), .clear], center: .topLeading, startRadius: 0, endRadius: 300)
            RadialGradient(colors: [SetupColor.phosphor.opacity(0.45), .clear], center: UnitPoint(x: 1, y: 1.1), startRadius: 0, endRadius: 320)
            // A dot field at the bottom of the wallpaper, like the icon's.
            Canvas { context, size in
                let pitch: CGFloat = 7
                var y = size.height * 0.55
                while y < size.height {
                    var x: CGFloat = 3
                    while x < size.width {
                        context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                                     with: .color(SetupColor.phosphor.opacity(0.55)))
                        x += pitch
                    }
                    y += pitch
                }
            }
            .mask(LinearGradient(colors: [.clear, .black], startPoint: UnitPoint(x: 0.5, y: 0.55), endPoint: .bottom))
            .opacity(0.55)
        }
    }

    private var hud: some View {
        HStack(spacing: 8) {
            Text("Press").font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
            HStack(spacing: 4) {
                ForEach(Array(shortcutKeys(shortcutText(for: .inline)).enumerated()), id: \.offset) { index, key in
                    let lit = index < litKeys
                    Text(key)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(lit ? SetupColor.screen : Color(hex: 0x1D1D1F))
                        .frame(minWidth: 26, minHeight: 26)
                        .padding(.horizontal, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(lit ? SetupColor.phosphor : .white.opacity(0.92)))
                        .shadow(color: lit ? SetupColor.phosphor.opacity(0.6) : .black.opacity(0.14), radius: lit ? 7 : 0, y: lit ? 0 : 1.5)
                        .offset(y: lit ? 1 : 0)
                        .animation(.easeOut(duration: 0.18), value: lit)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.28)))
    }

    private var chat: some View {
        let dark = scheme == .dark
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(0 ..< 3, id: \.self) { _ in Circle().fill(Color.gray.opacity(0.35)).frame(width: 7, height: 7) }
                Text("Team chat").font(.system(size: 11, weight: .semibold)).padding(.leading, 6)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.gray.opacity(0.18)).frame(height: 1) }

            VStack(spacing: 6) {
                Spacer(minLength: 0)
                bubble("Are you joining the 10:00 call?", mine: false)
                if let sent { bubble(sent, mine: true) }
            }
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 4, trailing: 10))
            .frame(height: 96)

            HStack(spacing: 0) {
                if typedWords == 0 {
                    Caret()
                    Text("Message").foregroundStyle(Color.gray.opacity(0.8))
                } else {
                    (Text(words.prefix(typedWords).joined(separator: " ")) + Text(" "))
                        .fixedSize(horizontal: false, vertical: true)
                        .overlay(alignment: .bottomTrailing) { Caret().offset(x: 2) }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .overlay(RoundedRectangle(cornerRadius: 15)
                .strokeBorder(composerActive ? SetupColor.phosphor.opacity(0.8) : Color.gray.opacity(0.3), lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: 18).fill(SetupColor.phosphor.opacity(composerActive ? 0.25 : 0)).padding(-3))
            .padding(EdgeInsets(top: 6, leading: 8, bottom: 8, trailing: 8))
        }
        .font(.system(size: 11.5))
        .foregroundStyle(dark ? Color(white: 0.95) : Color(hex: 0x1D1D1F))
        .background(RoundedRectangle(cornerRadius: 10).fill(dark ? Color(hex: 0x1F1F21) : Color(hex: 0xFBFBFB)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.35), radius: 15, y: 12)
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(text)
                .foregroundStyle(mine ? .white : .primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12).fill(mine ? SetupColor.brand : Color.gray.opacity(0.16)))
            if !mine { Spacer(minLength: 40) }
        }
    }

    private func finalFrame() {
        typedWords = words.count
        stripShown = true
    }

    private func sleep(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    private func press() async -> Bool {
        for n in 1 ... 3 {
            litKeys = n
            guard await sleep(0.07) else { return false }
        }
        guard await sleep(0.26) else { return false }
        litKeys = 0
        return true
    }

    private func loop() async {
        while !Task.isCancelled {
            sent = nil
            typedWords = 0
            composerActive = true
            guard await sleep(0.7), await press() else { return }
            stripShown = true
            listening = true
            guard await sleep(0.45) else { return }
            for n in 1 ... words.count {
                withAnimation(.easeOut(duration: 0.18)) { typedWords = n }
                guard await sleep(0.17 + Double.random(in: 0 ... 0.09)) else { return }
            }
            guard await sleep(0.25), await press() else { return }
            listening = false
            stripShown = false
            guard await sleep(0.9) else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                sent = Self.sentence
                typedWords = 0
                composerActive = false
            }
            guard await sleep(1.6) else { return }
        }
    }
}

private struct Caret: View {
    @State private var on = true

    var body: some View {
        Rectangle().frame(width: 1.5, height: 13)
            .opacity(on ? 1 : 0)
            .onAppear {
                withAnimation(.linear(duration: 0.01).delay(0.5).repeatForever(autoreverses: true)) { on = false }
            }
    }
}

/// `RecordingOverlayView`'s strip in the skin the overlay will wear, drawn at its real
/// size: the dot-matrix glass and the moulded ✕, or microphone (or sparkles), 12 bars, ✕.
private struct DemoStrip: View {
    let skin: AppSkin
    let listening: Bool
    var ai = false

    @AppStorage(SettingsKeys.technoPhosphor) private var technoRaw = TechnoPhosphor.green.rawValue

    var body: some View {
        Group {
            switch skin {
            case .techno: techno
            case .minimal: minimal
            }
        }
        // A picture of the overlay: its ✕ does nothing, so VoiceOver should not find it.
        .accessibilityHidden(true)
    }

    /// `RecordingOverlayView.technoStrip`, fed a scripted voice instead of the microphone.
    private var techno: some View {
        let glass = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let palette = TechnoPalette(stored: technoRaw)
        return TimelineView(.periodic(from: .now, by: 0.09)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let loudness = listening ? CGFloat(0.4 + 0.48 * abs(sin(t * 3.1))) : 0
            HStack(spacing: 6) {
                ZStack {
                    glass.fill(palette.screen)
                    PixelWaveform(levels: [loudness], columns: 16, rows: 8,
                                  mode: listening ? .level : .idle,
                                  palette: ai ? .ai : .phosphor(palette))
                    InnerShadow(shape: glass, width: 6.6, blur: 3.3)
                    InnerShadow(shape: glass, width: 4, blur: 2, offset: CGSize(width: 0, height: -1))
                }
                .frame(width: 100, height: 56)
                .clipShape(glass)
                ButtonRail {
                    PlasticButton(systemImage: "xmark", label: "Cancel", action: {})
                }
            }
            .frame(width: skin.overlayStripSize.width, height: skin.overlayStripSize.height)
            .allowsHitTesting(false)
            .environment(\.technoPalette, palette)
            .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
        }
    }

    private var minimal: some View {
        TimelineView(.periodic(from: .now, by: 0.09)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let loudness = listening ? 0.35 + 0.65 * abs(sin(t * 3.1)) : 0
            HStack(spacing: 10) {
                Image(systemName: ai ? "sparkles" : "mic.fill")
                    .font(.system(size: 14))
                    .frame(width: 24, height: 24)
                    .opacity(0.55)
                HStack(spacing: 6) {
                    ForEach(0 ..< 12, id: \.self) { i in
                        let shape = 0.55 + 0.45 * sin(Double(i) / 11 * .pi)
                        let jitter = 0.6 + 0.4 * abs(sin(Double(i) * 12.9898 + floor(t / 0.09) * 3.1))
                        let height = listening ? 4 + 22 * loudness * shape * jitter : (6 + 14 * sin(Double(i) / 11 * .pi)) * 0.4
                        RoundedRectangle(cornerRadius: 2).frame(width: 4, height: height)
                            .animation(.spring(response: 0.12, dampingFraction: 0.6), value: height)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 30)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .opacity(0.45)
            }
            .foregroundStyle(ai ? AnyShapeStyle(SetupColor.ai) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .frame(width: 300, height: 44)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
        }
    }
}

// MARK: - ② Speech

private struct SpeechScreen: View {
    @Bindable var model: OnboardingModel
    @State private var showHeavyModels = false
    private var spoken: [String] { model.spokenLanguages }

    private var appleSilicon: Bool { model.capabilities.isAppleSilicon }

    var body: some View {
        StepColumns {
            VStack(alignment: .leading, spacing: 0) {
                Text("Where should your speech become text?").setupTitle(32).padding(.bottom, 10)
                Text("On this Mac or online — you can change it later.").setupLead().padding(.bottom, 22)
                VStack(spacing: 12) {
                    SetupChoiceCard(glyph: .mac, name: "On this Mac",
                                    why: appleSilicon && model.recommendedSpeechModel != nil ? "Best choice for your Mac." : nil,
                                    facts: appleSilicon
                                        ? "Private and free. Your voice stays on your Mac; works offline after one download."
                                        : intelSpeechPlaceFacts,
                                    isSelected: model.speechPath == .local) { model.speechPath = .local }
                    SetupChoiceCard(glyph: .cloud, name: "Online service",
                                    why: appleSilicon ? nil : "Best choice for your Mac.",
                                    facts: "Works on any Mac. Needs internet and a free account; your recording is sent to the service.",
                                    isSelected: model.speechPath == .online) { model.speechPath = .online }
                }
            }
        } panel: {
            SetupPanel {
                if model.speechPath == .local { localDetails } else { onlineDetails }
            }
        }
    }

    private var localDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if spoken.isEmpty { languagesNudge }
                (Text("Recommended for your ") + Text(macDescription(model.capabilities)).fontWeight(.semibold).foregroundColor(SetupColor.label))
                    .font(.system(size: 11.5))
                    .foregroundStyle(SetupColor.label2)
                    .padding(.leading, 10)
                    .padding(.bottom, 2)
                // Settings' order: the picks, Apple Dictation, the rest, and the models
                // this Mac cannot hold behind a link — the one chosen or on disk stays in sight.
                let listing = localSTTListing(for: model.capabilities, languages: spoken) { speech in
                    (!model.speechUsesApple && model.speechModelID == speech.id)
                        || model.store.state(for: speech.id) != .notInstalled
                }
                ForEach(listing.picks) { row($0) }
                // macOS asks for Speech Recognition at the first Apple dictation — Try it, here.
                SetupRow(title: "Apple Dictation", subtitle: "Built in",
                         languageBadge: languageBadge(sttModel(vendor: .apple, id: appleSpeechModelID).languages, spoken: spoken),
                         detail: appleDictationLine + " macOS asks to allow Speech Recognition the first time.",
                         isSelected: model.speechUsesApple) { model.pickAppleDictation() }
                ForEach(listing.others + listing.lackingLanguage) { row($0) }
                if !listing.heavy.isEmpty {
                    let count = listing.heavy.count
                    Button(showHeavyModels ? "Hide models too heavy for this Mac"
                                           : "Show \(count) \(count == 1 ? "model" : "models") too heavy for this Mac") {
                        withAnimation(.easeOut(duration: 0.2)) { showHeavyModels.toggle() }
                    }
                    .buttonStyle(SetupInlineLinkStyle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    if showHeavyModels { ForEach(listing.heavy) { row($0) } }
                }
                if let pending = model.pendingSpeechSwitch, let target = localSTTModel(id: pending) {
                    switchConfirm(target)
                }
                Text("Preparing a model for your Mac takes a while the first time — up to 10 minutes. You can continue while it runs.")
                    .font(.system(size: 11))
                    .foregroundStyle(SetupColor.label3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .padding(.horizontal, 2)
            }
            .padding(EdgeInsets(top: 14, leading: 12, bottom: 12, trailing: 12))
        }
        .scrollIndicators(.never)
    }

    private func row(_ speech: LocalSTTModel) -> some View {
        let state = model.store.state(for: speech.id)
        let caps = model.capabilities
        let badge: SetupBadge? = switch state {
        case .installed: SetupBadge(text: "✓ Installed", kind: .done)
        default:
            if model.recommendedSpeechModel?.id == speech.id {
                SetupBadge(text: "Recommended", kind: .recommended)
            } else if model.bestSpeechModel?.id == speech.id {
                SetupBadge(text: "Best quality", kind: .quality)
            } else if !localModelFitsMemory(speech.memoryFloorBytes, caps) {
                SetupBadge(text: "Too heavy for this Mac", kind: .warn)
            } else {
                nil
            }
        }
        return SetupRow(title: speechModelName(speech), badge: badge,
                        languageBadge: languageBadge(speech.languages, spoken: spoken), facts: speechModelSubtitle(speech),
                        detail: speechModelLine(speech, spoken: spoken), isSelected: !model.speechUsesApple && model.speechModelID == speech.id,
                        action: { model.pickSpeechModel(speech.id) }, extra: {
            switch state {
            case .downloading(let f):
                SetupProgressBar(fraction: f).padding(.top, 6)
                Text("Downloading · \(Int(f * 100))%").rowNote()
            case .optimizing:
                SetupProgressBar(fraction: nil).padding(.top, 6)
                Text("Getting ready for your Mac…").rowNote()
            case .failed:
                HStack(spacing: 4) {
                    Text("Download failed — check your internet.").rowNote(bad: true)
                    Button("Retry") { model.store.install(speech) }.buttonStyle(SetupInlineLinkStyle())
                }
            default:
                EmptyView()
            }
        })
    }

    /// With no language stated, nothing tells a row that lacks one apart: asked here, in place.
    private var languagesNudge: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add the languages you speak to see which models know them.")
                .font(.system(size: 12))
                .foregroundStyle(SetupColor.label)
                .fixedSize(horizontal: false, vertical: true)
            SpokenLanguagesChips(selected: spoken, addTitle: "Add languages", showsAnyLanguage: false) { model.spokenLanguages = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(SetupColor.control))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SetupColor.panelBorder, lineWidth: 1))
        .padding(.bottom, 10)
    }

    private func switchConfirm(_ target: LocalSTTModel) -> some View {
        let current = model.speechDownloadID.flatMap(localSTTModel(id:))
        return VStack(alignment: .leading, spacing: 8) {
            Text("Switch to \(speechModelName(target))? The current download will stop.")
                .font(.system(size: 12))
            HStack(spacing: 6) {
                Button("Switch") { model.confirmSpeechSwitch() }
                    .buttonStyle(SetupButtonStyle(kind: .primary, height: 26))
                Button("Keep \(current.map(speechModelName)?.replacingOccurrences(of: "Whisper ", with: "") ?? "it")") {
                    model.pendingSpeechSwitch = nil
                }
                .buttonStyle(SetupButtonStyle(kind: .secondary, height: 26))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xFF9F0A).opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xFF9F0A).opacity(0.3), lineWidth: 1))
        .padding(.top, 8)
    }

    private var onlineDetails: some View {
        SetupCenteredScroll {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SetupCards.speech, id: \.service) { card in
                    SetupRow(title: card.title, subtitle: card.subtitle, detail: card.detail,
                             isSelected: model.speechService == card.service) { model.speechService = card.service }
                }
                SetupKeyBlock(model: model, service: model.speechService)
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
            }
            .padding(EdgeInsets(top: 14, leading: 12, bottom: 12, trailing: 12))
            .frame(maxWidth: .infinity)
        }
    }
}

private extension Text {
    func rowNote(bad: Bool = false) -> some View {
        font(.system(size: 11)).foregroundStyle(bad ? SetupColor.danger : SetupColor.label2).padding(.top, 3)
    }
}

// MARK: - ③ AI

private struct AIScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.setupTint) private var tint

    var body: some View {
        StepColumns {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Want AI to tidy up your text?").setupTitle(32)
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tint.glow)
                }
                .padding(.bottom, 10)
                (Text("Optional. Press ") + kbd(shortcutText(for: .ai)) + Text(" instead of ")
                 + kbd(shortcutText(for: .inline)) + Text(" and AI turns what you say — or what you ask for — into clean text for the app you're in."))
                    .setupLead(14.5)
                    .padding(.bottom, 16)
                VStack(spacing: 10) {
                    SetupChoiceCard(glyph: .mac, name: "On this Mac",
                                    facts: model.capabilities.isAppleSilicon
                                        ? "Private and free. A 3–19 GB download, nothing else to install."
                                        : "Private and free, but slow on an Intel Mac. A 3–19 GB download.",
                                    isSelected: model.aiPath == .local) { model.chooseAIPath(.local) }
                    SetupChoiceCard(glyph: .cloud, name: "Online service",
                                    badge: Provider.allCases.contains(where: model.keyReadyFromSpeech) ? "Ready" : nil,
                                    facts: "Fast on any Mac. Needs an account — Groq has a free plan.",
                                    isSelected: model.aiPath == .online) { model.chooseAIPath(.online) }
                }
                .padding(.bottom, 36)
            }
        } panel: {
            VStack(spacing: 10) {
                SetupPanel {
                    switch model.aiPath {
                    case .none: example
                    case .local: localDetails
                    case .online: onlineDetails
                    }
                }
                .background(LinearGradient(colors: [SetupColor.ai.opacity(0.09), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.5, y: 0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 14)))
                HStack(spacing: 10) {
                    Text("You can turn this on later in Settings.").font(.system(size: 12)).foregroundStyle(SetupColor.label2)
                    SetupSkipButton(title: "Skip for now") { model.skipAI() }
                }
            }
        }
    }

    private func kbd(_ text: String) -> Text {
        Text(" \(text) ").font(.system(size: 12.5, weight: .semibold)).foregroundColor(SetupColor.label)
    }

    /// Nothing picked yet: what AI polish does, which is what sells it.
    private var example: some View {
        // Before and after, one under the other and the same width: the point is the
        // difference between the two texts, not a conversation.
        VStack(alignment: .leading, spacing: 10) {
            Text("FOR EXAMPLE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(tint.accent)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Text("You say").font(.system(size: 10.5, weight: .semibold)).opacity(0.7)
                Text("“uh so um tell John that I'm gonna be like— wait no, ten, ten minutes late I think? cause the traffic is just, ugh. yeah sorry”")
                    .italic()
            }
            .font(.system(size: 13))
            .foregroundStyle(SetupColor.label2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(SetupColor.control))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SetupColor.panelBorder, lineWidth: 1))
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint.accent)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Text("✨ AI writes").font(.system(size: 10.5, weight: .semibold)).opacity(0.7)
                Text("Hi John, I'll be about 10 minutes late — traffic is bad. Sorry!")
            }
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(hex: 0x8A6AF0), Color(hex: 0x4A2FB0)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        }
        .padding(22)
        .frame(maxHeight: .infinity)
    }

    // MARK: On this Mac

    private var localDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if !model.capabilities.isAppleSilicon {
                    Text(intelChatWarning)
                        .font(.system(size: 12))
                        .foregroundStyle(SetupColor.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                }
                modelLists
            }
            .padding(EdgeInsets(top: 14, leading: 12, bottom: 12, trailing: 12))
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var modelLists: some View {
        let caps = model.capabilities
        let picks = [model.recommendedAIModel, model.bestAIModel].compactMap { $0 }
            .reduce(into: [LocalChatModel]()) { if !$0.contains($1) { $0.append($1) } }
        let fitting = localChatModels.filter { localModelFitsMemory($0.memoryFloorBytes, caps) && !picks.contains($0) }
        let heavy = localChatModels.filter { !localModelFitsMemory($0.memoryFloorBytes, caps) && !picks.contains($0) }
        heading("Recommended for your Mac (\(macDescription(caps)))")
        ForEach(picks) { aiRow($0) }
        if !fitting.isEmpty {
            heading("Other models")
            ForEach(fitting) { aiRow($0) }
        }
        if !heavy.isEmpty {
            heading("Heavier models")
            ForEach(heavy) { aiRow($0) }
        }
        if let selected = localChatModel(id: model.aiModelID), !localModelFitsMemory(selected.memoryFloorBytes, caps) {
            Text("This model may be slow on your Mac. We recommend \(model.recommendedAIModel?.displayName ?? "a lighter one").")
                .font(.system(size: 11.5))
                .foregroundStyle(SetupColor.warn)
                .padding(.horizontal, 10)
                .padding(.top, 8)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(SetupColor.label3)
            .padding(EdgeInsets(top: 12, leading: 10, bottom: 4, trailing: 10))
    }

    private func aiRow(_ llm: LocalChatModel) -> some View {
        let heavy = !localModelFitsMemory(llm.memoryFloorBytes, model.capabilities)
        let state = model.chatStore.state(for: llm)
        let selected = model.aiModelID == llm.id
        let badge: SetupBadge? = if state == .installed { SetupBadge(text: "✓ Downloaded", kind: .done) }
            else if heavy { SetupBadge(text: "Too heavy for this Mac", kind: .warn) }
            else if model.recommendedAIModel?.id == llm.id { SetupBadge(text: "Recommended", kind: .recommended) }
            else if model.bestAIModel?.id == llm.id { SetupBadge(text: "Best quality", kind: .quality) }
            else { nil }
        return SetupRow(title: llm.displayName, subtitle: llm.downloadSizeDescription, badge: badge,
                        detail: aiModelLine(llm, heavy: heavy, spoken: storedSpokenLanguages()), isSelected: selected, dimmed: heavy,
                        action: { model.aiModelID = llm.id }) {
            if case .downloading(let f) = state {
                SetupProgressBar(fraction: f).padding(.top, 6)
                Text("Downloading · \(Int(f * 100))%").rowNote()
            }
            if case .failed = state {
                HStack(spacing: 4) {
                    Text("Download failed.").rowNote(bad: true)
                    Button("Retry") { model.chatStore.install(llm) }.buttonStyle(SetupInlineLinkStyle())
                }
            }
        }
    }

    // MARK: Online

    private var onlineDetails: some View {
        SetupCenteredScroll {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SetupCards.ai, id: \.service) { card in
                    SetupRow(title: card.title, subtitle: card.subtitle,
                             isSelected: model.aiService == card.service, compact: true) { model.aiService = card.service }
                }
                // A key from the Speech step (Groq's, OpenAI's) is reused as it is.
                SetupKeyBlock(model: model, service: model.aiService,
                              collapsedText: model.keyReadyFromSpeech(model.aiService)
                                  ? "AI polish is ready — it uses your \(model.aiService.displayName) key." : nil,
                              compact: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        }
    }
}

// MARK: - ④ Permissions

private struct PermissionsScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.setupTint) private var tint

    var body: some View {
        StepColumns(copyWidth: 280, copyAlignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.needsMacDictation ? "Three quick settings" : "Two quick permissions").setupTitle(32).padding(.bottom, 10)
                Text("SpeechText needs these to hear you and to type for you.").setupLead().padding(.bottom, 22)
                VStack(alignment: .leading, spacing: 10) {
                    promise("Listens only while you dictate", "— from one press of the shortcut to the next.")
                    promise("Types only what you said", "— right where your cursor is.")
                }
                .frame(maxWidth: 250, alignment: .leading)
            }
        } panel: {
            VStack {
                Spacer(minLength: 0)
                SetupPanel {
                    VStack(alignment: .leading, spacing: 0) {
                        micRow
                        Divider().overlay(SetupColor.separator)
                        accessibilityRow
                        Divider().overlay(SetupColor.separator)
                        if model.needsMacDictation {
                            dictationRow
                            Divider().overlay(SetupColor.separator)
                        }
                        loginRow
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 2)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .onAppear { model.refreshPermissions() }
    }

    private func promise(_ bold: String, _ rest: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield").font(.system(size: 16)).foregroundStyle(tint.accent).frame(width: 20)
            (Text(bold).fontWeight(.semibold).foregroundColor(SetupColor.label) + Text(" \(rest)"))
                .font(.system(size: 12.5))
                .foregroundStyle(SetupColor.label2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var micRow: some View {
        PermissionRow(icon: "mic", title: "Microphone", detail: "So SpeechText can hear you.",
                      granted: model.micGranted, glowID: model.justGranted.row == "mic" ? model.justGranted.count : 0) {
            switch model.micStatus {
            case .denied:
                PermissionState(tone: .warn) { Text("Microphone is turned off for SpeechText.") }
            case .restricted:
                PermissionState(tone: .bad) { Text("Your Mac's settings don't allow microphone use. Ask whoever manages this Mac.") }
            default:
                EmptyView()
            }
        } actions: {
            if model.micStatus == .denied {
                Button("Open System Settings") { model.openMicrophoneSettings() }.buttonStyle(SetupLinkButtonStyle(height: 28))
            }
        } control: {
            if model.micStatus == .notDetermined {
                Button("Allow") { model.allowMicrophone() }.buttonStyle(SetupLinkButtonStyle(height: 28))
            } else if model.micGranted {
                AllowedLabel()
            }
        }
    }

    private var accessibilityRow: some View {
        PermissionRow(icon: "keyboard", title: "Type for you", detail: "So your words appear where your cursor is.",
                      granted: model.accessibilityGranted, glowID: model.justGranted.row == "ax" ? model.justGranted.count : 0) {
            if !model.accessibilityGranted {
                switch model.accessibilityChoice {
                case .idle: EmptyView()
                case .waiting:
                    PermissionState(tone: .plain) {
                        HStack(alignment: .top, spacing: 6) {
                            WaitingDot()
                            Text("Waiting for you to turn on SpeechText in System Settings.")
                        }
                    }
                    Button("Open again") { model.openAccessibilitySettings() }.buttonStyle(SetupInlineLinkStyle())
                }
            }
        } actions: {
            if !model.accessibilityGranted {
                switch model.accessibilityChoice {
                case .idle:
                    Button("Open System Settings") { model.openAccessibilitySettings() }.buttonStyle(SetupLinkButtonStyle(height: 28))
                case .waiting:
                    EmptyView()
                }
            }
        } control: {
            if model.accessibilityGranted { AllowedLabel() }
        }
    }

    /// Apple Dictation is macOS's recogniser, and works only while macOS Dictation is on —
    /// off on a new account. Read again whenever setup comes back to the front.
    private var dictationRow: some View {
        PermissionRow(icon: "waveform", title: "Dictation", detail: "Apple Dictation needs it on.",
                      granted: model.dictationOn, glowID: model.justGranted.row == "dictation" ? model.justGranted.count : 0) {
            EmptyView()
        } actions: {
            if !model.dictationOn {
                Button("Open Keyboard Settings") { OnboardingModel.openKeyboardSettings() }
                    .buttonStyle(SetupLinkButtonStyle(height: 28))
            }
        } control: {
            if model.dictationOn { AllowedLabel(text: "On") }
        }
    }

    private var loginRow: some View {
        PermissionRow(icon: "power", title: "Open at login", detail: "So SpeechText is always ready when you start your Mac.",
                      granted: model.launchAtLogin, glowID: 0) {
            EmptyView()
        } actions: {
            EmptyView()
        } control: {
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .tint(tint.accent)
                .labelsHidden()
        }
    }
}

private struct PermissionRow<State: View, Actions: View, Control: View>: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let glowID: Int
    @ViewBuilder let state: State
    @ViewBuilder let actions: Actions
    @ViewBuilder let control: Control
    @SwiftUI.State private var glow = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 11)
                .fill(granted ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x1F6A48), SetupColor.brandDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                      : AnyShapeStyle(SetupColor.control))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(granted ? .clear : SetupColor.panelBorder, lineWidth: 1))
                .overlay(Image(systemName: icon).font(.system(size: 16)).foregroundStyle(granted ? SetupColor.phosphor : SetupColor.label2))
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 11).stroke(SetupColor.phosphor.opacity(glow ? 0 : 0.7), lineWidth: glow ? 14 : 0))
                .animation(.easeInOut(duration: 0.3), value: granted)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(SetupColor.label)
                Text(detail).font(.system(size: 12)).foregroundStyle(SetupColor.label2)
                VStack(alignment: .leading, spacing: 2) { state }
                    .font(.system(size: 11.5))
                    .padding(.top, 4)
                HStack(spacing: 14) { actions }.padding(.top, 4)
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.vertical, 14)
        .onChange(of: glowID) {
            // A row that has just been granted glows once.
            glow = false
            withAnimation(.easeOut(duration: 1.2)) { glow = true }
        }
        .onAppear { glow = true }
    }
}

private struct PermissionState<Content: View>: View {
    enum Tone { case plain, warn, bad }
    let tone: Tone
    @ViewBuilder let content: Content

    var body: some View {
        content
            .foregroundStyle(tone == .warn ? SetupColor.warn : tone == .bad ? SetupColor.danger : SetupColor.label2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AllowedLabel: View {
    var text = "Allowed"
    var body: some View {
        Text("✓ \(text)").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(SetupColor.ok).fixedSize()
    }
}

private struct WaitingDot: View {
    @State private var dim = false

    var body: some View {
        Circle().fill(Color(hex: 0x0A84FF)).frame(width: 7, height: 7)
            .opacity(dim ? 0.3 : 1).scaleEffect(dim ? 0.8 : 1)
            .padding(.top, 4)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true } }
    }
}

// MARK: - ⑤ Try it

/// The practice step. Three stages share one layout — the step's words and the
/// shortcut on the left, what came of it on the right: a plain dictation; once it
/// worked and AI polish is set up, the same step offering the AI shortcut, drawn as the
/// plain one was; and an AI dictation, whose panel holds only what was said and what the
/// AI wrote. A failure says what happened and offers Try again, which goes back to the
/// stage's opening words.
private struct TryItScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.setupTint) private var tint

    private var appState: AppState { model.appState }
    private var engine: SpeechEngine { appState.speechEngine }
    private var test: DictationTest { appState.dictationTest }
    private var q: String { shortcutText(for: .inline) }
    private var a: String { shortcutText(for: .ai) }
    @AppStorage(SettingsKeys.holdToTalk) private var holdToTalk = false
    /// "You said" opened past its two lines, after an AI dictation.
    @State private var saidExpanded = false
    /// ⌃⇧ of "⌃⇧Q", and Q.
    private var qModifiers: String { shortcutKeys(q).filter(isModifierCap).joined() }
    private var qLetter: String { shortcutKeys(q).last ?? q }
    private var aLetter: String { shortcutKeys(a).last ?? a }

    private enum Phase { case ready, listening, transcribing, success, nothing, rejected, offline, failed(String) }
    private enum AIPhase { case ready, listening, polishing, success(said: String, wrote: String), failed(said: String, reason: String) }

    private var inAI: Bool { appState.isAIMode && !appState.isEditMode }
    private var listening: Bool { engine.isRecording || engine.isStartingEngine }

    private var phase: Phase {
        if listening && !inAI { return .listening }
        if engine.isTranscribing && !inAI { return .transcribing }
        switch test.outcome {
        case nil: return .ready
        case .typed?: return .success
        case .nothingHeard?: return .nothing
        case .failed(let message)?:
            if message.localizedCaseInsensitiveContains("API key") { return .rejected }
            if message.localizedCaseInsensitiveContains("internet") { return .offline }
            return .failed(message)
        }
    }

    private var aiPhase: AIPhase {
        if listening && inAI { return .listening }
        if inAI && (engine.isTranscribing || appState.isRefining) { return .polishing }
        switch test.rewrite {
        case .wrote(let said, let text)?: return .success(said: said, wrote: text)
        case .failed(let said, let reason)?: return .failed(said: said, reason: reason)
        case nil: return .ready
        }
    }

    private var pending: (model: LocalSTTModel, state: LocalModelStore.InstallState)? { model.pendingSpeechModel }

    /// An AI dictation is under way or has ended: the step is about it alone.
    private var aiStage: Bool {
        guard pending == nil, model.aiIsSetUp else { return false }
        if case .ready = aiPhase { return false }
        return true
    }

    /// The plain dictation worked and AI polish is set up: the AI shortcut is offered.
    private var aiOffered: Bool {
        guard pending == nil, model.aiIsSetUp, !aiStage else { return false }
        if case .success = phase { return true }
        return false
    }

    var body: some View {
        StepColumns(copyWidth: 310, insets: EdgeInsets(top: 44, leading: 36, bottom: 24, trailing: 32), copyAlignment: .leading) {
            copy
        } panel: {
            HStack {
                Spacer(minLength: 0)
                panel.frame(width: 316)
            }
        }
        .onChange(of: pending?.state) { model.refreshTestBlock() }
        .onChange(of: test.outcome) { _, outcome in
            // No AI set up: go to Done after 1.5 s, so the ✓ is seen.
            guard case .typed? = outcome, !model.aiIsSetUp else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if model.step == .tryIt, case .typed? = test.outcome { model.go(.done) }
            }
        }
        .onAppear { model.refreshTestBlock() }
        .onChange(of: listening) { saidExpanded = false }
        .animation(.easeInOut(duration: 0.18), value: stageKey)
    }

    // MARK: Left

    @ViewBuilder
    private var copy: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsModePicker {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How the shortcut records").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SetupColor.label3)
                    RecordingModePicker(holdToTalk: $holdToTalk, compact: true)
                }
                // Kept in place while a dictation runs, only dimmed: taking it away and
                // back moved the whole column at each press and release.
                .disabled(!modePickerEnabled)
                .opacity(modePickerEnabled ? 1 : 0.4)
                .padding(.bottom, 26)
            }
            if let pending {
                switch pending.state {
                case .downloading(let f):
                    title(Text("Almost ready…"))
                    body(Text("Your speech model is still downloading (\(Int(f * 100))%). You can wait here or finish setup now — we'll let you know when it's ready."))
                case .optimizing:
                    title(Text("Getting ready for your Mac…"))
                    body(Text("This happens only once and takes \(pending.model.downloadBytes > 500_000_000 ? "about 10 minutes" : "under a minute"). You can wait here or finish setup now — we'll let you know when it's ready."))
                case .failed:
                    title(Text("The download didn't finish"))
                    body(Text("Check your internet connection and try again."))
                default:
                    title(Text("Your speech model isn't downloaded"))
                    body(Text("Download it to try dictating here."))
                }
            } else if aiStage {
                aiCopy
            } else if aiOffered {
                aiOfferCopy
            } else {
                plainCopy
            }
        }
    }

    /// The plain dictation's stage — not the AI stages, whose column is full and whose
    /// mode was chosen by then.
    private var showsModePicker: Bool {
        pending == nil && !aiStage && !aiOffered
    }

    /// Never while a dictation runs, when a change would leave the words on screen
    /// describing the other mode.
    private var modePickerEnabled: Bool { !listening && !engine.isTranscribing }

    /// One value for every state the step draws, so a change between them is animated
    /// as one cross-fade rather than popping in and out a frame at a time.
    private var stageKey: String {
        "\(phase)|\(aiPhase)|\(aiStage)|\(aiOffered)|\(HeldShortcuts.shared.down.contains(.inline))|\(appState.holdTipFollowed)"
    }

    @ViewBuilder
    private var plainCopy: some View {
        switch phase {
        case .ready:
            Text(holdToTalk ? "Try it: hold" : "Try it: press").setupTitle(32)
            LiveShortcutKeycaps(action: .inline, size: 52).padding(.top, 14).padding(.bottom, 18)
            body(Text(holdToTalk ? "Say anything — or read this out, then let go." : "Say anything — or read this out, then press the keys again."))
            example(Self.plainExample)
        case .listening:
            if holdToTalk && HeldShortcuts.shared.down.contains(.inline) {
                // The practice step: the letter alone keeps it going.
                if appState.holdTipFollowed {
                    title(Text("✓ ").foregroundColor(SetupColor.ok) + Text("Just \(qLetter) — that's it"))
                    body(Text("Clicks and ⌘Tab work as usual while you hold it. Let go of \(qLetter) when you're done."))
                } else {
                    title(Text("Now let go of \(qModifiers)"))
                    body(Text("Keep \(qLetter) down — it alone keeps recording, and your hand is free for the mouse and ⌘Tab."))
                }
                LiveShortcutKeycaps(action: .inline, size: 22).padding(.top, 10)
            } else {
                title(Text("Listening…"))
                body(Text(holdToTalk ? "Let go of \(qLetter) when you're done." : "Press \(q) again when you're done."))
                LiveShortcutKeycaps(action: .inline, size: 22, pulsing: true).padding(.top, 10)
            }
            example(Self.plainExample)
            hint("See the small bar at the bottom of your screen? That's SpeechText listening.")
        case .transcribing:
            title(Text("Turning your speech into text…"))
        case .success:
            title(Text("✓ ").foregroundColor(SetupColor.ok) + Text("It works!"))
            body(Text("That's your voice, typed."))
        case .nothing:
            title(Text("We didn't hear anything"))
            body(Text("Check that the right microphone is selected — it's shown on the right — then try again."))
        case .rejected:
            title(Text("Your key stopped working"))
            body(Text("Go back and paste your key again."))
        case .offline:
            title(Text("No internet connection"))
            body(Text("Online services need internet. Connect, then try again."))
        case .failed(let message):
            title(Text("That didn't work"))
            body(Text(message))
            if let fix = settingsFix(for: message) {
                Button(fix.title, action: fix.open)
                    .buttonStyle(SetupLinkButtonStyle(height: 32))
                    .padding(.top, 16)
            }
        }
    }

    /// A failure whose remedy is a System Settings page gets a button to that page: the
    /// path in the message alone was easy to miss.
    private func settingsFix(for message: String) -> (title: String, open: () -> Void)? {
        if message == RecognitionFailure.dictationOffMessage || message.contains("System Settings › Keyboard") {
            return ("Open Keyboard Settings", { OnboardingModel.openKeyboardSettings() })
        }
        if message == RecognitionFailure.speechPermissionMessage {
            return ("Open Privacy Settings", {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
            })
        }
        return nil
    }

    /// The plain dictation worked: the AI shortcut, drawn as the plain one was.
    @ViewBuilder
    private var aiOfferCopy: some View {
        Text("✓ It works!").font(.system(size: 13, weight: .semibold)).foregroundStyle(SetupColor.ok)
            .padding(.bottom, 8)
        if let f = model.pendingAIFraction {
            title(Text("AI polish is almost ready"))
            body(Text("Its model is still downloading (\(Int(f * 100))%). You can wait here, or try it later."))
        } else {
            Text(holdToTalk ? "Now try AI polish: hold" : "Now try AI polish: press").setupTitle(32)
            LiveShortcutKeycaps(action: .ai, size: 52, ai: true).padding(.top, 14).padding(.bottom, 18)
            body(Text("Say something the way you'd say it, hesitations and all — for example:"))
            example(Self.aiExample, ai: true)
        }
    }

    @ViewBuilder
    private var aiCopy: some View {
        switch aiPhase {
        case .ready:
            EmptyView()
        case .listening:
            title(Text("Listening…"))
            body(Text(holdToTalk ? "Let go of \(aLetter) when you're done." : "Press \(a) again when you're done."))
            LiveShortcutKeycaps(action: .ai, size: 22, pulsing: true, ai: true).padding(.top, 10)
            example(Self.aiExample, ai: true)
        case .polishing:
            title(Text("AI is tidying up your text…"))
            body(Text("This takes a few seconds."))
        case .success:
            title(Text("✓ ").foregroundColor(SetupColor.ok) + Text("Here's the AI version"))
            body(Text("What you said, and what AI polish wrote from it — in any app, only the AI version is typed."))
        case .failed:
            title(Text("AI couldn't answer this time"))
            body(Text("In any app, your words would be typed as you said them."))
        }
    }

    /// What to say, kept on screen while the shortcut is down, so there is something to
    /// read from: a short email for the plain dictation, a sentence to tidy for AI polish.
    private static let plainExample = "Hi Josh, thanks for the update. I'll send you the report on Friday. Talk soon."
    private static let aiExample = "Uh, so I think we should, um, move the meeting to Friday — no, wait, Thursday — and, uh, invite Josh too."

    private func example(_ words: String, ai: Bool = false) -> some View {
        Text("“\(words)”")
            .font(.system(size: 13.5).italic())
            .foregroundStyle(SetupColor.label)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(ai ? SetupTint.violet.accent.opacity(0.08) : SetupColor.control))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(ai ? SetupTint.violet.accent : SetupTint.green.accent).frame(width: 3).padding(.vertical, 8)
            }
            .padding(.top, 14)
    }

    private func title(_ text: Text) -> some View { text.setupTitle(32).padding(.bottom, 10) }
    private func body(_ text: Text) -> some View { text.setupLead(14.5) }
    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(SetupColor.label2).padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Right

    private var panel: some View {
        let breathing = (listening && pending == nil)
        return VStack(spacing: 12) {
            Spacer(minLength: 0)
            if aiStage { aiResultCard } else { resultCard }
            if let pending { downloadStatus(pending) }
            links
            skipRow
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .background {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: !breathing)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let s = breathing ? (sin(t * .pi / 0.9) + 1) / 2 : 0
                let color = inAI ? SetupColor.ai : SetupColor.phosphor
                RoundedRectangle(cornerRadius: 14)
                    .fill(SetupColor.panel)
                    .overlay(RoundedRectangle(cornerRadius: 14).fill(color.opacity(breathing ? 0.14 + 0.16 * s : 0)))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(breathing ? color.opacity(0.3 + 0.25 * s) : SetupColor.panelBorder, lineWidth: 1))
            }
        }
    }

    private var resultCard: some View {
        let success: Bool = if case .success = phase { pending == nil } else { false }
        return VStack(spacing: 0) {
            HStack {
                Text("RESULT").font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(SetupColor.label3)
                Spacer()
                chip
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ScrollView {
                resultText
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .frame(height: 7 * 20 + 16)

            meter
        }
        .background(RoundedRectangle(cornerRadius: 13).fill(SetupColor.control))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(success ? tint.accent : SetupColor.panelBorder, lineWidth: success ? 1.5 : 1))
        .background(RoundedRectangle(cornerRadius: 16).fill(SetupColor.phosphor.opacity(success ? 0.22 : 0)).padding(-4))
        .animation(.easeInOut(duration: 0.3), value: success)
    }

    @ViewBuilder
    private var resultText: some View {
        if listening && !inAI {
            let live = liveText
            Text(live.isEmpty ? "Listening…" : live).foregroundStyle(live.isEmpty ? SetupColor.label3 : SetupColor.label2)
        } else if engine.isTranscribing && !inAI {
            HStack(spacing: 8) { SetupSpinner(); Text("Turning your speech into text…").foregroundStyle(SetupColor.label2) }
        } else if case .typed(let text)? = test.outcome {
            Text(text).foregroundStyle(SetupColor.label).textSelection(.enabled)
        } else {
            Text("Your words will appear here.").foregroundStyle(SetupColor.label3)
        }
    }

    private var liveText: String {
        (engine.spanLayer.stableText + " " + engine.spanLayer.segmentProvisionalText)
            .trimmingCharacters(in: .whitespaces)
    }

    @ViewBuilder
    private var chip: some View {
        switch phase {
        case .listening: ChipView(text: "Listening", on: true, dot: true)
        case .transcribing: ChipView(text: "Transcribing", on: false, spinner: true)
        case .success: ChipView(text: "✓ Typed", on: true)
        default: if pending == nil { ChipView(text: "Waiting for \(q)", on: false) }
        }
    }

    /// An AI dictation's panel: what was said and what the AI wrote from it — nothing of
    /// the plain dictation before it.
    private var aiResultCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI POLISH").font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(SetupColor.label3)
                Spacer()
                aiChip
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    column("You said", highlighted: false) { saidText }
                    column("✨ AI wrote", highlighted: true) { wroteText }
                }
                .font(.system(size: 13))
                .lineSpacing(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            // Up to 18 lines, as far as the panel has room: the AI's text is what this
            // stage is for.
            .frame(minHeight: 7 * 20 + 16, maxHeight: 18 * 20 + 16)

            meter
        }
        .background(RoundedRectangle(cornerRadius: 13).fill(SetupColor.control)
            .overlay(RoundedRectangle(cornerRadius: 13).fill(SetupColor.ai.opacity(0.06))))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(SetupColor.ai.opacity(0.3), lineWidth: 1))
    }

    @ViewBuilder
    private var saidText: some View {
        switch aiPhase {
        case .listening:
            let live = liveText
            Text(live.isEmpty ? "Listening…" : live).foregroundStyle(live.isEmpty ? SetupColor.label3 : SetupColor.label2)
        case .polishing:
            let said = engine.spanLayer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if said.isEmpty {
                HStack(spacing: 8) { SetupSpinner(); Text("Turning your speech into text…").foregroundStyle(SetupColor.label2) }
            } else {
                Text(said).foregroundStyle(SetupColor.label)
            }
        case .success(let said, _), .failed(let said, _):
            // Once the AI has written, what was said gives it the room: one line, the
            // rest a click away.
            let long = said.count > 40
            VStack(alignment: .leading, spacing: 4) {
                Text(said.isEmpty ? "—" : said).foregroundStyle(SetupColor.label2).textSelection(.enabled)
                    .lineLimit(long && !saidExpanded ? 1 : nil)
                    .truncationMode(.tail)
                if long {
                    Button(saidExpanded ? "Show less" : "Show all") {
                        withAnimation(.easeOut(duration: 0.2)) { saidExpanded.toggle() }
                    }
                    .buttonStyle(SetupInlineLinkStyle())
                    .font(.system(size: 11.5))
                }
            }
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var wroteText: some View {
        switch aiPhase {
        case .listening:
            Text("Appears when you're done.").foregroundStyle(SetupColor.label3)
        case .polishing:
            HStack(spacing: 8) { SetupSpinner().environment(\.setupTint, .violet); Text("Rewriting…").foregroundStyle(SetupColor.label2) }
        case .success(_, let wrote):
            Text(wrote).foregroundStyle(SetupColor.label).textSelection(.enabled)
        case .failed(_, let reason):
            Text(reason).foregroundStyle(SetupColor.danger)
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var aiChip: some View {
        switch aiPhase {
        case .listening: ChipView(text: "Listening", on: true, dot: true)
        case .polishing: ChipView(text: "Rewriting", on: false, spinner: true)
        case .success: ChipView(text: "✓ Done", on: true)
        case .failed, .ready: ChipView(text: "Waiting for \(a)", on: false)
        }
    }

    private func column<Content: View>(_ label: String, highlighted: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(SetupColor.label3)
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(SetupColor.control))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(highlighted ? SetupColor.ai.opacity(0.45) : SetupColor.panelBorder, lineWidth: 1))
    }

    private var meter: some View {
        let levels = engine.barLevels
        let hot = listening && (levels.max() ?? 0) > 0.05
        let accent = inAI ? SetupColor.ai : tint.accent
        return HStack(spacing: 8) {
            Image(systemName: "mic.fill").font(.system(size: 10)).foregroundStyle(hot ? accent : SetupColor.label3)
            Text(AVCaptureDevice.default(for: .audio)?.localizedName ?? "Microphone")
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0 ..< 22, id: \.self) { i in
                    let level = levels.isEmpty ? 0 : levels[i * levels.count / 22]
                    let jitter = 0.55 + 0.45 * abs(sin(Double(i) * 12.9898))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(hot ? accent : SetupColor.label3)
                        .frame(width: 3, height: max(3, min(16, level * 18 * jitter)))
                }
            }
            .frame(height: 16)
            .animation(.linear(duration: 0.08), value: levels)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(SetupColor.label2)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 9)
        .overlay(alignment: .top) { Rectangle().fill(SetupColor.separator).frame(height: 1) }
    }

    @ViewBuilder
    private func downloadStatus(_ pending: (model: LocalSTTModel, state: LocalModelStore.InstallState)) -> some View {
        switch pending.state {
        case .downloading(let f):
            VStack(alignment: .leading, spacing: 5) {
                SetupProgressBar(fraction: f, height: 5)
                Text("\(speechModelName(pending.model)) · \(Int(f * 100))%").font(.system(size: 11.5)).foregroundStyle(SetupColor.label2)
            }
            .padding(.horizontal, 4)
        case .optimizing:
            VStack(alignment: .leading, spacing: 5) {
                SetupProgressBar(fraction: nil, height: 5)
                Text("Preparing \(speechModelName(pending.model)) for your Mac…").font(.system(size: 11.5)).foregroundStyle(SetupColor.label2)
            }
            .padding(.horizontal, 4)
        default:
            EmptyView()
        }
    }

    /// A failed plain dictation, or a failed AI one, that Try again can take back.
    private var canTryAgain: Bool {
        if aiStage, case .failed = aiPhase { return true }
        if aiStage { return false }
        switch phase {
        case .nothing, .offline, .failed: return true
        default: return false
        }
    }

    @ViewBuilder
    private var links: some View {
        HStack(spacing: 16) {
            if let pending {
                switch pending.state {
                case .downloading, .optimizing:
                    Button("Finish setup") { model.go(.done) }.buttonStyle(SetupInlineLinkStyle(size: 12))
                default:
                    Button("Retry") { model.retrySpeechDownload() }.buttonStyle(SetupLinkButtonStyle(height: 26))
                    Button("Choose another option") { model.go(.speech) }.buttonStyle(SetupInlineLinkStyle(size: 12))
                }
            } else {
                if canTryAgain {
                    Button("Try again") {
                        if aiStage { test.resetRewrite() } else { test.reset() }
                    }
                    .buttonStyle(SetupLinkButtonStyle(height: 26))
                }
                if !aiStage, case .nothing = phase {
                    Button("Open Sound Settings ↗") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!)
                    }
                    .buttonStyle(SetupInlineLinkStyle(size: 12))
                }
                if !aiStage, case .rejected = phase {
                    Button("Back to Speech") { model.go(.speech) }.buttonStyle(SetupLinkButtonStyle(height: 26))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var skipRow: some View {
        if pending == nil, !isSuccess {
            SetupSkipButton(title: "Skip the test") { model.go(.done) }
        } else if aiOffered || (aiStage && !isAISuccess) {
            SetupSkipButton(title: "Skip AI test") { model.go(.done) }
        }
    }

    private var isSuccess: Bool { if case .success = phase { true } else { false } }
    private var isAISuccess: Bool { if case .success = aiPhase { true } else { false } }
}

private struct ChipView: View {
    let text: String
    let on: Bool
    var dot = false
    var spinner = false
    @Environment(\.setupTint) private var tint
    @Environment(\.colorScheme) private var scheme
    @State private var dim = false

    var body: some View {
        HStack(spacing: 5) {
            if dot {
                Circle().fill(.primary).frame(width: 6, height: 6).opacity(dim ? 0.3 : 1)
                    .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true } }
            }
            if spinner { SetupSpinner(size: 9) }
            Text(text)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(on ? (scheme == .dark ? SetupColor.phosphor : SetupColor.brand) : SetupColor.label2)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? SetupColor.phosphor.opacity(0.24) : SetupColor.separator))
    }
}

// MARK: - Done

private struct DoneScreen: View {
    @Bindable var model: OnboardingModel
    @AppStorage(SettingsKeys.holdToTalk) private var holdToTalk = false

    var body: some View {
        StepColumns(copyWidth: 310, insets: EdgeInsets(top: 44, leading: 36, bottom: 24, trailing: 32), copyAlignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                Text("🎉").font(.system(size: 40)).padding(.bottom, 14)
                Text("You're all set").setupTitle(32).padding(.bottom, 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SpeechText lives in your menu bar").font(.system(size: 14, weight: .semibold)).foregroundStyle(SetupColor.label)
                    Text("Its window opens next. Once you close it there's no Dock icon — click the icon at the top of your screen to open SpeechText again.")
                        .font(.system(size: 13)).foregroundStyle(SetupColor.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } panel: {
            HStack {
                Spacer(minLength: 0)
                shortcutsPanel.frame(width: 316)
            }
        }
    }

    private var shortcutsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your shortcuts").font(.system(size: 15, weight: .semibold))
            VStack(spacing: 0) {
                shortcut(.inline, "Dictate", on: true)
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                shortcut(.ai, model.aiIsSetUp ? "Dictate with AI" : "Dictate with AI · off", on: model.aiIsSetUp)
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                shortcut(.edit, model.aiIsSetUp ? "Edit selection" : "Edit selection · off", on: model.aiIsSetUp)
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                shortcut(.recordWindow, "Dictation window", on: true)
            }
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.26)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1), lineWidth: 1))
            (Text(holdToTalk ? "Work in any app. Hold to talk, let go to stop. Change them any time in " : "Work in any app. Press once to start, again to stop. Change them any time in ")
             + Text("Settings").fontWeight(.semibold).foregroundColor(.white) + Text("."))
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            if model.pendingSpeechModel != nil {
                Text("Your speech model is still getting ready. We'll show a message when you can start dictating.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: 0xFFD479))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxHeight: .infinity)
        .background {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x134A33), SetupColor.brandDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(hex: 0x1F6A48), .clear], center: .topLeading, startRadius: 0, endRadius: 300)
                RadialGradient(colors: [SetupColor.phosphor.opacity(0.45), .clear], center: UnitPoint(x: 1, y: 1.1), startRadius: 0, endRadius: 320)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func shortcut(_ action: ShortcutAction, _ title: String, on: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(shortcutKeys(shortcutText(for: action)).enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SetupColor.phosphor)
                        .frame(minWidth: 22, minHeight: 22)
                        .padding(.horizontal, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(SetupColor.phosphor.opacity(0.18)))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(SetupColor.phosphor.opacity(0.4), lineWidth: 1))
                }
            }
            .frame(width: 88, alignment: .leading)
            Text(title).font(.system(size: 13)).foregroundStyle(on ? .white : .white.opacity(0.5))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
