// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How a family of local chat models wants its conversation written out, and how to read
/// its reply. llama.cpp's C API has no Jinja — a model's own `tokenizer.chat_template` is
/// not run — so each family's format is written here by hand, from that template, for
/// the one shape AI Rewrite sends: a system prompt, one user message, and reasoning off.
///
/// Every rendering is checked token for token against `llama-server --jinja` by the
/// rewrite evaluation, and written out literally in `ChatTemplateTests`; a family whose
/// template changes upstream is a change here, made against that diff, never by feel.
public enum ChatTemplateFamily: String, Codable, CaseIterable, Sendable {
    /// Qwen3.5 and Qwen3.8 (`qwen35` in GGUF): chatml. Thinking is switched off as the
    /// template's own `enable_thinking=false` does it — an empty `<think>` block already
    /// written into the assistant turn. Both trim the system and user text. No BOS.
    case qwen
    /// Gemma 4 (`gemma4`): `<|turn>role … <turn|>`, not Gemma 3's `<start_of_turn>`. The
    /// template writes `<bos>` itself, and with thinking off writes an empty thought
    /// channel into the model's turn. Trims the system and user text.
    case gemma4
    /// gpt-oss: OpenAI's Harmony. The template's own system message (identity, cutoff,
    /// date, `Reasoning:`, channels), our system prompt as the developer's `# Instructions`,
    /// and the user's message untrimmed. Reasoning cannot be switched off, only set to
    /// `low`; the model writes an `analysis` message first and the reply in `final`.
    case harmony
}

public enum ChatTemplates {

    /// The prompt for one system + user exchange, ending where the model starts writing.
    /// Special tokens are written as text: the runtime tokenizes it with `parse_special`,
    /// and adds no BOS of its own (Gemma's is in the text, the others take none).
    /// `date` only reaches Harmony, whose system message carries the current date.
    public static func render(_ family: ChatTemplateFamily, system: String, user: String,
                       date: Date = Date()) -> String {
        let prefix = cacheablePrefix(family, system: system, date: date)
        switch family {
        case .qwen:
            return prefix + "\n<|im_start|>user\n\(trimmed(user))<|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
        case .gemma4:
            return prefix + "\n<|turn>user\n\(trimmed(user))<turn|>\n"
                + "<|turn>model\n<|channel>thought\n<channel|>"
        case .harmony:
            return prefix + "<|start|>user<|message|>\(user)<|end|>"
                + "<|start|>assistant"
        }
    }

    /// The start of `render` that depends on the system prompt alone, ending on the special
    /// token that closes the system turn. Tokenization restarts after a special token, so
    /// its tokens are exactly the first tokens of the whole prompt: the runtime reads it
    /// once and restores its state for every later request with the same system prompt.
    public static func cacheablePrefix(_ family: ChatTemplateFamily, system: String, date: Date = Date()) -> String {
        switch family {
        case .qwen:
            return "<|im_start|>system\n\(trimmed(system))<|im_end|>"
        case .gemma4:
            return "<bos><|turn>system\n\(trimmed(system))<turn|>"
        case .harmony:
            return "<|start|>system<|message|>"
                + "You are ChatGPT, a large language model trained by OpenAI.\n"
                + "Knowledge cutoff: 2024-06\n"
                + "Current date: \(harmonyDate(date))\n\n"
                + "Reasoning: low\n\n"
                + "# Valid channels: analysis, commentary, final. Channel must be included for every message."
                + "<|end|>"
                + "<|start|>developer<|message|># Instructions\n\n\(system)\n\n<|end|>"
        }
    }

    /// Whether `generated` — everything the model wrote so far, special tokens included —
    /// is a whole reply. Harmony is the one that needs it: its `<|end|>` closes the
    /// analysis message too, which llama.cpp reports as end-of-generation, so only the
    /// final channel's `<|return|>` (or its `<|end|>`) ends the reply.
    public static func isComplete(_ generated: String, family: ChatTemplateFamily) -> Bool {
        switch family {
        case .qwen: return generated.contains("<|im_end|>")
        case .gemma4: return generated.contains("<turn|>")
        case .harmony:
            if generated.contains("<|return|>") { return true }
            guard let final = generated.range(of: "<|channel|>final") else { return false }
            return generated[final.upperBound...].contains("<|end|>")
        }
    }

