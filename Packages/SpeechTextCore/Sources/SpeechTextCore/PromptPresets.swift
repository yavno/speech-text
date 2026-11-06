// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Model

/// One "topic" the LLM can apply to a dictation.
///
/// `whenToUse` is what the model reads to decide whether this preset matches the
/// dictation — it is the routing signal, so it should describe the *situation*,
/// not the output. `instructions` is what the model applies once it has picked
/// this preset; whatever else the dictation asked for is applied on top of them,
/// so a preset need not anticipate every combination.
public struct PromptPreset: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var whenToUse: String
    public var instructions: String

    public init(id: UUID = UUID(), name: String, whenToUse: String, instructions: String) {
        self.id = id
        self.name = name
        self.whenToUse = whenToUse
        self.instructions = instructions
    }
}

// MARK: - Store

public enum PromptPresetStore {
    /// Stable IDs so `defaultPresetID` keeps pointing at the right preset across launches.
    private static func fixedID(_ suffix: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(suffix)")!
    }

    static let cleanupPresetID = fixedID("01")

    /// The three modes of docs/specs/2026-11-03-rewrite-modes-and-router.md, kept in
    /// `RewriteModes` with the prompt that carries them. Each says what it is for and what
    /// to do, and stops there: they go out in full on every AI dictation and every edit,
    /// and the model fills in the obvious. The user's own prompts may be as long as they
    /// like.
    public static var builtInDefaults: [PromptPreset] { RewriteModes.builtIns }

    // MARK: - Built-ins that shipped before

    /// The six built-ins v0.10.0 shipped, as `53b1287` (2026-10-18) left them and as they
    /// stood from `1ead0ee` (2026-10-06). The harness's `current` variant measures them,
    /// the baseline #109 was held to, and the migration knows them as shipped.
    public static let october2026: [PromptPreset] = [
        PromptPreset(
            id: fixedID("01"),
            name: "Clean-up",
            whenToUse: "Plain content, with no instruction about style, format or language.",
            instructions: """
            Write down what was said, as clean text: recognition errors, punctuation, \
            capitals and paragraphs fixed, fillers and false starts dropped. Keep the \
            user's own wording and language; add nothing.
            """
        ),
        PromptPreset(
            id: fixedID("02"),
            name: "Rewrite / Draft",
            whenToUse: """
            A rough draft the user asked to write, rewrite, polish, expand or shorten, or \
            asked for in a particular style or tone.
            """,
            instructions: """
            Write it as well-made prose in the style, tone and length asked for, clear and \
            natural if none was named. Keep every fact and intent; invent nothing.
            """
        ),
        PromptPreset(
            id: fixedID("03"),
            name: "Email / Message",
            whenToUse: "An email, letter, chat message or reply addressed to someone.",
            instructions: """
            Write the message, in the register asked for and polite and professional \
            otherwise. Greeting and sign-off only where the format calls for them. Invent \
            no names, dates or facts — leave an obvious [placeholder] instead.
            """
        ),
        PromptPreset(
            id: fixedID("04"),
            name: "Translate",
            whenToUse: "The user asked to translate, or for the text in another language.",
            instructions: """
            Write it in the target language as someone writing natively would, keeping \
            tone and formatting. Output only the translation.
            """
        ),
        PromptPreset(
            id: fixedID("05"),
            name: "Notes / Bullets",
            whenToUse: "The user asked for a summary, notes, bullet points, a list, or structure.",
            instructions: """
            Compact "- " bullets, grouped by topic, in the order the user raised them. One \
            idea per line; no padding, no closing commentary.
            """
        ),
        PromptPreset(
            id: fixedID("06"),
            name: "Technical / Prompt",
            whenToUse: """
            Something technical: a commit message, a PR or ticket description, a bug \
            report, or an instruction meant for an AI coding tool.
            """,
            instructions: """
            Use that artefact's conventional form — imperative mood for a commit message, \
            problem / steps / expected for a bug report, explicit steps for an AI \
            instruction. Keep identifiers, paths and commands exactly as dictated, fixing \
            only obvious mishearings of them.
            """
        ),
    ]

