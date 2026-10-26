// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ChatTemplates

// MARK: - Provider Type

public enum LLMProviderType: String, CaseIterable, Identifiable, Sendable {
    case groq = "groq"
    case anthropic = "anthropic"
    case openai = "openai"
    /// Built in: a GGUF model run by llama.cpp in the SpeechTextLLM service.
    case local = "local"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .groq: "Groq"
        case .anthropic: "Anthropic (Claude)"
        case .openai: "OpenAI"
        case .local: "On this Mac"
        }
    }

    /// The provider that serves the pick.
    public var vendor: Provider {
        switch self {
        case .groq: .groq
        case .anthropic: .anthropic
        case .openai: .openAI
        case .local: .local
        }
    }

    /// The Mac has no key; `LLMConfiguration.isConfigured` then means "a model is chosen",
    /// and one not downloaded surfaces as the request's own error, through the same
    /// raw-transcript fallback as any other failure — which says what to do.
    public var needsAPIKey: Bool { vendor.descriptor.apiKey != nil }
}

// MARK: - Model catalogue

/// How a model's reasoning is kept out of its reply, where its API has a switch for it.
enum ReasoningOutput: Equatable {
    /// Nothing sent: the model documents no switch, or needs none.
    case unchanged
    /// `include_reasoning: false` — Groq's gpt-oss, which rejects `reasoning_format`.
    case excluded
    /// `reasoning_format: hidden` — Groq's Qwen, whose default `raw` puts `<think>` into
    /// the content ahead of the `<<mode:NAME>>` marker.
    case hidden
}

/// A chat model AI Rewrite can use: who serves it, its picker name, and the request
/// switches measured for it. Which switches a model accepts is exactly what goes wrong —
/// the wrong one is an HTTP 400 and the whole rewrite lost — so they are written down per
/// model here, and no request is built from a check on the model's name. The local
/// entries are derived from `localChatModels`, so each model is written down once.
public struct ChatModelDescriptor: Equatable, Sendable {
    public let provider: LLMProviderType
    public let id: String
    public let displayName: String
    /// Sent as `reasoning_effort` (Anthropic: `output_config.effort`); nil sends nothing.
    let reasoningEffort: String?
    let reasoningOutput: ReasoningOutput
    /// Anthropic's server-side refusal fallbacks, documented for the Opus 5 / Fable 5 tier.
    let refusalFallbacks: Bool
    /// The vendor's list price, checked on `UsagePrices.checked`. Required, so a model
    /// added without one fails to build rather than showing as free.
    public let price: ListPrice<ChatRates>
    /// Where the model is in its vendor's life (`ModelLifecycle`). A model on this Mac is
    /// current while the catalogue lists it.
    public var lifecycle: ModelLifecycle = .current
}

/// What a vendor charges for a chat model's tokens.
public struct ChatRates: Hashable, Sendable {
    public let inputPerToken: Double
    /// A cache read (`ChatUsage.cachedInputTokens`) — the input price where the vendor
    /// lists no cache.
    public let cachedInputPerToken: Double
    public let outputPerToken: Double

    init(inputPerToken: Double, cachedInputPerToken: Double? = nil, outputPerToken: Double) {
        self.inputPerToken = inputPerToken
        self.cachedInputPerToken = cachedInputPerToken ?? inputPerToken
        self.outputPerToken = outputPerToken
    }

    /// Dollars per million tokens, as every vendor lists them.
    static func perMillion(input: Double, cachedInput: Double? = nil, output: Double) -> ChatRates {
        ChatRates(inputPerToken: input / 1e6, cachedInputPerToken: cachedInput.map { $0 / 1e6 },
                  outputPerToken: output / 1e6)
    }
}

