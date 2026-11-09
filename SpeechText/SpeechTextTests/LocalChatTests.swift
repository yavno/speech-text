// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ChatTemplates
@testable import SpeechTextCore

private let gb: UInt64 = 1_073_741_824

private func mac(ram: UInt64, disk: UInt64 = 2000, appleSilicon: Bool = true) -> SystemCapabilities {
    SystemCapabilities(chipName: appleSilicon ? "Apple M5" : "Intel Core i7",
                       isAppleSilicon: appleSilicon, cores: 10,
                       memoryBytes: ram * gb, freeDiskBytes: disk * gb, systemMajorVersion: 26)
}

// MARK: - Templates

/// Each family's prompt written out whole. These strings are what the rewrite evaluation
/// compared, token for token, with the model's own Jinja template in `llama-server --jinja`
/// (b11696, 2026-10-16); a change here is a change to what the model reads, and needs
/// that comparison run again.
final class ChatTemplateTests: XCTestCase {

    func testQwenIsChatmlWithThinkingSwitchedOffAndItsTextTrimmed() {
        XCTAssertEqual(
            ChatTemplates.render(.qwen, system: "Rules.\n", user: "\n<transcript>\nпривіт\n</transcript>\n"),
            "<|im_start|>system\nRules.<|im_end|>\n"
                + "<|im_start|>user\n<transcript>\nпривіт\n</transcript><|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n")
    }

    func testGemma4CarriesItsOwnBOSAndAnEmptyThoughtChannel() {
        XCTAssertEqual(
            ChatTemplates.render(.gemma4, system: " Rules. ", user: "Hi"),
            "<bos><|turn>system\nRules.<turn|>\n<|turn>user\nHi<turn|>\n<|turn>model\n<|channel>thought\n<channel|>")
    }

    func testHarmonyPutsOurPromptInTheDeveloperMessageAtLowReasoning() {
        let date = ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z")!
        XCTAssertEqual(
            ChatTemplates.render(.harmony, system: "Rules.", user: " Hi ", date: date),
            "<|start|>system<|message|>You are ChatGPT, a large language model trained by OpenAI.\n"
                + "Knowledge cutoff: 2024-06\nCurrent date: 2026-10-16\n\nReasoning: low\n\n"
                + "# Valid channels: analysis, commentary, final. Channel must be included for every message.<|end|>"
                + "<|start|>developer<|message|># Instructions\n\nRules.\n\n<|end|>"
                + "<|start|>user<|message|> Hi <|end|>"
                + "<|start|>assistant")
    }

    func testEachFamilyKnowsWhereItsReplyEnds() {
        XCTAssertFalse(ChatTemplates.isComplete("<<mode:Clean-up>>\nТекст", family: .qwen))
        XCTAssertTrue(ChatTemplates.isComplete("Текст<|im_end|>", family: .qwen))
        XCTAssertTrue(ChatTemplates.isComplete("Текст<turn|>", family: .gemma4))
    }

    /// Harmony's analysis message ends in `<|end|>` too — which llama.cpp reports as the
    /// end of generation — and the reply has not even started there.
    func testHarmonyIsNotCompleteAtTheEndOfItsAnalysis() {
        let analysis = "<|channel|>analysis<|message|>User wants clean-up.<|end|>"
        XCTAssertFalse(ChatTemplates.isComplete(analysis, family: .harmony))
        XCTAssertFalse(ChatTemplates.isComplete(analysis + "<|start|>assistant<|channel|>final<|message|>Текст",
                                                family: .harmony))
        XCTAssertTrue(ChatTemplates.isComplete(analysis + "<|start|>assistant<|channel|>final<|message|>Текст<|return|>",
                                               family: .harmony))
        XCTAssertTrue(ChatTemplates.isComplete(analysis + "<|start|>assistant<|channel|>final<|message|>Текст<|end|>",
                                               family: .harmony))
    }

    func testHarmonyReplyIsTheFinalChannelOnly() {
        let generated = "<|channel|>analysis<|message|>Mode: Clean-up. Output text.<|end|>"
            + "<|start|>assistant<|channel|>final<|message|><<mode:Clean-up>>\nЗавтра зустріч.<|return|>"
        XCTAssertEqual(ChatTemplates.reply(from: generated, family: .harmony), "<<mode:Clean-up>>\nЗавтра зустріч.")
    }

