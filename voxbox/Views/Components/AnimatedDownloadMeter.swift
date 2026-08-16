import SwiftUI

/// Download progress for the model card and sidebar tile.
///
/// New byte samples arrive from the download service a few times a second.
/// The bar and counts ease between those samples with SwiftUI animation
/// (Core Animation, display refresh). There is no app-wide or tile FPS
/// timer — a main-thread display timer was hitching the rest of the window.
struct AnimatedDownloadMeter: View {
    let targetFraction: Double
    let status: ModelDownloadStatus?
    var showsSubtitle = true
    var usesCapsuleBar = true

    var body: some View {
        VStack(alignment: .leading, spacing: usesCapsuleBar ? 8 : 4) {
            HStack {
                Text(title)
                    .font(usesCapsuleBar ? Typography.uiMedium(12) : Typography.captionSmall)
                    .foregroundStyle(usesCapsuleBar ? Color.textSecondary : Color.textMuted)
                    .lineLimit(1)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                Text(ModelDownloadFormatting.percent(targetFraction))
                    .font(usesCapsuleBar ? Typography.uiBold(11) : Typography.captionSmall)
                    .foregroundStyle(usesCapsuleBar ? Color.brandAccent : Color.textSecondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            bar
            if showsSubtitle, let subtitle = status?.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(usesCapsuleBar ? Typography.ui(11) : Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
            }
        }
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private var bar: some View {
        if usesCapsuleBar {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.textPrimary.opacity(0.08)).frame(height: 6)
                    Capsule()
                        .fill(Color.brandAccent)
                        .frame(width: max(6, geo.size.width * targetFraction), height: 6)
                        .animation(
                            .easeInOut(duration: DownloadProgressEasing.duration),
                            value: targetFraction
                        )
                }
            }
            .frame(height: 6)
        } else {
            ProgressView(value: targetFraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(Color.accentBlue)
                .animation(
                    .easeInOut(duration: DownloadProgressEasing.duration),
                    value: targetFraction
                )
        }
    }

    private var title: String {
        if let status {
            switch status.phase {
            case .downloading where status.totalBytes > 0:
                return ModelDownloadFormatting.bytesTitle(
                    received: status.receivedBytes, total: status.totalBytes)
            default:
                return status.title
            }
        }
        return "Downloading…"
    }
}

/// Green “ready to use” panel shown after a download finishes.
struct DownloadCompleteBanner: View {
    var compact = false
    var isLoading = false
    var loadingStage: String = ""
    let onStartUsing: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: compact ? 18 : 22, weight: .semibold))
                    .foregroundStyle(Color.accentSuccess)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download complete")
                        .font(compact ? Typography.uiBold(12) : Typography.uiBold(14))
                        .foregroundStyle(Color.textPrimary)
                    Text("Ready to use on this Mac")
                        .font(compact ? Typography.captionSmall : Typography.ui(12))
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer(minLength: 8)
            }

            if isLoading {
                HStack(spacing: 8) {
                    Spinner(size: 13, lineWidth: 2, tint: Color.accentSuccess)
                    Text(loadingStage.isEmpty ? ModelLoadCopy.preparing : loadingStage)
                        .font(Typography.uiMedium(12))
                        .foregroundStyle(Color.textSecondary)
                }
            } else {
                Button(action: onStartUsing) {
                    ActionButton.label(
                        title: "Start using this model?",
                        icon: "arrow.right",
                        style: .success,
                        large: !compact
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous)
                .fill(Color.accentSuccess.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous)
                .stroke(Color.accentSuccess.opacity(0.45), lineWidth: 1)
        )
    }
}