/// Groq: checked against Groq's model and deprecation pages on 2026-09-16. Both Llama
/// models, Qwen3 32B and Kimi K2 were shut down for free and developer accounts between
/// April and August 2026 — the old default among them. They were deleted from this list
/// before models had a lifecycle, so a stored ID for any of them leads nowhere and
/// is cleared at launch. The two preview models are labelled as
/// such: Groq may withdraw a preview without notice. Groq's reasoning models take
/// different switches, and the wrong one is an HTTP 400 rather than something ignored:
/// gpt-oss rejects `reasoning_format` and has no `none` effort; Qwen defaults to `raw`.
/// MiniMax M2.7 documents no switch, so its reply goes through `strippingReasoning`; it
/// went Enterprise-only on 2026-10-16 and is retired (#39).
///
/// Anthropic: Fable 5.1 is left out on purpose: it is the slowest and most expensive
/// model, and a dictation clean-up gains nothing from it. Haiku 4.5 is still active, its
/// retirement "not sooner than 2026-10-15" (checked 2026-10-16); when it is deprecated it
/// is marked `.deprecated` with its replacement, never dropped (docs/adding-a-provider.md
/// › Retiring a model). `output_config.effort` is rejected by pre-4.6-era models such as
/// Haiku 4.5; elsewhere `low` keeps latency down while leaving adaptive thinking
/// on (disabling it can leak `<thinking>` tags).
///
/// OpenAI: GPT-6 Astra is left out: it is built for long agentic work, and a dictation
/// clean-up would only pay for its latency. `reasoning_effort: none` — measured
/// 2026-09-21 on `gpt-5.6-luna` against the live API: median 1.63 s on the default
/// effort, 0.98 s with `none`, and `low` matched that median with a longer tail. The
/// accepted values are `none / low / medium / high / xhigh`; `minimal` is rejected. Only
/// the 5.6 family was measured, so a model added here without a measurement is sent
/// nothing: an unsupported value costs the whole rewrite, a default effort only time.
///
/// Prices are pay-as-you-go list prices per million tokens as of `UsagePrices.checked`
/// (docs/prices.md): Groq's models page (cached input for gpt-oss at the 50 % discount its
/// prompt-caching page states, and for Qwen3.8 27B from `/v1/models`, the one place it is
/// published), Anthropic's pricing page (cache hits as the
/// cached price), OpenAI's pricing page (standard tier). A model on this Mac is free.
public let chatModelCatalog: [ChatModelDescriptor] = [
    ChatModelDescriptor(provider: .groq, id: "openai/gpt-oss-120b", displayName: "GPT-OSS 120B",
                        reasoningEffort: "low", reasoningOutput: .excluded, refusalFallbacks: false,
                        price: .listed(.perMillion(input: 0.15, cachedInput: 0.075, output: 0.60))),
    ChatModelDescriptor(provider: .groq, id: "openai/gpt-oss-20b", displayName: "GPT-OSS 20B (fastest)",
                        reasoningEffort: "low", reasoningOutput: .excluded, refusalFallbacks: false,
                        price: .listed(.perMillion(input: 0.075, cachedInput: 0.0375, output: 0.30))),
    ChatModelDescriptor(provider: .groq, id: "qwen/qwen3.8-27b", displayName: "Qwen3.8 27B (preview)",
                        reasoningEffort: "none", reasoningOutput: .hidden, refusalFallbacks: false,
                        price: .listed(.perMillion(input: 0.80, cachedInput: 0.40, output: 4.00))),
    // Groq lists no price for it ("Contact sales"). Gone from `/v1/models` for an ordinary
    // key since 2026-10-16 with no deprecation published — "Contact sales" is how Groq marks
    // an Enterprise-only model — so it is retired as of the day it was first seen missing.
    ChatModelDescriptor(provider: .groq, id: "minimaxai/minimax-m2.7", displayName: "MiniMax M2.7 (preview)",
                        reasoningEffort: nil, reasoningOutput: .unchanged, refusalFallbacks: false,
                        price: .notPriced,
                        lifecycle: .deprecated(Deprecation(
                            announced: ModelRetirement.day(2026, 10, 16), shutdown: ModelRetirement.day(2026, 10, 16),
                            replacement: "openai/gpt-oss-120b",
                            source: URL(string: "https://github.com/yavno/speech-text/issues/39")!))),

    ChatModelDescriptor(provider: .anthropic, id: "claude-sonnet-5", displayName: "Claude Sonnet 5",
                        reasoningEffort: "low", reasoningOutput: .unchanged, refusalFallbacks: false,
                        price: .listed(.perMillion(input: 2, cachedInput: 0.20, output: 10))),
    ChatModelDescriptor(provider: .anthropic, id: "claude-opus-5", displayName: "Claude Opus 5",
                        reasoningEffort: "low", reasoningOutput: .unchanged, refusalFallbacks: true,
                        price: .listed(.perMillion(input: 5, cachedInput: 0.50, output: 25))),
    ChatModelDescriptor(provider: .anthropic, id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5 (fastest)",
                        reasoningEffort: nil, reasoningOutput: .unchanged, refusalFallbacks: false,
                        price: .listed(.perMillion(input: 1, cachedInput: 0.10, output: 5))),

    ChatModelDescriptor(provider: .openai, id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna — fastest",
                        reasoningEffort: "none", reasoningOutput: .unchanged, refusalFallbacks: false,
                        price: .listed(.perMillion(input: 0.20, cachedInput: 0.02, output: 1.20))),
    ChatModelDescriptor(provider: .openai, id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra — balanced",
                        reasoningEffort: "none", reasoningOutput: .unchanged, refusalFallbacks: false,
                        price: .listed(.perMillion(input: 2, cachedInput: 0.20, output: 12))),
    ChatModelDescriptor(provider: .openai, id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol — flagship",
                        reasoningEffort: "none", reasoningOutput: .unchanged, refusalFallbacks: false,
                        price: .listed(.perMillion(input: 4, cachedInput: 0.40, output: 20))),
] + localChatModels.map { local in
    // No switches: reasoning is the template's business (`ChatTemplates`), not a request's.
    ChatModelDescriptor(provider: .local, id: local.id, displayName: local.displayName,
                        reasoningEffort: nil, reasoningOutput: .unchanged, refusalFallbacks: false,
                        price: .free)
}

