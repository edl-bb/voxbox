import Foundation
import FoundationModels

/// Runs eval cases through the app's real cleanup pipeline on Apple
/// Intelligence and scores them against reference outputs. Usage:
/// scripts/cleanup-eval.sh --help
@main
struct CleanupEval {
    struct Options {
        var casePaths: [String] = []
        var promptSets: [String] = ["v2", "v3"]
        var levels: [EvalLevel]? = nil
        var context = "on"
        var repeats = 1
        var filters: [String] = []
        var tags: [String] = []
        var outDir: String? = nil
        var label = ""
        var stepDown = true
        var warmup = true
        var freshSessions = false
        var probeSessions: Int? = nil
        var selfTest = false
        var repairs = true
        var budgetOverrides: [String: GuardrailBudget] = [:]
        var promptFile: String? = nil
        var promptOverrides: PromptOverrides? = nil
        var scaffold = true
        var prerender = true
        var autoEdit = false

        var nonDefaultSwitches: [String] {
            var switches: [String] = []
            if casePaths != ["evals/cleanup/cases.json"] {
                switches += casePaths.map { "--cases \($0)" }
            }
            if promptSets != ["v2", "v3"] { switches.append("--prompts " + promptSets.joined(separator: ",")) }
            if let levels { switches.append("--levels " + levels.map(\.rawValue).joined(separator: ",")) }
            if context != "on" { switches.append("--context \(context)") }
            if repeats != 1 { switches.append("--repeat \(repeats)") }
            if !filters.isEmpty { switches.append("--filter " + filters.joined(separator: ",")) }
            if !tags.isEmpty { switches.append("--tag " + tags.joined(separator: ",")) }
            if !label.isEmpty { switches.append("--label \(label)") }
            if let outDir { switches.append("--out \(outDir)") }
            if !stepDown { switches.append("--single-rung") }
            if !repairs { switches.append("--no-repairs") }
            if !warmup { switches.append("--no-warmup") }
            if freshSessions { switches.append("--fresh-sessions") }
            if let probeSessions { switches.append("--probe-sessions \(probeSessions)") }
            if selfTest { switches.append("--self-test") }
            for level in budgetOverrides.keys.sorted() {
                let budget = budgetOverrides[level]!
                switches.append("--budget \(level)=\(budget.maxCostRatio),\(budget.minFreeEdits),\(budget.minRetention)")
            }
            if let promptFile { switches.append("--prompt-file \(promptFile)") }
            if !scaffold { switches.append("--no-scaffold") }
            if !prerender { switches.append("--no-prerender") }
            if autoEdit { switches.append("--autoedit") }
            return switches
        }
    }

    struct PromptOverrides: Decodable {
        var light: String?
        var polish: String?
        var style: String?
        var role: String?
        var outputOnly: String?
        var repeatSuffixes: RepeatSuffixes?

        struct RepeatSuffixes: Decodable {
            var light: String?
            var polish: String?
        }
    }

