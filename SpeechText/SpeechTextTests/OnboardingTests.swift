// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SpeechTextCore

final class ServerDraftTests: XCTestCase {
    private let address = "http://localhost:11434/v1"

    private func answered(_ model: String, listed: [String]? = nil) -> ServerTestRun {
        ServerTestRun(listed: listed ?? [model], model: model, result: .answered(seconds: 0.2))
    }

    private func tested(_ draft: inout ServerDraft, _ run: ServerTestRun) {
        XCTAssertTrue(draft.beginTest())
        draft.finishTest(run)
    }

    func testContinueWaitsForAPassedTest() {
        var draft = ServerDraft(role: .chat, address: "", model: "", key: "")
        XCTAssertFalse(draft.canContinue)
        draft.setAddress(address)
        XCTAssertFalse(draft.canContinue)
        XCTAssertTrue(draft.beginTest())
        XCTAssertFalse(draft.canContinue, "a running test is not a passed one")
        draft.finishTest(answered("gemma4:12b"))
        XCTAssertTrue(draft.canContinue)
        XCTAssertEqual(draft.saved?.address, address)
        XCTAssertEqual(draft.saved?.model, "gemma4:12b")
    }

    func testAFailedTestSavesNothing() {
        var draft = ServerDraft(role: .chat, address: address, model: "", key: "")
        tested(&draft, ServerTestRun(listed: nil, model: nil, result: .noAnswer))
        XCTAssertFalse(draft.canContinue)
        XCTAssertNil(draft.saved)
        XCTAssertEqual(draft.result, .noAnswer)
    }

    /// Setup run again with the server stopped keeps it: it has passed before.
    func testWhatIsStoredAlreadyPassed() {
        let draft = ServerDraft(role: .speech, address: address, model: "whisper", key: "secret")
        XCTAssertTrue(draft.canContinue)
        XCTAssertEqual(draft.saved?.key, "secret")
        XCTAssertEqual(draft.modelRows, ["whisper"])
        XCTAssertTrue(draft.showsKey)
    }

    func testTheStoredServerStillPassesAfterATestOfAnotherAddress() {
        var draft = ServerDraft(role: .speech, address: address, model: "whisper", key: "secret")
        draft.setAddress("http://192.168.1.20:8000/v1")
        tested(&draft, answered("parakeet"))
        XCTAssertTrue(draft.canContinue)
        draft.setAddress(address)
        XCTAssertTrue(draft.canContinue)
        XCTAssertEqual(draft.saved?.model, "whisper")
        XCTAssertEqual(draft.saved?.key, "secret")
    }

    func testAStoredAddressWithNoModelHasNotPassed() {
        XCTAssertFalse(ServerDraft(role: .speech, address: address, model: "", key: "").canContinue)
    }

    func testTheKeyFieldWaitsForTheServerToAsk() {
        var draft = ServerDraft(role: .chat, address: address, model: "", key: "")
        XCTAssertFalse(draft.showsKey)
        tested(&draft, ServerTestRun(listed: nil, model: nil, result: .noAnswer))
        XCTAssertFalse(draft.showsKey)
        tested(&draft, ServerTestRun(listed: nil, model: nil, result: .needsKey))
        XCTAssertTrue(draft.showsKey)
        tested(&draft, ServerTestRun(listed: nil, model: nil, result: .noAnswer))
        XCTAssertTrue(draft.showsKey, "it stays once the server has asked")
    }

    /// A stored key is never sent to another address, and comes back with its own.
    func testAnotherAddressStartsWithoutTheStoredKeyOrModel() {
        var draft = ServerDraft(role: .chat, address: address, model: "gemma", key: "secret")
        draft.setAddress("http://studio.local:8000/v1")
        XCTAssertEqual(draft.key, "")
        XCTAssertEqual(draft.model, "")
        XCTAssertFalse(draft.canContinue)
        draft.setAddress(address)
        XCTAssertEqual(draft.key, "secret")
        XCTAssertEqual(draft.model, "gemma")
        XCTAssertTrue(draft.canContinue)
    }

