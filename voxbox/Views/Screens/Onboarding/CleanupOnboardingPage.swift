import SwiftUI

/// First-run explainer for transcript cleanup: what each level does, a
/// built-in sample to see the difference on, and the choice itself. Writes
/// the same two Settings keys the AI Models page uses.
struct CleanupOnboardingPage: View {
    let action: () -> Void

    @AppStorage(TranscriptFormatterService.enabledKey)
    private var formatWithOnDeviceAI: Bool = false
    @AppStorage(TranscriptFormatterService.intensityKey)
    private var formattingIntensityRaw: Int = FormattingIntensity.lightCleanup.rawValue

    @State private var choice: CleanupLevelChoice = .recommended
    @State private var sample: CleanupSampleTranscripts = .onboardingDefault
    @State private var results: [CleanupOption: TranscriptCleanupOutcome] = [:]
    @State private var isPreviewing = false
    @State private var previewTask: Task<Void, Never>?

    private let isAvailable = TranscriptFormatterService.isCleanupAvailable
    private let previewOptions: [CleanupOption] = [.basic, .light, .polish]

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text("TIDY UP")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .textCase(.uppercase)
                    .tracking(2)

                Text("Transcript cleanup")
                    .font(.system(size: 36, weight: .regular, design: .serif))
                    .foregroundStyle(Color.textPrimary)

                Text(
                    "After transcribing, VoxBox can run an on-device model over the text before it is pasted. Nothing leaves your Mac. Choose how much it may change; try each level on a sample below."
                )
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .lineSpacing(3)
            }
            .padding(.bottom, 22)

            HStack(spacing: 8) {
                ForEach(CleanupLevelChoice.allCases) { level in
                    CleanupLevelChip(
                        level: level,
                        isSelected: choice == level,
                        isRecommended: level == .recommended
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) { choice = level }
                    }
                }
            }
            .frame(maxWidth: 640)

            Text(choice.blurb)
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560, minHeight: 36, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            samplePanel
                .frame(maxWidth: 640)
                .padding(.top, 16)

            Spacer(minLength: 12)

            ContinueButton(isEnabled: true) {
                choice.apply()
                action()
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .onAppear {
            if formatWithOnDeviceAI,
                let intensity = FormattingIntensity(rawValue: formattingIntensityRaw)
            {
                choice = CleanupLevelChoice(enabled: true, intensity: intensity)
            }
        }
        .task {
            guard isAvailable else { return }
            await TranscriptCleanupPreview.prewarm()
        }
        .onDisappear { previewTask?.cancel() }
    }

    // MARK: - Sample and preview

    private var currentOutcome: TranscriptCleanupOutcome? {
        results[choice.previewOption]
    }

    private var placeholder: String {
        switch choice {
        case .off:
            return sample.text
        case .custom:
            return
                "Custom rulesets are written in AI Models → LLM Instructions after setup, and tested there on these same samples. Until you add one, Light cleanup runs; its preview is shown when you press Preview."
        default:
            if !isAvailable {
                return "Apple Intelligence is not available on this Mac right now, so there is nothing to preview. Your choice is saved and cleanup runs whenever a model is available."
            }
            return "Press Preview to run the sample through all three levels, then switch between them to compare."
        }
    }

    private var samplePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Sample")
                    .font(Typography.uiBold(11)).tracking(0.8)
                    .foregroundStyle(Color.textMuted)
                    .textCase(.uppercase)

                Picker("", selection: $sample) {
                    ForEach(CleanupSampleTranscripts.allCases) { sample in
                        Text(sample.title).tag(sample)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()

                Spacer()

                Button(action: runPreview) {
                    HStack(spacing: 6) {
                        if isPreviewing {
                            Spinner(size: 11, lineWidth: 1.5, tint: Color.bgApp)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        }
                        Text(isPreviewing ? "Previewing…" : "Preview")
                            .font(Typography.uiBold(12))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.textPrimary.opacity(isAvailable ? 1 : 0.35)))
                    .foregroundStyle(Color.bgApp)
                }
                .buttonStyle(.plain)
                .disabled(!isAvailable || isPreviewing)
                .help(
                    isAvailable
                        ? "Run the sample through Basic, Light cleanup and Polish"
                        : "No cleanup model is available on this Mac right now")
            }

            if choice != .off {
                Text(sample.text)
                    .font(Typography.ui(12))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            CleanupPreviewResultView(
                outcome: choice == .off ? nil : currentOutcome,
                isRunning: isPreviewing && choice != .off && choice != .custom,
                placeholder: placeholder,
                minHeight: 110)
        }
        .onChange(of: sample) { _, _ in
            previewTask?.cancel()
            isPreviewing = false
            results = [:]
        }
    }

    private func runPreview() {
        previewTask?.cancel()
        results = [:]
        isPreviewing = true
        let text = sample.text
        let options = previewOptions
        previewTask = Task {
            await TranscriptCleanupPreview.compare(text: text, options: options) { option, outcome in
                results[option] = outcome
            }
            if !Task.isCancelled { isPreviewing = false }
        }
    }
}

/// One compact level card in the row: icon, title, and a Recommended tag.
private struct CleanupLevelChip: View {
    let level: CleanupLevelChoice
    let isSelected: Bool
    let isRecommended: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: level.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isSelected ? Color.brandAccent : Color.textPrimary)
                    .frame(height: 22)
                Text(level.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(isRecommended ? "Recommended" : " ")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.brandAccent)
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.brandAccentSoft : Color.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? Color.brandAccent.opacity(0.6) : Color.border.opacity(0.5),
                        lineWidth: isSelected ? 1.5 : 1)
            )
            .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 10 : 4, x: 0, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

#Preview {
    CleanupOnboardingPage(action: {})
        .frame(width: 720, height: 620)
        .background(Color.bgApp)
}
