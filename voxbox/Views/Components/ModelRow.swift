import SwiftUI

/// A single AI-model card. Clean two-font layout (Clash Display for the name,
/// Satoshi for everything else) with a single logo-blue accent.
struct ModelRow: View, Equatable {
    let model: AIModel
    @Binding var selectedModel: String
    /// Highlights this card as the engine's recommendation for this Mac.
    var isRecommended: Bool = false
    let snapshot: ModelDownloadSnapshot

    private var transcription: TranscriptionManager { TranscriptionManager.shared }
    private var downloadService: ModelDownloadService { ModelDownloadService.shared }

    static func == (lhs: ModelRow, rhs: ModelRow) -> Bool {
        lhs.model == rhs.model
            && lhs.selectedModel == rhs.selectedModel
            && lhs.isRecommended == rhs.isRecommended
            && lhs.snapshot == rhs.snapshot
    }

    @State private var isLoadingModel = false
    @State private var loadError: String?
    @State private var loadingStartTime: Date?
    @State private var loadingElapsed: TimeInterval = 0
    @State private var loadingTimer: Timer?
    @State private var isHovered = false
    @State private var appeared = false

    // MARK: - Derived state

    var progress: Double { snapshot.progress }
    var isDownloading: Bool { snapshot.isDownloading }
    var isDownloaded: Bool { progress >= 1.0 }
    var isActive: Bool { selectedModel == model.variant }
    var justCompleted: Bool {
        ModelDownloadCompletion.isHighlighted(
            downloaded: isDownloaded,
            active: isActive,
            recentlyCompleted: snapshot.recentlyCompleted
        )
    }

    private var cardFill: Color {
        if justCompleted { return Color.accentSuccess.opacity(0.10) }
        if isActive { return Color.brandAccentSoft }
        return Color.bgCard
    }

    private var cardStroke: Color {
        if justCompleted { return Color.accentSuccess.opacity(0.55) }
        if isActive { return Color.brandAccent.opacity(0.4) }
        return Color.border.opacity(isHovered ? 1.0 : 0.5)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    titleRow
                    Text(model.details)
                        .font(Typography.ui(12))
                        .foregroundStyle(Color.textSecondary)

                    // One compact line: size chip + the two metric bars.
                    HStack(spacing: 14) {
                        chip(icon: "internaldrive", text: model.size)
                        MetricBars(model: model, appeared: appeared)
                    }

                    if let warning = model.ramWarning(deviceRAMGB: WhisperService.deviceRAMGB) {
                        note(icon: "exclamationmark.triangle.fill", text: warning, tint: .accentWarning)
                    }
                    if let loadError {
                        note(icon: "xmark.circle.fill", text: loadError, tint: .accentError)
                    }
                }

                Spacer(minLength: 8)

