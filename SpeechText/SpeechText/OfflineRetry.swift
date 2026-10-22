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
/// Nothing a retry transcribes goes anywhere: not into an app — by the time the network
/// is back the user may be typing anywhere — and not onto the clipboard, which would
/// replace whatever the user copied meanwhile. It stays in History, and once a drain is
/// over `onDrained` says how many dictations are waiting there, so the owner can say so
/// once for the whole outage.
///
/// App target only: it retries through `HistoryRetry`, which reads the user's settings.
@MainActor
final class OfflineRetry {
    static let shared = OfflineRetry()

    /// What a finished drain came to: the dictations it transcribed and the ones it
    /// could not (any failure but no network — a timeout, a file too large). Not called
    /// when it finished none.
    var onDrained: ((_ transcribed: Int, _ failed: Int) -> Void)?

    /// Dictations saved offline and not yet transcribed — what the "No connection" notice counts.
    var pendingCount: Int { queue.pending.count }

    /// How long the network has to stay up before the first retry. The path turns
    /// satisfied as soon as an interface has an address, which is often a moment before
    /// DNS answers — a retry sent at once would find "no network" and wait for the
    /// next outage to end.
    static let settleDelay: TimeInterval = 2

    private var queue = OfflineRetryQueue()
    private let monitor = NWPathMonitor()
    private var settleTask: Task<Void, Never>?
    /// The running drain's results so far.
    private var transcribed = 0
    private var failed = 0

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
        transcribed = 0
        failed = 0
        while true {
            let result = await retry(next)
            guard let following = queue.finished(next, result) else { break }
            next = following
        }
        if transcribed + failed > 0 {
            dlog("Network", "drain over: \(transcribed) transcribed, \(failed) failed")
            onDrained?(transcribed, failed)
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
        case .succeeded:
            transcribed += 1
            return .succeeded
        case .offline:
            return .offline
        case .failed:
            // Said, not dropped in silence: its row has the error and Retry.
            failed += 1
            return .dropped
        case .alreadyRunning:
            // A retry the user started reports to them itself; the record stays queued
            // in case that one finds no network.
            return .busy
        }
    }
}