    func testAChangeAfterAPassedTestNeedsAnother() {
        var draft = ServerDraft(role: .chat, address: address, model: "", key: "")
        tested(&draft, answered("a", listed: ["a", "b"]))
        draft.setModel("b")
        XCTAssertFalse(draft.canContinue)
        draft.setModel("a")
        XCTAssertTrue(draft.canContinue, "back on what passed")
        draft.setKey("new")
        XCTAssertFalse(draft.canContinue)
    }

    func testNothingChangesWhileATestRuns() {
        var draft = ServerDraft(role: .chat, address: address, model: "", key: "")
        XCTAssertTrue(draft.beginTest())
        XCTAssertFalse(draft.beginTest())
        draft.setAddress("http://other:1/v1")
        draft.setKey("k")
        draft.setModel("m")
        XCTAssertEqual(draft.address, address)
        XCTAssertEqual(draft.key, "")
        XCTAssertEqual(draft.model, "")
    }

    func testNoTestWithoutAnAddress() {
        var draft = ServerDraft(role: .chat, address: "not an address", model: "", key: "")
        XCTAssertFalse(draft.beginTest())
    }

    func testAServerWithNoListGetsATypedModel() {
        var draft = ServerDraft(role: .speech, address: address, model: "", key: "")
        tested(&draft, ServerTestRun(listed: [], model: nil, result: .noModels))
        XCTAssertTrue(draft.listsNoModels)
        XCTAssertEqual(draft.modelRows, [])
        draft.setModel("ggml-large")
        tested(&draft, ServerTestRun(listed: [], model: "ggml-large", result: .answered(seconds: 1)))
        XCTAssertTrue(draft.canContinue)
        XCTAssertEqual(draft.saved?.model, "ggml-large")
    }

    /// The other step offers only an address that has answered.
    func testOnlyAVerifiedAddressIsOffered() {
        var draft = ServerDraft(role: .speech, address: "", model: "", key: "")
        draft.setAddress(address)
        XCTAssertNil(draft.verifiedAddress)
        tested(&draft, answered("m"))
        XCTAssertEqual(draft.verifiedAddress, address)
    }

    func testAListForAnotherAddressIsDropped() {
        var draft = ServerDraft(role: .chat, address: address, model: "m", key: "")
        draft.refreshModels(["x"], from: "http://other:1/v1")
        XCTAssertEqual(draft.modelRows, ["m"])
        draft.refreshModels(["m", "n"], from: address)
        XCTAssertEqual(draft.modelRows, ["m", "n"])
    }

    func testTheSavedAddressIsTrimmed() {
        var draft = ServerDraft(role: .chat, address: "", model: "", key: "")
        draft.setAddress("  \(address) ")
        tested(&draft, answered("m"))
        XCTAssertEqual(draft.saved?.address, address)
    }
}

final class OnboardingGateTests: XCTestCase {
    func testANewInstallSeesSetup() {
        XCTAssertEqual(OnboardingGate.decide(completed: nil, hasUsedTheAppBefore: false), .show)
    }

    /// There was no marker before setup existed: an install that already stored settings
    /// has done its setup, and is marked done rather than walked through it again.
    func testAnExistingInstallIsMarkedDone() {
        XCTAssertEqual(OnboardingGate.decide(completed: nil, hasUsedTheAppBefore: true), .markCompleted)
    }

    /// Setup closed half-way stores `false`, and opens again even though settings exist.
    func testAnUnfinishedSetupOpensAgain() {
        XCTAssertEqual(OnboardingGate.decide(completed: false, hasUsedTheAppBefore: true), .show)
        XCTAssertEqual(OnboardingGate.decide(completed: true, hasUsedTheAppBefore: false), .skip)
    }

