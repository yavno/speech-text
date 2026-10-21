// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import SpeechTextCore

// The setup window's parts, shared by every step. Values follow the design in
// docs/design/setup/setup.css; colours that come from the app are named after their
// source there (TechnoSkin.phosphor, Semantic.ai…).

// MARK: - Colours

extension Color {
    /// A colour with its own light and dark value, resolved per appearance.
    static func setup(_ light: UInt32, _ lightAlpha: Double = 1, dark: UInt32, _ darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

enum SetupColor {
    // Brand — sampled from the app icon
    static let brandDeep = Color(hex: 0x0D3A25)
    static let brand = Color(hex: 0x14543A)
    static let phosphor = TechnoSkin.phosphor
    static let screen = TechnoSkin.screen

    static let card = Color.setup(0xFBFBFB, dark: 0x2A2A2C)
    static let cardRim = Color.setup(0x000000, 0.1, dark: 0xFFFFFF, 0.08)
    static let pill = Color.setup(0xFFFFFF, 0.85, dark: 0xFFFFFF, 0.07)
    static let separator = Color.setup(0x000000, 0.1, dark: 0xFFFFFF, 0.1)
    static let label = Color.setup(0x000000, 0.88, dark: 0xFFFFFF, 0.9)
    static let label2 = Color.setup(0x000000, 0.56, dark: 0xFFFFFF, 0.58)
    static let label3 = Color.setup(0x000000, 0.32, dark: 0xFFFFFF, 0.3)
    static let panel = Color.setup(0xF0F0F2, dark: 0xFFFFFF, 0.04)
    static let panelBorder = Color.setup(0x000000, 0.08, dark: 0xFFFFFF, 0.08)
    static let control = Color.setup(0xFFFFFF, dark: 0xFFFFFF, 0.08)
    static let ok = Color.setup(0x1E8E46, dark: 0x30D158)
    static let warn = Color.setup(0xB35F00, dark: 0xFF9F0A)
    /// Something is wrong — a key refused, a download failed: the main window's calm
    /// teal-green (`MainColor.problem`), not an alarm red.
    static let danger = Color.setup(0x2F7A70, dark: 0x6CC3B5)
    static let ai = Semantic.ai
}

/// The step's colour: the app's greens, or AI violet on the AI step — inside the window
/// only; the frame's glow stays green.
struct SetupTint {
    /// The current step, selections, links.
    let accent: Color
    /// Rings and halos.
    let glow: Color
    let primary: Color
    let card: Color
    let glyph: [Color]
    let glyphInk: Color

    static let green = SetupTint(
        accent: .setup(0x14543A, dark: 0x61C58C),
        glow: SetupColor.phosphor,
        primary: .setup(0x14543A, dark: 0x1D6B4A),
        card: SetupColor.card,
        glyph: [Color(hex: 0x1F6A48), SetupColor.brandDeep],
        glyphInk: SetupColor.phosphor)

    static let violet = SetupTint(
        accent: .setup(0x7652E8, dark: 0xA98BFF),
        glow: .setup(0xB8A2FF, dark: 0x9E7BFF),
        primary: Color(hex: 0x6C4AD8),
        card: .setup(0xF8F5FF, dark: 0x2C2A33),
        glyph: [Color(hex: 0x7B5CE6), Color(hex: 0x3D2491)],
        glyphInk: Color(hex: 0xE4DBFF))
}

private struct SetupTintKey: EnvironmentKey {
    static let defaultValue = SetupTint.green
}

extension EnvironmentValues {
    var setupTint: SetupTint {
        get { self[SetupTintKey.self] }
        set { self[SetupTintKey.self] = newValue }
    }
}

// MARK: - Type

extension View {
    /// Step titles: semibold, a little tracked in, lines set close. Tight leading rather
    /// than `lineHeight`, which draws the text in a box shorter than its glyphs and cuts
    /// the descenders off the last line ("typing").
    func setupTitle(_ size: CGFloat) -> some View {
        font(.system(size: size, weight: .semibold).leading(.tight))
            .tracking(-size * 0.03)
            .foregroundStyle(SetupColor.label)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    func setupLead(_ size: CGFloat = 16) -> some View {
        font(.system(size: size))
            .foregroundStyle(SetupColor.label2)
            .lineSpacing(size * 0.3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Frame

/// A slow glow in the app's greens that turns and drifts under the window, seen through
/// its glass rim — clipped to the window's shape, never spilling out. Drawn on the GPU
/// (`drawingGroup`): left to Core Graphics, the blurred gradients were rasterised on the
/// main thread 30 times a second, about 30% of a core while Settings or setup was open.
/// It stands still while its window cannot be seen.
struct SetupAura: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowVisible = true

    private struct Blob {
        let color: Color
        let size: CGSize
        let center: CGPoint
        let period: Double
        let phase: Double
    }

    private let blobs: [Blob] = [
        Blob(color: SetupColor.phosphor, size: .init(width: 0.38, height: 0.42), center: .init(x: 0.33, y: 0.33), period: 5, phase: 0),
        Blob(color: Color(red: 31 / 255, green: 138 / 255, blue: 90 / 255).opacity(0.9), size: .init(width: 0.36, height: 0.44), center: .init(x: 0.70, y: 0.38), period: 6, phase: 2),
        Blob(color: SetupColor.phosphor.opacity(0.75), size: .init(width: 0.42, height: 0.36), center: .init(x: 0.51, y: 0.70), period: 4, phase: 1),
        Blob(color: Color(red: 47 / 255, green: 158 / 255, blue: 103 / 255).opacity(0.95), size: .init(width: 0.32, height: 0.40), center: .init(x: 0.28, y: 0.64), period: 6, phase: 3),
        Blob(color: Semantic.confirmation.opacity(0.7), size: .init(width: 0.30, height: 0.36), center: .init(x: 0.71, y: 0.68), period: 5, phase: 4),
        Blob(color: SetupColor.brand.opacity(0.55), size: .init(width: 0.26, height: 0.30), center: .init(x: 0.53, y: 0.35), period: 7, phase: 1),
        Blob(color: Semantic.confirmation.opacity(0.45), size: .init(width: 0.24, height: 0.28), center: .init(x: 0.58, y: 0.60), period: 4, phase: 2),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !windowVisible)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    AngularGradient(colors: [
                        Color(red: 97 / 255, green: 197 / 255, blue: 140 / 255).opacity(0.8),
                        SetupColor.brandDeep.opacity(0.55),
                        Semantic.confirmation.opacity(0.6),
                        Color(red: 97 / 255, green: 197 / 255, blue: 140 / 255).opacity(0.1),
                        Color(red: 47 / 255, green: 158 / 255, blue: 103 / 255).opacity(0.75),
                        SetupColor.brand.opacity(0.25),
                        Color(red: 97 / 255, green: 197 / 255, blue: 140 / 255).opacity(0.8),
                    ], center: .center)
                    .frame(width: size.width * 1.7, height: size.height * 1.7)
                    .rotationEffect(.degrees((t / 9).truncatingRemainder(dividingBy: 1) * 360))

                    ForEach(blobs.indices, id: \.self) { i in
                        let blob = blobs[i]
                        // An eased back-and-forth, like the design's `alternate` drift.
                        let s = (sin((t + blob.phase) / blob.period * .pi) + 1) / 2
                        let dx = (0.38 * sin(s * .pi * 1.5) - 0.1 * s) * blob.size.width * size.width
                        let dy = (-0.26 * sin(s * .pi) + 0.3 * s * s) * blob.size.height * size.height
                        Ellipse()
                            .fill(RadialGradient(colors: [blob.color, blob.color.opacity(0)], center: .center,
                                                 startRadius: 0, endRadius: blob.size.width * size.width / 2))
                            .frame(width: blob.size.width * size.width, height: blob.size.height * size.height)
                            .scaleEffect(0.85 + 0.4 * s)
                            .opacity(0.45 + 0.55 * s)
                            .position(x: blob.center.x * size.width + dx, y: blob.center.y * size.height + dy)
                    }
                }
                .frame(width: size.width, height: size.height)
                .blur(radius: 22)
                .drawingGroup()
            }
        }
        .background(WindowVisibilityReader(isVisible: $windowVisible))
    }
}

/// Whether the window a view is in can be seen at all — false while it is covered,
/// minimised, on another Space or not ordered in — so an animation can stop drawing
/// frames nobody sees.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return report(false) }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportWindowState() }
            }
            reportWindowState()
        }

        private func reportWindowState() {
            report(window?.occlusionState.contains(.visible) ?? false)
        }

        // Never during the view update that moved it into the window.
        private func report(_ visible: Bool) {
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }
    }
}

