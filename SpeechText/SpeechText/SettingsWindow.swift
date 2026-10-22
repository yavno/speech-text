// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import SpeechTextCore

// MARK: - The Settings window

/// The Settings window: the setup window's frame — a glass rim with the green glow under
/// it — around a white card that holds a category sidebar and the page it picks. Like the
/// setup window it draws its own frame, so it is borderless and its traffic lights are
/// part of the drawing.
///
/// It is a window of our own rather than SwiftUI's `Settings` scene, because that scene
/// always wears a system title bar. `SpeechTextApp` keeps an empty `Settings` scene and
/// points the app menu's Settings… (⌘,) here instead.
@MainActor
final class SettingsWindow: NSWindow {
    static let size = NSSize(width: 820, height: 600)

    private let onClose: () -> Void

    init(category: SettingsCategory = .general, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .miniaturizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        title = "SpeechText Settings"
        let host = NSHostingView(rootView: SettingsView(window: SetupWindowRef(self), category: category))
        host.frame = NSRect(origin: .zero, size: Self.size)
        contentView = host
        center()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        // A clear window's shadow follows what is drawn, which exists only after a pass.
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }

    override func close() {
        super.close()
        onClose()
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

extension Notification.Name {
    /// Posted with a `SettingsCategory` to turn an open Settings window to that page.
    static let settingsShowCategory = Notification.Name("SettingsShowCategory")
    /// Posted when `SettingsAnchor.pending` names a group to scroll to.
    static let settingsScrollToAnchor = Notification.Name("SettingsScrollToAnchor")
}

/// A group further down a Settings page that another window links straight to, so the
/// setting it talks about is on screen when Settings opens — not below the fold.
enum SettingsAnchor: String {
    /// Privacy & Data › History, from the History page.
    case history
    /// Dictation › Microphone, from a dictation in which nothing was heard.
    case microphone

    var category: SettingsCategory {
        switch self {
        case .history: .privacy
        case .microphone: .dictation
        }
    }

    /// The group the next Settings page to appear scrolls to: a window built ahead, or one
    /// already open, takes it from the notification, and a new one when it appears.
    @MainActor static var pending: SettingsAnchor?
}

// MARK: - Categories

/// The sidebar's entries, in the order the sidebar lists them.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, dictation, speech, ai, privacy, apiKeys

    var id: String { rawValue }

    /// Three runs in the sidebar: the app itself; a dictation — how you give it, what
    /// turns it into text, what rewrites it; and what is kept, sent and allowed.
    static let groups: [[SettingsCategory]] = [
        [.general, .appearance],
        [.dictation, .speech, .ai],
        [.privacy, .apiKeys],
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .dictation: "Dictation"
        case .speech: "Speech to text"
        // What the step does rather than what runs it: "AI" alone named the technology.
        case .ai: "AI Rewrite"
        case .privacy: "Privacy & Data"
        case .apiKeys: "API Keys"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .dictation: "mic"
        case .speech: "waveform"
        case .ai: "sparkles"
        case .privacy: "hand.raised"
        case .apiKeys: "key"
        }
    }

    /// The line under the page's title.
    var lead: String {
        switch self {
        case .general: "How SpeechText starts, and how it stays up to date."
        case .appearance: "How the recording overlay and the Record Window look."
        case .dictation: "How you dictate: the shortcuts, the microphone, your languages and how the text is written."
        case .speech: "What turns your voice into text — on this Mac or online."
        case .ai: "Optional. Turns a dictation into finished text — an email, a list, a translation — or does what you ask (“a short reply, in English”)."
        case .privacy: "What is kept on this Mac, what is sent, and what macOS allows."
        case .apiKeys: "Every key SpeechText holds. The ones your choices use come first."
        }
    }
}

// MARK: - Colours

