// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a catalogue model is in its vendor's life.
///
/// A model is never simply deleted from a catalogue any more: deleting it moved whoever
/// had it to the provider's default without a word, and turned every History record made
/// with it "Not priced", since records are priced from the current table. Instead a model
/// is marked, its users are moved to its *own* replacement with our release, and it stays
/// listed — for History's prices and names — until `ModelRetirement.term` after the
/// vendor switched it off, when its ID, name and price move to the archive.
///
/// "Needs a newer macOS" is not a lifecycle state: that is a property of this Mac, not of
/// the vendor, and is a separate input to the same *offered* filter.
public enum ModelLifecycle: Hashable, Sendable {
    /// Offered, nothing better to suggest.
    case current
    /// Still works and is still offered, but this model (same vendor) is better — or is
    /// the default now. Whoever has it is offered the switch; nothing moves by itself.
    case superseded(by: String)
    /// The vendor is switching it off. It is no longer offered, and the first launch of
    /// the release that marks it moves every stored choice to `replacement`.
    case deprecated(Deprecation)

    /// Whether a picker, setup or a recommendation may offer the model.
    var isOffered: Bool {
        if case .deprecated = self { false } else { true }
    }

    var deprecation: Deprecation? {
        if case .deprecated(let deprecation) = self { deprecation } else { nil }
    }

    /// The model this one points to, whatever the reason.
    var successor: String? {
        switch self {
        case .current: nil
        case .superseded(let id): id
        case .deprecated(let deprecation): deprecation.replacement
        }
    }

    /// What a picker row says about the model on `day`, or nil for one that needs no note.
    public func status(on day: Date) -> String? {
        guard let deprecation else { return nil }
        // An archived model's dates are not kept: it is past them by definition.
        guard let shutdown = deprecation.shutdown.date else { return "Retired" }
        return day < shutdown ? "Retiring on \(ModelRetirement.dayText(shutdown))" : "Retired"
    }
}

/// A vendor's announcement that a model will be switched off.
public struct Deprecation: Hashable, Sendable {
    /// The day the vendor announced it.
    let announced: DateComponents
    /// The day the vendor stops answering — the vendor's own word for it is OpenAI's
    /// "shutdown date". Shown, never a trigger: users move with our release.
    public let shutdown: DateComponents
    /// The same vendor's model its users are moved to. A chain (A → B → C) is followed.
    let replacement: String
    /// The vendor's page that says so.
    let source: URL
}

extension Deprecation {
    /// How an archived model reads when it is looked up: switched off, dates not kept.
    static func archived(replacement: String?) -> Deprecation {
        Deprecation(announced: DateComponents(), shutdown: DateComponents(),
                    replacement: replacement ?? "", source: URL(string: "about:blank")!)
    }
}

/// A model past its retirement term, kept as one line so History can still name and
/// price records made with it. Never deleted. `replacement` lets an install that skipped
/// releases still follow the chain to a model that is offered.
struct ArchivedModel<Rates: Hashable & Sendable>: Hashable, Sendable {
    let vendor: Provider
    let id: String
    let displayName: String
    let price: ListPrice<Rates>
    let replacement: String?
}

enum ModelRetirement {
    /// How long a deprecated model's full catalogue entry outlives the vendor's shutdown
    /// date before it moves to the archive. `ModelLifecycleTests` fails once an entry is
    /// past it, so the move is not forgotten.
    static let termMonths = 6

    /// The day an entry deprecated with this shutdown date must leave the catalogue.
    static func archiveBy(_ deprecation: Deprecation) -> Date? {
        deprecation.shutdown.date.flatMap {
            calendar.date(byAdding: .month, value: termMonths, to: $0)
        }
    }

    static let calendar = Calendar(identifier: .gregorian)

    static func day(_ year: Int, _ month: Int, _ day: Int) -> DateComponents {
        DateComponents(calendar: calendar, timeZone: TimeZone(identifier: "UTC"), year: year, month: month, day: day)
    }

    /// "26 Feb 2027".
    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = calendar
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}

/// Speech models past their term: ID, name, price and replacement only.
let archivedSpeechModels: [ArchivedModel<SpeechRates>] = []

/// Chat models past their term.
let archivedChatModels: [ArchivedModel<ChatRates>] = []

// MARK: - Following a replacement

/// One model as the chain sees it: whether it is offered and where it points.
struct LifecycleLink: Equatable {
    let offered: Bool
    let successor: String?
}