                actionColumn
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if isDownloading {
                downloadProgressSection
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if justCompleted {
                DownloadCompleteBanner(
                    isLoading: isLoadingModel,
                    loadingStage: transcription.loadingStage,
                    onStartUsing: loadAndSelectModel
                )
                .padding(.horizontal, 16).padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(cardStroke, lineWidth: justCompleted || isActive ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(isHovered ? 0.09 : 0.03),
                radius: isHovered ? 14 : 6, x: 0, y: isHovered ? 6 : 2)
        .animation(.easeInOut(duration: 0.45), value: isDownloading)
        .animation(.easeInOut(duration: 0.45), value: justCompleted)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .animation(.easeOut(duration: 0.16), value: isActive)
        .onHover { isHovered = $0 }
        .onAppear { withAnimation(.easeOut(duration: 0.5).delay(0.05)) { appeared = true } }
    }

    // MARK: - Header

    private var titleRow: some View {
        HStack(spacing: 9) {
            Text(model.name)
                .font(Typography.modelName)
                .foregroundStyle(Color.textPrimary)

            LanguageBadge(isEnglishOnly: model.isEnglishOnly)
            StreamingCapabilityBadge(supportsStreaming: StreamingMode.modelSupportsStreaming(model.variant))

            if isRecommended {
                statusBadge(text: "Recommended", icon: "sparkles", tint: Color.brandAccent)
            }

            if isActive && isDownloaded {
                statusBadge(text: "Selected", icon: "checkmark", tint: Color.brandAccent)
            } else if justCompleted {
                statusBadge(text: "Ready", icon: "checkmark.circle.fill", tint: Color.accentSuccess)
            } else if isDownloaded {
                statusBadge(text: "Installed", icon: "arrow.down.circle.fill",
                            tint: Color.textMuted)
            }
        }
    }

    private func statusBadge(text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(Typography.uiBold(10)).textCase(.uppercase).tracking(0.5)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .foregroundStyle(tint)
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(Typography.uiMedium(12))
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.textPrimary.opacity(0.05)))
    }

    private func note(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(Typography.ui(11)).lineLimit(2)
        }
        .foregroundStyle(tint)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionColumn: some View {
        HStack(spacing: 8) {
            if isDownloaded {
                if isActive || justCompleted {
                    // Selected badge, or the completion banner holds the Use prompt.
                    EmptyView()
                } else if isLoadingModel {
                    loadingIndicator
                } else {
                    Button(action: loadAndSelectModel) {
                        ActionButton.label(title: "Use", icon: "arrow.right", style: .secondary)
                    }
                    .buttonStyle(.plain).help("Set as default model")
                }
                if model.engine != .apple {
                    Button(action: deleteModel) {
                        Image(systemName: "trash").font(.system(size: 13))
                            .foregroundStyle(Color.textMuted).padding(8)
                            .background(Circle().fill(Color.textPrimary.opacity(isHovered ? 0.06 : 0)))
                    }
                    .buttonStyle(.plain).help("Delete model")
                }
            } else if isDownloading {
                Button(action: { downloadService.cancelDownload(for: model.variant) }) {
                    ActionButton.label(title: "Cancel", icon: "xmark", style: .secondary)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: { downloadService.downloadModel(variant: model.variant) }) {
                    ActionButton.label(title: "Download", icon: "arrow.down", style: .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var loadingIndicator: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 9) {
                Spinner(size: 13, lineWidth: 2, tint: Color.textSecondary)
                Text(
                    transcription.loadingStage.isEmpty
                        ? ModelLoadCopy.preparing : transcription.loadingStage
                )
                    .font(Typography.uiMedium(12))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.leading, 12).padding(.trailing, 15).padding(.vertical, 8)
            .background(Capsule().fill(Color.textPrimary.opacity(0.08)))
            .foregroundStyle(Color.textSecondary)

            Text(loadingElapsed > 45 ? ModelLoadCopy.takingLonger : ModelLoadCopy.firstLoadHint)
                .font(Typography.ui(10))
                .foregroundStyle(loadingElapsed > 45 ? Color.accentWarning : Color.textMuted)
        }
        .help(ModelLoadCopy.firstLoadHint)
    }

    private var downloadProgressSection: some View {
        AnimatedDownloadMeter(
            targetFraction: progress,
            status: snapshot.status
        )
        .padding(.horizontal, 16).padding(.bottom, 14)
    }

    // MARK: - Logic

    private func deleteModel() {
        Task {
            _ = await downloadService.deleteModel(variant: model.variant)
            if selectedModel == model.variant { selectedModel = ModelSelection.none }
        }
    }

    private func loadAndSelectModel() {
        isLoadingModel = true
        loadError = nil
        loadingStartTime = Date()
        loadingElapsed = 0
        loadingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if let start = loadingStartTime { loadingElapsed = Date().timeIntervalSince(start) }
        }
        Task {
            do {
                try await transcription.loadModel(variant: model.variant)
                await MainActor.run {
                    stopLoadingTimer()
                    isLoadingModel = false
                    selectedModel = model.variant
                    downloadService.acknowledgeCompletedDownload(for: model.variant)
                }
            } catch {
                await MainActor.run {
                    stopLoadingTimer()
                    isLoadingModel = false
                    if isMissingDownload(error) {
                        downloadService.downloadProgress[model.variant] = 0
                        loadError = nil
                    } else {
                        loadError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func isMissingDownload(_ error: Error) -> Bool {
        if let engineError = error as? ParakeetEngineError,
            case .modelNotDownloaded = engineError
        {
            return true
        }
        if let appleError = error as? AppleSpeechEngineError,
            case .assetsNotInstalled = appleError
        {
            return true
        }
        return false
    }

    private func stopLoadingTimer() {
        loadingTimer?.invalidate(); loadingTimer = nil
        loadingStartTime = nil; loadingElapsed = 0
    }
}

// MARK: - Language differentiator badge

/// The single most decision-relevant trait at a glance: multilingual vs English.
struct LanguageBadge: View {
    let isEnglishOnly: Bool

    var body: some View {
        let tint = isEnglishOnly ? Color.textMuted : Color.brandAccent
        Text(isEnglishOnly ? "ENGLISH" : "MULTILINGUAL")
            .font(Typography.uiBold(9)).tracking(0.6)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.14)))
            .foregroundStyle(tint)
    }
}

/// A yes/no capability marker: "✓ STREAMING" / "✗ STREAMING" (SF Symbols,
/// not emoji). The capability name stays constant so rows scan vertically;
/// only the mark and tint change.
struct CapabilityBadge: View {
    let name: String
    let supported: Bool

    var body: some View {
        let tint = supported ? Color.accentSuccess : Color.textMuted
        HStack(spacing: 3) {
            Image(systemName: supported ? "checkmark" : "xmark")
                .font(.system(size: 8, weight: .bold))
            Text(name.uppercased())
                .font(Typography.uiBold(9)).tracking(0.6)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .foregroundStyle(tint)
        .help(supported ? "Supports \(name.lowercased())" : "No \(name.lowercased()) support")
    }
}

struct StreamingCapabilityBadge: View {
    let supportsStreaming: Bool

    var body: some View {
        CapabilityBadge(name: "Streaming", supported: supportsStreaming)
    }
}

// MARK: - Shared metric bars

/// A single calm, continuous metric bar with a qualitative tier word.
/// No false-precision decimals, no gamified LED pips.
struct MetricBar: View {
    let label: String
    let tier: String
    let value: Double
    let tint: Color
    var appeared: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(Typography.uiBold(9)).tracking(0.8)
                    .foregroundStyle(Color.textMuted)
                Text(tier)
                    .font(Typography.uiBold(11))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.textPrimary.opacity(0.07)).frame(height: 6)
                    Capsule()
                        .fill(tint.opacity(0.7))
                        .frame(width: geo.size.width * (appeared ? value / 10.0 : 0), height: 6)
                        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: appeared)
                }
            }
            .frame(height: 6)
        }
    }
}

