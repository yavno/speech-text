// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import SpeechTextCore

// MARK: - Inline overlay

/// The strip that floats in a corner of the screen while an inline dictation is running,
/// and — for a streaming recording — the transcript being built above it.
///
/// It has no controls of its own by design — the hotkey starts and stops it. The only
/// affordance is a cancel button, kept beside the display rather than over it.
///
/// The transcript is why this exists as more than a meter: a streaming provider closes a
/// sentence on a short pause and reopens it a moment later ("…почнемо. Потім" →
/// "…почнемо, потім"), and only a surface we own can show that correction happening.
/// The text is pasted once, at the stop, in its final form.
///
/// Both skins live here rather than in separate files: they show the same states
/// (listening, working, AI, the transcript) from the same inputs, and keeping them in
/// one place is what stops one of them from quietly falling behind.
struct RecordingOverlayView: View {
    let barLevels: [CGFloat]
    let isLoading: Bool
    let isPreparing: Bool
    /// Recolours the display so an LLM-processed dictation is obvious at a glance.
    var isAIMode: Bool = false
    /// An edit of selected text (the Edit shortcut): the recording is an instruction, and
    /// the panel is filled violet rather than outlined, with the pencil glyph — AI mode's
    /// violet alone would not tell the two apart.
    var isEditMode: Bool = false
    /// Draw the transcript, growing from nothing towards `onTranscriptHeight`'s answer — see
    /// `RecordingOverlayPanel`.
    var showsTranscript: Bool = false
    /// The strip is at the top and the transcript grows down from it.
    var growsDown: Bool = false
    /// The transcript's height, 0 until the first word. The view animates towards it.
    var transcriptHeight: CGFloat = 0
    /// What the provider has committed, all segments — drawn at full brightness.
    var settledText: String = ""
    /// The partial it may still take back — drawn dimmer, after the settled text.
    var movingText: String = ""
    /// Where the text went ("Pasted into Slack"), drawn with a tick in place of the
    /// transcript for the second the overlay stays up after a paste.
    var confirmation: String? = nil
    /// The height the transcript would like: its text and padding, 0 before the first word.
    var onTranscriptHeight: (CGFloat) -> Void = { _ in }
    let onCancel: () -> Void

    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.default.rawValue
    @AppStorage(SettingsKeys.accentColor) private var accentHex = AccentColor.neutral
    @AppStorage(SettingsKeys.technoPhosphor) private var technoRaw = TechnoPhosphor.green.rawValue

    @State private var isHoveringCancel = false
    /// The text's own height, for the fade that shows lines have scrolled off the top.
    @State private var textHeight: CGFloat = 0

    private var skin: AppSkin { AppSkin(rawValue: skinRaw) ?? .default }
    private var techno: TechnoPalette { TechnoPalette(stored: technoRaw) }
    private var accent: Color { isAIMode || isEditMode ? Semantic.ai : AccentColor.meter(accentHex) }
    private var isViolet: Bool { isAIMode || isEditMode }
    private var cancelHelp: String {
        isEditMode ? "Cancel (the selected text is left as it was)" : "Cancel (nothing is pasted)"
    }
    private var isBusy: Bool { isLoading || isPreparing }
    /// VoiceOver reads the meter as one element in both skins: the kind of dictation,
    /// then what it is doing — the mode glyph and the bars say nothing on their own.
    private var meterLabel: String {
        isEditMode ? "Edit selection" : isAIMode ? "AI dictation" : "Dictation"
    }
    private var meterState: String {
        isPreparing ? "Starting" : isLoading ? "Working" : "Listening"
    }
    private var hasText: Bool { !settledText.isEmpty || !movingText.isEmpty || confirmation != nil }

    var body: some View {
        // Always laid out at the panel's largest size, with the strip pinned to its corner:
        // the window only reveals as much of it as is drawn, so resizing the window never
        // makes this view lay itself out again — which is what made the strip jump.
        let full = skin.overlayGeometry(showsTranscript: showsTranscript).fullSize
        Group {
            switch skin {
            case .minimal: minimalBody
            case .techno: technoBody
            }
        }
        .animation(Self.growth, value: transcriptHeight)
        .frame(width: full.width, height: full.height,
               alignment: growsDown ? .topTrailing : .bottomTrailing)
        .environment(\.technoPalette, techno)
    }

