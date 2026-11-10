// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import SpeechTextCore

/// A keychain in memory. Never the real one: the test bundle is unsigned, and a real
/// keychain holds the user's own keys.
private final class FakeSecrets: SecretStorage {
    var items: [String: String] = [:]
    var failWrites = false
    var failReads = false
    /// A keychain that accepts a write and returns something else.
    var garbleReads = false

    struct Refused: Error {}

    func read(_ account: String) throws -> String? {
        if failReads { throw Refused() }
        return garbleReads ? items[account].map { $0 + "?" } : items[account]
    }
    func write(_ value: String, for account: String) throws {
        if failWrites { throw Refused() }
        items[account] = value
    }
    func delete(_ account: String) throws { items[account] = nil }
}

// MARK: - Opening the store at launch (APIKeyStore.swift)

final class APIKeyStoreTests: XCTestCase {
    private var suites: [String] = []

    /// An isolated preferences domain, never `UserDefaults.standard`.
    private func domain() -> UserDefaults {
        let name = "APIKeyStoreTests.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suites = []
        super.tearDown()
    }

    private let groq = SettingsKeys.groqAPIKey
    private let openAI = SettingsKeys.openAIAPIKey

    // MARK: Keychain mode

    /// The first launch with the profile: the key moves in and every plain-text copy goes,
    /// in the current domain and every pre-rename one.
    func testAKeyMovesIntoTheKeychainAndLeavesEveryDomain() {
        let current = domain(), renamed = domain(), original = domain()
        current.set("gsk_current", forKey: groq)
        renamed.set("gsk_old", forKey: groq)
        original.set("gsk_older", forKey: groq)
        let secrets = FakeSecrets()

        let store = APIKeyStore()
        let report = store.open(keychain: secrets, defaults: current, legacy: [renamed, original])

        XCTAssertEqual(report.mode, .keychain)
        XCTAssertEqual(report.moved, [groq])
        XCTAssertEqual(secrets.items[groq], "gsk_current")
        XCTAssertEqual(store.value(for: groq), "gsk_current")
        for defaults in [current, renamed, original] {
            XCTAssertNil(defaults.object(forKey: groq))
        }
    }

    /// Nothing in the current domain (an install that has not run under the new name):
    /// the newest pre-rename domain fills the key.
    func testTheNewestPreRenameDomainFillsAMissingKey() {
        let current = domain(), renamed = domain(), original = domain()
        renamed.set("sk-renamed", forKey: openAI)
        original.set("sk-original", forKey: openAI)
        let secrets = FakeSecrets()

        let store = APIKeyStore()
        store.open(keychain: secrets, defaults: current, legacy: [renamed, original])

        XCTAssertEqual(secrets.items[openAI], "sk-renamed")
        XCTAssertNil(renamed.object(forKey: openAI))
        XCTAssertNil(original.object(forKey: openAI))
    }

    /// A pre-rename domain never overrides the keychain: its copy is older than the move.
    func testAPreRenameCopyDoesNotReplaceAKeychainKey() {
        let current = domain(), renamed = domain()
        renamed.set("stale", forKey: groq)
        let secrets = FakeSecrets()
        secrets.items[groq] = "fresh"

        let store = APIKeyStore()
        let report = store.open(keychain: secrets, defaults: current, legacy: [renamed])

        XCTAssertEqual(report.moved, [])
        XCTAssertEqual(secrets.items[groq], "fresh")
        XCTAssertNil(renamed.object(forKey: groq), "the stale copy is deleted all the same")
    }

    /// The current domain's key was typed into a build without the profile after the
    /// move (Xcode ⌘R shares the domain), so it is the newer one and replaces the item.
    func testACurrentDomainKeyIsNewerThanTheKeychain() {
        let current = domain()
        current.set("typed-in-a-dev-build", forKey: groq)
        let secrets = FakeSecrets()
        secrets.items[groq] = "moved-earlier"

        let store = APIKeyStore()
        store.open(keychain: secrets, defaults: current, legacy: [])

        XCTAssertEqual(secrets.items[groq], "typed-in-a-dev-build")
        XCTAssertNil(current.object(forKey: groq))
    }

