import SwiftUI

/// One page for everything that happens to a transcript before it is
/// pasted: the level (Off, Basic, Light cleanup, Polish, Custom), the instant
/// rules, the custom rulesets, and a preview that re-runs on the sample as
/// the choice changes. Replaces the split between Settings › Transcript
/// Cleanup and AI Models › LLM Instructions.
struct CleanupPageView: View {
    @AppStorage(TranscriptFormatterService.enabledKey)
    private var formatWithOnDeviceAI: Bool = false
    @AppStorage(TranscriptFormatterService.intensityKey)
    private var formattingIntensityRaw: Int = FormattingIntensity.lightCleanup.rawValue
    @AppStorage(TranscriptFormatterService.markdownFormattingKey)
    private var markdownFormatting: Bool = true
    @AppStorage(AutoEdit.defaultsKey) private var enableAutoEdit: Bool = false
    @AppStorage(SmartTrailingPunctuation.defaultsKey) private var smartTrailingPunctuation: Bool = true

    @ObservedObject private var rulesetStore = CustomRulesetStore.shared
    @ObservedObject private var history = HistoryService.shared
    @ObservedObject private var postProcessing = PostProcessingModelManager.shared
    @StateObject private var runner = CleanupPreviewRunner()

    @State private var sample: CleanupSampleTranscripts = .onboardingDefault
    @State private var useLastTake = false

    private var isAvailable: Bool { TranscriptFormatterService.isCleanupAvailable }

    private var currentLevel: OnboardingCleanupChoice {
        guard formatWithOnDeviceAI else { return .off }
        switch FormattingIntensity(rawValue: formattingIntensityRaw) ?? .lightCleanup {
        case .formatting: return .basic
        case .lightCleanup: return .lightCleanup
        case .polish: return .polish
        case .custom: return .custom
        }
    }

    private var lastTake: (text: String, isRaw: Bool)? {
        guard let item = history.items.first else { return nil }
        let picked = RulesetTestInput.text(for: item)
        return picked.text.isEmpty ? nil : picked
    }

    private var previewText: String {
        if useLastTake, let lastTake { return lastTake.text }
        return sample.text
    }

