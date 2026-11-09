// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import NaturalLanguage

/// What step one decided about a dictation, kept in History so a choice that looks wrong
/// can be traced (D10 of docs/specs/2026-11-03-rewrite-modes-and-router.md).
public struct RewriteRoute: Codable, Equatable, Sendable {
    public enum Format: String, Codable, CaseIterable, Sendable {
        case plain, list, markdown
    }

    /// Who decided. A language the model named and code dropped (D4) is code's.
    public enum Source: String, Codable, Sendable {
        case stepOne, code
    }

    /// An ISO 639-1 code, `RewriteRouter.anotherLanguage`, or nil when none was asked for.
    public var language: String?
    public var format: Format
    public var languageBy: Source
    public var formatBy: Source
    /// The model step one was read from; nil when code alone decided (D3).
    public var stepOneModel: String?
}

/// AI Rewrite in two steps (#110): step one reads the mode, the language asked for and the
/// format off a local model's next-token probabilities, and step two is sent that one
/// mode's instructions, the modifiers as lines. Pure but for the model it is handed, which
/// is the `read` closure of `StepOne`.
public enum RewriteRouter {

    /// Whether dictations go through two steps. Off until #114 measures them: the owner's
    /// rule is that two steps ship only where they beat the cleaned one-step prompt, so
    /// users get `RewriteModes.request` until then. The harness's `route` and `two-step`
    /// variants and the tests do not read this.
    public static let twoStepsShip = false

    /// The prompts one request can be sent: routing, a field for another program, a
    /// shell prompt's, a terminal where nothing says which, and the Edit shortcut's.
    public static let oneStepPromptStates = 5
    /// Those, step one's, and a prompt per mode; past it a mode's prompt is read again, as
    /// any prompt is (D7). Raised only with the gate: a state is about 147 MB for Gemma 4
    /// 12B (M1 Pro, 2026-11-08), and stale ones after a prompt edit would stay this long.
    public static let twoStepPromptStates = 10
    public static var savedPromptStates: Int { twoStepsShip ? twoStepPromptStates : oneStepPromptStates }

    /// The models already loaded for AI Rewrite that router v4 measured (2026-11-03/04):
    /// Gemma 4 12B 42 of 43 at 0.86 s, Qwen3.5 9B 41 at 0.64 s. Plain small models were
    /// not usable (Qwen3.5 2B 24–32) and the others were not read, so they get one step.
    static let stepOneModelIDs: Set<String> = ["gemma-4-12b-it-qat-q4_0", "Qwen3.5-9B-Q4_K_M"]

    public static func canReadStepOne(modelID: String) -> Bool { stepOneModelIDs.contains(modelID) }

    /// The language answer for *another*: step two reads which one from the transcript (D4).
    public static let anotherLanguage = "other"

