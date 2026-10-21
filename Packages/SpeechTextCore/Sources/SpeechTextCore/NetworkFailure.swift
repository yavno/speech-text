// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - What counts as "no connection"

/// Whether an error means the Mac could not reach the network at all, as opposed to a
/// provider that was reached and answered badly. Pure logic.
///
/// The answer decides what the user is told and what happens next: an offline failure
/// says "No connection — saved to History" and is retried by itself once the network is
/// back, where anything else keeps the provider's own words and waits for the user.
/// So the set is deliberately narrow — the codes URLSession uses when no request left
/// the machine or the link went down under one. A timeout is *not* in it: with the
/// network up it is a slow provider, and retrying it the moment the Wi-Fi comes back
/// would retry something the Wi-Fi never broke.
public enum NetworkFailure {
    /// `URLError` codes that mean there was no usable network.
    static let offlineURLErrorCodes: Set<Int> = [
        URLError.notConnectedToInternet.rawValue,   // -1009: no interface up
        URLError.networkConnectionLost.rawValue,    // -1005: the link went down mid-request
        URLError.cannotFindHost.rawValue,           // -1003: no DNS answer
        URLError.dnsLookupFailed.rawValue,          // -1006
        URLError.cannotConnectToHost.rawValue,      // -1004: nothing answered at all
        URLError.internationalRoamingOff.rawValue,  // -1018
        URLError.dataNotAllowed.rawValue,           // -1020: cellular data off
    ]

    /// POSIX codes a socket reports when the interface under it goes away.
    static let offlinePOSIXCodes: Set<Int> = [
        Int(ENETDOWN),     // 50
        Int(ENETUNREACH),  // 51
        Int(EHOSTUNREACH), // 65
    ]

    /// True when `error`, or any error it wraps (`NSUnderlyingErrorKey`), is one of the
    /// offline codes above.
    public static func isOffline(_ error: Error) -> Bool {
        isOffline(domain: (error as NSError).domain, code: (error as NSError).code)
            || underlying(of: error).map(isOffline) == true
    }

    static func isOffline(domain: String, code: Int) -> Bool {
        switch domain {
        case NSURLErrorDomain: return offlineURLErrorCodes.contains(code)
        case NSPOSIXErrorDomain: return offlinePOSIXCodes.contains(code)
        default: return false
        }
    }

    private static func underlying(of error: Error) -> Error? {
        (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
    }
}

// MARK: - Reconnecting a stream

/// When a realtime stream that broke mid-recording is opened again, and how hard to try.
/// Pure logic; `StreamingRecognitionSession` asks it.
///
/// A reconnect exists for the overlay: after a short outage the user keeps seeing their
/// words instead of a transcript frozen where the link dropped. It is never what the
/// dictation's text rests on — the new socket did not hear the outage, so the stop takes
/// the upload, which has the whole segment on disk. That is why the policy can afford to
/// give up early: giving up costs only the live text.
public struct StreamReconnectPolicy: Sendable {
    /// The wait before each attempt within one outage — about 26 s of trying, which is
    /// what "a short outage" means here. Longer than the outage itself: once the Wi-Fi is
    /// back, macOS still needs a few seconds to join, take an address and answer DNS. An
    /// attempt made with no network fails at once and costs nothing, so the waits are
    /// what pace them.
    var delays: [TimeInterval]
    /// Outages one segment rides out. A link that keeps dropping is not a short outage,
    /// and every reconnect is a new realtime session that is paid for.
    var maxOutages: Int

    public init(delays: [TimeInterval] = [0.5, 1, 2, 3, 5, 5, 5, 5], maxOutages: Int = 3) {
        self.delays = delays
        self.maxOutages = maxOutages
    }

    /// POSIX codes a WebSocket reports when the connection under it went away — the
    /// peer or a middlebox reset it, or the interface vanished and took it along.
    static let droppedConnectionPOSIXCodes: Set<Int> = [
        Int(ECONNABORTED), // 53
        Int(ECONNRESET),   // 54
        Int(ENOTCONN),     // 57
        Int(ETIMEDOUT),    // 60
        Int(EPIPE),        // 32
    ]

    /// Whether a stream that failed with `error` is worth opening again: the network
    /// went away (`NetworkFailure.isOffline`), the connection dropped or stalled, or the
    /// server never started a session. Never a refusal — a rejected key, a quota, a
    /// rate limit, a request the server could not use — which a new socket would only
    /// hear again, nor our own failure to convert the audio.
    static func isReconnectable(_ error: Error) -> Bool {
        if NetworkFailure.isOffline(error) { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == URLError.timedOut.rawValue { return true }
        if ns.domain == NSPOSIXErrorDomain, droppedConnectionPOSIXCodes.contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error, isReconnectable(underlying) {
            return true
        }
        // Held audio filled up with no session to send it to: the server never answered.
        switch error {
        case TranscriptionError.realtime(_, let code, _): return code == "no_session"
        default: return false
        }
    }

    /// How long to wait before attempt `attempt` (0 for the first) of outage `outage`
    /// (1 for the first), or nil to give up and leave the segment to the upload.
    func delay(attempt: Int, outage: Int) -> TimeInterval? {
        guard outage <= maxOutages, delays.indices.contains(attempt) else { return nil }
        return delays[attempt]
    }
}
