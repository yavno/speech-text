// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SpeechTextCore

// MARK: - Retrying an archived recording

/// Transcribes a History entry's archived audio again. One owner for every way a retry
/// starts — History's button, the "No connection" notice's Retry — so the same record is
/// never sent twice at once and History's spinner shows a retry whoever began it.
///
/// App target only: it reads `RecordingConfiguration.current()`, since a retry exists to
/// try the settings the user has *now*.
@MainActor
@Observable
final class HistoryRetry {
    static let shared = HistoryRetry()

    /// Records being retried right now.
    private(set) var inFlight: Set<UUID> = []

    enum Result: Equatable {
        /// The record now holds this text — AI Rewrite's, for a dictation made with the AI
        /// shortcut and saved offline, unless the rewrite failed.
        case succeeded(String)
        /// Still no network; the record keeps its audio and its row says so.
        case offline
        /// Anything else, as History now shows it.
        case failed(String)
        /// A retry of this record was already running; this one did nothing.
        case alreadyRunning
    }

    private var history: TranscriptionHistory { .shared }

    /// Retries one record and writes the result into History. Returns what happened, so
    /// the caller can tell the user — History shows it in the row by itself.
    @discardableResult
    func retry(_ recordID: UUID) async -> Result {
        guard !inFlight.contains(recordID) else { return .alreadyRunning }
        guard let record = history.record(id: recordID),
              let audioURL = history.audioURL(for: record) else {
            let message = "Saved audio is no longer available"
            history.markRetryFailed(id: recordID, error: message)
            return .failed(message)
        }

        // Read fresh: a retry honours the *current* settings, not the ones the
        // recording was made with.
        let configuration = RecordingConfiguration.current()

        // Retries always go through a file transcription — Apple's recognizer has no
        // batch API, so an Apple selection retries through Groq — and that path must be
        // able to start: a key for the cloud tiers, an installed model for the local one.
        if let reason = configuration.batchUnavailableReason() {
            history.markRetryFailed(id: recordID, error: reason)
            return .failed(reason)
        }

        inFlight.insert(recordID)
        defer { inFlight.remove(recordID) }
        // The language comes from the current settings too, not from the record: a
        // retry exists precisely because the first attempt came back wrong, and an
        // entry recorded under a mis-guessed language would repeat that guess.
        let language = configuration.cloudLanguage
        dlog("History", "retry \(recordID.uuidString.prefix(8)): \(configuration.provider.rawValue), language=\(language ?? "auto")")

        let provider = makeBatchTranscriber(configuration: configuration)
        let start = Date()
        // The retry's own request, for the record's ledger; nil for a model on this Mac.
        func event(_ billing: SpeechBilling?, succeeded: Bool) -> UsageEvent? {
            provider.meter?.event(.retry, audioSeconds: record.duration, billing: billing, succeeded: succeeded,
                                  latency: Date().timeIntervalSince(start), date: start)
        }
        do {
            let result = try await provider.transcribeMetered(audioFileURL: audioURL, language: language)
            let billed = event(result.billing, succeeded: true)
            var trimmed = configuration.finished(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
            // A retry sends the same short clip to a model again, and gets the same
            // invented sign-off back — which would land on the clipboard as a success.
            // The script is judged against the languages stated now, as the language is.
            if let rejection = HallucinationFilter.rejection(trimmed, segmentSeconds: record.duration,
                                                             languages: configuration.languages) {
                dlog("History", "retry \(recordID.uuidString.prefix(8)): the whole result is \(rejection) — dropped")
                trimmed = ""
            }
            guard !trimmed.isEmpty else {
                let message = "Retry returned no text"
                history.markRetryFailed(id: recordID, error: message, event: billed)
                return .failed(message)
            }
            history.markRetrySucceeded(id: recordID, text: trimmed,
                                       provider: configuration.batchProvider.rawValue,
                                       model: configuration.batchModel, event: billed)
            guard record.retryRewrites else { return .succeeded(trimmed) }
            return .succeeded(await rewrite(trimmed, of: record))
        } catch {
            dlog("History", "retry \(recordID.uuidString.prefix(8)) failed: \(error.localizedDescription)", level: .error)
            history.markRetryFailed(id: recordID, error: error.localizedDescription,
                                    event: NetworkFailure.isOffline(error) ? nil : event(nil, succeeded: false))
            return NetworkFailure.isOffline(error) ? .offline : .failed(error.localizedDescription)
        }
    }

    /// AI Rewrite's half of a dictation made with the AI shortcut and saved offline: the
    /// rewrite it would have had at its stop, told the context read then. Any failure
    /// leaves the transcription, as a rewrite at the stop does, and says why on the row.
    /// Returns the text the record now delivers.
    private func rewrite(_ text: String, of record: TranscriptionRecord) async -> String {
        guard TextRefinementService.isConfigured else {
            dlog("History", "retry \(record.id.uuidString.prefix(8)): AI Rewrite not configured — transcription kept", level: .notice)
            return text
        }
        let context = record.undelivered?.context
        do {
            let result = try await TextRefinementService.refine(text, context: context)
            history.recordRefinement(id: record.id, input: text, output: result.text,
                                     presetName: result.presetName, provider: result.provider, model: result.model,
                                     context: context, usage: result.usage, latency: result.latency)
            return result.text
        } catch {
            dlog("History", "retry \(record.id.uuidString.prefix(8)): rewrite failed: \(error.localizedDescription)", level: .error)
            let type = LLMConfiguration.providerType
            history.recordRefinementFailure(id: record.id, input: text, error: error.localizedDescription,
                                            provider: type.rawValue, model: LLMConfiguration.model(for: type),
                                            context: context)
            return text
        }
    }
}