/// The offered model a chain of replacements starting at `id` ends on, or nil when it
/// ends nowhere (an ID nobody lists, an archived model with no replacement, a cycle).
/// Only `deprecated` and archived links are followed: a superseded model is still offered
/// and is the user's to keep.
func resolvedReplacement(of id: String, link: (String) -> LifecycleLink?) -> String? {
    var current = id
    var seen: Set<String> = []
    while seen.insert(current).inserted {
        guard let node = link(current) else { return nil }
        if node.offered { return current }
        guard let next = node.successor else { return nil }
        current = next
    }
    return nil
}

/// A speech model's link: the catalogue first, then the archive.
func speechLifecycleLink(vendor: Provider, id: String) -> LifecycleLink? {
    if let model = knownSTTModels(of: vendor).first(where: { $0.id == id }) {
        return LifecycleLink(offered: model.lifecycle.isOffered,
                             successor: model.lifecycle.deprecation?.replacement)
    }
    if let archived = archivedSpeechModels.first(where: { $0.vendor == vendor && $0.id == id }) {
        return LifecycleLink(offered: false, successor: archived.replacement)
    }
    return nil
}

/// A chat model's link: the catalogue first, then the archive.
func chatLifecycleLink(provider: LLMProviderType, id: String) -> LifecycleLink? {
    if let model = knownChatModels(of: provider).first(where: { $0.id == id }) {
        return LifecycleLink(offered: model.lifecycle.isOffered,
                             successor: model.lifecycle.deprecation?.replacement)
    }
    if let archived = archivedChatModels.first(where: { $0.vendor == provider.vendor && $0.id == id }) {
        return LifecycleLink(offered: false, successor: archived.replacement)
    }
    return nil
}

// MARK: - Moving stored choices

/// One stored model choice the launch changed, kept so the first dictation after the
/// update can say so (`SettingsKeys.modelMigrations`). Machine-local.
public struct ModelMigration: Codable, Equatable, Sendable {
    enum Reason: String, Codable {
        /// The vendor is switching the model off; `to` is its replacement.
        case deprecated
        /// The stored ID leads to no model that is offered; the choice was cleared and the
        /// user picks.
        case unavailable
    }

    /// The `SettingsKeys` name of the model setting.
    let settingsKey: String
    let from: String
    /// The model now stored, or nil when the choice was cleared.
    let to: String?
    let reason: Reason
    let date: Date
}

/// What one stored model setting comes to.
enum StoredModelVerdict: Equatable {
    case keep
    case move(to: String)
    case clear
}

/// The rule, apart from any store: an offered model stays (superseded included); anything
/// else follows its replacements to an offered model, and is cleared when they lead
/// nowhere — never moved to the provider's default, which may be another kind of model.
func storedModelVerdict(_ id: String, link: (String) -> LifecycleLink?) -> StoredModelVerdict {
    if link(id)?.offered == true { return .keep }
    if let target = resolvedReplacement(of: id, link: link) { return .move(to: target) }
    return .clear
}

/// What a model setting holds once its model led nowhere: an empty string, so the user
/// picks (the owner's call, 2026-10-16). Not an absent key, which reads through to the
/// provider's default and is pinned at the next launch — a cleared choice would quietly
/// come back as the default, which is the silent move the lifecycle exists to stop. A dictation on
/// an engine whose choice is cleared is refused until the user picks
/// (`RecordingConfiguration.modelChoiceMissing`), and AI Rewrite falls back to the text as
/// dictated (`LLMError.noModelChosen`).
public let clearedModelChoice = ""

/// Applies `storedModelVerdict` to every normalised model setting in `defaults` and
/// appends what changed to `SettingsKeys.modelMigrations`. Takes the store, so the tests
/// run it against an isolated suite.
@discardableResult
func migrateStoredModels(in defaults: UserDefaults, now: Date = Date()) -> [ModelMigration] {
    var settings: [(key: String, link: (String) -> LifecycleLink?)] = []
    for engine in STTProviderType.allCases {
        guard let setting = engine.vendor.descriptor.speechModel, setting.normalized,
              let key = setting.settingsKey else { continue }
        settings.append((key, { speechLifecycleLink(vendor: engine.vendor, id: $0) }))
    }
    for type in LLMProviderType.allCases {
        guard let setting = type.vendor.descriptor.chatModel, setting.normalized,
              let key = setting.settingsKey else { continue }
        settings.append((key, { chatLifecycleLink(provider: type, id: $0) }))
    }

    var moved: [ModelMigration] = []
    for (key, link) in settings {
        // A choice already cleared waits for the user, and was recorded when it was cleared.
        guard let raw = defaults.string(forKey: key), raw != clearedModelChoice else { continue }
        switch storedModelVerdict(raw, link: link) {
        case .keep:
            continue
        case .move(let target):
            dlog("Settings", "\(key)=\"\(raw)\" is being retired by its vendor — moved to \(target)")
            defaults.set(target, forKey: key)
            moved.append(ModelMigration(settingsKey: key, from: raw, to: target, reason: .deprecated, date: now))
        case .clear:
            dlog("Settings", "\(key)=\"\(raw)\" leads to no model on offer — cleared for the user to pick", level: .notice)
            defaults.set(clearedModelChoice, forKey: key)
            moved.append(ModelMigration(settingsKey: key, from: raw, to: nil, reason: .unavailable, date: now))
        }
    }
    if !moved.isEmpty {
        let earlier = storedModelMigrations(in: defaults)
        // The newest 20 are plenty: each is told once, at the next dictation.
        let all = Array((earlier + moved).suffix(20))
        defaults.set(try? JSONEncoder().encode(all), forKey: SettingsKeys.modelMigrations)
    }
    return moved
}

