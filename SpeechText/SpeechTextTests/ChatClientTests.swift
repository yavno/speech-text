// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SpeechTextCore

// MARK: - The chat request body (ChatClients.swift)

final class LLMRequestPayloadTests: XCTestCase {

    private func provider(_ model: String, _ dialect: OpenAICompatibleChatClient.Dialect)
        -> OpenAICompatibleChatClient
    {
        let vendor: LLMProviderType = dialect == .classic ? .groq : .openai
        return OpenAICompatibleChatClient(label: "Test", baseURL: URL(string: "https://example.invalid")!,
                                          apiKey: "k", model: chatModel(provider: vendor, id: model), dialect: dialect)
    }

    private func body(_ model: String, _ dialect: OpenAICompatibleChatClient.Dialect) -> [String: Any] {
        provider(model, dialect).payload(system: "system", user: "user")
    }

    // MARK: The reasoning dialect

    func testReasoningModelIsToldNotToThink() {
        // Unsent, `reasoning_effort` leaves the model on its default effort, which a
        // dictation clean-up pays for in latency and gains nothing from.
        let payload = body("gpt-5.6-luna", .reasoning)
        XCTAssertEqual(payload["reasoning_effort"] as? String, "none")
        XCTAssertEqual(payload["max_completion_tokens"] as? Int, 8192)
    }

    func testEveryCatalogueReasoningModelGetsTheEffort() {
        for model in knownChatModels(of: .openai) {
            // 6.1 Sol rejects `none` (checked 2026-10-26).
            XCTAssertEqual(model.reasoningEffort, model.id == "gpt-6.1-sol" ? "low" : "none", model.id)
        }
    }

    func testAnUnmeasuredModelIsSentNoEffortAtAll() {
        // Only the 5.6 family was measured against the live API. A value a later model
        // rejects is an HTTP 400 and costs the whole rewrite; a default effort only
        // costs time, so anything unknown is sent nothing.
        XCTAssertNil(chatModel(provider: .openai, id: "gpt-6-astra").reasoningEffort)
        XCTAssertNil(body("gpt-6-astra", .reasoning)["reasoning_effort"])
        XCTAssertNil(chatModel(provider: .anthropic, id: "claude-fable-5-1").reasoningEffort)
    }

    func testReasoningDialectSendsNeitherRejectedParameter() {
        let payload = body("gpt-5.6-luna", .reasoning)
        XCTAssertNil(payload["max_tokens"])
        XCTAssertNil(payload["temperature"])
    }

    // MARK: The classic dialect is unchanged

    func testGroqOSSKeepsItsOwnSwitches() {
        let payload = body("openai/gpt-oss-120b", .classic)
        XCTAssertEqual(payload["reasoning_effort"] as? String, "low")
        XCTAssertEqual(payload["include_reasoning"] as? Bool, false)
        XCTAssertNil(payload["reasoning_format"])
        XCTAssertEqual(payload["max_tokens"] as? Int, 8192)
    }

    func testGroqQwenKeepsItsOwnSwitches() {
        let payload = body("qwen/qwen3.8-27b", .classic)
        XCTAssertEqual(payload["reasoning_effort"] as? String, "none")
        XCTAssertEqual(payload["reasoning_format"] as? String, "hidden")
    }

    func testAClassicModelWithNoDocumentedSwitchIsSentNone() {
        let payload = body("minimaxai/minimax-m2.7", .classic)
        XCTAssertNil(payload["reasoning_effort"])
        XCTAssertNil(payload["reasoning_format"])
    }

    func testTheMessagesAreTheSystemAndUserTurns() {
        let messages = body("gpt-5.6-luna", .reasoning)["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?.first?["role"], "system")
        XCTAssertEqual(messages?.last?["content"], "user")
    }
}

// MARK: - Chat model catalogue (ChatClients.swift)

final class ChatModelCatalogTests: XCTestCase {

    func testEveryProviderOffersModelsAndItsDefaultIsOne() {
        for provider in LLMProviderType.allCases {
            XCTAssertFalse(offeredChatModels(of: provider).isEmpty, provider.rawValue)
        }
        XCTAssertNotNil(listedChatModel(provider: .groq, id: "openai/gpt-oss-120b"))
        XCTAssertNotNil(listedChatModel(provider: .anthropic, id: "claude-sonnet-5"))
        XCTAssertNotNil(listedChatModel(provider: .openai, id: "gpt-5.6-luna"))
    }

