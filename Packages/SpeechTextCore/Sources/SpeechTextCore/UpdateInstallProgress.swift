// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where an update the user agreed to has got to, for Settings › General › Updates.
public enum UpdateInstallStatus: Equatable, Sendable {
    case idle
    /// `percent` is nil while the size is unknown: a server need not send one.
    case downloading(percent: Int?)
    case extracting(percent: Int)
    case readyToInstall
    case installing

    /// For a progress bar; nil draws one with no position.
    public var fraction: Double? {
        switch self {
        case .downloading(let percent): percent.map { Double($0) / 100 }
        case .extracting(let percent): Double(percent) / 100
        case .readyToInstall: 1
        case .idle, .installing: nil
        }
    }
}

/// Turns the updater's stream of callbacks into an `UpdateInstallStatus`. The download
/// arrives as chunk lengths, a chunk every few milliseconds; the status holds whole
/// percents, so it changes a hundred times per download whatever the chunk size and
/// a view that follows it is not redrawn per chunk.
public struct UpdateInstallProgress: Equatable, Sendable {
    public private(set) var status: UpdateInstallStatus = .idle
    private var received: UInt64 = 0
    private var expected: UInt64 = 0

    public init() {}

    public mutating func downloadStarted() {
        received = 0
        expected = 0
        status = .downloading(percent: nil)
    }

    /// The first thing a server says about the file; 0 means it did not say.
    public mutating func expectedLengthReceived(_ length: UInt64) {
        expected = length
        updateDownloadPercent()
    }

    public mutating func dataReceived(_ length: UInt64) {
        received += length
        updateDownloadPercent()
    }

    public mutating func extractionStarted() {
        status = .extracting(percent: 0)
    }

    /// `fraction` from 0 to 1.
    public mutating func extractionProgressed(_ fraction: Double) {
        status = .extracting(percent: Self.percent(fraction))
    }

    public mutating func readyToInstall() {
        status = .readyToInstall
    }

    public mutating func installationStarted() {
        status = .installing
    }

    public mutating func reset() {
        self = UpdateInstallProgress()
    }

    /// A server's stated length can be short of what it sends, so the bar stops at full,
    /// as the updater's own window does.
    private mutating func updateDownloadPercent() {
        guard expected > 0 else {
            status = .downloading(percent: nil)
            return
        }
        status = .downloading(percent: Self.percent(Double(received) / Double(expected)))
    }

    /// Rounded down: 100% says it has all arrived.
    private static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded(.down))
    }
}