    /// Both header shapes gpt-oss 20B was measured writing besides the plain one.
    func testHarmonyFinalChannelIsReadWhateverItsHeader() {
        let constrained = "<|channel|>analysis<|message|>Clean-up.<|end|><|start|>assistant<|channel|>final "
            + "<|constrain|><<mode:Clean-up>><|message|>The build is green.<|return|>"
        XCTAssertTrue(ChatTemplates.isComplete(constrained, family: .harmony))
        XCTAssertEqual(ChatTemplates.reply(from: constrained, family: .harmony), "<<mode:Clean-up>>The build is green.")
        let noMessage = "<|channel|>analysis<|message|>A message.<|end|><|start|>assistant<|channel|>final "
            + "<|constrain|><<mode:Message>> так, давай<|end|>"
        XCTAssertTrue(ChatTemplates.isComplete(noMessage, family: .harmony))
        XCTAssertEqual(ChatTemplates.reply(from: noMessage, family: .harmony), "<<mode:Message>> так, давай")
    }

    /// Cut off by the token budget inside its analysis: no reply, rather than the
    /// model's reasoning pasted as if it were the rewrite.
    func testHarmonyCutOffBeforeItsFinalChannelHasNoReply() {
        XCTAssertEqual(ChatTemplates.reply(from: "<|channel|>analysis<|message|>The user wants", family: .harmony), "")
    }

    func testQwenReplyLosesItsEndMarkerAndAnyReasoningBlock() {
        XCTAssertEqual(ChatTemplates.reply(from: "<<mode:Clean-up>>\nТекст.<|im_end|>", family: .qwen),
                       "<<mode:Clean-up>>\nТекст.")
        XCTAssertEqual(ChatTemplates.reply(from: "<think>\nhmm\n</think>\n\nТекст.<|im_end|>", family: .qwen), "Текст.")
    }

    func testGemmaReplyLosesAThoughtChannelItOpenedAnyway() {
        XCTAssertEqual(ChatTemplates.reply(from: "Текст.<turn|>", family: .gemma4), "Текст.")
        XCTAssertEqual(ChatTemplates.reply(from: "<|channel>thought\nhmm<channel|>Текст.<turn|>", family: .gemma4), "Текст.")
        XCTAssertEqual(ChatTemplates.reply(from: "Текст.<|channel>thought\nunfinished", family: .gemma4), "Текст.")
    }

    /// A model may stop on an end-of-generation token that is not its family's end of
    /// turn. The runtime no longer writes one in; a reply that still ends on one loses it.
    func testAnEndOfGenerationTokenAtTheEndIsNotPasted() {
        XCTAssertEqual(ChatTemplates.reply(from: "<<mode:Clean-up>>\nТекст.<|endoftext|>", family: .qwen),
                       "<<mode:Clean-up>>\nТекст.")
        XCTAssertEqual(ChatTemplates.reply(from: "<think>\nhmm\n</think>\n\nТекст.<|endoftext|>\n", family: .qwen), "Текст.")
        XCTAssertEqual(ChatTemplates.reply(from: "Текст.\n<eos>", family: .gemma4), "Текст.")
        XCTAssertEqual(ChatTemplates.reply(from: "<|channel|>analysis<|message|>Clean-up.<|end|>"
                                           + "<|start|>assistant<|channel|>final<|message|>Текст.<|endoftext|>",
                                           family: .harmony), "Текст.")
    }

    /// Only at the very end: the same letters inside a reply may be what the user said.
    func testTheSameLettersInsideAReplyAreKept() {
        let dictated = "Модель закінчує відповідь токеном <eos> чи <|endoftext|>, а не текстом."
        XCTAssertEqual(ChatTemplates.reply(from: dictated + "<turn|>", family: .gemma4), dictated)
        XCTAssertEqual(ChatTemplates.reply(from: dictated + "<|im_end|>", family: .qwen), dictated)
    }

    /// A fixed 2048-token budget cut a long selection's rewrite short, and the cut-off
    /// rewrite replaced the whole selection. The context bounds what this asks for.
    func testALongMessageIsGivenRoomForItsOwnLength() {
        XCTAssertEqual(ChatTemplates.replyTokens(atLeast: 2048, forInputTokens: 0), 2048)
        XCTAssertEqual(ChatTemplates.replyTokens(atLeast: 2048, forInputTokens: 600), 2048)
        XCTAssertEqual(ChatTemplates.replyTokens(atLeast: 2048, forInputTokens: 3000), 6000)
    }

    func testOnlyHarmonyIsGivenRoomToReason() {
        XCTAssertEqual(ChatTemplates.reasoningAllowance(.qwen), 0)
        XCTAssertEqual(ChatTemplates.reasoningAllowance(.gemma4), 0)
        XCTAssertGreaterThan(ChatTemplates.reasoningAllowance(.harmony), 0)
    }
}

// MARK: - The reply's bytes

/// A token is not a character: what the runtime reads out of each piece, and what is left
/// of a reply when the model writes a byte that is not UTF-8.
final class UTF8AccumulatorTests: XCTestCase {
    private let mixed = "Hi, Привіт! 你好 😀 👨‍👩‍👧."

