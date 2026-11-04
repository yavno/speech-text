// SPDX-FileCopyrightText: 2026 Vladyslav Husakov
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ChatTemplates
import SpeechTextCore

/// AI Rewrite measured: text scenarios through the app's own prompt, client and parser, on
/// cloud and local models, judged by `RewriteChecks` — the harness every change to the
/// prompt is compared with (#108). It began as the local LLM's phase-0 measurement
/// (docs/specs/2026-10-16-built-in-local-llm.md).
///
///     SpeechTextEvaluation --rewrite <fixtures.json> --runs <dir>
///                          [--engines provider/model,…] [--fixtures id,…] [--repeat n]
///                          [--variant current] [--reasoning-effort default|omit|<value>] [--concurrency n]
///                          [--judge provider/model,…] [--models <dir>] [--llama-server <path>] [--greedy]
///     SpeechTextEvaluation --self-check <fixtures.json>
///
/// The fixtures are text: AI Rewrite's input is a transcript, so no audio is needed. A
/// *variant* is a way of turning a fixture into requests and a reply into text; `current`
/// is exactly what the app sends today — the built-in presets (never the user's),
/// `buildSystemPrompt` / `buildEditSystemPrompt`, `userMessage`, `parse` and
/// `polishedReply` with the fixture's Dictionary — through the client
/// `LLMConfiguration.makeChatClient(model:apiKey:)` builds, with each model's catalogue
/// switches unless `--reasoning-effort` says otherwise. Later variants (#109, #110) are new
/// cases of `Variant`, judged by the same checks.
///
/// Engines are `groq/<id>`, `anthropic/<id>`, `openai/<id>` and `local/<id>`; the default
/// is the six agreed for #114. Cloud keys come from the environment only
/// (`GROQ_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`); an engine without one is a
/// `no key` row. Each cloud engine has `--concurrency` requests in flight (4 unless given),
/// a vendor's engines one after another, the vendors and this Mac side by side; a local
/// model runs one request at a time and needs `--models`, the folder of its GGUF file. The
/// judges grade once the engines are done, side by side, `--concurrency` requests each.
///
/// `--judge` asks other models — none, one or several — to grade every reply (off unless
/// given). Each judge's family is recorded beside each candidate's, since a judge tends to
/// favour its own. `--recheck … --judge …` grades the replies of an earlier run without
/// asking for new ones.
///
/// `--self-check` runs the checks on each fixture's hand-written `examples` and asks no
/// model: a check that fails a good reply, or passes a bad one, is found before a run.
///
/// Writes `rewrite-results.json` and `rewrite-summary.md` into a new folder under
/// `--runs` — outside the repository: a run may hold real dictations.
enum RewriteEvaluation {

    // MARK: - What a run is made of

    static let defaultEngines = [
        "groq/openai/gpt-oss-120b", "groq/openai/gpt-oss-20b",
        "anthropic/claude-sonnet-5-5", "anthropic/claude-haiku-5-5",
        "openai/gpt-6-luna", "local/gemma-4-12b-it-qat-q4_0",
    ]
    static let llamaBuild = "b11696"
    static let contextLength = 8192
    /// The reply's own budget on this Mac; `ChatTemplates.reasoningAllowance` comes on top for Harmony.
    static let maxTokens = 1024

    struct Engine: Hashable, Sendable {
        var provider: LLMProviderType
        var id: String
        var spec: String { "\(provider.rawValue)/\(id)" }

        /// `groq/openai/gpt-oss-120b`, `local/<id>`, or a bare local id (the old form).
        init?(_ spec: String) {
            let parts = spec.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let provider = LLMProviderType(rawValue: parts[0]) {
                self.provider = provider; id = parts[1]
            } else if localChatModel(id: spec) != nil {
                provider = .local; id = spec
            } else {
                return nil
            }
        }

        var name: String {
            switch provider {
            case .local: localChatModel(id: id)?.displayName ?? id
            // Groq serves other makers' models, so its name goes first.
            case .groq: "Groq \(chatModel(provider: provider, id: id).displayName)"
            case .anthropic, .openai: chatModel(provider: provider, id: id).displayName
            }
        }

        /// Who made the model, which is what a judge may be partial to.
        var family: String {
            switch provider {
            case .anthropic: return "anthropic"
            case .openai: return "openai"
            case .groq: return id.contains("gpt-oss") ? "openai" : id.split(separator: "/").first.map(String.init) ?? "groq"
            case .local:
                switch localChatModel(id: id)?.family {
                case .harmony: return "openai"
                case .gemma4: return "google"
                case .qwen: return "qwen"
                case nil: return "local"
                }
            }
        }

        var keyVariable: String? {
            switch provider {
            case .groq: "GROQ_API_KEY"
            case .anthropic: "ANTHROPIC_API_KEY"
            case .openai: "OPENAI_API_KEY"
            case .local: nil
            }
        }
    }

    enum Variant: String, Codable, CaseIterable, Sendable {
        /// What the app sends today: one request, the routing prompt with every preset.
        case current
    }

    /// One request a variant made.
    struct Call: Codable, Sendable {
        var engine: String
        var inputTokens: Int?
        var cachedInputTokens: Int?
        var outputTokens: Int?
        /// The answered attempt alone, without the waits before it.
        var seconds: Double
        var cost: Double?
        /// Attempts refused by a rate limit or lost to the network before this one.
        var retries: Int?
        // On this Mac only.
        var promptSeconds: Double?
        var generationSeconds: Double?
        var finished: Bool?
    }

    struct JudgeVerdict: Codable, Sendable {
        var judge: String
        var sameFamily: Bool
        var score: Int?
        var followedRequest: Bool?
        var faithful: Bool?
        var issues: String?
        var error: String?
        var cost: Double?
    }