    /// How the transcript grows and shrinks. `RecordingOverlayPanel.growthDuration` has to
    /// cover it: the window shrinks only once the glass has.
    static let growth = Animation.spring(response: 0.35, dampingFraction: 0.9)

    // MARK: Transcript

    /// The settled text, then the partial, at two brightnesses — the same boundary the
    /// Record Window's glass draws.
    private func transcriptText(base: Color) -> Text {
        if let confirmation {
            return Text(Image(systemName: "checkmark")).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(base)
                + Text(verbatim: "  " + confirmation).foregroundStyle(base.opacity(0.9))
        }
        var text = Text(verbatim: "")
        if !settledText.isEmpty {
            text = text + Text(verbatim: settledText).foregroundStyle(base.opacity(0.9))
        }
        if !movingText.isEmpty {
            let lead = settledText.isEmpty ? "" : " "
            text = text + Text(verbatim: lead + movingText).foregroundStyle(base.opacity(0.45))
        }
        return text
    }

    /// The transcript, pinned to its newest line: the text is laid out at its full height
    /// and the area shows its bottom, so as the panel grows the older lines come into view
    /// above, and once it stops growing they slide off the top under a fade.
    private func transcript(base: Color, font: Font, horizontal: CGFloat,
                            top: CGFloat, bottom: CGFloat) -> some View {
        // Judged against the glass's full height, not the height it has on this frame of
        // its animation: mid-growth the text is always taller than the glass, and taking
        // that for overflow flipped the alignment and flashed the fade on every new line.
        let overflows = textHeight + top + bottom
            > skin.overlayGeometry(showsTranscript: true).maxTranscriptHeight + 1
        // Growing down, the text hangs from the top while it fits, so the glass's lower
        // edge reveals each new line under lines that stay put; pinned to the bottom it
        // travelled down with that edge and the whole block slid on every line. Growing
        // up, the bottom is the edge that stays put. Once it overflows, the newest line
        // is what must stay in view, whichever way it grows.
        let alignment: Alignment = overflows || !growsDown ? .bottom : .top
        return transcriptText(base: base)
            .font(font)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: TranscriptHeightKey.self, value: proxy.size.height)
                }
            }
            .padding(.horizontal, horizontal)
            .padding(.top, top)
            .padding(.bottom, bottom)
            // `minHeight: 0` matters: without it the frame is never smaller than the text,
            // so once there was more text than room it overflowed centred — over the strip
            // below, with the newest line hidden under it.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: alignment)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: overflows ? .clear : .black, location: 0),
                                       .init(color: .black, location: overflows ? 0.3 : 0)],
                               startPoint: .top, endPoint: .bottom)
            }
            .onPreferenceChange(TranscriptHeightKey.self) { height in
                textHeight = height
                onTranscriptHeight(hasText ? (height + top + bottom).rounded(.up) : 0)
            }
            .onChange(of: hasText) {
                onTranscriptHeight(hasText ? (textHeight + top + bottom).rounded(.up) : 0)
            }
    }

    // MARK: Minimal

    /// One piece of glass: the strip is a capsule, and the glass keeps the capsule's
    /// radius as the transcript grows out of it, so the strip's ends stay its corners.
    private var minimalShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: skin.overlayStripSize.height / 2, style: .continuous)
    }

    private var minimalBody: some View {
        VStack(spacing: 0) {
            if growsDown { minimalStrip }
            if showsTranscript {
                // Kept in the hierarchy at zero height too: it is what measures the text.
                transcript(base: .primary, font: .system(size: 13), horizontal: 16,
                           top: growsDown ? 6 : 12, bottom: growsDown ? 12 : 6)
                    .frame(height: transcriptHeight)
            }
            if !growsDown { minimalStrip }
        }
        .background {
            // An edit fills the glass: the outline alone is AI dictation's.
            if isEditMode { Semantic.ai.opacity(0.26) }
        }
        .minimalGlass(in: minimalShape)
        .clipShape(minimalShape)
        .overlay {
            // Only the AI modes get an outline; a plain dictation is meant to be a quiet
            // sliver of glass over whatever the user is working in.
            if isViolet {
                minimalShape.stroke(accent.opacity(isEditMode ? 0.8 : 0.55), lineWidth: 1.5)
            }
        }
    }

    private var minimalStrip: some View {
        HStack(spacing: 10) {
            // What kind of dictation this is, where the language badge used to be: the
            // language rarely changes and had to be read, the AI rewrite changes what gets
            // pasted and has to be noticed.
            Group {
                if isEditMode {
                    EditGlyph(size: 18)
                } else {
                    Image(systemName: isAIMode ? "sparkles" : "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(isViolet ? accent : accent.opacity(0.55))
            .frame(width: 24, height: 24)
            .help(isEditMode ? "Editing the selected text — say how to change it"
                  : isAIMode ? "AI dictation — rewritten before it is pasted" : "Dictation")
            .accessibilityHidden(true)

            WaveformBarsView(
                barLevels: barLevels,
                isLoading: isLoading,
                isPreparing: isPreparing,
                spacing: 6,
                minBarHeight: 4,
                maxBarHeight: 26,
                barColor: accent
            )
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(meterLabel)
            .accessibilityValue(meterState)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary.opacity(isHoveringCancel ? 1.0 : 0.6))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(.primary.opacity(isHoveringCancel ? 0.12 : 0))
                    )
                    .scaleEffect(isHoveringCancel ? 1.1 : 1.0)
            }
            .buttonStyle(.plain)
            .help(cancelHelp)
            .accessibilityLabel("Cancel")
            .pointingHandCursor { isHoveringCancel = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHoveringCancel)
        }
        .padding(.horizontal, 12)
        .frame(height: skin.overlayStripSize.height)
        .background {
            // Once there is text, the strip reads as a bar of its own within the glass.
            Capsule().fill(.primary.opacity(showsTranscript && hasText ? 0.07 : 0))
                .animation(.easeInOut(duration: 0.25), value: hasText)
        }
    }

    // MARK: Techno

    /// 8 rows at the design's 7pt pitch, and enough columns to overrun the glass at
    /// both ends — the design clips the dot mask rather than framing it.
    private static let technoColumns = 16
    private static let technoRows = 8
    private static let glass = RoundedRectangle(cornerRadius: 24, style: .continuous)
    private static let transcriptGlass = RoundedRectangle(cornerRadius: 20, style: .continuous)

    private var technoBody: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if growsDown { technoStrip }
            if showsTranscript {
                // Kept in the hierarchy at zero height too: it is what measures the text.
                let geometry = skin.overlayGeometry(showsTranscript: true)
                technoTranscript
                    .frame(width: geometry.transcriptWidth, height: transcriptHeight)
                    .opacity(transcriptHeight > 0 ? 1 : 0)
                    .padding(growsDown ? .top : .bottom, transcriptHeight > 0 ? geometry.gap : 0)
            }
            if !growsDown { technoStrip }
        }
    }

    /// The transcript on a glass of its own, phosphor on black like the Record Window's.
    private var technoTranscript: some View {
        ZStack {
            Self.transcriptGlass.fill(isEditMode ? TechnoSkin.editScreen : techno.screen)
            transcript(base: isViolet ? TechnoSkin.aiText : techno.phosphorText,
                       font: .system(size: 12, design: .monospaced),
                       horizontal: 16, top: 12, bottom: 12)
            InnerShadow(shape: Self.transcriptGlass, width: 6.6, blur: 3.3)
            InnerShadow(shape: Self.transcriptGlass, width: 4, blur: 2,
                        offset: CGSize(width: 0, height: -1))
        }
        .clipShape(Self.transcriptGlass)
    }

    private var technoStrip: some View {
        HStack(spacing: 6) {
            ZStack {
                Self.glass.fill(isEditMode ? TechnoSkin.editScreen : techno.screen)

                PixelWaveform(
                    levels: barLevels,
                    columns: Self.technoColumns,
                    rows: Self.technoRows,
                    mode: isBusy ? .busy : .level,
                    palette: isViolet ? .ai : .phosphor(techno)
                )

                if isEditMode {
                    // The glyph printed in the glass's corner, where it cannot be taken
                    // for a pixel of the meter.
                    EditGlyph(size: 13)
                        .foregroundStyle(TechnoSkin.aiPeak.opacity(0.85))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.leading, 14)
                        .padding(.top, 10)
                }

                // The design's inset shadow — it seats the glass into the panel edge.
                InnerShadow(shape: Self.glass, width: 6.6, blur: 3.3)
                InnerShadow(shape: Self.glass, width: 4, blur: 2,
                            offset: CGSize(width: 0, height: -1))
            }
            .frame(width: 100, height: 56)
            .clipShape(Self.glass)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(meterLabel)
            .accessibilityValue(meterState)

            // Cancel is a button *of the device*: the same moulded plastic in the same
            // milled recess as the record window's rail, so the two techno surfaces
            // read as one machine. It is never drawn on the glass — the display is for
            // the voice, and a disc floating on it made the screen look clickable.
            ButtonRail {
                PlasticButton(
                    systemImage: "xmark",
                    label: "Cancel",
                    help: cancelHelp,
                    action: onCancel
                )
            }
        }
        .frame(width: skin.overlayStripSize.width, height: skin.overlayStripSize.height)
    }
}

