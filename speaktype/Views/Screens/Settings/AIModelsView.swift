import SwiftUI

/// Screen for managing AI transcription models
struct AIModelsView: View {
    // MARK: - Properties

    @StateObject private var downloadService = ModelDownloadService.shared
    @AppStorage(ModelSelection.defaultsKey) private var selectedModel: String = ModelSelection.none
    @AppStorage("modelUseCase") private var useCaseRaw: String = AIModel.UseCase.dictation.rawValue
    @State private var models = AIModel.availableModels

    // MARK: - Computed Properties

    private var capability: DeviceCapability { .current }

    private var useCase: AIModel.UseCase {
        AIModel.UseCase(rawValue: useCaseRaw) ?? .dictation
    }

    private var recommendedModel: AIModel {
        AIModel.recommendedModel(for: capability, useCase: useCase)
    }

    var selectedModelName: String {
        models.first(where: { $0.variant == selectedModel })?.name ?? "No model downloaded yet"
    }

    private func isDownloaded(_ variant: String) -> Bool {
        (downloadService.downloadProgress[variant] ?? 0) >= 1.0
    }

    private var hasAnyModelDownloaded: Bool {
        downloadService.downloadProgress.values.contains { $0 >= 1.0 }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection

                recommendationCard

                // Show setup banner if no model downloaded
                if !hasAnyModelDownloaded {
                    setupBanner
                }

                currentModelCard
                modelsListSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(Color.clear)
        .onAppear {
            // Refresh model download status when view appears.
            // We deliberately do NOT overwrite `selectedModel` here: the disk scan is
            // async and a transient miss used to wipe the persisted selection on every
            // launch (#79). The selection only changes on explicit user actions —
            // picking a model, or deleting the currently-selected one.
            Task {
                await downloadService.refreshDownloadedModels()
            }
        }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI Models")
                .font(Typography.displayLarge)
                .foregroundStyle(Color.textPrimary)

            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textMuted)
                Text(capability.summary)
                    .font(Typography.bodySmall)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    /// Hero card: a use-case picker plus the model we recommend for this Mac,
    /// re-scored live as the use case changes.
    private var recommendationCard: some View {
        let rec = recommendedModel
        let downloaded = isDownloaded(rec.variant)
        let isActive = selectedModel == rec.variant

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Recommended for you", systemImage: "sparkles")
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
            }

            // Use-case selector — changes the speed/accuracy trade-off.
            Picker("", selection: $useCaseRaw) {
                ForEach(AIModel.UseCase.allCases) { uc in
                    Text(uc.title).tag(uc.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(rec.name)
                        .font(Typography.headlineMedium)
                        .foregroundStyle(Color.textPrimary)

                    Text(AIModel.recommendationReason(for: rec, capability: capability, useCase: useCase))
                        .font(Typography.bodySmall)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 14) {
                        recMeta(
                            icon: rec.isEnglishOnly ? "character.book.closed" : "globe",
                            text: rec.languageSupportLabel)
                        recMeta(icon: "arrow.down.circle", text: rec.size)
                    }
                    .padding(.top, 2)
                    .foregroundStyle(Color.textMuted)
                }

                Spacer()

                // Primary action reflects current state.
                if isActive && downloaded {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .font(Typography.buttonLabelSmall)
                        .foregroundStyle(Color.textSecondary)
                } else if downloaded {
                    Button {
                        selectedModel = rec.variant
                    } label: {
                        Text("Use")
                            .font(Typography.buttonLabelSmall)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.white)
                            .foregroundStyle(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        downloadService.downloadModel(variant: rec.variant)
                    } label: {
                        Label("Download", systemImage: "arrow.down")
                            .font(Typography.buttonLabelSmall)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.white)
                            .foregroundStyle(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.textPrimary.opacity(0.25), lineWidth: 1)
        )
    }

    private func recMeta(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(text)
                .font(Typography.cardMeta)
        }
    }

    private var currentModelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default Model")
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)

            Text(selectedModelName)
                .font(Typography.headlineMedium)
                .foregroundStyle(Color.textPrimary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.border.opacity(0.5), lineWidth: 1)
        )
        .cardShadow()
    }

    private var modelsListSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Available Models")
                .font(Typography.headlineLarge)
                .foregroundStyle(Color.textPrimary)

            VStack(spacing: 12) {
                ForEach($models) { $model in
                    ModelRow(model: $model, selectedModel: $selectedModel)
                }
            }
        }
    }

    private var setupBanner: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.textPrimary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Download a Model to Get Started")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)

                Text(
                    "Choose a model below to enable voice transcription. We recommend **\(recommendedModel.name)** for your \(capability.chipName)."
                )
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
            }

            Spacer()
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.textPrimary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.textPrimary.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Preview

#Preview {
    AIModelsView()
        .background(Color.black)
}