/// Speed + accuracy side by side — the card layout.
struct MetricBars: View {
    let model: AIModel
    var appeared: Bool = true

    var body: some View {
        HStack(spacing: 16) {
            MetricBar(label: "Speed", tier: model.speedTier, value: model.speed,
                      tint: .brandAccent, appeared: appeared).frame(width: 116)
            MetricBar(label: "Accuracy", tier: model.accuracyTier, value: model.accuracy,
                      tint: .brandAccent, appeared: appeared).frame(width: 116)
        }
    }
}

// MARK: - Shared action button label

/// One consistent button treatment used by both the hero and the cards, so the
/// same action never looks like three different buttons.
enum ActionButton {
    enum Style { case primary, secondary, success }

    static func label(title: String, icon: String?, style: Style, large: Bool = false) -> some View {
        HStack(spacing: 7) {
            Text(title).font(Typography.uiBold(large ? 14 : 13))
            if let icon { Image(systemName: icon).font(.system(size: large ? 12 : 11, weight: .bold)) }
        }
        .padding(.horizontal, large ? 22 : 16)
        .padding(.vertical, large ? 12 : 9)
        .background(Capsule().fill(fill(for: style)))
        .foregroundStyle(style == .secondary ? Color.textPrimary : Color.bgApp)
    }

    private static func fill(for style: Style) -> Color {
        switch style {
        case .primary: return Color.accentPrimary
        case .secondary: return Color.textPrimary.opacity(0.06)
        case .success: return Color.accentSuccess
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        ModelRow(
            model: AIModel.availableModels.first { $0.engine == .parakeet }!,
            selectedModel: .constant("x"),
            isRecommended: true,
            snapshot: ModelDownloadSnapshot.make(
                progress: 0, isDownloading: false, status: nil, recentlyCompleted: false, error: nil)
        )
        ModelRow(
            model: AIModel.availableModels[0],
            selectedModel: .constant("x"),
            snapshot: ModelDownloadSnapshot.make(
                progress: 0, isDownloading: false, status: nil, recentlyCompleted: false, error: nil)
        )
    }
    .padding()
    .frame(width: 640)
    .background(Color.bgApp)
}
