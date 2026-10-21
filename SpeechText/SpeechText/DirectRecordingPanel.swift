// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import SpeechTextCore

// MARK: - Panel Window

/// The record window, whose chrome follows the skin.
///
/// Minimal wears an ordinary macOS window: the rounded corners, the vibrancy behind
/// the material and the close button all come from the system, and reimplementing them
/// only produces a worse copy. Techno draws its own moulded shell, so it gets a
/// borderless window — there, a titlebar would sit on top of the moulding and swallow
/// clicks meant for the knob.
final class DirectRecordingPanelWindow: NSPanel {
    private var skinObserver: NSObjectProtocol?

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: AppSkin.current.recordPanelSize),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        title = ""
        isMovableByWindowBackground = true
        acceptsMouseMovedEvents = true
        hasShadow = true

        applySkin()

        // The hosted view reflows itself, but the window it sits in does not — and the
        // two skins want different chrome as well as different sizes.
        skinObserver = NotificationCenter.default.addObserver(
            forName: .skinDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySkin() }
        }

        center()
    }

    private func applySkin() {
        switch AppSkin.current {
        case .minimal:
            styleMask = [.titled, .closable, .fullSizeContentView, .nonactivatingPanel]
            standardWindowButton(.closeButton)?.isHidden = false
            // Neither makes sense for a fixed-size floating scratchpad.
            standardWindowButton(.miniaturizeButton)?.isHidden = true
            standardWindowButton(.zoomButton)?.isHidden = true
        case .techno:
            styleMask = [.borderless, .nonactivatingPanel]
        }
        setContentSize(AppSkin.current.recordPanelSize)
        invalidateShadow()
    }

    deinit {
        // A window is let go on main, as AppKit releases every one.
        MainActor.assumeIsolated {
            if let skinObserver { NotificationCenter.default.removeObserver(skinObserver) }
        }
    }

    /// `.nonactivatingPanel` normally refuses key status, but the panel's whole point
    /// is a text area the user can edit.
    override var canBecomeKey: Bool { true }

    /// The techno skin has no titlebar and the app has no menu bar, so the usual ways
    /// out of a window have to be wired up by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags.contains(.command), key == "w" {
            performClose(nil)
            return true
        }
        // Undo is wired by hand for the same reason: an agent app has no Edit menu for
        // ⌘Z to find, and ⌘Z is how an AI rewrite of a segment is taken back.
        // The focused text view's manager: that is the one its edits were registered on.
        if key == "z", flags == [.command] || flags == [.command, .shift],
           let undoManager = (firstResponder ?? self).undoManager {
            if flags.contains(.shift) {
                if undoManager.canRedo { undoManager.redo() }
            } else if undoManager.canUndo {
                undoManager.undo()
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }

    override func performClose(_ sender: Any?) {
        close()
    }
}

// MARK: - Text Insertion Handler

/// Inserts transcribed text at the caret and remembers where each span landed.
///
/// The Record Window is Tier A by definition — our own surface, the result visible
/// immediately — so it is where the "remember the range, replace exactly that span"
/// machinery is kept honest. The ledger is the same pure type inline delivery uses.
@MainActor
final class TextInsertionHandler {
    weak var textView: NSTextView?
    /// Where each inserted span sits in the text view. Read by `replaceSpan`; reset
    /// when a new recording starts, because the old ranges describe old text.
    private(set) var ledger = InsertionLedger()

    func reset() {
        ledger.clear()
        dlog("Span", "insertion ledger cleared")
    }