    static let usage = """
        cleanup-eval [options]
          --cases PATH        case file; repeatable (default evals/cleanup/cases.json)
          --prompts A,B       prompt sets: v2, v3, legacy (default v2,v3)
          --levels L,…        basic, light, polish (default: every level a case has a reference for)
          --context MODE      on | off | both: speaker context for cases that name one (default on)
          --repeat N          run each case N times (latency spread)
          --filter S,…        only case ids containing one of these
          --tag T,…           only cases with one of these tags
          --label NAME        suffix for the run directory
          --out DIR           run directory (default evals/cleanup/runs/<stamp>-<label>)
          --single-rung       no step-down (default: step down like a real take)
          --no-repairs        skip the self-correction pass before the model
          --budget LEVEL=COST,FREE,RETENTION
                              override basic|light|polish guardrail budget; repeatable
                              COST >= 0, FREE integer >= 0, RETENTION in 0...1
          --prompt-file PATH  JSON overrides: light, polish, style, role, outputOnly,
                              repeatSuffixes (light and polish); replaces present fields
          --no-scaffold       keep spoken scaffolding
          --no-prerender      skip number rendering before the model
          --autoedit          enable deterministic Auto Edit before the model
          --no-warmup         skip the untimed warm-up call per prompt set and level
          --fresh-sessions    new LanguageModelSession per request (no pooling)
          --probe-sessions N  measure session reuse vs fresh sessions over N takes, then exit
          --self-test         model-free checks of the deterministic pieces, then exit
        """

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        func value() -> String {
            i += 1
            guard i < args.count else { fail("missing value for \(args[i - 1])") }
            return args[i]
        }
        func list(_ s: String) -> [String] { s.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
        while i < args.count {
            switch args[i] {
            case "--cases": o.casePaths.append(value())
            case "--prompts": o.promptSets = list(value())
            case "--levels":
                o.levels = list(value()).map { name in
                    guard let level = EvalLevel(rawValue: name) else { fail("unknown level \(name)") }
                    return level
                }
            case "--context": o.context = value()
            case "--repeat": o.repeats = Int(value()) ?? 1
            case "--filter": o.filters = list(value())
            case "--tag": o.tags = list(value())
            case "--label": o.label = value()
            case "--out": o.outDir = value()
            case "--single-rung": o.stepDown = false
            case "--no-repairs": o.repairs = false
            case "--budget":
                let spec = value()
                let parts = spec.split(separator: "=", omittingEmptySubsequences: false)
                guard parts.count == 2, let level = EvalLevel(rawValue: String(parts[0])) else {
                    fail("invalid budget \(spec); expected basic|light|polish=COST,FREE,RETENTION")
                }
                let values = parts[1].split(separator: ",", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                guard values.count == 3,
                    let cost = Double(values[0]), cost.isFinite, cost >= 0,
                    let free = Int(values[1]), free >= 0,
                    let retention = Double(values[2]), retention.isFinite, (0...1).contains(retention)
                else { fail("invalid budget \(spec); COST >= 0, FREE integer >= 0, RETENTION in 0...1") }
                o.budgetOverrides[level.rawValue] = GuardrailBudget(maxCostRatio: cost, minFreeEdits: free, minRetention: retention)
            case "--prompt-file": o.promptFile = value()
            case "--no-scaffold": o.scaffold = false
            case "--no-prerender": o.prerender = false
            case "--autoedit": o.autoEdit = true
            case "--no-warmup": o.warmup = false
            case "--fresh-sessions": o.freshSessions = true
            case "--self-test": o.selfTest = true
            case "--probe-sessions": o.probeSessions = Int(value()) ?? 20
            case "-h", "--help": print(usage); exit(0)
            default: fail("unknown option \(args[i])\n\(usage)")
            }
            i += 1
        }
        if o.casePaths.isEmpty { o.casePaths = ["evals/cleanup/cases.json"] }
        if let path = o.promptFile {
            do {
                o.promptOverrides = try JSONDecoder().decode(PromptOverrides.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            } catch {
                fail("could not read prompt file \(path): \(error)")
            }
        }
        return o
    }

    static func promptSet(named name: String, options: Options = Options()) -> CleanupPromptSet {
        var set: CleanupPromptSet
        switch name {
        case "v2": set = .v2
        case "v3": set = .v3
        case "legacy": set = .legacy
        case "compiled": set = .compiled
        default: fail("unknown prompt set \(name)")
        }
        for level in EvalLevel.allCases {
            if let budget = options.budgetOverrides[level.rawValue] { set.budgets[level.intensity] = budget }
        }
        if let overrides = options.promptOverrides {
            if let light = overrides.light { set.light = light }
            if let polish = overrides.polish { set.polish = polish }
            if let style = overrides.style { set.style = style }
            if let role = overrides.role { set.role = role }
            if let outputOnly = overrides.outputOnly { set.outputOnly = outputOnly }
            if let light = overrides.repeatSuffixes?.light { set.repeatSuffixes[.lightCleanup] = light }
            if let polish = overrides.repeatSuffixes?.polish { set.repeatSuffixes[.polish] = polish }
        }
        if !options.scaffold { set.dropsSpokenScaffolding = false }
        return set
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }

    @MainActor
    static func main() async {
        let options = parse(Array(CommandLine.arguments.dropFirst()))
        if options.selfTest {
            exit(await SelfTest.run())
        }
        guard case .available = SystemLanguageModel.default.availability else {
            fail("Apple Intelligence is not available: \(SystemLanguageModel.default.availability)")
        }
        if let n = options.probeSessions {
            await SessionProbe.run(count: n)
            return
        }
        CleanupSessionPool.reusesSessions = !options.freshSessions

        var jobs: [(suite: EvalSuite, evalCase: EvalCase)] = []
        for path in options.casePaths {
            do {
                let suite = try JSONDecoder().decode(EvalSuite.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                for c in suite.cases {
                    if !options.filters.isEmpty, !options.filters.contains(where: { c.id.contains($0) }) { continue }
                    if !options.tags.isEmpty, !options.tags.contains(where: { (c.tags ?? []).contains($0) }) { continue }
                    jobs.append((suite, c))
                }
            } catch {
                fail("could not read \(path): \(error)")
            }
        }
        guard !jobs.isEmpty else { fail("no cases selected") }

        let contextModes: [Bool] = switch options.context {
        case "off": [false]
        case "both": [false, true]
        default: [true]
        }

        let pipeline = TranscriptCleanupPipeline()
        let started = Date()
        var rows: [EvalRow] = []
        let heartbeat = MainActorHeartbeat()
        heartbeat.start()

        if options.warmup {
            for name in options.promptSets {
                for level in options.levels ?? EvalLevel.allCases {
                    _ = await pipeline.clean(
                        raw: "So this is just a quick warm up take to load the model before we time anything.",
                        plan: plan(level: level, language: "en-AU", markdown: false, promptSet: promptSet(named: name, options: options), speaker: nil, stepDown: false, repairs: options.repairs, prerender: options.prerender, autoEdit: options.autoEdit))
                }
            }
        }

        for job in jobs {
            let c = job.evalCase
            let levels = (options.levels ?? EvalLevel.allCases).filter { c.expected[$0.rawValue] != nil }
            let context = c.context.flatMap { job.suite.contexts?[$0] }
            let modes = context == nil ? [false] : contextModes
            let language = c.language ?? job.suite.language ?? "en-AU"
            for _ in 0..<options.repeats {
                for level in levels {
                    for contextOn in modes {
                        for name in options.promptSets {
                            let set = promptSet(named: name, options: options)
                            let speaker = contextOn ? context?.speaker : nil
                            let p = plan(level: level, language: language, markdown: c.markdown ?? false, promptSet: set, speaker: speaker, stepDown: options.stepDown, repairs: options.repairs, prerender: options.prerender, autoEdit: options.autoEdit)
                            heartbeat.reset()
                            let outcome = await pipeline.clean(raw: c.raw, plan: p)
                            let mainGap = heartbeat.maxGapMs
                            let expected = c.expected[level.rawValue]!
                            let instructions = set.instructionStages(
                                for: level.intensity, includeMarkdown: p.includeMarkdown, language: language, speaker: speaker
                            ).joined(separator: "\n\n") + "\n" + set.userPrompt(for: "", intensity: level.intensity)
                            let scored = EvalScorer.score(
                                evalCase: c, level: level, contextOn: contextOn, output: outcome.output,
                                expected: expected, instructions: instructions)
                            let row = EvalRow(
                                caseId: c.id, tags: c.tags ?? [], promptSet: name, level: level, contextOn: contextOn,
                                raw: c.raw, expected: expected, output: outcome.output,
                                landed: outcome.landed?.displayName ?? (outcome.skippedReason != nil ? "instant" : "raw"),
                                verdicts: outcome.attempts.map { TranscriptCleanupPipeline.describe($0.verdict) },
                                attemptOutputs: outcome.attempts.map(\.rawOutput),
                                error: outcome.error, totalMs: outcome.totalDurationMs,
                                modelMs: outcome.attempts.reduce(0) { $0 + $1.durationMs },
                                attempts: outcome.attempts.count,
                                wordErrorRate: EvalScorer.wordErrorRate(output: outcome.output, expected: expected),
                                charSimilarity: EvalScorer.charSimilarity(output: outcome.output, expected: expected),
                                exact: EvalScorer.collapse(outcome.output) == EvalScorer.collapse(expected),
                                checks: scored.checks, fixesWanted: scored.fixesWanted, fixesMade: scored.fixesMade,
                                contractionsWanted: scored.contractionsWanted, contractionsKept: scored.contractionsKept,
                                mainThreadGapMs: mainGap)
                            rows.append(row)
                            let failed = row.checks.filter { !$0.passed }.map(\.name)
                            print(String(
                                format: "%-34@ %-6@ %-3@ ctx=%@ WER %.2f  %5d ms  main gap %4d ms  %@%@",
                                c.id as NSString, level.rawValue as NSString, name as NSString, (contextOn ? "on " : "off") as NSString,
                                row.wordErrorRate, row.totalMs, row.mainThreadGapMs, (failed.isEmpty ? "pass" : "FAIL " + failed.joined(separator: ",")) as NSString,
                                (row.landed == level.intensity.displayName ? "" : "  → landed \(row.landed)") as NSString))
                        }
                    }
                }
            }
        }

        let report = EvalReport(rows: rows, options: options, started: started)
        print("\n" + report.summaryMarkdown())

        let stamp = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "")
        let dir = options.outDir ?? "evals/cleanup/runs/\(stamp)\(options.label.isEmpty ? "" : "-" + options.label)"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: dir + "/rows.json"))
            try report.fullMarkdown().write(toFile: dir + "/report.md", atomically: true, encoding: .utf8)
            print("Wrote \(dir)/rows.json and report.md")
        } catch {
            fail("could not write results: \(error)")
        }
    }

    static func plan(
        level: EvalLevel, language: String, markdown: Bool, promptSet: CleanupPromptSet, speaker: SpeakerContext?,
        stepDown: Bool, repairs: Bool = true, prerender: Bool = true, autoEdit: Bool = false
    ) -> CleanupPlan {
        var plan = CleanupPlan(
            option: level.option,
            includeMarkdown: markdown,
            language: language,
            autoEditEnabled: autoEdit,
            applyDictionary: false,
            smartTrailingPunctuation: true,
            minimumWordCount: TranscriptFormatterService.minimumWordCount,
            allowStepDown: stepDown,
            isPreview: true,
            promptSet: promptSet,
            speaker: speaker)
        plan.resolveSelfCorrections = repairs
        plan.renderNumbersBeforeModel = prerender
        return plan
    }
}

