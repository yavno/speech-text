// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import llama
import ChatTemplates

/// The one file that imports llama.cpp: a GGUF chat model loaded and run on this Mac.
/// Compiled into the SpeechTextLLM service and the SpeechTextEvaluation tool only — the
/// app never links llama.framework, so a crash in it ends the service, not the dictation,
/// and the standalone test bundle never has to resolve it.
///
/// One model at a time, one job at a time (`LocalLlamaRuntime` runs every job on one
/// serial queue). The prompt comes from `ChatTemplates`, which
/// is pure and tested; this file only tokenizes, decodes and samples.

/// What one completion did, in the units Usage and the evaluation read.
struct LlamaCompletion: Codable, Equatable, Sendable {
    /// Everything the model wrote, special tokens included — kept for the evaluation,
    /// which checks that no reasoning reached `reply`. The end-of-generation token it
    /// stopped on is left out, except Harmony's (`LlamaModel.complete`).
    var generated: String
    /// The reply's text (`ChatTemplates.reply`).
    var reply: String
    var promptTokens: Int
    /// The part of `promptTokens` restored from the saved system prompt rather than read.
    var cachedPromptTokens: Int = 0
    var outputTokens: Int
    /// Seconds to read the prompt, and from then to the last token.
    var promptSeconds: Double
    var generationSeconds: Double
    /// The model stopped by itself, rather than at the token budget or a cancel.
    var finished: Bool
}

/// The sampling every local rewrite uses: low temperature, as the cloud clients send, and
/// a fixed seed, so a run can be repeated.
struct LlamaSampling: Codable, Equatable, Sendable {
    /// Top-k first, as llama.cpp's own chain does: top-p alone sorts the whole vocabulary
    /// (248 000 tokens for Qwen3.5) on every token.
    var topK: Int32 = 40
    var temperature: Float = 0.3
    var topP: Float = 0.95
    var seed: UInt32 = 42

    static let rewrite = LlamaSampling()
}

enum LlamaError: LocalizedError, Equatable {
    case loadFailed(String)
    case contextFailed
    case tokenizeFailed
    case promptTooLong(tokens: Int, context: Int)
    case decodeFailed(Int32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .loadFailed(let path): "The local model couldn't be loaded (\((path as NSString).lastPathComponent))."
        case .contextFailed: "The local model couldn't start: not enough memory for its context."
        case .tokenizeFailed: "The local model couldn't read the prompt."
        // Read by the user as it stands: the service sends this text back as the error.
        case .promptTooLong: "The text is too long for the model on this Mac."
        case .decodeFailed(let code): "The local model stopped with an error (\(code))."
        case .cancelled: "The local rewrite was cancelled."
        }
    }
}

/// A loaded GGUF model with one context. Not `Sendable`: it lives on the runtime's queue.
final class LlamaModel {
    let path: String
    let family: ChatTemplateFamily
    let contextLength: Int
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    /// The system prompt's tokens and the model's state after reading them. The system
    /// prompt is the same from one dictation to the next (the rewrite prompt is built that
    /// way on purpose), and reading it is most of a rewrite's wait — 880 tokens take Gemma
    /// 4 12B six seconds on an M1 Pro — so it is read once and its state restored after.
    /// A copy of the state, not a trimmed cache: Qwen3.5 and 3.8 are hybrid models whose
    /// recurrent layers cannot be rolled back to a position. Two are kept, most recent
    /// first — AI dictation's system prompt and the Edit shortcut's.
    private var prefixes: [(tokens: [llama_token], state: [UInt8])] = []
    static let savedPrefixes = 2

    /// Bytes held by the saved system prompts' states.
    var savedPrefixBytes: Int { prefixes.reduce(0) { $0 + $1.state.count } }