    /// Returns what landed and where, or nil when nothing was inserted.
    @discardableResult
    func insert(_ text: String, span: TranscriptSpanID? = nil) -> InsertionRecord? {
        guard let textView, !text.isEmpty else { return nil }
        let range = textView.selectedRange()

        // Add a space before the new text if the character before cursor is not whitespace
        var prefix = ""
        if range.location > 0 {
            let charBefore = (textView.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1))
            if let scalar = charBefore.unicodeScalars.first,
               !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                prefix = " "
            }
        }

        textView.insertText(prefix + text, replacementRange: range)
        // Each segment its own undo step, rather than one typing run with the next.
        textView.breakUndoCoalescing()

        // What the view holds is what gets recorded, not what we sent: substitutions are
        // off in both editors, but a record that describes the document rather than our
        // intent is the one a later guard can actually trust.
        let landed = NSRange(location: range.location + (prefix as NSString).length,
                             length: (text as NSString).length)
        let document = textView.string as NSString
        guard NSMaxRange(landed) <= document.length else { return nil }
        let record = InsertionRecord(span: span, range: landed, text: document.substring(with: landed))
        ledger.insert(span: span, range: landed, text: record.text)
        if let span {
            dlog("Span", "inserted \(span) at \(landed.location)+\(landed.length)")
        }
        return record
    }

    /// Adds `text` after everything the view holds, spaced as `insert` spaces it, and
    /// leaves the caret after it — one undoable step, the text already there untouched.
    /// For a dictation handed to a Record Window that is already open
    /// (`AppState.showDirectRecordingPanel`).
    @discardableResult
    func append(_ text: String) -> InsertionRecord? {
        guard let textView else { return nil }
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        return insert(text)
    }

    /// The text view's whole content as one record, for a pass over all of it.
    func wholeText() -> InsertionRecord? {
        guard let textView else { return nil }
        let document = textView.string as NSString
        let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = document.range(of: trimmed)
        guard range.location != NSNotFound else { return nil }
        return InsertionRecord(span: nil, range: range, text: trimmed)
    }

    /// Writes `records`' replacement where `FinalizePass.plan` finds them untouched, as
    /// one undoable edit — ⌘Z puts back what was dictated. Nil when the text there is no
    /// longer what was recorded (the user edited it meanwhile, or it is gone): then the
    /// document is left exactly as it is.
    func replace(_ records: [InsertionRecord], with text: String) -> TextReplacement? {
        guard let textView else { return nil }
        var ledger = InsertionLedger()
        for record in records {
            ledger.insert(span: record.span, range: record.range, text: record.text)
        }
        guard let plan = FinalizePass.plan(ledger: ledger, document: textView.string, replacement: text),
              textView.shouldChangeText(in: plan.range, replacementString: plan.text) else { return nil }
        textView.breakUndoCoalescing()
        textView.textStorage?.replaceCharacters(in: plan.range, with: plan.text)
        textView.didChangeText()
        textView.undoManager?.setActionName("AI Rewrite")
        dlog("Refine", "replaced \(plan.range.location)+\(plan.range.length) with \((plan.text as NSString).length) chars")
        return plan
    }

    /// Replaces one span's text in place, but only where it is provably still the text
    /// this handler put there. Anything else — the user edited over it, it appears twice,
    /// it is gone — and the document is left exactly as it is. Still uncalled: the
    /// Record Window inserts a segment only once its text is final, so its finalizing
    /// pass has nothing to correct. It is here for the day it inserts earlier.
    @discardableResult
    func replaceSpan(_ span: TranscriptSpanID, with text: String) -> Bool {
        guard let textView else { return false }
        guard let range = ledger.resolve(span: span, in: textView.string) else {
            dlog("Span", "replaceSpan \(span): refused — the text there is not what we inserted", level: .notice)
            return false
        }
        guard textView.shouldChangeText(in: range, replacementString: text) else { return false }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        ledger.replaced(span: span, at: range, with: text)
        dlog("Span", "replaceSpan \(span) at \(range.location)+\(range.length): \(text.count) chars")
        return true
    }
}

// MARK: - LCD Text Editor (NSViewRepresentable)

/// The editable text printed on the glass: phosphor on black, no chrome of its own.
struct LCDTextEditor: NSViewRepresentable {
    @Binding var text: String
    let insertionHandler: TextInsertionHandler
    var textColor: Color
    /// The caret and the selection wash; the glass's phosphor.
    var accent: Color

    static let font = NSFont.systemFont(ofSize: 15, weight: .regular)

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LCDTextEditor
        var isUpdating = false

