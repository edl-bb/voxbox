import SwiftUI

/// Screen for choosing the on-device transcription model.
struct AIModelsView: View {
    @StateObject private var downloadService = ModelDownloadService.shared
    @AppStorage(ModelSelection.defaultsKey) private var selectedModel: String = ModelSelection.none
    @AppStorage("modelUseCase") private var useCaseRaw: String = AIModel.UseCase.dictation.rawValue

    // MARK: - Derived

    private var capability: DeviceCapability { .current }
    private var useCase: AIModel.UseCase { AIModel.UseCase(rawValue: useCaseRaw) ?? .dictation }
    private var recommendedModel: AIModel { AIModel.recommendedModel(for: capability, useCase: useCase) }

    private func isDownloaded(_ variant: String) -> Bool {
        (downloadService.downloadProgress[variant] ?? 0) >= 1.0
    }

    /// Engine groups for the list — the recommended model is intentionally left
    /// out here because it already headlines the hero (no more duplication).
    private var engineGroups: [(title: String, subtitle: String, models: [AIModel])] {
        [
            (title: "Parakeet", subtitle: "NVIDIA · fastest, near-Whisper accuracy",
             models: AIModel.models(for: .parakeet)),
            (title: "Whisper", subtitle: "OpenAI · most accurate, a touch slower",
             models: AIModel.models(for: .whisper)),
        ]
        .map { ($0.title, $0.subtitle, $0.models.filter { $0.variant != recommendedModel.variant }) }
        .filter { !$0.2.isEmpty }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                heroSection
                listSection
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
        .background(Color.clear)
        .onAppear {
            // Refresh download status; never overwrite the persisted selection here (#79).
            Task { await downloadService.refreshDownloadedModels() }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        let rec = recommendedModel
        let downloaded = isDownloaded(rec.variant)
        let active = selectedModel == rec.variant

        return VStack(alignment: .leading, spacing: 0) {
            // Eyebrow + optimize selector
            HStack(alignment: .top) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                    Text("RECOMMENDED FOR YOU")
                        .font(Typography.uiBold(11)).tracking(1.4)
                }
                .foregroundStyle(Color.brandIndigo)

                Spacer()

                VStack(alignment: .trailing, spacing: 7) {
                    Text("OPTIMIZE FOR")
                        .font(Typography.uiBold(9)).tracking(1)
                        .foregroundStyle(Color.textMuted)
                    Picker("", selection: $useCaseRaw) {
                        ForEach(AIModel.UseCase.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260)
                }
            }

            // The pick — big, in the display face.
            Text(rec.name)
                .font(Typography.heroName)
                .foregroundStyle(Color.textPrimary)
                .padding(.top, 18)

            Text(AIModel.recommendationReason(for: rec, capability: capability, useCase: useCase))
                .font(Typography.ui(15))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            // Metrics for the pick.
            MetricBars(model: rec)
                .padding(.top, 18)

            // Device context — explicitly labelled as *your* Mac, not a requirement.
            HStack(spacing: 7) {
                Image(systemName: "laptopcomputer").font(.system(size: 12))
                Text("Your Mac · \(capability.summary)")
                    .font(Typography.uiMedium(12))
            }
            .foregroundStyle(Color.textMuted)
            .padding(.top, 16)

            // Primary action.
            heroAction(rec: rec, downloaded: downloaded, active: active)
                .padding(.top, 22)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.brandIndigo.opacity(0.07), Color.brandIndigo.opacity(0.0)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.brandIndigo.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.brandIndigo.opacity(0.10), radius: 20, x: 0, y: 8)
    }

    @ViewBuilder
    private func heroAction(rec: AIModel, downloaded: Bool, active: Bool) -> some View {
        if active && downloaded {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                Text("This is your default model").font(Typography.uiBold(13))
            }
            .foregroundStyle(Color.brandIndigo)
        } else if downloaded {
            Button {
                selectedModel = rec.variant
            } label: {
                ActionButton.label(title: "Use this model", icon: "arrow.right",
                                   style: .primary, large: true)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                downloadService.downloadModel(variant: rec.variant)
            } label: {
                ActionButton.label(title: "Download", icon: "arrow.down",
                                   style: .primary, large: true)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - List

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("More models")
                .font(Typography.sectionTitle)
                .foregroundStyle(Color.textPrimary)

            ForEach(engineGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                            isRecommended: false
                        )
                    }
                }
            }
        }
    }
}

#Preview {
    AIModelsView().frame(width: 820, height: 900).background(Color.bgApp)
}