    /// The text of the reply, out of everything the model wrote: Harmony's final channel
    /// only, never its analysis; for the others, everything before the end-of-turn marker,
    /// with a reasoning block the model wrote anyway taken off. A Harmony reply cut off
    /// before its final channel has no text — empty, which the caller treats as no reply,
    /// rather than the analysis pasted as if it were the rewrite.
    ///
    /// The runtime writes no end-of-generation token into `generated`, but a reply that
    /// still ends on one the family does not end its turn with — Qwen's `<|endoftext|>`,
    /// Gemma's `<eos>` — loses it here too, so its text cannot be pasted. Only at the very
    /// end: the same letters inside a reply may be words the user dictated.
    public static func reply(from generated: String, family: ChatTemplateFamily) -> String {
        switch family {
        case .qwen:
            let body = generated.components(separatedBy: "<|im_end|>").first ?? ""
            return strippingReasoning(droppingTrailing("<|endoftext|>", from: body))
        case .gemma4:
            var body = droppingTrailing("<eos>", from: generated.components(separatedBy: "<turn|>").first ?? "")
            // A thought channel the model opened anyway: everything up to its close goes.
            if let open = body.range(of: "<|channel>") {
                if let close = body.range(of: "<channel|>", range: open.upperBound..<body.endIndex) {
                    body.removeSubrange(open.lowerBound..<close.upperBound)
                } else {
                    body = String(body[..<open.lowerBound])
                }
            }
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        case .harmony:
            // The final channel's header is not always `final<|message|>`: gpt-oss 20B also
            // writes `final <|constrain|>…<|message|>`, and now and then leaves `<|message|>`
            // out (measured 2026-10-16). Everything after `final`, header tokens taken out.
            guard let final = generated.range(of: "<|channel|>final", options: .backwards) else { return "" }
            var body = String(generated[final.upperBound...])
            for marker in ["<|return|>", "<|end|>", "<|call|>", "<|endoftext|>"] {
                if let end = body.range(of: marker) { body = String(body[..<end.lowerBound]) }
            }
            for header in ["<|constrain|>", "<|message|>"] {
                body = body.replacingOccurrences(of: header, with: "")
            }
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Output tokens a reply may take beyond what its text needs. Harmony writes its
    /// analysis first, from the same budget, so it gets more room: a budget sized for
    /// the reply alone would end inside the analysis and leave no final channel at all.
    public static func reasoningAllowance(_ family: ChatTemplateFamily) -> Int {
        family == .harmony ? 1024 : 0
    }

    /// The output tokens a rewrite of a user message of `inputTokens` is given: twice
    /// them — a rewrite is about as long as what it rewrites, a translation can be longer,
    /// and the message's own tags and context are counted in — and never less than
    /// `minimum`. A fixed budget cut a long selection's rewrite short. The context still
    /// bounds it: `LlamaModel.complete` stops where the context fills, and the app takes
    /// a reply stopped that way for a cut-off one, not a rewrite.
    public static func replyTokens(atLeast minimum: Int, forInputTokens inputTokens: Int) -> Int {
        max(minimum, 2 * inputTokens)
    }

    /// `text` without `marker` at its end, whitespace around it aside.
    private static func droppingTrailing(_ marker: String, from text: String) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.hasSuffix(marker) ? String(body.dropLast(marker.count)) : text
    }

    /// Jinja's `trim`: whitespace and newlines off both ends.
    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `strftime_now("%Y-%m-%d")`, in the Mac's own time zone as llama-server's is.
    private static func harmonyDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// The bytes a model writes, a token's worth at a time, turned into text as soon as they
/// can be. A token is not a character — a Cyrillic letter or an emoji is often split
/// across two — and a model can also write bytes that are not UTF-8 at all. Everything
/// that decodes is handed out at once; only the start of a character still waiting for
/// its next bytes is held back, never more than three; and a byte no character can be
/// made of comes out as U+FFFD, as llama-server writes it. Holding back until the whole
/// pending run decoded, as the runtime once did, let one such byte silence the rest of
/// the reply.
public struct UTF8Accumulator: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    /// The bytes held back for the next piece.
    var heldBytes: Int { pending.count }

    /// Adds one piece's bytes and returns the text they complete.
    public mutating func append<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        pending.append(contentsOf: bytes)
        let ready = pending.count - Self.unfinishedTail(of: pending)
        let text = String(decoding: pending[..<ready], as: UTF8.self)
        pending.removeFirst(ready)
        return text
    }