/// The moves recorded so far, oldest first.
public func storedModelMigrations(in defaults: UserDefaults) -> [ModelMigration] {
    guard let data = defaults.data(forKey: SettingsKeys.modelMigrations) else { return [] }
    return (try? JSONDecoder().decode([ModelMigration].self, from: data)) ?? []
}

// MARK: - Pinning a default nobody chose

/// Writes down the model an untouched install is running, so a later change of our
/// default does not move it: only new installs get a new default, and everyone else is
/// *offered* it (`ModelLifecycle.superseded`).
///
/// Only the speech engine and AI provider in use are pinned. Writing every provider's
/// default would hand a Groq user `localSTTModel = <today's default>`, and once that
/// default moved, switching to the local tier would point at a model they never
/// downloaded. The local tier is not pinned here at all: `preserveInstalledLocalModel`
/// pins it to a model on disk, whichever engine is in use, and with none installed there
/// is nothing to keep. A cleared choice (`clearedModelChoice`) is a stored value, so it is
/// never pinned over.
func pinUntouchedModelChoices(in defaults: UserDefaults) {
    let engine = defaults.string(forKey: SettingsKeys.sttProvider).flatMap(STTProviderType.init(rawValue:)) ?? .apple
    if engine != .local, let setting = engine.vendor.descriptor.speechModel, setting.normalized,
       let key = setting.settingsKey, defaults.string(forKey: key) == nil {
        dlog("Settings", "\(key) was never set — pinning \(setting.defaultID)")
        defaults.set(setting.defaultID, forKey: key)
    }
    let ai = defaults.string(forKey: SettingsKeys.llmProvider).flatMap(LLMProviderType.init(rawValue:)) ?? .groq
    if let setting = ai.vendor.descriptor.chatModel, setting.normalized,
       let key = setting.settingsKey, defaults.string(forKey: key) == nil {
        dlog("Settings", "\(key) was never set — pinning \(setting.defaultID)")
        defaults.set(setting.defaultID, forKey: key)
    }
}

// MARK: - A reply that says the model is gone

/// Whether a vendor's error reply says the model asked for is not served — switched off,
/// renamed, or never existed. Read from the body's codes, never the HTTP status, which
/// differs per vendor for the same meaning. Measured 2026-10-16 and 2026-10-17 with the
/// project's test keys (the literal bodies are in `ModelUnavailableReplyTests`):
///
/// - OpenAI and Groq: `error.code` `model_not_found` (404) — which also means the key has
///   no access to a model that exists, so the notice keeps the vendor's own words rather
///   than saying the model was switched off — and Groq's `model_decommissioned` (400);
/// - ElevenLabs: `detail.code` `unsupported_model` (400);
/// - Anthropic: `error.type` `not_found_error` with a message `model: <id>` (404). The type
///   alone is any 404 of Anthropic's ("Not found" for an unknown path), so both are read.
///
/// Nothing retries on it (the owner's call, 2026-10-17): a model the catalogue retires is
/// moved at launch before a request can name it, so the reply means a model nobody here
/// knew was going, or a key without access — the user's to sort out in Settings, and the
/// audio is in History for a retry.
enum ModelUnavailableReply {
    static func matches(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let error = json["error"] as? [String: Any] {
            if let code = error["code"] as? String, ["model_not_found", "model_decommissioned"].contains(code) {
                return true
            }
            if error["type"] as? String == "not_found_error",
               (error["message"] as? String)?.hasPrefix("model: ") == true {
                return true
            }
        }
        if let detail = json["detail"] as? [String: Any], detail["code"] as? String == "unsupported_model" {
            return true
        }
        return false
    }
}

