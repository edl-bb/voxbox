import Foundation
import FoundationModels
import XCTest

@testable import voxbox

/// Ticket 09: score compiled Light cleanup and Polish on the macOS 27
/// system model and each catalog MLX model that has weights. Runs through
/// `TranscriptCleanupPreview` (the same pipeline a take uses).
///
/// T1 scorer tests do not need a model. The live matrix fails loudly when
/// Apple Intelligence is unavailable, and lists missing catalog weights as
/// env-blocked rather than `XCTSkip`.
final class CleanupEvalMacOS27Tests: XCTestCase {

    // MARK: - T1 scorer (no model)

    func testScorerCountsLeftoverFillersWithoutAModel() {
        XCTAssertEqual(
            CleanupEvalScorer.leftoverFillerCount(
                in: "Um so I think, uh, we should, you know, ship it, I mean basically tomorrow."),
            5,
            "um + uh + you know + I mean + basically")
        XCTAssertEqual(
            CleanupEvalScorer.leftoverFillerCount(in: "I think we should ship it tomorrow."),
            0)
        XCTAssertEqual(
            CleanupEvalScorer.leftoverFillerCount(in: "I like it, looks like this."),
            0,
            "content like is not a leftover filler")
    }

    func testScorerDetectsBrokenFreezeStringsWithoutAModel() {
        let fixture = CleanupEvalFixture.freezeStrings
        let broken = CleanupEvalScorer.freezeSurvival(
            input: fixture.text,
            output: "Email the recap to nobody and put the link in the tracker, the invoice is gone.")
        XCTAssertEqual(broken.email, .dropped)
        XCTAssertEqual(broken.url, .dropped)
        XCTAssertEqual(broken.number, .dropped)

        let kept = CleanupEvalScorer.freezeSurvival(
            input: fixture.text,
            output: "Email the recap to priya@voxbox.app and put the link https://notes.voxbox.app/q3 in the tracker, the invoice is 12,500.")
        XCTAssertEqual(kept.email, .survived)
        XCTAssertEqual(kept.url, .survived)
        XCTAssertEqual(kept.number, .survived)
    }

    func testScorerDetectsPreambleRefusalAndEmptyWithoutAModel() {
        XCTAssertTrue(CleanupEvalScorer.hadPreamble("Here is the cleaned text:\nHello Jack."))
        XCTAssertFalse(CleanupEvalScorer.hadPreamble("Hello Jack."))
        XCTAssertTrue(CleanupEvalScorer.isRefusal("Sorry, I can't help with that."))
        XCTAssertTrue(CleanupEvalScorer.isEmpty("   "))
        XCTAssertFalse(CleanupEvalScorer.isEmpty("Hello."))
    }

    func testScorerScoresAnAcceptedLightPass() {
        let fixture = CleanupEvalFixture.followUp
        let outcome = TranscriptCleanupOutcome(
            rawInput: fixture.text,
            modelInput: fixture.text,
            output: "Hi Jack, just following up on the thing we talked about yesterday. Can you send the updated deck to jules@testco.com by Thursday, and put the revised total, I think it was $12,500, into the tracker.",
            requested: .light,
            landed: .lightCleanup,
            attempts: [
                CleanupAttempt(
                    intensity: .lightCleanup,
                    engineName: "Apple Intelligence",
                    requestedEngineName: "Apple Intelligence",
                    rawOutput: "Hi Jack, just following up on the thing we talked about yesterday. Can you send the updated deck to jules@testco.com by Thursday, and put the revised total, I think it was $12,500, into the tracker.",
                    tidiedOutput: "Hi Jack, just following up on the thing we talked about yesterday. Can you send the updated deck to jules@testco.com by Thursday, and put the revised total, I think it was $12,500, into the tracker.",
                    evaluation: GuardrailEvaluation(
                        verdict: .accepted, costRatio: 0.1, retention: 0.9, cost: 2, inputTokens: 40),
                    verdict: .accepted,
                    casingAnomaly: false,
                    durationMs: 12)
            ],
            totalDurationMs: 12,
            skippedReason: nil)
        let row = CleanupEvalScorer.score(
            fixture: fixture, model: .appleIntelligence, option: .light, outcome: outcome, status: .ran)
        XCTAssertEqual(row.leftoverFillerCount, 0)
        XCTAssertFalse(row.guardrailVeto)
        XCTAssertEqual(row.freeze.email, .survived)
        XCTAssertEqual(row.freeze.url, .notPresent)
        XCTAssertEqual(
            row.freeze.number, .notPresent,
            "follow-up’s total is spoken words, so Guardrail freeze strings do not include a digit run")
        XCTAssertFalse(row.empty)
        XCTAssertFalse(row.preamble)
        XCTAssertFalse(row.refusal)
    }

