// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What kind of failure a transcription error is, read from the codes its text carries —
/// the HTTP status the providers' messages end with ("(HTTP 401)"), the URL error code
/// ("-1009") — and only then from Foundation's English words. Not from our own words:
/// those are translated, and a check for "API key" would miss in Spanish. The app picks
/// the notice's wording by it, and setup's Try it step its panel.
public enum TranscriptionFailureKind: Equatable, Sendable {
    case tooLarge, rateLimited, rejected, timedOut, offline, other

    public init(message raw: String) {
        if raw.contains("413") || raw.localizedCaseInsensitiveContains("too large") {
            self = .tooLarge
        } else if raw.contains("429") {
            self = .rateLimited
        } else if raw.contains("401") || raw.contains("403") {
            self = .rejected
        } else if raw.localizedCaseInsensitiveContains("timed out") || raw.contains("-1001") {
            self = .timedOut
        } else if raw.localizedCaseInsensitiveContains("offline") || raw.contains("-1009") {
            self = .offline
        } else {
            self = .other
        }
    }
}
