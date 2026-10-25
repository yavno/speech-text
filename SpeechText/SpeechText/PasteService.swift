// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Cocoa
import ApplicationServices
import Carbon.HIToolbox
import SpeechTextCore

@MainActor
struct PasteService {
    /// Pastes text at the current cursor position, preserving the user's clipboard.
    /// Saves clipboard contents, pastes via ⌘V, then restores the original clipboard.
    static func pasteAtCursor(_ text: String) {
        let frontApp = NSWorkspace.shared.frontmostApplication
        dlog("Paste", "pasteAtCursor: \(text.count) chars, trusted=\(AXIsProcessTrusted()), secureInput=\(IsSecureEventInputEnabled()), front=\(frontApp?.localizedName ?? "nil") (\(frontApp?.bundleIdentifier ?? "nil"))")

        let pasteboard = NSPasteboard.general
        stageClipboard(pasteboard, text: text)

        // Use CGEvent as primary method — it only requires Accessibility permission,
        // unlike AppleScript which also needs Automation permission for System Events
        // and com.apple.security.automation.apple-events entitlement with hardened runtime.
        simulatePasteCGEvent()

        scheduleClipboardRestore(pasteboard)
    }

    // MARK: - Reading a selection (the Edit shortcut)

    /// What `readSelection` found.
    enum SelectionRead {
        case selected(CapturedSelection)
        case nothingSelected
    }

    /// The selected text of the app in front, for the Edit shortcut to rewrite.
    ///
    /// A field whose selection the AX API can read *and* re-select (Tier A, see
    /// `probeFocusedText`) is read directly, and the answer carries the range: when the
    /// instruction is over, `select` finds those words again untouched and re-selects
    /// them before they are cut. Everything else — Chromium, Electron, terminals — is read
    /// with a ⌘C, the user's clipboard put back once the copy is in. Reading changes
    /// nothing: the selection is cut only once the user has finished the instruction.
    static func readSelection(in app: NSRunningApplication?, completion: @escaping (SelectionRead) -> Void) {
        let probe = probeFocusedText(in: app)
        if DeliveryTier.resolve(isOwnSurface: false, probe: probe) == .a,
           let element = focusedTextElement(of: app),
           let range = selectedRange(of: element),
           let document = stringValue(of: element) {
            guard let record = SelectionEdit.words(in: range, of: document) else {
                dlog("Edit", "selection: \(range.location)+\(range.length) of \((document as NSString).length) read through AX holds no words")
                completion(.nothingSelected)
                return
            }
            dlog("Edit", "selection: \(record.text.count) chars at \(record.range.location)+\(record.range.length) (selected \(range.location)+\(range.length)), read through AX")
            completion(.selected(CapturedSelection(text: record.text, record: record)))
            return
        }

        copySelection { text in
            guard let text else {
                completion(.nothingSelected)
                return
            }
            dlog("Edit", "selection: \(text.count) chars, read with ⌘C")
            completion(.selected(CapturedSelection(text: text, record: nil)))
        }
    }

    /// The selected text of the app in front, read with a ⌘C and the user's clipboard put
    /// back; nil when nothing is selected.
    private static func copySelection(completion: @escaping (String?) -> Void) {
        copySelectionItems { completion($0?.text) }
    }

