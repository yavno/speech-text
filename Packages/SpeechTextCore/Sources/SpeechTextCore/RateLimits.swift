// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - What the vendor says is left

/// One window of a vendor's rate limit, as its reply's headers state it: requests a
/// day, tokens a minute, and whatever else the vendor meters. A free tier is spent
/// against these, not against dollars, so how much of each is left is the useful number.
public struct RateLimitWindow: Equatable, Sendable {
    /// The vendor's own word for what is counted: `requests`, `tokens`, `input-tokens`…
    public let name: String
    public var limit: Int?
    public var remaining: Int?
    /// When the window refills, from the vendor's reset header.
    public var resetsAt: Date?

    /// The share used, 0–1; nil until both numbers are known.
    public var used: Double? {
        guard let limit, let remaining, limit > 0 else { return nil }
        return min(1, max(0, Double(limit - remaining) / Double(limit)))
    }
}

/// The last limits a vendor reported for one model — Groq's apply per model, so a chat
/// model's and a speech model's are kept apart.
public struct RateLimitSnapshot: Equatable, Sendable {
    public let vendor: Provider
    public let model: String
    let date: Date
    public var windows: [RateLimitWindow]
}

/// Reads the rate-limit headers the vendors send with every reply. Pure.
enum RateLimits {
    /// OpenAI and Groq spell them `x-ratelimit-{limit,remaining,reset}-<what>` with the
    /// reset as a duration ("2m59.56s"); Anthropic `anthropic-ratelimit-<what>-{limit,
    /// remaining,reset}` with the reset as an RFC 3339 time. Any `<what>` is kept, so a
    /// window a vendor adds later (audio seconds) is read without a change here. Nil when
    /// the reply carried none — ElevenLabs sends none.
    static func parse(vendor: Provider, model: String, headers: [AnyHashable: Any],
                      now: Date = Date()) -> RateLimitSnapshot? {
        var windows: [String: RateLimitWindow] = [:]
        func update(_ name: String, _ field: String, _ value: String) {
            var window = windows[name] ?? RateLimitWindow(name: name)
            switch field {
            case "limit": window.limit = Int(value)
            case "remaining": window.remaining = Int(value)
            case "reset": window.resetsAt = resetDate(value, now: now)
            default: return
            }
            windows[name] = window
        }
        for (key, raw) in headers {
            guard let header = (key as? String)?.lowercased(), let value = (raw as? String) ?? (raw as? NSNumber)?.stringValue
            else { continue }
            if header.hasPrefix("x-ratelimit-") {
                let rest = header.dropFirst("x-ratelimit-".count)
                for field in ["limit", "remaining", "reset"] where rest.hasPrefix(field + "-") {
                    update(String(rest.dropFirst(field.count + 1)), field, value)
                }
            } else if header.hasPrefix("anthropic-ratelimit-") {
                let rest = header.dropFirst("anthropic-ratelimit-".count)
                for field in ["limit", "remaining", "reset"] where rest.hasSuffix("-" + field) {
                    update(String(rest.dropLast(field.count + 1)), field, value)
                }
            }
        }
        guard !windows.isEmpty else { return nil }
        return RateLimitSnapshot(vendor: vendor, model: model, date: now,
                                 windows: windows.values.sorted { $0.name < $1.name })
    }

    /// A reset as a moment: an RFC 3339 time, or a duration from now in Go's notation —
    /// "1h2m3.5s", "7.66s", "120ms".
    static func resetDate(_ value: String, now: Date) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return duration(value).map { now.addingTimeInterval($0) }
    }

    static func duration(_ value: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        var unit = ""
        var parsedAny = false
        func flush() -> Bool {
            guard !number.isEmpty else { return unit.isEmpty }
            guard let amount = Double(number) else { return false }
            switch unit {
            case "h": total += amount * 3600
            case "m": total += amount * 60
            case "s": total += amount
            case "ms": total += amount / 1000
            default: return false
            }
            parsedAny = true
            number = ""; unit = ""
            return true
        }
        for character in value {
            if character.isNumber || character == "." {
                if !unit.isEmpty, !flush() { return nil }
                number.append(character)
            } else {
                unit.append(character)
            }
        }
        guard flush(), parsedAny else { return nil }
        return total
    }

    /// "requests 13,999 of 14,400 · tokens 5,800 of 6,000" — numbers only, for the Debug Log.
    static func logLine(_ snapshot: RateLimitSnapshot) -> String {
        snapshot.windows.compactMap { window in
            guard let remaining = window.remaining else { return nil }
            return "\(window.name) \(remaining)" + (window.limit.map { " of \($0)" } ?? "")
        }.joined(separator: " · ")
    }
}

/// The latest limits each vendor and model reported this session. Memory only: a limit
/// read yesterday says nothing about today, and the next request refreshes it.
@MainActor @Observable
public final class RateLimitStore {
    public nonisolated static let shared = RateLimitStore()

    nonisolated init() {}

    private(set) var latest: [String: RateLimitSnapshot] = [:]

    /// Called with each reply, from whatever thread the request finished on.
    nonisolated func record(vendor: Provider, model: String, response: URLResponse) {
        guard let http = response as? HTTPURLResponse,
              let snapshot = RateLimits.parse(vendor: vendor, model: model, headers: http.allHeaderFields)
        else { return }
        dlog("Limits", "\(vendor.displayName) \(model): \(RateLimits.logLine(snapshot))")
        DispatchQueue.main.async {
            self.latest["\(vendor.rawValue)/\(model)"] = snapshot
        }
    }

    /// Newest first.
    public var snapshots: [RateLimitSnapshot] { latest.values.sorted { $0.date > $1.date } }
}