        init(_ parent: LCDTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        /// The text view is first responder for most of the panel's life, and it eats
        /// Escape — so hand that one command back to the window.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            textView.window?.performClose(nil)
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
        textView.font = Self.font
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.textColor = NSColor(textColor)
        textView.setAccessibilityLabel("Transcript")
        applyAccent(to: textView)
        insertionHandler.textView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        context.coordinator.parent = self
        let wanted = NSColor(textColor)
        if textView.textColor != wanted {
            textView.textColor = wanted
        }
        // The display colour can change while the window is open.
        if textView.insertionPointColor != NSColor(accent) {
            applyAccent(to: textView)
        }
        if textView.string != text {
            context.coordinator.isUpdating = true
            let range = textView.selectedRange()
            // A wholesale replacement is not undoable, and the steps recorded before it
            // describe ranges of text that is gone.
            textView.undoManager?.removeAllActions()
            textView.string = text
            let safeLoc = min(range.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: safeLoc, length: 0))
            context.coordinator.isUpdating = false
        }
    }

    private func applyAccent(to textView: NSTextView) {
        textView.insertionPointColor = NSColor(accent)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(accent).withAlphaComponent(0.25),
            .foregroundColor: NSColor.white,
        ]
    }
}

// MARK: - Panel View

/// The record window.
///
/// One set of state and actions, two chassis. Every action lives once, below the two
/// `body` variants, so a button can't exist in one skin and be missing from the other.
struct DirectRecordingPanelView: View {
    @Bindable var speechEngine: SpeechEngine
    var appState: AppState
    /// Where segments land in the text view — and, kept by `AppState`, a dictation handed
    /// to the panel while it is open (`TextInsertionHandler.append`).
    let insertionHandler: TextInsertionHandler
    var autoStartRecording: Bool = true
    let onDismiss: () -> Void

    /// Coordinates lifted straight from the design file, for the techno chassis.
    /// Anything drawn on the glass is measured from the glass's top-left corner,
    /// everything else from the shell's.
    private enum Layout {
        static let screenOrigin = CGPoint(x: 12, y: 12)
        static let screenSize = CGSize(width: 338, height: 259.108)
        static let knobCentre = CGPoint(x: 294.5, y: 56)
        static let railLeft: CGFloat = 304.5

        // On the glass
        static let textOrigin = CGPoint(x: 24, y: 26)
        /// The glass is notched for the knob down to y≈81, so the text column stops
        /// short of it rather than reflowing around a hole that scrolls away.
        static let textWidth: CGFloat = 190
        static let statusOrigin = CGPoint(x: 24, y: 183)
        static let matrixOrigin = CGPoint(x: 4, y: 215)
        static let matrixColumns = 47
        static let matrixRows = 6
        /// Air between the action rail and the close button below it.
        static let closeGap: CGFloat = 6
    }

    @State private var showCopyCheck = false
    @State private var showPasteCheck = false
    @State private var isHoveringTransport = false
    @State private var langLabel = ""
    @State private var keyboardObserverID: UUID?
    @AppStorage(SettingsKeys.appSkin) private var skinRaw = AppSkin.default.rawValue
    @AppStorage(SettingsKeys.accentColor) private var accentHex = AccentColor.neutral
    @AppStorage(SettingsKeys.technoPhosphor) private var technoRaw = TechnoPhosphor.green.rawValue
    @AppStorage(SettingsKeys.spokenLanguages) private var spokenLanguages = ""
    @AppStorage(SettingsKeys.aiModeInRecordWindow) private var aiMode = false

    /// True while the LLM is rewriting the panel's text.
    @State private var isRefining = false
    @State private var refineTask: Task<Void, Never>?
    /// Passes waiting for the one in flight, oldest first: each segment is refined on
    /// its own, in order, so one never overtakes another in the text.
    @State private var refineQueue: [PendingRefinement] = []
    /// Which preset the last refinement routed to, shown under the text area.
    @State private var refineStatus: String?
    /// Set when the last refinement failed, so the status line can be shown in red.
    @State private var refineFailed = false