    /// A write the keychain refuses deletes nothing: the key stays usable and on disk
    /// where it was, and the next launch tries again.
    func testAFailedWriteKeepsEveryCopy() {
        let current = domain(), renamed = domain()
        current.set("gsk_keep", forKey: groq)
        renamed.set("gsk_keep_too", forKey: groq)
        let secrets = FakeSecrets()
        secrets.failWrites = true

        let store = APIKeyStore()
        let report = store.open(keychain: secrets, defaults: current, legacy: [renamed])

        XCTAssertEqual(report.failed, [groq])
        XCTAssertEqual(store.value(for: groq), "gsk_keep")
        XCTAssertEqual(current.string(forKey: groq), "gsk_keep")
        XCTAssertEqual(renamed.string(forKey: groq), "gsk_keep_too")
    }

    /// A keychain that returns something other than what it was given is not trusted
    /// with the only copy.
    func testAReadBackMismatchKeepsEveryCopy() {
        let current = domain()
        current.set("gsk_keep", forKey: groq)
        let secrets = FakeSecrets()
        secrets.garbleReads = true

        let store = APIKeyStore()
        let report = store.open(keychain: secrets, defaults: current, legacy: [])

        XCTAssertEqual(report.failed, [groq])
        XCTAssertEqual(current.string(forKey: groq), "gsk_keep")
    }

    /// A keychain that will not even read decides nothing: every copy stays.
    func testAnUnreadableKeychainKeepsEveryCopy() {
        let current = domain(), renamed = domain()
        current.set("gsk_keep", forKey: groq)
        renamed.set("gsk_old", forKey: groq)
        let secrets = FakeSecrets()
        secrets.failReads = true

        let store = APIKeyStore()
        let report = store.open(keychain: secrets, defaults: current, legacy: [renamed])

        XCTAssertEqual(report.failed.first, groq)
        XCTAssertEqual(store.value(for: groq), "gsk_keep")
        XCTAssertEqual(renamed.string(forKey: groq), "gsk_old")
    }

    /// Editing in Settings writes the keychain only; clearing a key deletes its item.
    func testSettingAKeyWritesTheKeychainAndClearingDeletesIt() {
        let current = domain()
        let secrets = FakeSecrets()
        let store = APIKeyStore()
        store.open(keychain: secrets, defaults: current, legacy: [])

        store.set("sk-ant-new", for: SettingsKeys.anthropicAPIKey)
        XCTAssertEqual(secrets.items[SettingsKeys.anthropicAPIKey], "sk-ant-new")
        XCTAssertNil(current.object(forKey: SettingsKeys.anthropicAPIKey))
        XCTAssertTrue(store.hasAnyKey)

        store.set("", for: SettingsKeys.anthropicAPIKey)
        XCTAssertNil(secrets.items[SettingsKeys.anthropicAPIKey])
        XCTAssertFalse(store.hasAnyKey)
    }

    /// A failed save is kept for the session only — never written to a plist instead.
    func testAFailedSaveNeverFallsBackToThePreferences() {
        let current = domain()
        let secrets = FakeSecrets()
        let store = APIKeyStore()
        store.open(keychain: secrets, defaults: current, legacy: [])
        secrets.failWrites = true

        store.set("sk-new", for: openAI)

        XCTAssertEqual(store.value(for: openAI), "sk-new")
        XCTAssertNil(current.object(forKey: openAI))
    }

    // MARK: Defaults mode (a build without the profile)