    // MARK: - T2 live matrix

    @MainActor
    func testLiveEvalMatrixOnMacOS27() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VOXBOX_CLEANUP_EVAL"] == "1",
            "set VOXBOX_CLEANUP_EVAL=1 to re-run the live matrix; results live in docs/macos-27-custom-llm/eval-report.md")
        continueAfterFailure = true
        executionTimeAllowance = 1_800

        let apple = AppleIntelligenceCleanupEngine()
        if !apple.isAvailable {
            XCTFail(
                "env-block: Apple Intelligence is not available (\(String(describing: SystemLanguageModel.default.availability)))")
            return
        }

        let manager = PostProcessingModelManager.shared
        let previousSelection = manager.selectedVariant
        manager.refreshDownloadedModels()
        defer { manager.selectedVariant = previousSelection }

        var rows: [CleanupEvalRow] = []
        for model in CleanupEvalTarget.allCases {
            rows.append(contentsOf: await runTarget(model, manager: manager))
        }

        let json = try CleanupEvalReportJSON.encode(rows)
        print("===VOXBOX_EVAL_JSON_BEGIN===")
        print(json)
        print("===VOXBOX_EVAL_JSON_END===")
        add(XCTAttachment(string: json))

        let markdown = CleanupEvalMarkdown.render(rows: rows, appleAvailable: true)
        try writeEvalArtifacts(json: json, markdown: markdown)

        XCTAssertTrue(
            rows.contains { $0.model == .appleIntelligence && $0.status == .ran },
            "Apple Intelligence must produce live rows")
        XCTAssertTrue(
            rows.contains { $0.model == .llama1B && ($0.status == .ran || $0.status == .envBlocked) },
            "Llama 3.2 1B must be live or env-blocked with a weights-path reason")
        for blocked in [CleanupEvalTarget.qwen17B, .llama3B, .qwen4B] {
            XCTAssertTrue(
                rows.contains { $0.model == blocked && $0.status == .envBlocked },
                "\(blocked.catalogName) must be listed as env-blocked when weights are missing")
        }
    }

    func testCheckedInEvalReportExists() throws {
        let url = Self.evalReportURL
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "docs/macos-27-custom-llm/eval-report.md is missing")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("leftover filler"), "report must include leftover filler column")
        XCTAssertTrue(text.contains("Guardrail"), "report must include Guardrail column")
        XCTAssertTrue(text.contains("freeze"), "report must include freeze-string column")
        XCTAssertTrue(text.contains("Apple Intelligence"))
    }

    // MARK: - Live helpers

    @MainActor
    private func runTarget(
        _ target: CleanupEvalTarget,
        manager: PostProcessingModelManager
    ) async -> [CleanupEvalRow] {
        switch target {
        case .appleIntelligence:
            let model = target.catalogModel
            manager.selectedVariant = model.variant
            let pipeline = TranscriptCleanupPipeline()
            pipeline.selectedModel = { model }
            pipeline.engineProvider = { CleanupEngineFactory.engine(for: $0, manager: manager) }
            return await runFixtures(target: target, pipeline: pipeline)

        case .llama1B:
            let model = target.catalogModel
            let directory = PostProcessingModelManager.storageDir(for: model.variant)
            guard Self.hasMLXFiles(in: directory) else {
                return CleanupEvalFixture.all.map { fixture in
                    CleanupEvalRow.envBlocked(
                        fixture: fixture, model: target, option: .light,
                        reason: "weights missing at \(directory.path)")
                } + CleanupEvalFixture.all.map { fixture in
                    CleanupEvalRow.envBlocked(
                        fixture: fixture, model: target, option: .polish,
                        reason: "weights missing at \(directory.path)")
                }
            }
            manager.markDownloadedForTesting(model.variant)
            manager.selectedVariant = model.variant
            XCTAssertTrue(
                manager.isDownloaded(model.variant),
                "Llama 3.2 1B is on disk at \(directory.path) but manager.isDownloaded is false")
            let pipeline = TranscriptCleanupPipeline()
            pipeline.selectedModel = { model }
            pipeline.engineProvider = { CleanupEngineFactory.engine(for: $0, manager: manager) }
            return await runFixtures(target: target, pipeline: pipeline)

        case .qwen17B, .llama3B, .qwen4B:
            let directory = PostProcessingModelManager.storageDir(for: target.catalogModel.variant)
            let reason = Self.hasMLXFiles(in: directory)
                ? "not run: \(target.catalogName) is outside this eval’s downloaded set (weights at \(directory.path))"
                : "env-block: \(target.catalogName) weights missing at \(directory.path)"
            return envBlockedRows(target: target, reason: reason)
        }
    }

    private func envBlockedRows(target: CleanupEvalTarget, reason: String) -> [CleanupEvalRow] {
        CleanupEvalFixture.all.flatMap { fixture in
            [CleanupOption.light, .polish].map { option in
                CleanupEvalRow.envBlocked(fixture: fixture, model: target, option: option, reason: reason)
            }
        }
    }

    @MainActor
    private func runFixtures(
        target: CleanupEvalTarget,
        pipeline: TranscriptCleanupPipeline
    ) async -> [CleanupEvalRow] {
        var rows: [CleanupEvalRow] = []
        for fixture in CleanupEvalFixture.all {
            for option in [CleanupOption.light, .polish] {
                print("=== eval \(target.catalogName) · \(fixture.id) · \(option.displayName)")
                let outcome = await TranscriptCleanupPreview.preview(
                    text: fixture.text,
                    option: option,
                    includeMarkdown: false,
                    autoEdit: false,
                    allowStepDown: false,
                    promptSet: .compiled,
                    pipeline: pipeline)
                let row = CleanupEvalScorer.score(
                    fixture: fixture, model: target, option: option, outcome: outcome, status: .ran)
                print(
                    "    leftover=\(row.leftoverFillerCount.map(String.init) ?? "-") veto=\(row.guardrailVeto) "
                        + "freeze=\(row.freeze.summary) empty=\(row.empty) preamble=\(row.preamble) refusal=\(row.refusal) "
                        + "engine=\(row.engineName ?? "-") fallback=\(row.fellBack) \(row.durationMs)ms")
                print("    OUT: \(row.output)")
                if target == .llama1B {
                    XCTAssertFalse(
                        row.fellBack,
                        "Llama 3.2 1B fell back to \(row.engineName ?? "another engine"): \(row.error ?? "no error")")
                    XCTAssertEqual(
                        row.engineName, target.catalogName,
                        "Llama 3.2 1B live row must run on the catalog model: \(row.error ?? "no error")")
                }
                if target == .appleIntelligence {
                    XCTAssertEqual(
                        row.engineName, target.catalogName,
                        "Apple Intelligence live row used \(row.engineName ?? "nil"): \(row.error ?? "no error")")
                }
                rows.append(row)
            }
        }
        return rows
    }

    private func writeEvalArtifacts(json: String, markdown: String) throws {
        try FileManager.default.createDirectory(
            at: Self.evalRowsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try json.write(to: Self.evalRowsURL, atomically: true, encoding: .utf8)
            print("Wrote \(Self.evalRowsURL.path)")
        } catch {
            print("Could not write \(Self.evalRowsURL.path): \(error)")
        }
        // Do not clobber a curated report that already has the ticket Verdict.
        let existing = try? String(contentsOf: Self.evalReportURL, encoding: .utf8)
        let shouldWriteReport = existing == nil || existing?.contains("Pending live") == true
        if shouldWriteReport {
            do {
                try markdown.write(to: Self.evalReportURL, atomically: true, encoding: .utf8)
                print("Wrote \(Self.evalReportURL.path)")
            } catch {
                print("Could not write \(Self.evalReportURL.path): \(error)")
                let fallback = FileManager.default.temporaryDirectory
                    .appendingPathComponent("voxbox-eval-report.md")
                try markdown.write(to: fallback, atomically: true, encoding: .utf8)
                print("Wrote fallback report to \(fallback.path)")
            }
        } else {
            print("Left curated \(Self.evalReportURL.path) in place")
        }
    }

    static var evalReportURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/macos-27-custom-llm/eval-report.md")
    }

    static var evalRowsURL: URL {
        evalReportURL.deletingLastPathComponent().appendingPathComponent("eval-rows.json")
    }

    static func hasMLXFiles(in directory: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent("config.json").path),
            fm.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path),
            let contents = try? fm.contentsOfDirectory(atPath: directory.path)
        else { return false }
        return contents.contains { $0.hasSuffix(".safetensors") }
    }
}