    func testEveryIDIsListedOnce() {
        let ids = chatModelCatalog.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testTheLocalEntriesAreTheBuiltInCatalogue() {
        XCTAssertEqual(knownChatModels(of: .local).map(\.id), localChatModels.map(\.id))
        XCTAssertEqual(knownChatModels(of: .local).map(\.displayName), localChatModels.map(\.displayName))
        for model in knownChatModels(of: .local) {
            XCTAssertEqual(model.price, .free, model.id)
            // Reasoning is the template's business on this Mac, never a request switch.
            XCTAssertNil(model.reasoningEffort, model.id)
        }
    }

    /// Switches only where a provider's API has them: `reasoning_format` and
    /// `include_reasoning` are Groq's, the refusal fallbacks Anthropic's.
    func testNoModelClaimsASwitchItsProviderLacks() {
        for model in chatModelCatalog {
            if model.reasoningOutput != .unchanged { XCTAssertEqual(model.provider, .groq, model.id) }
            if model.refusalFallbacks { XCTAssertEqual(model.provider, .anthropic, model.id) }
        }
    }

    /// The pickers read the catalogue, in the order and with the names they had.
    func testPickersKeepTheirOrderAndNames() {
        XCTAssertEqual(offeredChatModels(of: .groq).map(\.id), ["openai/gpt-oss-120b", "openai/gpt-oss-20b",
                                                   "qwen/qwen3.8-27b"])
        XCTAssertEqual(offeredChatModels(of: .groq).map(\.displayName), ["GPT-OSS 120B", "GPT-OSS 20B (fastest)",
                                                     "Qwen3.8 27B (preview)"])
        XCTAssertEqual(offeredChatModels(of: .anthropic).map(\.id), ["claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5",
                                                        "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(offeredChatModels(of: .anthropic).map(\.displayName), ["Claude Sonnet 5", "Claude Opus 5", "Claude Haiku 4.5 (fastest)",
                                                                "Claude Sonnet 5.5", "Claude Opus 5.5", "Claude Haiku 5.5"])
        XCTAssertEqual(offeredChatModels(of: .openai).map(\.id), ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol",
                                                     "gpt-6-luna", "gpt-6-sol", "gpt-6.1-sol"])
        XCTAssertEqual(offeredChatModels(of: .openai).map(\.displayName), ["GPT-5.6 Luna — fastest", "GPT-5.6 Terra — balanced",
                                                       "GPT-5.6 Sol — flagship", "GPT-6 Luna", "GPT-6 Sol", "GPT-6.1 Sol"])
    }

    func testAnUnlistedIDIsNamedByItselfAndListedNowhere() {
        XCTAssertNil(listedChatModel(provider: .local, id: "llama3.2:3b"))
        XCTAssertEqual(chatModel(provider: .local, id: "llama3.2:3b").displayName, "llama3.2:3b")
        XCTAssertEqual(chatModel(provider: .local, id: "llama3.2:3b").price, .free)
        XCTAssertNil(listedChatModel(provider: .groq, id: "gpt-5.6-luna"))
    }
}

/// Every catalogue chat model's whole request body, written out literally. A switch sent
/// to a model that rejects it is an HTTP 400 and the whole rewrite lost, so these pin what
/// each model is sent today: a change to how the switches are chosen must leave every one
/// of them as it is.
final class ChatRequestBodyTests: XCTestCase {

    private let turns: [[String: String]] = [["role": "system", "content": "S"], ["role": "user", "content": "U"]]

    private func assertBody(_ body: [String: Any], _ expected: [String: Any], _ model: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(body as NSDictionary, expected as NSDictionary, model, file: file, line: line)
    }

    private func groq(_ model: String) -> [String: Any] {
        OpenAICompatibleChatClient(label: "Groq", baseURL: URL(string: "https://example.invalid")!,
                                   apiKey: "k", model: chatModel(provider: .groq, id: model),
                                   dialect: .classic).payload(system: "S", user: "U")
    }

    private func openAI(_ model: String) -> [String: Any] {
        OpenAICompatibleChatClient(label: "OpenAI", baseURL: URL(string: "https://example.invalid")!,
                                   apiKey: "k", model: chatModel(provider: .openai, id: model),
                                   dialect: .reasoning).payload(system: "S", user: "U")
    }

    func testGroqModels() {
        for model in ["openai/gpt-oss-120b", "openai/gpt-oss-20b"] {
            assertBody(groq(model), ["model": model, "messages": turns, "max_tokens": 8192, "temperature": 0.3,
                                     "reasoning_effort": "low", "include_reasoning": false], model)
        }
        assertBody(groq("qwen/qwen3.8-27b"), ["model": "qwen/qwen3.8-27b", "messages": turns, "max_tokens": 8192,
                                              "temperature": 0.3, "reasoning_effort": "none",
                                              "reasoning_format": "hidden"], "qwen")
        assertBody(groq("minimaxai/minimax-m2.7"), ["model": "minimaxai/minimax-m2.7", "messages": turns,
                                                    "max_tokens": 8192, "temperature": 0.3], "minimax")
    }