/// A pencil with an AI sparkle over it, as one glyph: the Edit shortcut's mark. The
/// sparkle sits on the side the pencil writes from — at the eraser end it read as a wand.
///
/// Composed rather than taken from SF Symbols: the one symbol that draws this,
/// `apple.writing.tools`, needs macOS 15 (the app runs on 14) and is reserved for Apple's
/// own Writing Tools.
struct EditGlyph: View {
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: "pencil")
            .font(.system(size: size, weight: .semibold))
            .overlay(alignment: .topLeading) {
                Image(systemName: "sparkle")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .offset(x: -size * 0.14, y: -size * 0.22)
            }
            .padding(.leading, size * 0.14)
    }
}

private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Status Overlay

/// A button a notice offers beside its text — "Retry" on "No connection — saved to
/// History". The rest of the notice still opens History when clicked.
struct StatusOverlayAction {
    let title: String
    let perform: () -> Void
}

/// Transient notice shown after a recording ends without usable text — a provider
/// error, or silence. Without this the inline flow fails completely silently.
struct StatusOverlayView: View {
    let icon: String
    let title: String
    let detail: String?
    let tint: Color
    var action: StatusOverlayAction? = nil
    let onTap: () -> Void

    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.default.rawValue
    @AppStorage(SettingsKeys.technoPhosphor) private var technoRaw = TechnoPhosphor.green.rawValue
    @State private var isHovering = false