// MARK: - Fixtures

struct CleanupEvalFixture: Equatable {
    var id: String
    var title: String
    var text: String

    static let followUp = CleanupEvalFixture(
        id: "follow-up", title: CleanupSampleTranscripts.followUp.title,
        text: CleanupSampleTranscripts.followUp.text)
    static let noteToSelf = CleanupEvalFixture(
        id: "note-to-self", title: CleanupSampleTranscripts.noteToSelf.title,
        text: CleanupSampleTranscripts.noteToSelf.text)
    static let teamUpdate = CleanupEvalFixture(
        id: "team-update", title: CleanupSampleTranscripts.teamUpdate.title,
        text: CleanupSampleTranscripts.teamUpdate.text)
    static let fillerHeavy = CleanupEvalFixture(
        id: "filler-heavy", title: "Filler-heavy spoken take",
        text: "Um uh so I I was, um, thinking we should, uh, uh, maybe ship it, you know, I mean, basically tomorrow, um, if that's, uh, okay.")
    static let freezeStrings = CleanupEvalFixture(
        id: "freeze-strings", title: "Freeze strings (email, URL, number)",
        text: "Um so email the recap to priya@voxbox.app and, uh, put the link https://notes.voxbox.app/q3 in the tracker, the invoice is 12,500.")
    static let shortTake = CleanupEvalFixture(
        id: "short-take", title: "Short take",
        text: "Um yeah call Sam.")