    /// The six as they first shipped, from `71edce8` (2026-08-26) until `1ead0ee`: a
    /// stored copy may hold these. Git history holds no other text for them, across the
    /// file's three paths (VoicePeter/, SpeechText/SpeechText/, here).
    static let august2026: [PromptPreset] = [
        PromptPreset(id: fixedID("01"), name: "Clean-up",
                     whenToUse: "The dictation is plain content with no instruction about style, format or language — the user just wants what they said, written down properly.",
                     instructions: "Rewrite the dictation as clean written text. Fix speech-recognition errors, misheard words, punctuation, capitalization and paragraph breaks. Remove filler words, stutters, repetitions and false starts. Keep the user's own wording, tone and language — do not translate, do not summarise, do not add anything that was not said."),
        PromptPreset(id: fixedID("02"), name: "Rewrite / Draft",
                     whenToUse: "The user dictated a rough draft and asked to write, rewrite, polish, expand or shorten it, or asked for a particular style or tone.",
                     instructions: "Turn the draft into well-written prose that follows whatever style, tone, length or audience the user described. Keep every fact and intent from the draft; invent nothing. If no style was named, write clear, natural prose."),
        PromptPreset(id: fixedID("03"), name: "Email / Message",
                     whenToUse: "The user asked for an email, letter, Slack or chat message, a reply, or any text addressed to another person.",
                     instructions: "Write the message. Match the register the user asked for (formal, friendly, terse…); default to polite and professional. Include a greeting and sign-off only if the format calls for it. Do not invent names, dates or facts — leave an obvious placeholder such as [name] when something is genuinely missing."),
        PromptPreset(id: fixedID("04"), name: "Translate",
                     whenToUse: "The user asked to translate, or asked for the text in a specific language different from the one they dictated in.",
                     instructions: "Produce the text in the requested target language. Translate meaning, not words — the result must read as if it were written natively. Preserve tone and formatting. Output only the translation."),
        PromptPreset(id: fixedID("05"), name: "Notes / Bullets",
                     whenToUse: "The user asked for a summary, notes, bullet points, a list, a to-do list, or for their rambling to be structured.",
                     instructions: "Structure the content as compact bullet points or a short list, grouped by topic, in the order the user raised them. Use plain \"- \" bullets. One idea per line, no padding, no closing commentary."),
        PromptPreset(id: fixedID("06"), name: "Technical / Prompt",
                     whenToUse: "The user dictated something technical: a commit message, a PR or ticket description, a bug report, or an instruction meant for an AI coding tool.",
                     instructions: "Write it in the conventional format for that artefact — imperative mood for commit messages, problem/steps/expected for bug reports, an explicit step-by-step task description for an AI coding instruction. Keep identifiers, paths, commands and code fragments exactly as dictated; correct only obvious speech-recognition mangling of them."),
    ]

    /// Bumped when the built-ins change in a way stored prompts must follow.
    static let presetsVersion = 1

    /// D9: a stored list moved onto the three modes, once. A built-in left as it shipped
    /// — equal in name, *When to use* and instructions to any text it ever had — becomes
    /// the new one (01, 03, 05) or goes (02 Rewrite, 04 Translate, 06 Technical); one the
    /// user edited stays exactly as they left it, and their own prompts are not touched.
    /// The new texts match no old one, so a second pass changes nothing. `clearsDefault`:
    /// the stored default pointed at a prompt that went.
    static func migrated(_ stored: [PromptPreset], defaultID: UUID?) -> (presets: [PromptPreset], clearsDefault: Bool) {
        let shipped = october2026 + august2026
        let replacements = Dictionary(uniqueKeysWithValues: builtInDefaults.map { ($0.id, $0) })
        var removed: Set<UUID> = []
        let presets = stored.compactMap { preset -> PromptPreset? in
            guard shipped.contains(where: { $0.id == preset.id && $0.name == preset.name
                && $0.whenToUse == preset.whenToUse && $0.instructions == preset.instructions }) else { return preset }
            if let replacement = replacements[preset.id] { return replacement }
            removed.insert(preset.id)
            return nil
        }
        return (presets, defaultID.map(removed.contains) ?? false)
    }

    /// `migrated` on the stored list, at launch, once: before anything reads the prompts.
    /// A list never saved is the built-ins already, and only the marker is written.
    public static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: SettingsKeys.promptPresetsVersion) < presetsVersion else { return }
        defaults.set(presetsVersion, forKey: SettingsKeys.promptPresetsVersion)
        guard let data = defaults.data(forKey: SettingsKeys.promptPresets),
              let stored = try? JSONDecoder().decode([PromptPreset].self, from: data), !stored.isEmpty else { return }
        let result = migrated(stored, defaultID: storedDefaultPresetID())
        if result.presets != stored {
            if result.presets.isEmpty { defaults.removeObject(forKey: SettingsKeys.promptPresets) } else { save(result.presets) }
        }
        if result.clearsDefault { defaults.removeObject(forKey: SettingsKeys.defaultPresetID) }
        dlog("Prompts", "moved \(stored.count) stored prompt(s) to \(result.presets.count) on the 2026-11 modes")
    }

    public static func load() -> [PromptPreset] {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.promptPresets),
              let decoded = try? JSONDecoder().decode([PromptPreset].self, from: data),
              !decoded.isEmpty
        else {
            return builtInDefaults
        }
        return decoded
    }

    public static func save(_ presets: [PromptPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: SettingsKeys.promptPresets)
    }

    public static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.promptPresets)
        UserDefaults.standard.removeObject(forKey: SettingsKeys.defaultPresetID)
    }

    /// The preset the model falls back to when nothing else clearly matches, given what
    /// the user chose. Pure, so the routing prompt can be built without reading the user's
    /// settings — the split is the same one `resolveLocale` / `resolvedLocale()` makes,
    /// and for the same reason: the tests must not touch `UserDefaults`.
    static func defaultPreset(in presets: [PromptPreset], storedID: UUID?) -> PromptPreset? {
        if let storedID, let match = presets.first(where: { $0.id == storedID }) {
            return match
        }
        return presets.first(where: { $0.id == cleanupPresetID }) ?? presets.first
    }

    /// The same answer for the app, which has the user's settings to read.
    public static func defaultPreset(in presets: [PromptPreset]) -> PromptPreset? {
        defaultPreset(in: presets, storedID: storedDefaultPresetID())
    }

    /// The chosen fallback's id as stored, or nil when the user never picked one.
    public static func storedDefaultPresetID() -> UUID? {
        UserDefaults.standard.string(forKey: SettingsKeys.defaultPresetID)
            .flatMap(UUID.init(uuidString:))
    }

    public static func setDefaultPreset(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: SettingsKeys.defaultPresetID)
    }
}

