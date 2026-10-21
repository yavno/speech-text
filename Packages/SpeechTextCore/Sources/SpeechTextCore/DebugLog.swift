// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os
import os.log

/// Main-actor state behind a `nonisolated` front door: `log` is called from every
/// thread, `entries` is changed and read on main only.
@MainActor @Observable
public final class DebugLog {
    public nonisolated static let shared = DebugLog()

    public nonisolated init() {}

    /// How much an entry matters, in the system log's own levels. `notice` is what
    /// `os.Logger` calls `default`; there is no "warning" level.
    public enum Level: Int, Comparable, CaseIterable, Sendable {
        /// High-frequency detail (every partial, every posted key event): kept in the
        /// window only while `keepsDebugEntries` is on, and never persisted by the system
        /// log, which shows it only to a `log stream --debug` running at the time.
        case debug
        /// The default: what the app is doing.
        case info
        /// Something degraded but carrying on — a slow main thread, a late shortcut.
        case notice
        /// A failure: a request, a socket, a start, a permission.
        case error
        /// A state the code believes cannot happen.
        case fault

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        var osLogType: OSLogType {
            switch self {
            case .debug: .debug
            case .info: .info
            case .notice: .default
            case .error: .error
            case .fault: .fault
            }
        }

        /// The name in a copied line, padded so the messages line up.
        var label: String {
            switch self {
            case .debug: "DEBUG "
            case .info: "INFO  "
            case .notice: "NOTICE"
            case .error: "ERROR "
            case .fault: "FAULT "
            }
        }
    }

    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let timestamp: Date
        public let level: Level
        public let category: String
        public let message: String
    }

    public private(set) var entries: [Entry] = []
    private let maxEntries = 1000
    /// Trimming is O(n) in the whole buffer, so it is paid once per `trimSlack` entries
    /// rather than on every log line: the array is allowed to run over before it is cut
    /// back to `maxEntries`.
    private let trimSlack = 100
    /// Whether `.debug` entries are kept in the window's buffer. On in a debug build, off
    /// in a release, where they would push the failures out of the last 1000 lines; the
    /// Debug Log window's Debug lines switch turns them on for the session. Not stored:
    /// a release left keeping them would lose its history to partials. The system log
    /// gets every entry either way. Read on the main thread only.
    public var keepsDebugEntries: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    private nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "SpeechText"
    /// One `Logger` per dlog category, so Console and `log stream --predicate
    /// 'category == "ElevenLabs"'` can pick one out. Made on first use from any thread.
    private nonisolated static let loggers = OSAllocatedUnfairLock(initialState: [String: Logger]())

    private nonisolated static func logger(for category: String) -> Logger {
        loggers.withLock { loggers in
            if let logger = loggers[category] { return logger }
            let logger = Logger(subsystem: subsystem, category: category)
            loggers[category] = logger
            return logger
        }
    }

    private nonisolated static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    nonisolated func log(_ category: String, _ message: String, level: Level = .info) {
        let entry = Entry(timestamp: Date(), level: level, category: category, message: message)
        // The category stays in the text too: what reads `log stream` output by line
        // (scripts/e2e/check.py's `[App] stopRecording`) keeps finding it.
        Self.logger(for: category).log(level: level.osLogType,
                                       "[\(category, privacy: .public)] \(message, privacy: .public)")

        if Thread.isMainThread {
            MainActor.assumeIsolated { appendEntry(entry) }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.appendEntry(entry)
            }
        }
    }

    private func appendEntry(_ entry: Entry) {
        if entry.level == .debug && !keepsDebugEntries { return }
        entries.append(entry)
        if entries.count > maxEntries + trimSlack {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    /// Every entry, as Copy puts it on the clipboard.
    func formatted() -> String {
        Self.formatted(entries)
    }

    /// `12:03:04.567 ERROR  [Groq] message`, one per line — the Debug Log window's Copy
    /// writes a filtered list the same way.
    public nonisolated static func formatted(_ entries: [Entry]) -> String {
        entries.map {
            "\(dateFormatter.string(from: $0.timestamp)) \($0.level.label) [\($0.category)] \($0.message)"
        }.joined(separator: "\n")
    }

    /// The entries at `minimumLevel` or above whose category or message holds `query`,
    /// ignoring case — what the Debug Log window lists.
    public nonisolated static func filtered(_ entries: [Entry], minimumLevel: Level, matching query: String) -> [Entry] {
        let query = query.lowercased()
        return entries.filter {
            $0.level >= minimumLevel
                && (query.isEmpty
                    || $0.category.lowercased().contains(query)
                    || $0.message.lowercased().contains(query))
        }
    }

    public func clear() {
        entries.removeAll()
    }
}

/// Shorthand for logging from anywhere.
public func dlog(_ category: String, _ message: String, level: DebugLog.Level = .info) {
    DebugLog.shared.log(category, message, level: level)
}