enum SettingsColor {
    /// The card: white, as asked; the setup card's own dark grey in Dark Mode, where a
    /// white card would glare.
    static let background = Color.setup(0xFFFFFF, dark: 0x2A2A2C)
    /// The grey of a group, the selected sidebar entry and the glyph wells: the main
    /// window's (`MainColor.panel`, under Home's Last 7 days), so Settings and the pages
    /// read as one design — not the setup window's cooler grey, which sits on its own card.
    static let panel = MainColor.panel
    static let panelBorder = MainColor.panelBorder
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @Binding var selection: SettingsCategory
    let window: SetupWindowRef

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupTrafficLights(onClose: { window.window?.close() },
                               onMinimize: { window.window?.miniaturize(nil) })
                .padding(.leading, 6)
                .padding(.top, 6)
                .padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(SettingsCategory.groups.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(SettingsCategory.groups[index]) { category in
                            SettingsSidebarItem(category: category, isSelected: selection == category) {
                                selection = category
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
    }
}

private struct SettingsSidebarItem: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    /// The AI entry lights violet, as the setup window's AI step does.
    private var tint: SetupTint { category == .ai ? .violet : .green }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                          ? AnyShapeStyle(LinearGradient(colors: tint.glyph, startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(SettingsColor.panel))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isSelected ? .clear : SettingsColor.panelBorder, lineWidth: 0.5))
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: category.symbol)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(isSelected ? tint.glyphInk : SetupColor.label2)
                    }
                Text(category.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? SetupColor.label : SetupColor.label2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? SettingsColor.panel : hovering ? SettingsColor.panel.opacity(0.6) : .clear)
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? SettingsColor.panelBorder : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Page parts

/// A run of related settings on a grey panel, the way the setup window groups its rows.
/// `inset` is smaller for a radio list, whose `SetupRow`s carry their own padding.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    var inset: CGFloat = 14
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SetupColor.label2)
                    }
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, inset)
                .padding(.vertical, inset < 14 ? inset : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                // No outline, as the main window's grey surfaces have none.
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SettingsColor.panel))
        }
    }
}

/// One setting: its name and what it does on the left, the control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SetupColor.label)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SetupColor.label2)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 11)
    }
}

extension SettingsRow where Control == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail, control: { EmptyView() })
    }
}

/// A choice along a scale — how long History keeps things — drawn as a track with a stop
/// per value, its name above it, as a cache-size slider is. Dragging moves the knob from
/// stop to stop; the choice is made when it is let go (or a stop or its name is clicked),
/// so a choice that has to ask first asks once.
struct SettingsStepSlider<Value: Hashable>: View {
    let values: [Value]
    let selection: Value
    let title: (Value) -> String
    /// What VoiceOver calls the slider; its value is the stop's name.
    let label: String
    let onChoose: (Value) -> Void

    /// Where the knob is while it is being dragged.
    @State private var dragIndex: Int?
    @Environment(\.setupTint) private var tint

    private let knobWidth: CGFloat = 30
    private let knobHeight: CGFloat = 20
    private let trackHeight: CGFloat = 6

    private var selectedIndex: Int { values.firstIndex(of: selection) ?? 0 }
    private var shownIndex: Int { dragIndex ?? selectedIndex }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            VStack(spacing: 8) {
                labels(width: width)
                track(width: width)
            }
            // The window moves by its background, and a SwiftUI drag never wins against
            // that: the press is taken by a view that tells AppKit it is not background.
            .overlay(StepSliderTracking(
                changed: { x in
                    let index = nearest(x, width: width)
                    if index != dragIndex {
                        withAnimation(.easeOut(duration: 0.12)) { dragIndex = index }
                    }
                },
                ended: { x in
                    dragIndex = nil
                    choose(nearest(x, width: width))
                }))
        }
        .frame(height: 15 + 8 + knobHeight + 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(title(values[shownIndex]))
        // An adjustment is a release on the next stop: through `choose`, so a shorter
        // History retention still asks before it deletes.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: choose(min(selectedIndex + 1, values.count - 1))
            case .decrement: choose(max(selectedIndex - 1, 0))
            @unknown default: break
            }
        }
    }

    /// The x of stop `index`'s centre: the ends sit under the knob's ends, not off them.
    private func x(_ index: Int, width: CGFloat) -> CGFloat {
        guard values.count > 1 else { return width / 2 }
        let usable = width - knobWidth
        return knobWidth / 2 + usable * CGFloat(index) / CGFloat(values.count - 1)
    }

    private func nearest(_ location: CGFloat, width: CGFloat) -> Int {
        guard values.count > 1 else { return 0 }
        let fraction = (location - knobWidth / 2) / max(width - knobWidth, 1)
        return min(max(Int((fraction * CGFloat(values.count - 1)).rounded()), 0), values.count - 1)
    }

    private func labels(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(values.indices, id: \.self) { index in
                let isShown = index == shownIndex
                let position = x(index, width: width)
                let last = values.count - 1
                let knob = knobWidth
                Text(title(values[index]))
                    .font(.system(size: 11.5, weight: isShown ? .semibold : .regular))
                    .foregroundStyle(isShown ? SetupColor.label : SetupColor.label2)
                    .fixedSize()
                    .alignmentGuide(.leading) { d in
                        // The first and last names are held inside the track's ends.
                        if index == 0 { return -max(position - knob / 2, 0) }
                        if index == last { return d.width - width }
                        return d.width / 2 - position
                    }
            }
        }
        .frame(width: width, height: 15, alignment: .topLeading)
    }

    private func track(width: CGFloat) -> some View {
        let knobX = x(shownIndex, width: width)
        return ZStack(alignment: .leading) {
            Capsule().fill(SetupColor.separator)
                .frame(height: trackHeight)
            Capsule().fill(tint.primary)
                .frame(width: knobX, height: trackHeight)
            ForEach(values.indices, id: \.self) { index in
                Circle()
                    .fill(index <= shownIndex ? Color.white.opacity(0.75) : SetupColor.label3)
                    .frame(width: 3, height: 3)
                    .position(x: x(index, width: width), y: knobHeight / 2)
            }
            Capsule()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                .frame(width: knobWidth, height: knobHeight)
                .position(x: knobX, y: knobHeight / 2)
        }
        .frame(width: width, height: knobHeight)
        .animation(.easeOut(duration: 0.15), value: selectedIndex)
    }

    private func choose(_ index: Int) {
        guard values.indices.contains(index), values[index] != selection else { return }
        onChoose(values[index])
    }
}

