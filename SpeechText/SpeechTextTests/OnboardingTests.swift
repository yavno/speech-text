// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SpeechTextCore

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
            case .apple, .local:
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
            case .local:
                XCTAssertNil(card, pick.rawValue)
            }
        }
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