    func testStepsKeepTheirOrderAndStoredNames() {
        XCTAssertLessThan(OnboardingStep.speech, OnboardingStep.ai)
        XCTAssertLessThan(OnboardingStep.tryIt, OnboardingStep.done)
        XCTAssertEqual(OnboardingStep(rawValue: "try"), .tryIt)
        XCTAssertEqual(OnboardingStep.named.count, 5)
    }
}

final class ProviderKeyTests: XCTestCase {
    private let long = String(repeating: "a1B2", count: 8)

    /// Each provider's sample key is taken for its own and for no other's — every pair, so
    /// a new provider whose prefix overlaps another's fails here.
    func testEveryKeyShapeIsTakenForItsOwnProviderOnly() {
        let keyed = Provider.allCases.filter { $0.descriptor.apiKey != nil }
        XCTAssertFalse(keyed.isEmpty)
        for owner in keyed {
            let sample = owner.descriptor.apiKey!.sample
            for provider in keyed {
                XCTAssertEqual(provider.looksLikeKey(sample), provider == owner, "\(owner) sample, \(provider)")
            }
        }
    }

    func testKeyShapesTellTheServicesApart() {
        XCTAssertTrue(Provider.groq.looksLikeKey("gsk_\(long)"))
        XCTAssertTrue(Provider.elevenLabs.looksLikeKey("  sk_\(long)\n"))
        XCTAssertTrue(Provider.anthropic.looksLikeKey("sk-ant-api03-\(long)"))
        XCTAssertTrue(Provider.openAI.looksLikeKey("sk-proj-\(long)"))
        // An Anthropic key is not an OpenAI one, though both begin "sk-".
        XCTAssertFalse(Provider.openAI.looksLikeKey("sk-ant-api03-\(long)"))
        XCTAssertFalse(Provider.elevenLabs.looksLikeKey("gsk_\(long)"))
    }

    /// Whatever else is on the clipboard is never taken for a key.
    func testClipboardTextThatIsNotAKeyIsIgnored() {
        XCTAssertFalse(Provider.groq.looksLikeKey("gsk_short"))
        XCTAssertFalse(Provider.groq.looksLikeKey("gsk_\(long) and some words"))
        XCTAssertFalse(Provider.groq.looksLikeKey("Meeting notes for Tuesday"))
    }