/// `SettingsStepSlider`'s mouse: a press, a drag and a release, reported as x in the
/// slider's own space, on a view that never lets the press move the window.
private struct StepSliderTracking: NSViewRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.changed = changed
        view.ended = ended
    }

    final class TrackingView: NSView {
        var changed: (CGFloat) -> Void = { _ in }
        var ended: (CGFloat) -> Void = { _ in }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func x(_ event: NSEvent) -> CGFloat { convert(event.locationInWindow, from: nil).x }

        override func mouseDown(with event: NSEvent) { changed(x(event)) }
        override func mouseDragged(with event: NSEvent) { changed(x(event)) }
        override func mouseUp(with event: NSEvent) { ended(x(event)) }
    }
}

/// A hairline between two rows of a group.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(SetupColor.separator).frame(height: 1)
    }
}

/// An explanation that belongs to the row above it but is too long to sit beside a control.
struct SettingsNote: View {
    let text: String
    var tone: Color = SetupColor.label2

    init(_ text: String, tone: Color = SetupColor.label2) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(tone)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The switch the setup window uses: macOS' own, in the page's colour.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
    }
}

/// "Ready" / "Needs an API key" beside a group's title.
struct SettingsStatus: View {
    let text: String
    let ok: Bool

    var body: some View {
        Text(ok ? "✓ \(text)" : "⚠︎ \(text)")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(ok ? SetupColor.ok : SetupColor.warn)
    }
}

/// What a key can be used for, named after the settings page that makes the choice.
enum SettingsKeyRole: CaseIterable {
    case speech, aiRewrite

    var category: SettingsCategory {
        switch self {
        case .speech: .speech
        case .aiRewrite: .ai
        }
    }

    var tint: SetupTint {
        switch self {
        case .speech: .green
        case .aiRewrite: .violet
        }
    }
}

/// One of a key's roles: tinted when the current choices use the key for it, grey when
/// the key could serve it but nothing selected does.
struct SettingsKeyRoleTag: View {
    let role: SettingsKeyRole
    let active: Bool

