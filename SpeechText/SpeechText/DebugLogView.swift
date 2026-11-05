// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import SpeechTextCore

// MARK: - Debug Log View

struct DebugLogView: View {
    @State private var debugLog = DebugLog.shared
    @State private var autoScroll = true
    @State private var filterText = ""
    @State private var minimumLevel = DebugLog.Level.debug
    @AppStorage(SettingsKeys.recordDictationTraces) private var recordTraces = false

    private var filteredEntries: [DebugLog.Entry] {
        if filterText.isEmpty && minimumLevel == .debug { return debugLog.entries }
        return DebugLog.filtered(debugLog.entries, minimumLevel: minimumLevel, matching: filterText)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
        }
        .frame(minWidth: 650, minHeight: 400)
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "ladybug")
                .foregroundStyle(.secondary)
            Text("Debug Log")
                .font(.headline)

            TextField("Filter...", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            Picker("Show", selection: $minimumLevel) {
                Text("All").tag(DebugLog.Level.debug)
                Text("Hide debug").tag(DebugLog.Level.info)
                Text("Notices and above").tag(DebugLog.Level.notice)
                Text("Errors and faults").tag(DebugLog.Level.error)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Show levels")

            Spacer()

            Text("\(filteredEntries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Record traces", isOn: $recordTraces)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Save each streamed inline dictation to Traces/ so it can be replayed as a test. The words you dictate are saved there in plain text.")

            Button("Traces") {
                let directory = DictationTraceRecorder.directory
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(directory)
            }

            Toggle("Debug lines", isOn: $debugLog.keepsDebugEntries)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Keep debug lines — every partial, every key event posted — in this window. They push older lines out of the last 1000. On in a debug build; the system log gets them either way.")

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.switch)
                .controlSize(.small)

            Button("Copy") {
                let text = DebugLog.formatted(filteredEntries)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }

            Button("Clear") {
                debugLog.clear()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Log List

    @ViewBuilder
    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(formatTime(entry.timestamp))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 85, alignment: .leading)

                    levelMarker(entry.level)
                        .frame(width: 12)

                    Text(entry.category)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(categoryColor(entry.category))
                        .frame(width: 90, alignment: .leading)

                    Text(entry.message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(entry.level == .debug ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                .id(entry.id)
            }
            .listStyle(.plain)
            // The ring buffer caps at 1000 entries, so once it's full the count stays
            // put while entries still roll over — key on the newest id instead.
            .onChange(of: debugLog.entries.last?.id) {
                if autoScroll, let last = filteredEntries.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    /// A mark for the levels worth finding by eye; nothing for debug and info.
    @ViewBuilder
    private func levelMarker(_ level: DebugLog.Level) -> some View {
        switch level {
        case .debug, .info:
            Color.clear
                .accessibilityHidden(true)
        case .notice:
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.orange)
                .accessibilityLabel("Notice")
        case .error:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .accessibilityLabel("Error")
        case .fault:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.purple)
                .accessibilityLabel("Fault")
        }
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        // Recording pipeline
        case "Engine":      .blue
        case "Audio":       .green
        case "Span":        .cyan
        // Cloud STT/LLM providers
        case "Groq", "ElevenLabs": .orange
        // Local models
        case "LocalModel", "LocalWhisper": .brown
        // AI text refinement
        case "LLM", "Refine": .indigo
        // Delivery
        case "Paste":       .pink
        case "App":         .purple
        case "Settings":    .gray
        case "History":     .mint
        case "Hotkey":      .teal
        // Dictation traces
        case "Trace":       .yellow
        default:            .secondary
        }
    }
}

// MARK: - Dictation traces

extension DictationTraceRecorder {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.recordDictationTraces)
    }

    /// `Application Support/SpeechText/Traces` (`SpeechText-e2e/` in an end-to-end build). History is touched first: its rename
    /// migration moves a pre-rename folder into `SpeechText/` only while that does not
    /// exist yet, and creating `Traces/` would create it.
    static var directory: URL {
        _ = TranscriptionHistory.shared
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(E2EMode.supportFolderName, isDirectory: true)
            .appendingPathComponent("Traces", isDirectory: true)
    }
}

// MARK: - Debug Log Window

final class DebugLogWindow: NSWindow {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = String(localized: "SpeechText Debug Log")
        contentView = NSHostingView(rootView: DebugLogView())
        isReleasedWhenClosed = false
        center()
    }
}