extension TranscriptionError {
    /// The vendor answered that the model is not served (`ModelUnavailableReply`).
    public var isModelUnavailable: Bool {
        if case .httpError(_, _, let body) = self { ModelUnavailableReply.matches(body) } else { false }
    }
}

extension LLMError {
    /// The vendor answered that the model is not served, or none is chosen: either way the
    /// user's next step is the model picker.
    public var needsModelChoice: Bool {
        switch self {
        case .httpError(_, let body): ModelUnavailableReply.matches(body)
        case .noModelChosen: true
        default: false
        }
    }
}

// MARK: - Telling the user

/// A one-time notice about the model in use, or the one that says a dictation needs a
/// model picked. Built here, shown by `AppState` as a status notice whose action is one of
/// `Action`'s.
public struct ModelNotice: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        case speech, chat
    }

    public enum Action: Equatable, Sendable {
        /// Opens Settings on the role's page.
        case openSettings(Role)
        /// Stores `id` under `settingsKey`.
        case switchModel(settingsKey: String, to: String)
    }

    /// What `SettingsKeys.modelNoticesShown` records, so each is told once.
    public let id: String
    public let title: String
    public let detail: String
    public let actionTitle: String
    public let action: Action
}

/// The model settings a notice can be about: the speech engine's and the AI provider's
/// in use (`nil` for one with no stored choice — Apple's speech, an AI provider without a
/// list). Read from the store by `AppState`, handed in so the rules stay testable.
public struct ModelSettingsInUse: Equatable, Sendable {
    var speechKey: String?
    var chatKey: String?

    init(speechKey: String?, chatKey: String?) {
        self.speechKey = speechKey
        self.chatKey = chatKey
    }

    public init(_ defaults: UserDefaults) {
        let engine = defaults.string(forKey: SettingsKeys.sttProvider).flatMap(STTProviderType.init(rawValue:)) ?? .apple
        let ai = defaults.string(forKey: SettingsKeys.llmProvider).flatMap(LLMProviderType.init(rawValue:)) ?? .groq
        speechKey = engine.vendor.descriptor.speechModel.flatMap { $0.normalized ? $0.settingsKey : nil }
        chatKey = ai.vendor.descriptor.chatModel.flatMap { $0.normalized ? $0.settingsKey : nil }
    }
}

/// The next notice the first dictation after an update owes, or nil. Only about the
/// settings in use — a move of a provider the user does not use is told if they switch
/// to it — and only while the setting still holds what the move left there. In order: a
/// model the vendor is retiring that the launch moved (`ModelMigration`), then a model in
/// use that a newer one supersedes. A cleared choice is not here: a dictation that needs
/// it is refused with `modelChoiceNotice` every time until the user picks.
public func pendingModelNotice(inUse: ModelSettingsInUse, stored: (String) -> String?,
                        migrations: [ModelMigration], shown: Set<String>) -> ModelNotice? {
    for (role, key) in [(ModelNotice.Role.speech, inUse.speechKey), (.chat, inUse.chatKey)] {
        guard let key, let current = stored(key) else { continue }
        if let move = migrations.last(where: { $0.settingsKey == key && $0.reason == .deprecated && $0.to == current }),
           !shown.contains(move.noticeID) {
            return movedNotice(move, role: role)
        }
        if let offer = supersededNotice(key: key, id: current, role: role), !shown.contains(offer.id) {
            return offer
        }
    }
    return nil
}

/// The notice a dictation (or an AI pass) that needs a model is refused with: names the
/// model the launch cleared when a move recorded it, and opens the picker.
public func modelChoiceNotice(settingsKey key: String, role: ModelNotice.Role, migrations: [ModelMigration]) -> ModelNotice {
    let naming = ModelNaming(key: key)
    let old = migrations.last { $0.settingsKey == key && $0.to == nil }.map { naming.name(of: $0.from) }
    return ModelNotice(
        id: "choose:\(key)",
        title: "Choose a model for \(naming.target)",
        detail: old.map { "\($0) is no longer available." }
            ?? (role == .speech ? "Dictation waits for your pick." : "AI Rewrite waits for your pick."),
        actionTitle: "Choose",
        action: .openSettings(role))
}

extension ModelMigration {
    /// What `SettingsKeys.modelNoticesShown` records once this move was told.
    var noticeID: String { "moved:\(settingsKey):\(from)" }
}

