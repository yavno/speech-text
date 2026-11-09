// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ChatTemplates

/// What the app and the SpeechTextLLM service say to each other. The service runs
/// llama.cpp in its own process (`Contents/XPCServices/SpeechTextLLM.xpc`), so a crash in
/// it or a model that exhausts memory ends the service, not the dictation: the app sees an
/// interrupted connection, AI Rewrite falls back to the transcript as for any failed
/// rewrite, and launchd starts the service again for the next request.
///
/// Requests and replies cross as JSON (`Data`), so the protocol needs no `NSSecureCoding`
/// classes and both sides decode the same `Codable` types.
let localChatServiceName = "app.speech-text.SpeechText.LLM"

/// `Sendable`, and every reply block with it: an XPC proxy and the replies it hands the
/// service may be called from any thread, once.
@objc protocol LocalChatServiceProtocol: Sendable {
    /// Loads the model if it is not already the one in memory, then answers. `reply` gets
    /// a JSON `LocalChatResponse`, or nil and the error's message.
    func complete(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Loads the model ahead of the first request — a cold load takes seconds — and reads
    /// the request's `prefixes`, the system prompts, which take seconds more.
    func prewarm(_ request: Data, reply: @escaping @Sendable (String?) -> Void)
    /// AI Rewrite's step one: a JSON `LocalChatRouteRequest` read as next-token
    /// probabilities, nothing generated. `reply` gets a `LocalChatRouteResponse`, or nil
    /// and the error.
    func readRoute(_ request: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
    /// Stops the completion with this `LocalChatRequest.id`: before its model loads, before
    /// it reads its prompt, or at its next token — and no other.
    func cancel(_ requestID: String)
    /// Drops the model at `modelPath` from memory if it is the one loaded — a removed
    /// download. Any other model stays: it may be the one in use.
    func unload(_ modelPath: String, reply: @escaping @Sendable () -> Void)
}

struct LocalChatRequest: Codable, Equatable {
    var modelPath: String
    var family: ChatTemplateFamily
    var system: String
    var user: String
    /// The output tokens the reply may take. For a completion it is the least: the
    /// service gives a longer user message twice its own tokens
    /// (`ChatTemplates.replyTokens`), and the context bounds it.
    var maxTokens: Int
    var contextLength: Int
    /// For a prewarm: system prompts to read ahead, so the requests that follow restore
    /// them (AI dictation's and the Edit shortcut's). Nil on a completion.
    var prefixes: [String]? = nil
    /// What a cancel names, so it stops this request and no other (`LocalChatActivity`).
    var id = UUID().uuidString
}

/// Step one's questions: `ChatTemplates.render`'s prompt, then each step's `lead` read and
/// its `options`, single tokens, weighed (`LlamaModel.chainedProbabilities`).
struct LocalChatRouteRequest: Codable, Equatable {
    struct Step: Codable, Equatable {
        var lead: String
        var options: [String]
    }

    var modelPath: String
    var family: ChatTemplateFamily
    var system: String
    var user: String
    var steps: [Step]
    /// The rewrite's own, or the model would be loaded again for it.
    var contextLength: Int
    var id = UUID().uuidString
}

struct LocalChatRouteResponse: Codable, Equatable {
    var probabilities: [[Double]]
    var promptTokens: Int
    var cachedPromptTokens: Int
    var seconds: Double
}

struct LocalChatResponse: Codable, Equatable {
    var reply: String
    var promptTokens: Int
    var outputTokens: Int
    var loadSeconds: Double
    var promptSeconds: Double
    var generationSeconds: Double
    /// The model ended its reply itself, rather than running out of tokens — a reply that
    /// did not is cut off, and the app does not paste it.
    var finished: Bool
}

/// A failure the service reports by name rather than by message. The service has no
/// String Catalog and runs in its own process, so a message it wrote would reach the user
/// in English whatever the app's language; the app words the failure itself
/// (`LocalChatError.service`). A reply that is not one of these is shown as it is.
enum LocalChatFailure: Codable, Equatable {
    case badRequest
    case loadFailed(file: String)
    case contextFailed
    case tokenizeFailed
    case promptTooLong
    case decodeFailed(code: Int32)
    case cancelled

    private static let prefix = "local-chat-failure:"

    /// What the service sends as the error string.
    var wire: String {
        let json = (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return Self.prefix + json
    }

    init?(wire: String) {
        guard wire.hasPrefix(Self.prefix),
              let data = wire.dropFirst(Self.prefix.count).data(using: .utf8),
              let failure = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = failure
    }

    /// In the app's language.
    var message: String {
        switch self {
        case .badRequest: String(localized: "The local model couldn't read the request.")
        case .loadFailed(let file): String(localized: "The local model couldn't be loaded (\(file)).")
        case .contextFailed: String(localized: "The local model couldn't start: not enough memory for its context.")
        case .tokenizeFailed: String(localized: "The local model couldn't read the prompt.")
        case .promptTooLong: String(localized: "The text is too long for the model on this Mac.")
        case .decodeFailed(let code): String(localized: "The local model stopped with an error (\(code)).")
        case .cancelled: String(localized: "The local rewrite was canceled.")
        }
    }
}
