import SwiftUI

/// One dictation, cleaned at every level, so the choice is made by reading
/// results rather than descriptions. Runs the same pipeline a take uses.
struct CleanupOnboardingPage: View {
    let continueAction: () -> Void
    let skipAction: () -> Void

    @StateObject private var runner = CleanupPreviewRunner()
    @ObservedObject private var rulesetStore = CustomRulesetStore.shared
    @State private var selection: OnboardingCleanupChoice = .current()
    @State private var sample: CleanupSampleTranscripts = .onboardingDefault
    @State private var customText = ""
    @State private var usingCustomText = false

    static let minimumCustomWords = TranscriptFormatterService.minimumWordCount

    private var isAvailable: Bool { TranscriptFormatterService.isCleanupAvailable }

    private var previewText: String {
        usingCustomText ? customText.trimmingCharacters(in: .whitespacesAndNewlines) : sample.text
    }

    private var customWordCount: Int {
        customText.split(whereSeparator: { $0.isWhitespace }).count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 12) {
                    sampleCard
                    if !isAvailable { unavailableBanner }
                    ForEach(OnboardingCleanupChoice.allCases) { choice in
                        CleanupOptionCard(
                            choice: choice,
                            isSelected: selection == choice,
                            state: state(for: choice),
                            select: { selection = choice })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Divider()
                .padding(.horizontal, 16)
            footer
                .padding(.top, 14)
                .padding(.bottom, 8)
        }
        .onAppear { runPreviews() }
        .onChange(of: sample) { _, _ in
            if !usingCustomText { runPreviews() }
        }
        .onChange(of: rulesetStore.activeRulesetID) { _, _ in runPreviews() }
        .onDisappear { runner.cancel() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            OnboardingEyebrow(text: "Cleanup")
            Text("Clean up your transcripts")
                .font(Typography.displayMedium)
                .foregroundStyle(Color.textPrimary)
            Text(
                "After each take, an on-device model can tidy what you said before it's pasted. Nothing leaves your Mac. Here's one dictation at every level. Pick what reads right to you. You can change it later in Settings."
            )
            .font(Typography.bodyMedium)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sampleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WHAT YOU SAID")
                    .font(Typography.captionBold)
                    .foregroundStyle(Color.textSecondary)
                    .tracking(1.2)
                Spacer()
                Menu {
                    ForEach(CleanupSampleTranscripts.allCases) { candidate in
                        Button {
                            usingCustomText = false
                            sample = candidate
                        } label: {
                            if candidate == sample, !usingCustomText {
                                Label(candidate.title, systemImage: "checkmark")
                            } else {
                                Text(candidate.title)
                            }
                        }
                    }
                    Divider()
                    Button("Try your own text…") {
                        usingCustomText = true
                        if customWordCount >= Self.minimumCustomWords { runPreviews() }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(usingCustomText ? "Your text" : sample.title)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .font(Typography.labelSmall)
                    .foregroundStyle(Color.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if usingCustomText {
                TextField("Type or paste a dictation of at least \(Self.minimumCustomWords) words", text: $customText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Typography.bodySmall)
                    .lineLimit(3...6)
                HStack {
                    Text(
                        customWordCount >= Self.minimumCustomWords
                            ? "\(customWordCount) words"
                            : "\(customWordCount) of \(Self.minimumCustomWords) words needed")
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    Button("Run cleanup") { runPreviews() }
                        .disabled(customWordCount < Self.minimumCustomWords)
                        .controlSize(.small)
                }
            } else {
                Text(sample.text)
                    .font(Typography.bodySmall)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.border.opacity(0.6), lineWidth: 1))
    }

    private var unavailableBanner: some View {
        Label(
            "Apple Intelligence isn't available on this Mac right now, so there's nothing to preview. You can still choose a level; cleanup starts working as soon as it's available.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(Typography.caption)
        .foregroundStyle(Color.accentWarning)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentWarning.opacity(0.08)))
    }

    private var footer: some View {
        VStack(spacing: 12) {
            ContinueButton(isEnabled: true, action: finish)
            OnboardingSkipButton(action: skipAction)
                .help("Cleanup stays as it is. Change it any time in Settings.")
        }
    }

    // MARK: - Behaviour

    private func state(for choice: OnboardingCleanupChoice) -> CleanupOptionCard.State {
        if !isAvailable, choice != .off { return .unavailable }
        guard let option = choice.previewOption(rulesetStore: rulesetStore) else { return .notApplicable }
        if usingCustomText, customWordCount < Self.minimumCustomWords { return .waitingForText }
        switch runner.state(for: option, text: previewText) {
        case .idle, .queued: return .queued
        case .running: return .running
        case .done(let outcome): return .done(outcome)
        case .failed(let message): return .failed(message)
        }
    }

    private func runPreviews() {
        if usingCustomText, customWordCount < Self.minimumCustomWords { return }
        let options = OnboardingCleanupChoice.allCases.compactMap { choice -> CleanupOption? in
            guard isAvailable || choice == .off else { return nil }
            return choice.previewOption(rulesetStore: rulesetStore)
        }
        runner.run(text: previewText, options: options)
    }

    private func finish() {
        let needsEditor = selection.apply(rulesetStore: rulesetStore)
        if selection == .custom || needsEditor {
            DashboardRoute.pending = .aiModels
            DashboardRoute.pendingAIModelsTab = .instructions
        }
        continueAction()
    }
}

/// Radio, name and summary on the left; the cleaned output on the right.
struct CleanupOptionCard: View {
    enum State: Equatable {
        /// Custom with no ruleset yet.
        case notApplicable
        case waitingForText
        case queued
        case running
        case done(TranscriptCleanupOutcome)
        case failed(String)
        case unavailable
    }

    let choice: OnboardingCleanupChoice
    let isSelected: Bool
    let state: State
    let select: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary.opacity(0.6))
                        Text(choice.title)
                            .font(Typography.onboardingCardTitle)
                            .foregroundStyle(Color.textPrimary)
                    }
                    Text(choice.summary)
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 190, alignment: .leading)

                output
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.textPrimary.opacity(colorScheme == .dark ? 0.08 : 0.04) : Color.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.textPrimary : Color.border.opacity(0.6), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var output: some View {
        switch state {
        case .notApplicable:
            muted("Write your rules after setup. We'll open the editor for you.")
        case .waitingForText:
            muted("Enter your text above to see this level.")
        case .queued:
            muted("Waiting…")
        case .running:
            HStack(spacing: 8) {
                Spinner(size: 12)
                Text("Cleaning up…")
            }
            .font(Typography.caption)
            .foregroundStyle(Color.textSecondary)
        case .failed(let message):
            muted(message)
        case .unavailable:
            muted("Preview unavailable.")
        case .done(let outcome):
            VStack(alignment: .leading, spacing: 8) {
                Text(outcome.output)
                    .font(Typography.bodySmall)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    if outcome.modelRan {
                        Text("\(outcome.engineName ?? "Apple Intelligence") · \(Self.seconds(outcome.totalDurationMs))")
                    } else if choice != .off, let reason = outcome.skippedReason {
                        Text(reason)
                    } else if choice == .off {
                        Text("As transcribed")
                    }
                    if outcome.modelRan, outcome.landed == nil {
                        Label("Changed too much. VoxBox would keep the original.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.accentWarning)
                    }
                }
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private func muted(_ text: String) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func seconds(_ ms: Int) -> String {
        String(format: "%.1f s", Double(ms) / 1000)
    }
}