    /// What is still held at the end — a character the model never finished — as U+FFFD.
    public mutating func flush() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    /// How many bytes at the end of `bytes` begin a character that more bytes could still
    /// finish: a lead byte and the continuation bytes after it, fewer than it announces.
    private static func unfinishedTail(of bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        // A character is at most four bytes, so an unfinished one's lead is at most three
        // from the end.
        for back in 1...min(3, bytes.count) {
            let byte = bytes[bytes.count - back]
            if byte & 0xC0 == 0x80 { continue }
            let length = switch byte {
            case 0xC2...0xDF: 2
            case 0xE0...0xEF: 3
            case 0xF0...0xF4: 4
            default: 1   // ASCII, or a byte no character begins with
            }
            return back < length ? back : 0
        }
        return 0
    }
}

/// What the SpeechTextLLM service is doing, as far as its requests' cancels and its idle
/// exit need: how many jobs are running and have begun, and which requests the app has
/// given up on. A cancel is kept by
/// request, never as one flag for the service: as one flag it was cleared by the completion
/// it was meant to stop when that completion started — after the model's load, or after
/// the prewarm it waited behind, so ⎋ during a cold load was lost — and it stopped whatever
/// was running rather than the request it named. A cancel can also arrive before its
/// request (the app gave up while sending it); it waits for it. One for a request that has
/// already ended stays until the service exits, a few bytes. The service keeps one under
/// its lock; it is here, in the ChatTemplates product the tests import, so the rules are tested.
///
/// The idle exit is armed when the last job ends and carries `started` as it was then; it
/// may exit only while no job has begun since. Freeing the model before the exit takes
/// hundreds of milliseconds, and a request that arrived in them used to be killed with the
/// process — the app saw an interrupted connection and pasted the transcript unrewritten.
public struct LocalChatActivity: Sendable {
    public private(set) var running = 0
    /// Jobs begun since the service started.
    public private(set) var started = 0
    private var cancelled: Set<String> = []

    public init() {}

    public mutating func begin() {
        running += 1
        started += 1
    }

    /// `requestID` is the completion's; nil for a prewarm, which nothing cancels.
    public mutating func end(_ requestID: String?) {
        running -= 1
        if let requestID { cancelled.remove(requestID) }
    }

    public mutating func cancel(_ requestID: String) { cancelled.insert(requestID) }

    public func isCancelled(_ requestID: String) -> Bool { cancelled.contains(requestID) }

    /// Whether an idle exit armed when `started` was `mark` may still exit.
    public func mayExit(armedAt mark: Int) -> Bool { running == 0 && started == mark }
}

/// Removes a leading `<think>…</think>` block.
///
/// A fallback, not the main defence: the local templates write an empty reasoning block
/// for the model, and the cloud clients ask for none. A model that reasons inline anyway
/// would defeat `TextRefinementService.parse` — the `<<mode:NAME>>` marker would no longer
/// lead, so the routing line would be pasted into the user's document along with the
/// model's private deliberation.
///
/// Only a *leading* block is removed, and only a closed one: text that merely contains
/// the word elsewhere is left alone, and an unterminated tag means the reply was cut off
/// rather than that it reasoned, so there is nothing safe to strip.
public func strippingReasoning(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    for tag in ["think", "thinking", "reasoning"] {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard trimmed.hasPrefix(open), let end = trimmed.range(of: close) else { continue }
        return String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}

/// A choice between single-token options read off a model's logits: pure, so it is tested
/// without one (`LlamaModel.chainedProbabilities`).
public enum OptionLogits {
    /// The options' softmax, over them alone.
    public static func probabilities(_ logits: [Double]) -> [Double] {
        let top = logits.max() ?? 0
        let exponents = logits.map { exp($0 - top) }
        let sum = exponents.reduce(0, +)
        return exponents.map { $0 / sum }
    }

    public static func best(_ probabilities: [Double]) -> Int {
        probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0
    }
}