    private var hasText: Bool {
        !speechEngine.editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isBusy: Bool { speechEngine.isTranscribing || isRefining || speechEngine.isStartingEngine }

    private var skin: AppSkin { AppSkin(rawValue: skinRaw) ?? .default }
    private var techno: TechnoPalette { TechnoPalette(stored: technoRaw) }

    /// The transport's colour. Techno ignores the free accent and lights in its display
    /// colour; AI mode overrides both — it means something.
    private var accent: Color {
        if aiMode { return skin == .techno ? TechnoSkin.aiPhosphor : Semantic.ai }
        return skin == .techno ? techno.phosphor : AccentColor.transport(accentHex)
    }

    /// The flash after copy / paste / send. Semantic, so it stays put whatever colour
    /// the rest of the panel is wearing — on techno that is the design's green phosphor,
    /// whichever display colour the user picked.
    private var confirmation: Color {
        skin == .techno ? TechnoPalette.green.phosphor : Semantic.confirmation
    }

    private var palette: PixelPalette { aiMode ? .ai : .phosphor(techno) }

    private var displayMode: PixelDisplayMode {
        if speechEngine.isRecording { return .level }
        if isBusy { return .busy }
        return .idle
    }

    var body: some View {
        Group {
            switch skin {
            case .minimal: minimalBody
            case .techno: technoBody
            }
        }
        .frame(width: skin.recordPanelSize.width, height: skin.recordPanelSize.height)
        .environment(\.technoPalette, techno)
        .onAppear {
            refreshLangLabel()
            keyboardObserverID = KeyboardChangeObserver.shared.addHandler { refreshLangLabel() }
            if autoStartRecording {
                // Defer one runloop so the panel renders before the audio engine
                // initializes (engine.prepare() can block the main thread ~200-500ms).
                DispatchQueue.main.async {
                    insertionHandler.reset()
                    speechEngine.startRecording(locale: resolvedLocale())
                }
            }
        }
        .onDisappear {
            if let id = keyboardObserverID { KeyboardChangeObserver.shared.removeHandler(id: id) }
            dropRefinements()
        }
        .onChange(of: spokenLanguages) { refreshLangLabel() }
        .onChange(of: speechEngine.pendingInsertionText) { _, newValue in
            if let text = newValue, !text.isEmpty {
                // One insertion per span where the engine could name them, so each
                // carries its own range and the finalizing pass can replace one without
                // touching its neighbours; otherwise one untracked piece.
                let spans = speechEngine.pendingInsertionSpans
                var landed: [InsertionRecord] = []
                if spans.isEmpty {
                    if let record = insertionHandler.insert(text) { landed.append(record) }
                } else {
                    for id in spans {
                        guard let span = speechEngine.spanLayer.span(id),
                              let record = insertionHandler.insert(span.text, span: id) else { continue }
                        landed.append(record)
                    }
                }
                speechEngine.pendingInsertionText = nil
                if aiMode, !landed.isEmpty {
                    // Only this segment: the text before it is already refined, and a
                    // preset that fits these words is not one to apply to the rest.
                    enqueueRefinement(PendingRefinement(records: landed, wholeText: false,
                                                        recordID: speechEngine.lastRecordID))
                }
            }
        }
    }

    // MARK: - Techno chassis

    private var technoBody: some View {
        ZStack(alignment: .topLeading) {
            ShellBackground()

            LCDScreen(size: Layout.screenSize) {
                dotMatrix
                textArea
                statusLine
            }
            .offset(x: Layout.screenOrigin.x, y: Layout.screenOrigin.y)

            TransportKnob(
                systemImage: speechEngine.isRecording ? "pause" : "play",
                label: "Record",
                value: transportState,
                tint: aiMode ? TechnoSkin.aiPhosphor.opacity(0.95) : .white.opacity(0.92),
                isBusy: isBusy,
                isEnabled: !isBusy,
                help: transportHelp,
                action: toggleRecording
            )
            .offset(
                x: Layout.knobCentre.x - TransportKnob.diameter / 2,
                y: Layout.knobCentre.y - TransportKnob.diameter / 2
            )

            buttonRail
            closeButton
        }
        .clipShape(RoundedRectangle(cornerRadius: TechnoSkin.shellRadius, style: .continuous))
    }

    // MARK: - Minimal chassis

    /// The same controls in native macOS dress: a toolbar of icon buttons over a plain
    /// text area, with the transport as a capsule that grows into a level meter.
    private var minimalBody: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(langLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.secondary.opacity(0.5), lineWidth: 1)
                        )
                        .accessibilityLabel("Language")
                        .accessibilityValue(langName)

