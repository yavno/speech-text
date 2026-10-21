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
