// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os.log

private let histLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SpeechText",
                             category: "History")

// MARK: - Record

public struct TranscriptionRecord: Identifiable, Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case success
        case empty
        case failed
    }

    /// The LLM pass, when the dictation went through one. `text` always stays the raw
    /// transcription, so both versions survive and can be compared after the fact.
    public struct Refinement: Codable, Equatable, Sendable {
        /// What was actually sent to the model. Usually equals the record's `text`, but
        /// the Record Window refines its whole text area, which can span several
        /// segments and manual edits — so it is stored rather than assumed.
        public var inputText: String
        public var outputText: String
        /// Preset the model routed to, when it reported one on the `<<mode:…>>` line.
        public var presetName: String?
        public var provider: String
        public var model: String
        /// Set when the LLM step failed; the raw transcription was used instead.
        public var errorMessage: String?
        /// The app, window and field the model was told the text was for. Nil for the
        /// Record Window, for entries older than the setting, and when it was off.
        public var context: FocusContext? = nil
        /// The Edit shortcut's rewrite of text selected in another app: `inputText` is the
        /// selection, and the record's `text` the spoken instruction ("" with none).
        var editsSelection: Bool? = nil
        /// The tokens the provider billed for the pass, when it reported them — what Usage
        /// prices. Nil for a pass that never got a reply, and for entries written before
        /// it was kept, which Usage estimates from their words.
        var usage: ChatUsage? = nil

        public var isSelectionEdit: Bool { editsSelection == true }
        public var succeeded: Bool { errorMessage == nil && !outputText.isEmpty }
    }

    public let id: UUID
    public let date: Date
    public var text: String
    public var status: Status
    public var errorMessage: String?
    /// The speech engine's `STTProviderType` raw value. A retry that succeeds rewrites
    /// it with the engine that transcribed it then. `noSpeechProvider` for an edit sent
    /// with no spoken instruction, which no engine heard.
    public var provider: String
    public let locale: String?
    public let duration: TimeInterval
    /// The speech within `duration`, from the first word to the last — the silence before
    /// and after left out, a pause between words kept (`VoiceActivityReading.voicedSpanSeconds`).
    /// What Usage divides the words by; nil for a record from before it was kept, and
    /// whenever the voice detector could not read the segment, which then counts whole.
    public var speakingDuration: TimeInterval? = nil
    /// Filename (not a full path — the container may move) of the archived audio kept
    /// so a failed transcription can be retried instead of being lost.
    var audioFileName: String?
    /// Optional, so history written before AI mode existed still decodes.
    public var refinement: Refinement?
    /// The app an inline dictation started in, and the one it was pasted into — the app
    /// in front at the stop. Nil for the Record Window, for an edit, and for entries
    /// written before the stop chose where the text went.
    public var originApp: String?
    public var destinationApp: String?
    /// The speech model's ID (`STTModelDescriptor.id`) — the one selected, for a stream
    /// that fell back to its upload too. Nil for entries written before it was kept, which
    /// Usage then names by their engine alone.
    public var sttModel: String?
    /// Every request this record cost (`UsageEvent`), oldest first. Nil for records
    /// written before the ledger was kept, which Usage prices the old way; empty for one
    /// that sent nothing anywhere — Apple, a model on this Mac, or a silent segment.
    public var usageEvents: [UsageEvent]?
    /// The bundle identifiers of `originApp` and `destinationApp`, so an app's icon is
    /// still found after it is renamed or moved (`AppIdentity`). Nil for entries written
    /// before they were kept, which are looked up by name alone.
    var originBundleID: String?
    var destinationBundleID: String?
    /// Set when the dictation was saved for want of a network: nothing was pasted at its
    /// stop, and nothing is pasted later either — it waits here, transcribed by itself once
    /// the network is back, for the user to copy. Kept after that, so the row still says it
    /// never reached its app. Nil for every other record, and for those from before it.
    public var undelivered: Undelivered? = nil

    /// Where a dictation saved offline was going, and whether AI Rewrite was to rewrite it.
    public struct Undelivered: Codable, Equatable, Sendable {
        /// The app in front at the stop — where it would have been pasted. Nil for the
        /// Record Window's segments, and for an inline dictation whose stop named none.
        public var app: String?
        var bundleID: String?
        /// Made with the AI shortcut: a retry rewrites it too, told `context`.
        public var rewrite: Bool
        /// What AI Rewrite would have been told about where the text was going, read at
        /// the stop as for any AI dictation (`FocusContext.capture`'s exclusions applied).
        public var context: FocusContext?

        public init(app: String? = nil, bundleID: String? = nil, rewrite: Bool = false,
                    context: FocusContext? = nil) {
            self.app = app
            self.bundleID = bundleID
            self.rewrite = rewrite
            self.context = context
        }
    }

    public var isRetryable: Bool { audioFileName != nil && status != .success }

    /// A retry of this record runs AI Rewrite after the transcription: it was dictated
    /// with the AI shortcut and saved offline before the rewrite could run.
    public var retryRewrites: Bool { undelivered?.rewrite == true }

    /// The `provider` of an edit sent with no instruction (a double press): nothing was
    /// recorded, so no engine heard anything and Usage counts no speech for it.
    static let noSpeechProvider = "edit"

    /// Whether a speech engine heard anything for this record.
    public var hasSpeech: Bool { provider != Self.noSpeechProvider }

    /// What the user actually received — the refined text when the LLM pass worked,
    /// otherwise the raw transcription.
    public var deliveredText: String {
        guard let refinement, refinement.succeeded else { return text }
        return refinement.outputText
    }
}