    /// `contextLength` is set, never left to the model: 0 means the model's own maximum
    /// (262 144 for Qwen3.5), whose KV cache alone would take gigabytes.
    init(path: String, family: ChatTemplateFamily, contextLength: Int = 8192) throws {
        LlamaBackend.start()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw LlamaError.loadFailed(path)
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextLength)
        // The whole prompt in one batch: a rewrite's prompt is a few thousand tokens.
        contextParams.n_batch = UInt32(contextLength)
        contextParams.n_ubatch = 512
        contextParams.n_seq_max = 1
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaError.contextFailed
        }
        self.path = path
        self.family = family
        self.contextLength = contextLength
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// A metadata value from the GGUF header, such as `tokenizer.chat_template`.
    func metadata(_ key: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256 * 1024)
        let length = llama_model_meta_val_str(model, key, &buffer, buffer.count)
        guard length >= 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The prompt as token IDs, exactly as `complete` feeds it — special markers parsed,
    /// no BOS added (the rendering carries one where the family wants it). `addSpecial`
    /// adds the model's own BOS instead, as llama-server does to a rendered template.
    func tokenize(_ text: String, addSpecial: Bool = false) throws -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 16)
        let count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), addSpecial, true)
        guard count >= 0 else { throw LlamaError.tokenizeFailed }
        return Array(tokens.prefix(Int(count)))
    }

    /// Generates a reply to `prompt` (already rendered for this model's family).
    /// `cacheablePrefix` is the part of it that does not change between requests — the
    /// system turn (`ChatTemplates.cacheablePrefix`); its state is saved the first time
    /// and restored after, so only the rest is read.
    /// `shouldCancel` is asked before the prompt is read and between tokens: llama.cpp's
    /// abort callback reaches only CPU execution, and on Metal a token is the smallest unit
    /// that can be stopped.
    func complete(prompt: String, cacheablePrefix: String? = nil, maxTokens: Int,
                  sampling: LlamaSampling = .rewrite,
                  shouldCancel: () -> Bool = { false }) throws -> LlamaCompletion {
        if shouldCancel() { throw LlamaError.cancelled }
        let memory = llama_get_memory(context)
        llama_memory_clear(memory, true)
        let tokens = try tokenize(prompt)
        guard tokens.count + 1 < contextLength else {
            throw LlamaError.promptTooLong(tokens: tokens.count, context: contextLength)
        }
        let budget = min(maxTokens, contextLength - tokens.count - 1)

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(sampler) }
        if sampling.temperature <= 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(sampling.topK))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(sampling.topP, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(sampling.temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(sampling.seed))
        }

        let start = Date()
        var read = 0
        var cached = 0
        // The prefix is used only when the whole prompt's tokens begin with it: it ends on
        // a special token, where tokenization restarts, so that is the expected case.
        if let cacheablePrefix, case let prefix = try tokenize(cacheablePrefix),
           !prefix.isEmpty, prefix.count < tokens.count, tokens.starts(with: prefix) {
            if try restoreOrRead(prefix) { cached = prefix.count }
            read = prefix.count
        }
        try decode(Array(tokens[read...]))
        // Decoding is asynchronous on Metal: without this, reading the prompt would be
        // counted as generating the first token.
        llama_synchronize(context)
        let promptDone = Date()

        var generated = ""
        var bytes = UTF8Accumulator()   // a character split across tokens, or bytes that are not UTF-8
        var produced = 0
        var finished = false
        while produced < budget {
            if shouldCancel() { throw LlamaError.cancelled }
            var token = llama_sampler_sample(sampler, context, -1)
            produced += 1
            // The end of generation is not part of the reply, whichever token the model
            // ended on — Qwen may close with `<|endoftext|>` rather than `<|im_end|>`,
            // Gemma with `<eos>` — so its text is never written in. Harmony's is: its
            // `<|end|>` closes the analysis too, the model carries on into `final`, and
            // `isComplete` reads where the reply ends.
            if llama_vocab_is_eog(vocab, token), family != .harmony { finished = true; break }
            generated += bytes.append(piece(token).lazy.map { UInt8(bitPattern: $0) })
            if ChatTemplates.isComplete(generated, family: family) { finished = true; break }
            let next = llama_decode(context, llama_batch_get_one(&token, 1))
            guard next == 0 else { throw LlamaError.decodeFailed(next) }
        }
        generated += bytes.flush()
        let end = Date()
        return LlamaCompletion(
            generated: generated,
            reply: ChatTemplates.reply(from: generated, family: family),
            promptTokens: tokens.count, cachedPromptTokens: cached, outputTokens: produced,
            promptSeconds: promptDone.timeIntervalSince(start),
            generationSeconds: end.timeIntervalSince(promptDone),
            finished: finished)
    }

    /// Reads the cacheable prefix of a prompt ahead of it — while the user is still
    /// speaking — so the request that follows restores it instead.
    func cache(prefix text: String) throws {
        let prefix = try tokenize(text)
        guard !prefix.isEmpty else { return }
        _ = try restoreOrRead(prefix)
    }

    /// Leaves the context holding exactly `prefix`: restored from a saved state (true), or
    /// read and its state saved for next time (false).
    private func restoreOrRead(_ prefix: [llama_token]) throws -> Bool {
        let memory = llama_get_memory(context)
        llama_memory_clear(memory, true)
        if let index = prefixes.firstIndex(where: { $0.tokens == prefix }),
           llama_state_seq_set_data(context, prefixes[index].state, prefixes[index].state.count, 0)
            == prefixes[index].state.count {
            prefixes.insert(prefixes.remove(at: index), at: 0)
            return true
        }
        llama_memory_clear(memory, true)
        try decode(prefix)
        llama_synchronize(context)
        let size = llama_state_seq_get_size(context, 0)
        var state = [UInt8](repeating: 0, count: size)
        prefixes.removeAll { $0.tokens == prefix }
        if size > 0, llama_state_seq_get_data(context, &state, size, 0) == size {
            prefixes.insert((prefix, state), at: 0)
            prefixes = Array(prefixes.prefix(Self.savedPrefixes))
        }
        return false
    }

    private func decode(_ tokens: [llama_token]) throws {
        var tokens = tokens
        let status = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard status == 0 else { throw LlamaError.decodeFailed(status) }
    }

    /// One token's bytes, special tokens written out (`<|im_end|>`, `<|channel|>`), so the
    /// template's markers can be read in the text.
    private func piece(_ token: llama_token) -> [CChar] {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        }
        return Array(buffer.prefix(Int(max(0, length))))
    }
}