    private var skin: AppSkin { AppSkin(rawValue: skinRaw) ?? .default }
    private var techno: TechnoPalette { TechnoPalette(stored: technoRaw) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: skin == .techno ? 18 : 16, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: skin == .techno ? .light : .medium))
                .foregroundStyle(tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(titleColor)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(detailColor)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The notice's click opens History; VoiceOver gets it as a button of its own
            // beside the action's, which keeps its title as its name.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(detail.map { "\(title). \($0)" } ?? title)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens History")
            .accessibilityAction { onTap() }

            if let action {
                Button(action.title, action: action.perform)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(skin == .techno ? techno.phosphor : nil)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background {
            if skin == .techno { shape.fill(techno.screen) }
        }
        .minimalGlass(in: shape, isEnabled: skin == .minimal)
        .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
        .clipShape(shape)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .pointingHandCursor { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    private var titleColor: Color {
        skin == .techno ? techno.phosphorText : .primary
    }

    private var detailColor: Color {
        skin == .techno ? techno.phosphorText.opacity(0.6) : .secondary
    }

    private var borderColor: Color {
        skin == .techno
            ? techno.phosphor.opacity(isHovering ? 0.35 : 0.14)
            : .primary.opacity(isHovering ? 0.25 : 0.10)
    }
}

final class StatusOverlayPanel: NSPanel {
    static let panelWidth: CGFloat = 340

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hasShadow = true
    }

    /// Beside the recording overlay — its frame while it is still up, otherwise the strip at
    /// the spot the user left it — never over it: above an overlay in the bottom half of the
    /// screen, below one in the top half (`OverlayPlacement.noticeOrigin`). Called once its
    /// content is in.
    func place(beside overlay: NSRect?) {
        let screens = NSScreen.screens.map(\.visibleFrame)
        let anchor: CGRect
        if let overlay {
            anchor = overlay
        } else {
            let strip = AppSkin.current.overlayStripSize
            let saved = OverlayPlacement.decode(UserDefaults.standard.string(forKey: SettingsKeys.overlayOrigin) ?? "")
            guard let placed = OverlayPlacement.placement(saved: saved, OverlayGeometry(strip: strip),
                                                          screens: screens, main: NSScreen.main?.visibleFrame)
            else { return }
            anchor = CGRect(origin: placed.strip, size: strip)
        }
        let screen = screens.first { $0.intersects(anchor) } ?? NSScreen.main?.visibleFrame ?? anchor
        setFrameOrigin(OverlayPlacement.noticeOrigin(frame.size, beside: anchor, in: screen))
    }
}

// MARK: - Panel

/// What the panel tells the view it hosts: which way the transcript grows, and how tall it
/// is on this frame of its animation.
@Observable
final class OverlayLayout {
    var growsDown = false
    var transcriptHeight: CGFloat = 0
}

/// The inline overlay's window.
///
/// It opens where the user last left it — the bottom-right corner until they move it —
/// and is never anywhere a screen does not show all of it. The user drags it by any part
/// that is not a button; the drag is the panel's own rather than AppKit's, so it is held
/// on screen *while* it moves instead of being corrected after the mouse is let go. The
/// saved spot is also re-checked on every show, skin change and display change, so an
/// unplugged monitor cannot strand it.
///
/// For a streaming recording the transcript grows out of the strip. The hosted view is
/// always the panel's *largest* size, pinned by the strip's corner inside a plain
/// container, and the window only reveals part of it: resizing an `NSHostingView` makes
/// SwiftUI lay out again a frame later, anchored at the top, so a window growing upward
/// showed its strip jumping down and back. Growing, the window takes the new height at
/// once and the glass animates into it (`RecordingOverlayView.growth`); shrinking, the
/// glass animates first and the window follows once it has. The transparent strip that
/// leaves exists only while the glass is moving.
final class RecordingOverlayPanel: NSPanel {
    let layout = OverlayLayout()

    private var geometry: OverlayGeometry
    private var placement: OverlayPlacement.Placement
    private var observers: [NSObjectProtocol] = []
    private let container = NSView()
    private var hosting: NSView?

    /// The transcript height the window is sized for — at least the glass's, while it moves.
    private var windowTranscriptHeight: CGFloat = 0
    /// The window catching up with the glass: a shrink, and the shadow's recomputation.
    private var settleWork: DispatchWorkItem?
    /// Longer than `RecordingOverlayView.growth` takes to come to rest.
    private static let growthDuration: TimeInterval = 0.45

    /// A press that may become a drag: where the mouse and the strip were.
    private var pressStart: (mouse: CGPoint, strip: CGPoint)?
    private var isDragging = false

    init(showsTranscript: Bool = false) {
        geometry = AppSkin.current.overlayGeometry(showsTranscript: showsTranscript)
        placement = OverlayPlacement.Placement(strip: .zero, growth: .up)
        super.init(
            contentRect: NSRect(origin: .zero, size: geometry.strip),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        // Above the level macOS's window tiling manages. Dragged to a screen edge, a
        // floating panel still brought up the tiling preview, even with the window server
        // barred from moving it; the tiling engine leaves high-level windows alone
        // (developer.apple.com/forums/thread/757430). The overlay belongs above
        // everything the user is working in anyway.
        level = .statusBar
        // Not one of the user's windows to arrange: out of tiling, Mission Control and
        // the window cycle, on every Space.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenDisallowsTiling,
                              .stationary, .ignoresCycle]
        // The drag is handled in `sendEvent`, where it can be kept on screen as it happens.
        isMovableByWindowBackground = false
        // Nor may the window server move it: a system drag moved the panel alongside ours.
        isMovable = false
        hasShadow = true
        container.clipsToBounds = true
        contentView = container

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .skinDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.geometry = AppSkin.current.overlayGeometry(showsTranscript: self.geometry.showsTranscript)
                self.placeAtSavedSpot()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeAtSavedSpot() }
        })

        placeAtSavedSpot()
    }

    deinit {
        // A window is let go on main, as AppKit releases every one.
        MainActor.assumeIsolated {
            observers.forEach(NotificationCenter.default.removeObserver)
            settleWork?.cancel()
        }
    }

    /// The overlay's view, hosted at the panel's largest size — see the type's comment.
    func host<Content: View>(_ root: Content) {
        self.hosting?.removeFromSuperview()
        let hosting = NSHostingView(rootView: root)
        // The size is ours to decide; by default the hosting view would push the SwiftUI
        // content's ideal size onto the window.
        hosting.sizingOptions = []
        container.addSubview(hosting)
        self.hosting = hosting
        pinHosting()
    }

    /// The hosted view at full size, its strip corner on the window's — bottom-right when
    /// the transcript grows up, top-right when it grows down.
    private func pinHosting() {
        guard let hosting else { return }
        let full = geometry.fullSize
        let bounds = container.bounds
        let frame = NSRect(x: bounds.width - full.width,
                           y: placement.growth == .down ? bounds.height - full.height : 0,
                           width: full.width, height: full.height)
        if hosting.frame != frame { hosting.frame = frame }
    }

    /// Makes room for the transcript glass in a panel opened without it — the paste's
    /// confirmation is drawn there whatever the engine.
    func showTranscriptArea() {
        guard !geometry.showsTranscript else { return }
        geometry = AppSkin.current.overlayGeometry(showsTranscript: true)
        placeAtSavedSpot()
    }

    /// Fades the panel out, then closes it.
    func fadeOutAndClose() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            animator().alphaValue = 0
        }, completionHandler: {
            // Held until it closes: nothing else keeps it once AppState has let it go. The
            // completion comes on main.
            MainActor.assumeIsolated { self.close() }
        })
    }

    // MARK: Placing

    private func placeAtSavedSpot() {
        let saved = OverlayPlacement.decode(UserDefaults.standard.string(forKey: SettingsKeys.overlayOrigin) ?? "")
        guard let placed = OverlayPlacement.placement(saved: saved, geometry,
                                                      screens: NSScreen.screens.map(\.visibleFrame),
                                                      main: NSScreen.main?.visibleFrame) else { return }
        apply(placed)
    }

    private func apply(_ placed: OverlayPlacement.Placement) {
        placement = placed
        if layout.growsDown != (placed.growth == .down) { layout.growsDown = placed.growth == .down }
        layoutFrame()
    }

    /// The window around the strip, sized for `windowTranscriptHeight`.
    private func layoutFrame() {
        let frame = OverlayPlacement.frame(strip: placement.strip, geometry, growth: placement.growth,
                                           transcriptHeight: windowTranscriptHeight)
        if frame != self.frame { setFrame(frame, display: false) }
        pinHosting()
    }

    // MARK: Growing the transcript

    /// How tall the transcript would like to be — its text and padding, 0 before the first
    /// word. Capped at the geometry's maximum, beyond which older lines scroll off the top.
    func setTranscriptHeight(_ wanted: CGFloat) {
        let target = min(max(wanted, 0), geometry.maxTranscriptHeight)
        guard target != layout.transcriptHeight else { return }
        layout.transcriptHeight = target

        settleWork?.cancel()
        if target > windowTranscriptHeight {
            // Room first, so the glass has somewhere to grow into.
            windowTranscriptHeight = target
            layoutFrame()
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.windowTranscriptHeight = self.layout.transcriptHeight
            self.layoutFrame()
            // Recomputed once the glass is at rest: a shadow rebuilt while it moves stutters.
            self.invalidateShadow()
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.growthDuration, execute: work)
    }

    // MARK: Dragging

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressStart = (NSEvent.mouseLocation, placement.strip)
            isDragging = false
            super.sendEvent(event)

        case .leftMouseDragged:
            guard let start = pressStart else { return super.sendEvent(event) }
            let mouse = NSEvent.mouseLocation
            let delta = CGPoint(x: mouse.x - start.mouse.x, y: mouse.y - start.mouse.y)
            if !isDragging {
                // A few points of slack, so a click on ✕ with a trembling hand is a click.
                guard hypot(delta.x, delta.y) >= 3 else { return super.sendEvent(event) }
                isDragging = true
            }
            let proposed = CGPoint(x: start.strip.x + delta.x, y: start.strip.y + delta.y)
            // The screen under the pointer, so the overlay can be carried to another display.
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? self.screen ?? NSScreen.main
            guard let screen else { return }
            apply(OverlayPlacement.settled(strip: proposed, geometry, in: screen.visibleFrame))

        case .leftMouseUp:
            defer { pressStart = nil; isDragging = false }
            guard isDragging else { return super.sendEvent(event) }
            UserDefaults.standard.set(OverlayPlacement.encode(placement.strip), forKey: SettingsKeys.overlayOrigin)
            // A button that took the mouse-down is released away from itself, so it lets go
            // without firing — the window moved with the pointer, which is still over it.
            // The bottom-left corner: inside the window, where no skin puts a button.
            if let release = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 1, y: 1),
                                                modifierFlags: [], timestamp: event.timestamp,
                                                windowNumber: windowNumber, context: nil,
                                                eventNumber: event.eventNumber, clickCount: 1, pressure: 0) {
                super.sendEvent(release)
            }

        default:
            super.sendEvent(event)
        }
    }
}