private func movedNotice(_ move: ModelMigration, role: ModelNotice.Role) -> ModelNotice {
    let naming = ModelNaming(key: move.settingsKey)
    let new = move.to ?? ""
    let when = naming.shutdown(of: move.from).map { "retires on \(ModelRetirement.dayText($0))" } ?? "is retiring"
    let price = naming.priceChange(from: move.from, to: new).map { " \($0)" } ?? ""
    return ModelNotice(
        id: move.noticeID,
        title: "Now using \(naming.name(of: new))",
        detail: "\(naming.name(of: move.from)) \(when).\(price)",
        actionTitle: "Settings",
        action: .openSettings(role))
}

private func supersededNotice(key: String, id: String, role: ModelNotice.Role) -> ModelNotice? {
    let naming = ModelNaming(key: key)
    guard case .superseded(let next)? = naming.lifecycle(of: id), naming.isOffered(next) else { return nil }
    let noticeID = "superseded:\(key):\(id)"
    if naming.vendor == .local {
        // Never downloaded for the user: the new version is recommended, and the row in
        // Settings downloads it when they choose it.
        return ModelNotice(
            id: noticeID,
            title: "Newer: \(naming.name(of: next))",
            detail: "We recommend updating from \(naming.name(of: id)). Download it in Settings.",
            actionTitle: "Settings",
            action: .openSettings(role))
    }
    let price = naming.priceChange(from: id, to: next).map { " \($0)" } ?? ""
    return ModelNotice(
        id: noticeID,
        title: "Newer: \(naming.name(of: next))",
        detail: "It supersedes \(naming.name(of: id)).\(price)",
        actionTitle: "Switch",
        action: .switchModel(settingsKey: key, to: next))
}

/// A model setting's vendor, and what the catalogue says about a model stored under it.
private struct ModelNaming {
    /// The speech vendor whose setting this is, if it is a speech setting.
    let vendor: Provider?
    let chat: LLMProviderType?

    init(key: String) {
        vendor = Provider.allCases.first { $0.descriptor.speechModel?.settingsKey == key }
        chat = vendor == nil
            ? LLMProviderType.allCases.first { $0.vendor.descriptor.chatModel?.settingsKey == key }
            : nil
    }

    /// "this Mac" or the vendor's name (`Provider.modelChoiceTarget`).
    var target: String {
        vendor?.modelChoiceTarget ?? chat?.vendor.modelChoiceTarget ?? ""
    }

    /// The model's name without a picker note ("Scribe v2 Realtime", not "… — live text").
    func name(of id: String) -> String {
        if let vendor { return plainModelName(sttModel(vendor: vendor, id: id).displayName) }
        if let chat { return plainModelName(listedChatModel(provider: chat, id: id)?.displayName ?? knownChatModelName(id: id)) }
        return id
    }

    func lifecycle(of id: String) -> ModelLifecycle? {
        if let vendor { return knownSTTModels(of: vendor).first { $0.id == id }?.lifecycle }
        if let chat { return knownChatModels(of: chat).first { $0.id == id }?.lifecycle }
        return nil
    }

    func isOffered(_ id: String) -> Bool {
        if let vendor { return offeredSTTModels(of: vendor).contains { $0.id == id } }
        if let chat { return offeredChatModels(of: chat).contains { $0.id == id } }
        return false
    }

    func shutdown(of id: String) -> Date? {
        lifecycle(of: id)?.deprecation?.shutdown.date
    }

    /// "Same price." / "+$0.0015/min." / "About 2× the price." — nil where either
    /// side has no list price (free on the Mac, or not priced). A chat model is compared
    /// by a million tokens in and out together, the only way two rate cards read as one.
    func priceChange(from old: String, to new: String) -> String? {
        if let vendor {
            guard case .listed(let was) = sttModel(vendor: vendor, id: old).price,
                  case .listed(let now) = sttModel(vendor: vendor, id: new).price else { return nil }
            let difference = now.perMinute - was.perMinute
            if abs(difference) < 0.000_000_5 { return "Same price." }
            return "\(difference > 0 ? "+" : "−")\(dollars(abs(difference)))/min."
        }
        if let chat {
            guard case .listed(let was) = chatModel(provider: chat, id: old).price,
                  case .listed(let now) = chatModel(provider: chat, id: new).price else { return nil }
            let ratio = (now.inputPerToken + now.outputPerToken) / (was.inputPerToken + was.outputPerToken)
            if abs(ratio - 1) < 0.05 { return "Same price." }
            return ratio > 1 ? "About \(String(format: "%.2g", ratio))× the price."
                             : "About \(Int((ratio * 100).rounded()))% of the price."
        }
        return nil
    }
}

/// "$0.003", "$2.5", "$15" — up to four significant digits, no trailing zeros.
func dollars(_ value: Double) -> String {
    "$" + String(format: "%.4g", value)
}
