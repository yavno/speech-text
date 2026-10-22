// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where an AI dictation is going to land: the app, its window and the text field the
/// cursor was in when the recording started.
///
/// It is handed to the model as a hint for the *form* of the output — a reply in Slack
/// is a chat message, the same words in Mail are a letter — and never as instructions.
/// Every string in here was written by someone other than the user (an email subject, a
/// web page's title, a file name), so it is cleaned before it reaches a prompt and the
/// system prompt tells the model to treat it as data.
///
/// Pure logic, like `AXTextProbe`: `PasteService.readFocusContext` makes the Accessibility
/// calls and hands the raw answers to `capture`, which is what keeps the decisions about
/// what may be sent in SpeechTextCore, where the tests reach them.
public struct FocusContext: Codable, Equatable, Sendable {
    public var appName: String?
    public var bundleID: String?
    public var windowTitle: String?
    /// The field's placeholder, accessibility description or title — "Message #general".
    public var fieldLabel: String?

    /// Long enough for a mail subject or a document path, short enough that a window
    /// title cannot turn into a second transcript.
    static let maxValueLength = 160

    public init(appName: String? = nil, bundleID: String? = nil,
         windowTitle: String? = nil, fieldLabel: String? = nil) {
        self.appName = Self.clean(appName)
        self.bundleID = Self.clean(bundleID)
        self.windowTitle = Self.clean(windowTitle)
        self.fieldLabel = Self.clean(fieldLabel)
    }

    /// Apps whose windows are nobody's business but the user's. Nothing is read from
    /// them — not even the name, since "the user is in their password manager" is
    /// itself worth keeping off a third-party server.
    static let excludedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc",
        "com.sinnerschrader-mobile.strongbox",
    ]

    /// Builds the context from what the Accessibility API answered, or nil when there
    /// is nothing that may be sent.
    ///
    /// A secure text field keeps the app's name and loses everything else: the window
    /// around a password prompt ("Sign in to bank.example — alice@…") says more than the
    /// app does, and the model needs neither to clean up a dictation.
    public static func capture(appName: String?, bundleID: String?, windowTitle: String?,
                        fieldLabels: [String?], isSecureField: Bool) -> FocusContext? {
        if let bundleID, excludedBundleIDs.contains(bundleID) { return nil }

        var context = FocusContext(appName: appName, bundleID: bundleID)
        if !isSecureField {
            context.windowTitle = clean(windowTitle)
            context.fieldLabel = fieldLabels.lazy.compactMap(clean).first
            // Browsers and editors often label the field with the window's own title.
            if context.fieldLabel == context.windowTitle { context.fieldLabel = nil }
        }
        return context.isEmpty ? nil : context
    }

    /// What kind of text the field takes, where the app or the field's label says so
    /// plainly. Only one kind is told apart today: a prompt box for an AI. An app such as
    /// T3 Code is newer than any model's training, so its name alone said nothing, and a
    /// dictation into it came out as a chat message, or carried out, rather than as the
    /// prompt it was. Cursor and VS Code are left out on purpose: their agent pane and their
    /// editor are one app, and only the field could tell them apart.
    enum Kind: Equatable {
        case aiPrompt
    }

    /// Apps whose text fields are prompts to an AI, by bundle identifier prefix, so every
    /// channel of one ("T3 Code (Alpha)", "(Beta)") counts.
    static let aiPromptBundleIDPrefixes = [
        "com.t3tools.t3code",
        "com.anthropic.claudefordesktop",
        "com.openai.chat",
        "com.openai.codex",
    ]

    /// Derived, never stored: `Refinement.context` is kept in History, and a record from
    /// before the kind existed reads the same as one after.
    var kind: Kind? {
        if let bundleID, Self.aiPromptBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return .aiPrompt
        }
        // A chat page in a browser is known only by its field: "Write your prompt to
        // Claude", ChatGPT's "Ask anything".
        if let label = fieldLabel?.lowercased(),
           label.contains("prompt") || label.hasPrefix("ask anything") {
            return .aiPrompt
        }
        return nil
    }

    public var isEmpty: Bool {
        appName == nil && bundleID == nil && windowTitle == nil && fieldLabel == nil
    }

    /// The `<context>` block that goes in front of the transcript in the user message.
    public var promptBlock: String {
        var lines: [String] = []
        switch (appName, bundleID) {
        case let (name?, id?): lines.append("app: \(name) (\(id))")
        case let (name?, nil): lines.append("app: \(name)")
        case let (nil, id?): lines.append("app: \(id)")
        case (nil, nil): break
        }
        if let windowTitle { lines.append("window: \(windowTitle)") }
        if let fieldLabel { lines.append("field: \(fieldLabel)") }
        // Ours, not read off the screen, so it is a fact the model may lean on.
        if kind == .aiPrompt { lines.append("kind: a prompt to an AI assistant") }
        return "<context>\n\(lines.joined(separator: "\n"))\n</context>"
    }

    /// One line for History and the Debug Log: "Slack — #backend". The app's own name is
    /// said once: a window titled just that ("Claude") adds nothing, and the browsers'
    /// "Page - Google Chrome – Profile" keeps only the page. The model is still told the
    /// title as the app wrote it (`promptBlock`); this is only how it is shown.
    public var summary: String {
        let app = appName ?? bundleID
        let place = [windowTitle, fieldLabel].lazy
            .compactMap { $0.flatMap { Self.withoutAppName($0, app: app) } }
            .first
        return [app, place].compactMap { $0 }.joined(separator: " — ")
    }

    /// The title with the app's name taken off its end, or nil when nothing else is left.
    private static func withoutAppName(_ title: String, app: String?) -> String? {
        var text = title.trimmingCharacters(in: .whitespaces)
        if let app, !app.isEmpty {
            for dash in [" - ", " – ", " — "] {
                if let range = text.range(of: dash + app, options: [.caseInsensitive, .backwards]) {
                    text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            if text.caseInsensitiveCompare(app) == .orderedSame { return nil }
        }
        return text.isEmpty ? nil : text
    }

    /// One line, no angle brackets, bounded. Angle brackets are replaced rather than
    /// escaped: a window titled `</context><transcript>…` must not be able to close the
    /// block it sits in, and the model reads ‹ › just as well.
    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        var text = value
            .replacingOccurrences(of: "<", with: "‹")
            .replacingOccurrences(of: ">", with: "›")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        if text.count > maxValueLength {
            text = String(text.prefix(maxValueLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return text
    }
}
