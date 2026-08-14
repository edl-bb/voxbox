import SwiftUI

/// Surfaces in-flight model downloads anywhere in the app.
///
/// Model downloads used to be visible only inside Settings → AI Models; from
/// everywhere else they were invisible background work. This view renders a
/// compact card per active download — model name, progress bar, percentage —
/// and disappears entirely when nothing is downloading. It lives in the
/// sidebar and the menu bar dashboard so a download is always discoverable.
struct ActiveDownloadsView: View {
    @ObservedObject private var downloadService = ModelDownloadService.shared

    private var activeVariants: [String] {
        downloadService.isDownloading
            .filter { $0.value }
            .keys
            .sorted()
    }

    private func displayName(for variant: String) -> String {
        AIModel.availableModels.first(where: { $0.variant == variant })?.name ?? variant
    }

    var body: some View {
        if !activeVariants.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentBlue)
                    Text(activeVariants.count == 1 ? "Downloading model" : "Downloading models")
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textSecondary)
                }

                ForEach(activeVariants, id: \.self) { variant in
                    let progress = downloadService.downloadProgress[variant] ?? 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(displayName(for: variant))
                                .font(Typography.captionSmall)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(Int(progress * 100))%")
                                .font(Typography.captionSmall)
                                .foregroundStyle(Color.textSecondary)
                                .monospacedDigit()
                        }
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .tint(Color.accentBlue)
                    }
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
}
