// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import SpeechTextCore

// MARK: - Glass

extension View {
    /// The minimal skin's surface behind this view, clipped to `shape`: Liquid Glass on
    /// macOS 26 and later, the material before it, either at the stop of Settings ›
    /// Appearance › Transparency (`GlassTransparency`). The one place that asks which
    /// macOS this is, so a surface cannot be glass in one place and material in another.
    /// `isEnabled` false leaves the view as it is: a surface that has a techno look too.
    func minimalGlass(in shape: some Shape, isEnabled: Bool = true) -> some View {
        modifier(MinimalGlass(shape: shape, isEnabled: isEnabled))
    }
}

private struct MinimalGlass<S: Shape>: ViewModifier {
    let shape: S
    let isEnabled: Bool

    @AppStorage(SettingsKeys.glassTransparency) private var transparencyRaw = GlassTransparency.default.rawValue
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var transparency: GlassTransparency { GlassTransparency(stored: transparencyRaw) }

    /// A background, not `glassEffect` on the content: like `.background(.ultraThinMaterial)`
    /// before it, it reaches under a titled window's title bar, where the content does not.
    func body(content: Content) -> some View {
        if isEnabled {
            content.background { surface.ignoresSafeArea() }
        } else {
            content
        }
    }

    @ViewBuilder
    private var surface: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(glass, in: shape)
        } else {
            let fill = transparency.material(reduceTransparency: reduceTransparency)
            ZStack {
                shape.fill(.ultraThinMaterial.opacity(fill.materialOpacity))
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(fill.backgroundOpacity))
            }
        }
    }

    /// The tint is a SwiftUI colour from the window's background, which follows light and
    /// dark by itself — `NSGlassEffectView.tintColor` resolved such a colour once and kept
    /// the light one in dark mode (measured).
    @available(macOS 26, *)
    private var glass: Glass {
        switch transparency.glass(reduceTransparency: reduceTransparency) {
        case .regular:
            return .regular
        case .clear(let tint):
            return tint > 0 ? .clear.tint(Color(nsColor: .windowBackgroundColor).opacity(tint)) : .clear
        }
    }
}

// MARK: - Waveform

/// The minimal skin's level meter: a row of bars that rise with the microphone.
///
/// It carries three animations the user actually reads as status — bars appearing one
/// by one while the audio engine warms up, snapping to full brightness when it is
/// ready, and a dot chasing along the row while a provider is working.
struct WaveformBarsView: View {
    let barLevels: [CGFloat]
    let isLoading: Bool
    var isPreparing: Bool = false
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3
    var minBarHeight: CGFloat = 6
    var maxBarHeight: CGFloat = 42
    var barColor: Color = .white

    @State private var activeDot: Int = 0
    /// How many bars have been revealed during the preparing phase.
    @State private var revealedCount: Int = 0
    /// Flips to true when the engine is ready and bars snap to full brightness.
    @State private var barsBright: Bool = false

    /// True while bars are in the dim one-by-one reveal or the snap-to-bright transition.
    private var inPreparingDisplay: Bool {
        isPreparing || (revealedCount > 0 && !barsBright)
    }

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<barLevels.count, id: \.self) { i in
                let dimmed = inPreparingDisplay
                let visible = !dimmed || i < revealedCount

                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor.opacity(barOpacity(index: i, visible: visible, dimmed: dimmed)))
                    .frame(width: barWidth, height: dimmed ? minBarHeight : barFrameHeight(barLevels[i]))
                    .animation(.easeInOut(duration: 0.35), value: isLoading)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: revealedCount)
                    .animation(.easeOut(duration: 0.25), value: barsBright)
                    .animation(.interpolatingSpring(stiffness: 300, damping: 18), value: barLevels[i])
            }
        }
        // Preparing animation: reveal bars one by one (dim), then brighten when ready.
        .task(id: isPreparing) {
            if isPreparing {
                revealedCount = 0
                barsBright = false
                for _ in 0..<barLevels.count {
                    try? await Task.sleep(for: .milliseconds(85))
                    if Task.isCancelled { break }
                    withAnimation {
                        revealedCount += 1
                    }
                }
            } else if revealedCount > 0 {
                // Snap any remaining bars in (still dim), then brighten all at once.
                withAnimation(.easeOut(duration: 0.06)) {
                    revealedCount = barLevels.count
                }
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    barsBright = true
                }
                // Wait for the brighten to finish, then reset so the normal waveform
                // takes over cleanly (inPreparingDisplay becomes false).
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                revealedCount = 0
                barsBright = false
            }
        }
        // Transcribing animation: dot-chase across the bars.
        .task(id: isLoading) {
            guard isLoading else { return }
            activeDot = 0
            let count = barLevels.count
            guard count > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.15)) {
                    activeDot = (activeDot + 1) % count
                }
            }
        }
    }

    private func barOpacity(index: Int, visible: Bool, dimmed: Bool) -> Double {
        if isLoading { return loadingOpacity(for: index) }
        if dimmed { return visible ? 0.38 : 0.0 }
        return 0.85
    }

    private func barFrameHeight(_ level: CGFloat) -> CGFloat {
        isLoading ? minBarHeight : (minBarHeight + level * (maxBarHeight - minBarHeight))
    }

    private func loadingOpacity(for index: Int) -> Double {
        let count = barLevels.count
        guard count > 0 else { return 0.15 }
        let distance = min(
            abs(index - activeDot),
            count - abs(index - activeDot)
        )
        switch distance {
        case 0: return 1.0
        case 1: return 0.6
        case 2: return 0.35
        default: return 0.15
        }
    }
}

// MARK: - Toolbar button

/// A square icon button of the kind the minimal skin lines up above the text area.
struct MinimalIconButton: View {
    let systemImage: String
    /// What VoiceOver calls the button, and the state it reads after the name — see
    /// `PlasticButton`.
    let label: String
    var value = ""
    var isOn = false
    var accent: Color = .accentColor
    var isEnabled = true
    var help: String = ""
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? AnyShapeStyle(accent) : AnyShapeStyle(.ultraThinMaterial))
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                )
                .scaleEffect(isHovering && isEnabled ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .pointingHandCursor(enabled: isEnabled) { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.easeInOut(duration: 0.2), value: isOn)
    }

    private var foreground: Color {
        guard isEnabled else { return .secondary.opacity(0.4) }
        return isOn ? .white : .secondary
    }
}

// MARK: - Text editor

/// The minimal skin's text area: a plain `NSTextView` in the system label colour.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    let insertionHandler: TextInsertionHandler
    /// Closes the panel when the text view swallows Escape.
    var onCancel: () -> Void = {}

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        var isUpdating = false

        init(_ parent: PlainTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.onCancel()
            return true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 14)
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.textColor = .labelColor
        textView.setAccessibilityLabel("Transcript")
        insertionHandler.textView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        context.coordinator.parent = self
        if textView.string != text {
            context.coordinator.isUpdating = true
            let range = textView.selectedRange()
            // See `LCDTextEditor.updateNSView`.
            textView.undoManager?.removeAllActions()
            textView.string = text
            let safeLoc = min(range.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: safeLoc, length: 0))
            context.coordinator.isUpdating = false
        }
    }
}