    static let all: [CleanupEvalFixture] = [
        .followUp, .noteToSelf, .teamUpdate, .fillerHeavy, .freezeStrings, .shortTake,
    ]
}

enum CleanupEvalTarget: String, CaseIterable, Codable {
    case appleIntelligence = "apple-intelligence"
    case llama1B = "mlx-llama-3.2-1b-instruct-4bit"
    case qwen17B = "mlx-qwen3-1.7b-4bit"
    case llama3B = "mlx-llama-3.2-3b-instruct-4bit"
    case qwen4B = "mlx-qwen3-4b-4bit"

    var catalogModel: PostProcessingModel {
        PostProcessingModel.catalog.first { $0.variant == rawValue }!
    }

    var catalogName: String { catalogModel.name }
}

enum CleanupEvalStatus: String, Codable {
    case ran
    case envBlocked = "env-blocked"
}

enum FreezeStatus: String, Codable {
    case survived
    case dropped
    case notPresent = "n/a"

    var mark: String {
        switch self {
        case .survived: return "✓"
        case .dropped: return "✗"
        case .notPresent: return "–"
        }
    }
}

struct FreezeSurvival: Equatable, Codable {
    var email: FreezeStatus
    var url: FreezeStatus
    var number: FreezeStatus

    var summary: String { "email \(email.mark) URL \(url.mark) number \(number.mark)" }
    var anyDropped: Bool { email == .dropped || url == .dropped || number == .dropped }
}

