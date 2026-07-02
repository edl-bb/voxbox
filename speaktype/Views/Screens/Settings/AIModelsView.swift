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

    private var engineGroups: [(title: String, subtitle: String, models: [AIModel])] {
        [
            (title: "Parakeet", subtitle: "NVIDIA · fastest, near-Whisper accuracy",
             models: AIModel.models(for: .parakeet)),
            (title: "Whisper", subtitle: "OpenAI · most accurate, a touch slower",
             models: AIModel.models(for: .whisper)),
        ].filter { !$0.models.isEmpty }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                heroSection
                listSection
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 32)
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
                Text("RECOMMENDED FOR YOUR MAC")
                    .font(.system(size: 11, weight: .bold)).tracking(1.5)
                    .foregroundStyle(Color.textMuted)

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text("OPTIMIZE FOR")
                        .font(.system(size: 9, weight: .bold)).tracking(1)
                        .foregroundStyle(Color.textMuted)
                    Picker("", selection: $useCaseRaw) {
                        ForEach(AIModel.UseCase.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }
            }

            // The pick — big and editorial.
            Text(rec.name)
                .font(.system(size: 34, weight: .regular, design: .serif))
                .foregroundStyle(Color.textPrimary)
                .padding(.top, 16)

            Text(AIModel.recommendationReason(for: rec, capability: capability, useCase: useCase))
                .font(.system(size: 15))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            // Device context — plain language.
            HStack(spacing: 7) {
                Image(systemName: "cpu").font(.system(size: 12))
                Text(capability.summary).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.textMuted)
            .padding(.top, 14)

            // Primary action.
            heroAction(rec: rec, downloaded: downloaded, active: active)
                .padding(.top, 20)
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.textPrimary.opacity(0.06), Color.textPrimary.opacity(0.02)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.textPrimary.opacity(0.14), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func heroAction(rec: AIModel, downloaded: Bool, active: Bool) -> some View {
        if active && downloaded {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                Text("This is your default model").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color.textSecondary)
        } else if downloaded {
            heroButton(title: "Use this model", icon: "arrow.right") {
                selectedModel = rec.variant
            }
        } else {
            heroButton(title: "Download · \(rec.size)", icon: "arrow.down") {
                downloadService.downloadModel(variant: rec.variant)
            }
        }
    }

    private func heroButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Capsule().fill(Color.textPrimary))
            .foregroundStyle(Color.bgCard)
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(engineGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text(group.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text(group.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.textMuted)
                    }

                    ForEach(group.models) { model in
                        ModelRow(
                            model: model,
                            selectedModel: $selectedModel,
                            isRecommended: model.variant == recommendedModel.variant
                        )
                    }
                }
            }
        }
    }
}

#Preview {
    AIModelsView().frame(width: 720, height: 900).background(Color.bgApp)
}
