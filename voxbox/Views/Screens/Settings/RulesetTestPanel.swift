import SwiftUI

/// Pure helpers for the "Test this ruleset" panel: which History items are
/// offered, which text of an item is used, and how it is previewed.
nonisolated enum RulesetTestInput {
    static let historyLimit = 5

    /// Newest first, capped, skipping items with no usable text.
    static func recentHistoryCandidates(from items: [HistoryItem], limit: Int = historyLimit) -> [HistoryItem] {
        items
            .sorted { $0.date > $1.date }
            .filter { !text(for: $0).text.isEmpty }
            .prefix(limit)
            .map { $0 }
    }

    /// The raw take when History kept it; otherwise the cleaned transcript.
    static func text(for item: HistoryItem) -> (text: String, isRaw: Bool) {
        if let raw = item.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return (raw, true)
        }
        return (item.transcript.trimmingCharacters(in: .whitespacesAndNewlines), false)
    }

    /// One flattened line for menus and captions.
    static func previewLine(_ text: String, maxLength: Int = 60) -> String {
        let flat = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > maxLength else { return flat }
        return String(flat.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// What a test result was produced with; the result goes stale when the
/// draft moves on.
nonisolated struct RulesetTestFingerprint: Equatable, Sendable {
    var instructions: String
    var temperature: Double

    init(ruleset: CustomCleanupRuleset) {
        instructions = ruleset.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        temperature = ruleset.temperature
    }
}

enum RulesetTestSource: Hashable {
    case example(CleanupSampleTranscripts)
    case history(UUID)
}

/// Runs the in-progress ruleset over a built-in dictation or a recent
/// transcript and shows the result. Never writes to History or Settings.
struct RulesetTestPanel: View {
    /// The sheet's unsaved name, instructions and temperature.
    let draft: CustomCleanupRuleset

    @StateObject private var runner = CleanupPreviewRunner()
    @ObservedObject private var history = HistoryService.shared
    @State private var source: RulesetTestSource = .example(.onboardingDefault)
    @State private var showFullInput = false
    @State private var comparison: CleanupOption?
    @State private var ranWith: RulesetTestFingerprint?
    @State private var ranText = ""

    private var candidates: [HistoryItem] { RulesetTestInput.recentHistoryCandidates(from: history.items) }

    private var input: (text: String, isRaw: Bool, isHistory: Bool) {
        switch source {
        case .example(let sample): return (sample.text, true, false)
        case .history(let id):
            guard let item = history.items.first(where: { $0.id == id }) else { return ("", true, true) }
            let picked = RulesetTestInput.text(for: item)
            return (picked.text, picked.isRaw, true)
        }
    }

    private var draftOption: CleanupOption? { draft.isUsable ? .custom(draft) : nil }
    private var isStale: Bool { ranWith != nil && ranWith != RulesetTestFingerprint(ruleset: draft) }
    private var usesHistorySource: Bool {
        if case .history = source { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourcePicker
            inputPreview
            runRow
            if let option = draftOption, let outcome = runner.outcome(for: option, text: ranText), !ranText.isEmpty {
                resultCard(outcome: outcome)
            }
            if let comparison, let outcome = runner.outcome(for: comparison, text: ranText), !ranText.isEmpty {
                comparisonCard(option: comparison, outcome: outcome)
            }
        }
        .onDisappear { runner.cancel() }
    }

    // MARK: - Input

    private var sourcePicker: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(
                get: { usesHistorySource ? 1 : 0 },
                set: { index in
                    if index == 0 {
                        source = .example(.onboardingDefault)
                    } else if let first = candidates.first {
                        source = .history(first.id)
                    } else {
                        source = .history(UUID())
                    }
                })
            ) {
                Text("Example").tag(0)
                Text("From History").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            if usesHistorySource {
                if candidates.isEmpty {
                    Text("No transcripts yet. Dictate something first, or use an example.")
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)
                } else {
                    Menu {
                        ForEach(candidates) { item in
                            Button(historyLabel(item)) { source = .history(item.id) }
                        }
                    } label: {
                        menuLabel(selectedHistoryLabel)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } else {
                Menu {
                    ForEach(CleanupSampleTranscripts.allCases) { sample in
                        Button(sample.title) { source = .example(sample) }
                    }
                } label: {
                    if case .example(let sample) = source { menuLabel(sample.title) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer()
        }
    }

    private var selectedHistoryLabel: String {
        if case .history(let id) = source, let item = history.items.first(where: { $0.id == id }) {
            return historyLabel(item)
        }
        return "Choose a transcript"
    }

    private func historyLabel(_ item: HistoryItem) -> String {
        "\(item.date.formatted(.relative(presentation: .named))) · \(RulesetTestInput.previewLine(RulesetTestInput.text(for: item).text))"
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .font(Typography.uiMedium(12))
        .foregroundStyle(Color.textSecondary)
    }

    @ViewBuilder
    private var inputPreview: some View {
        let current = input
        if !current.text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(current.text)
                    .font(Typography.ui(12))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(showFullInput ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if current.isHistory, !current.isRaw {
                        Text("Using the cleaned transcript from History. The raw take wasn't kept.")
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                    }
                    Spacer()
                    Button(showFullInput ? "Show less" : "Show all") { showFullInput.toggle() }
                        .buttonStyle(.plain)
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.bgCard))
        }
    }

    // MARK: - Run

    private var runRow: some View {
        HStack(spacing: 10) {
            if runner.isRunning {
                Spinner(size: 12)
                Text("Running on \(PostProcessingModelManager.shared.selectedModel.name)…")
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
                Button("Cancel") { runner.cancel() }
                    .controlSize(.small)
            } else {
                Button("Run test") { run() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(draftOption == nil || input.text.isEmpty || !TranscriptFormatterService.isCleanupAvailable)
                    .help(draft.isUsable ? "Uses your unsaved edits" : "Write some instructions first")
                Menu("Also run…") {
                    Button("Nothing else") { comparison = nil }
                    Divider()
                    Button(FormattingIntensity.formatting.displayName) { comparison = .basic }
                    Button(FormattingIntensity.lightCleanup.displayName) { comparison = .light }
                    Button(FormattingIntensity.polish.displayName) { comparison = .polish }
                }
                .fixedSize()
                if let comparison {
                    Text("+ \(comparison.displayName)")
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)
                }
            }
            Spacer()
            if !TranscriptFormatterService.isCleanupAvailable {
                Text("No cleanup model is available right now.")
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.accentWarning)
            }
        }
    }

    private func run() {
        guard let option = draftOption else { return }
        let text = input.text
        guard !text.isEmpty else { return }
        ranText = text
        ranWith = RulesetTestFingerprint(ruleset: draft)
        runner.run(text: text, options: [option] + (comparison.map { [$0] } ?? []))
    }

    // MARK: - Results

    private func resultCard(outcome: TranscriptCleanupOutcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RESULT")
                    .font(Typography.uiBold(10)).tracking(1)
                    .foregroundStyle(Color.textMuted)
                if isStale {
                    Label("Instructions changed since this run", systemImage: "clock.arrow.circlepath")
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.accentWarning)
                }
                Spacer()
            }
            if let error = outcome.error {
                Text(error)
                    .font(Typography.ui(13))
                    .foregroundStyle(Color.accentError)
            } else {
                Text(outcome.output)
                    .font(Typography.ui(13))
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(diagnostics(for: outcome, governed: false))
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textMuted)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border, lineWidth: 1))
    }

    private func comparisonCard(option: CleanupOption, outcome: TranscriptCleanupOutcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(option.displayName.uppercased())
                    .font(Typography.uiBold(10)).tracking(1)
                    .foregroundStyle(Color.textMuted)
                if outcome.modelRan, outcome.landed == nil {
                    Label("Changed too much. VoxBox would keep the original.", systemImage: "exclamationmark.triangle.fill")
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.accentWarning)
                }
                Spacer()
            }
            Text(outcome.output)
                .font(Typography.ui(13))
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(diagnostics(for: outcome, governed: true))
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textMuted)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.bgCard.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border.opacity(0.6), lineWidth: 1))
    }

    static func diagnosticsLine(for outcome: TranscriptCleanupOutcome, governed: Bool) -> String {
        var parts: [String] = []
        if let engine = outcome.engineName {
            parts.append("Ran on \(engine)")
            if outcome.fellBackToSystemModel, let requested = outcome.requestedEngineName {
                parts.append("(requested \(requested))")
            }
        } else if let reason = outcome.skippedReason {
            parts.append(reason)
        }
        parts.append(String(format: "%.1f s", Double(outcome.totalDurationMs) / 1000))
        let changed = CleanupGuardrail.legacyChangeRatio(from: outcome.modelInput, to: outcome.output)
        parts.append("\(Int((changed * 100).rounded()))% changed")
        if governed {
            if let ratio = outcome.changeRatio {
                parts.append(String(format: "guardrail cost %.2f", ratio))
            }
        } else {
            parts.append("No guardrail for custom rulesets")
        }
        return parts.joined(separator: " · ")
    }

    private func diagnostics(for outcome: TranscriptCleanupOutcome, governed: Bool) -> String {
        Self.diagnosticsLine(for: outcome, governed: governed)
    }
}
