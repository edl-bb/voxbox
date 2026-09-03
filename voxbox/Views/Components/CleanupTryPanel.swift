import SwiftUI

/// The output card for one preview: the cleaned text, or a placeholder, or a
/// spinner while the model runs, with a status line underneath.
struct CleanupPreviewResultView: View {
    var outcome: TranscriptCleanupOutcome?
    var isRunning: Bool
    var placeholder: String
    var minHeight: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.bgCard)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.border.opacity(0.6), lineWidth: 1)

                if isRunning, outcome == nil {
                    HStack(spacing: 10) {
                        Spinner(size: 14, lineWidth: 2)
                        Text("Tidying up…")
                            .font(Typography.ui(13))
                            .foregroundStyle(Color.textSecondary)
                    }
                    .padding(14)
                } else if let outcome {
                    ScrollView {
                        Text(outcome.output)
                            .font(Typography.ui(13))
                            .foregroundStyle(Color.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                } else {
                    Text(placeholder)
                        .font(Typography.ui(13))
                        .foregroundStyle(Color.textMuted)
                        .padding(14)
                }
            }
            .frame(minHeight: minHeight)

            if let outcome {
                Text(CleanupOutcomeSummary.statusLine(for: outcome))
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
            }
        }
    }
}

/// Pick a built-in sample or a recent take, run it through one cleanup
/// option, and show the result. Used under the effort picker and inside the
/// ruleset editor.
struct CleanupTryPanel: View {
    /// What to run. Rebuilt by the caller when settings or a draft change.
    let option: CleanupOption
    var includeMarkdown: Bool = false
    /// Why running is disabled right now, if it is (no instructions yet, …).
    var disabledReason: String?

    @ObservedObject private var history = HistoryService.shared
    @State private var source: CleanupSampleSource = .defaultSource
    @State private var outcome: TranscriptCleanupOutcome?
    @State private var isRunning = false
    @State private var task: Task<Void, Never>?

    init(option: CleanupOption, includeMarkdown: Bool = false, disabledReason: String? = nil) {
        self.option = option
        self.includeMarkdown = includeMarkdown
        self.disabledReason = disabledReason
    }

    private var recent: [CleanupSampleSource] {
        CleanupSampleSource.recent(from: history.items)
    }

    private var blocker: String? {
        if let disabledReason { return disabledReason }
        if !TranscriptFormatterService.isCleanupAvailable {
            return "No cleanup model is available on this Mac right now."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $source) {
                    Section("Built-in samples") {
                        ForEach(CleanupSampleSource.builtIn) { sample in
                            Text(sample.title).tag(sample)
                        }
                    }
                    if !recent.isEmpty {
                        Section("Recent transcripts") {
                            ForEach(recent) { sample in
                                Text(sample.title).tag(sample)
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 320, alignment: .leading)

                Spacer(minLength: 8)

                Button(action: run) {
                    HStack(spacing: 6) {
                        if isRunning {
                            Spinner(size: 11, lineWidth: 1.5, tint: Color.bgApp)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        }
                        Text(isRunning ? "Running…" : "Run")
                            .font(Typography.uiBold(12))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.textPrimary.opacity(blocker == nil ? 1 : 0.35)))
                    .foregroundStyle(Color.bgApp)
                }
                .buttonStyle(.plain)
                .disabled(blocker != nil || isRunning)
                .help(blocker ?? "Run the selected sample through this cleanup")
            }

            Text(source.text)
                .font(Typography.ui(12))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            CleanupPreviewResultView(
                outcome: outcome,
                isRunning: isRunning,
                placeholder: blocker ?? "Press Run to see what this cleanup does to the sample.",
                minHeight: 72)
        }
        .onChange(of: source) { _, _ in reset() }
        .onChange(of: option) { _, _ in reset() }
        .onDisappear { task?.cancel() }
    }

    private func reset() {
        task?.cancel()
        isRunning = false
        outcome = nil
    }

    private func run() {
        task?.cancel()
        outcome = nil
        isRunning = true
        let text = source.text
        let option = self.option
        let includeMarkdown = self.includeMarkdown
        task = Task {
            let result = await TranscriptCleanupPreview.preview(
                text: text, option: option, includeMarkdown: includeMarkdown)
            guard !Task.isCancelled else { return }
            outcome = result
            isRunning = false
        }
    }
}