/// Behind-window vibrancy, so the glass rim is glass over the desktop too.
struct SetupVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The window: glass rim over the glow, the card inside it.
struct SetupFrame<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        ZStack {
            SetupVibrancy().clipShape(shape)
            SetupAura().clipShape(shape)
            shape.fill(LinearGradient(
                stops: scheme == .dark
                    ? [.init(color: Color(white: 0.16, opacity: 0.42), location: 0),
                       .init(color: Color(white: 0.1, opacity: 0.3), location: 0.45),
                       .init(color: Color(white: 0.14, opacity: 0.38), location: 1)]
                    : [.init(color: .white.opacity(0.5), location: 0),
                       .init(color: .white.opacity(0.22), location: 0.45),
                       .init(color: .white.opacity(0.36), location: 1)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.strokeBorder(.white.opacity(scheme == .dark ? 0.14 : 0.6), lineWidth: 1)
            content.padding(8)
        }
        .overlay(shape.strokeBorder(.black.opacity(scheme == .dark ? 0.6 : 0.14), lineWidth: 0.5))
    }
}

/// macOS' three window buttons, drawn — the window has no title bar to carry them.
struct SetupTrafficLights: View {
    let onClose: () -> Void
    let onMinimize: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            light(Color(hex: 0xFF5F57), symbol: "xmark", action: onClose)
            light(Color(hex: 0xFEBC2E), symbol: "minus", action: onMinimize)
            // Not resizable: the zoom button is disabled.
            Circle().fill(SetupColor.label3.opacity(0.6)).frame(width: 14, height: 14)
        }
        .onHover { hovering = $0 }
    }

    private func light(_ color: Color, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(color)
                .overlay(Circle().strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black.opacity(0.55))
                        .opacity(hovering ? 1 : 0)
                }
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step progress