/// A provider's models a picker, setup or a recommendation may offer, in picker order.
public func offeredChatModels(of provider: LLMProviderType) -> [ChatModelDescriptor] {
    chatModelCatalog.filter { $0.provider == provider && $0.lifecycle.isOffered }
}

/// Every model of a provider the catalogue still describes, offered or not — what
/// prices, names, History, Usage and normalisation look in. The archive
/// (`archivedChatModels`) is the rest of what is known.
func knownChatModels(of provider: LLMProviderType) -> [ChatModelDescriptor] {
    chatModelCatalog.filter { $0.provider == provider }
}

/// What a chat model picker lists: the offered models, and the selected one after them
/// when it is not offered, so the picker never renders blank. An empty selection (a
/// choice the launch cleared) adds nothing.
public func pickerChatModels(of provider: LLMProviderType, selected: String) -> [ChatModelDescriptor] {
    let offered = offeredChatModels(of: provider)
    if selected.isEmpty || offered.contains(where: { $0.id == selected }) { return offered }
    return offered + [chatModel(provider: provider, id: selected)]
}

/// The catalogue's entry for this model, or nil for an ID it does not list.
func listedChatModel(provider: LLMProviderType, id: String) -> ChatModelDescriptor? {
    chatModelCatalog.first { $0.provider == provider && $0.id == id }
}

/// A chat model's name wherever it is known — the catalogue, else the archive — for a
/// caller that has the ID but not the provider; the ID itself otherwise.
public func knownChatModelName(id: String) -> String {
    chatModelCatalog.first { $0.id == id }?.displayName
        ?? archivedChatModels.first { $0.id == id }?.displayName
        ?? id
}