    func testVerdicts() {
        XCTAssertEqual(Provider.verdict(statusCode: 200, body: "{}"), .valid)
        XCTAssertEqual(Provider.verdict(statusCode: 429, body: "slow down"), .valid)
        XCTAssertEqual(Provider.verdict(statusCode: 401, body: #"{"error":"invalid_api_key"}"#), .invalid)
        XCTAssertEqual(Provider.verdict(statusCode: 500, body: ""), .unreachable)
    }

    /// A key scoped to Speech to Text only is refused the model list, and still works.
    func testAScopedKeyIsValid() {
        let body = #"{"detail":{"status":"missing_permissions","message":"The API key you used is missing the permission models_read"}}"#
        XCTAssertEqual(Provider.verdict(statusCode: 401, body: body), .valid)
        XCTAssertEqual(Provider.verdict(statusCode: 403, body: "You have insufficient permissions for this operation."), .valid)
    }

    func testVerificationRequestsAuthenticate() {
        let groq = Provider.groq.verificationRequest(key: " gsk_x ")
        XCTAssertEqual(groq?.value(forHTTPHeaderField: "Authorization"), "Bearer gsk_x")
        XCTAssertEqual(groq?.url?.absoluteString, "https://api.groq.com/openai/v1/models")
        let anthropic = Provider.anthropic.verificationRequest(key: "k")
        XCTAssertEqual(anthropic?.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(anthropic?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(Provider.elevenLabs.verificationRequest(key: "k")?.value(forHTTPHeaderField: "xi-api-key"), "k")
        XCTAssertEqual(Provider.openAI.verificationRequest(key: "k")?.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertEqual(Provider.groq.verificationRequest(key: "k")?.httpMethod, "GET")
        XCTAssertNil(Provider.ollama.verificationRequest(key: "k"))
    }
}

final class DiskImageLaunchTests: XCTestCase {
    private func copy(_ path: String, _ build: String, signed: Bool = true) -> InstalledCopy {
        InstalledCopy(path: path, build: build, isSameSigner: signed)
    }

    /// Dragged, then double-clicked in the image: the installed copy opens, nothing is asked.
    func testTheSameBuildInApplicationsIsOpened() {
        XCTAssertEqual(DiskImageLaunch.decide(runningBuild: "52", copies: [copy("/Applications/SpeechText.app", "52")]),
                       .openInstalled("/Applications/SpeechText.app"))
    }

    func testANewerInstalledBuildIsOpenedAndComparedAsANumber() {
        XCTAssertEqual(DiskImageLaunch.decide(runningBuild: "9", copies: [copy("/Applications/SpeechText.app", "10")]),
                       .openInstalled("/Applications/SpeechText.app"))
    }

    /// An older copy is what the move replaces.
    func testAnOlderInstalledBuildIsMovedOver() {
        XCTAssertEqual(DiskImageLaunch.decide(runningBuild: "52", copies: [copy("/Applications/SpeechText.app", "47")]),
                       .offerMove)
    }

    func testNoInstalledCopyOffersTheMove() {
        XCTAssertEqual(DiskImageLaunch.decide(runningBuild: "52", copies: []), .offerMove)
    }

    /// A bundle at that path signed by anyone else is never opened past Gatekeeper.
    func testACopySignedByAnotherTeamIsNotOpened() {
        XCTAssertEqual(DiskImageLaunch.decide(runningBuild: "52",
                                              copies: [copy("/Applications/SpeechText.app", "60", signed: false)]),
                       .offerMove)
    }

    /// An account that cannot write /Applications installs into its own; the shared one
    /// is preferred when both hold a usable copy.
    func testTheSharedApplicationsFolderComesFirst() {
        let shared = copy("/Applications/SpeechText.app", "52")
        let own = copy("/Users/me/Applications/SpeechText.app", "52")
        XCTAssertEqual(DiskImageLaunch.decide(runningBuild: "52", copies: [shared, own]), .openInstalled(shared.path))
        XCTAssertEqual(DiskImageLaunch.decide(runningBuild: "52", copies: [copy(shared.path, "40"), own]),
                       .openInstalled(own.path))
    }
}

final class InstallLocationTests: XCTestCase {
    private let image = MountedDiskImage(imagePath: "/Users/me/Downloads/SpeechText-0.9.0.dmg",
                                         mountPoint: "/Volumes/SpeechText 0.9.0")
    private let other = MountedDiskImage(imagePath: "/Users/me/Downloads/Other.dmg", mountPoint: "/Volumes/Other")

    private func decide(_ path: String, _ images: [MountedDiskImage]) -> InstallLocation {
        InstallLocation.decide(bundlePath: path, appName: "SpeechText", images: images)
    }

    func testOpenedFromTheImageHasToMove() {
        XCTAssertEqual(decide("/Volumes/SpeechText 0.9.0/SpeechText.app", [other, image]), .inDiskImage(image))
    }

    /// A quarantined app runs from a random path that names no volume.
    func testATranslocatedAppIsMatchedToItsImage() {
        let translocated = "/private/var/folders/xy/T/AppTranslocation/8C1E/d/SpeechText.app"
        XCTAssertEqual(decide(translocated, [other, image]), .inDiskImage(image))
        XCTAssertEqual(decide(translocated, [other]), .inDiskImage(nil))
    }

    /// The image left mounted after the drag is the user's to put away; the app says nothing.
    func testInstalledWithTheImageStillMountedIsInstalled() {
        XCTAssertEqual(decide("/Applications/SpeechText.app", [other, image]), .installed)
        XCTAssertEqual(decide("/Applications/SpeechText.app", [other]), .installed)
    }

    /// Running inside a volume is matched by whole path component: a volume whose name
    /// only begins like the one the app is on does not contain it.
    func testAMountPointIsMatchedByWholeComponent() {
        let shorter = MountedDiskImage(imagePath: "/x.dmg", mountPoint: "/Volumes/SpeechText")
        XCTAssertEqual(decide("/Volumes/SpeechText 0.9.0/SpeechText.app", [shorter]), .installed)
    }

    /// A translocated app's image is known by its file's or its volume's name — never by
    /// reading it.
    func testAnImageIsKnownByItsName() {
        let translocated = "/private/var/folders/xy/T/AppTranslocation/8C1E/d/SpeechText.app"
        let renamed = MountedDiskImage(imagePath: "/Users/me/Downloads/download.dmg", mountPoint: "/Volumes/SpeechText")
        XCTAssertEqual(decide(translocated, [renamed]), .inDiskImage(renamed))
        let byFile = MountedDiskImage(imagePath: "/Users/me/Downloads/speechtext-0.9.0.dmg", mountPoint: "/Volumes/Untitled")
        XCTAssertEqual(decide(translocated, [byFile]), .inDiskImage(byFile))
    }

    /// A build run from Xcode is never asked to move.
    func testADevelopmentBuildCountsAsInstalled() {
        let derived = "/Users/me/Library/Developer/Xcode/DerivedData/SpeechText-abc/Build/Products/Debug/SpeechText.app"
        XCTAssertEqual(decide(derived, [other]), .installed)
    }

    func testHdiutilInfoIsRead() throws {
        let plist: [String: Any] = ["images": [
            ["image-path": "/Users/me/Downloads/SpeechText-0.9.0.dmg",
             "system-entities": [["content-hint": "GUID_partition_scheme"],
                                 ["content-hint": "Apple_HFS", "mount-point": "/Volumes/SpeechText 0.9.0"]]],
            ["image-path": "/tmp/raw.dmg", "system-entities": [["content-hint": "Apple_HFS"]]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(MountedDiskImage.parse(hdiutilInfo: data), [image])
        XCTAssertEqual(MountedDiskImage.parse(hdiutilInfo: Data("not a plist".utf8)), [])
    }
}

/// Which services setup offers is a curated list; what choosing one saves, and which card a
/// stored engine reopens on, is read off it — checked here over every engine.
final class SetupCardsTests: XCTestCase {

    func testEverySpeechCardSavesItsOwnEngineAndOnlyThePromisedModel() {
        XCTAssertEqual(SetupCards.speech.map(\.service), [.groq, .elevenLabs, .openAI])
        for card in SetupCards.speech {
            XCTAssertEqual(card.engine.vendor, card.service, card.title)
            XCTAssertNotNil(card.service.descriptor.apiKey, card.title)
            if card.promisesLiveWords {
                let saved = card.savedModel.map { sttModel(vendor: card.service, id: $0) }
                XCTAssertEqual(saved?.isRealtime, true, card.title)
            } else {
                XCTAssertNil(card.savedModel, card.title)
            }
        }
        XCTAssertEqual(SetupCards.speech(for: .elevenLabs).savedModel, "scribe_v2_realtime")
        XCTAssertEqual(SetupCards.speech(for: .openAI).savedModel, "gpt-live-transcribe")
    }

    func testEveryAICardSavesItsOwnPick() {
        XCTAssertEqual(SetupCards.ai.map(\.service), [.groq, .anthropic, .openAI])
        for card in SetupCards.ai {
            XCTAssertEqual(card.pick.vendor, card.service, card.title)
            XCTAssertNotNil(card.service.descriptor.apiKey, card.title)
        }
    }

    /// Setup run again opens on the card of the stored engine; an engine with no card
    /// opens on none.
    func testEveryEngineReopensOnItsOwnCardOrNone() {
        for engine in STTProviderType.allCases {
            let card = SetupCards.speechCard(reopening: engine)
            switch engine {
            case .groq, .elevenlabs, .openai:
                XCTAssertEqual(card?.engine, engine)
                XCTAssertEqual(SetupCards.speech(for: card!.service).engine, engine)
            case .apple, .local, .server:
                XCTAssertNil(card, engine.rawValue)
            }
        }
    }

    /// Setup run again opens the AI step on the card of the stored pick; the Mac has none.
    func testEveryAIPickReopensOnItsOwnCardOrNone() {
        for pick in LLMProviderType.allCases {
            let card = SetupCards.aiCard(reopening: pick)
            switch pick {
            case .groq, .anthropic, .openai:
                XCTAssertEqual(card?.pick, pick)
                XCTAssertEqual(SetupCards.ai(for: card!.service).pick, pick)
            case .local, .server:
                XCTAssertNil(card, pick.rawValue)
            }
        }
    }

    /// The bug this guards: a stored server has no card, read as "On this Mac", and
    /// Continue replaced it with a local engine.
    func testAStoredServerReopensOnYourServerNeverOnThisMac() {
        XCTAssertEqual(SetupSpeechPath.reopening(.server), .server)
        XCTAssertEqual(SetupSpeechPath.reopening(.local), .local)
        XCTAssertEqual(SetupSpeechPath.reopening(.apple), .local)
        XCTAssertEqual(SetupSpeechPath.reopening(.openai), .online)
        XCTAssertEqual(SetupSpeechPath.reopening(nil), .local)
    }

    func testTheAIStepReopensOnlyOnAPickThatWorks() {
        XCTAssertEqual(SetupAIPath.reopening(.server, isConfigured: true), .server)
        XCTAssertEqual(SetupAIPath.reopening(.local, isConfigured: true), .local)
        XCTAssertEqual(SetupAIPath.reopening(.anthropic, isConfigured: true), .online)
        XCTAssertEqual(SetupAIPath.reopening(.server, isConfigured: false), .none)
        XCTAssertEqual(SetupAIPath.reopening(.groq, isConfigured: false), .none)
    }

    /// A service with no card falls back to the first, Groq, as it always did.
    func testAServiceWithNoCardFallsBackToTheFirst() {
        XCTAssertEqual(SetupCards.speech(for: .anthropic).engine, .groq)
        XCTAssertEqual(SetupCards.ai(for: .elevenLabs).pick, .groq)
    }

    func testTheAPIKeysPageListsSpeechKeysFirst() {
        XCTAssertEqual(APIKeyPage.order.filter { $0.descriptor.apiKey != nil }, [.groq, .elevenLabs, .openAI, .anthropic])
    }

    func testEveryRealtimeModelExplainsItsStreamInSettings() {
        for model in sttModelCatalog {
            XCTAssertEqual(model.settingsNote != nil, model.isRealtime, model.id)
        }
    }
}

/// A stored key is shown by its ends, so two keys of one vendor can be told apart.
final class APIKeyDisplayTests: XCTestCase {
    func testAKeyShowsItsPrefixFourMoreAndItsEnd() {
        XCTAssertEqual(APIKeyDisplay.masked("gsk_a1B2c3D4e5F6g7H8i9J0", prefix: "gsk_"), "gsk_a1B2…i9J0")
        XCTAssertEqual(APIKeyDisplay.masked("sk-ant-api03-abcdefghijklmnop", prefix: "sk-ant-"), "sk-ant-api0…mnop")
        XCTAssertEqual(APIKeyDisplay.masked("  abcdefghijklmnop  "), "abcd…mnop", "no prefix, and whitespace dropped")
        XCTAssertEqual(APIKeyDisplay.masked("short-key", prefix: "gsk_"), "•••••••••", "too short to show any of it")
        XCTAssertEqual(APIKeyDisplay.masked("gsk_abcdefg", prefix: "gsk_"), "•••••••••••")
    }
}