    struct Row: Codable, Sendable {
        var fixture: String
        var engine: String
        var variant: String
        var attempt: Int
        var status: String          // ok / failed / cut off / error / no key / not installed
        var reply: String?
        /// What the model wrote, before the app's parser — to see a marker it got wrong.
        var raw: String?
        /// On this Mac: everything generated, special tokens included.
        var generated: String?
        var mode: String?
        /// The marker's name as written, before it was matched to a preset.
        var rawMode: String?
        var routed: Bool?
        var verdict: RewriteVerdict?
        var error: String?
        var calls: [Call] = []
        var totalSeconds: Double?
        /// One grade per judge. `judge` is the single grade of a run from before there
        /// could be several; it is still read.
        var judges: [JudgeVerdict]?
        var judge: JudgeVerdict?

        var grades: [JudgeVerdict] { judges ?? judge.map { [$0] } ?? [] }

        var ran: Bool { status != "not installed" && status != "no key" }
        /// The text checks passed. The mode is counted apart: it depends on the variant.
        var passed: Bool { status == "ok" && verdict?.passed == true }
        var markerless: Bool { status == "ok" && rawMode == nil }
        /// A marker was written but named no preset — usually an abbreviation.
        var abbreviated: Bool { status == "ok" && rawMode != nil && mode == nil }
        var cost: Double? { calls.isEmpty ? nil : calls.compactMap(\.cost).reduce(0, +) }
        var requestSeconds: Double? { calls.isEmpty ? nil : calls.map(\.seconds).reduce(0, +) }
        var inputTokens: Int? { calls.isEmpty ? nil : calls.compactMap(\.inputTokens).reduce(0, +) }
        var outputTokens: Int? { calls.isEmpty ? nil : calls.compactMap(\.outputTokens).reduce(0, +) }
    }

    struct EngineInfo: Codable, Sendable {
        var engine: String
        var name: String
        var family: String
        var loadSeconds: Double?
        var footprintAfterLoadMB: Double?
        var footprintPeakMB: Double?
        var fileBytes: Int64?
        var templateCheck: String?
    }

    struct Report: Codable, Sendable {
        var date: Date
        var machine: String
        var variant: String
        var reasoningEffort: String
        var judge: String?
        var judgeList: [String]?
        var systemPromptCharacters: Int
        var editSystemPromptCharacters: Int
        var llamaBuild: String
        var sampling: LlamaSampling
        var contextLength: Int
        var engines: [EngineInfo]
        var rows: [Row]
        /// The runs whose replies this report rechecked, when it was made by `--recheck`.
        var rechecked: [String]?
    }

    /// Everything a request needs, the same for every engine of a run.
    struct Setup: Sendable {
        var variant: Variant
        var presets: [PromptPreset]
        var system: String
        var editSystem: String
        var repeats: Int
        /// nil: the catalogue's switch. `.some(nil)`: send none.
        var reasoningEffort: String??
        var judges: [Engine]
        /// Requests in flight at once to each cloud engine, and to each judge.
        var concurrency: Int = 4
        var keys: [String: String]

        var presetNames: [String] { presets.map(\.name) }
        func key(for engine: Engine) -> String {
            engine.keyVariable.flatMap { keys[$0] }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func model(for engine: Engine) -> ChatModelDescriptor {
            let model = chatModel(provider: engine.provider, id: engine.id)
            guard let effort = reasoningEffort else { return model }
            return model.withReasoningEffort(effort)
        }
    }

    // MARK: - Run

