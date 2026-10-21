// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// Where the API keys are kept outside memory. The app registers the data-protection
/// keychain (`KeychainSecretStorage`, app target only); the test bundle registers a fake,
/// so nothing it runs can reach a real keychain.
public protocol SecretStorage: AnyObject {
    /// The stored value, or nil when there is none.
    func read(_ account: String) throws -> String?
    func write(_ value: String, for account: String) throws
    func delete(_ account: String) throws
}

/// Every provider's API key, held in memory once the launch has opened the store.
///
/// A key is read on every shortcut press (`AppState.effectiveKey` asks whether an AI
/// provider is configured), so readers only ever touch the cache — never the keychain.
/// Each key is named by its `SettingsKeys` constant, which is also its keychain account
/// and the name it had in UserDefaults before it moved.
///
/// Two modes, fixed at launch by `open`:
/// - **keychain** — the build carries the provisioning profile that authorises its
///   keychain access group (releases, and `rebuild.sh` with the profile). Keys live only
///   in the data-protection keychain; any copy found in a preferences domain is moved in
///   and then deleted from every domain the app has run under.
/// - **defaults** — a build without the profile (Xcode ⌘R, a contributor's clone) cannot
///   reach that keychain at all, so it keeps the keys in UserDefaults as before.
///
/// `@unchecked Sendable`: every reader may be on any thread, and the stored values are read
/// and written under `lock` (`mode` read bare only by the tests, after `open`).
@Observable
public final class APIKeyStore: @unchecked Sendable {
    public static let shared = APIKeyStore()

    /// Every key the store holds, by its `SettingsKeys` name: one per provider that has a
    /// key (`APIKeyDescriptor`). The launch migration moves exactly these, so the list is
    /// pinned literally in the tests.
    static let keys: [String] = Provider.allCases.compactMap { $0.descriptor.apiKey?.settingsKey }

    public enum Mode: Equatable, Sendable {
        /// Not opened: every key reads as empty. The test bundle's state.
        case unopened
        case keychain
        case defaults
    }

    /// What `open` did, for the Debug Log and the tests.
    public struct Report: Equatable, Sendable {
        public var mode: Mode
        /// Keys written into the keychain from a preferences domain.
        public var moved: [String] = []
        /// Keys copied into the current domain from a pre-rename one (defaults mode).
        public var adopted: [String] = []
        /// Keys whose keychain write or read-back failed; their copies were kept.
        public var failed: [String] = []
    }

    @ObservationIgnored private let lock = NSLock()
    private var values: [String: String] = [:]
    private(set) var mode: Mode = .unopened
    @ObservationIgnored private var keychain: SecretStorage?
    @ObservationIgnored private var defaults: UserDefaults?

    init() {}

    /// The key, or "" when there is none. Safe from any thread.
    public func value(for key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return values[key] ?? ""
    }

    /// Whether any key is stored — one of the signs that this is not a new install.
    public var hasAnyKey: Bool {
        lock.lock(); defer { lock.unlock() }
        return values.values.contains { !$0.isEmpty }
    }

    /// Stores a key; an empty value removes it. In keychain mode a failed write keeps the
    /// value for this session only and is logged — it is never written to UserDefaults.
    public func set(_ value: String, for key: String) {
        lock.lock()
        let changed = values[key] ?? "" != value
        values[key] = value
        let mode = self.mode, keychain = self.keychain, defaults = self.defaults
        lock.unlock()
        guard changed else { return }

        switch mode {
        case .unopened:
            break
        case .keychain:
            do {
                if value.isEmpty {
                    try keychain?.delete(key)
                } else {
                    try keychain?.write(value, for: key)
                }
            } catch {
                dlog("Keys", "could not save \(key) to the keychain: \(error)", level: .error)
            }
        case .defaults:
            // Written even when empty: an absent key is what lets `open` adopt one from a
            // pre-rename domain, and a key the user cleared must stay cleared.
            defaults?.set(value, forKey: key)
        }
    }

    #if DEBUG
    /// Debug builds only, for an end-to-end run (`E2EMode.keysFile`): the keys this
    /// session reads, held in memory and never written to the keychain or a plist.
    public func useForThisSession(_ keys: [String: String]) {
        lock.lock()
        values.merge(keys) { _, new in new }
        lock.unlock()
    }
    #endif

    /// Opens the store at launch, moving keys out of the preferences domains when the
    /// keychain is there. `keychain` is nil for a build that cannot reach it.
    /// `legacy` is the chain of pre-rename domains, newest first.
    @discardableResult
    public func open(keychain: SecretStorage?, defaults: UserDefaults, legacy: [UserDefaults]) -> Report {
        var loaded: [String: String] = [:]
        var report = Report(mode: keychain == nil ? .defaults : .keychain)

        for key in Self.keys {
            let current = defaults.object(forKey: key) as? String
            let fromLegacy = legacy.lazy.compactMap { $0.string(forKey: key) }.first { !$0.isEmpty }

            guard let keychain else {
                // Defaults mode: the pre-rename adoption, as it always worked for keys —
                // only into an absent key, so one the user cleared stays cleared.
                if current == nil, let fromLegacy {
                    defaults.set(fromLegacy, forKey: key)
                    report.adopted.append(key)
                    loaded[key] = fromLegacy
                } else {
                    loaded[key] = current ?? ""
                }
                continue
            }

            let stored: String?
            do {
                stored = try keychain.read(key)
            } catch {
                // Nothing can be decided about a key the keychain would not read: keep
                // every copy, use the current domain's for this session.
                dlog("Keys", "could not read \(key) from the keychain: \(error)", level: .error)
                report.failed.append(key)
                loaded[key] = current ?? ""
                continue
            }

            // A key in the current domain was written after the last move — by a build
            // without the profile, which shares this domain — so it wins. A pre-rename
            // domain only fills a key the keychain does not have.
            let candidate = current.flatMap { $0.isEmpty ? nil : $0 } ?? (stored == nil ? fromLegacy : nil)

            if let candidate, candidate != stored {
                do {
                    try keychain.write(candidate, for: key)
                    guard try keychain.read(key) == candidate else {
                        throw APIKeyStoreError.readBackMismatch
                    }
                    report.moved.append(key)
                    loaded[key] = candidate
                } catch {
                    dlog("Keys", "could not move \(key) into the keychain: \(error)", level: .error)
                    report.failed.append(key)
                    loaded[key] = candidate
                    continue
                }
            } else {
                loaded[key] = stored ?? ""
            }

            // The keychain holds the key (or there is none anywhere): no plain-text copy
            // may stay behind, in this domain or in any the app has run under.
            defaults.removeObject(forKey: key)
            legacy.forEach { $0.removeObject(forKey: key) }
        }

        lock.lock()
        values = loaded
        mode = report.mode
        self.keychain = keychain
        self.defaults = defaults
        lock.unlock()
        return report
    }
}

enum APIKeyStoreError: Error {
    /// The keychain accepted the write but returned something else.
    case readBackMismatch
}
