#if DEBUG
    import SwiftUI

    /// Settings › General (DEBUG builds only). Overlays any compiled prompt or
    /// budget, shows what the last real take did, and runs a preview on the
    /// built-in samples or the last take. Release builds omit this file's UI
    /// and `TranscriptCleanupDebug.overlay` returns the compiled set.
    struct TranscriptCleanupDebugSection: View {
        @State private var field: TranscriptCleanupDebug.Field = .light
        @State private var overlayText = ""
        @State private var hasOverlay = TranscriptCleanupDebug.hasOverlay
        @State private var lastOutcome: TranscriptCleanupOutcome? = TranscriptFormatterService.shared.lastOutcome

        @State private var previewSource: PreviewSource = .sample(.onboardingDefault)
        @State private var previewIntensity: FormattingIntensity = .lightCleanup
        @State private var previewOutcome: TranscriptCleanupOutcome?
        @State private var previewTask: Task<Void, Never>?

        private enum PreviewSource: Hashable {
            case sample(CleanupSampleTranscripts)
            case lastTake

            var title: String {
                switch self {
                case .sample(let sample): return sample.title
                case .lastTake: return "Last take (raw)"
                }
            }
        }

        var body: some View {
            SettingsSection {
                SettingsSectionHeader(
                    icon: "hammer",
                    title: "Transcript Cleanup (DEBUG)",
                    subtitle: hasOverlay
                        ? "Overlay active: takes run on the edited values below."
                        : "Compiled prompts and budgets are in use."
                )

                VStack(alignment: .leading, spacing: 14) {
                    editor
                    Divider()
                    lastTakeBlock
                    Divider()
                    previewBlock
                }
            }
            .onAppear { loadField() }
            .onChange(of: field) { _, _ in loadField() }
            .onReceive(NotificationCenter.default.publisher(for: .transcriptCleanupFinished)) { _ in
                lastOutcome = TranscriptFormatterService.shared.lastOutcome
            }
            .onDisappear { previewTask?.cancel() }
        }

        // MARK: - Overlay editor

        private var editor: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Field", selection: $field) {
                        ForEach(TranscriptCleanupDebug.Field.allCases, id: \.self) { field in
                            Text(field.title).tag(field)
                        }
                    }
                    .frame(maxWidth: 360)
                    Spacer()
                    Button("Reset all") {
                        TranscriptCleanupDebug.resetOverlay()
                        hasOverlay = false
                        loadField()
                    }
                    .disabled(!hasOverlay)
                }

                TextEditor(text: $overlayText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 96)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.bgCard))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.border, lineWidth: 1))
                    .onChange(of: overlayText) { _, text in
                        let compiled = TranscriptCleanupDebug.compiledValue(field)
                        TranscriptCleanupDebug.setOverlay(text == compiled ? nil : text, for: field)
                        hasOverlay = TranscriptCleanupDebug.hasOverlay
                    }

                Text(
                    TranscriptCleanupDebug.overlayValue(field) == nil
                        ? "Showing the compiled value. Edit to overlay; budgets are “ratio, free edits, retention”."
                        : "Overlaid. Clear the text to return to the compiled value."
                )
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textMuted)
            }
        }

        private func loadField() {
            overlayText = TranscriptCleanupDebug.overlayValue(field) ?? TranscriptCleanupDebug.compiledValue(field)
        }

        // MARK: - Last take

        @ViewBuilder
        private var lastTakeBlock: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Last take")
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                if let lastOutcome {
                    OutcomeDiagnostics(outcome: lastOutcome)
                } else {
                    Text("None this launch.")
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)
                }
            }
        }

        // MARK: - Preview

        private var previewBlock: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run preview")
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                HStack {
                    Picker("Text", selection: $previewSource) {
                        ForEach(CleanupSampleTranscripts.allCases) { sample in
                            Text(sample.title).tag(PreviewSource.sample(sample))
                        }
                        if lastOutcome != nil {
                            Text("Last take (raw)").tag(PreviewSource.lastTake)
                        }
                    }
                    .frame(maxWidth: 260)
                    Picker("Level", selection: $previewIntensity) {
                        ForEach(FormattingIntensity.builtInCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .frame(maxWidth: 220)
                    Spacer()
                    if previewTask != nil {
                        Spinner().frame(width: 16, height: 16)
                        Button("Cancel") { previewTask?.cancel(); previewTask = nil }
                    } else {
                        Button("Run") { runPreview() }
                    }
                }
                if let previewOutcome {
                    Text(previewOutcome.output)
                        .font(Typography.ui(13))
                        .foregroundStyle(Color.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.bgCard))
                    OutcomeDiagnostics(outcome: previewOutcome)
                }
            }
        }

        private var previewText: String {
            switch previewSource {
            case .sample(let sample): return sample.text
            case .lastTake: return lastOutcome?.rawInput ?? ""
            }
        }

        private func runPreview() {
            let text = previewText
            let option = CleanupOption(intensity: previewIntensity, ruleset: nil)
            previewTask?.cancel()
            previewTask = Task { @MainActor in
                let outcome = await TranscriptCleanupPreview.preview(
                    text: text, option: option, includeMarkdown: false, allowStepDown: false)
                guard !Task.isCancelled else { return }
                previewOutcome = outcome
                previewTask = nil
            }
        }
    }

    /// One line per attempt plus the headline, for the tuner and previews.
    struct OutcomeDiagnostics: View {
        let outcome: TranscriptCleanupOutcome

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textSecondary)
                ForEach(Array(outcome.attempts.enumerated()), id: \.offset) { _, attempt in
                    Text(describe(attempt))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(attempt.verdict.isAccepted ? Color.textMuted : Color.accentWarning)
                }
            }
        }

        private var headline: String {
            var parts = ["Requested \(outcome.requested.displayName)", "landed \(outcome.landed?.displayName ?? "raw")"]
            if let engine = outcome.engineName { parts.append("on \(engine)") }
            if outcome.fellBackToSystemModel, let requested = outcome.requestedEngineName {
                parts.append("(fell back from \(requested))")
            }
            parts.append("\(outcome.totalDurationMs) ms")
            if let reason = outcome.skippedReason { parts.append("· \(reason)") }
            return parts.joined(separator: " · ")
        }

        private func describe(_ attempt: CleanupAttempt) -> String {
            var line = "\(attempt.intensity.displayName): \(TranscriptCleanupPipeline.describe(attempt.verdict))"
            if let evaluation = attempt.evaluation {
                line += String(
                    format: " · cost %.1f/%d (%.2f) · kept %.2f", evaluation.cost, evaluation.inputTokens,
                    evaluation.costRatio, evaluation.retention)
            }
            if attempt.casingAnomaly { line += " · casing anomaly" }
            line += " · \(attempt.durationMs) ms"
            return line
        }
    }
#endif
