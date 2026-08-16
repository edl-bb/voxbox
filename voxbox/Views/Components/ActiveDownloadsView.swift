import SwiftUI

/// Surfaces in-flight model downloads anywhere in the app.
///
/// Model downloads used to be visible only inside Settings → AI Models; from
/// everywhere else they were invisible background work. This view renders a
/// compact card per active download — model name, progress bar, percentage —
/// and disappears entirely when nothing is downloading. It lives in the
/// sidebar and the menu bar dashboard so a download is always discoverable.
struct ActiveDownloadsView: View {
    private let downloadService = ModelDownloadService.shared
    @AppStorage(ModelSelection.defaultsKey) private var selectedModel: String = ModelSelection.none
    @State private var loadingVariant: String?

    private var activeVariants: [String] {
        let downloading = downloadService.isDownloading
            .filter { $0.value }
            .map(\.key)
        let completed = downloadService.recentlyCompleted.filter { variant in
            downloadService.isDownloading[variant] != true
        }
        return Array(Set(downloading + completed)).sorted()
    }

    private var hasActiveDownload: Bool {
        downloadService.isDownloading.contains { $0.value }
    }

    private var headerTitle: String {
        if hasActiveDownload {
            return activeVariants.count == 1 ? "Downloading model" : "Downloading models"
        }
        return activeVariants.count == 1 ? "Download complete" : "Downloads complete"
    }

    private var headerIcon: String {
        hasActiveDownload ? "arrow.down.circle" : "checkmark.circle.fill"
    }

    private var headerTint: Color {
        hasActiveDownload ? Color.accentBlue : Color.accentSuccess
    }

    private func displayName(for variant: String) -> String {
        AIModel.availableModels.first(where: { $0.variant == variant })?.name ?? variant
    }

    var body: some View {
        if !activeVariants.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: headerIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(headerTint)
                    Text(headerTitle)
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textSecondary)
                }

                ForEach(activeVariants, id: \.self) { variant in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName(for: variant))
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        if downloadService.isDownloading[variant] == true {
                            AnimatedDownloadMeter(
                                targetFraction: downloadService.downloadProgress[variant] ?? 0,
                                status: downloadService.downloadStatus[variant],
                                usesCapsuleBar: false
                            )
                        } else {
                            DownloadCompleteBanner(
                                compact: true,
                                isLoading: loadingVariant == variant,
                                loadingStage: TranscriptionManager.shared.loadingStage,
                                onStartUsing: { startUsing(variant) }
                            )
                        }
                    }
                    .animation(.easeInOut(duration: 0.4), value: downloadService.isDownloading[variant])
                }
            }
            .padding(10)
            .background(Color.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.border.opacity(0.6), lineWidth: 1)
            )
        }
    }

    private func startUsing(_ variant: String) {
        loadingVariant = variant
        Task {
            do {
                try await TranscriptionManager.shared.loadModel(variant: variant)
                await MainActor.run {
                    selectedModel = variant
                    downloadService.acknowledgeCompletedDownload(for: variant)
                    loadingVariant = nil
                }
            } catch {
                await MainActor.run {
                    loadingVariant = nil
                    DashboardRoute.reveal(.aiModels)
                }
            }
        }
    }
}