    /// The same, with every pasteboard type the app wrote.
    private static func copySelectionItems(completion: @escaping ((text: String, items: [NSPasteboardItem])?) -> Void) {
        let pasteboard = NSPasteboard.general
        // A paste's restore still pending means the pasteboard holds our own text, and
        // the snapshot taken now would be of that rather than of the user's clipboard.
        restorePendingClipboardNow(pasteboard)
        let saved = saveClipboard(pasteboard)
        pasteboardWrites += 1
        let before = pasteboard.changeCount
        simulateCommandKey("c", name: "⌘C")
        awaitChange(of: pasteboard, since: before, late: {
            // Taken for nothing selected, but the copy did land, over the user's clipboard.
            dlog("Edit", "selection: the ⌘C landed late — the clipboard is put back")
            restoreClipboard(pasteboard, items: saved)
        }) { changed in
            guard changed else {
                dlog("Edit", "selection: ⌘C changed nothing — nothing selected")
                completion(nil)
                return
            }
            let text = pasteboard.string(forType: .string) ?? ""
            let items = saveClipboard(pasteboard)
            var strings: [String: String] = [:]
            for type in pasteboard.types ?? [] where type.rawValue.localizedCaseInsensitiveContains("vscode") {
                if let data = pasteboard.data(forType: type), let value = String(data: data, encoding: .utf8) {
                    strings[type.rawValue] = value
                }
            }
            restoreClipboard(pasteboard, items: saved)

            if SelectionEdit.isEmptySelectionLineCopy(strings) {
                dlog("Edit", "selection: the editor copied the caret's line — nothing selected")
                completion(nil)
                return
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                dlog("Edit", "selection: ⌘C copied no text")
                completion(nil)
                return
            }
            completion((text, items))
        }
    }

    /// What `cutSelection` took out of the document.
    enum CutResult {
        /// `items` is the pasteboard as the ⌘X left it, every type the app wrote — pasting
        /// them back restores the text with its formatting.
        case cut(items: [NSPasteboardItem], text: String)
        /// The ⌘X changed nothing: nothing selected, or a field that cannot be edited.
        case nothing
    }

    /// Cuts the selection of the app in front with a ⌘X, keeping what was cut and putting
    /// the user's clipboard back.
    ///
    /// A ⌘X that lands after `completion` said `.nothing` has still taken the text out of
    /// the document. If what it put on the pasteboard `isSelection`, the user's clipboard
    /// is put back and `landedLate` is handed the cut, to put it back where it was; a
    /// change that is not the selection is someone else's copy and is left alone.
    static func cutSelection(isSelection: @escaping (String) -> Bool,
                             landedLate: @escaping ([NSPasteboardItem]) -> Void,
                             completion: @escaping (CutResult) -> Void) {
        let pasteboard = NSPasteboard.general
        restorePendingClipboardNow(pasteboard)
        let saved = saveClipboard(pasteboard)
        pasteboardWrites += 1
        let before = pasteboard.changeCount
        simulateCommandKey("x", name: "⌘X")
        awaitChange(of: pasteboard, since: before, late: {
            let text = pasteboard.string(forType: .string) ?? ""
            guard isSelection(text) else {
                dlog("Edit", "cut: the pasteboard changed late to \(text.count) chars that are not the selection — left alone")
                return
            }
            dlog("Edit", "cut: the ⌘X landed late (\(text.count) chars) — the clipboard is put back")
            let items = saveClipboard(pasteboard)
            restoreClipboard(pasteboard, items: saved)
            landedLate(items)
        }) { changed in
            guard changed else {
                dlog("Edit", "cut: ⌘X changed nothing")
                completion(.nothing)
                return
            }
            let text = pasteboard.string(forType: .string) ?? ""
            let items = saveClipboard(pasteboard)
            restoreClipboard(pasteboard, items: saved)
            completion(.cut(items: items, text: text))
        }
    }

    /// Polls the pasteboard until a ⌘C or ⌘X lands. The copy happens in another process
    /// with no signal of its own. Once the poll has given up, `late` runs if the key lands
    /// after all (`watchForLateChange`).
    private static func awaitChange(of pasteboard: NSPasteboard, since before: Int, attempt: Int = 0,
                                    late: @escaping () -> Void, completion: @escaping (Bool) -> Void) {
        // ~600 ms in 20 ms steps: Chromium takes its time. An app with nothing selected
        // leaves the pasteboard alone, so running out means nothing was there.
        let maxAttempts = 30
        guard pasteboard.changeCount == before else {
            completion(true)
            return
        }
        guard attempt < maxAttempts else {
            // Read before the completion runs: what it writes is ours, not the key's.
            let writes = pasteboardWrites
            completion(false)
            watchForLateChange(of: pasteboard, since: before, writes: writes,
                               until: ProcessInfo.processInfo.systemUptime + lateChangeSeconds, landed: late)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            awaitChange(of: pasteboard, since: before, attempt: attempt + 1, late: late, completion: completion)
        }
    }