// MARK: - Usage ledger

/// One request to a vendor, as metering counts it: what was sent and what the vendor
/// said it billed. A record keeps one per request in `usageEvents` — a stream and the
/// upload it fell back to are two, a retry is another, a rewrite another — so Usage
/// counts the work that was paid for, not the one result that survived. Prices are not
/// stored: the units are, and Usage prices them.
public struct UsageEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A segment's file upload — including a stream's fallback.
        case upload
        /// A realtime socket, reconnects included.
        case stream
        /// History's retry of an archived recording.
        case retry
        /// AI Rewrite, or the Record Window's ✨.
        case rewrite
        /// The Edit shortcut's rewrite of a selection.
        case edit

        /// A speech request — priced by its audio, whatever else its reply reported
        /// (OpenAI's token-billed transcriptions carry tokens too).
        public var isSpeech: Bool { self == .upload || self == .stream || self == .retry }
    }

    let date: Date
    public let kind: Kind
    /// The vendor actually called — Groq for an Apple session's upload.
    public let vendor: Provider
    public let model: String
    /// The vendor answered, whatever the answer held — for a stream, the socket did not
    /// break; one that answered with nothing still counts, as its fallback upload is
    /// what shows it was paid for twice.
    public let succeeded: Bool
    /// Audio sent, in seconds; nil for a chat request.
    public var audioSeconds: Double? = nil
    /// The vendor's own figure, or its documented minimum (`UsageMeter`); nil when
    /// neither is known — then only `audioSeconds` is.
    public var billedSeconds: Double? = nil
    /// A chat request's tokens, or a token-billed transcription's.
    public var tokens: ChatUsage? = nil
    /// Terms sent with a speech request (ElevenLabs bills a surcharge for them).
    var keyterms: Int? = nil
    /// Seconds from sending the request to its answer.
    public var latency: Double? = nil
}

// MARK: - Store

/// Main-actor, as every view and the engine that write it are; the file is written on
/// `ioQueue`, which reaches nothing of the store but the paths and `unreadableCopyOwed`.
@MainActor @Observable
public final class TranscriptionHistory {
    public static let shared = TranscriptionHistory()

    /// Newest first.
    public private(set) var records: [TranscriptionRecord] = []

    /// How long History keeps dictations (`SettingsKeys.historyRetention`): forever until
    /// the user chooses otherwise. Entries it lets go take their archived audio with them.
    public var retention: HistoryRetention {
        HistoryRetention.stored(UserDefaults.standard.string(forKey: SettingsKeys.historyRetention))
    }
    /// How long a failed dictation's audio is kept for a retry (`SettingsKeys.failedAudioRetention`):
    /// a week until the user chooses otherwise.
    public var audioRetention: HistoryRetention {
        HistoryRetention.stored(UserDefaults.standard.string(forKey: SettingsKeys.failedAudioRetention),
                                default: .defaultAudio)
    }
    /// When this run of the app began — what *Don't keep* keeps from.
    let sessionStart = Date()