struct CleanupEvalRow: Codable {
    var fixture: String
    var model: CleanupEvalTarget
    var modelName: String
    var intensity: String
    var status: CleanupEvalStatus
    var envBlockReason: String?
    var leftoverFillerCount: Int?
    var leftoverFillersRaw: Int?
    var guardrailVeto: Bool
    var guardrailVerdict: String
    var steppedDown: Bool
    var freeze: FreezeSurvival
    var empty: Bool
    var preamble: Bool
    var refusal: Bool
    var landed: String?
    var engineName: String?
    var fellBack: Bool
    var durationMs: Int
    var cost: Double?
    var retention: Double?
    var error: String?
    var output: String
    var rawOutput: String
    var tidiedOutput: String

    static func envBlocked(
        fixture: CleanupEvalFixture, model: CleanupEvalTarget, option: CleanupOption, reason: String
    ) -> CleanupEvalRow {
        CleanupEvalRow(
            fixture: fixture.id, model: model, modelName: model.catalogName,
            intensity: option.displayName, status: .envBlocked, envBlockReason: reason,
            leftoverFillerCount: nil, leftoverFillersRaw: nil, guardrailVeto: false,
            guardrailVerdict: "env-blocked", steppedDown: false,
            freeze: FreezeSurvival(email: .notPresent, url: .notPresent, number: .notPresent),
            empty: false, preamble: false, refusal: false, landed: nil, engineName: nil,
            fellBack: false, durationMs: 0, cost: nil, retention: nil, error: reason,
            output: "", rawOutput: "", tidiedOutput: "")
    }
}

enum CleanupEvalScorer {
    static func leftoverFillerCount(in text: String, lexicon: FillerLexicon = .compiled) -> Int {
        let words = CleanupGuardrail.tokens(text)
        var count = 0
        var index = 0
        while index < words.count {
            var matched = false
            for phrase in lexicon.phrases where !phrase.isEmpty {
                if index + phrase.count <= words.count,
                    Array(words[index..<(index + phrase.count)]) == phrase
                {
                    count += 1
                    index += phrase.count
                    matched = true
                    break
                }
            }
            if matched { continue }
            if lexicon.pureTokens.contains(words[index]) || words[index] == "basically" {
                count += 1
            }
            index += 1
        }
        return count
    }

    static func freezeSurvival(input: String, output: String) -> FreezeSurvival {
        let required = CleanupGuardrail.protectedTokens(in: input)
        let emails = required.compactMap { if case .email(let s) = $0 { return s } else { return nil } }
        let urls = required.compactMap { if case .url(let s) = $0 { return s } else { return nil } }
        let numbers = required.compactMap { if case .number(let s) = $0 { return s } else { return nil } }
        let lowered = output.lowercased()
        let outputNumbers = Set(
            CleanupGuardrail.protectedTokens(in: output).compactMap {
                if case .number(let digits) = $0 { return digits } else { return nil }
            })
        return FreezeSurvival(
            email: status(required: emails, survived: emails.allSatisfy { lowered.contains($0.lowercased()) }),
            url: status(required: urls, survived: urls.allSatisfy { lowered.contains($0.lowercased()) }),
            number: status(required: numbers, survived: numbers.allSatisfy { outputNumbers.contains($0) }))
    }

    private static func status(required: [String], survived: Bool) -> FreezeStatus {
        if required.isEmpty { return .notPresent }
        return survived ? .survived : .dropped
    }