    /// Without the keychain the keys stay in the preferences, and the pre-rename chain
    /// fills a missing one — the adoption `adoptPreRenameDefaults()` used to do for them.
    func testWithoutTheKeychainKeysStayInThePreferences() {
        let current = domain(), renamed = domain(), original = domain()
        current.set("gsk_here", forKey: groq)
        renamed.set("sk-renamed", forKey: openAI)
        original.set("sk-original", forKey: openAI)

        let store = APIKeyStore()
        let report = store.open(keychain: nil, defaults: current, legacy: [renamed, original])

        XCTAssertEqual(report.mode, .defaults)
        XCTAssertEqual(report.adopted, [openAI])
        XCTAssertEqual(store.value(for: groq), "gsk_here")
        XCTAssertEqual(current.string(forKey: openAI), "sk-renamed")
        XCTAssertEqual(renamed.string(forKey: openAI), "sk-renamed", "nothing is deleted without a keychain")
    }

    /// A key the user cleared is stored empty, so the pre-rename copy does not come back.
    func testAClearedKeyIsNotAdoptedAgain() {
        let current = domain(), renamed = domain()
        renamed.set("sk-renamed", forKey: openAI)
        let store = APIKeyStore()
        store.open(keychain: nil, defaults: current, legacy: [renamed])

        store.set("", for: openAI)
        let reopened = APIKeyStore()
        reopened.open(keychain: nil, defaults: current, legacy: [renamed])

        XCTAssertEqual(reopened.value(for: openAI), "")
    }

    /// Unopened — the test bundle's state for every other test — every key reads empty
    /// and a write goes nowhere.
    func testAnUnopenedStoreHoldsNothing() {
        let store = APIKeyStore()
        XCTAssertEqual(store.mode, .unopened)
        XCTAssertEqual(store.value(for: groq), "")
        XCTAssertFalse(store.hasAnyKey)
    }
}

/// The end-to-end run's key file (`-SPTKeysFile`), read in the shape `LiveProviderTests`
/// takes from the environment.
final class E2EKeysFileTests: XCTestCase {
    func testTheEnvFileIsReadOntoTheStoredKeyNames() {
        let keys = E2EMode.parseKeys("""
        # test accounts
        GROQ_API_KEY=gsk_one
        export OPENAI_API_KEY="sk-two"
        ELEVENLABS_API_KEY = 'three'
        ANTHROPIC_API_KEY=
        SOMETHING_ELSE=four
        """)
        XCTAssertEqual(keys, [
            SettingsKeys.groqAPIKey: "gsk_one",
            SettingsKeys.openAIAPIKey: "sk-two",
            SettingsKeys.elevenLabsAPIKey: "three",
        ])
    }

    #if DEBUG
    func testSessionKeysAreHeldWithoutBeingWritten() {
        let store = APIKeyStore()
        store.useForThisSession([SettingsKeys.groqAPIKey: "gsk_one"])
        XCTAssertEqual(store.value(for: SettingsKeys.groqAPIKey), "gsk_one")
        XCTAssertEqual(store.mode, .unopened)
    }
    #endif
}

/// `scripts/window-snapshots.sh --only`: which of a snapshot run's windows it draws.
final class WindowSnapshotSelectionTests: XCTestCase {
    private let names = [
        "setup-welcome", "setup-speech", "setup-done", "main-home",
        "settings-ai", "settings-apiKeys", "record-window",
    ]

    func testNoWordsDrawEveryWindow() {
        for text in [nil, "", "  "] {
            let selection = WindowSnapshotSelection(text)
            XCTAssertTrue(names.allSatisfy(selection.includes))
            XCTAssertEqual(selection.unmatched(in: names), [])
        }
    }

    func testNamesAreMatchedWholeAndAWordEndingInADashAsAPrefix() {
        let selection = WindowSnapshotSelection("setup-  settings-ai,record-window")
        XCTAssertEqual(names.filter(selection.includes),
                       ["setup-welcome", "setup-speech", "setup-done", "settings-ai", "record-window"])
        XCTAssertEqual(selection.unmatched(in: names), [])
    }

    func testAWordThatNamesNoWindowIsReported() {
        // Not a prefix without its dash: "settings-a" would otherwise take both categories.
        let selection = WindowSnapshotSelection("settings-a main-home setup notetaker-")
        XCTAssertEqual(names.filter(selection.includes), ["main-home"])
        XCTAssertEqual(selection.unmatched(in: names), ["settings-a", "setup", "notetaker-"])
    }
}