/// The model a request is built for: its catalogue entry, or what an unlisted ID is sent.
public func chatModel(provider: LLMProviderType, id: String) -> ChatModelDescriptor {
    if let listed = listedChatModel(provider: provider, id: id) { return listed }
    switch provider {
    case .groq, .anthropic, .openai:
        // The launch moves a stored cloud ID the catalogue no longer offers to its
        // replacement, so only an ID nobody measured, or History's archived one, gets
        // here. It is sent no switch: an unsupported one costs the whole rewrite, a
        // default effort only time. An archived model keeps its name and price; anything
        // else is named as unpriced, never charged at another model's rate.
        let archived = archivedChatModels.first { $0.vendor == provider.vendor && $0.id == id }
        return ChatModelDescriptor(provider: provider, id: id, displayName: archived?.displayName ?? id,
                                   reasoningEffort: nil, reasoningOutput: .unchanged, refusalFallbacks: false,
                                   price: archived?.price ?? .notPriced,
                                   lifecycle: archived.map { .deprecated(.archived(replacement: $0.replacement)) } ?? .current)
    case .local:
        // Only a catalogue model can run (the client finds its file by the entry), so an
        // unlisted ID is named and free, and the request fails as not downloaded.
        return ChatModelDescriptor(provider: .local, id: id, displayName: id, reasoningEffort: nil,
                                   reasoningOutput: .unchanged, refusalFallbacks: false, price: .free)
    }
}

// MARK: - Protocol

public protocol ChatClient {
    /// Sends a single-turn completion and returns the assistant's plain-text reply, with
    /// the tokens the provider says it billed for it.
    func complete(system: String, user: String) async throws -> ChatReply
}

/// What a chat request returned: the reply and, when the provider reported it, its usage.
public struct ChatReply: Equatable, Sendable {
    public let text: String
    public let usage: ChatUsage?

    public init(text: String, usage: ChatUsage?) {
        self.text = text
        self.usage = usage
    }
}

/// The tokens a chat request was billed for, as the provider reported them — Usage
/// prices these instead of estimating from words. The vendors count differently, so each
/// field has one meaning here whatever the wire said: `inputTokens` is *every* input
/// token (OpenAI's `prompt_tokens` already includes its cached ones; Anthropic's
/// `input_tokens` leaves out cache reads and writes, which are added in), and
/// `outputTokens` every output token, reasoning included (both vendors already include
/// it). `cachedInputTokens` and `reasoningTokens` are parts of those totals, never extra.
public struct ChatUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    var cachedInputTokens: Int? = nil
    var reasoningTokens: Int? = nil

    public init(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
    }
}

public enum LLMError: LocalizedError, Sendable {
    case missingAPIKey(LLMProviderType)
    case invalidResponse
    case httpError(Int, String)
    case refused(String?)
    case emptyResponse
    /// The reply ran out of tokens before it ended: only the start of one, never pasted.
    case cutOff
    case noLocalModel
    /// The choice of model was cleared because the one stored leads to no model on offer
    /// (`clearedModelChoice`), and the user has not picked another.
    case noModelChosen(LLMProviderType)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p): "No API key set for \(p.displayName)"
        case .invalidResponse: "Invalid response from the LLM API"
        case .httpError(let code, let body) where ModelUnavailableReply.matches(body):
            "The model isn't available: \(providerErrorReason(in: body) ?? "the service no longer serves it.") (HTTP \(code))"
        case .httpError(let code, let body): "The rewrite failed: \(chatErrorSentence(status: code, body: body)) (HTTP \(code))"
        case .refused(let why): "The model declined the request\(why.map { ": \($0)" } ?? "")"
        case .emptyResponse: "The model returned an empty response"
        case .cutOff: "The model's reply was cut off before it ended."
        case .noLocalModel: "No model on this Mac is ready — choose or download one in Settings › AI Rewrite"
        case .noModelChosen(let p): "No model chosen for \(p.displayName) — choose one in Settings"
        }
    }
}

/// What an AI provider's error reply says, as a sentence the notice and History can show:
/// its own message where the body carries one (`providerErrorReason`, as the transcription
/// errors read it), else what the status means — never the body itself, which may be a
/// proxy's whole HTML page or a rate-limit reply's JSON. The Debug Log keeps the body.
private func chatErrorSentence(status: Int, body: String) -> String {
    let reason = providerErrorReason(in: body) ?? chatErrorReason(forStatus: status)
    return reason.last.map { ".!?".contains($0) } == true ? reason : reason + "."
}