/// The path across the footer, on a glass capsule; the primary button is the stop after it.
/// Completed steps are links back.
struct SetupStepsBar: View {
    let current: OnboardingStep
    let onGo: (OnboardingStep) -> Void
    @Environment(\.setupTint) private var tint

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(OnboardingStep.named.enumerated()), id: \.element) { index, step in
                if index > 0 {
                    connector(after: OnboardingStep.named[index - 1])
                }
                item(step)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(SetupColor.pill))
        .overlay(Capsule().strokeBorder(SetupColor.cardRim, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    private func state(of step: OnboardingStep) -> StepDot.State {
        if step == current || (current == .done && step == .tryIt) {
            return current == .done ? .done : .current
        }
        return step < current ? .done : .upcoming
    }

    @ViewBuilder
    private func item(_ step: OnboardingStep) -> some View {
        let state = state(of: step)
        let label = HStack(spacing: 6) {
            StepDot(state: state)
            Text(step.title)
                .font(.system(size: 12, weight: state == .current ? .semibold : .regular))
                .foregroundStyle(state == .current ? SetupColor.label : state == .done ? SetupColor.label2 : SetupColor.label3)
                .fixedSize()
        }
        if state == .done && step != current && current != .done {
            Button { onGo(step) } label: { label }
                .buttonStyle(.plain)
                .help("Back to \(step.title)")
                .pointingHandCursor()
        } else {
            label
        }
    }

    private func connector(after step: OnboardingStep) -> some View {
        let before = state(of: step)
        return Rectangle()
            .fill(before == .done
                  ? AnyShapeStyle(tint.accent)
                  : before == .current
                    ? AnyShapeStyle(LinearGradient(colors: [tint.accent, SetupColor.separator], startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(SetupColor.separator))
            .frame(minWidth: 10, maxWidth: .infinity)
            .frame(height: 1)
            .padding(.horizontal, 8)
    }
}

struct StepDot: View {
    enum State { case upcoming, current, done }
    let state: State
    @Environment(\.setupTint) private var tint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var breathing = false

    var body: some View {
        switch state {
        case .upcoming:
            Circle().strokeBorder(SetupColor.label3, lineWidth: 1.5).frame(width: 9, height: 9)
        case .current:
            // The current step breathes: the dot grows and shrinks, its halo swells and fades.
            Circle().fill(tint.accent)
                .frame(width: 9, height: 9)
                .background(Circle().fill(tint.accent.opacity(breathing ? 0.14 : 0.28))
                    .padding(breathing ? -3.5 : -2))
                .scaleEffect(breathing ? 1.12 : 1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathing = true }
                }
        case .done:
            Circle().fill(tint.accent)
                .frame(width: 11, height: 11)
                .overlay(Image(systemName: "checkmark").font(.system(size: 6, weight: .heavy)).foregroundStyle(tint.card))
        }
    }
}

// MARK: - Buttons

struct SetupButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind
    var height: CGFloat = 36
    /// The pointer is over it — passed by a button that tracks its own hover (History's
    /// Copy and Retry); everywhere else the style draws no hover, as before.
    var hovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.setupTint) private var tint

    /// The top of a filled button catches a little light.
    static let sheen = LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0)], startPoint: .top, endPoint: .bottom)

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, kind == .primary ? 20 : 16)
            .frame(height: height)
            .foregroundStyle(kind == .primary ? Color.white : SetupColor.label)
            .background {
                if kind == .primary {
                    shape.fill(tint.primary).overlay(shape.fill(Self.sheen))
                        .overlay(shape.strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                        // A soft ring that always sits around the button, not only on focus.
                        .background(shape.fill(tint.glow.opacity(isEnabled ? 0.42 : 0.18)).padding(height > 30 ? -3.5 : -2.5))
                } else {
                    shape.fill(SetupColor.control)
                        .overlay(shape.fill(Color.primary.opacity(hovered && isEnabled ? 0.06 : 0)))
                        .overlay(shape.strokeBorder(.black.opacity(hovered && isEnabled ? 0.26 : 0.18), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.06), radius: 0.5, y: 1)
                }
            }
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .contentShape(shape)
    }
}