    static func hadPreamble(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return CleanupPostPass.stripModelPreamble(trimmed) != trimmed
    }

    static func isRefusal(_ text: String) -> Bool {
        CleanupPostPass.looksLikeRefusal(text)
    }

    static func isEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func score(
        fixture: CleanupEvalFixture,
        model: CleanupEvalTarget,
        option: CleanupOption,
        outcome: TranscriptCleanupOutcome,
        status: CleanupEvalStatus
    ) -> CleanupEvalRow {
        let attempt = outcome.attempts.first
        let scoredText = attempt?.tidiedOutput ?? outcome.output
        let freeze = freezeSurvival(input: fixture.text, output: scoredText)
        let verdict = attempt.map { TranscriptCleanupPipeline.describe($0.verdict) } ?? (outcome.skippedReason ?? "no attempt")
        return CleanupEvalRow(
            fixture: fixture.id, model: model, modelName: model.catalogName,
            intensity: option.displayName, status: status, envBlockReason: nil,
            leftoverFillerCount: leftoverFillerCount(in: scoredText),
            leftoverFillersRaw: leftoverFillerCount(in: attempt?.rawOutput ?? ""),
            guardrailVeto: outcome.guardrailTripped,
            guardrailVerdict: verdict,
            steppedDown: outcome.steppedDown,
            freeze: freeze,
            empty: isEmpty(scoredText),
            preamble: hadPreamble(attempt?.rawOutput ?? ""),
            refusal: (attempt?.verdict == .refusal) || (attempt?.verdict == .appleContentFilter)
                || isRefusal(scoredText),
            landed: outcome.landed?.displayName,
            engineName: attempt?.engineName ?? outcome.engineName,
            fellBack: outcome.fellBackToSystemModel,
            durationMs: outcome.totalDurationMs,
            cost: attempt?.evaluation?.cost,
            retention: attempt?.evaluation?.retention,
            error: outcome.error,
            output: outcome.output,
            rawOutput: attempt?.rawOutput ?? "",
            tidiedOutput: scoredText)
    }
}