    private let ioQueue = DispatchQueue(label: "app.speech-text.SpeechText.history.io")
    /// The write scheduled by the last mutation, or nil when nothing is pending.
    /// Main-thread-only, like `records`.
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    /// How long a burst of mutations is allowed to coalesce into one write.
    private let saveCoalescingDelay: TimeInterval = 0.25
    /// The entries of `history.json` this build cannot decode, kept as they were read and
    /// written back with every save (`HistoryFile`). Main-thread-only, like `records`.
    /// Retention leaves them alone — the build that can read them applies it at its own
    /// launch — while Clear History, which asks first, takes them with everything else.
    @ObservationIgnored private var undecodable: [UndecodableRecord] = []
    /// `history.json` was there but could not be read at all, so a copy of it is owed before
    /// a write replaces it. Set by `load()` before any write is queued; after that read and
    /// cleared on `ioQueue` only, which is what makes the unchecked access safe.
    @ObservationIgnored private nonisolated(unsafe) var unreadableCopyOwed = false

    private init() {
        adoptPreRenameStore()
        load()
        // A span of time lets entries go as the days pass, not only when one is added.
        applyRetention()
    }

    // MARK: Paths

    private nonisolated var baseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(E2EMode.supportFolderName, isDirectory: true)
    }

    /// Folder names this app kept its history under before, newest first: it shipped as
    /// VoicePeter, then under the misspelled SpeachText. Move the newest one that still
    /// exists across, once, so a rename doesn't silently look like data loss.
    private static let preRenameStoreNames = ["SpeachText", "VoicePeter"]

    private func adoptPreRenameStore() {
        let fm = FileManager.default
        guard !E2EMode.isActive, !fm.fileExists(atPath: baseDirectory.path) else { return }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in Self.preRenameStoreNames {
            let legacy = support.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: legacy.path) else { continue }
            do {
                try fm.moveItem(at: legacy, to: baseDirectory)
                histLog.info("migrated history store from \(name, privacy: .public) to SpeechText")
            } catch {
                histLog.error("could not migrate history store: \(error.localizedDescription)")
            }
            return
        }
    }

    private nonisolated var historyFileURL: URL {
        baseDirectory.appendingPathComponent("history.json")
    }

    private nonisolated var recordingsDirectory: URL {
        baseDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// What History takes on disk: its file and the audio kept for retries.
    public func diskBytes() -> Int64 {
        let fm = FileManager.default
        func size(_ url: URL) -> Int64 {
            (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).flatMap { $0 }
                .map(Int64.init) ?? 0
        }
        let audio = (try? fm.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]))
            ?? []
        let files = [historyFileURL] + HistoryFile.unreadableCopies(of: historyFileURL)
        return (files + audio).reduce(0) { $0 + size($1) }
    }

    /// Full path of the archived audio for a record, if it still exists on disk.
    public func audioURL(for record: TranscriptionRecord) -> URL? {
        guard let name = record.audioFileName else { return nil }
        let url = recordingsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private nonisolated func ensureDirectories() {
        try? FileManager.default.createDirectory(at: recordingsDirectory,
                                                 withIntermediateDirectories: true)
    }

    // MARK: Recording outcomes

    /// Returns the new record's id so a later LLM pass can be attached to this entry.
    @discardableResult
    public func recordSuccess(text: String, provider: String, model: String? = nil, locale: String?,
                       duration: TimeInterval, speakingDuration: TimeInterval? = nil,
                       usage: [UsageEvent] = []) -> UUID {
        let id = UUID()
        add(TranscriptionRecord(id: id, date: Date(), text: text, status: .success,
                                errorMessage: nil, provider: provider, locale: locale,
                                duration: duration, speakingDuration: speakingDuration,
                                audioFileName: nil, sttModel: model, usageEvents: usage))
        return id
    }

    /// The speech in a record the detector read after it was written (an Apple segment).
    public func recordSpeakingDuration(id: UUID, _ seconds: TimeInterval) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].speakingDuration = seconds
        save()
    }

    /// Where an inline dictation started and where it was pasted.
    public func recordApps(id: UUID, origin: String?, originBundleID: String? = nil,
                    destination: String?, destinationBundleID: String? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].originApp = origin
        records[index].destinationApp = destination
        records[index].originBundleID = originBundleID
        records[index].destinationBundleID = destinationBundleID
        save()
    }

    // MARK: LLM pass

    /// Attaches the result of the AI step to an existing transcription entry.
    public func recordRefinement(id: UUID, input: String, output: String, presetName: String?,
                          provider: String, model: String, context: FocusContext? = nil,
                          usage: ChatUsage? = nil, latency: Double? = nil) {
        updateRefinement(id: id, TranscriptionRecord.Refinement(
            inputText: input, outputText: output, presetName: presetName,
            provider: provider, model: model, errorMessage: nil, context: context, usage: usage
        ), latency: latency)
    }

    /// Records that the AI step was attempted and failed. Worth keeping: the pasted text
    /// silently differs from what the user asked for, and the entry explains why.
    /// `usage`: a reply that came back and was refused by us (the Record Window's collapse
    /// guard) was still billed.
    public func recordRefinementFailure(id: UUID, input: String, error: String,
                                 provider: String, model: String, context: FocusContext? = nil,
                                 usage: ChatUsage? = nil, latency: Double? = nil) {
        updateRefinement(id: id, TranscriptionRecord.Refinement(
            inputText: input, outputText: "", presetName: nil,
            provider: provider, model: model, errorMessage: error, context: context, usage: usage
        ), latency: latency)
    }

    /// The Edit shortcut's rewrite. It belongs to the spoken instruction's record when
    /// there was one (`recordID`); an edit with no instruction gets a record of its own,
    /// whose text — the instruction — is empty.
    public func recordSelectionEdit(recordID: UUID?, selection: String, output: String, error: String?,
                             presetName: String?, provider: String, model: String,
                             context: FocusContext?, usage: ChatUsage? = nil, latency: Double? = nil) {
        let refinement = TranscriptionRecord.Refinement(
            inputText: selection, outputText: output, presetName: presetName,
            provider: provider, model: model, errorMessage: error, context: context,
            editsSelection: true, usage: usage)
        if let recordID, records.contains(where: { $0.id == recordID }) {
            updateRefinement(id: recordID, refinement, latency: latency)
            return
        }
        var record = TranscriptionRecord(id: UUID(), date: Date(), text: "", status: .success,
                                         errorMessage: nil, provider: TranscriptionRecord.noSpeechProvider, locale: nil,
                                         duration: 0, audioFileName: nil, usageEvents: [])
        record.refinement = refinement
        record.usageEvents?.append(contentsOf: Self.chatEvent(for: refinement, latency: latency).map { [$0] } ?? [])
        add(record)
    }

    /// The pass written onto the record, and its request onto the record's ledger — which
    /// a later retry's cleared refinement cannot take back: it was billed all the same.
    /// A record from before the ledger (`usageEvents == nil`) gets no entries at all:
    /// one entry would make Usage price it from the ledger alone and lose its speech.
    private func updateRefinement(id: UUID, _ refinement: TranscriptionRecord.Refinement, latency: Double?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            histLog.info("refinement for unknown record \(id.uuidString, privacy: .public) — dropped")
            return
        }
        records[index].refinement = refinement
        if let event = Self.chatEvent(for: refinement, latency: latency) {
            records[index].usageEvents?.append(event)
        }
        save()
    }

    /// The ledger entry for an LLM pass. A pass that got a reply counts as answered,
    /// even one refused afterwards (the Record Window's collapse guard); one with no
    /// reply — a missing key, an HTTP error — sent no tokens anyone billed. Nil when the
    /// provider is one History cannot name.
    nonisolated static func chatEvent(for refinement: TranscriptionRecord.Refinement, latency: Double?,
                          date: Date = Date()) -> UsageEvent? {
        guard let vendor = LLMProviderType(rawValue: refinement.provider)?.vendor else { return nil }
        return UsageEvent(date: date, kind: refinement.isSelectionEdit ? .edit : .rewrite, vendor: vendor,
                          model: refinement.model, succeeded: refinement.usage != nil || refinement.succeeded,
                          tokens: refinement.usage, latency: latency)
    }

    /// Records a failure and *keeps* the audio so the user can retry it. Passing the temp
    /// audio file here transfers ownership — do not call `AudioBufferWriter.cleanup` on it after.
    /// Returns the new record's id, so a failure the user can retry can name its row.
    /// `offline`: the failure was the network's and `OfflineRetry` will retry it (never an
    /// Edit instruction or a Try it dictation) — the record is marked `undelivered`, which
    /// the inline flow then fills in with where the text was going.
    @discardableResult
    public func recordFailure(error: String, provider: String, model: String? = nil, locale: String?,
                       duration: TimeInterval, audioURL: URL?, usage: [UsageEvent] = [],
                       offline: Bool = false) -> UUID {
        let archived = archive(audioURL: audioURL)
        let id = UUID()
        add(TranscriptionRecord(id: id, date: Date(), text: "", status: .failed,
                                errorMessage: error, provider: provider, locale: locale,
                                duration: duration, audioFileName: archived, sttModel: model, usageEvents: usage,
                                undelivered: offline ? TranscriptionRecord.Undelivered() : nil))
        return id
    }

    /// Where a dictation saved offline was going (`TranscriptionRecord.Undelivered`) — the
    /// inline flow's half of the mark `recordFailure(offline:)` set.
    public func recordUndelivered(id: UUID, _ undelivered: TranscriptionRecord.Undelivered) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].undelivered = undelivered
        save()
    }

    public func record(id: UUID) -> TranscriptionRecord? {
        records.first { $0.id == id }
    }

    /// Transcription succeeded technically but produced no words. Audio is kept too —
    /// an empty result is often a provider hiccup worth retrying.
    public func recordEmpty(provider: String, model: String? = nil, locale: String?, duration: TimeInterval, audioURL: URL?,
                     usage: [UsageEvent] = []) {
        let archived = archive(audioURL: audioURL)
        add(TranscriptionRecord(id: UUID(), date: Date(), text: "", status: .empty,
                                errorMessage: nil, provider: provider, locale: locale,
                                duration: duration, audioFileName: archived, sttModel: model, usageEvents: usage))
    }

    /// Replace a failed record's outcome after a successful retry.
    /// `provider` and `model`: the engine the retry went to — the current settings', not
    /// the recording's — so Usage counts and prices the work where it was done.
    /// `event`: the retry's own request, added to the ledger — the attempts before it
    /// were billed too, and stay. Not added to a record from before the ledger, which
    /// Usage keeps pricing the old way.
    public func markRetrySucceeded(id: UUID, text: String, provider: String? = nil, model: String? = nil,
                            event: UsageEvent? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var record = records[index]
        if let event { record.usageEvents?.append(event) }
        // The audio has served its purpose — reclaim the disk.
        if let url = audioURL(for: record) {
            try? FileManager.default.removeItem(at: url)
        }
        record.text = text
        record.status = .success
        record.errorMessage = nil
        record.audioFileName = nil
        if let provider {
            record.provider = provider
            record.sttModel = model
        }
        // The old refinement described text that no longer exists.
        record.refinement = nil
        records[index] = record
        save()
    }

    public func markRetryFailed(id: UUID, error: String, event: UsageEvent? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].errorMessage = error
        if let event { records[index].usageEvents?.append(event) }
        save()
    }

    // MARK: Mutation

    private func add(_ record: TranscriptionRecord) {
        records.insert(record, at: 0)
        trim(to: retention)
        histLog.info("recorded \(record.status.rawValue, privacy: .public) entry, \(record.text.count) chars")
        save()
    }

    /// How many entries `retention` would let go right now — what Settings asks about
    /// before a shorter choice deletes them.
    public func droppedCount(under retention: HistoryRetention) -> Int {
        records.count - retention.keptCount(of: records, sessionStart: sessionStart)
    }

    /// How many failed dictations' audio `audioRetention` would delete right now.
    public func droppedAudioCount(under audioRetention: HistoryRetention) -> Int {
        expiredAudio(under: audioRetention, sessionStart: sessionStart).count
    }

    /// Lets go of what the stored choices no longer keep — at launch, and once the user has
    /// agreed to a shorter one in Settings.
    public func applyRetention() {
        let trimmed = trim(to: retention)
        if pruneExpiredAudio(sessionStart: sessionStart) || trimmed { save() }
    }

    /// At quit: what *Don't keep* kept for this session goes now.
    public func applyRetentionAtQuit() {
        let quitting = Date.distantFuture
        let trimmed = trim(to: retention, sessionStart: quitting)
        if pruneExpiredAudio(sessionStart: quitting) || trimmed { save() }
    }

    @discardableResult
    private func trim(to retention: HistoryRetention, sessionStart: Date? = nil) -> Bool {
        let kept = retention.keptCount(of: records, sessionStart: sessionStart ?? self.sessionStart)
        guard kept < records.count else { return false }
        records[kept...].forEach(deleteAudio)
        records.removeLast(records.count - kept)
        return true
    }

    public func delete(_ record: TranscriptionRecord) {
        deleteAudio(record)
        records.removeAll { $0.id == record.id }
        save()
    }

    /// Everything goes: the entries this build cannot read too, and any unreadable file
    /// copied aside — Clear History asks first, and means every dictation on this Mac.
    public func clear() {
        records.forEach(deleteAudio)
        records.removeAll()
        undecodable.forEach { deleteAudio(named: $0.audioFileName) }
        undecodable.removeAll()
        let url = historyFileURL
        // On the queue, behind any write in flight, so no copy is made after this.
        ioQueue.async { [weak self] in
            self?.unreadableCopyOwed = false
            HistoryFile.unreadableCopies(of: url).forEach { try? FileManager.default.removeItem(at: $0) }
        }
        save()
    }

    private func deleteAudio(_ record: TranscriptionRecord) {
        guard let url = audioURL(for: record) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// An entry this build cannot decode names its audio only as its JSON did, so a name
    /// that is not a bare file name is left alone.
    private func deleteAudio(named name: String?) {
        guard let name, !name.isEmpty, !name.contains("/") else { return }
        try? FileManager.default.removeItem(at: recordingsDirectory.appendingPathComponent(name))
    }

    // MARK: Audio archive

    /// Move a temp audio file into the archive. Returns the stored filename, or nil if
    /// there was no audio or the move failed (in which case the record is still kept).
    /// The file keeps its extension (`.flac` normally, `.wav` on the writer's fallback
    /// and for entries archived before FLAC uploads existed): the retry path reads the
    /// MIME type off it, so the archive must not rename everything to one container.
    private func archive(audioURL: URL?) -> String? {
        guard let audioURL, FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
        ensureDirectories()

        let ext = audioURL.pathExtension.isEmpty ? "wav" : audioURL.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let destination = recordingsDirectory.appendingPathComponent(filename)
        do {
            try FileManager.default.moveItem(at: audioURL, to: destination)
            dlog("History", "archived audio for retry: \(filename)")
            return filename
        } catch {
            histLog.error("archive failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: audioURL)
            return nil
        }
    }

    /// The records whose archived audio `audioRetention` no longer keeps.
    private func expiredAudio(under audioRetention: HistoryRetention, sessionStart: Date) -> [Int] {
        guard let cutoff = audioRetention.cutoff(sessionStart: sessionStart) else { return [] }
        return records.indices.filter { records[$0].audioFileName != nil && records[$0].date < cutoff }
    }

    @discardableResult
    private func pruneExpiredAudio(sessionStart: Date) -> Bool {
        let expired = expiredAudio(under: audioRetention, sessionStart: sessionStart)
        for index in expired {
            deleteAudio(records[index])
            records[index].audioFileName = nil
        }
        return !expired.isEmpty
    }

    // MARK: Persistence

    private func load() {
        switch HistoryFile.read(historyFileURL) {
        case .missing:
            break
        case .unreadable(let reason):
            unreadableCopyOwed = true
            histLog.error("history file unreadable (\(reason, privacy: .public)); it is copied aside before the first write replaces it")
        case .read(let contents):
            records = contents.records
            undecodable = contents.undecodable
            let kept = contents.undecodable.count
            if kept > 0 {
                histLog.error("\(kept) history entries this build cannot decode are kept as they are")
            }
        }
    }

    /// Schedules one write for a burst of mutations.
    ///
    /// A single dictation mutates the store several times (the record, the apps it went
    /// between, its refinement), and each write re-encodes every entry kept. The pending write is
    /// cancelled and re-scheduled instead of stacking, so a burst costs one encode. The
    /// snapshot is taken when the write *fires*, so it is always the latest state.
    ///
    /// `records` and `pendingSave` are both main-actor state, so a burst never races its write.
    private func save() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.writeNow(records: self.records)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveCoalescingDelay, execute: work)
    }

    /// Writes any pending change immediately, on the calling thread. Called at
    /// termination, where an asynchronous write would not land before the process exits.
    public func flush() {
        if let work = pendingSave {
            work.cancel()
            pendingSave = nil
            writeNow(records: records, synchronously: true)
        } else {
            // Nothing pending, but a write scheduled a moment ago may still be in flight.
            ioQueue.sync {}
        }
    }

    private func writeNow(records snapshot: [TranscriptionRecord], synchronously: Bool = false) {
        let url = historyFileURL
        let kept = undecodable
        let write: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.ensureDirectories()
            self.unreadableCopyOwed = HistoryFile.write(snapshot, keeping: kept, to: url,
                                                        copyingUnreadableFirst: self.unreadableCopyOwed)
        }
        if synchronously { ioQueue.sync(execute: write) } else { ioQueue.async(execute: write) }
    }
}

