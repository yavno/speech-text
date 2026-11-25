// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What a terminal's cursor is talking to when an AI dictation starts: the shell, which
/// takes a command, or a program running in it, such as Claude Code, which takes the
/// user's words. AI Rewrite writes a command only at the first (docs/decisions.md ›
/// *A command at a shell prompt*).
///
/// Read from the window title and the process table, which need no permission of their
/// own. Measured on Terminal and cmux with zsh, claude, sleep, python, vim, tmux and ssh in
/// the tabs (2026-11-08). Pure, like `FocusContext.capture`: `PasteService` reads the raw
/// answers.
public enum TerminalFocus: String, Codable, Sendable {
    case shellPrompt
    case program
    /// Nothing here says which: a remote host or a multiplexer hides what runs behind it,
    /// and a process table does not say which of several tabs is in front.
    case unknown

    /// One process, as `foregroundJobs` needs it.
    public struct Process: Sendable {
        public var id: Int32
        public var parent: Int32
        public var group: Int32
        public var foregroundGroup: Int32
        /// The controlling terminal, nil for a process that has none.
        public var terminal: Int32?
        public var name: String

        public init(id: Int32, parent: Int32, group: Int32, foregroundGroup: Int32, terminal: Int32?, name: String) {
            self.id = id
            self.parent = parent
            self.group = group
            self.foregroundGroup = foregroundGroup
            self.terminal = terminal
            self.name = name
        }
    }

    private static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "tcsh", "csh", "fish", "nu", "pwsh", "elvish", "xonsh"]
    private static let opaque: Set<String> = ["ssh", "mosh", "mosh-client", "et", "tmux", "screen", "zellij"]

    /// The names in the foreground of each terminal device that `root` (the terminal app)
    /// opened: one list per tab, the group's leader first, with no way to tell from it
    /// which tab is in front.
    public static func foregroundJobs(of root: Int32, in processes: [Process]) -> [[String]] {
        let parents = Dictionary(processes.map { ($0.id, $0.parent) }, uniquingKeysWith: { first, _ in first })
        func descends(_ id: Int32) -> Bool {
            var current = id
            // A bound rather than a set: a process table read in one call has no cycle,
            // and init, the top of every chain, is its own end.
            for _ in 0..<64 {
                if current == root { return true }
                guard let parent = parents[current], parent != current else { return false }
                current = parent
            }
            return false
        }
        let foreground = processes.filter { $0.terminal != nil && $0.group == $0.foregroundGroup && descends($0.id) }
        return Dictionary(grouping: foreground, by: { $0.terminal ?? -1 })
            .sorted { $0.key < $1.key }
            .map { job in
                let leader = job.value.filter { $0.id == $0.group }
                return (leader + job.value.filter { $0.id != $0.group }).map(\.name)
            }
    }

    public static func read(bundleID: String?, windowTitle: String?, foreground: [[String]]) -> TerminalFocus {
        reading(bundleID: bundleID, windowTitle: windowTitle, foreground: foreground).focus
    }

    /// `read`, and for a `.program` the name of that program as the process table or
    /// Terminal's title gives it ("claude", "python3", "node" for a CLI Node runs), never
    /// its arguments: told to the model and kept in History (#275). Nil wherever the focus
    /// is not `.program`.
    public static func reading(bundleID: String?, windowTitle: String?, foreground: [[String]]) -> (focus: TerminalFocus, program: String?) {
        if bundleID?.hasPrefix("com.apple.Terminal") == true,
           let job = terminalAppJob(windowTitle) {
            let named = focus(ofJob: job)
            // The end of a title is Terminal's only where its profile shows the job, so a
            // shell the processes do not have is not believed.
            let aShellIsThere = foreground.isEmpty || foreground.contains { !$0.isEmpty && $0.map(commandName).allSatisfy(shells.contains) }
            if named != .shellPrompt || aShellIsThere {
                // Before the size the title is anyone's when the profile shows no job — a
                // remote shell's "user@host: ~" — so a name is kept only where the processes
                // have it and nothing in front of them hides a remote host.
                let names = foreground.joined().map(commandName)
                let program = named == .program && !names.contains(where: opaque.contains)
                    ? program(ofJob: job).flatMap { names.contains($0) ? $0 : nil } : nil
                return (named, program)
            }
        }
        let tabs = foreground.filter { !$0.isEmpty }.map { $0.map(commandName) }
        guard !tabs.isEmpty else { return (.unknown, nil) }
        let shellTabs = tabs.filter { $0.allSatisfy(shells.contains) }
        if shellTabs.count == tabs.count { return (.shellPrompt, nil) }
        if tabs.joined().contains(where: opaque.contains) { return (.unknown, nil) }
        // The group's leader comes first (`foregroundJobs`): the program the shell started,
        // not the `rg` or `git` it runs. A shell in front of its child ("zsh", "op") is
        // passed over.
        if tabs.count == 1 { return (.program, tabs[0].first { !shells.contains($0) }) }
        // Several tabs and only some at a prompt: the title is of the tab in front. cmux's
        // shell puts the directory there at a prompt and the command while one runs, so a
        // directory is a prompt; Claude Code writes its own. An ssh tab was ruled out
        // above, since a remote shell's title looks the same. A program that writes a path
        // as its own title would read as a prompt: nothing better says which tab is in
        // front (cmux's scripting has no tty and its CLI refuses outside processes), and
        // the cost is a command pasted, never run, where words were wanted.
        if bundleID?.hasPrefix("com.cmuxterm.app") == true, !shellTabs.isEmpty, isDirectoryTitle(windowTitle) {
            return (.shellPrompt, nil)
        }
        return (.unknown, nil)
    }

    /// Terminal ends a title with the active tab's job and its size: "hskv — -zsh — 80×24",
    /// "hskv — claude ▸ gh — 80×24". Read from the end, since all that comes before can be
    /// set by a program or a remote host ("fake — -zsh — 80×24 — sleep 4 — 80×24"). Nil
    /// when the profile leaves either out.
    private static func terminalAppJob(_ title: String?) -> String? {
        guard let parts = title?.components(separatedBy: " — "), parts.count >= 2,
              parts[parts.count - 1].range(of: #"^\d+×\d+$"#, options: .regularExpression) != nil else { return nil }
        return parts[parts.count - 2]
    }

    private static func focus(ofJob job: String) -> TerminalFocus {
        let name = commandName(job.components(separatedBy: " ")[0])
        if opaque.contains(name) { return .unknown }
        // "-zsh ▸ op": the shell has a child in front of it.
        return shells.contains(name) && !job.contains("▸") ? .shellPrompt : .program
    }

    /// The program of a job Terminal names: "claude ▸ gh" is claude running gh, "-zsh ▸ op"
    /// a shell in front of op.
    private static func program(ofJob job: String) -> String? {
        job.components(separatedBy: "▸").lazy
            .compactMap { $0.split(separator: " ").first.map { commandName(String($0)) } }
            .first { !shells.contains($0) }
    }

    /// "-zsh" and "-/bin/zsh" are login shells; the rest is the path.
    private static func commandName(_ raw: String) -> String {
        (raw.hasPrefix("-") ? String(raw.dropFirst()) : raw).components(separatedBy: "/").last ?? raw
    }

    private static func isDirectoryTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        return title.hasPrefix("…/") || title.hasPrefix("~") || title.hasPrefix("/")
            || title.range(of: #"^[^\s@]+@[^\s:]+:[~/]"#, options: .regularExpression) != nil
    }
}