enum CleanupEvalReportJSON {
    static func encode(_ rows: [CleanupEvalRow]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rows)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

enum CleanupEvalMarkdown {
    static func render(rows: [CleanupEvalRow], appleAvailable: Bool) -> String {
        var lines: [String] = []
        lines.append("# Cleanup eval — macOS 27")
        lines.append("")
        lines.append("Ticket 09. Live Preview through `TranscriptCleanupPreview` / `TranscriptCleanupPipeline` with compiled Light cleanup and Polish. Auto Edit off, markdown off, step-down off (Preview single rung).")
        lines.append("")
        lines.append("- **Host:** macOS \(operatingSystem)")
        lines.append("- **Apple Intelligence:** \(appleAvailable ? "available" : "unavailable")")
        lines.append("- **Compiled prompts:** `CleanupPromptSet.compiled` (no DEBUG overlay)")
        lines.append("- **Date:** \(isoDate)")
        lines.append("")
        lines.append("## Summary")
        lines.append("")
        lines.append("| Model | Intensity | Fixture | Leftover fillers | Guardrail veto / step-down | Freeze (email / URL / number) | Empty / preamble | Refusal | Status |")
        lines.append("|---|---|---|---|---|---|---|---|---|")
        for row in rows {
            let leftover = row.leftoverFillerCount.map(String.init) ?? "–"
            let veto = row.status == .envBlocked
                ? "–"
                : "\(row.guardrailVeto ? "veto" : "accepted")\(row.steppedDown ? ", step-down" : "")"
            let emptyPreamble: String
            if row.status == .envBlocked {
                emptyPreamble = "–"
            } else {
                emptyPreamble = "empty \(row.empty ? "yes" : "no") / preamble \(row.preamble ? "yes" : "no")"
            }
            let refusal = row.status == .envBlocked ? "–" : (row.refusal ? "yes" : "no")
            let status = row.status == .envBlocked ? "env-blocked" : "ran (\(row.durationMs) ms)"
            lines.append(
                "| \(row.modelName) | \(row.intensity) | \(row.fixture) | \(leftover) | \(veto) · \(row.guardrailVerdict) | \(row.freeze.summary) | \(emptyPreamble) | \(refusal) | \(status) |")
        }
        lines.append("")
        lines.append("## Outputs")
        lines.append("")
        for row in rows where row.status == .ran {
            lines.append("### \(row.modelName) · \(row.intensity) · \(row.fixture)")
            lines.append("")
            lines.append("- Engine: \(row.engineName ?? "–")\(row.fellBack ? " (fell back)" : "")")
            lines.append("- Landed: \(row.landed ?? "raw")")
            if let cost = row.cost, let retention = row.retention {
                lines.append(
                    "- Cost \(String(format: "%.1f", cost)) · retention \(String(format: "%.2f", retention))")
            }
            lines.append("")
            lines.append("```")
            lines.append(row.output)
            lines.append("```")
            lines.append("")
        }
        lines.append("## Env-blocked rows")
        lines.append("")
        let blocked = rows.filter { $0.status == .envBlocked }
        if blocked.isEmpty {
            lines.append("None.")
        } else {
            for reason in Set(blocked.compactMap(\.envBlockReason)).sorted() {
                lines.append("- \(reason)")
            }
        }
        lines.append("")
        lines.append("## Verdict")
        lines.append("")
        lines.append(verdict(from: rows))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func verdict(from rows: [CleanupEvalRow]) -> String {
        let live = rows.filter { $0.status == .ran }
        let appleLight = live.filter { $0.model == .appleIntelligence && $0.intensity == "Light cleanup" }
        let llamaLight = live.filter { $0.model == .llama1B && $0.intensity == "Light cleanup" }
        var flags: [String] = []

        func flagLight(_ label: String, _ subset: [CleanupEvalRow]) {
            let leftover = subset.filter { ($0.leftoverFillerCount ?? 0) > 0 && !$0.guardrailVeto }
            if !leftover.isEmpty {
                flags.append(
                    "\(label) Light cleanup left fillers on accepted passes: \(leftover.map(\.fixture).joined(separator: ", ")).")
            }
            let freeze = subset.filter { $0.freeze.anyDropped }
            for row in freeze {
                if row.guardrailVeto {
                    flags.append(
                        "\(label) \(row.intensity) dropped a freeze string on \(row.fixture); Guardrail vetoed (\(row.guardrailVerdict)).")
                } else {
                    flags.append(
                        "\(label) \(row.intensity) dropped a freeze string on \(row.fixture) and Guardrail accepted the pass — prompt change candidate.")
                }
            }
            let empty = subset.filter(\.empty)
            if !empty.isEmpty {
                flags.append("\(label) empty output on \(empty.map(\.fixture).joined(separator: ", ")).")
            }
            let refusal = subset.filter(\.refusal)
            if !refusal.isEmpty {
                flags.append("\(label) refusal on \(refusal.map(\.fixture).joined(separator: ", ")).")
            }
        }

        flagLight("Apple Intelligence", appleLight)
        flagLight("Llama 3.2 1B Instruct", llamaLight)
        for row in live.filter({ $0.intensity == "Polish" && $0.freeze.anyDropped && !$0.guardrailVeto }) {
            flags.append(
                "\(row.modelName) Polish dropped a freeze string on \(row.fixture) and Guardrail accepted — prompt change candidate.")
        }

        if flags.isEmpty {
            return "Keep compiled prompts. Live rows did not show leftover fillers on accepted Light cleanup, freeze-string breaks the Guardrail failed to veto, empty output, or refusals that the Guardrail cannot absorb."
        }
        return flags.joined(separator: "\n\n")
    }

    private static var operatingSystem: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static var isoDate: String {
        ISO8601DateFormatter().string(from: Date())
    }
}