/// The transcription errors' `genericReason`, in words about text rather than a recording.
private func chatErrorReason(forStatus status: Int) -> String {
    switch status {
    case 401, 403: "the API key was rejected"
    case 413: "the text is too long for the service"
    case 429: "too many requests — try again in a moment"
    case 500...: "the service is having problems"
    default: "the request was refused"
    }
}

/// Shared session — URLSession.shared enforces its own 60s timeout regardless of
/// URLRequest.timeoutInterval, so we build our own, as the transcribers do.
private let llmSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 90
    config.timeoutIntervalForResource = 180
    return URLSession(configuration: config)
}()

// MARK: - OpenAI-compatible (Groq + OpenAI)

/// Both Groq and OpenAI expose the same `/chat/completions` shape, so one
/// implementation covers them. They diverge on which parameters they accept —
/// see `Dialect`.
public struct OpenAICompatibleChatClient: ChatClient, Sendable {
    /// The two backends share an endpoint shape but not its parameters.
    public enum Dialect: Sendable {
        /// Groq: classic Chat Completions — `max_tokens` and sampling params accepted.
        case classic
        /// OpenAI's GPT-5.x reasoning models: `max_tokens` and `temperature` are both
        /// rejected with HTTP 400. The output cap moved to `max_completion_tokens`, and
        /// how hard the model thinks before answering is the descriptor's
        /// `reasoningEffort`.
        case reasoning
    }

    let label: String
    let baseURL: URL
    let apiKey: String
    let model: ChatModelDescriptor
    let dialect: Dialect

    public init(label: String, baseURL: URL, apiKey: String, model: ChatModelDescriptor, dialect: Dialect) {
        self.label = label
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.dialect = dialect
    }

    /// The request body, built apart from the network so it can be asserted directly.
    /// The switches are the model's descriptor's; see `chatModelCatalog`.
    func payload(system: String, user: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.id,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        switch dialect {
        case .classic:
            body["max_tokens"] = 8192
            body["temperature"] = 0.3
        case .reasoning:
            body["max_completion_tokens"] = 8192
        }
        if let effort = model.reasoningEffort {
            body["reasoning_effort"] = effort
        }
        switch model.reasoningOutput {
        case .unchanged: break
        case .excluded: body["include_reasoning"] = false
        case .hidden: body["reasoning_format"] = "hidden"
        }
        return body
    }