/// A small filled capsule for an action inside the panel ("Get your key ↗", "Allow").
struct SetupLinkButtonStyle: ButtonStyle {
    var height: CGFloat = 24
    @Environment(\.setupTint) private var tint

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: height > 24 ? 12.5 : 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, height > 24 ? 12 : 10)
            .frame(height: height)
            .background(Capsule().fill(tint.primary).overlay(Capsule().fill(SetupButtonStyle.sheen)))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .contentShape(Capsule())
    }
}

/// Text in the step's colour: "Try again", "Change", "Open again".
struct SetupInlineLinkStyle: ButtonStyle {
    var size: CGFloat = 11.5
    @Environment(\.setupTint) private var tint

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(tint.accent)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// The way past a step — one text button everywhere: bolder and in the step's colour so it
/// reads as clickable, never a capsule that would compete with Back and Continue.
struct SetupSkipButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(SetupInlineLinkStyle(size: 12.5))
            .fontWeight(.semibold)
            .pointingHandCursor()
    }
}

// MARK: - Panel parts

struct SetupPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(SetupColor.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SetupColor.panelBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// One answer of a step's question, as a card in a radio group.
struct SetupChoiceCard: View {
    enum Glyph { case mac, cloud }
    let glyph: Glyph
    let name: String
    var badge: String?
    var why: String?
    let facts: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.setupTint) private var tint
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected
                          ? AnyShapeStyle(LinearGradient(colors: tint.glyph, startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(SetupColor.panel))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? .clear : SetupColor.panelBorder, lineWidth: 0.5))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: glyph == .mac ? "laptopcomputer" : "cloud")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isSelected ? tint.glyphInk : SetupColor.label2)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(SetupColor.label)
                        if let badge { SetupBadge(text: badge, kind: .recommended) }
                    }
                    if let why {
                        Text(why).font(.system(size: 12, weight: .medium)).foregroundStyle(tint.accent)
                    }
                    Text(facts)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SetupColor.label2)
                        .lineSpacing(2)
                        .padding(.top, 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16).fill(SetupColor.control))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? tint.accent : hovering ? tint.accent.opacity(0.4) : SetupColor.panelBorder,
                                  lineWidth: isSelected ? 1.5 : 1)
            }
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 20).fill(tint.glow.opacity(0.32)).padding(-4)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct SetupBadge: View {
    enum Kind { case recommended, quality, warn, done }
    let text: String
    let kind: Kind
    @Environment(\.setupTint) private var tint
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let (ink, fill): (Color, Color) = switch kind {
        case .recommended: (scheme == .dark ? tint.glow : tint.accent, tint.glow.opacity(scheme == .dark ? 0.16 : 0.24))
        case .quality: (SetupColor.label2, SetupColor.separator)
        case .warn: (SetupColor.warn, Color(hex: 0xFF9F0A).opacity(0.2))
        case .done: (SetupColor.ok, Semantic.confirmation.opacity(0.16))
        }
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8).fill(fill))
    }
}

/// A radio row in the panel: a model, or a service.
struct SetupRow<Detail: View>: View {
    let title: String
    var subtitle: String?
    var badge: SetupBadge?
    /// A language the model lacks ("No Spanish"), beside whatever `badge` says — a
    /// recommendation or an install state never hides it.
    var languageBadge: SetupBadge? = nil
    var detail: String?
    let isSelected: Bool
    var dimmed = false
    var compact = false
    let action: () -> Void
    @ViewBuilder var extra: Detail
    @Environment(\.setupTint) private var tint
    @State private var hovering = false

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 10) {
            ZStack {
                if isSelected {
                    Circle().fill(tint.accent)
                    Circle().fill(tint.card).frame(width: 6, height: 6)
                } else {
                    Circle().strokeBorder(SetupColor.label3, lineWidth: 1.5)
                }
            }
            .frame(width: 16, height: 16)
            .padding(.top, compact ? 0 : 1)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(dimmed ? SetupColor.label2 : SetupColor.label)
                    if let subtitle {
                        Text("· \(subtitle)").font(.system(size: 13)).foregroundStyle(SetupColor.label2)
                    }
                    if let badge { badge.padding(.leading, 4) }
                    if let languageBadge { languageBadge.padding(.leading, badge == nil ? 4 : 0) }
                }
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(SetupColor.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                extra
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 5 : 8)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? SetupColor.control : hovering ? SetupColor.control.opacity(0.6) : .clear)
                .shadow(color: .black.opacity(isSelected ? 0.05 : 0), radius: 1, y: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? SetupColor.panelBorder : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

extension SetupRow where Detail == EmptyView {
    init(title: String, subtitle: String? = nil, badge: SetupBadge? = nil, languageBadge: SetupBadge? = nil,
         detail: String? = nil, isSelected: Bool, dimmed: Bool = false, compact: Bool = false,
         action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, badge: badge, languageBadge: languageBadge, detail: detail, isSelected: isSelected,
                  dimmed: dimmed, compact: compact, action: action, extra: { EmptyView() })
    }
}