// MARK: - Hold tip

/// The hold tip: beside the overlay while a hold recording's shortcut is held,
/// teaching that the letter alone keeps it going — ⌃⇧ may be let go, which gives back
/// ordinary clicks and ⌘Tab. Its keycaps are live, so the modifiers fade the moment the
/// letter is down and the title changes once they are let go.
struct HoldTipView: View {
    let action: ShortcutAction
    let stage: HoldTip.Stage
    /// The other dictation shortcut, for the switch hint.
    let other: ShortcutAction?
    let followed: Bool

    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.default.rawValue
    private var skin: AppSkin { AppSkin(rawValue: skinRaw) ?? .default }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: skin == .techno ? 18 : 16, style: .continuous)
    }

    private var keys: [String] { shortcutKeys(shortcutText(for: action)) }
    private var letter: String { keys.last ?? "" }
    private var modifiers: String { keys.filter(isModifierCap).joined() }

    var body: some View {
        HStack(spacing: 12) {
            switch stage {
            case .switchHint:
                if let other {
                    SetupKeycaps(keys: shortcutKeys(shortcutText(for: other)), size: 20, ai: other == .ai)
                }
            case .keepHolding, .none:
                LiveShortcutKeycaps(action: action, size: 20, ai: action == .ai)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(skin == .techno ? TechnoSkin.phosphorText : .primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(skin == .techno ? TechnoSkin.phosphorText.opacity(0.6) : .secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background {
            if skin == .techno { shape.fill(TechnoSkin.screen) }
        }
        .minimalGlass(in: shape, isEnabled: skin == .minimal)
        .overlay(shape.strokeBorder(skin == .techno ? TechnoSkin.phosphor.opacity(0.14) : .primary.opacity(0.10), lineWidth: 1))
        .clipShape(shape)
        .animation(.easeOut(duration: 0.2), value: followed)
    }

    private var text: (title: String, detail: String) {
        HoldTip.text(stage: stage, followed: followed, isEdit: action == .edit, letter: letter,
                     modifiers: modifiers, other: other.map { shortcutText(for: $0) } ?? "",
                     otherIsAI: other == .ai)
    }
    private var title: String { text.title }
    private var detail: String { text.detail }
}

/// The hold tip's window: beside the recording overlay, following it as the transcript
/// grows. It takes no clicks — it is read, not used.
final class HoldTipPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: StatusOverlayPanel.panelWidth, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        hasShadow = true
    }

    /// Beside the overlay, as a notice is (`OverlayPlacement.noticeOrigin`).
    func place(beside overlay: NSRect) {
        let visible = NSScreen.screens.first { $0.frame.intersects(overlay) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? overlay
        setFrameOrigin(OverlayPlacement.noticeOrigin(frame.size, beside: overlay, in: visible))
    }
}