    func testOpenAIModels() {
        for model in ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-6-luna", "gpt-6-sol"] {
            assertBody(openAI(model), ["model": model, "messages": turns, "max_completion_tokens": 8192,
                                       "reasoning_effort": "none"], model)
        }
        assertBody(openAI("gpt-6.1-sol"), ["model": "gpt-6.1-sol", "messages": turns, "max_completion_tokens": 8192,
                                           "reasoning_effort": "low"], "gpt-6.1-sol")
    }

    func testAnthropicModels() {
        let userTurn = [["role": "user", "content": "U"]]
        let sonnet = AnthropicChatClient(apiKey: "k", model: chatModel(provider: .anthropic, id: "claude-sonnet-5"))
        assertBody(sonnet.payload(system: "S", user: "U"),
                   ["model": "claude-sonnet-5", "max_tokens": 16000, "system": "S", "messages": userTurn,
                    "output_config": ["effort": "low"]], "sonnet")
        XCTAssertNil(sonnet.betaHeader)

        let opus = AnthropicChatClient(apiKey: "k", model: chatModel(provider: .anthropic, id: "claude-opus-5"))
        assertBody(opus.payload(system: "S", user: "U"),
                   ["model": "claude-opus-5", "max_tokens": 16000, "system": "S", "messages": userTurn,
                    "output_config": ["effort": "low"], "fallbacks": "default"], "opus")
        XCTAssertEqual(opus.betaHeader, "server-side-fallback-2026-07-01")

        let haiku = AnthropicChatClient(apiKey: "k", model: chatModel(provider: .anthropic, id: "claude-haiku-4-5"))
        assertBody(haiku.payload(system: "S", user: "U"),
                   ["model": "claude-haiku-4-5", "max_tokens": 16000, "system": "S", "messages": userTurn], "haiku")
        XCTAssertNil(haiku.betaHeader)

        for id in ["claude-sonnet-5-5", "claude-opus-5-5"] {
            let client = AnthropicChatClient(apiKey: "k", model: chatModel(provider: .anthropic, id: id))
            assertBody(client.payload(system: "S", user: "U"),
                       ["model": id, "max_tokens": 16000, "system": "S", "messages": userTurn,
                        "output_config": ["effort": "low"], "fallbacks": "default"], id)
            XCTAssertEqual(client.betaHeader, "server-side-fallback-2026-07-01")
        }

        // Haiku 5.5 takes the effort, unlike 4.5, but has no server-side fallback.
        let haiku55 = AnthropicChatClient(apiKey: "k", model: chatModel(provider: .anthropic, id: "claude-haiku-5-5"))
        assertBody(haiku55.payload(system: "S", user: "U"),
                   ["model": "claude-haiku-5-5", "max_tokens": 16000, "system": "S", "messages": userTurn,
                    "output_config": ["effort": "low"]], "haiku 5.5")
        XCTAssertNil(haiku55.betaHeader)
    }
}

// MARK: - A chat reply that did not end (ChatClients.swift)