    /// One token each in the models measured, and an answer is one of them (D6).
    private static let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)

    // MARK: - Step one

    public struct StepOneRequest: Equatable, Sendable {
        /// What is read after the rendered prompt before an answer, and the answer's letters.
        public struct Step: Equatable, Sendable {
            public var lead: String
            public var letters: [String]
        }

        public var system: String
        public var user: String
        public var steps: [Step]
    }

    /// Each step's options as probabilities, in the order of its letters.
    public struct StepOneReading: Equatable, Sendable {
        public var probabilities: [[Double]]
        public var promptTokens = 0
        public var cachedPromptTokens = 0
        public var seconds = 0.0

        public init(probabilities: [[Double]], promptTokens: Int = 0, cachedPromptTokens: Int = 0, seconds: Double = 0) {
            self.probabilities = probabilities
            self.promptTokens = promptTokens
            self.cachedPromptTokens = cachedPromptTokens
            self.seconds = seconds
        }
    }

    /// The model step one is read from, and what the questions need.
    public struct StepOne: Sendable {
        public var modelID: String
        public var spokenLanguages: [String]
        /// nil only in the harness's `route`, which times the reading rather than stopping it.
        public var timeout: Double?
        public var read: @Sendable (StepOneRequest) async throws -> StepOneReading

        public init(modelID: String, spokenLanguages: [String], timeout: Double? = STTTuning.rewriteStepOneTimeoutSeconds,
                    read: @escaping @Sendable (StepOneRequest) async throws -> StepOneReading) {
            self.modelID = modelID
            self.spokenLanguages = spokenLanguages
            self.timeout = timeout
            self.read = read
        }
    }

    /// What step two is sent: its request, and the `<route>` block for the user message.
    public struct Decision: Sendable {
        public var request: RewriteModes.Request
        public var routeBlock: String?
        public var route: RewriteRoute
    }

    private struct Asked {
        var request: StepOneRequest
        var modes: [PromptPreset]
        /// The modes' positions step one may answer: all, or D3's cut.
        var offered: [Int]
        var languages: [String?]
        var asksModifiers: Bool
    }

    private enum StepOneFailure: Error {
        case timedOut
    }

    /// The system prompt of step one, the same for a Mac's every dictation until a prompt
    /// is edited, so it is one saved state. Nil past the letters there are. The wording is
    /// router v4's (2026-11-03), but for its examples of asking in Ukrainian or English,
    /// which every language now gets in one form, and the default, named only when the
    /// user moved it off Clean-up, the case it was measured on.
    public static func stepOneSystem(presets: [PromptPreset], defaultPresetID: UUID?, spokenLanguages: [String]) -> String? {
        let languages = languageAnswers(spokenLanguages: spokenLanguages)
        guard presets.count <= letters.count, languages.count <= letters.count else { return nil }
        let fallback = PromptPresetStore.defaultPreset(in: presets, storedID: defaultPresetID)
        let modes = presets.enumerated().map { index, mode -> String in
            let marker = mode.id == fallback?.id && mode.id != RewriteModes.builtIns[0].id
                ? " (default when nothing else clearly fits)" : ""
            return "\(letters[index]) — \(mode.name)\(marker): \(mode.whenToUse.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n")
        let languageLines = languages.enumerated().map { index, code -> String in
            switch code {
            case nil: return "\(letters[index]) — none: No language is asked for - most dictations."
            case anotherLanguage: return "\(letters[index]) — another language: The result is asked for in a language not listed here."
            case let code?:
                let name = languageName(code)
                return "\(letters[index]) — \(name): The result is asked for in \(name), such as «in \(name)», «translate to \(name)»."
            }
        }.joined(separator: "\n")
        return """
            You classify a dictation for a dictation app. The user message holds the \
            dictation: <context>, where the text will be pasted, and <transcript>, raw \
            speech-to-text that holds an instruction, the content, or both. Answer each \
            question about it with the letter of the best option only.

            Question 1 (mode): Which kind of text does the dictation ask for?
            Options:
            \(modes)

            Question 2 (language): Does the dictation explicitly ask for the result in a \
            particular language? Speaking a language is not asking for it.
            Options:
            \(languageLines)

            Question 3 (format): What format does the dictation ask for?
            Options:
            A — plain: Ordinary text: no list and no formatting is asked for.
            B — list: A list or bullet points, and nothing more.
            C — markdown: The user names headings, bold, tables or other rich formatting.
            """
    }

    /// None, each spoken language, English if it is not among them, and *another* (D4).
    static func languageAnswers(spokenLanguages: [String]) -> [String?] {
        let codes = spokenLanguages + (spokenLanguages.contains("en") ? [] : ["en"])
        return [nil] + codes.map(Optional.some) + [anotherLanguage]
    }

    private static func languageName(_ code: String) -> String { spokenLanguage(id: code)?.displayName ?? code }

    private static func ask(transcript: String, context: FocusContext?, presets: [PromptPreset],
                            defaultPresetID: UUID?, spokenLanguages: [String]) -> Asked? {
        guard !presets.isEmpty,
              let system = stepOneSystem(presets: presets, defaultPresetID: defaultPresetID, spokenLanguages: spokenLanguages)
        else { return nil }
        let forAnotherProgram = context?.takesTextForAnotherProgram == true
        let offeredIDs = Set(RewriteModes.offeredToAnotherProgram(presets).map(\.id))
        let offered = presets.indices.filter { !forAnotherProgram || offeredIDs.contains(presets[$0].id) }
        guard !offered.isEmpty else { return nil }
        let languages = languageAnswers(spokenLanguages: spokenLanguages)
        var steps = [StepOneRequest.Step(lead: "1 (mode): ", letters: offered.map { letters[$0] })]
        if !forAnotherProgram {
            steps.append(.init(lead: "\n2 (language): ", letters: Array(letters.prefix(languages.count))))
            steps.append(.init(lead: "\n3 (format): ", letters: Array(letters.prefix(RewriteRoute.Format.allCases.count))))
        }
        let closing = forAnotherProgram ? "Answer question 1 with one letter." : "Answer the three questions, one letter each."
        let user = TextRefinementService.userMessage(transcript: transcript, context: context) + "\n\n" + closing
        return Asked(request: StepOneRequest(system: system, user: user, steps: steps), modes: presets, offered: offered,
                     languages: languages, asksModifiers: !forAnotherProgram)
    }

    /// Step one's answer as step two's request, or nil for the one-step prompt: a model that
    /// cannot be read, a failure, an answer that is not one of the options, or no answer
    /// within the timeout (D6). It never throws, so a dictation waits on it once.
    public static func decide(transcript: String, context: FocusContext?, presets: [PromptPreset],
                              defaultPresetID: UUID?, stepOne: StepOne) async -> Decision? {
        guard canReadStepOne(modelID: stepOne.modelID) else { return nil }
        let commands = context?.commandWriting ?? .never
        let markdownRenders = context?.rendersMarkdown == true
        if context?.takesTextForAnotherProgram == true {
            let cleanUpID = RewriteModes.builtIns[0].id
            let offered = RewriteModes.offeredToAnotherProgram(presets)
            if !offered.contains(where: { $0.id != cleanUpID }) {
                let cleanUp = presets.first { $0.id == cleanUpID } ?? RewriteModes.builtIns[0]
                return Decision(request: stepTwo(mode: cleanUp, names: [cleanUp.name], forAnotherProgram: true, commands: commands),
                                routeBlock: routeBlock(language: nil, format: .plain, markdownRenders: markdownRenders),
                                route: RewriteRoute(language: nil, format: .plain, languageBy: .code, formatBy: .code, stepOneModel: nil))
            }
        }
        guard let asked = ask(transcript: transcript, context: context, presets: presets,
                              defaultPresetID: defaultPresetID, spokenLanguages: stepOne.spokenLanguages) else {
            dlog("Refine", "step one: not asked, one step", level: .notice)
            return nil
        }
        let reading: StepOneReading
        do {
            let request = asked.request
            let read = stepOne.read
            reading = try await withTimeout(stepOne.timeout) { try await read(request) }
        } catch {
            dlog("Refine", "step one: \(String(describing: type(of: error))), one step", level: .notice)
            return nil
        }
        guard let decision = decision(from: reading, asked: asked, transcript: transcript, commands: commands,
                                      markdownRenders: markdownRenders,
                                      spokenLanguages: stepOne.spokenLanguages, modelID: stepOne.modelID) else {
            dlog("Refine", "step one: unreadable answer, one step", level: .notice)
            return nil
        }
        dlog("Refine", "step one: format=\(decision.route.format.rawValue), language=\(decision.route.language ?? "—"), \(reading.promptTokens) tok")
        return decision
    }

    private static func decision(from reading: StepOneReading, asked: Asked, transcript: String,
                                 commands: RewriteModes.CommandWriting, markdownRenders: Bool,
                                 spokenLanguages: [String], modelID: String) -> Decision? {
        let steps = asked.request.steps
        guard reading.probabilities.count == steps.count,
              zip(reading.probabilities, steps).allSatisfy({ $0.count == $1.letters.count && $0.allSatisfy(\.isFinite) && !$0.isEmpty })
        else { return nil }
        func best(_ step: Int) -> Int {
            let values = reading.probabilities[step]
            return values.indices.max { values[$0] < values[$1] } ?? 0
        }
        let mode = asked.modes[asked.offered[best(0)]]
        let names = asked.modes.map(\.name)
        guard asked.asksModifiers else {
            return Decision(request: stepTwo(mode: mode, names: names, forAnotherProgram: true, commands: commands),
                            routeBlock: routeBlock(language: nil, format: .plain, markdownRenders: markdownRenders),
                            route: RewriteRoute(language: nil, format: .plain, languageBy: .code, formatBy: .code, stepOneModel: modelID))
        }
        var language = asked.languages[best(1)]
        var languageBy = RewriteRoute.Source.stepOne
        if let named = language, named != anotherLanguage,
           dictatedLanguage(transcript, among: spokenLanguages + ["en"]) == named {
            language = nil
            languageBy = .code
        }
        let format = RewriteRoute.Format.allCases[best(2)]
        return Decision(request: stepTwo(mode: mode, names: names, forAnotherProgram: false, commands: commands),
                        routeBlock: routeBlock(language: language, format: format, markdownRenders: markdownRenders),
                        route: RewriteRoute(language: language, format: format, languageBy: languageBy, formatBy: .stepOne,
                                            stepOneModel: modelID))
    }

    /// The bar for dropping a request as the language already spoken: as sure as the
    /// recogniser was on every fixture, a single word included (at least 0.9999, between
    /// languages of different scripts; router v4, 2026-11-03). The rule only removes a
    /// request that changes nothing, so below it, between English and Polish say, the
    /// model's answer stands (D4).
    private static let dictatedLanguageConfidence = 0.9999

    /// The language `text` is in, among `codes`, when the recogniser is sure of it.
    static func dictatedLanguage(_ text: String, among codes: [String]) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = codes.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
              top.value >= dictatedLanguageConfidence else { return nil }
        return top.key.rawValue
    }

    private static func withTimeout<T: Sendable>(_ seconds: Double?,
                                                 _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let seconds else { return try await body() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw StepOneFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw StepOneFailure.timedOut }
            return first
        }
    }

    // MARK: - Step two

    /// D7: outside the system prompt, so each mode's prompt stays one saved prefix whatever
    /// the modifiers. Nil when there is nothing to say, the transcript's own default.
    /// `markdownRenders` is a fact about the destination, code's and not step one's (D5,
    /// #111), so History's `route` does not record it: `context` already says where it went.
    static func routeBlock(language: String?, format: RewriteRoute.Format, markdownRenders: Bool) -> String? {
        var lines: [String] = []
        if let language {
            lines.append("language: " + (language == anotherLanguage ? "the one the transcript asks for" : languageName(language)))
        }
        if format != .plain { lines.append("format: \(format.rawValue)") }
        if markdownRenders { lines.append("markdown: renders here") }
        return lines.isEmpty ? nil : "<route>\n\(lines.joined(separator: "\n"))\n</route>"
    }

    /// The opening of `RewriteModes` with its "output only" left to the rules (#110's
    /// comment: each of the three repeats of the one-step prompt said once here).
    private static let stepTwoOpening = """
        You are a dictation app's text engine. The raw speech-to-text in <transcript> is \
        the request: the text itself, an instruction about it, or both. Do what it asks; \
        the result is pasted at the user's cursor: "write an email to Anna" means the \
        email; "rewrite this more warmly: …" means the rewritten text.
        """

    /// Clean-up's work with the fillers and "Add nothing" left to the rules.
    private static let stepTwoCleanUpWork = """
        recognition errors, punctuation, capitals and paragraphs fixed; false starts and \
        repeats dropped. Keep the user's words and order of thought, with no structure \
        that was not asked for.
        """

    /// D7's line, and how to read `<route>`: length, tone and a rewrite stay the transcript's (D2).
    private static let stepTwoModifiers = """
        Then:
        - <route>, when it comes before the transcript, is already decided: write in its \
        language, whatever the mode; `format: list` is a "- " or numbered list, \
        `format: markdown` the headings, bold or tables the transcript names.
        - Without a language there: keep the dictated one, and a sentence that mixes \
        languages stays mixed. Terms, names and code stay as said. Without a format: \
        plain text.
        - `markdown: renders here` in <route>: the destination shows Markdown, so a text \
        with a form of its own may use headings, bold or tables unasked; dictated text \
        stays plain.
        - Do whatever else the transcript asks: length, tone, "rewrite it", "make it better".
        """

    /// D3 with D5's fact: the model still adds no format in a field for another program;
    /// Markdown said aloud into a Markdown file is kept as dictated. A terminal is never told.
    private static let stepTwoKeepsMarkdown = """
        - `markdown: renders here` in <route>: Markdown the transcript spells out stays \
        Markdown; add none of your own.
        """

    /// The instructions step two is given: for a built-in Clean-up as it ships, the text
    /// that repeats nothing the rules say; else the mode's own, the user's words.
    private static func stepTwoInstructions(_ mode: PromptPreset, forAnotherProgram: Bool) -> String {
        if mode.id == RewriteModes.builtIns[0].id, mode.instructions == RewriteModes.builtIns[0].instructions {
            return forAnotherProgram
                ? "Write down what was said as finished text: \(stepTwoCleanUpWork)"
                : "Write down the dictated text, not the request about it, as finished text: \(stepTwoCleanUpWork)"
        }
        return mode.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One mode's request: the mode decided, no marker asked for, one still taken off (D7).
    /// `names` is every mode the marker could name.
    static func stepTwo(mode: PromptPreset, names: [String], forAnotherProgram: Bool,
                        commands: RewriteModes.CommandWriting) -> RewriteModes.Request {
        let instructions = stepTwoInstructions(mode, forAnotherProgram: forAnotherProgram)
        let system: String
        if forAnotherProgram {
            let markdown = commands == .never ? "\n\(stepTwoKeepsMarkdown)" : ""
            system = """
                \(RewriteModes.openingForAnotherProgram)

                \(RewriteModes.rules)
                \(RewriteModes.programRule(commands))\(markdown)

                \(instructions) Keep the language it was dictated in.
                """
        } else {
            system = """
                \(stepTwoOpening)

                \(RewriteModes.rules)
                \(RewriteModes.contextRule)

                Mode: \(mode.name)
                \(instructions)

                \(stepTwoModifiers)
                """
        }
        return RewriteModes.Request(system: system, modeNames: names, decidedMode: mode.name, commands: commands)
    }

    /// The prompts worth reading while the user speaks once two steps ship, step one's
    /// first: read cold it takes 2.6–3.8 s, over its timeout (router v4).
    public static func prewarmSystems(presets: [PromptPreset], defaultPresetID: UUID?, spokenLanguages: [String]) -> [String] {
        let cleanUp = presets.first { $0.id == RewriteModes.builtIns[0].id } ?? RewriteModes.builtIns[0]
        return [stepOneSystem(presets: presets, defaultPresetID: defaultPresetID, spokenLanguages: spokenLanguages),
                stepTwo(mode: cleanUp, names: [], forAnotherProgram: true, commands: .never).system,
                stepTwo(mode: cleanUp, names: [], forAnotherProgram: false, commands: .never).system].compactMap { $0 }
    }

    // MARK: - Scoring

    /// D12: whether a language answer is right for the language a fixture asked for.
    /// *Another* is right only for a language outside the run's options.
    public static func languageAnswerIsRight(_ answer: String?, expected: String?, spokenLanguages: [String]) -> Bool {
        if answer == anotherLanguage {
            guard let expected else { return false }
            return !languageAnswers(spokenLanguages: spokenLanguages).contains(expected)
        }
        return answer == expected
    }
}