// MARK: - What History says about them

/// How often AI Rewrite chose each prompt, from History — the Prompts page's counts and
/// its "last chosen for" examples. Models write a prompt's name in their own capitals
/// ("EMAIL / MESSAGE"), so a name is matched ignoring case. An edit reports its own modes
/// (Polish, Instruction) and is not a dictation's choice, so edits are left out.
public enum PresetUsage {
    public struct Use: Equatable, Sendable {
        public var count = 0
        public var last: Date?
    }

    /// Successful rewrites of a dictation, by the lowercased name of the prompt chosen.
    static func uses(in records: [TranscriptionRecord]) -> [String: Use] {
        var uses: [String: Use] = [:]
        for record in records {
            guard let name = chosenPreset(record) else { continue }
            var use = uses[name.lowercased()] ?? Use()
            use.count += 1
            use.last = max(use.last ?? record.date, record.date)
            uses[name.lowercased()] = use
        }
        return uses
    }

    /// The latest dictations rewritten with `preset`, newest first — as History keeps its
    /// records, each added at the front with the time it was made, so the first found are
    /// the latest and the search stops there.
    static func recent(_ preset: PromptPreset, in records: [TranscriptionRecord], limit: Int = 3) -> [TranscriptionRecord] {
        Array(records.lazy.filter { chosenPreset($0)?.caseInsensitiveCompare(preset.name) == .orderedSame }
            .prefix(limit))
    }

    /// Rewrites History records with no prompt name at all — a model that wrote no marker.
    static func unnamed(in records: [TranscriptionRecord]) -> Int {
        records.filter {
            guard let refinement = $0.refinement, !refinement.isSelectionEdit, refinement.succeeded else { return false }
            return refinement.presetName == nil
        }.count
    }

    private static func chosenPreset(_ record: TranscriptionRecord) -> String? {
        guard let refinement = record.refinement, !refinement.isSelectionEdit, refinement.succeeded else { return nil }
        return refinement.presetName
    }

    /// `uses` and `recent` for the Prompts page, kept until History changes: its body runs
    /// on every keystroke in the prompt being edited, and counted afresh each time that was
    /// every record read again.
    ///
    /// History is known to have changed by a fingerprint of what the two read (the number
    /// of records, the first and last, and each one's status, text length and rewrite —
    /// whether it was an edit, succeeded, its prompt's name and its length). One that
    /// changed without changing any of those goes unseen until the next change, and a count
    /// or a "last chosen for" is that much out of date meanwhile.
    public final class Cache {
        private var fingerprint: Int?
        /// The records a prompt was chosen for — a copy of its own, so History's array is
        /// not held and still changes in place.
        private var rewrites: [TranscriptionRecord] = []
        public private(set) var uses: [String: Use] = [:]
        /// By the prompt's name exactly as written: `recent` matches it its own way.
        private var recents: [String: [TranscriptionRecord]] = [:]

        public init() {}

        /// Brought up to date with `records`; counted again only when they changed.
        public func refresh(from records: [TranscriptionRecord]) {
            var hasher = Hasher()
            hasher.combine(records.count)
            hasher.combine(records.first?.id)
            hasher.combine(records.last?.id)
            for record in records {
                hasher.combine(record.status == .success)
                hasher.combine(record.text.utf8.count)
                if let refinement = record.refinement {
                    hasher.combine(refinement.isSelectionEdit)
                    hasher.combine(refinement.succeeded)
                    hasher.combine(refinement.presetName)
                    hasher.combine(refinement.outputText.utf8.count)
                } else {
                    hasher.combine(-1)
                }
            }
            let fingerprint = hasher.finalize()
            guard fingerprint != self.fingerprint else { return }
            self.fingerprint = fingerprint
            rewrites = records.filter { PresetUsage.chosenPreset($0) != nil }
            uses = PresetUsage.uses(in: rewrites)
            recents = [:]
        }

        /// `PresetUsage.recent` of the records last refreshed from.
        public func recent(_ preset: PromptPreset) -> [TranscriptionRecord] {
            if let found = recents[preset.name] { return found }
            let found = PresetUsage.recent(preset, in: rewrites)
            recents[preset.name] = found
            return found
        }
    }
}