    /// How long after `awaitChange` gave up a ⌘C or ⌘X is still watched for.
    private static let lateChangeSeconds: TimeInterval = 3

    /// Bumped by every write of ours to the pasteboard and by every ⌘C or ⌘X posted: a
    /// change after it is not the late key's.
    private static var pasteboardWrites = 0

    /// After `awaitChange` gave up, the key may still land — an app slower than 600 ms, a
    /// beach ball — and with nothing watching, a ⌘C left the user's clipboard holding the
    /// selection, and a ⌘X took text out of the document with nothing but the clipboard
    /// holding it, while the edit had concluded that nothing could be cut. So the
    /// pasteboard is watched a while longer, on the main run loop. A change with no write
    /// of ours in between is taken for the key; a write of ours ends the watch, since the
    /// change would then be ours.
    private static func watchForLateChange(of pasteboard: NSPasteboard, since before: Int, writes: Int,
                                           until deadline: TimeInterval, landed: @escaping () -> Void) {
        guard writes == pasteboardWrites else { return }
        guard pasteboard.changeCount == before else {
            landed()
            return
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            watchForLateChange(of: pasteboard, since: before, writes: writes, until: deadline, landed: landed)
        }
    }

    /// Pastes pasteboard items — text cut earlier, with its formatting — at the cursor,
    /// the user's clipboard preserved as for every paste.
    static func pasteItems(_ items: [NSPasteboardItem]) {
        let pasteboard = NSPasteboard.general
        if pendingRestore == nil || pasteboard.changeCount != stagedChangeCount {
            savedClipboard = saveClipboard(pasteboard)
        }
        pasteboardWrites += 1
        pasteboard.clearContents()
        pasteboard.writeObjects(copies(of: items))
        markTransient(pasteboard)
        stagedChangeCount = pasteboard.changeCount
        simulatePasteCGEvent()
        scheduleClipboardRestore(pasteboard)
    }

