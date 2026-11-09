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
    /// In a terminal, what the cursor was talking to. Stored, unlike `kind`: a retry from
    /// History cannot look at the terminal again.
    public var terminalFocus: TerminalFocus?

    /// Long enough for a mail subject or a document path, short enough that a window
    /// title cannot turn into a second transcript.
    static let maxValueLength = 160

    public init(appName: String? = nil, bundleID: String? = nil,
         windowTitle: String? = nil, fieldLabel: String? = nil, terminalFocus: TerminalFocus? = nil) {
        self.appName = Self.clean(appName)
        self.bundleID = Self.clean(bundleID)
        self.windowTitle = Self.clean(windowTitle)
        self.fieldLabel = Self.clean(fieldLabel)
        self.terminalFocus = terminalFocus
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
    ///
    /// `foreground` is `TerminalFocus.foregroundJobs` for a terminal, read before the title
    /// is cut to `maxValueLength`, since Terminal keeps the job at its end.
    public static func capture(appName: String?, bundleID: String?, windowTitle: String?,
                        fieldLabels: [String?], isSecureField: Bool,
                        foreground: [[String]] = []) -> FocusContext? {
        if let bundleID, excludedBundleIDs.contains(bundleID) { return nil }

        var context = FocusContext(appName: appName, bundleID: bundleID)
        if context.kind == .terminal {
            context.terminalFocus = TerminalFocus.read(bundleID: bundleID, windowTitle: windowTitle, foreground: foreground)
        }
        if !isSecureField {
            context.windowTitle = clean(windowTitle)
            context.fieldLabel = fieldLabels.lazy.compactMap(clean).first
            // Browsers and editors often label the field with the window's own title.
            if context.fieldLabel == context.windowTitle { context.fieldLabel = nil }
        }
        return context.isEmpty ? nil : context
    }

    /// What kind of text the field takes, where the app or the field's label says so
    /// plainly: a prompt box for an AI, a code editor or a terminal. Text dictated into any
    /// of them is for that program, so AI Rewrite writes it down and does not carry it out
    /// (a shell prompt alone excepted, `commandWriting`; `RewriteModes`, docs/specs/2026-11-03-rewrite-modes-and-router.md D3). An app such
    /// as T3 Code is newer than any model's training, so its name alone said nothing, and a
    /// dictation into it came out as a chat message, or carried out, rather than as the
    /// prompt it was. Cursor's and VS Code's agent pane and editor are one app, which once
    /// kept them off the AI list; as editors they now get the same answer either way.
    enum Kind: Equatable {
        case aiPrompt
        case codeEditor
        case terminal
    }

    /// Apps whose text fields are prompts to an AI, by bundle identifier prefix, so every
    /// channel of one ("T3 Code (Alpha)", "(Beta)") counts.
    static let aiPromptBundleIDPrefixes = [
        "com.t3tools.t3code",
        "com.anthropic.claudefordesktop",
        "com.openai.chat",
        "com.openai.codex",
    ]

    /// Editors, by bundle identifier prefix. Read off the installed apps (Xcode, VS Code,
    /// PyCharm for JetBrains), else off each app's Homebrew cask (2026-11-05). Cursor's is
    /// the ID its packager gave it.
    static let codeEditorBundleIDPrefixes = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",             // and VSCodeInsiders
        "com.todesktop.230313mzl4w4u92",    // Cursor
        "com.jetbrains.",
        "dev.zed.Zed",                      // and Zed-Preview
        "com.sublimetext.",
        "com.panic.Nova",
    ]

    /// Terminals, by bundle identifier prefix, checked the same way (Terminal, iTerm2 and
    /// cmux installed; the rest from their casks, 2026-11-05).
    static let terminalBundleIDPrefixes = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.cmuxterm.app",
        "com.mitchellh.ghostty",
        "dev.warp.Warp",                    // Warp-Stable, Warp-Preview
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty",
    ]

    /// Apps where the plain text we paste is Markdown, by bundle identifier prefix: the
    /// fact D5's format rule turns on (#111). Checked 2026-11-09, each ID off the installed
    /// app, and listed only where the text itself is read as Markdown, however it got
    /// there: a Discord 0.0.412 message once sent ("Discord also uses Markdown for its
    /// message formatting", discord.com/blog), an Obsidian 1.12.7 note, whose file is
    /// Markdown (obsidian.md/help/syntax), T3 Code 0.1.7's composer, whose source is
    /// Markdown (the note in `SelectionEdit`, this repository's, not its maker's).
    /// Left out: Slack, whose markup is opt-in and `*bold*`, with no headings or tables,
    /// and whose page says "Messages that you copy and paste will appear in plain text"
    /// (slack.com/help/articles/360039953113); Notion, whose help documents shortcuts as
    /// typed and file import, not a paste; the prompt boxes of Claude and ChatGPT, of
    /// which neither maker says anything.
    static let markdownBundleIDPrefixes = [
        "com.hnc.Discord",                  // and DiscordPTB, DiscordCanary
        "com.t3tools.t3code",
        "md.obsidian",
    ]

    /// Whether Markdown means something where this text lands: an app on the list, or an
    /// editor whose window names a Markdown file. Goes only to the two-step path
    /// (`RewriteRouter`): the one-step prompt may not change before #114.
    var rendersMarkdown: Bool {
        if let bundleID, Self.markdownBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) { return true }
        return kind == .codeEditor && Self.namesMarkdownFile(windowTitle)
    }

    /// A word of the title that is a file name ending in `.md` or `.markdown`, wherever it
    /// sits: editors put the project after it ("README.md — speech-text") and marks before
    /// it ("● notes.md").
    private static func namesMarkdownFile(_ title: String?) -> Bool {
        guard let title else { return false }
        return title.split(whereSeparator: \.isWhitespace).contains { word in
            let name = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            return name.hasSuffix(".md") || name.hasSuffix(".markdown")
        }
    }

    /// Derived, never stored: `Refinement.context` is kept in History, and a record from
    /// before the kind existed reads the same as one after. An AI's prompt box is told
    /// apart first, so an agent pane labelled as one stays a prompt in `promptBlock`.
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
        guard let bundleID else { return nil }
        if Self.codeEditorBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) { return .codeEditor }
        if Self.terminalBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) { return .terminal }
        return nil
    }

    /// A field whose text is for another program — an editor, a terminal, an AI's prompt
    /// box — so an instruction in it is written down, never carried out (D3).
    public var takesTextForAnotherProgram: Bool { kind != nil }

    /// Whether AI Rewrite may write a shell command here (docs/decisions.md › *A command
    /// at a shell prompt*). A program in a terminal is told the user's words, so only the
    /// shell gets one unasked; where nothing says which, only the words "a command" do.
    var commandWriting: RewriteModes.CommandWriting {
        guard kind == .terminal else { return .never }
        switch terminalFocus {
        case .shellPrompt: return .atPrompt
        case .program: return .never
        case .unknown, nil: return .whenAsked
        }
    }

    /// Whether this is a terminal, the one kind `PasteService` reads processes for.
    public static func isTerminal(bundleID: String?) -> Bool {
        FocusContext(bundleID: bundleID).kind == .terminal
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
        // A terminal's title can be set by a remote host, and text from there has no place
        // beside a prompt that may write a command.
        if let windowTitle, kind != .terminal { lines.append("window: \(windowTitle)") }
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