    private var previewOption: CleanupOption? {
        currentLevel.previewOption(rulesetStore: rulesetStore)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Cleanup")
                    .font(Typography.displayLarge)
                    .foregroundStyle(Color.textPrimary)

                modelStrip

                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 14) {
                        levels
                        instantRules
                        if currentLevel == .custom {
                            customSection
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    preview
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .onAppear { runPreview() }
        .onChange(of: formatWithOnDeviceAI) { _, _ in runPreview() }
        .onChange(of: formattingIntensityRaw) { _, _ in runPreview() }
        .onChange(of: rulesetStore.activeRulesetID) { _, _ in runPreview() }
        .onChange(of: rulesetStore.rulesets) { _, _ in
            runner.invalidate()
            runPreview()
        }
        .onChange(of: enableAutoEdit) { _, _ in
            runner.invalidate()
            runPreview()
        }
        .onChange(of: sample) { _, _ in runPreview() }
        .onChange(of: useLastTake) { _, _ in runPreview() }
        .onDisappear { runner.cancel() }
    }

    // MARK: - Strip

    private var modelStrip: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.brandAccentSoft)
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.brandAccent)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("CLEANING UP WITH")
                    .font(Typography.uiBold(9)).tracking(1.1)
                    .foregroundStyle(Color.textMuted)
                Text(formatWithOnDeviceAI ? "\(postProcessing.selectedModel.name) · on this Mac" : "Instant rules only")
                    .font(Typography.uiBold(14))
                    .foregroundStyle(Color.textPrimary)
            }
            Spacer()
            if !PostProcessingModel.downloadableModelsEnabled {
                Text("Other on-device models arrive with macOS 27")
                    .font(Typography.ui(12))
                    .foregroundStyle(Color.textMuted)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.border.opacity(0.6), lineWidth: 1))
    }

    // MARK: - Levels

    private var levels: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(OnboardingCleanupChoice.allCases) { level in
                CleanupLevelRow(
                    level: level,
                    isSelected: currentLevel == level,
                    isEnabled: level == .off || isAvailable,
                    select: { select(level) })
            }
            if !isAvailable {
                Label(
                    "Apple Intelligence isn't available on this Mac right now. Instant rules still run; the model levels start working as soon as it is.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(Typography.captionSmall)
                .foregroundStyle(Color.accentWarning)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func select(_ level: OnboardingCleanupChoice) {
        switch level {
        case .off:
            formatWithOnDeviceAI = false
        default:
            formatWithOnDeviceAI = true
            formattingIntensityRaw = level.intensity!.rawValue
            if level == .custom, rulesetStore.rulesets.isEmpty, var created = rulesetStore.addRuleset() {
                created.name = OnboardingCleanupChoice.defaultRulesetName
                rulesetStore.update(created)
                rulesetStore.activeRulesetID = created.id
            }
        }
    }

    // MARK: - Instant rules and options

    private var instantRules: some View {
        VStack(alignment: .leading, spacing: 12) {
            if currentLevel == .lightCleanup || currentLevel == .polish {
                toggleRow(
                    "Markdown formatting",
                    caption: "Lists and bold only where the dictation clearly calls for them.",
                    isOn: $markdownFormatting)
                Divider()
            }
            toggleRow(
                "Remove filler words instantly",
                caption: "Strips um, uh and similar before anything else. No model, no wait. Applies at every level, including Off.",
                isOn: $enableAutoEdit)
            Divider()
            toggleRow(
                "Strip stray period",
                caption: "If you dictate only an email, URL, number or single word, drops the full stop the engine adds.",
                isOn: $smartTrailingPunctuation)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.border.opacity(0.6), lineWidth: 1))
    }

    private func toggleRow(_ title: String, caption: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                Text(caption)
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CustomRulesetManagerView()
            Text("Custom rulesets are sent to the model exactly as written, with their own temperature and no guardrail. Open a ruleset to test it before saving.")
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.border.opacity(0.6), lineWidth: 1))
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TRY IT")
                    .font(Typography.uiBold(10)).tracking(1)
                    .foregroundStyle(Color.textMuted)
                Spacer()
                Menu {
                    ForEach(CleanupSampleTranscripts.allCases) { candidate in
                        Button(candidate.title) {
                            useLastTake = false
                            sample = candidate
                        }
                    }
                    if lastTake != nil {
                        Divider()
                        Button("My last take") { useLastTake = true }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(useLastTake ? "My last take" : sample.title)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .font(Typography.uiMedium(12))
                    .foregroundStyle(Color.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.bgCard.opacity(0.7))

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("You said")
                        .font(Typography.captionBold)
                        .foregroundStyle(Color.textMuted)
                    Text(previewText)
                        .font(Typography.ui(12.5))
                        .italic()
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if useLastTake, let lastTake, !lastTake.isRaw {
                        Text("Using the cleaned transcript from History. The raw take wasn't kept.")
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                    }
                }

                previewResult
            }
            .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.border.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var previewResult: some View {
        let label = currentLevel.title.uppercased()
        if currentLevel != .off, !isAvailable {
            Text("Preview unavailable until Apple Intelligence is back.")
                .font(Typography.ui(13))
                .foregroundStyle(Color.textMuted)
        } else if previewOption == nil {
            Text("Write some instructions in your ruleset, then the preview runs here.")
                .font(Typography.ui(13))
                .foregroundStyle(Color.textMuted)
        } else if let option = previewOption {
            switch runner.state(for: option, text: previewText) {
            case .idle, .queued, .running:
                HStack(spacing: 8) {
                    Spinner(size: 12)
                    Text("Cleaning up…")
                }
                .font(Typography.ui(13))
                .foregroundStyle(Color.textSecondary)
            case .failed(let message):
                Text(message)
                    .font(Typography.ui(13))
                    .foregroundStyle(Color.accentError)
            case .done(let outcome):
                VStack(alignment: .leading, spacing: 8) {
                    Text(outcome.output)
                        .font(Typography.ui(15))
                        .foregroundStyle(Color.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.bgApp))
                        .overlay(alignment: .topLeading) {
                            Text(label)
                                .font(Typography.uiBold(9)).tracking(1)
                                .foregroundStyle(Color.textMuted)
                                .padding(.horizontal, 6)
                                .background(Color.bgApp)
                                .offset(x: 10, y: -7)
                        }
                    HStack(spacing: 12) {
                        Text(footer(for: outcome))
                            .font(Typography.monoSmall)
                            .foregroundStyle(Color.textMuted)
                        Spacer()
                        Button("Run again") {
                            runner.invalidate()
                            runPreview()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func footer(for outcome: TranscriptCleanupOutcome) -> String {
        guard outcome.modelRan else {
            return currentLevel == .off ? "as transcribed" : (outcome.skippedReason ?? "no model pass")
        }
        var parts = [outcome.engineName ?? "Apple Intelligence", String(format: "%.1f s", Double(outcome.totalDurationMs) / 1000)]
        if let landed = outcome.landed {
            parts.append("landed at \(landed.displayName)")
        } else {
            parts.append("changed too much, kept the original")
        }
        return parts.joined(separator: " · ")
    }

    private func runPreview() {
        guard let option = previewOption else { return }
        if currentLevel != .off, !isAvailable { return }
        runner.run(text: previewText, options: [option])
    }
}

/// One level: radio, serif name, one-line summary.
private struct CleanupLevelRow: View {
    let level: OnboardingCleanupChoice
    let isSelected: Bool
    let isEnabled: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textMuted)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(level.title)
                        .font(Typography.onboardingCardTitle)
                        .foregroundStyle(Color.textPrimary)
                    Text(level.summary)
                        .font(Typography.ui(12.5))
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.bgCard))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.textPrimary : Color.border.opacity(isHovered ? 1 : 0.6),
                        lineWidth: isSelected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    CleanupPageView().frame(width: 1000, height: 800).background(Color.bgApp)
}