/// A thin progress bar inside a row; nil fraction runs indeterminately.
struct SetupProgressBar: View {
    let fraction: Double?
    var height: CGFloat = 4
    @Environment(\.setupTint) private var tint
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SetupColor.separator)
                if let fraction {
                    Capsule().fill(tint.accent).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                        .animation(.linear(duration: 0.3), value: fraction)
                } else {
                    Capsule().fill(tint.accent).frame(width: proxy.size.width * 0.3)
                        .offset(x: sweep ? proxy.size.width : -proxy.size.width * 0.3)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { sweep = true }
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

struct SetupSpinner: View {
    var size: CGFloat = 11
    @Environment(\.setupTint) private var tint
    @State private var turning = false

    var body: some View {
        Circle()
            .stroke(SetupColor.separator, lineWidth: 1.5)
            .overlay(Circle().trim(from: 0, to: 0.25).stroke(tint.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turning = true }
            }
    }
}

// MARK: - The key block

/// Connecting an online account: where to get a key, and a field that picks it up.
/// Shared by the Speech and AI steps; `collapsedText` replaces it with one line when the
/// key is already in hand (Groq's or OpenAI's, connected on the Speech step).
struct SetupKeyBlock: View {
    @Bindable var model: OnboardingModel
    let service: Provider
    var collapsedText: String?
    var compact = false
    @State private var draft = ""
    @State private var pasteHint: String?
    @FocusState private var focused: Bool
    @Environment(\.setupTint) private var tint

    private var entry: OnboardingModel.KeyEntry { model.key(service) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(SetupColor.separator).frame(height: 1).padding(.bottom, compact ? 10 : 12)
            Text("Connect your \(service.displayName) account")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(SetupColor.label)
                .padding(.bottom, 2)
            if let collapsedText {
                statusLine(.ok, text: "✓ \(collapsedText)")
            } else {
                Text("A key is like a password that lets SpeechText use your account.")
                    .font(.system(size: 11.5)).foregroundStyle(SetupColor.label2)
                    .padding(.bottom, compact ? 8 : 10)
                VStack(alignment: .leading, spacing: 7) {
                    howStep(1) {
                        Button(service.linkTitle) { model.getKey(service) }
                            .buttonStyle(SetupLinkButtonStyle())
                            .pointingHandCursor()
                        Text("sign in, then click **\(service.descriptor.apiKey?.createButton ?? "")**.")
                    }
                    howStep(2) { Text(LocalizedStringKey(service.descriptor.apiKey?.createNote ?? "")) }
                    howStep(3) { Text("Come back here — we'll pick it up automatically.") }
                }
                .font(.system(size: 12))
                .foregroundStyle(SetupColor.label2)
                .padding(.bottom, compact ? 10 : 12)

                HStack(spacing: 6) {
                    field
                    Button("Paste") {
                        if model.pasteKey(service) { draft = model.key(service).value; pasteHint = nil }
                        else { pasteHint = "Your clipboard is empty — copy the key on the website first." }
                    }
                    .buttonStyle(SetupButtonStyle(kind: .secondary, height: 30))
                    .font(.system(size: 12))
                }
                status
            }
        }
        .onAppear { draft = entry.value }
        .onChange(of: service) { draft = model.key(service).value; pasteHint = nil }
        .onChange(of: entry.value) { _, new in if !focused { draft = new } }
    }

    private func howStep<C: View>(_ n: Int, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Text("\(n)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(SetupColor.label)
                .frame(width: 18, height: 18)
                .background(Circle().fill(SetupColor.separator))
            content().fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        HStack(spacing: 6) {
            if entry.status.isLocked {
                Text(mask(entry.value))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SetupColor.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if entry.status == .valid || entry.status == .offline {
                    Button("Change") { model.changeKey(service); draft = ""; focused = true }
                        .buttonStyle(SetupInlineLinkStyle())
                }
            } else {
                TextField("", text: $draft, prompt: Text("Paste your key here").foregroundStyle(SetupColor.label3))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onChange(of: draft) { _, new in
                        if new.trimmingCharacters(in: .whitespacesAndNewlines) != entry.value { model.typeKey(service, new) }
                    }
                    .accessibilityLabel("\(service.displayName) key")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(shape.fill(SetupColor.control))
        .overlay {
            shape.strokeBorder(entry.status == .invalid ? SetupColor.danger : focused ? tint.accent : SetupColor.panelBorder,
                               lineWidth: entry.status == .invalid || focused ? 1.5 : 1)
        }
        .background(shape.fill(tint.glow.opacity(focused ? 0.25 : 0)).padding(-3))
        .opacity(entry.status == .checking || entry.status == .found ? 0.7 : 1)
    }

    private func mask(_ value: String) -> String {
        APIKeyDisplay.masked(value, prefix: service.descriptor.apiKey?.prefix)
    }

    private enum Tone { case plain, ok, bad, warn }

    @ViewBuilder
    private var status: some View {
        Group {
            if let pasteHint, entry.status == .empty {
                statusLine(.plain, text: pasteHint)
            } else {
                switch entry.status {
                case .empty: statusLine(.plain, text: "")
                case .waiting: statusLine(.plain, text: "Waiting for your key… Copy it on the website and come back.", spinner: true)
                case .found: statusLine(.plain, text: "Found a key on your clipboard.", spinner: true)
                case .checking: statusLine(.plain, text: "Checking your key…", spinner: true)
                case .valid: statusLine(.ok, text: "✓ Your key works.")
                case .invalid: statusLine(.bad, text: "✗ This key didn't work. Copy it again from the website — make sure you copied all of it.")
                case .offline:
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("⚠︎ Couldn't check the key — no internet connection. You can continue and we'll try again later.")
                            .foregroundStyle(SetupColor.warn)
                        Button("Try again") { model.verify(service) }.buttonStyle(SetupInlineLinkStyle())
                    }
                    .font(.system(size: 11.5))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(minHeight: compact ? 0 : 32, alignment: .topLeading)
        .padding(.top, 7)
    }

    private func statusLine(_ tone: Tone, text: String, spinner: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if spinner { SetupSpinner().padding(.top, 1) }
            Text(text)
                .font(.system(size: 11.5, weight: tone == .ok ? .medium : .regular))
                .foregroundStyle(tone == .ok ? SetupColor.ok : tone == .bad ? SetupColor.danger
                                 : tone == .warn ? SetupColor.warn : SetupColor.label2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Background task pill

/// Top-right of the card on every step after a download starts: what is still arriving,
/// with a popover to cancel or retry it. A finished download says so and fades.
struct SetupTaskPill: View {
    @Bindable var model: OnboardingModel
    @State private var showsDetails = false
    @State private var readyAt: [String: Date] = [:]

    private struct Task: Identifiable {
        enum Phase { case downloading(Double), preparing, ready, failed(String) }
        let id: String
        let label: String
        let name: String
        let size: String
        let phase: Phase
    }

    private var tasks: [Task] {
        var tasks: [Task] = []
        if let id = model.speechDownloadID, let speech = localSTTModel(id: id) {
            let phase: Task.Phase? = switch model.store.state(for: id) {
            case .downloading(let f): .downloading(f)
            case .optimizing: .preparing
            case .installed: .ready
            case .failed(let why): .failed(why)
            case .notInstalled: nil
            }
            if let phase {
                tasks.append(Task(id: "speech", label: "Speech model", name: speech.displayName,
                                  size: speech.downloadSizeDescription, phase: phase))
            }
        }
        if let id = model.aiDownloadID, let chat = localChatModel(id: id) {
            let phase: Task.Phase? = switch model.chatStore.state(for: chat) {
            case .downloading(let f): .downloading(f)
            case .optimizing: .preparing
            case .installed: .ready
            case .failed(let why): .failed(why)
            case .notInstalled: nil
            }
            if let phase {
                tasks.append(Task(id: "ai", label: "AI model", name: chat.displayName,
                                  size: chat.downloadSizeDescription, phase: phase))
            }
        }
        return tasks
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let visible = tasks.filter { task in
                if case .ready = task.phase, let at = readyAt[task.id] { return context.date.timeIntervalSince(at) < 3 }
                return true
            }
            if !visible.isEmpty {
                Button { showsDetails.toggle() } label: {
                    HStack(spacing: 10) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, task in
                            if index > 0 { Rectangle().fill(SetupColor.separator).frame(width: 1, height: 12) }
                            line(task)
                        }
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(SetupColor.pill))
                    .overlay(Capsule().strokeBorder(SetupColor.cardRim, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) { details(visible) }
            }
        }
        .onChange(of: tasks.map { "\($0.id):\(phaseKey($0.phase))" }) { _, keys in
            for key in keys where key.hasSuffix(":ready") {
                let id = String(key.dropLast(":ready".count))
                if readyAt[id] == nil { readyAt[id] = Date() }
            }
        }
    }

    private func phaseKey(_ phase: Task.Phase) -> String {
        switch phase {
        case .downloading: "downloading"
        case .preparing: "preparing"
        case .ready: "ready"
        case .failed: "failed"
        }
    }

    @ViewBuilder
    private func line(_ task: Task) -> some View {
        switch task.phase {
        case .downloading(let f):
            HStack(spacing: 7) {
                ProgressRing(fraction: f)
                Text("\(task.label) · \(Int(f * 100))%").foregroundStyle(SetupColor.label)
            }
        case .preparing:
            HStack(spacing: 7) {
                SetupSpinner()
                Text("Preparing speech model for your Mac…").foregroundStyle(SetupColor.label)
            }
        case .ready:
            Text("✓ \(task.label) ready").foregroundStyle(SetupColor.ok)
        case .failed:
            Text("⚠︎ \(task.label) download failed · Retry").foregroundStyle(SetupColor.danger)
        }
    }

    private func details(_ tasks: [Task]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(task.label) — \(task.name)\(task.size.isEmpty ? "" : " (\(task.size))")")
                        .font(.system(size: 12.5, weight: .semibold))
                    switch task.phase {
                    case .downloading(let f):
                        Text("Downloading · \(Int(f * 100))%").foregroundStyle(.secondary)
                        cancel(task)
                    case .preparing:
                        Text("Getting ready for your Mac. This happens only once and can take up to 10 minutes. You can keep going.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    case .ready:
                        Text("Ready.").foregroundStyle(.secondary)
                    case .failed(let why):
                        Text("The download stopped. Check your internet connection.").foregroundStyle(.secondary)
                        Text(why).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        Button("Retry") { retry(task) }.buttonStyle(SetupButtonStyle(kind: .secondary, height: 26))
                    }
                }
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 290, alignment: .leading)
    }

    private func cancel(_ task: Task) -> some View {
        Button("Cancel download") {
            if task.id == "speech", let id = model.speechDownloadID, let m = localSTTModel(id: id) {
                model.store.cancelInstall(m)
            } else if let id = model.aiDownloadID, let chat = localChatModel(id: id) {
                model.chatStore.cancelInstall(chat)
            }
            showsDetails = false
        }
        .buttonStyle(SetupButtonStyle(kind: .secondary, height: 26))
    }

    private func retry(_ task: Task) {
        if task.id == "speech", let id = model.speechDownloadID, let m = localSTTModel(id: id) {
            model.store.install(m)
        } else if let id = model.aiDownloadID, let chat = localChatModel(id: id) {
            model.chatStore.install(chat)
        }
    }
}

struct ProgressRing: View {
    let fraction: Double
    @Environment(\.setupTint) private var tint

    var body: some View {
        ZStack {
            Circle().fill(SetupColor.separator)
            Circle().trim(from: 0, to: fraction).stroke(tint.accent, lineWidth: 6)
                .rotationEffect(.degrees(-90))
                .padding(3)
        }
        .frame(width: 12, height: 12)
        .clipShape(Circle())
    }
}

// MARK: - Keycaps

/// A shortcut drawn as keys, each symbol its own cap. `litKeys` are the indexes of the
/// caps whose key is down; `fadedKeys` the caps no longer needed — a held recording's
/// modifiers once its letter is down, dimmed with a dashed edge even while still
/// held; `ringKeys` the caps to keep down, drawn with a ring around them.
struct SetupKeycaps: View {
    let keys: [String]
    var size: CGFloat = 22
    var litKeys: Set<Int> = []
    var fadedKeys: Set<Int> = []
    var ringKeys: Set<Int> = []
    var pulsing = false
    var ai = false
    @Environment(\.colorScheme) private var scheme
    @State private var pulse = false

    var body: some View {
        HStack(spacing: size > 40 ? 8 : 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                let faded = fadedKeys.contains(index)
                let lit = litKeys.contains(index) && !faded
                let base = ai ? SetupColor.ai : SetupColor.phosphor
                let corner = size * 0.25
                Text(key)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(lit ? (ai ? .white : SetupColor.screen)
                                     : ai ? (scheme == .dark ? Color(hex: 0xC7B3FF) : Color(hex: 0x6B46E0))
                                     : (scheme == .dark ? SetupColor.phosphor : SetupColor.brand))
                    .frame(minWidth: size, minHeight: size)
                    .padding(.horizontal, size * 0.12)
                    .background(RoundedRectangle(cornerRadius: corner)
                        .fill(lit ? base : faded ? base.opacity(0.06)
                              : base.opacity(pulse ? 0.5 : (ai ? 0.18 : (scheme == .dark ? 0.16 : 0.24)))))
                    .overlay {
                        if faded {
                            RoundedRectangle(cornerRadius: corner)
                                .strokeBorder(base.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                        } else {
                            RoundedRectangle(cornerRadius: corner).strokeBorder(base.opacity(lit ? 0 : 0.45), lineWidth: 1)
                        }
                    }
                    .overlay {
                        if ringKeys.contains(index) {
                            RoundedRectangle(cornerRadius: corner + 3)
                                .strokeBorder(base.opacity(0.8), lineWidth: max(1, size * 0.06))
                                .padding(-max(3, size * 0.12))
                        }
                    }
                    .opacity(faded ? 0.35 : 1)
                    .shadow(color: lit ? base.opacity(0.65) : .clear, radius: 8)
                    .offset(y: lit ? 1 : 0)
            }
        }
        .animation(.easeOut(duration: 0.15), value: litKeys)
        .animation(.easeOut(duration: 0.2), value: fadedKeys)
        .animation(.easeOut(duration: 0.2), value: ringKeys)
        .onChange(of: pulsing, initial: true) { _, on in
            if on {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { pulse = false }
            }
        }
    }
}

/// A shortcut's caps drawn from the keys as they are right now: each lit while its own
/// key is down, and — with hold to talk, once the letter is down — the modifiers faded
/// and the letter ringed, since the letter alone now keeps the recording going.
/// The letter comes from `HeldShortcuts` (Carbon takes the key event; no window sees
/// it), the modifiers from `ModifierKeys`; both are observed, so the caps are redrawn
/// when a key moves rather than on a timer.
struct LiveShortcutKeycaps: View {
    let action: ShortcutAction
    /// The combination to draw; the stored one when nil.
    var text: String? = nil
    var size: CGFloat = 22
    var pulsing = false
    var ai = false
    @AppStorage(SettingsKeys.holdToTalk) private var holdToTalk = false

    var body: some View {
        let keys = shortcutKeys(text ?? shortcutText(for: action))
        let caps = liveKeycapStates(keys: keys, letterDown: HeldShortcuts.shared.down.contains(action),
                                    holdToTalk: holdToTalk && action != .recordWindow,
                                    flags: ModifierKeys.shared.flags)
        SetupKeycaps(keys: keys, size: size,
                     litKeys: caps.indexes(of: .down), fadedKeys: caps.indexes(of: .notNeeded),
                     ringKeys: caps.contains(.notNeeded) ? caps.indexes(of: .down) : [],
                     pulsing: pulsing, ai: ai)
            .onAppear { ModifierKeys.shared.watch() }
            .onDisappear { ModifierKeys.shared.unwatch() }
    }
}

/// The modifier keys as they are now, for the views that draw them live. Kept from the
/// system's flagsChanged events — the window's own, and every other app's (which needs
/// the Accessibility permission a paste needs anyway) — only while such a view is shown.
@MainActor @Observable
final class ModifierKeys {
    static let shared = ModifierKeys()

    private(set) var flags: NSEvent.ModifierFlags = []
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var watchers = 0

    func watch() {
        watchers += 1
        guard monitors.isEmpty else { return }
        take(NSEvent.modifierFlags)
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.take(event.modifierFlags)
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.take(event.modifierFlags)
        }
        monitors = [local, global].compactMap { $0 }
    }

    func unwatch() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func take(_ raw: NSEvent.ModifierFlags) {
        let next = raw.intersection([.control, .option, .shift, .command])
        if next != flags { flags = next }
    }
}

/// Each cap's state for `keys` ("⌃", "⇧", "Q") as the keyboard is now.
func liveKeycapStates(keys: [String], letterDown: Bool, holdToTalk: Bool,
                      flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> [KeycapState] {
    let modifierKeys = keys.filter(isModifierCap)
    let modifiersDown = modifierKeys.map { key in
        switch key {
        case "⌃": flags.contains(.control)
        case "⌥": flags.contains(.option)
        case "⇧": flags.contains(.shift)
        default: flags.contains(.command)
        }
    }
    let caps = HoldTip.keycaps(modifiersDown: modifiersDown, letterDown: letterDown, holdToTalk: holdToTalk)
    var modifiers = caps.modifiers.makeIterator()
    return keys.map { isModifierCap($0) ? (modifiers.next() ?? .up) : caps.letter }
}

/// The modifier caps of `keys` are down, the letter is down: the hold tip was followed.
func modifiersOfHeldShortcutLetGo(keys: [String], letterDown: Bool) -> Bool {
    let states = liveKeycapStates(keys: keys, letterDown: letterDown, holdToTalk: false)
    let modifiersDown = zip(keys, states).filter { isModifierCap($0.0) }.map { $0.1 == .down }
    return HoldTip.isFollowed(modifiersDown: modifiersDown, letterDown: letterDown)
}

func isModifierCap(_ key: String) -> Bool { "⌃⌥⇧⌘".contains(key) && key.count == 1 }

extension Array where Element == KeycapState {
    func indexes(of state: KeycapState) -> Set<Int> {
        Set(enumerated().filter { $0.element == state }.map(\.offset))
    }
}

/// "⌃⇧Q" → ["⌃", "⇧", "Q"].
func shortcutKeys(_ text: String) -> [String] {
    var keys: [String] = []
    var rest = Substring(text)
    while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
        keys.append(String(first))
        rest = rest.dropFirst()
    }
    if !rest.isEmpty { keys.append(String(rest)) }
    return keys
}
