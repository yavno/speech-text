// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// What the model rows in Settings › Speech to text, Settings › AI Rewrite and setup say, in
// the words of someone choosing one. Pure, so `ModelLanguageTests` can hold every line to
// one rule: a line names no language unless it is one of the user's own, and only a
// `LanguageNote` added for them does that. What a model knows is said by the subtitle's
// count and the "No …" badge (ModelLanguages.swift), never in a sentence.

// MARK: - Speech on this Mac

/// A local speech model's own words, before the notes for the user's languages.
private func speechModelWords(_ model: LocalSTTModel) -> String {
    switch model.id {
    case "openai_whisper-large-v3-v20240930": "As accurate as Turbo, about 30% slower. Needs 24 GB of memory."
    case parakeetUltraModelID: "Parakeet v3 trained further: as accurate on our tests, just as quick."
    case parakeetV3ModelID: "The quickest to answer."
    case "parakeet-redux": "Less than half the download of v3, and slower to answer."
    case "phonon-2": "Parakeet v3 compressed for a single language, as accurate on it."
    case "openai_whisper-large-v3-v20240930_turbo_632MB": "Slower to answer than Parakeet."
    case "openai_whisper-small_216MB": "Small and fast."
    case "openai_whisper-base": "Smaller still, and less accurate."
    case "openai_whisper-tiny": "Many mistakes. Only for a quick test."
    default: model.summary
    }
}

/// What a local speech model's row says: its words, and what we measured in the languages
/// the user speaks.
public func speechModelLine(_ model: LocalSTTModel, spoken: [String]) -> String {
    lineWithLanguageNotes(speechModelWords(model), notes: model.languageNotes, spoken: spoken)
}

/// "483 MB · 25 languages", "378 MB · English only".
public func speechModelSubtitle(_ model: LocalSTTModel) -> String {
    ([model.downloadSizeDescription] + [languageCountLabel(model.languages)].compactMap { $0 })
        .joined(separator: " · ")
}

public func speechModelName(_ model: LocalSTTModel) -> String {
    model.id == "openai_whisper-large-v3-v20240930_turbo_632MB" ? "Whisper Turbo" : model.displayName
}

/// Apple's recogniser, as a row beside the downloaded models. Which of the user's languages
/// it takes on this Mac is asked of macOS and said by the row's badge.
public let appleDictationLine = "Built into macOS, nothing to download. Words appear as you speak."

/// Setup's "On this Mac" card on an Intel Mac.
public let intelSpeechPlaceFacts = "Private and free, but slow on this Mac."

// MARK: - Speech online

/// An online speech model's name in a row, without the catalogue's picker suffix
/// ("— live text"), which the line under it says in words.
public func onlineSpeechModelName(_ model: STTModelDescriptor) -> String {
    model.displayName.components(separatedBy: " — ").first ?? model.displayName
}

private func onlineSpeechModelWords(_ model: STTModelDescriptor) -> String {
    switch model.id {
    case "whisper-large-v3-turbo": "Fast and accurate. Text appears when you stop."
    case "whisper-large-v3": "A little more careful on hard audio, a little slower."
    case "scribe_v2": "Text appears when you stop."
    case elevenLabsRealtimeModel: "Words appear as you speak."
    case "gpt-transcribe": "Text appears when you stop."
    case "gpt-4o-mini-transcribe": "Cheaper, a little less accurate."
    case openAIRealtimeSTTModel: "Words appear as you speak."
    default: model.isRealtime ? "Words appear as you speak." : "Text appears when you stop."
    }
}

public func onlineSpeechModelLine(_ model: STTModelDescriptor, spoken: [String]) -> String {
    lineWithLanguageNotes(onlineSpeechModelWords(model), notes: model.languageNotes, spoken: spoken)
}

/// What each online speech service is good at.
public func onlineSpeechServiceLine(_ service: Provider) -> String {
    switch service {
    case .groq: "Fast Whisper. Text appears when you stop."
    case .elevenLabs: "Strongest on accents and noise. Can show words as you speak."
    case .openAI: "Can show words as you speak. Its key works for AI Rewrite too."
    default: service.displayName
    }
}

// MARK: - AI Rewrite

/// A chat model's name in a row, without the catalogue's picker notes ("(fastest)",
/// "— balanced"), which the line under it says in words.
public func chatModelName(_ model: ChatModelDescriptor) -> String {
    let name = model.displayName.components(separatedBy: " — ").first ?? model.displayName
    return name.replacingOccurrences(of: #" \((fastest|preview)\)$"#, with: "", options: .regularExpression)
}

public func chatModelLine(_ model: ChatModelDescriptor) -> String {
    switch model.id {
    case "openai/gpt-oss-120b": "Clean text in about a second."
    case "openai/gpt-oss-20b": "The fastest, a little less careful."
    case "qwen/qwen3.8-27b": "A preview — Groq may withdraw it."
    case "claude-sonnet-5": "Fast, and writes well."
    case "claude-opus-5": "Writes best. Slower, and costs more."
    case "claude-haiku-4-5": "The fastest."
    case "gpt-5.6-luna": "The fastest."
    case "gpt-5.6-terra": "Balanced."
    case "gpt-5.6-sol": "The flagship. Slower, and costs more."
    default: ""
    }
}

public func onlineAIServiceLine(_ service: Provider) -> String {
    switch service {
    case .groq: "Fast, with a free plan. Its key works for speech too."
    case .anthropic: "Claude. Careful writing, paid."
    case .openAI: "ChatGPT's models, paid. Its key works for speech too."
    default: service.displayName
    }
}

/// What each local chat model is, in a line — from the rewrite evaluation on an M1 Pro —
/// with what we measured in the user's languages, and the memory a heavy one needs.
public func aiModelLine(_ model: LocalChatModel, heavy: Bool, spoken: [String]) -> String {
    let words = switch model.id {
    case "gemma-4-12b-it-qat-q4_0": "The best in our rewrite test. Clean text in 2–4 seconds."
    case "Qwen3.5-9B-Q4_K_M": "A step behind Gemma 4 12B, a little lighter."
    case "Qwen3.5-4B-Q4_K_M": "Works, with some mistakes."
    case "gpt-oss-20b-MXFP4": "OpenAI's open model. Close behind Gemma, and the fastest here."
    case "Qwen3.8-27B-Q4_K_M": "The largest. About 8 seconds a dictation on an M1 Pro."
    default: model.summary
    }
    let line = lineWithLanguageNotes(words, notes: model.languageNotes, spoken: spoken)
    guard heavy else { return line }
    return "\(line) Needs \(Int((Double(model.memoryFloorBytes) / 1_073_741_824).rounded())) GB of memory."
}

/// Under the models on an Intel Mac, which has no GPU llama.cpp can use well.
public let intelChatWarning = "This Mac has an Intel processor: a model runs on it alone, and a rewrite can take a minute or more. An online service is much faster."