/// What each cloud reply says about how it ended, read from literal bodies: a reply the
/// output cap or the context window ended is only the start of one, and is never pasted —
/// it would end a dictation mid-sentence, or replace a whole selection in an edit.
final class ChatReplyEndingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func isCutOff(_ error: Error) -> Bool {
        if case LLMError.cutOff = error { true } else { false }
    }

    func testAReplyTheOutputCapEndedIsCutOff() throws {
        let groq = try decode(ChatCompletionResponse.self, """
            {"id":"chatcmpl-1","object":"chat.completion","created":1760000000,"model":"openai/gpt-oss-120b",
             "choices":[{"index":0,"message":{"role":"assistant","content":"<<mode:Clean-up>>\\nThe first half of"},
                         "logprobs":null,"finish_reason":"length"}],
             "usage":{"queue_time":0.01,"prompt_tokens":900,"prompt_time":0.02,"completion_tokens":8192,
                      "completion_time":9.1,"total_tokens":9092,"total_time":9.12}}
            """)
        XCTAssertThrowsError(try groq.replyText()) { XCTAssertTrue(self.isCutOff($0), "\($0)") }
        // A reasoning model that spent the cap thinking: no text, and the reason is the cap.
        let openAI = try decode(ChatCompletionResponse.self, """
            {"id":"chatcmpl-2","object":"chat.completion","model":"gpt-5.6-luna",
             "choices":[{"index":0,"message":{"role":"assistant","content":"","refusal":null,"annotations":[]},
                         "finish_reason":"length"}],
             "usage":{"prompt_tokens":1432,"completion_tokens":8192,"total_tokens":9624,
                      "completion_tokens_details":{"reasoning_tokens":8192}}}
            """)
        XCTAssertThrowsError(try openAI.replyText()) { XCTAssertTrue(self.isCutOff($0), "\($0)") }
    }

    func testAReplyTheModelEndedIsItsText() throws {
        let stopped = try decode(ChatCompletionResponse.self, """
            {"choices":[{"index":0,"message":{"role":"assistant","content":"<<mode:Clean-up>>\\nHi."},
                         "finish_reason":"stop"}]}
            """)
        XCTAssertEqual(try stopped.replyText(), "<<mode:Clean-up>>\nHi.")
        // A reply that says nothing of how it ended is taken as before.
        let unsaid = try decode(ChatCompletionResponse.self, #"{"choices":[{"message":{"content":"<think>x</think>Hi."}}]}"#)
        XCTAssertEqual(try unsaid.replyText(), "Hi.")
    }

    func testAnAnthropicReplyTheCapOrTheContextEndedIsCutOff() throws {
        for reason in ["max_tokens", "model_context_window_exceeded"] {
            let reply = try decode(AnthropicChatClient.MessagesResponse.self, """
                {"id":"msg_01","type":"message","role":"assistant","model":"claude-sonnet-5",
                 "content":[{"type":"text","text":"<<mode:Email>>\\nDear Anna,"}],
                 "stop_reason":"\(reason)","stop_sequence":null,"stop_details":null,
                 "usage":{"input_tokens":1200,"output_tokens":16000}}
                """)
            XCTAssertThrowsError(try reply.replyText(), reason) { XCTAssertTrue(self.isCutOff($0), "\(reason): \($0)") }
        }
        let ended = try decode(AnthropicChatClient.MessagesResponse.self, """
            {"content":[{"type":"text","text":"Hi."}],"stop_reason":"end_turn","usage":{"input_tokens":20,"output_tokens":3}}
            """)
        XCTAssertEqual(try ended.replyText(), "Hi.")
    }

    func testARefusalIsStillARefusal() throws {
        let refusal = try decode(AnthropicChatClient.MessagesResponse.self, """
            {"content":[],"stop_reason":"refusal",
             "stop_details":{"type":"refusal","category":"cyber","explanation":"Not this one."},
             "usage":{"input_tokens":20,"output_tokens":0}}
            """)
        XCTAssertThrowsError(try refusal.replyText()) { error in
            guard case LLMError.refused(let why) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(why, "Not this one.")
        }
    }
}

// MARK: - What an AI Rewrite HTTP error says (ChatClients.swift)

/// The notice and History read the provider's own sentence or what the status means —
/// never the reply's body, which may be a proxy's whole HTML page.
final class ChatHTTPErrorWordsTests: XCTestCase {

    func testTheProvidersOwnSentenceIsKept() {
        let groq = #"{"error":{"message":"Rate limit reached for model `openai/gpt-oss-120b` in organization `org_1` service tier `on_demand` on tokens per minute (TPM): Limit 8000, Used 7400, Requested 1200. Please try again in 4.5s.","type":"tokens","code":"rate_limit_exceeded"}}"#
        XCTAssertEqual(LLMError.httpError(429, groq).errorDescription,
                       "The rewrite failed: Rate limit reached for model `openai/gpt-oss-120b` in organization `org_1` "
                           + "service tier `on_demand` on tokens per minute (TPM): Limit 8000, Used 7400, Requested 1200. "
                           + "Please try again in 4.5s. (HTTP 429)")
        let anthropic = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertEqual(LLMError.httpError(529, anthropic).errorDescription, "The rewrite failed: Overloaded. (HTTP 529)")
    }

    func testABodyWithNoMessageIsNamedByItsStatus() {
        let proxy = "<html><head><title>502 Bad Gateway</title></head><body><center><h1>502 Bad Gateway</h1></center></body></html>"
        XCTAssertEqual(LLMError.httpError(502, proxy).errorDescription,
                       "The rewrite failed: the service is having problems. (HTTP 502)")
        XCTAssertEqual(LLMError.httpError(401, "").errorDescription, "The rewrite failed: the API key was rejected. (HTTP 401)")
        XCTAssertEqual(LLMError.httpError(429, "{}").errorDescription,
                       "The rewrite failed: too many requests — try again in a moment. (HTTP 429)")
        XCTAssertEqual(LLMError.httpError(400, "Bad Request").errorDescription,
                       "The rewrite failed: the request was refused. (HTTP 400)")
    }
}
