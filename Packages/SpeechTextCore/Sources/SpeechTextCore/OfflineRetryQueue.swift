// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Retrying by itself once the network is back

/// Dictations saved to History for want of a network in *this* session, and when to
/// retry them. Pure logic, in SpeechTextCore: `OfflineRetry` feeds it the network's state
/// and the retries' results, and does what it answers.
///
/// Memory only, on purpose — "this session" is the decision: a recording archived
/// last week is History's to retry at the user's word, not something to upload the next
/// time the Wi-Fi happens to come up.
///
/// A drain is started by the network *returning* — an unsatisfied → satisfied edge —
/// never by the monitor's first report, which is the current state rather than a
/// change. The one exception is a dictation queued while the network already looks
/// up (the link dropped mid-upload and was back before the failure was written): it is
/// tried once at once, since no edge will ever come for it. It runs one record at a
/// time, oldest first, and a record that finds no network again stops the drain and
/// waits for the next edge, with everything behind it — unless that edge already came
/// while the drain ran (`drainOwed`).
public struct OfflineRetryQueue: Sendable {
    public enum Result: Equatable, Sendable {
        /// Transcribed: it leaves the queue; its text waits in History, never pasted.
        case succeeded
        /// No network again: it stays, and so does everything after it.
        case offline
        /// Any other failure, or the record is gone or was retried by the user: it
        /// leaves the queue. History's row already says what happened.
        case dropped
        /// The user is retrying it right now: it stays — should that retry find no
        /// network, the next return still owes it one — and the drain moves on.
        case busy
    }

    /// Oldest first.
    public private(set) var pending: [UUID] = []
    private(set) var isDraining = false
    /// The last state the monitor reported; nil before its first report.
    public private(set) var networkIsUp: Bool?
    /// Records passed over as `busy` in the running drain.
    private var skipped: Set<UUID> = []
    /// The network came back while a drain was running, so `networkChanged` started none.
    /// Forgotten when the network goes again, whose return will start a drain itself.
    private var returnedDuringDrain = false
    /// A drain ended on "no network" with the network up, after it had come back while
    /// that drain ran: a fast Wi-Fi roam, whose retry failed before the return and said so
    /// after it. No edge is left to start the next drain, so the one that ended owes it —
    /// one per return, never one per "no network": a captive portal reports the path as
    /// satisfied, and draining again on every such result would retry every few seconds
    /// for as long as it stood. True until the next drain begins or the network goes.
    public private(set) var drainOwed = false

    public init() {}

    /// Adds a record. True when a drain should start now: the network already looks up,
    /// so no edge will come to start one.
    public mutating func enqueue(_ id: UUID) -> Bool {
        guard !pending.contains(id) else { return false }
        pending.append(id)
        return networkIsUp == true && !isDraining
    }

    /// The monitor's report. True when a drain should start: the network has just come
    /// back and something is waiting for it.
    public mutating func networkChanged(isUp: Bool) -> Bool {
        let cameBack = networkIsUp == false && isUp
        networkIsUp = isUp
        if !isUp {
            returnedDuringDrain = false
            drainOwed = false
        } else if cameBack, isDraining {
            returnedDuringDrain = true
        }
        return cameBack && !pending.isEmpty && !isDraining
    }

    /// Starts a drain and returns the first record to retry, or nil when there is
    /// nothing to do (or a drain is already running).
    public mutating func beginDrain() -> UUID? {
        guard !isDraining, let first = pending.first else { return nil }
        isDraining = true
        returnedDuringDrain = false
        drainOwed = false
        return first
    }

    /// Records one retry's result and returns the next record to retry, or nil when the
    /// drain is over — the queue is empty, or the network is gone again.
    public mutating func finished(_ id: UUID, _ result: Result) -> UUID? {
        switch result {
        case .succeeded, .dropped:
            pending.removeAll { $0 == id }
        case .busy:
            skipped.insert(id)
        case .offline:
            let owed = returnedDuringDrain && networkIsUp == true
            _ = endDrain()
            drainOwed = owed
            return nil
        }
        guard let next = pending.first(where: { !skipped.contains($0) }) else { return endDrain() }
        return next
    }

    private mutating func endDrain() -> UUID? {
        isDraining = false
        skipped = []
        returnedDuringDrain = false
        return nil
    }
}
