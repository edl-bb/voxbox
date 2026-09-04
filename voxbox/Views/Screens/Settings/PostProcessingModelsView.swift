import SwiftUI

/// The "Post-processing models" tab: pick which LLM cleans up transcripts,
/// and download/manage local models.
struct PostProcessingModelsView: View {
    @ObservedObject private var manager = PostProcessingModelManager.shared
    @AppStorage(TranscriptFormatterService.enabledKey)
    private var formatWithOnDeviceAI: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Post-processing models")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Color.textPrimary)
                Text(
                    PostProcessingModel.downloadableModelsEnabled
                        ? "The model that cleans up transcripts after transcription. Apple Intelligence is built in, or download a model to run the cleanup with instead."
                        : "The model that cleans up transcripts after transcription. Apple Intelligence is built into macOS and runs entirely on your Mac."
                )
                .font(Typography.ui(13))
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !PostProcessingModel.downloadableModelsEnabled {
                Label(
                    "Downloadable models such as Llama and Qwen are coming with macOS 27's native on-device model support.",
                    systemImage: "clock"
                )
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textMuted)
            }

            if !formatWithOnDeviceAI {
                Label(
                    "Cleanup AI is currently off — turn it on in the LLM Instructions tab (or Settings) to use these models.",
                    systemImage: "info.circle"
                )
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textMuted)
            }

            VStack(spacing: 10) {
                ForEach(PostProcessingModel.offered) { model in
                    PostProcessingModelRow(model: model, manager: manager)
                }
            }
        }
        .onAppear { manager.refreshDownloadedModels() }
    }
}

/// One cleanup-model card: compact single-block layout with capability
/// badges and the download/select/delete actions.
private struct PostProcessingModelRow: View {
    let model: PostProcessingModel
    @ObservedObject var manager: PostProcessingModelManager

    @State private var isHovered = false

    private var isSelected: Bool { manager.selectedVariant == model.variant }
    private var isDownloaded: Bool {
        model.kind == .appleSystem || manager.isDownloaded(model.variant)
    }
    private var isDownloading: Bool { manager.isDownloading(model.variant) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(Typography.uiBold(15))
                            .foregroundStyle(Color.textPrimary)

                        if isSelected {
                            selectedBadge
                        } else if model.kind == .mlx && isDownloaded {
                            downloadedBadge
                        }
                    }

                    Text("\(model.provider) • \(model.details)")
                        .font(Typography.ui(12))
                        .foregroundStyle(Color.textSecondary)

                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Image(systemName: "internaldrive").font(.system(size: 10))
                            Text(model.sizeLabel).font(Typography.uiMedium(11))
                        }
                        .foregroundStyle(Color.textMuted)

                        if let warning = model.ramWarning {
                            HStack(spacing: 5) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                Text(warning).font(Typography.ui(11))
                            }
                            .foregroundStyle(Color.accentWarning)
                        }

                        if let error = manager.downloadError[model.variant] {
                            HStack(spacing: 5) {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                                Text(error).font(Typography.ui(11))
                            }
                            .foregroundStyle(Color.accentError)
                        }
                    }
                }

                Spacer(minLength: 8)

                actions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if isDownloading {
                AnimatedDownloadMeter(
                    targetFraction: manager.downloadProgress[model.variant] ?? 0,
                    status: manager.downloadStatus[model.variant]
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.brandAccentSoft : Color.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected
                        ? Color.brandAccent.opacity(0.4)
                        : Color.border.opacity(isHovered ? 1.0 : 0.5),
                    lineWidth: isSelected ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var selectedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
            Text("SELECTED").font(Typography.uiBold(10)).tracking(0.5)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.brandAccent.opacity(0.14)))
        .foregroundStyle(Color.brandAccent)
    }

    private var downloadedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 9, weight: .bold))
            Text("DOWNLOADED").font(Typography.uiBold(10)).tracking(0.5)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.textMuted.opacity(0.14)))
        .foregroundStyle(Color.textMuted)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if isDownloading {
                Button {
                    manager.cancelDownload(variant: model.variant)
                } label: {
                    ActionButton.label(title: "Cancel", icon: "xmark", style: .secondary)
                }
                .buttonStyle(.plain)
            } else if !isDownloaded {
                Button {
                    manager.download(variant: model.variant)
                } label: {
                    ActionButton.label(title: "Download", icon: "arrow.down", style: .primary)
                }
                .buttonStyle(.plain)
            } else {
                if !isSelected {
                    Button {
                        manager.selectedVariant = model.variant
                    } label: {
                        ActionButton.label(title: "Use", icon: "arrow.right", style: .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Use this model for transcript cleanup")
                }
                if model.kind == .mlx {
                    Button {
                        manager.deleteModel(variant: model.variant)
                    } label: {
                        Image(systemName: "trash").font(.system(size: 13))
                            .foregroundStyle(Color.textMuted).padding(8)
                            .background(
                                Circle().fill(Color.textPrimary.opacity(isHovered ? 0.06 : 0)))
                    }
                    .buttonStyle(.plain).help("Delete downloaded model")
                }
            }
        }
    }
}

#Preview {
    PostProcessingModelsView()
        .padding()
        .frame(width: 800)
        .background(Color.bgApp)
}
