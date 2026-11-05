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
    case "openai_whisper-large-v3-v20240930": localized("As accurate as Turbo, about 30% slower. Needs 24 GB of memory.")
    case parakeetUltraModelID: localized("Parakeet v3 trained further: as accurate on our tests, just as quick.")
    case parakeetV3ModelID: localized("The quickest to answer.")
    case "parakeet-redux": localized("Less than half the download of v3, and slower to answer.")
    case "phonon-2": localized("Parakeet v3 compressed for a single language, as accurate on it.")
    case "openai_whisper-large-v3-v20240930_turbo_632MB": localized("Slower to answer than Parakeet.")
    case "openai_whisper-small_216MB": localized("Small and fast.")
    case "openai_whisper-base": localized("Smaller still, and less accurate.")
    case "openai_whisper-tiny": localized("Many mistakes. Only for a quick test.")
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
public let appleDictationLine = localized("Built into macOS, nothing to download. Words appear as you speak.")

/// Setup's "On this Mac" card on an Intel Mac.
public let intelSpeechPlaceFacts = localized("Private and free, but slow on this Mac.")

// MARK: - Speech online

/// An online speech model's name in a row, without the catalogue's picker suffix
/// ("— live text"), which the line under it says in words.
public func onlineSpeechModelName(_ model: STTModelDescriptor) -> String {
    model.displayName.components(separatedBy: " — ").first ?? model.displayName
}

private func onlineSpeechModelWords(_ model: STTModelDescriptor) -> String {
    switch model.id {
    case "whisper-large-v3-turbo": localized("Fast and accurate. Text appears when you stop.")
    case "whisper-large-v3": localized("A little more careful on hard audio, a little slower.")
    case "scribe_v2": localized("Text appears when you stop.")
    case elevenLabsRealtimeModel: localized("Words appear as you speak.")
    case "gpt-transcribe": localized("Text appears when you stop.")
    case "gpt-4o-mini-transcribe": localized("Cheaper, a little less accurate.")
    case openAIRealtimeSTTModel: localized("Words appear as you speak.")
    default: model.isRealtime ? localized("Words appear as you speak.") : localized("Text appears when you stop.")
    }
}

public func onlineSpeechModelLine(_ model: STTModelDescriptor, spoken: [String]) -> String {
    lineWithLanguageNotes(onlineSpeechModelWords(model), notes: model.languageNotes, spoken: spoken)
}

/// What each online speech service is good at.
public func onlineSpeechServiceLine(_ service: Provider) -> String {
    switch service {
    case .groq: localized("Fast Whisper. Text appears when you stop.")
    case .elevenLabs: localized("Strongest on accents and noise. Can show words as you speak.")
    case .openAI: localized("Can show words as you speak. Its key works for AI Rewrite too.")
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
    case "openai/gpt-oss-120b": localized("Clean text in about a second.")
    case "openai/gpt-oss-20b": localized("The fastest, a little less careful.")
    case "qwen/qwen3.8-27b": localized("A preview — Groq may withdraw it.")
    case "claude-sonnet-5-5": localized("Fast, and writes well.")
    case "claude-opus-5-5": localized("Writes best. Slower, and costs more.")
    case "claude-haiku-5-5": localized("The cheapest, for short clean-ups.")
    case "claude-sonnet-5": localized("The previous Sonnet, at the same price.")
    case "claude-opus-5": localized("The previous Opus. Costs more than Opus 5.5.")
    case "claude-haiku-4-5": localized("The previous Haiku, at ten times the price.")
    case "gpt-6-luna": localized("Fast and cheap.")
    case "gpt-6.1-terra": localized("Balanced.")
    case "gpt-6.1-sol": localized("The flagship. Slower, and costs more.")
    case "gpt-6-sol": localized("The previous Sol, at the same price.")
    case "gpt-5.6-luna": localized("The previous Luna. Costs about twice as much.")
    case "gpt-5.6-terra": localized("The previous Terra. Costs about twice as much.")
    case "gpt-5.6-sol": localized("The previous Sol. Costs twice as much.")
    default: ""
    }
}

public func onlineAIServiceLine(_ service: Provider) -> String {
    switch service {
    case .groq: localized("Fast, with a free plan. Its key works for speech too.")
    case .anthropic: localized("Claude. Careful writing, paid.")
    case .openAI: localized("ChatGPT's models, paid. Its key works for speech too.")
    default: service.displayName
    }
}

/// What each local chat model is, in a line — from the rewrite evaluation on an M1 Pro —
/// with what we measured in the user's languages, and the memory a heavy one needs.
public func aiModelLine(_ model: LocalChatModel, heavy: Bool, spoken: [String]) -> String {
    let words = switch model.id {
    case "gemma-4-12b-it-qat-q4_0": localized("The best in our rewrite test. Clean text in 2–4 seconds.")
    case "Qwen3.5-9B-Q4_K_M": localized("A step behind Gemma 4 12B, a little lighter.")
    case "Qwen3.5-4B-Q4_K_M": localized("Works, with some mistakes.")
    case "gpt-oss-20b-MXFP4": localized("OpenAI's open model. Close behind Gemma, and the fastest here.")
    case "Qwen3.8-27B-Q4_K_M": localized("The largest. About 8 seconds a dictation on an M1 Pro.")
    default: model.summary
    }
    let line = lineWithLanguageNotes(words, notes: model.languageNotes, spoken: spoken)
    guard heavy else { return line }
    let gigabytes = Int((Double(model.memoryFloorBytes) / 1_073_741_824).rounded())
    return line + " " + localized("Needs \(gigabytes) GB of memory.")
}

/// Under the models on an Intel Mac, which has no GPU llama.cpp can use well.
public let intelChatWarning = localized("This Mac has an Intel processor: a model runs on it alone, and a rewrite can take a minute or more. An online service is much faster.")