    var body: some View {
        let accent = role.tint.accent
        HStack(spacing: 3) {
            Image(systemName: role.category.symbol).font(.system(size: 9, weight: .semibold))
            Text(role.category.title).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(active ? accent : SetupColor.label2)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(active ? accent.opacity(0.12) : .clear))
        .overlay(Capsule().strokeBorder(active ? .clear : SettingsColor.panelBorder, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(active ? "Used for \(role.category.title)" : "Can be used for \(role.category.title)")
    }
}

/// An API key: which account it belongs to, where to get one, and the key itself — shown by
/// its ends once stored (`APIKeyDisplay`), so the user can tell which key it is, with
/// Change and Remove; a field while there is none or it is being changed. `showsHeader` is
/// off where the key sits under its service's own row (Speech to text, AI Rewrite).
struct SettingsKeyField: View {
    let service: Provider
    @Binding var value: String
    var showsHeader = true
    /// Everything the key can be used for, in pipeline order.
    var roles: [SettingsKeyRole] = []
    /// The roles the current choices use it for.
    var activeRoles: Set<SettingsKeyRole> = []
    var uses: String?
    /// The current choices use this key: its row says whether it is filled in.
    var inUse = false
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmingRemove = false
    @FocusState private var focused: Bool
    @Environment(\.setupTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsHeader { header }
            if hasValue && !editing { stored } else { field }
            if let uses {
                SettingsNote(uses)
            }
        }
        .padding(.vertical, showsHeader ? 12 : 0)
        .confirmationDialog("Remove your \(service.displayName) key?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { value = "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(inUse ? "What uses it stops working until you add a key again." : "You can add it again at any time.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(service.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(inUse ? SetupColor.label : SetupColor.label2)
            ForEach(roles, id: \.self) { role in
                SettingsKeyRoleTag(role: role, active: activeRoles.contains(role))
            }
            if inUse {
                SettingsStatus(text: hasValue ? "Added" : "Needed", ok: hasValue)
            }
            Spacer(minLength: 0)
            getKeyLink
        }
    }

    private var getKeyLink: some View {
        Button(service.linkTitle) {
            if let page = service.descriptor.apiKey?.keysPage { NSWorkspace.shared.open(page) }
        }
        .buttonStyle(SetupInlineLinkStyle())
        .pointingHandCursor()
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 9) }

    /// The stored key, by its ends.
    private var stored: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 10))
                .foregroundStyle(SetupColor.label3)
            Text(APIKeyDisplay.masked(value, prefix: service.descriptor.apiKey?.prefix))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(SetupColor.label)
                .textSelection(.disabled)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Change") {
                draft = ""
                editing = true
                focused = true
            }
            .buttonStyle(SetupInlineLinkStyle())
            Button("Remove") { confirmingRemove = true }
                .buttonStyle(SetupInlineLinkStyle())
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(shape.fill(SetupColor.control))
        .overlay(shape.strokeBorder(SettingsColor.panelBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(service.displayName) key, ending \(String(value.suffix(4)))")
    }

    /// Typing or pasting a key. A new key replaces the stored one only once it is entered;
    /// leaving the field empty keeps the old one.
    private var field: some View {
        HStack(spacing: 6) {
            TextField("", text: $draft, prompt: Text("Paste your key here").foregroundStyle(SetupColor.label3))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused)
                // Only Return or Paste takes it: a key half typed when the user clicks
                // away must not replace one that works.
                .onSubmit(commit)
                .accessibilityLabel("\(service.displayName) key")
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(shape.fill(SetupColor.control))
                .overlay(shape.strokeBorder(focused ? tint.accent : SettingsColor.panelBorder, lineWidth: focused ? 1.5 : 1))
                .background(shape.fill(tint.glow.opacity(focused ? 0.25 : 0)).padding(-3))
            Button("Paste") {
                if let text = NSPasteboard.general.string(forType: .string) {
                    draft = text
                    commit()
                }
            }
            .buttonStyle(SetupButtonStyle(kind: .secondary, height: 30))
            .font(.system(size: 12))
            if editing {
                Button("Cancel") { editing = false; draft = "" }
                    .buttonStyle(SetupInlineLinkStyle())
            } else if !showsHeader {
                getKeyLink
            }
        }
    }

    private func commit() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        value = key
        draft = ""
        editing = false
    }

    private var hasValue: Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A permission, drawn like the setup window's: an icon that turns green once granted.
struct SettingsPermissionRow<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 11)
                .fill(granted
                      ? AnyShapeStyle(LinearGradient(colors: SetupTint.green.glyph, startPoint: .topLeading, endPoint: .bottomTrailing))
                      : AnyShapeStyle(SetupColor.control))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(granted ? .clear : SettingsColor.panelBorder, lineWidth: 1))
                .overlay(Image(systemName: symbol).font(.system(size: 16))
                    .foregroundStyle(granted ? SetupColor.phosphor : SetupColor.label2))
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(SetupColor.label)
                Text(detail).font(.system(size: 12)).foregroundStyle(SetupColor.label2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if granted {
                Text("✓ Allowed").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(SetupColor.ok).fixedSize()
            } else {
                control
            }
        }
        .padding(.vertical, 14)
        .animation(.easeInOut(duration: 0.3), value: granted)
    }
}