// MARK: - The file

/// A `history.json` entry this build cannot decode — a status, a vendor or a ledger kind a
/// newer build added, say — kept as the bytes it was read as, so a save writes it back
/// unchanged and the build that wrote it finds it again.
struct UndecodableRecord: Equatable {
    /// The element exactly as it stood in the file.
    let json: Data
    /// Where it goes among the records, which are newest first: its own `date` where that
    /// can be read, else the place of the element before it in the file.
    let place: Date
    /// Its archived audio, where that can be read — what Clear History deletes with it.
    let audioFileName: String?
}

/// `history.json`, read and written one entry at a time. Decoded whole, as it was, one
/// entry this build could not decode sank all of them, and the next dictation's save
/// replaced the file with that one dictation — while a ⌘R build of an older branch shares
/// the folder with the installed app, and `rebuild.sh --rollback` installs an older build.
/// Skipping such entries alone would only move the loss: the older build's next save would
/// delete exactly the entries it skipped. So they are kept as they were read and written
/// back where they stood.
enum HistoryFile {
    struct Contents: Equatable {
        var records: [TranscriptionRecord] = []
        var undecodable: [UndecodableRecord] = []
    }

    enum Reading: Equatable {
        /// No file (or an empty one) — a fresh start.
        case missing
        /// A file that is not a JSON array at all — truncated, overwritten, or one the disk
        /// would not give up. Copied aside before the first write replaces it.
        case unreadable(reason: String)
        case read(Contents)
    }