                    Spacer()

                    ForEach(railActions) { item in
                        MinimalIconButton(
                            systemImage: item.systemImage,
                            label: item.label,
                            value: item.value,
                            isOn: item.isOn,
                            accent: item.accent,
                            isEnabled: item.isEnabled,
                            help: item.help,
                            action: item.action
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)

                PlainTextEditor(
                    text: $speechEngine.editedText,
                    insertionHandler: insertionHandler,
                    onCancel: onDismiss
                )
                .overlay(alignment: .topLeading) {
                    if !hasText, let ghost = ghostView(base: .secondary) {
                        ghost
                            .font(.system(size: 14))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .padding(4)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.bottom, 32) // space so text doesn't hide behind the button
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 6) {
                if let text = statusText {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(statusTint)
                        .lineLimit(1)
                }
                minimalTransport
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 8)
            .offset(y: 4) // the button overlaps the text area's edge
        }
        .background(.ultraThinMaterial)
    }

    /// Collapsed it is a record button; recording or working, it stretches into the
    /// level meter so the panel always shows what the microphone is doing.
    private var minimalTransport: some View {
        let expanded = speechEngine.isRecording || isBusy
        return Button(action: toggleRecording) {
            ZStack {
                if expanded {
                    WaveformBarsView(
                        barLevels: speechEngine.barLevels,
                        isLoading: isBusy,
                        isPreparing: speechEngine.isStartingEngine,
                        barWidth: 3,
                        spacing: 2,
                        minBarHeight: 4,
                        maxBarHeight: 28,
                        barColor: .white
                    )
                    .padding(.horizontal, 16)
                    .transition(.opacity)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .transition(.opacity)
                }
            }
            .frame(width: expanded ? 160 : 48, height: 48)
            .background(
                Capsule()
                    .fill(accent.opacity(expanded ? 0.85 : 1.0))
                    .shadow(color: accent.opacity(isHoveringTransport ? 0.5 : 0.25),
                            radius: isHoveringTransport ? 10 : 4, y: 2)
            )
            .overlay(Capsule().fill(.white.opacity(isHoveringTransport ? 0.12 : 0)))
            .scaleEffect(isHoveringTransport ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help(transportHelp)
        .accessibilityLabel("Record")
        .accessibilityValue(transportState)
        .pointingHandCursor(enabled: !isBusy) { isHoveringTransport = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHoveringTransport)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: expanded)
    }

    // MARK: - Glass contents

    /// The equaliser along the bottom edge. It runs wider than the glass; `LCDScreen`
    /// clips it, so the dots stop at the rounded corners the way the design shows.
    private var dotMatrix: some View {
        PixelWaveform(
            levels: speechEngine.barLevels,
            columns: Layout.matrixColumns,
            rows: Layout.matrixRows,
            mode: displayMode,
            palette: palette
        )
        .offset(x: Layout.matrixOrigin.x, y: Layout.matrixOrigin.y)
    }

    private var textArea: some View {
        ZStack(alignment: .topLeading) {
            LCDTextEditor(
                text: $speechEngine.editedText,
                insertionHandler: insertionHandler,
                textColor: aiMode ? TechnoSkin.aiText : techno.phosphorText,
                accent: techno.phosphor
            )

            // While the first segment is still being spoken there is nothing in the
            // editor yet; showing the partial transcript here is the only feedback
            // that the words are landing.
            if !hasText, let ghost = ghostView(base: aiMode ? TechnoSkin.aiText : techno.phosphorText) {
                ghost
                    .font(Font(LCDTextEditor.font))
                    .multilineTextAlignment(.leading)
                    .allowsHitTesting(false)
            }
        }
        .frame(
            width: Layout.textWidth,
            height: Layout.statusOrigin.y - Layout.textOrigin.y - 6,
            alignment: .topLeading
        )
        .offset(x: Layout.textOrigin.x, y: Layout.textOrigin.y)
    }

    /// The transcript in progress, printed where the editor is still empty. Settled text
    /// and the partial the recogniser may still take back are drawn at different
    /// brightnesses: on a surface we own, the boundary between what has landed and what
    /// is still moving is drawn rather than implied (the span layer's invariant).
    private func ghostView(base: Color) -> Text? {
        let settled = speechEngine.spanLayer.segmentStableText
        let moving = speechEngine.spanLayer.segmentProvisionalText

        guard !settled.isEmpty || !moving.isEmpty else {
            guard let placeholder = placeholderText else { return nil }
            return Text(placeholder).foregroundStyle(base.opacity(0.45))
        }

        var text = Text(verbatim: "")
        if !settled.isEmpty {
            text = text + Text(settled).foregroundStyle(base.opacity(0.8))
        }
        if !moving.isEmpty {
            let lead = settled.isEmpty ? "" : " "
            text = text + Text(lead + moving).foregroundStyle(base.opacity(0.35))
        }
        return text
    }

    /// What the glass says before the first word lands.
    private var placeholderText: String? {
        if speechEngine.isRecording { return "Listening…" }
        if speechEngine.isStartingEngine { return "Starting…" }
        if speechEngine.isTranscribing { return "Transcribing…" }
        return nil
    }

    @ViewBuilder
    private var statusLine: some View {
        if let text = statusText {
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusTint)
                .lineLimit(2)
                .frame(width: 250, alignment: .leading)
                .offset(x: Layout.statusOrigin.x, y: Layout.statusOrigin.y)
                .allowsHitTesting(false)
        }
    }

    private var statusText: String? {
        if let error = speechEngine.errorMessage { return error }
        if isRefining { return "Rewriting with AI…" }
        return refineStatus
    }

    private var statusTint: Color {
        if speechEngine.errorMessage != nil || refineFailed { return TechnoSkin.danger }
        if isRefining { return TechnoSkin.aiText }
        return techno.phosphorText.opacity(0.55)
    }

    // MARK: - Controls

    private var transportHelp: String {
        if isBusy { return "Working…" }
        if speechEngine.isRecording { return "Pause and transcribe" }
        if speechEngine.isPaused { return "Resume recording" }
        return "Start recording"
    }

    /// What VoiceOver reads after the transport's name, in both skins.
    private var transportState: String {
        if speechEngine.isStartingEngine { return "Starting" }
        if isRefining { return "Rewriting with AI" }
        if speechEngine.isTranscribing { return "Transcribing" }
        if speechEngine.isRecording { return "Recording" }
        if speechEngine.isPaused { return "Paused" }
        return "Not recording"
    }

    /// The language badge's code, spelled out for VoiceOver ("EN" → "English").
    private var langName: String {
        Locale.current.localizedString(forLanguageCode: langLabel.lowercased()) ?? langLabel
    }

    private func refreshLangLabel() {
        let locale = resolvedLocale()
        langLabel = locale.components(separatedBy: "-").first.map { $0.uppercased() } ?? "?"
    }

    private func toggleRecording() {
        let spring = Animation.spring(response: 0.35, dampingFraction: 0.75)
        if speechEngine.isRecording {
            withAnimation(spring) { speechEngine.pauseRecording() }
        } else if speechEngine.isPaused {
            withAnimation(spring) { speechEngine.resumeRecording(locale: resolvedLocale()) }
        } else {
            // A new recording: the ranges recorded for the old one describe text that is
            // no longer this recording's to rewrite.
            insertionHandler.reset()
            dropRefinements()
            withAnimation(spring) { speechEngine.startRecording(locale: resolvedLocale()) }
        }
    }

    /// The actions both chassis offer, defined once.
    ///
    /// The skins draw them differently — moulded discs in a rail, or a row of icon
    /// buttons — but they render the same list, which is what keeps a button from
    /// existing in one skin and quietly missing from the other.
    private struct RailAction: Identifiable {
        let id: String
        let systemImage: String
        /// VoiceOver's name for the button, the same in both skins.
        let label: String
        /// The state VoiceOver reads after the name. Only a toggle has one: `isOn` is
        /// also the paste and copy confirmation flash, which is not a state.
        var value = ""
        var isOn = false
        var accent: Color = .accentColor
        var isEnabled = true
        var help: String
        let action: () -> Void
    }

    private var railActions: [RailAction] {
        [
            RailAction(
                id: "ai",
                systemImage: "sparkles",
                label: "AI Rewrite",
                value: aiMode ? "On" : "Off",
                isOn: aiMode,
                accent: skin == .techno ? TechnoSkin.aiPhosphor : Semantic.ai,
                help: aiMode
                    ? "AI mode on — dictation is rewritten using your prompt presets"
                    : "AI mode off — text is inserted as transcribed",
                action: toggleAIMode
            ),
            RailAction(
                id: "paste",
                systemImage: showPasteCheck ? "checkmark" : "text.insert",
                label: "Insert",
                isOn: showPasteCheck,
                accent: confirmation,
                isEnabled: hasText,
                help: "Insert at the cursor in the app you came from",
                action: pasteAtCursor
            ),
            RailAction(
                id: "copy",
                systemImage: showCopyCheck ? "checkmark" : "doc.on.doc",
                label: "Copy",
                isOn: showCopyCheck,
                accent: confirmation,
                isEnabled: hasText,
                help: "Copy to the clipboard",
                action: copyToClipboard
            ),
        ]
    }

    private var railHeight: CGFloat {
        let count = CGFloat(railActions.count)
        return count * PlasticButton.size + (count - 1) * 4 + 8
    }

    /// The rail hangs from its bottom edge, high enough that the close button below it
    /// still clears the shell's bottom-right corner.
    private let railBottom: CGFloat = 213

    private var buttonRail: some View {
        ButtonRail {
            ForEach(railActions) { item in
                PlasticButton(
                    systemImage: item.systemImage,
                    label: item.label,
                    value: item.value,
                    isOn: item.isOn,
                    accent: item.accent,
                    isEnabled: item.isEnabled,
                    help: item.help,
                    action: item.action
                )
            }
        }
        .offset(x: Layout.railLeft, y: railBottom - railHeight)
    }

    /// Closing the window is not one of the things you do *to the text*, so it does not
    /// ride in their rail. It sits under it, in the same column but on its own and
    /// without the milled recess that binds the rail's buttons into a group — the
    /// missing recess is the separation.
    ///
    /// The minimal skin has no equivalent: there the system titlebar provides it, and a
    /// second close button beside the real one would be nonsense.
    private var closeButton: some View {
        PlasticButton(
            systemImage: "xmark",
            label: "Close",
            help: "Close (the transcription is kept in History)",
            action: onDismiss
        )
        .offset(x: Layout.railLeft + 3, y: railBottom + Layout.closeGap)
    }

    // MARK: - Actions

    private func toggleAIMode() {
        aiMode.toggle()
        // Turning it on with text already dictated should act on that text now,
        // otherwise the toggle would appear to do nothing.
        if aiMode, !speechEngine.isRecording, !speechEngine.isTranscribing {
            if let whole = insertionHandler.wholeText() {
                enqueueRefinement(PendingRefinement(records: [whole], wholeText: true,
                                                    recordID: speechEngine.lastRecordID))
            }
        } else if !aiMode {
            dropRefinements()
            refineStatus = nil
            refineFailed = false
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(speechEngine.editedText, forType: .string)
        flash($showCopyCheck)
    }

    private func pasteAtCursor() {
        appState.pasteTextToTarget(speechEngine.editedText)
        flash($showPasteCheck)
    }

    private func flash(_ binding: Binding<Bool>) {
        binding.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            binding.wrappedValue = false
        }
    }

    // MARK: - LLM Refinement

    /// Text the ✨ pass is to rewrite: where it landed, so the result replaces exactly it.
    private struct PendingRefinement {
        var records: [InsertionRecord]
        /// The whole text area, when ✨ was turned on over text already there. Several
        /// dictations routed as one, so a summarising preset gets no pass on length.
        let wholeText: Bool
        /// The History entry of the segment the pass belongs to.
        let recordID: UUID?

        var source: String {
            records.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func enqueueRefinement(_ pending: PendingRefinement) {
        guard TextRefinementService.isConfigured else {
            refineStatus = LLMConfiguration.providerType.needsAPIKey
                ? "Set an LLM API key in Settings to use AI mode"
                : "Choose a model in Settings › AI Rewrite to use AI mode"
            refineFailed = true
            return
        }
        refineQueue.append(pending)
        runNextRefinement()
    }

    private func dropRefinements() {
        refineQueue.removeAll()
        refineTask?.cancel()
        refineTask = nil
        isRefining = false
    }

    /// Refines the oldest queued text and writes the result over it — only where that
    /// text is still exactly what was inserted, as one undoable edit, and only when the
    /// result is not a collapse of it (`TextRefinementService.isCollapse`). Anything else
    /// leaves the text as dictated and says why under it.
    private func runNextRefinement() {
        guard !isRefining, !refineQueue.isEmpty else { return }
        let pending = refineQueue.removeFirst()
        let source = pending.source
        guard !source.isEmpty else { return runNextRefinement() }

        isRefining = true
        refineStatus = nil
        refineFailed = false
        let recordID = pending.recordID
        refineTask = Task { @MainActor in
            // Runs on the cancellation paths below too, which would otherwise leave
            // the panel stuck in its "rewriting" state.
            defer {
                if !Task.isCancelled {
                    isRefining = false
                    refineTask = nil
                    if aiMode { runNextRefinement() }
                }
            }
            do {
                let result = try await TextRefinementService.refine(source)
                guard !Task.isCancelled else { return }

                if TextRefinementService.isCollapse(input: source, output: result.text,
                                                    presetName: result.presetName,
                                                    presets: PromptPresetStore.load(),
                                                    allowsSummary: !pending.wholeText) {
                    let share = Int((Double(result.text.count) / Double(source.count) * 100).rounded())
                    dlog("Refine", "refused: \(result.presetName ?? "no preset") left \(share)% of \(source.count) chars", level: .notice)
                    refineStatus = "AI cut this to \(share)% of its length — kept what you dictated"
                    refineFailed = true
                    if let recordID {
                        TranscriptionHistory.shared.recordRefinementFailure(
                            id: recordID, input: source,
                            error: "Not applied: \(result.presetName ?? "the rewrite") cut the text to \(share)% of its length",
                            provider: result.provider, model: result.model, usage: result.usage,
                            latency: result.latency)
                    }
                    return
                }

                if source != result.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                    guard let applied = insertionHandler.replace(pending.records, with: result.text) else {
                        refineStatus = "The text changed while AI was working — left as it is"
                        refineFailed = true
                        return
                    }
                    shiftQueue(after: applied)
                }
                refineStatus = result.presetName.map { "AI · \($0)" } ?? "AI"
                refineFailed = false
                if let recordID {
                    TranscriptionHistory.shared.recordRefinement(
                        id: recordID, input: source, output: result.text,
                        presetName: result.presetName,
                        provider: result.provider, model: result.model, usage: result.usage,
                        latency: result.latency
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                // The dictated text stays in the text area — nothing is lost.
                refineStatus = "AI failed: \(error.localizedDescription)"
                refineFailed = true
                if let recordID {
                    let type = LLMConfiguration.providerType
                    TranscriptionHistory.shared.recordRefinementFailure(
                        id: recordID, input: source, error: error.localizedDescription,
                        provider: type.rawValue, model: LLMConfiguration.model(for: type)
                    )
                }
            }
        }
    }

    /// A replacement changed the length of the text: move the queued records that sit
    /// after it by the same amount, so they are found where they now are. (Without this,
    /// `InsertionLedger.resolve` would still find each by its text — unless it repeats.)
    private func shiftQueue(after replacement: TextReplacement) {
        let original = replacement.range
        let delta = (replacement.text as NSString).length - original.length
        guard delta != 0 else { return }
        for index in refineQueue.indices {
            for r in refineQueue[index].records.indices
            where refineQueue[index].records[r].range.location >= NSMaxRange(original) {
                refineQueue[index].records[r].range.location += delta
            }
        }
    }
}