// MARK: - Skin previews

/// A radio row with a picture on its right — `SetupRow`'s look, for a choice that is
/// easier seen than described.
struct SettingsPreviewRow<Preview: View>: View {
    let title: String
    var detail: String?
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let preview: Preview
    @Environment(\.setupTint) private var tint
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                if isSelected {
                    Circle().fill(tint.accent)
                    Circle().fill(tint.card).frame(width: 6, height: 6)
                } else {
                    Circle().strokeBorder(SetupColor.label3, lineWidth: 1.5)
                }
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(SetupColor.label)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(SetupColor.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            preview
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? tint.accent.opacity(0.6) : SettingsColor.panelBorder, lineWidth: 1)
                }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? SetupColor.control : hovering ? SetupColor.control.opacity(0.6) : .clear)
                .shadow(color: .black.opacity(isSelected ? 0.05 : 0), radius: 1, y: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? SettingsColor.panelBorder : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The inline recording overlay in a skin, in miniature, over a patch of desktop — the
/// surface the skin is mostly seen on. Built from the overlay's own parts at their real
/// size and scaled down, so the picture cannot drift from the thing it shows.
struct SkinPreview: View {
    let skin: AppSkin
    /// The accent picked in the Colour row, so the picture follows it; a skin that keeps
    /// its own colours ignores it, as the overlay does.
    var accentHex = AccentColor.neutral
    /// The display colour picked for techno, which only the techno picture follows.
    var technoRaw = TechnoPhosphor.green.rawValue

    private var palette: TechnoPalette { TechnoPalette(stored: technoRaw) }

    private var accent: Color {
        AccentColor.meter(skin.supportsAccent ? accentHex : AccentColor.neutral)
    }

    static let size = CGSize(width: 168, height: 64)

    /// Each skin as large as the patch allows, up to three quarters: at one shared scale
    /// the techno strip, less than half the minimal one's width, came out a speck.
    private var scale: CGFloat {
        let strip = skin.overlayStripSize
        return min((Self.size.width - 24) / strip.width, (Self.size.height - 16) / strip.height, 0.75)
    }

    /// A frozen syllable: loud in the middle, quieter at the ends.
    private static let levels: [CGFloat] = [0.15, 0.3, 0.5, 0.4, 0.7, 0.9, 0.65, 0.8,
                                            1.0, 0.7, 0.55, 0.75, 0.45, 0.3, 0.4, 0.2]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xE4ECF2), Color(hex: 0xC6D3DE)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            strip
                .scaleEffect(scale)
                .frame(width: skin.overlayStripSize.width * scale,
                       height: skin.overlayStripSize.height * scale)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // A picture, not a control: the moulded ✕ inside would otherwise take the click.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // The overlay is drawn light whatever the window is, as it is over most desktops.
        .environment(\.colorScheme, .light)
        .environment(\.technoPalette, palette)
        .animation(.easeInOut(duration: 0.25), value: accentHex)
        .animation(.easeInOut(duration: 0.25), value: technoRaw)
    }

    @ViewBuilder
    private var strip: some View {
        switch skin {
        case .minimal: minimal
        case .techno: techno
        }
    }

    /// `RecordingOverlayView.minimalStrip`, still: glass capsule, microphone, bars, ✕.
    private var minimal: some View {
        let size = skin.overlayStripSize
        return HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent.opacity(0.55))
                .frame(width: 24, height: 24)
            HStack(spacing: 6) {
                ForEach(Self.levels.indices, id: \.self) { index in
                    Capsule().fill(accent)
                        .frame(width: 4, height: 4 + 22 * Self.levels[index])
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary.opacity(0.6))
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 12)
        .frame(width: size.width, height: size.height)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(0.35))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    /// `RecordingOverlayView.technoStrip`, still: the dot-matrix glass and the moulded ✕.
    private var techno: some View {
        let glass = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return HStack(spacing: 6) {
            ZStack {
                glass.fill(palette.screen)
                PixelMatrix(levels: Self.levels, rows: 8, mode: .level, palette: .phosphor(palette))
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
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}