    @MainActor
    static func run(_ arguments: ArraySlice<String>) async throws {
        var arguments = arguments
        var fixturesURL: URL?, runs: URL?, models: URL?, llamaServer: URL?
        var engineSpecs = defaultEngines, fixtureFilter: [String] = []
        var repeats = 1
        var concurrency = 4
        var sampling = LlamaSampling.rewrite
        var variant = Variant.current
        var effortArgument = "default"
        var judgeSpecs: [String] = []
        func value(_ flag: String) throws -> String {
            guard let value = arguments.popFirst() else { throw SpeechTextEvaluation.UsageError("\(flag) needs a value") }
            return value
        }
        while let argument = arguments.popFirst() {
            switch argument {
            case "--rewrite": fixturesURL = URL(fileURLWithPath: try value(argument))
            case "--runs": runs = URL(fileURLWithPath: try value(argument))
            case "--models": models = URL(fileURLWithPath: try value(argument))
            case "--engines": engineSpecs = try value(argument).split(separator: ",").map(String.init)
            case "--fixtures": fixtureFilter = try value(argument).split(separator: ",").map(String.init)
            case "--repeat": repeats = max(1, Int(try value(argument)) ?? 1)
            case "--concurrency": concurrency = max(1, Int(try value(argument)) ?? 4)
            case "--llama-server": llamaServer = URL(fileURLWithPath: try value(argument))
            case "--greedy": sampling.temperature = 0
            case "--variant":
                let name = try value(argument)
                guard let chosen = Variant(rawValue: name) else {
                    throw SpeechTextEvaluation.UsageError("unknown variant \(name) — \(Variant.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                variant = chosen
            case "--reasoning-effort": effortArgument = try value(argument)
            case "--judge": judgeSpecs = try value(argument).split(separator: ",").map(String.init)
            default: throw SpeechTextEvaluation.UsageError("unknown argument \(argument)")
            }
        }
        guard let fixturesURL, let runs else { throw SpeechTextEvaluation.UsageError("--rewrite and --runs are required") }
        let engines = try engineSpecs.map { spec in
            guard let engine = Engine(spec) else { throw SpeechTextEvaluation.UsageError("unknown engine \(spec)") }
            return engine
        }
        let judges = try parseJudges(judgeSpecs)
        let fixtures = try loadFixtures(fixturesURL).filter { fixtureFilter.isEmpty || fixtureFilter.contains($0.id) }
        let folder = runs.appendingPathComponent(runFolderName(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let presets = PromptPresetStore.builtInDefaults
        let effort: String?? = switch effortArgument {
        case "default": nil
        case "omit": .some(nil)
        default: .some(effortArgument)
        }
        let environment = ProcessInfo.processInfo.environment
        let setup = Setup(
            variant: variant, presets: presets,
            system: TextRefinementService.buildSystemPrompt(presets: presets, defaultPresetID: nil),
            editSystem: TextRefinementService.buildEditSystemPrompt(presets: presets),
            repeats: repeats, reasoningEffort: effort, judges: judges, concurrency: concurrency,
            keys: environment.filter { $0.key.hasSuffix("_API_KEY") })

        let report = Report(date: Date(), machine: machineDescription(), variant: variant.rawValue,
                            reasoningEffort: effortArgument, judge: nil, judgeList: judges.map(\.spec),
                            systemPromptCharacters: setup.system.count, editSystemPromptCharacters: setup.editSystem.count,
                            llamaBuild: llamaBuild, sampling: sampling, contextLength: contextLength,
                            engines: [], rows: [])
        let sink = ReportSink(report: report, fixtures: fixtures, folder: folder)

        // Each cloud vendor's engines one at a time — a vendor's rate limit is per account —
        // and the vendors, and this Mac, side by side.
        let cloud = Dictionary(grouping: engines.filter { $0.provider != .local }, by: \.provider)
        let local = engines.filter { $0.provider == .local }
        async let cloudDone: Void = withTaskGroup(of: Void.self) { group in
            for (_, vendorEngines) in cloud {
                group.addTask {
                    for engine in vendorEngines {
                        await runCloud(engine, fixtures: fixtures, setup: setup, sink: sink)
                    }
                }
            }
        }
        for engine in local {
            try await runLocal(engine, fixtures: fixtures, setup: setup, sampling: sampling,
                               models: models, llamaServer: llamaServer, sink: sink)
        }
        await cloudDone
        if !judges.isEmpty {
            let byID = Dictionary(fixtures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            await sink.replaceRows(await gradeRows(await sink.rows, fixtures: byID, setup: setup))
        }
        try await sink.save()
        print(folder.appendingPathComponent("rewrite-summary.md").path)
    }

    static func parseJudges(_ specs: [String]) throws -> [Engine] {
        try specs.map { spec in
            guard let engine = Engine(spec), engine.provider != .local else {
                throw SpeechTextEvaluation.UsageError("--judge takes cloud models: \(spec)")
            }
            return engine
        }
    }

    static func loadFixtures(_ url: URL) throws -> [RewriteFixture] {
        try JSONDecoder().decode([RewriteFixture].self, from: Data(contentsOf: url))
    }

    // MARK: - Cloud

    static func runCloud(_ engine: Engine, fixtures: [RewriteFixture], setup: Setup, sink: ReportSink) async {
        await sink.add(EngineInfo(engine: engine.spec, name: engine.name, family: engine.family))
        let key = setup.key(for: engine)
        let model = setup.model(for: engine)
        let jobs = fixtures.flatMap { fixture in (1...setup.repeats).map { (fixture, $0) } }
        await forEach(jobs, concurrency: setup.concurrency) { job in
            let (fixture, attempt) = job
            var row = Row(fixture: fixture.id, engine: engine.spec, variant: setup.variant.rawValue,
                          attempt: attempt, status: "no key")
            if !key.isEmpty {
                let start = Date()
                row = await outcome(fixture, engine: engine, attempt: attempt, setup: setup) { system, user in
                    let (reply, seconds, retries) = try await withRetries {
                        try await LLMConfiguration.makeChatClient(model: model, apiKey: key).complete(system: system, user: user)
                    }
                    var call = Call(engine: engine.spec, inputTokens: reply.usage?.inputTokens,
                                    cachedInputTokens: reply.usage?.cachedInputTokens,
                                    outputTokens: reply.usage?.outputTokens, seconds: seconds,
                                    cost: reply.usage.flatMap { cost(of: $0, model: model) })
                    call.retries = retries > 0 ? retries : nil
                    return Completion(reply: reply.text, generated: nil, call: call)
                }
                row.totalSeconds = Date().timeIntervalSince(start)
            }
            print(line(row))
            await sink.add(row)
        }
    }

    /// `body` for every item, at most `concurrency` at once.
    static func forEach<T: Sendable>(_ items: [T], concurrency: Int, _ body: @escaping @Sendable (T) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = items[...]
            for _ in 0..<max(1, concurrency) {
                guard let item = pending.popFirst() else { break }
                group.addTask { await body(item) }
            }
            while await group.next() != nil {
                guard let item = pending.popFirst() else { continue }
                group.addTask { await body(item) }
            }
        }
    }

    /// A dropped connection, a server error or a rate limit is not the model's answer:
    /// asked again after a wait. A refusal or a rejected request is. Returns the seconds the
    /// answered attempt took — the waits are the account's limit, not the model's speed —
    /// and how many attempts came before it.
    static func withRetries<T: Sendable>(_ request: @Sendable () async throws -> T) async throws
        -> (value: T, seconds: Double, retries: Int) {
        var waits: [UInt64] = [5, 20, 40, 60]
        var retries = 0
        while true {
            let sent = Date()
            do {
                let value = try await request()
                return (value, Date().timeIntervalSince(sent), retries)
            } catch {
                let retryable: Bool = switch error {
                // A 429 is a rate limit to wait out — unless the account has no credit left
                // or has spent its day (OpenAI's `insufficient_quota`, Groq's tokens per
                // day), which no wait of a minute changes.
                case LLMError.httpError(let status, let body):
                    (status == 429 && !isOutOfCredit(body)) || status >= 500
                case is URLError: true
                default: false
                }
                guard retryable, !waits.isEmpty else { throw error }
                retries += 1
                try await Task.sleep(nanoseconds: waits.removeFirst() * 1_000_000_000)
            }
        }
    }

    static func isOutOfCredit(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return ["insufficient_quota", "no credits", "credit balance is too low", "exceeded your current quota",
                "tokens per day", "requests per day"]
            .contains { lowered.contains($0) }
    }

    static func cost(of usage: ChatUsage, model: ChatModelDescriptor) -> Double? {
        switch model.price {
        case .free: 0
        case .listed(let rates): rates.cost(usage)
        case .notPriced: nil
        }
    }

    // MARK: - This Mac

    @MainActor
    static func runLocal(_ engine: Engine, fixtures: [RewriteFixture], setup: Setup, sampling: LlamaSampling,
                         models: URL?, llamaServer: URL?, sink: ReportSink) async throws {
        var info = EngineInfo(engine: engine.spec, name: engine.name, family: engine.family)
        func notInstalled(_ why: String) async {
            info.templateCheck = why
            await sink.add(info)
            for fixture in fixtures {
                await sink.add(Row(fixture: fixture.id, engine: engine.spec, variant: setup.variant.rawValue,
                                   attempt: 1, status: "not installed"))
            }
            print("\(engine.spec): \(why)")
        }
        guard let model = localChatModel(id: engine.id) else { return await notInstalled("not in the catalogue") }
        guard let models else { return await notInstalled("not installed (no --models)") }
        // The folder of GGUF files, or the app's own Models folder (`llm/<id>/<file>`).
        let file = [models.appendingPathComponent(model.file),
                    models.appendingPathComponent("llm/\(model.id)/\(model.file)")]
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? models.appendingPathComponent(model.file)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64,
              size == model.downloadBytes else {
            return await notInstalled("not installed (\(file.path))")
        }
        info.fileBytes = size
        print("loading \(model.displayName)…")
        let runtime = LocalLlamaRuntime()
        info.loadSeconds = try await runtime.load(path: file.path, family: model.family, contextLength: contextLength)
        info.footprintAfterLoadMB = megabytes(processFootprintBytes())
        if let llamaServer {
            info.templateCheck = await templateCheck(model: model, file: file, server: llamaServer, runtime: runtime,
                                                    system: setup.system, fixtures: fixtures)
            print("template check \(engine.spec): \(info.templateCheck ?? "—")")
        }
        var peak = processFootprintBytes()
        for fixture in fixtures {
            for attempt in 1...setup.repeats {
                let start = Date()
                var row = await outcome(fixture, engine: engine, attempt: attempt, setup: setup) { system, user in
                    let completion = try await runtime.complete(system: system, user: user, maxTokens: maxTokens, sampling: sampling)
                    let call = Call(engine: engine.spec, inputTokens: completion.promptTokens,
                                    cachedInputTokens: completion.cachedPromptTokens, outputTokens: completion.outputTokens,
                                    seconds: completion.promptSeconds + completion.generationSeconds, cost: 0,
                                    promptSeconds: completion.promptSeconds, generationSeconds: completion.generationSeconds,
                                    finished: completion.finished)
                    return Completion(reply: completion.reply, generated: completion.generated, call: call)
                }
                row.totalSeconds = Date().timeIntervalSince(start)
                if row.status == "ok", row.calls.contains(where: { $0.finished == false }) { row.status = "cut off" }
                peak = max(peak, processFootprintBytes())
                info.footprintPeakMB = megabytes(peak)
                print(line(row))
                await sink.add(row)
            }
        }
        await sink.add(info)
        await runtime.unload()
    }

    // MARK: - One fixture

    /// What one request returned, before the app read it.
    struct Completion: Sendable {
        var reply: String
        var generated: String?
        var call: Call
    }

    /// The fixture through `setup.variant`: its requests sent with `complete`, the reply read
    /// as the app reads it and held to the checks.
    static func outcome(_ fixture: RewriteFixture, engine: Engine, attempt: Int, setup: Setup,
                        complete: @Sendable (String, String) async throws -> Completion) async -> Row {
        var row = Row(fixture: fixture.id, engine: engine.spec, variant: setup.variant.rawValue,
                      attempt: attempt, status: "ok")
        do {
            switch setup.variant {
            case .current:
                let (system, user) = messages(fixture, setup: setup)
                let completion = try await complete(system, user)
                row.calls = [completion.call]
                row.raw = completion.reply
                row.generated = completion.generated
                let names = setup.presetNames + (fixture.isEdit
                    ? [TextRefinementService.editDefaultModeName, TextRefinementService.editCustomModeName] : [])
                let read = RewriteChecks.read(completion.reply, fixture: fixture, presetNames: names)
                row.reply = read.text
                row.mode = read.mode
                row.rawMode = read.rawMode
                var verdict = RewriteChecks.check(fixture, text: read.text, raw: completion.reply)
                if let generated = completion.generated, RewriteChecks.leaksReasoning(completion.reply)
                    || (read.text.isEmpty && RewriteChecks.leaksReasoning(generated)) {
                    verdict.reasoningLeak = true
                }
                row.verdict = verdict
            }
            row.routed = RewriteChecks.modeMatches(fixture, variant: setup.variant.rawValue, mode: row.mode)
            if row.reply?.isEmpty != false, fixture.allowsEmpty != true { row.status = "failed" }
        } catch LLMError.cutOff {
            row.status = "cut off"
        } catch {
            row.status = "error"
            row.error = error.localizedDescription
        }
        return row
    }

    /// The system prompt and user message `TextRefinementService` would send.
    static func messages(_ fixture: RewriteFixture, setup: Setup) -> (String, String) {
        let context = fixture.context.map {
            FocusContext(appName: $0.appName, bundleID: $0.bundleID, windowTitle: $0.windowTitle, fieldLabel: $0.fieldLabel)
        }
        let vocabulary = Vocabulary.promptBlock((fixture.vocabulary ?? []).map { VocabularyEntry(term: $0) })
        if fixture.isEdit {
            return (setup.editSystem, TextRefinementService.editUserMessage(
                selection: fixture.selection ?? "", instruction: fixture.instruction, context: context, vocabulary: vocabulary))
        }
        return (setup.system, TextRefinementService.userMessage(transcript: fixture.transcript ?? "", context: context,
                                                                vocabulary: vocabulary))
    }

    // MARK: - Judge

    static let judgeSystem = """
        You grade the output of a dictation app's AI rewrite. The user dictated <transcript> — \
        raw speech-to-text: an instruction, the content, or both — at a cursor in the app or \
        field <context> names, and the app pasted <output> there. For an edit, \
        <selected_text> is text the user selected and <instruction> what they asked of it.

        A good output does what the transcript asks — format, language, length, tone — and \
        nothing else; keeps every fact, name, number and link; invents nothing; reads as \
        finished text for that place, with no preamble or commentary; and fixes recognition \
        errors and fillers. In a code editor, terminal or a prompt field for an AI, an \
        instruction is written down as the user's request, not carried out.

        Reply with JSON only: {"score": 1-5, "followed_request": true|false, "faithful": \
        true|false, "issues": "one short sentence, empty if none"}. 5: a careful editor would \
        paste it unchanged. 3: usable after a small fix. 1: wrong or harmful. Write the \
        issues in English.
        """

    /// Every judge's grade of every answered row, after the engines are done: a grade waits
    /// on nobody's reply, so the judges run side by side, `concurrency` requests each at a
    /// time. A judge given again grades only the replies it has no grade for; the others'
    /// grades are kept.
    static func gradeRows(_ rows: [Row], fixtures: [String: RewriteFixture], setup: Setup) async -> [Row] {
        guard !setup.judges.isEmpty else { return rows }
        let replace = Set(setup.judges.map(\.spec))
        // A reply a judge already graded keeps its grade: given again, a judge grades only
        // what it has not, or what it failed to.
        let jobs = rows.indices.filter { rows[$0].status == "ok" && rows[$0].reply != nil && fixtures[rows[$0].fixture] != nil }
            .flatMap { index in
                setup.judges.indices.filter { judge in
                    !rows[index].grades.contains { $0.judge == setup.judges[judge].spec && $0.score != nil }
                }.map { (index, $0) }
            }
        let grades = GradeBox()
        print("grading \(jobs.count / setup.judges.count) replies with \(setup.judges.count) judge(s)…")
        await forEach(jobs, concurrency: setup.concurrency * setup.judges.count) { job in
            let (index, judgeIndex) = job
            let row = rows[index]
            guard let fixture = fixtures[row.fixture], let reply = row.reply, let candidate = Engine(row.engine) else { return }
            let verdict = await grade(reply, fixture: fixture, candidate: candidate, by: setup.judges[judgeIndex], setup: setup)
            await grades.set(verdict, row: index, judge: judgeIndex)
        }
        let graded = await grades.all
        return rows.enumerated().map { index, row in
            guard let new = graded[index] else { return row }
            var row = row
            let regraded = Set(new.keys.map { setup.judges[$0].spec }).intersection(replace)
            row.judges = row.grades.filter { !regraded.contains($0.judge) } + new.sorted { $0.key < $1.key }.map(\.value)
            row.judge = nil
            return row
        }
    }

    static func grade(_ reply: String, fixture: RewriteFixture, candidate: Engine, by judge: Engine,
                      setup: Setup) async -> JudgeVerdict {
        var verdict = JudgeVerdict(judge: judge.spec, sameFamily: judge.family == candidate.family)
        let key = setup.key(for: judge)
        guard !key.isEmpty else {
            verdict.error = "no key"; return verdict
        }
        var blocks: [String] = []
        if let context = fixture.context {
            let focus = FocusContext(appName: context.appName, bundleID: context.bundleID,
                                     windowTitle: context.windowTitle, fieldLabel: context.fieldLabel)
            if !focus.isEmpty { blocks.append(focus.promptBlock) }
        }
        if fixture.isEdit {
            blocks.append("<selected_text>\n\(fixture.selection ?? "")\n</selected_text>")
            if let instruction = fixture.instruction { blocks.append("<instruction>\n\(instruction)\n</instruction>") }
        } else {
            blocks.append("<transcript>\n\(fixture.transcript ?? "")\n</transcript>")
        }
        blocks.append("<output>\n\(reply)\n</output>")
        let model = chatModel(provider: judge.provider, id: judge.id)
        let user = blocks.joined(separator: "\n\n")
        do {
            let answer = try await withRetries {
                try await LLMConfiguration.makeChatClient(model: model, apiKey: key).complete(system: judgeSystem, user: user)
            }.value
            struct Grade: Decodable {
                var score: Int?
                var followed_request: Bool?
                var faithful: Bool?
                var issues: String?
            }
            let text = answer.text
            guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"),
                  let grade = try? JSONDecoder().decode(Grade.self, from: Data(text[open...close].utf8)) else {
                verdict.error = "unreadable grade"; return verdict
            }
            verdict.score = grade.score
            verdict.followedRequest = grade.followed_request
            verdict.faithful = grade.faithful
            verdict.issues = grade.issues?.isEmpty == true ? nil : grade.issues
            // The judge's cost is the run's, not the candidate's: kept on the verdict.
            verdict.cost = answer.usage.flatMap { cost(of: $0, model: model) }
        } catch {
            verdict.error = error.localizedDescription
        }
        return verdict
    }

    // MARK: - Recheck

    /// Judges the replies of earlier runs again with today's checks and fixtures, asking no
    /// model: a check corrected after a run need not cost a second one. Runs given later
    /// replace the rows of the engine and fixture they hold and add the rest, so a run of new
    /// fixtures, or of one engine again, joins a fuller one.
    ///
    ///     SpeechTextEvaluation --recheck <fixtures.json> --runs <dir> [--judge provider/model,…] <results.json> […]
    ///
    /// With `--judge`, those judges grade the stored replies too — a judge given again only the
    /// replies it has no grade for.
    @MainActor
    static func recheck(_ arguments: ArraySlice<String>) async throws {
        var arguments = arguments
        var fixturesURL: URL?, runs: URL?, sources: [URL] = [], judgeSpecs: [String] = []
        while let argument = arguments.popFirst() {
            switch argument {
            case "--recheck", "--runs", "--judge":
                guard let value = arguments.popFirst() else { throw SpeechTextEvaluation.UsageError("\(argument) needs a value") }
                switch argument {
                case "--runs": runs = URL(fileURLWithPath: value)
                case "--judge": judgeSpecs = value.split(separator: ",").map(String.init)
                default: fixturesURL = URL(fileURLWithPath: value)
                }
            default: sources.append(URL(fileURLWithPath: argument))
            }
        }
        let judges = try parseJudges(judgeSpecs)
        guard let fixturesURL, let runs, !sources.isEmpty else {
            throw SpeechTextEvaluation.UsageError("--recheck <fixtures> --runs <dir> [--judge provider/model,…] <results.json>…")
        }
        let fixtures = try loadFixtures(fixturesURL)
        let byID = Dictionary(fixtures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var merged: Report?
        for source in sources {
            let report = try decoder.decode(Report.self, from: Data(contentsOf: source))
            guard var into = merged else { merged = report; continue }
            // By engine and fixture: a run of new fixtures adds to a run of old ones, and a
            // rerun of one engine replaces only what it ran.
            let ran = Set(report.rows.map { "\($0.engine)\u{1F}\($0.fixture)" })
            let engines = Set(report.engines.map(\.engine))
            into.rows.removeAll { ran.contains("\($0.engine)\u{1F}\($0.fixture)") }
            into.engines.removeAll { engines.contains($0.engine) }
            into.rows += report.rows
            into.engines += report.engines
            merged = into
        }
        guard var report = merged else { return }
        report.rechecked = sources.map(\.path)
        // A fixture removed since the run takes its rows with it.
        report.rows.removeAll { byID[$0.fixture] == nil }
        let names = PromptPresetStore.builtInDefaults.map(\.name)
        report.rows = report.rows.map { row in
            guard row.status == "ok" || row.status == "failed", let raw = row.raw, let fixture = byID[row.fixture] else { return row }
            var row = row
            let read = RewriteChecks.read(raw, fixture: fixture, presetNames: names + (fixture.isEdit
                ? [TextRefinementService.editDefaultModeName, TextRefinementService.editCustomModeName] : []))
            row.reply = read.text
            row.mode = read.mode
            row.rawMode = read.rawMode
            var verdict = RewriteChecks.check(fixture, text: read.text, raw: raw)
            if let generated = row.generated, read.text.isEmpty, RewriteChecks.leaksReasoning(generated) { verdict.reasoningLeak = true }
            row.verdict = verdict
            row.routed = RewriteChecks.modeMatches(fixture, variant: row.variant, mode: read.mode)
            row.status = read.text.isEmpty && fixture.allowsEmpty != true ? "failed" : "ok"
            return row
        }
        if !judges.isEmpty {
            report.judgeList = Array(Set((report.judgeList ?? report.judge.map { [$0] } ?? []) + judges.map(\.spec))).sorted()
            report.judge = nil
            let setup = Setup(variant: .current, presets: PromptPresetStore.builtInDefaults, system: "", editSystem: "",
                              repeats: 1, reasoningEffort: nil, judges: judges,
                              keys: ProcessInfo.processInfo.environment.filter { $0.key.hasSuffix("_API_KEY") })
            report.rows = await gradeRows(report.rows, fixtures: byID, setup: setup)
        }
        let folder = runs.appendingPathComponent(runFolderName() + "-recheck", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: folder.appendingPathComponent("rewrite-results.json"), options: .atomic)
        try summary(report, fixtures: fixtures).write(to: folder.appendingPathComponent("rewrite-summary.md"),
                                                      atomically: true, encoding: .utf8)
        print(folder.appendingPathComponent("rewrite-summary.md").path)
    }

    // MARK: - Self-check

    /// Runs the text checks on every fixture's examples, and holds each fixture's routing
    /// expectations to what a router can answer. Returns the number of examples the checks
    /// got wrong plus the number of fixtures with an expectation no answer could meet.
    static func selfCheck(_ url: URL) throws -> Int {
        var wrong = 0, total = 0, problems = 0
        for fixture in try loadFixtures(url) {
            for problem in routingProblems(fixture) {
                problems += 1
                print("✗ \(fixture.id): \(problem)")
            }
            for example in fixture.examples ?? [] {
                total += 1
                let verdict = RewriteChecks.check(fixture, text: example.reply, raw: example.reply)
                guard verdict.passed != example.passes else { continue }
                wrong += 1
                print("✗ \(fixture.id): expected \(example.passes ? "pass" : "fail"), got "
                      + (verdict.passed ? "pass" : verdict.failures.joined(separator: "; "))
                      + (example.note.map { " — \($0)" } ?? ""))
            }
        }
        print("self-check: \(total - wrong)/\(total) examples judged as expected, \(problems) routing expectations no router could meet")
        return wrong + problems
    }

    /// The three modes of the 2026-11 spec, which `variantModes["2026-11"]` names.
    static let modes202611 = ["Clean-up", "Message", "Document"]
    static let formats = ["plain", "list", "markdown"]

    /// What in a fixture's routing expectations no router could answer: a mode that is
    /// neither one of the 2026-11 three nor one of the fixture's own, a language that is
    /// not a code, a format that is not one of the three. An edit is not routed at all.
    static func routingProblems(_ fixture: RewriteFixture) -> [String] {
        var problems: [String] = []
        if fixture.isEdit {
            if fixture.askedLanguage != nil || fixture.format != nil || fixture.variantModes?["2026-11"] != nil {
                problems.append("an edit is not routed, so it takes no askedLanguage, format or 2026-11 modes")
            }
            return problems
        }
        let own = (fixture.presets ?? []).map(\.name)
        if let modes = fixture.variantModes?["2026-11"] {
            if modes.isEmpty { problems.append("no 2026-11 mode") }
            for mode in modes where !(modes202611 + own).contains(mode) {
                problems.append("2026-11 mode \(mode) is neither a built-in nor one of the fixture's presets")
            }
        }
        if let language = fixture.askedLanguage,
           language.count != 2 || !language.allSatisfy({ $0.isASCII && $0.isLowercase }) {
            problems.append("askedLanguage \(language) is not an ISO 639-1 code")
        }
        if let format = fixture.format {
            if format.isEmpty { problems.append("an empty format list") }
            for name in format where !formats.contains(name) { problems.append("unknown format \(name)") }
        }
        return problems
    }

    // MARK: - Template check

    /// Renders the first dictation fixture's messages with the model's own Jinja template in
    /// llama-server and compares string and token IDs with ours.
    @MainActor
    static func templateCheck(model: LocalChatModel, file: URL, server: URL, runtime: LocalLlamaRuntime,
                              system: String, fixtures: [RewriteFixture]) async -> String {
        let port = 18_765
        let process = Process()
        process.executableURL = server
        process.arguments = ["-m", file.path, "--jinja", "--port", "\(port)", "-c", "2048", "-ngl", "0",
                             "--no-warmup", "--log-disable"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "server did not start: \(error.localizedDescription)" }
        defer { process.terminate(); process.waitUntilExit() }

        guard let fixture = fixtures.first(where: { !$0.isEdit }) ?? fixtures.first else { return "no fixture" }
        let context = fixture.context.map {
            FocusContext(appName: $0.appName, bundleID: $0.bundleID, windowTitle: $0.windowTitle, fieldLabel: $0.fieldLabel)
        }
        let user = TextRefinementService.userMessage(transcript: fixture.transcript ?? "", context: context)
        var kwargs: [String: Any] = [:]
        switch model.family {
        case .qwen: kwargs["enable_thinking"] = false
        case .gemma4: kwargs["enable_thinking"] = false
        case .harmony: kwargs["reasoning_effort"] = "low"
        }
        let body: [String: Any] = [
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "chat_template_kwargs": kwargs,
        ]
        var theirs: String?
        for _ in 0..<240 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/apply-template")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let prompt = json["prompt"] as? String else { continue }
            theirs = prompt
            break
        }
        guard let theirs else { return "server gave no template" }
        // llama-server leaves the BOS out of the text and adds it when it tokenizes, where
        // the model asks for one (Gemma); ours writes it into the text. So the strings may
        // differ by exactly that, and the tokens are what must be equal.
        let ours = ChatTemplates.render(model.family, system: system, user: user)
        let oursTokens = (try? await runtime.tokenize(ours)) ?? []
        let theirsTokens = (try? await runtime.tokenize(theirs, addSpecial: true)) ?? []
        if !oursTokens.isEmpty, oursTokens == theirsTokens {
            return "identical tokens (\(oursTokens.count))" + (ours == theirs ? "" : ", BOS written as text")
        }
        let common = zip(ours, theirs).prefix { $0 == $1 }.count
        let oursTail = String(ours.dropFirst(common).prefix(80))
        let theirsTail = String(theirs.dropFirst(common).prefix(80))
        return "DIFFERENT at character \(common) — ours: \(oursTail.debugDescription), template: \(theirsTail.debugDescription); "
            + "tokens \(oursTokens.count) vs \(theirsTokens.count)"
    }

    // MARK: - Summary

    static func summary(_ report: Report, fixtures: [RewriteFixture]) -> String {
        var out = "# AI Rewrite — variant `\(report.variant)`\n\n"
        out += "\(ISO8601DateFormatter().string(from: report.date)) · \(report.machine) · reasoning effort: \(report.reasoningEffort)"
        out += " · system prompt \(report.systemPromptCharacters) characters (edit \(report.editSystemPromptCharacters))"
        if let sources = report.rechecked { out += " · rechecked from \(sources.count) run(s)" }
        let judgeNames = report.judgeList ?? report.judge.map { [$0] } ?? []
        if !judgeNames.isEmpty {
            let spent = report.rows.flatMap(\.grades).compactMap(\.cost).reduce(0, +)
            out += " · judges \(judgeNames.joined(separator: ", ")) (\(String(format: "$%.2f", spent)))"
        }
        out += "\n\nOn this Mac: llama.cpp \(report.llamaBuild), context \(report.contextLength), top-k \(report.sampling.topK), "
        out += "temperature \(report.sampling.temperature), top-p \(report.sampling.topP), seed \(report.sampling.seed).\n\n"
        out += "*Text* is the checks that hold whatever the prompt; *routed* is the mode this variant's fixtures expect. "
        out += "Cost is at list prices, per 1,000 dictations like these. *Text ✓* is split clean / dirty: fixtures written "
        out += "as a person types, and as a speech engine really writes. *Judge* is each judge's mean grade out of 10, in whole points, on its "
        out += "own scale; † marks a judge of the engine's own family.\n\n"
        out += "| Engine | text ✓ | clean / dirty | routed | marker abbreviated / none | failures | errors | median s | p90 s | tokens in / out | $ per 1k | judge | load s | template |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for engine in report.engines.sorted(by: { $0.engine < $1.engine }) {
            let rows = report.rows.filter { $0.engine == engine.engine }
            let ran = rows.filter(\.ran)
            guard !ran.isEmpty else {
                out += "| \(engine.name) | — | | | | | | | | | | | | \(engine.templateCheck ?? rows.first?.status ?? "") |\n"
                continue
            }
            let answered = ran.filter { $0.status == "ok" || $0.status == "failed" }
            // The requests' own time: a rate limit's waits are the account's, not the model's.
            let times = answered.compactMap(\.requestSeconds).sorted()
            let retried = ran.filter { $0.calls.contains { ($0.retries ?? 0) > 0 } }.count
            func pct(_ p: Double) -> String {
                guard !times.isEmpty else { return "—" }
                return String(format: "%.1f", times[min(times.count - 1, Int(Double(times.count - 1) * p))])
            }
            func mean(_ values: [Int]) -> String { values.isEmpty ? "—" : "\(values.reduce(0, +) / values.count)" }
            var kinds: [String: Int] = [:]
            for row in ran { for finding in row.verdict?.findings ?? [] { kinds[finding.kind, default: 0] += 1 } }
            let failures = kinds.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }.joined(separator: " · ")
            let costs = answered.compactMap(\.cost)
            let perThousand = costs.isEmpty ? "—" : String(format: "%.2f", costs.reduce(0, +) / Double(costs.count) * 1000)
            let routable = ran.filter { $0.routed != nil }
            // Per judge: judges keep different scales, so a mean across them would rank an
            // engine by who happened to grade it.
            let perJudge = Dictionary(grouping: ran.flatMap(\.grades), by: \.judge).sorted { $0.key < $1.key }
                .compactMap { name, grades -> String? in
                    let scores = grades.compactMap(\.score)
                    guard !scores.isEmpty else { return nil }
                    let short = name.split(separator: "/").last.map(String.init) ?? name
                    // Out of 10, in whole points: a judge's mean moves by a few hundredths
                    // from run to run, and a finer figure would rank engines by that noise.
                    let mean = Double(scores.reduce(0, +)) / Double(scores.count)
                    return "\(short) \(Int((mean * 2).rounded()))" + (grades.contains(where: \.sameFamily) ? "†" : "")
                }
            let judgeText = perJudge.isEmpty ? "—" : perJudge.joined(separator: " · ")
            let dirtyIDs = Set(fixtures.filter(\.isDirty).map(\.id))
            let clean = ran.filter { !dirtyIDs.contains($0.fixture) }, dirty = ran.filter { dirtyIDs.contains($0.fixture) }
            out += "| \(engine.name) | \(ran.filter(\.passed).count)/\(ran.count)"
            out += " | \(clean.filter(\.passed).count)/\(clean.count) / \(dirty.filter(\.passed).count)/\(dirty.count)"
            out += " | \(routable.filter { $0.routed == true }.count)/\(routable.count)"
            out += " | \(ran.filter(\.abbreviated).count) / \(ran.filter(\.markerless).count)"
            out += " | \(failures.isEmpty ? "—" : failures)"
            out += " | \(ran.filter { $0.status != "ok" }.count)\(retried > 0 ? " (\(retried) retried)" : "")"
            out += " | \(pct(0.5)) | \(pct(0.9))"
            out += " | \(mean(answered.compactMap(\.inputTokens))) / \(mean(answered.compactMap(\.outputTokens)))"
            out += " | \(perThousand) | \(judgeText)"
            out += " | \(engine.loadSeconds.map { String(format: "%.1f", $0) } ?? "—") | \(engine.templateCheck ?? "—") |\n"
        }
        out += "\n## Per fixture\n"
        for fixture in fixtures {
            out += "\n### \(fixture.id)\(fixture.isDirty ? " (dirty)" : "")\n\n\(fixture.note ?? "")  \n"
            out += "Expected mode: \(fixture.expectedModes(for: report.variant)?.joined(separator: " / ") ?? "—")\n\n"
            for row in report.rows where row.fixture == fixture.id && row.ran {
                var flags = row.verdict?.failures ?? []
                if row.routed == false { flags.append("mode \(row.mode ?? "")") }
                if row.abbreviated { flags.append("marker “\(row.rawMode ?? "")” names no preset") }
                if row.markerless { flags.append("no marker (\(markerLine(row.raw)))") }
                if row.status != "ok" { flags.append(row.status + (row.error.map { ": \($0)" } ?? "")) }
                out += "- **\(row.engine)**\(report.rows.contains { $0.fixture == fixture.id && $0.attempt > 1 } ? " #\(row.attempt)" : "")"
                out += " \(row.requestSeconds.map { String(format: "%.1f s", $0) } ?? "") "
                out += flags.isEmpty ? "✓" : "❌ " + flags.joined(separator: "; ")
                for grade in row.grades {
                    let name = grade.judge.split(separator: "/").last.map(String.init) ?? grade.judge
                    out += grade.score.map { " · \(name) \($0)/5" } ?? " · \(name): \(grade.error ?? "—")"
                    if let issues = grade.issues { out += " — \(issues)" }
                }
                out += "\n\n  > " + (row.reply ?? "").replacingOccurrences(of: "\n", with: "\n  > ") + "\n"
            }
        }
        return out
    }

    static func line(_ row: Row) -> String {
        let mark = row.passed ? "✓" : "❌ \(row.status == "ok" ? row.verdict?.failures.joined(separator: "; ") ?? "" : row.status)"
        return "\(row.fixture) · \(row.engine) #\(row.attempt): \(mark)"
            + (row.mode.map { " [\($0)]" } ?? "") + (row.totalSeconds.map { String(format: " %.1fs", $0) } ?? "")
            + (row.error.map { " — \($0)" } ?? "")
    }

    /// The first line of the raw reply, which is where the marker should have been.
    static func markerLine(_ raw: String?) -> String {
        let first = (raw ?? "").split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return first.count > 60 ? String(first.prefix(60)) + "…" : first
    }

    static func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    static func runFolderName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date()) + "_rewrite"
    }

