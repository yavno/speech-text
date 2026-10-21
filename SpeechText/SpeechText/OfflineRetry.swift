// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Network
import SpeechTextCore

// MARK: - Retry what was saved offline, once the network returns

/// Watches the network (`NWPathMonitor`) and retries the dictations this session saved
/// to History for want of one, through `HistoryRetry`. The decisions — what is waiting,
/// when to start, when to stop — are `OfflineRetryQueue`'s; this does the I/O.
///
/// Results are handed to `onTranscribed` together, oldest first, once a drain is over,
/// so several dictations that waited for the same outage reach the clipboard as one
/// write instead of each replacing the one before. The owner puts them there — never
/// into an app: by the time the network is back the user may be typing anywhere.
///
/// App target only: it retries through `HistoryRetry`, which reads the user's settings.
@MainActor
final class OfflineRetry {
    static let shared = OfflineRetry()

    /// Texts a finished drain transcribed, oldest first. Not called when none did.
    var onTranscribed: (([String]) -> Void)?

    /// How long the network has to stay up before the first retry. The path turns
    /// satisfied as soon as an interface has an address, which is often a moment before
    /// DNS answers — a retry sent at once would find "no network" and wait for the
    /// next outage to end.
    static let settleDelay: TimeInterval = 2

    private var queue = OfflineRetryQueue()
    private let monitor = NWPathMonitor()
    private var settleTask: Task<Void, Never>?
    private var transcribed: [String] = []

    private init() {}

    /// Starts watching the network. Called once, at launch.
    func start() {
        // `@Sendable`, so it is not taken for main-actor code: the monitor calls it on its own queue.
        monitor.pathUpdateHandler = { @Sendable path in
            let isUp = path.status == .satisfied
            Task { @MainActor in OfflineRetry.shared.networkChanged(isUp: isUp) }
        }
        monitor.start(queue: DispatchQueue(label: "SpeechText.network-monitor", qos: .utility))
    }

    /// A dictation was saved to History because there was no network.
    func enqueue(_ recordID: UUID) {
        dlog("Network", "saved offline, retried when the network returns: \(recordID.uuidString.prefix(8))")
        if queue.enqueue(recordID) {
            scheduleDrain()
        }
    }

    private func networkChanged(isUp: Bool) {
        guard isUp != queue.networkIsUp else { return }
        dlog("Network", "network \(isUp ? "up" : "down")\(queue.pending.isEmpty ? "" : ", \(queue.pending.count) saved offline")")
        if queue.networkChanged(isUp: isUp) {
            scheduleDrain()
        } else if !isUp {
            settleTask?.cancel()
            settleTask = nil
        }
    }

    private func scheduleDrain() {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.settleTask = nil
            await self.drain()
        }
    }

    private func drain() async {
        guard var next = queue.beginDrain() else { return }
        dlog("Network", "retrying \(queue.pending.count) dictation(s) saved offline")
        transcribed = []
        while true {
            let result = await retry(next)
            guard let following = queue.finished(next, result) else { break }
            next = following
        }
        let texts = transcribed
        transcribed = []
        if !texts.isEmpty {
            onTranscribed?(texts)
        }
        // The network came back while this drain ran and its last retry still found none:
        // no edge will come for what is left, so it is tried again — after the same settle.
        if queue.drainOwed {
            dlog("Network", "the network came back during the retry — retrying \(queue.pending.count) again")
            scheduleDrain()
        }
    }

    private func retry(_ recordID: UUID) async -> OfflineRetryQueue.Result {
        // Retried by the user meanwhile, deleted, or its audio expired: nothing to do.
        guard TranscriptionHistory.shared.record(id: recordID)?.isRetryable == true else { return .dropped }
        switch await HistoryRetry.shared.retry(recordID) {
        case .succeeded(let text):
            transcribed.append(text)
            return .succeeded
        case .offline:
            return .offline
        case .failed:
            return .dropped
        case .alreadyRunning:
            // A retry the user started reports to them itself; the record stays queued
            // in case that one finds no network.
            return .busy
        }
    }
}
