// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

// MARK: - The setup window

/// The first-run window: 760 × 540, not resizable, no title bar. It draws its own frame —
/// a glass rim with a slow green glow under it, and an inset card holding the step — so it
/// is borderless, and its traffic lights are part of the drawing.
@MainActor
final class OnboardingWindow: NSWindow {
    static let size = NSSize(width: 760, height: 540)

    let model: OnboardingModel
    private let onClose: () -> Void
    private let onFinish: () -> Void
    private var hasBeenShown = false

    init(appState: AppState, onClose: @escaping () -> Void, onFinish: @escaping () -> Void) {
        model = OnboardingModel(appState: appState)
        self.onClose = onClose
        self.onFinish = onFinish
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .miniaturizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        title = "SpeechText Setup"
        let host = NSHostingView(rootView: OnboardingView(model: model, window: SetupWindowRef(self)))
        host.frame = NSRect(origin: .zero, size: Self.size)
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func present() {
        if !hasBeenShown {
            center()
            hasBeenShown = true
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        // A clear window's shadow follows what is drawn, which exists only after a pass.
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }

    override func close() {
        model.tearDown()
        super.close()
        onClose()
    }

    /// Done's Start using SpeechText: setup closes and the main window opens.
    func finishAndOpenApp() {
        model.finish()
        close()
        onFinish()
    }

    /// ⌘W and ⌘M, which a borderless window does not get from a title bar.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let key = event.charactersIgnoringModifiers {
            if key == "w" { close(); return true }
            if key == "m" { miniaturize(nil); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - The Accessibility helper

/// Floats beside System Settings while the user looks for SpeechText's switch in
/// Privacy & Security › Accessibility — the one grant with no dialog of its own, and the
/// hardest moment of setup for someone who has never been in that pane.
@MainActor
final class AccessibilityHelperPanel: NSPanel {
    static let size = NSSize(width: 260, height: 190)
    private var placementAttempts = 0

    init(onDone: @escaping () -> Void) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: AccessibilityHelperView(pointsRight: true, onDone: onDone))
    }

    /// System Settings opens a moment after it is asked to, so its window is looked for a
    /// few times before the helper settles for a corner of the screen.
    func showBesideSystemSettings() {
        placementAttempts = 0
        place()
        orderFrontRegardless()
    }

    private func place() {
        placementAttempts += 1
        if let settings = Self.systemSettingsFrame() {
            let left = settings.minX - Self.size.width - 18
            let top = settings.maxY - 137 + 33
            let pointsRight = left >= (screen?.visibleFrame.minX ?? 0) + 8
            let origin = pointsRight
                ? NSPoint(x: left, y: top - Self.size.height)
                : NSPoint(x: settings.maxX - Self.size.width - 16, y: settings.minY + 16)
            setFrameOrigin(origin)
            (contentView as? NSHostingView<AccessibilityHelperView>)?.rootView.pointsRight = pointsRight
            return
        }
        if let visible = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.maxX - Self.size.width - 24, y: visible.minY + 24))
        }
        if placementAttempts < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.isVisible else { return }
                self.place()
            }
        }
    }

    /// System Settings' frontmost window, in Cocoa coordinates. Window bounds and owners
    /// are readable without screen-recording access; only titles are not.
    private static func systemSettingsFrame() -> NSRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
                  w > 300, h > 200 else { continue }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return NSRect(x: x, y: primaryHeight - y - h, width: w, height: h)
        }
        return nil
    }
}

struct AccessibilityHelperView: View {
    var pointsRight: Bool
    let onDone: () -> Void
    @State private var nudge = false
    @State private var switchOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Turn on SpeechText").font(.system(size: 13, weight: .semibold))
                if pointsRight {
                    Text("→")
                        .foregroundStyle(Color(hex: 0x0A84FF))
                        .offset(x: nudge ? 3 : 0)
                }
            }
            Text("Find **SpeechText** in the list and click its switch. You may need to enter your Mac password.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 18, height: 18)
                Text("SpeechText").font(.system(size: 12))
                Spacer()
                Capsule()
                    .fill(switchOn ? Color(hex: 0x0A84FF) : Color.primary.opacity(0.15))
                    .frame(width: 32, height: 19)
                    .overlay(alignment: switchOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 15, height: 15).padding(2)
                            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .controlSize(.small)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: AccessibilityHelperPanel.size.width - 16, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
        .frame(width: AccessibilityHelperPanel.size.width, height: AccessibilityHelperPanel.size.height)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) { nudge = true }
            withAnimation(.easeInOut(duration: 0.4).delay(0.9).repeatForever(autoreverses: true)) { switchOn = true }
        }
    }
}