    public func complete(system: String, user: String) async throws -> ChatReply {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = try JSONSerialization.data(withJSONObject: payload(system: system, user: user))

        let start = CFAbsoluteTimeGetCurrent()
        dlog("LLM", "\(label): sending request, model=\(model.id), input=\(user.count) chars")
        let (data, response) = try await llmSession.data(for: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        // Before the status check: a 429 carries the limit that was hit.
        RateLimitStore.shared.record(vendor: model.provider.vendor, model: model.id, response: response)

        try validatedHTTPResponse(response, data: data, log: "LLM", label: label,
                                  invalidResponse: LLMError.invalidResponse,
                                  httpError: LLMError.httpError)

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        if decoded.choices.first?.finish_reason == "length" {
            dlog("LLM", "\(label): cut off at the output cap\(decoded.usageLog)", level: .notice)
        }
        let text = try decoded.replyText()
        dlog("LLM", "\(label): done in \(String(format: "%.2f", elapsed))s, \(text.count) chars\(decoded.usageLog)")
        return ChatReply(text: text, usage: decoded.chatUsage)
    }
}

/// The `/chat/completions` reply shape, shared by every provider that speaks the
/// OpenAI-compatible dialect: Groq and OpenAI.
struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
        /// `stop` when the model ended the reply, `length` when the output cap did.
        let finish_reason: String?
    }
    /// `prompt_tokens` includes the cached ones and `completion_tokens` the reasoning
    /// ones; the details are parts of them. Groq sends the totals alone.
    struct Usage: Decodable {
        struct PromptDetails: Decodable { let cached_tokens: Int? }
        struct CompletionDetails: Decodable { let reasoning_tokens: Int? }
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let prompt_tokens_details: PromptDetails?
        let completion_tokens_details: CompletionDetails?
    }
    let choices: [Choice]
    let usage: Usage?

    /// Nil when the reply carried no usage, or no token counts in it.
    var chatUsage: ChatUsage? {
        guard let usage, let input = usage.prompt_tokens, let output = usage.completion_tokens else { return nil }
        return ChatUsage(inputTokens: input, outputTokens: output,
                         cachedInputTokens: usage.prompt_tokens_details?.cached_tokens,
                         reasoningTokens: usage.completion_tokens_details?.reasoning_tokens)
    }

    var usageLog: String { chatUsage.map { ", \($0.logLine)" } ?? "" }

    /// The reply's text, or why there is none to paste. A reply the output cap ended is
    /// only the start of one: pasted, it would end a dictation mid-sentence, and an edit
    /// would put it in place of the whole selection.
    func replyText() throws -> String {
        guard let choice = choices.first else { throw LLMError.emptyResponse }
        if choice.finish_reason == "length" { throw LLMError.cutOff }
        // A model whose reasoning cannot be switched off from here (MiniMax M2.7 on Groq
        // documents no control) may still put it inline; strip it before parsing.
        guard let raw = choice.message.content else { throw LLMError.emptyResponse }
        let text = strippingReasoning(raw)
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }
}

extension ChatUsage {
    /// "tokens 1432 in (1024 cached) / 87 out (40 reasoning)" — counts only, for the Debug Log.
    var logLine: String {
        "tokens \(inputTokens) in\(cachedInputTokens.map { " (\($0) cached)" } ?? "") / "
            + "\(outputTokens) out\(reasoningTokens.map { " (\($0) reasoning)" } ?? "")"
    }
}

// MARK: - Anthropic

struct AnthropicChatClient: ChatClient {
    let apiKey: String
    let model: ChatModelDescriptor

    /// The request body, built apart from the network so it can be asserted directly.
    func payload(system: String, user: String) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model.id,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]

        if let effort = model.reasoningEffort {
            payload["output_config"] = ["effort": effort]
        }
        if model.refusalFallbacks {
            payload["fallbacks"] = "default"
        }
        return payload
    }

    /// The `anthropic-beta` header the body's `fallbacks` needs, or nil.
    var betaHeader: String? {
        model.refusalFallbacks ? "server-side-fallback-2026-07-01" : nil
    }

    func complete(system: String, user: String) async throws -> ChatReply {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let betaHeader {
            request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload(system: system, user: user))

        let start = CFAbsoluteTimeGetCurrent()
        dlog("LLM", "Anthropic: sending request, model=\(model.id), input=\(user.count) chars")
        let (data, response) = try await llmSession.data(for: request)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        RateLimitStore.shared.record(vendor: .anthropic, model: model.id, response: response)

        try validatedHTTPResponse(response, data: data, log: "LLM", label: "Anthropic",
                                  invalidResponse: LLMError.invalidResponse,
                                  httpError: LLMError.httpError)

        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        let usage = decoded.usage?.chatUsage

        switch decoded.stop_reason {
        case "refusal":
            dlog("LLM", "Anthropic: refusal (\(decoded.stop_details?.category ?? "unknown"))", level: .error)
        case let reason? where MessagesResponse.cutOffReasons.contains(reason):
            dlog("LLM", "Anthropic: cut off (\(reason))\(usage.map { ", \($0.logLine)" } ?? "")", level: .notice)
        default:
            break
        }
        let text = try decoded.replyText()
        dlog("LLM", "Anthropic: done in \(String(format: "%.2f", elapsed))s, \(text.count) chars\(usage.map { ", \($0.logLine)" } ?? "")")
        return ChatReply(text: text, usage: usage)
    }

    struct MessagesResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct StopDetails: Decodable {
            let category: String?
            let explanation: String?
        }
        /// `input_tokens` leaves out what was read from or written to the prompt cache;
        /// `output_tokens` includes any thinking.
        struct Usage: Decodable {
            let input_tokens: Int
            let output_tokens: Int
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?

            var chatUsage: ChatUsage {
                let read = cache_read_input_tokens ?? 0
                return ChatUsage(inputTokens: input_tokens + read + (cache_creation_input_tokens ?? 0),
                                 outputTokens: output_tokens,
                                 cachedInputTokens: cache_read_input_tokens)
            }
        }
        let content: [Block]
        let stop_reason: String?
        let stop_details: StopDetails?
        let usage: Usage?

        /// The stop reasons that end a reply before the model did: the output cap, and the
        /// context window filling.
        static let cutOffReasons: Set<String> = ["max_tokens", "model_context_window_exceeded"]

        /// The reply's text, or why there is none to paste. A policy decline arrives as
        /// HTTP 200, and so does a reply the output cap or the context window ended, which
        /// is only the start of one — so `stop_reason` is read before the content.
        func replyText() throws -> String {
            if stop_reason == "refusal" { throw LLMError.refused(stop_details?.explanation) }
            if let stop_reason, Self.cutOffReasons.contains(stop_reason) { throw LLMError.cutOff }
            let text = content
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .joined()
            guard !text.isEmpty else { throw LLMError.emptyResponse }
            return text
        }
    }
}

