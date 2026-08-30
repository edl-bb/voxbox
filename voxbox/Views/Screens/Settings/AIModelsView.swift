import SwiftUI

/// Screen for choosing the on-device transcription model and configuring the
/// AI cleanup pass. Every model is a row in one flat catalog — capability
/// badges (multilingual, streaming ✓/✗) on each card replace the old
/// hero banner and the All/Streaming/Batch filter.
struct AIModelsView: View {
    private let downloadService = ModelDownloadService.shared
    @AppStorage(ModelSelection.defaultsKey) private var selectedModel: String = ModelSelection.none
    @AppStorage(TranscriptDeliveryMode.defaultsKey)
    private var transcriptDeliveryMode: TranscriptDeliveryMode = .autoPaste

    /// Keeps the content from stretching edge-to-edge on a wide window, so the
    /// name and its action never sit at opposite ends of a huge empty band.
    private let maxContentWidth: CGFloat = 940

    // MARK: - Derived

    private var capability: DeviceCapability { .current }
    private var selectedModelObject: AIModel? {
        AIModel.availableModels.first { $0.variant == selectedModel }
    }

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

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                currentStrip
                listSection
                cleanupSection
            }
            .frame(maxWidth: maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(Color.clear)
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

    // MARK: - Current model strip

    /// Always-visible "what am I using right now", so the active model isn't
    /// buried in the list.
    private var currentStrip: some View {
        let sel = selectedModelObject
        return HStack(spacing: 13) {
            ZStack {
                Circle().fill(Color.brandAccentSoft)
                Image(systemName: sel == nil ? "questionmark" : "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.brandAccent)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("CURRENTLY USING")
                    .font(Typography.uiBold(10)).tracking(1.2)
                    .foregroundStyle(Color.textMuted)
                Text(sel?.name ?? "No model selected yet")
                    .font(Typography.uiBold(16))
                    .foregroundStyle(sel == nil ? Color.textMuted : Color.textPrimary)
            }

            if let sel {
                LanguageBadge(isEnglishOnly: sel.isEnglishOnly)
                StreamingCapabilityBadge(
                    supportsStreaming: StreamingMode.modelSupportsStreaming(sel.variant))
            }

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                Image(systemName: "laptopcomputer").font(.system(size: 12))
                Text("Your Mac · \(capability.summary)")
                    .font(Typography.uiMedium(12))
            }
            .foregroundStyle(Color.textMuted)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.border.opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: - List

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speech models")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Color.textPrimary)
                Text("Apple Speech works out of the box. Download a model when you want a different speed, accuracy, or language trade-off.")
                    .font(Typography.ui(13))
                    .foregroundStyle(Color.textMuted)
            }

            ForEach(engineGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(group.title)
                            .font(Typography.sectionTitle)
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
    }

    // MARK: - Cleanup AI

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cleanup AI")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Color.textPrimary)
                Text("Runs after transcription, whichever speech model you use.")
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