/// llama.cpp's process-wide state: the backend, once, and its log kept quiet — it writes
/// every tensor it loads to stderr otherwise.
enum LlamaBackend {
    private static let once: Void = {
        llama_log_set({ level, text, _ in
            guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let text else { return }
            FileHandle.standardError.write(Data(String(cString: text).utf8))
        }, nil)
        llama_backend_init()
    }()

    static func start() { _ = once }
}

/// The model in memory and the queue in front of it. Loading is the expensive part —
/// seconds, the weights mapped from disk — so one model stays loaded until another is
/// asked for or it is unloaded.
///
/// Every call runs on one serial queue at user-initiated priority, not on Swift's
/// cooperative pool: generating a token is a small Metal graph whose encoding is CPU
/// work, and at the pool's default priority it ran at half llama.cpp's own speed
/// (Gemma 4 12B on an M1 Pro: 10 tokens/s against 20). The queue also keeps jobs strictly
/// one at a time, which one context requires.
///
/// `@unchecked Sendable` because the queue, not a lock, is what protects it: `loaded` —
/// its one mutable field, and the non-`Sendable` llama.cpp state behind it — is touched
/// only inside `run`, on `queue`, and only `Sendable` values come back out.
final class LocalLlamaRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.speech-text.llama", qos: .userInitiated)
    /// Touched only on `queue`.
    private var loaded: LlamaModel?

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    var loadedPath: String? {
        get async { (try? await run { self.loaded?.path }) ?? nil }
    }

    /// Loads `path` unless it is already the model in memory; returns the seconds it took
    /// (0 when it was already loaded).
    @discardableResult
    func load(path: String, family: ChatTemplateFamily, contextLength: Int = 8192) async throws -> Double {
        try await run {
            if let loaded = self.loaded, loaded.path == path, loaded.family == family,
               loaded.contextLength == contextLength { return 0 }
            self.loaded = nil
            let start = Date()
            self.loaded = try LlamaModel(path: path, family: family, contextLength: contextLength)
            return Date().timeIntervalSince(start)
        }
    }

    /// Reads each system prompt's cacheable prefix into the loaded model, last one first
    /// so the first is the most recently used.
    func cache(systems: [String], date: Date = Date()) async throws {
        try await run {
            guard let model = self.loaded else { throw LlamaError.loadFailed("no model loaded") }
            for system in systems.reversed() {
                try model.cache(prefix: ChatTemplates.cacheablePrefix(model.family, system: system, date: date))
            }
        }
    }

    /// Frees the model — with a `path`, only if it is the one loaded.
    func unload(ifLoaded path: String? = nil) async {
        _ = try? await run {
            if path == nil || self.loaded?.path == path { self.loaded = nil }
        }
    }

    /// Frees the model on the calling thread, waiting for any job first — unless `stillIdle`,
    /// asked once it is the queue's turn, says a job came in meanwhile and needs it. For a
    /// process about to exit: ggml asserts at exit if Metal still holds a model's buffers.
    func unloadNow(if stillIdle: () -> Bool = { true }) {
        queue.sync { if stillIdle() { loaded = nil } }
    }

    /// `shouldCancel` is asked before the prompt is read and between tokens, on the queue —
    /// the caller's own answer for this request, so a cancel stops the request it names
    /// whether it came while the job ran or while the job waited its turn.
    func complete(system: String, user: String, maxTokens: Int,
                  sampling: LlamaSampling = .rewrite, date: Date = Date(),
                  shouldCancel: @escaping @Sendable () -> Bool = { false }) async throws -> LlamaCompletion {
        try await run {
            guard let model = self.loaded else { throw LlamaError.loadFailed("no model loaded") }
            let prompt = ChatTemplates.render(model.family, system: system, user: user, date: date)
            return try model.complete(prompt: prompt,
                                      cacheablePrefix: ChatTemplates.cacheablePrefix(model.family, system: system, date: date),
                                      maxTokens: maxTokens + ChatTemplates.reasoningAllowance(model.family),
                                      sampling: sampling, shouldCancel: shouldCancel)
        }
    }

    func tokenize(_ text: String, addSpecial: Bool = false) async throws -> [Int32] {
        try await run {
            guard let model = self.loaded else { throw LlamaError.loadFailed("no model loaded") }
            return try model.tokenize(text, addSpecial: addSpecial)
        }
    }

    func metadata(_ key: String) async -> String? {
        (try? await run { self.loaded?.metadata(key) }) ?? nil
    }
}

/// The process's own memory as the system counts it (`phys_footprint`, what Activity
/// Monitor's Memory column shows) — not RSS, which counts the mapped weights and Metal's
/// buffers in ways that say little about pressure.
func processFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}