// MARK: - Factory

public enum LLMConfiguration {
    /// When AI Rewrite runs on this Mac, gets its model ready while the user speaks: the
    /// first rewrite after the service went idle otherwise pays the load and the system
    /// prompt at the stop. Nothing for a cloud provider.
    public static func prewarmIfLocal() {
        guard providerType == .local, let model = localChatModel(id: model(for: .local)) else { return }
        LocalChat.prewarm(model)
    }

    public static var providerType: LLMProviderType {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.llmProvider) ?? LLMProviderType.groq.rawValue
        return LLMProviderType(rawValue: raw) ?? .groq
    }

    static func apiKey(for type: LLMProviderType) -> String {
        type.vendor.descriptor.apiKey.map { APIKeyStore.shared.value(for: $0.settingsKey) } ?? ""
    }

    /// The chat model stored for the pick, else its provider's default; empty for a choice
    /// the launch cleared (`clearedModelChoice`).
    public static func model(for type: LLMProviderType) -> String {
        let setting = type.vendor.descriptor.chatModel
        return setting?.settingsKey.flatMap { UserDefaults.standard.string(forKey: $0) } ?? setting?.defaultID ?? ""
    }

    /// True when the selected provider can be called: a non-empty API key for the cloud
    /// providers, a chosen model on this Mac.
    public static var isConfigured: Bool {
        let type = providerType
        if type == .local { return localChatModel(id: model(for: type)) != nil }
        let value = type.needsAPIKey ? apiKey(for: type) : model(for: type)
        return !value.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public static func makeChatClient() throws -> ChatClient {
        let type = providerType
        if type == .local {
            guard let model = localChatModel(id: model(for: type)) else { throw LLMError.noLocalModel }
            return LocalChat.clientFactory(model)
        }
        let key = apiKey(for: type).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMError.missingAPIKey(type) }
        let id = model(for: type)
        guard id != clearedModelChoice else { throw LLMError.noModelChosen(type) }
        let model = chatModel(provider: type, id: id)

        switch type {
        case .groq:
            return OpenAICompatibleChatClient(
                label: "Groq",
                baseURL: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
                apiKey: key, model: model, dialect: .classic
            )
        case .openai:
            return OpenAICompatibleChatClient(
                label: "OpenAI",
                baseURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
                apiKey: key, model: model, dialect: .reasoning
            )
        case .anthropic:
            return AnthropicChatClient(apiKey: key, model: model)
        case .local:
            preconditionFailure("handled above — a model on this Mac has no key to check")
        }
    }
}