    /// Fresh items with the same contents: an `NSPasteboardItem` can be written once.
    private static func copies(of items: [NSPasteboardItem]) -> [NSPasteboardItem] {
        items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    enum RecordSelection {
        /// The selected words were found untouched, and are selected.
        case selected
        /// They are no longer there as they were.
        case changed
        /// They are there, but the field would not confirm them as its selection — the
        /// ⌘X that follows is checked by what it cuts instead.
        case unconfirmed
    }

    /// Selects the Tier A selection `record` again in `app`'s focused field, after finding
    /// its words untouched (`InsertionLedger.resolve`) — the user may have clicked
    /// elsewhere while speaking the instruction. Writes nothing but the selection.
    static func select(_ record: InsertionRecord, in app: NSRunningApplication) -> RecordSelection {
        guard AXIsProcessTrusted(), let element = focusedTextElement(of: app) else {
            dlog("Edit", "select: no focused element")
            return .unconfirmed
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier,
              let document = stringValue(of: element) else {
            dlog("Edit", "select: the focused element is not \(app.localizedName ?? "the target")'s, or has no value")
            return .unconfirmed
        }
        var ledger = InsertionLedger()
        ledger.insert(span: nil, range: record.range, text: record.text)
        guard let range = ledger.resolve(record, in: document) else {
            dlog("Edit", "select: the selected words are no longer there untouched")
            return .changed
        }
        // The record is the selection trimmed to its words, so a field still holding the
        // user's selection — a trailing newline and all — is left as it is. Writing the
        // trimmed range there was no improvement and Slack (Electron) applied it elsewhere:
        // the read-back failed and the ⌘X cut other text (2026-10-22).
        let current = selectedRange(of: element)
        if current != range, current.flatMap({ SelectionEdit.words(in: $0, of: document)?.range }) != range {
            guard setSelectedRange(range, of: element), selectedRange(of: element) == range else {
                dlog("Edit", "select: selecting \(range.location)+\(range.length) did not read back", level: .notice)
                return .unconfirmed
            }
        }
        return .selected
    }

    private static func setSelectedRange(_ range: NSRange, of element: AXUIElement) -> Bool {
        var value = CFRange(location: range.location, length: range.length)
        guard let axValue = AXValueCreate(.cfRange, &value) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
    }

    /// Leaves `text` on the clipboard for the user — the result that could not be
    /// written where it belonged.
    static func copyToClipboard(_ text: String) {
        let pasteboard = prepareClipboardForUser()
        pasteboard.setString(text, forType: .string)
    }

    /// The same, for text cut earlier with its formatting.
    static func copyToClipboard(items: [NSPasteboardItem]) {
        let pasteboard = prepareClipboardForUser()
        pasteboard.writeObjects(copies(of: items))
    }

    private static func prepareClipboardForUser() -> NSPasteboard {
        let pasteboard = NSPasteboard.general
        // A pending restore would find the change count moved and stand down anyway;
        // cancelled, it cannot put anything back over this either.
        pendingRestore?.cancel()
        pendingRestore = nil
        savedClipboard = nil
        pasteboardWrites += 1
        pasteboard.clearContents()
        return pasteboard
    }

    // MARK: - Tier probe (the Edit shortcut's selection read)

    /// What the Accessibility API will let us do to this app's focused text element —
    /// asked by `readSelection`, to decide whether the selection can be read and
    /// re-selected through AX or has to be read with a ⌘C.
    ///
    /// The read-back is the whole point: Chromium answers `.success` to a selected-range
    /// write and then reports a different range, so only writing the range the element
    /// already has — a no-op for the user — and comparing what comes back separates an
    /// app we can correct from one we would be scribbling into blind.
    ///
    /// That write is only a no-op if the range we read is where the caret really is. A
    /// web or Electron field whose accessibility tree has just been woken by our first
    /// query answers `{0, 0}` whatever the caret's position, and writing that back moved
    /// the caret to the start of the field — a dictation then landed *before* the text
    /// already there. So a range that cannot be the caret's (`{0, 0}` in a non-empty
    /// field, or one past the end of the value) is never written, and the element probes
    /// as Tier B. A selection genuinely at the very start of its field is then read with
    /// a ⌘C instead; that is the side to fail on.
    static func probeFocusedText(in app: NSRunningApplication?) -> AXTextProbe {
        guard AXIsProcessTrusted(), let element = focusedTextElement(of: app) else {
            return .unavailable
        }

        var probe = AXTextProbe()
        let document = stringValue(of: element)
        probe.valueReadable = document != nil

        guard let range = selectedRange(of: element) else { return probe }
        probe.rangeReadable = true

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return probe
        }

        let length = (document as NSString?)?.length ?? 0
        guard range.location + range.length <= length,
              !(range.location == 0 && range.length == 0 && length > 0) else {
            dlog("Span", "probe: selection \(range.location)+\(range.length) in \(length) characters is not trusted — not written back")
            return probe
        }

        // Setting the selection to what it already is changes nothing the user can see.
        var value = range
        guard let axValue = AXValueCreate(.cfRange, &value) else { return probe }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success else {
            return probe
        }
        probe.rangeReadsBack = selectedRange(of: element) == range
        return probe
    }

    /// Where the text is going: the app, its focused window's title and the focused
    /// field's label, or nil when there is nothing that may be sent (see `FocusContext.capture`).
    ///
    /// Only the LLM pass reads this: an AI dictation takes it at the stop, from the app the
    /// text is going to, and an edit after the microphone has been asked to start — these
    /// are round trips to another process, and against a slow app they would otherwise be
    /// time the user loses a first syllable to.
    static func readFocusContext(in app: NSRunningApplication?) -> FocusContext? {
        guard let target = app ?? NSWorkspace.shared.frontmostApplication,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }

        var windowTitle: String?
        var fieldLabels: [String?] = []
        var isSecureField = false
        if AXIsProcessTrusted() {
            _ = messagingTimeout
            let appElement = AXUIElementCreateApplication(target.processIdentifier)
            if let window = elementValue(of: appElement, kAXFocusedWindowAttribute) {
                windowTitle = attributeString(of: window, kAXTitleAttribute)
            }
            if let element = focusedTextElement(of: target) {
                isSecureField = attributeString(of: element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
                fieldLabels = [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute]
                    .map { attributeString(of: element, $0) }
            }
        }
        return FocusContext.capture(appName: target.localizedName,
                                    bundleID: target.bundleIdentifier,
                                    windowTitle: windowTitle,
                                    fieldLabels: fieldLabels,
                                    isSecureField: isSecureField)
    }

    /// The focused element of `app`, or of whatever is frontmost when `app` is nil.
    private static func focusedTextElement(of app: NSRunningApplication?) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        _ = messagingTimeout
        guard let pid = (app ?? NSWorkspace.shared.frontmostApplication)?.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        return elementValue(of: appElement, kAXFocusedUIElementAttribute)
    }