    private func feed(_ pieces: [[UInt8]]) -> (text: String, mostHeld: Int) {
        var accumulator = UTF8Accumulator()
        var text = ""
        var mostHeld = 0
        for piece in pieces {
            text += accumulator.append(piece)
            mostHeld = max(mostHeld, accumulator.heldBytes)
        }
        return (text + accumulator.flush(), mostHeld)
    }

    func testTextSplitAnywhereComesOutWhole() {
        let bytes = Array(mixed.utf8)
        for cut in 0...bytes.count {
            let (text, mostHeld) = feed([Array(bytes[..<cut]), Array(bytes[cut...])])
            XCTAssertEqual(text, mixed, "cut at byte \(cut)")
            XCTAssertLessThanOrEqual(mostHeld, 3)
        }
        let (text, mostHeld) = feed(bytes.map { [$0] })
        XCTAssertEqual(text, mixed, "byte by byte")
        XCTAssertLessThanOrEqual(mostHeld, 3)
    }

    func testACharacterIsHandedOutTheMomentItIsWhole() {
        var accumulator = UTF8Accumulator()
        XCTAssertEqual(accumulator.append([0xD0]), "")   // the first half of «П»
        XCTAssertEqual(accumulator.heldBytes, 1)
        XCTAssertEqual(accumulator.append([0x9F] + Array("ри".utf8)), "При")
        XCTAssertEqual(accumulator.append([0xF0, 0x9F]), "")   // half of «😀»
        XCTAssertEqual(accumulator.append([0x98]), "")
        XCTAssertEqual(accumulator.append([0x80]), "😀")
        XCTAssertEqual(accumulator.heldBytes, 0)
    }

    /// The regression: the runtime used to hold every byte back until the whole run
    /// decoded, so one byte that never could silenced the rest of the reply.
    func testAByteThatIsNotUTF8DoesNotSilenceWhatFollows() {
        let (text, _) = feed([Array("При".utf8), [0xFF], Array("віт, ".utf8), Array("світе.".utf8)])
        XCTAssertEqual(text, "При\u{FFFD}віт, світе.")
    }

    func testALeadByteWithNoCharacterAfterItIsReplaced() {
        XCTAssertEqual(feed([[0xD0], Array("x".utf8)]).text, "\u{FFFD}x")
        XCTAssertEqual(feed([[0xE2, 0x82], Array(" ok".utf8)]).text, "\u{FFFD} ok")
    }

    func testACharacterTheModelNeverFinishedIsReplacedAtTheEnd() {
        var accumulator = UTF8Accumulator()
        XCTAssertEqual(accumulator.append(Array("Так".utf8) + [0xF0, 0x9F]), "Так")
        XCTAssertEqual(accumulator.flush(), "\u{FFFD}")
        XCTAssertEqual(accumulator.heldBytes, 0)
    }
}

// MARK: - The service's requests

/// `LocalChatActivity`, the SpeechTextLLM service's bookkeeping of what it is doing: the
/// service is a process the test bundle cannot start, so its rules are held here.
final class LocalChatActivityTests: XCTestCase {

    /// ⎋ while the model loads: the cancel comes before the completion's own steps start,
    /// and nothing the request does on its way to the first token clears it.
    func testACancelDuringTheLoadIsStillThereWhenTheReplyWouldStart() {
        var activity = LocalChatActivity()
        activity.begin()
        activity.cancel("dictation")
        XCTAssertTrue(activity.isCancelled("dictation"))
        activity.end("dictation")
        XCTAssertFalse(activity.isCancelled("dictation"))
        XCTAssertEqual(activity.running, 0)
    }

    /// A rewrite queued behind another job: a cancel of one is not a cancel of the other.
    func testACancelStopsOnlyTheRequestItNames() {
        var activity = LocalChatActivity()
        activity.begin()   // a prewarm, which nothing cancels
        activity.begin()
        activity.begin()
        activity.cancel("second")
        XCTAssertFalse(activity.isCancelled("first"))
        XCTAssertTrue(activity.isCancelled("second"))
        activity.end("first")
        XCTAssertTrue(activity.isCancelled("second"))
        XCTAssertEqual(activity.running, 2)
    }

    /// The app gave up while it was sending the request: the cancel can arrive first.
    func testACancelThatArrivesBeforeItsRequestWaitsForIt() {
        var activity = LocalChatActivity()
        activity.cancel("early")
        activity.begin()
        XCTAssertTrue(activity.isCancelled("early"))
    }

    func testFiveIdleMinutesAfterTheLastJobTheServiceMayExit() {
        var activity = LocalChatActivity()
        activity.begin()
        activity.end("rewrite")
        XCTAssertTrue(activity.mayExit(armedAt: activity.started))
    }