    static func machineDescription() -> String {
        let capabilities = SystemCapabilities.current()
        return "\(capabilities.chipName), \(capabilities.memoryGB) GB"
    }
}

/// The run's report, written out after every row: rows arrive from every vendor at once.
actor ReportSink {
    private var report: RewriteEvaluation.Report
    private let fixtures: [RewriteFixture]
    private let folder: URL

    init(report: RewriteEvaluation.Report, fixtures: [RewriteFixture], folder: URL) {
        self.report = report
        self.fixtures = fixtures
        self.folder = folder
    }

    func add(_ row: RewriteEvaluation.Row) {
        report.rows.append(row)
        try? save()
    }

    var rows: [RewriteEvaluation.Row] { report.rows }

    func replaceRows(_ rows: [RewriteEvaluation.Row]) {
        report.rows = rows
        try? save()
    }

    func add(_ info: RewriteEvaluation.EngineInfo) {
        report.engines.removeAll { $0.engine == info.engine }
        report.engines.append(info)
        try? save()
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: folder.appendingPathComponent("rewrite-results.json"), options: .atomic)
        try RewriteEvaluation.summary(report, fixtures: fixtures)
            .write(to: folder.appendingPathComponent("rewrite-summary.md"), atomically: true, encoding: .utf8)
    }
}

/// The judges' grades as they come in, by row and judge.
actor GradeBox {
    private(set) var all: [Int: [Int: RewriteEvaluation.JudgeVerdict]] = [:]

    func set(_ verdict: RewriteEvaluation.JudgeVerdict, row: Int, judge: Int) {
        all[row, default: [:]][judge] = verdict
    }
}