    /// Set once, on the system-wide element, which makes it this process's default. The
    /// system's own is six seconds *per call*, and the focus context and an edit each
    /// make several on the main thread — against a hung Electron app that
    /// is a stop that appears to do nothing for half a minute.
    private static let messagingTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.5)
    }()

    private static func attributeString(of element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func elementValue(of element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        attributeString(of: element, kAXValueAttribute)
    }

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    // MARK: - Clipboard

    /// The user's clipboard, taken before the first paste of a burst, and the restore
    /// waiting to put it back.
    ///
    /// Pastes come in bursts — a dictation straight after another, an edit's put-back
    /// followed by the next — and the naive version — save, paste, restore in 1 s, per paste — corrupts the clipboard
    /// rather than preserving it: the second paste's "save" reads back the *first
    /// paste's text*, and a second later the user's clipboard holds their own
    /// dictation. So the snapshot is taken once per burst and the pending restore is
    /// cancelled and rescheduled, never re-taken.
    private static var savedClipboard: [NSPasteboardItem]?
    private static var pendingRestore: DispatchWorkItem?
    /// The pasteboard's change count right after our text went on it. If it differs
    /// when the restore fires, someone else wrote the pasteboard in between — the user
    /// pressed ⌘C mid-dictation — and putting the old snapshot back would wipe that copy.
    private static var stagedChangeCount = 0

    /// Puts `text` on the pasteboard, keeping the user's own contents safe.
    private static func stageClipboard(_ pasteboard: NSPasteboard, text: String) {
        // The first paste of a burst takes the snapshot. A later one takes it again
        // only if the pasteboard changed under us since our last write — the user
        // pressed ⌘C between two pastes — so what goes back at the end is their copy,
        // not the pre-dictation contents over it.
        if pendingRestore == nil || pasteboard.changeCount != stagedChangeCount {
            savedClipboard = saveClipboard(pasteboard)
        }
        pasteboardWrites += 1
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        markTransient(pasteboard)
        stagedChangeCount = pasteboard.changeCount
    }

    /// Tells clipboard managers (Maccy, Raycast, Paste, Alfred) that what is on the
    /// pasteboard is passing through, by the nspasteboard.org convention: without it
    /// every paste of a dictation is archived in their history. Never `ConcealedType` —
    /// that one is for passwords, and some apps refuse to paste it.
    private static func markTransient(_ pasteboard: NSPasteboard) {
        for type in ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(type))
        }
    }

    /// Restores the user's clipboard after a generous delay to ensure the target app has
    /// fully processed the paste command and read from the clipboard.
    ///
    /// This is a blind wait on purpose: the ⌘V lands in *another* process, and there is
    /// no signal from it telling us when it has read the pasteboard. No completion can
    /// replace this delay, so leave it at 1.0s. A paste that arrives before the previous
    /// restore fires pushes it out rather than stacking a second one behind it.
    private static func scheduleClipboardRestore(_ pasteboard: NSPasteboard) {
        pendingRestore?.cancel()
        let restore = DispatchWorkItem { finishClipboardRestore(pasteboard) }
        pendingRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: restore)
    }

    /// Runs a pending restore now instead of when its timer fires.
    private static func restorePendingClipboardNow(_ pasteboard: NSPasteboard) {
        guard let pending = pendingRestore else { return }
        pending.cancel()
        finishClipboardRestore(pasteboard)
    }

    private static func finishClipboardRestore(_ pasteboard: NSPasteboard) {
        defer {
            savedClipboard = nil
            pendingRestore = nil
        }
        guard pasteboard.changeCount == stagedChangeCount else {
            dlog("Paste", "Clipboard changed since the paste — leaving it alone")
            return
        }
        let items = savedClipboard ?? []
        restoreClipboard(pasteboard, items: items)
        dlog("Paste", "Clipboard restored", level: .debug)
    }

    /// Save current clipboard contents so they can be restored later.
    private static func saveClipboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        var saved: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            saved.append(copy)
        }
        return saved
    }

    /// Restore previously saved clipboard contents.
    private static func restoreClipboard(_ pasteboard: NSPasteboard, items: [NSPasteboardItem]) {
        pasteboardWrites += 1
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    /// Activate a specific app (used to switch back to user's app before pasting)
    static func activateApp(_ app: NSRunningApplication) {
        // An app that quit cannot be brought back — and the AppleScript fallback below
        // would *launch* it again, after which the ⌘V goes to whatever is in front.
        guard !app.isTerminated else {
            dlog("Paste", "Not activating \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")): it quit", level: .notice)
            return
        }
        dlog("Paste", "Activating: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")

        // Try NSRunningApplication.activate first
        let result = app.activate()
        dlog("Paste", "NSRunningApplication.activate: \(result)")

        if !result, let bundleID = app.bundleIdentifier {
            // Fallback to AppleScript only if direct activation failed
            let script = NSAppleScript(source: """
                tell application id "\(bundleID)" to activate
            """)
            var err: NSDictionary?
            script?.executeAndReturnError(&err)
            if let err {
                dlog("Paste", "AppleScript activate failed: \(err)", level: .error)
            } else {
                dlog("Paste", "AppleScript activate succeeded")
            }
        }
    }

    /// The name of the app whose menu bar menu has the keyboard — Control Center, or one
    /// of its extras (Sound, Wi-Fi, Bluetooth) — or nil. While one is open the app beneath
    /// is still `frontmostApplication`, but a ⌘V goes to the menu and is lost, and
    /// activating the app does not close it. Control Center answers a focused window only
    /// while one of its menus is open (measured 2026-10-22, macOS 26); the system-wide
    /// focused application cannot be read instead — it failed with and without the menu.
    /// Another app's status menu is not checked: unmeasured.
    static func openMenuBarMenu() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        _ = messagingTimeout
        guard let controlCenter = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.controlcenter").first else { return nil }
        var window: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(controlCenter.processIdentifier),
                                                   kAXFocusedWindowAttribute as CFString, &window)
        return result == .success ? controlCenter.localizedName ?? "Control Center" : nil
    }

    /// Check whether the given app likely accepts pasted text.
    /// Uses a denylist approach: returns true unless the focused element is a known
    /// non-text role (button, table, list, etc.). Unknown roles (including Electron/Chromium
    /// custom elements) default to true so paste is attempted.
    /// Returns false only when there is no focused element or it's definitely not a text input.
    static func canLikelyPasteText(in app: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else { return true } // Can't check — assume yes

        guard let axElement = focusedTextElement(of: app) else {
            // Can't determine focused element — common in Electron/web apps (Slack, Discord,
            // VS Code, etc.) whose text inputs don't appear in the native AX tree.
            // Default to attempting paste rather than falling back to Record Window.
            return true
        }

        // Quick positive: if the value attribute is settable, it's definitely a text input
        var isSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            axElement,
            kAXValueAttribute as CFString,
            &isSettable
        )
        if settableResult == .success && isSettable.boolValue {
            return true
        }

        // Denylist: roles that definitely don't accept pasted text.
        // Everything NOT in this list (including unknown Electron roles) defaults to "try paste".
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)

        if let roleString = role as? String {
            let nonTextRoles: Set<String> = [
                kAXButtonRole as String,
                kAXCheckBoxRole as String,
                kAXRadioButtonRole as String,
                kAXMenuItemRole as String,
                kAXMenuBarRole as String,
                kAXMenuRole as String,
                kAXToolbarRole as String,
                kAXScrollBarRole as String,
                kAXImageRole as String,
                kAXStaticTextRole as String,
                kAXListRole as String,
                kAXOutlineRole as String,
                kAXTableRole as String,
                kAXBrowserRole as String,
                kAXTabGroupRole as String,
                kAXScrollAreaRole as String,
                kAXSplitGroupRole as String,
                kAXSplitterRole as String,
                kAXWindowRole as String,
            ]
            if nonTextRoles.contains(roleString) {
                return false
            }
        }

        // Unknown or unrecognized role — default to trying paste
        return true
    }

    /// Check if accessibility is granted
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }


    private static func simulatePasteCGEvent() {
        simulateCommandKey("v", name: "⌘V")
    }

    /// Posts ⌘ + `keyCode`. The flags are set outright, so a shortcut's ⌃⇧ still held
    /// down does not turn ⌘C into ⌘⌃⇧C.
    private static func simulateCommandKey(_ letter: Character, name: String) {
        simulateKey(commandKeyCode(for: letter), flags: .maskCommand, name: name)
    }

    /// The key that types `letter` while ⌘ is down in the keyboard layout in use. A
    /// virtual key code names a *position*: 0x09 is V on QWERTY and K on Dvorak, where a
    /// hard-coded ⌘V pastes nothing and a hard-coded ⌘X cuts nothing — or something else.
    /// The layout is asked with ⌘ held because that is the question: Ukrainian and
    /// "Dvorak – QWERTY ⌘" both answer with the QWERTY position then. Read on every call
    /// rather than cached; 128 table lookups cost nothing next to the paste. Falls back
    /// to the ANSI position when the layout has no such key or no layout data at all.
    private static func commandKeyCode(for letter: Character) -> CGKeyCode {
        let ansi: [Character: CGKeyCode] = ["c": 0x08, "v": 0x09, "x": 0x07]
        let fallback = ansi[letter] ?? 0
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return fallback
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
        let wanted = String(letter)
        let commandDown = UInt32(cmdKey >> 8) & 0xFF
        let found: CGKeyCode? = layoutData.withUnsafeBytes { ptr in
            guard let layout = ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            // The ANSI position first, so a layout that has the letter twice keeps it.
            for keyCode in [fallback] + (0..<128).map({ CGKeyCode($0) }) {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), commandDown,
                                            UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeyState, chars.count, &length, &chars)
                if status == noErr, length > 0,
                   String(utf16CodeUnits: chars, count: length).lowercased() == wanted {
                    return keyCode
                }
            }
            return nil
        }
        if let found, found != fallback {
            dlog("Paste", "⌘\(wanted.uppercased()) is key \(found) in this layout", level: .debug)
        }
        return found ?? fallback
    }

    /// Posts `keyCode` with exactly `flags` — none at all for a plain ⌫, whatever is
    /// physically held.
    private static func simulateKey(_ keyCode: CGKeyCode, flags: CGEventFlags, name: String) {
        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags

        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
        dlog("Paste", "CGEvent \(name) posted", level: .debug)
    }
}