    /// The review's case: a rewrite that arrives while the idle exit is freeing the model.
    /// It keeps the service — whether it is still running at the exit's last look, or was
    /// quick enough to have ended already — and its own end arms the next exit.
    func testARequestThatBeganAfterTheExitWasArmedKeepsTheService() {
        var activity = LocalChatActivity()
        activity.begin()
        activity.end(nil)
        let mark = activity.started
        activity.begin()
        XCTAssertFalse(activity.mayExit(armedAt: mark))
        activity.end("rewrite")
        XCTAssertFalse(activity.mayExit(armedAt: mark))
        XCTAssertTrue(activity.mayExit(armedAt: activity.started))
    }
}

// MARK: - Catalogue

final class LocalChatCatalogTests: XCTestCase {

    func testCatalogueIsHeaviestFirstWithUniqueIDs() {
        let sizes = localChatModels.map(\.downloadBytes)
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        XCTAssertEqual(Set(localChatModels.map(\.id)).count, localChatModels.count)
    }

    /// The download is checked against `sha256` and fetched from a pinned commit, so the
    /// bytes cannot change under the hash; the id is the file name, as the folder is.
    func testEveryModelIsPinnedAndHashed() {
        for model in localChatModels {
            XCTAssertEqual(model.sha256.count, 64, model.id)
            XCTAssertTrue(model.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, model.id)
            XCTAssertEqual(model.revision.count, 40, model.id)
            XCTAssertEqual(model.file, model.id + ".gguf")
            XCTAssertEqual(model.downloadURL.absoluteString,
                           "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(model.file)")
            XCTAssertGreaterThan(model.memoryFloorBytes, UInt64(model.downloadBytes), model.id)
        }
    }

    func testEveryPickIsInTheCatalogue() {
        for tier in MacTier.allCases {
            let picks = localChatPicks(for: tier)
            XCTAssertFalse(picks.recommended.isEmpty, "\(tier)")
            for id in picks.recommended + picks.bestQuality {
                XCTAssertNotNil(localChatModel(id: id), "\(tier): \(id)")
            }
        }
    }

    func testEachTierGetsItsPair() {
        XCTAssertEqual(recommendedLocalChatModel(for: mac(ram: 8))?.id, "Qwen3.5-4B-Q4_K_M")
        XCTAssertEqual(recommendedLocalChatModel(for: mac(ram: 16))?.id, "gemma-4-12b-it-qat-q4_0")
        XCTAssertEqual(recommendedLocalChatModel(for: mac(ram: 32))?.id, "gemma-4-12b-it-qat-q4_0")
        XCTAssertEqual(bestQualityLocalChatModel(for: mac(ram: 24))?.id, "gpt-oss-20b-MXFP4")
        XCTAssertEqual(bestQualityLocalChatModel(for: mac(ram: 32))?.id, "gpt-oss-20b-MXFP4")
        XCTAssertEqual(bestQualityLocalChatModel(for: mac(ram: 64))?.id, "gpt-oss-20b-MXFP4")
    }

    /// A Mac without the disk for gpt-oss 20B (12.1 GB) steps down rather than overfilling.
    func testBottomOfATierStepsDown() {
        XCTAssertEqual(bestQualityLocalChatModel(for: mac(ram: 32, disk: 12))?.id, "gemma-4-12b-it-qat-q4_0")
    }

    func testIntelIsOfferedTheSmallModelFirst() {
        XCTAssertEqual(recommendedLocalChatModel(for: mac(ram: 32, appleSilicon: false))?.id, "Qwen3.5-4B-Q4_K_M")
    }

    func testDiskSpaceStepsDown() {
        XCTAssertEqual(recommendedLocalChatModel(for: mac(ram: 32, disk: 7))?.id, "Qwen3.5-9B-Q4_K_M")
        XCTAssertNil(recommendedLocalChatModel(for: mac(ram: 32, disk: 2)))
    }

    func testModelsLiveUnderTheirOwnFolderInModelsLLM() {
        let model = localChatModels[0]
        let path = localChatModelFile(for: model).path
        XCTAssertTrue(path.hasSuffix("/SpeechText/Models/llm/\(model.id)/\(model.file)"), path)
    }
}

final class OptionLogitsTests: XCTestCase {
    func testLogitsBecomeProbabilitiesOverTheOptionsAlone() {
        let probabilities = OptionLogits.probabilities([1, 3, 2])
        XCTAssertEqual(probabilities.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(OptionLogits.best(probabilities), 1)
        // A large logit does not overflow: they are taken relative to the top one.
        XCTAssertEqual(OptionLogits.probabilities([2000, 2000]), [0.5, 0.5])
    }
}
