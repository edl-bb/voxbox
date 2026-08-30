import SwiftUI

/// The AI Models page, split into three tabs: transcription (speech → text)
/// models, post-processing (cleanup LLM) models, and the LLM instruction
/// settings. A strip above the tabs always shows both active models.
struct AIModelsView: View {
    @State private var selectedTab: AIModelsTab = .transcription

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI Models")
                    .font(Typography.displayLarge)
                    .foregroundStyle(Color.textPrimary)

                CurrentModelsStrip()

                HStack(spacing: 0) {
                    ForEach(AIModelsTab.allCases) { tab in
                        AIModelsTabButton(
                            tab: tab,
                            isSelected: selectedTab == tab,
                            action: { selectedTab = tab }
                        )
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch selectedTab {
                    case .transcription:
                        TranscriptionModelsTab()
                    case .postProcessing:
                        PostProcessingModelsView()
                    case .instructions:
                        LLMInstructionsTab()
                    }
                }
                .frame(maxWidth: 940, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 32)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .background(Color.clear)
        .onAppear {
            if let tab = DashboardRoute.pendingAIModelsTab {
                DashboardRoute.pendingAIModelsTab = nil
                selectedTab = tab
            }
        }
    }
}

enum AIModelsTab: String, CaseIterable, Identifiable {
    case transcription = "Transcription models"
    case postProcessing = "Post-processing models"
    case instructions = "LLM Instructions"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .transcription: return "waveform"
        case .postProcessing: return "sparkles"
        case .instructions: return "text.quote"
        }
    }
}

/// Same treatment as the Settings tab bar, typed for this page's tabs.
struct AIModelsTabButton: View {
    let tab: AIModelsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13))
                Text(tab.rawValue)
                    .font(Typography.bodyMedium)
            }
            .foregroundStyle(isSelected ? Color.textPrimary : Color.textMuted)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? Color.bgHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Currently-using strip

/// Always-visible summary of the whole pipeline: the transcription model and
/// the post-processing model side by side.
private struct CurrentModelsStrip: View {
    @AppStorage(ModelSelection.defaultsKey) private var selectedModel: String = ModelSelection.none
    @AppStorage(TranscriptFormatterService.enabledKey)
    private var formatWithOnDeviceAI: Bool = false
    // Bound via @AppStorage (not read from the service) so the strip
    // re-renders the moment the effort level changes on another tab.
    @AppStorage(TranscriptFormatterService.intensityKey)
    private var formattingIntensityRaw: Int = FormattingIntensity.lightCleanup.rawValue
    @ObservedObject private var postProcessing = PostProcessingModelManager.shared
    @ObservedObject private var rulesetStore = CustomRulesetStore.shared

    private var transcriptionModel: AIModel? {
        AIModel.availableModels.first { $0.variant == selectedModel }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            segment(
                icon: "waveform",
                label: "TRANSCRIBING WITH",
                value: transcriptionModel?.name ?? "No model selected",
                detail: transcriptionModel.map {
                    StreamingMode.modelSupportsStreaming($0.variant)
                        ? "Streaming" : "Batch"
                }
            )

            Divider().frame(height: 34)

            segment(
                icon: "sparkles",
                label: "CLEANING UP WITH",
                value: cleanupValue,
                detail: cleanupDetail
            )

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                Image(systemName: "laptopcomputer").font(.system(size: 12))
                Text("Your Mac · \(DeviceCapability.current.summary)")
                    .font(Typography.uiMedium(12))
            }
            .foregroundStyle(Color.textMuted)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.border.opacity(0.6), lineWidth: 1)
        )
    }

    private var cleanupValue: String {
        guard formatWithOnDeviceAI else { return "Off" }
        return postProcessing.selectedModel.name
    }

    private var cleanupDetail: String? {
        guard formatWithOnDeviceAI else { return nil }
        let intensity = FormattingIntensity(rawValue: formattingIntensityRaw) ?? .lightCleanup
        guard intensity == .custom else { return intensity.displayName }
        guard let ruleset = rulesetStore.activeRuleset else { return "Custom: no ruleset yet" }
        return "Custom: \(ruleset.name)"
    }

    private func segment(
        icon: String, label: String, value: String, detail: String?
    ) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.brandAccentSoft)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.brandAccent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(Typography.uiBold(9)).tracking(1.1)
                    .foregroundStyle(Color.textMuted)
                Text(value)
                    .font(Typography.uiBold(14))
                    .foregroundStyle(Color.textPrimary)
                if let detail {
                    Text(detail)
                        .font(Typography.ui(11))
                        .foregroundStyle(Color.textMuted)
                }
            }
        }
    }
}

// MARK: - Transcription models tab

private struct TranscriptionModelsTab: View {
    private let downloadService = ModelDownloadService.shared
    @AppStorage(ModelSelection.defaultsKey) private var selectedModel: String = ModelSelection.none
    @AppStorage(TranscriptDeliveryMode.defaultsKey)
    private var transcriptDeliveryMode: TranscriptDeliveryMode = .autoPaste

    /// The catalog, grouped by engine. Apple leads: it is the zero-download
    /// starting point every new install already has.
    private var engineGroups: [(title: String, subtitle: String, models: [AIModel])] {
        [
            (title: "Apple", subtitle: "Built-in · system speech assets, no download",
             models: AIModel.models(for: .apple)),
            (title: "Parakeet", subtitle: "NVIDIA · fastest, near-Whisper accuracy",
             models: AIModel.models(for: .parakeet)),
            (title: "Whisper", subtitle: "OpenAI · most accurate, a touch slower",
             models: AIModel.models(for: .whisper)),
        ]
        .filter { !$0.models.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription models")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Color.textPrimary)
                Text("Apple Speech works out of the box. Download a model when you want a different speed, accuracy, or language trade-off.")
                    .font(Typography.ui(13))
                    .foregroundStyle(Color.textMuted)
            }

            ForEach(engineGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(group.title)
                            .font(Typography.uiBold(15))
                            .foregroundStyle(Color.textPrimary)
                        Text(group.subtitle)
                            .font(Typography.ui(12))
                            .foregroundStyle(Color.textMuted)
                    }

                    ForEach(group.models) { model in
                        ModelRow(
                            model: model,
                            selectedModel: $selectedModel,
                            isRecommended: model.engine == .apple,
                            snapshot: downloadService.snapshot(for: model.variant)
                        )
                        .equatable()
                    }
                }
            }
        }
        .onAppear {
            transcriptDeliveryMode = TranscriptDeliveryMode.current()
            // Refresh download status; never overwrite the persisted selection here (#79).
            Task { await downloadService.refreshDownloadedModels() }
        }
        .onChange(of: selectedModel) { _, variant in
            if StreamingMode.disableIfIncompatible(with: variant) {
                transcriptDeliveryMode = .autoPaste
            }
        }
    }
}

// MARK: - LLM Instructions tab

private struct LLMInstructionsTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LLM Instructions")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Color.textPrimary)
                Text("How the cleanup model edits your transcripts — pick a built-in effort level or write your own rulesets.")
                    .font(Typography.ui(13))
                    .foregroundStyle(Color.textMuted)
            }

            TranscriptCleanupAISection()
        }
    }
}

#Preview {
    AIModelsView().frame(width: 900, height: 900).background(Color.bgApp)
}