    static func read(_ url: URL) -> Reading {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return isNoSuchFile(error) ? .missing : .unreadable(reason: error.localizedDescription)
        }
        guard !data.isEmpty else { return .missing }
        guard let contents = decode(data) else { return .unreadable(reason: "not a JSON array") }
        return .read(contents)
    }

    /// The records, and every element that does not decode as one kept verbatim; nil when
    /// `data` is not a JSON array at all. The whole array is tried first — what every file
    /// is, so loading costs what it always did.
    static func decode(_ data: Data) -> Contents? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let records = try? decoder.decode([TranscriptionRecord].self, from: data) {
            return Contents(records: records)
        }
        let bytes = [UInt8](data)
        guard let elements = elementRanges(in: bytes) else { return nil }
        var contents = Contents()
        var previous = Date.distantFuture
        for range in elements {
            let element = Data(bytes[range])
            if let record = try? decoder.decode(TranscriptionRecord.self, from: element) {
                contents.records.append(record)
                previous = record.date
                continue
            }
            // Kept only if it is JSON, so that what is written back still parses.
            guard (try? JSONSerialization.jsonObject(with: element, options: .fragmentsAllowed)) != nil else {
                return nil
            }
            let placement = try? decoder.decode(Placement.self, from: element)
            let place = placement?.date ?? previous
            contents.undecodable.append(UndecodableRecord(json: element, place: place,
                                                          audioFileName: placement?.audioFileName))
            previous = place
        }
        return contents
    }

    /// The file's bytes: the records as `JSONEncoder` writes them — exactly what it wrote
    /// before, when nothing is kept — with every undecodable entry spliced back in verbatim,
    /// placed by date among the records, newest first. A merge rather than a sort, so the
    /// records keep their order and the kept entries theirs. Keys are sorted: unsorted,
    /// `JSONEncoder` writes an object's keys in hash order, which can differ between two
    /// encodings of equal records, so the same History could be written as other bytes.
    static func encode(_ records: [TranscriptionRecord], keeping undecodable: [UndecodableRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(records)
        guard !undecodable.isEmpty else { return encoded }
        let bytes = [UInt8](encoded)
        guard let ranges = elementRanges(in: bytes), ranges.count == records.count else {
            throw CocoaError(.coderInvalidValue)
        }
        var elements: [ArraySlice<UInt8>] = []
        elements.reserveCapacity(records.count + undecodable.count)
        var next = 0
        for entry in undecodable {
            while next < records.count, records[next].date >= entry.place {
                elements.append(bytes[ranges[next]])
                next += 1
            }
            elements.append(ArraySlice(entry.json))
        }
        elements.append(contentsOf: ranges[next...].map { bytes[$0] })
        // Laid out as `JSONEncoder` lays out an array, so the file reads as it always did.
        var data = Data("[\n".utf8)
        for (index, element) in elements.enumerated() {
            data.append(contentsOf: Array((index == 0 ? "  " : ",\n  ").utf8))
            data.append(contentsOf: element)
        }
        data.append(contentsOf: Array("\n]".utf8))
        return data
    }

    /// One save. With `copyingUnreadableFirst` the unreadable original is copied aside
    /// before it is replaced — and if the copy fails the write still goes ahead, since losing
    /// this session's dictations too would help no one. Returns whether the copy is still
    /// owed: only when neither it nor the write happened, so the original is still there.
    static func write(_ records: [TranscriptionRecord], keeping undecodable: [UndecodableRecord],
                      to url: URL, copyingUnreadableFirst: Bool, now: Date = Date()) -> Bool {
        var owed = copyingUnreadableFirst
        if owed {
            do {
                let copy = try preserveUnreadable(url, now: now)
                owed = false
                histLog.error("copied the unreadable history file aside as \(copy.lastPathComponent, privacy: .public)")
            } catch {
                histLog.error("could not copy the unreadable history file aside: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try encode(records, keeping: undecodable).write(to: url, options: .atomic)
            owed = false
        } catch {
            histLog.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
        return owed
    }

    /// Copies `url` aside as `history.json.unreadable-<UTC date>`, never over an earlier copy.
    /// The time has no colons, which Finder would show as slashes.
    @discardableResult
    static func preserveUnreadable(_ url: URL, now: Date = Date()) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        let stem = "\(url.lastPathComponent)\(unreadableMarker)\(formatter.string(from: now))"
        let folder = url.deletingLastPathComponent()
        var copy = folder.appendingPathComponent(stem)
        var attempt = 2
        while FileManager.default.fileExists(atPath: copy.path) {
            copy = folder.appendingPathComponent("\(stem)-\(attempt)")
            attempt += 1
        }
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// Every copy `preserveUnreadable` has made of `url`.
    static func unreadableCopies(of url: URL) -> [URL] {
        let prefix = url.lastPathComponent + unreadableMarker
        let folder = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted().map { folder.appendingPathComponent($0) }
    }

    private static let unreadableMarker = ".unreadable-"

    /// Where each element of a top-level JSON array lies in `bytes`, without the whitespace
    /// around it; nil when `bytes` is not one array — truncated, unbalanced, or anything else
    /// at the top. Strings are skipped whole, escapes included, since a dictation can hold
    /// every character JSON gives a meaning to.
    static func elementRanges(in bytes: [UInt8]) -> [Range<Int>]? {
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), comma = UInt8(ascii: ",")
        let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
        let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }
        var index = 0
        func skipSpace() { while index < bytes.count, isSpace(bytes[index]) { index += 1 } }

        skipSpace()
        guard index < bytes.count, bytes[index] == openBracket else { return nil }
        index += 1
        skipSpace()
        var ranges: [Range<Int>] = []
        if index < bytes.count, bytes[index] == closeBracket {
            index += 1
        } else {
            while true {
                let start = index
                var depth = 0, inString = false, escaped = false
                scan: while index < bytes.count {
                    let byte = bytes[index]
                    if inString {
                        if escaped {
                            escaped = false
                        } else if byte == backslash {
                            escaped = true
                        } else if byte == quote {
                            inString = false
                        }
                    } else if byte == quote {
                        inString = true
                    } else if byte == openBrace || byte == openBracket {
                        depth += 1
                    } else if byte == closeBrace || byte == closeBracket {
                        if depth == 0 { break scan }
                        depth -= 1
                    } else if byte == comma, depth == 0 {
                        break scan
                    }
                    index += 1
                }
                // Out of bytes, or a `}` closing nothing.
                guard index < bytes.count, bytes[index] != closeBrace else { return nil }
                var end = index
                while end > start, isSpace(bytes[end - 1]) { end -= 1 }
                guard end > start else { return nil }
                ranges.append(start..<end)
                let separator = bytes[index]
                index += 1
                if separator == closeBracket { break }
                skipSpace()
            }
        }
        skipSpace()
        return index == bytes.count ? ranges : nil
    }

    private static func isNoSuchFile(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isNoSuchFile) ?? false
    }

    /// What can still be read of an entry that does not decode: where it goes, and its audio.
    private struct Placement: Decodable {
        let date: Date?
        let audioFileName: String?

        private enum CodingKeys: String, CodingKey { case date, audioFileName }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = try? container.decodeIfPresent(Date.self, forKey: .date)
            audioFileName = try? container.decodeIfPresent(String.self, forKey: .audioFileName)
        }
    }
}