// MARK: - Report

struct EvalReport {
    var rows: [EvalRow]
    var options: CleanupEval.Options
    var started: Date

    struct Group: Hashable, Comparable {
        var promptSet: String
        var level: EvalLevel
        var contextOn: Bool

        static func < (a: Group, b: Group) -> Bool {
            let order = EvalLevel.allCases
            if a.level != b.level { return order.firstIndex(of: a.level)! < order.firstIndex(of: b.level)! }
            if a.contextOn != b.contextOn { return !a.contextOn }
            return a.promptSet < b.promptSet
        }
    }

    static let checkNames = ["keep", "drop", "words", "forbid", "ending", "questions", "sentences", "person", "markdown", "echo", "answer"]

    func percentile(_ values: [Int], _ p: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    func summaryMarkdown() -> String {
        let groups = Dictionary(grouping: rows) { Group(promptSet: $0.promptSet, level: $0.level, contextOn: $0.contextOn) }
        var out = "Non-default switches:\n"
        let switches = options.nonDefaultSwitches
        out += switches.isEmpty ? "- none\n\n" : switches.map { "- " + $0 }.joined(separator: "\n") + "\n\n"
        out += "| Prompts | Level | Context | n | Pass | WER | Char sim | Exact | Fixes | Contractions | Stepped down | Errors | p50 ms | p90 ms | max ms | max main gap ms |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for key in groups.keys.sorted() {
            let g = groups[key]!
            let n = Double(g.count)
            let pass = Double(g.filter(\.passed).count) / n
            let wer = g.map(\.wordErrorRate).reduce(0, +) / n
            let sim = g.map(\.charSimilarity).reduce(0, +) / n
            let exact = Double(g.filter(\.exact).count) / n
            let fixesWanted = g.map(\.fixesWanted).reduce(0, +)
            let fixesMade = g.map(\.fixesMade).reduce(0, +)
            let cWanted = g.map(\.contractionsWanted).reduce(0, +)
            let cKept = g.map(\.contractionsKept).reduce(0, +)
            let stepped = g.filter { $0.landed != key.level.intensity.displayName && $0.landed != "instant" }.count
            let errors = g.filter { $0.error != nil }.count
            let times = g.filter { $0.landed != "instant" }.map(\.totalMs)
            out += String(
                format: "| %@ | %@ | %@ | %d | %.0f%% | %.3f | %.3f | %.0f%% | %d/%d | %d/%d | %d | %d | %d | %d | %d | %d |\n",
                key.promptSet, key.level.rawValue, key.contextOn ? "on" : "off", g.count, pass * 100, wer, sim, exact * 100,
                fixesMade, fixesWanted, cKept, cWanted, stepped, errors,
                percentile(times, 0.5), percentile(times, 0.9), times.max() ?? 0, g.map(\.mainThreadGapMs).max() ?? 0)
        }
        out += "\nFailed checks (rows failing each check):\n\n| Prompts | Level | Context | " + Self.checkNames.joined(separator: " | ") + " |\n"
        out += "|---|---|---|" + Self.checkNames.map { _ in "---" }.joined(separator: "|") + "|\n"
        for key in groups.keys.sorted() {
            let g = groups[key]!
            let counts = Self.checkNames.map { name in g.filter { $0.checks.contains { $0.name == name && !$0.passed } }.count }
            out += "| \(key.promptSet) | \(key.level.rawValue) | \(key.contextOn ? "on" : "off") | "
                + counts.map(String.init).joined(separator: " | ") + " |\n"
        }
        return out
    }

    func fullMarkdown() -> String {
        var out = "# Cleanup eval run\n\n"
        out += "- Started: \(ISO8601DateFormatter().string(from: started))\n"
        out += "- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "- Cases: \(options.casePaths.joined(separator: ", "))\n"
        out += "- Prompt sets: \(options.promptSets.joined(separator: ", ")) · step-down \(options.stepDown ? "on" : "off") · repeats \(options.repeats)\n\n"
        out += summaryMarkdown()

        out += "\n## Per case (WER, ✓ = all checks pass)\n\n| Case | Level | Ctx | " + options.promptSets.joined(separator: " | ") + " |\n"
        out += "|---|---|---|" + options.promptSets.map { _ in "---" }.joined(separator: "|") + "|\n"
        let byCase = Dictionary(grouping: rows) { "\($0.caseId)|\($0.level.rawValue)|\($0.contextOn)" }
        for key in byCase.keys.sorted() {
            let g = byCase[key]!
            let first = g[0]
            let cells = options.promptSets.map { name -> String in
                let r = g.filter { $0.promptSet == name }
                guard !r.isEmpty else { return "–" }
                let wer = r.map(\.wordErrorRate).reduce(0, +) / Double(r.count)
                return String(format: "%.2f %@", wer, r.allSatisfy(\.passed) ? "✓" : "✗")
            }
            out += "| \(first.caseId) | \(first.level.rawValue) | \(first.contextOn ? "on" : "off") | " + cells.joined(separator: " | ") + " |\n"
        }

        out += "\n## Failures and outputs\n"
        for row in rows.sorted(by: { ($0.caseId, $0.level.rawValue, $0.promptSet) < ($1.caseId, $1.level.rawValue, $1.promptSet) }) {
            let failed = row.checks.filter { !$0.passed }
            out += "\n### \(row.caseId) · \(row.level.rawValue) · \(row.promptSet) · context \(row.contextOn ? "on" : "off")\n\n"
            out += String(format: "WER %.2f · char sim %.2f · %d ms · landed %@", row.wordErrorRate, row.charSimilarity, row.totalMs, row.landed)
            if !row.verdicts.isEmpty { out += " · " + row.verdicts.joined(separator: " → ") }
            if let error = row.error { out += " · error: \(error)" }
            out += "\n\n"
            if !failed.isEmpty {
                out += failed.map { "- ✗ \($0.name)" + ($0.detail.map { ": \($0)" } ?? "") }.joined(separator: "\n") + "\n\n"
            }
            if row.fixesWanted > 0 { out += "- fixes \(row.fixesMade)/\(row.fixesWanted)\n\n" }
            out += "Output:\n\n> " + row.output.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n"
            out += "Expected:\n\n> " + row.expected.replacingOccurrences(of: "\n", with: "\n> ") + "\n"
        }
        return out
    }
}

/// Ticks on the main actor every 50 ms and records the longest gap, so a
/// row shows whether cleanup blocked the main thread (in the app that is a
/// frozen UI).
@MainActor
final class MainActorHeartbeat {
    private var last = Date()
    private(set) var maxGapMs = 0

    func start() {
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: 50_000_000)
                let now = Date()
                maxGapMs = max(maxGapMs, Int(now.timeIntervalSince(last) * 1000))
                last = now
            }
        }
    }

    func reset() {
        last = Date()
        maxGapMs = 0
    }
}
