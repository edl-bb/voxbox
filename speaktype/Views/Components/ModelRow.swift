import SwiftUI

/// A single AI-model card. Editorial layout with gamified speed/accuracy meters.
struct ModelRow: View {
    let model: AIModel
    @Binding var selectedModel: String
    /// Highlights this card as the engine's recommendation for this Mac.
    var isRecommended: Bool = false

    @ObservedObject var downloadService = ModelDownloadService.shared
    private var transcription: TranscriptionManager { TranscriptionManager.shared }

    @State private var isLoadingModel = false
    @State private var loadError: String?
    @State private var loadingStartTime: Date?
    @State private var loadingElapsed: TimeInterval = 0
    @State private var loadingTimer: Timer?
    @State private var isHovered = false
    @State private var appeared = false

    // MARK: - Derived state

    var progress: Double { downloadService.downloadProgress[model.variant] ?? 0.0 }
    var isDownloading: Bool { downloadService.isDownloading[model.variant] ?? false }
    var isDownloaded: Bool { progress >= 1.0 }
    var isActive: Bool { selectedModel == model.variant }

    private var speedTint: Color { Color(red: 0.98, green: 0.62, blue: 0.11) }   // amber
    private var accuracyTint: Color { Color(red: 0.20, green: 0.74, blue: 0.51) } // green

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    titleRow
                    Text(model.details)
                        .font(Typography.cardDescription)
                        .foregroundStyle(Color.textSecondary)
                    metaRow
                    meters

                    if let warning = model.ramWarning(deviceRAMGB: WhisperService.deviceRAMGB) {
                        note(icon: "exclamationmark.triangle.fill", text: warning, tint: .orange)
                    }
                    if let loadError {
                        note(icon: "xmark.circle.fill", text: loadError, tint: .red)
                    }
                }

                Spacer(minLength: 8)

                actionColumn
            }
            .padding(20)

            if isDownloading { downloadProgressSection }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isActive ? Color.textPrimary.opacity(0.045) : Color.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    isActive ? Color.textPrimary.opacity(0.5)
                        : Color.border.opacity(isHovered ? 1.0 : 0.5),
                    lineWidth: isActive ? 1.5 : 1
                )
        )
        .shadow(color: .black.opacity(isHovered ? 0.10 : 0.04),
                radius: isHovered ? 14 : 6, x: 0, y: isHovered ? 6 : 2)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .animation(.easeOut(duration: 0.16), value: isActive)
        .onHover { isHovered = $0 }
        .onAppear { withAnimation(.easeOut(duration: 0.5).delay(0.05)) { appeared = true } }
    }

    // MARK: - Header

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(model.name)
                .font(Typography.cardTitle)
                .foregroundStyle(Color.textPrimary)

            enginePill

            if isRecommended {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
                    Text("PICK").font(.system(size: 9, weight: .bold)).tracking(0.6)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5))
                .foregroundStyle(Color.accentColor)
            }

            if isActive && isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(Color.textPrimary)
            }
        }
    }

    private var enginePill: some View {
        Text(model.engine == .parakeet ? "PARAKEET" : "WHISPER")
            .font(.system(size: 9, weight: .bold)).tracking(0.8)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.textPrimary.opacity(0.07)))
            .foregroundStyle(Color.textMuted)
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            chip(icon: model.isEnglishOnly ? "character.book.closed" : "globe",
                 text: model.languageSupportLabel)
            chip(icon: "internaldrive", text: model.size)
        }
    }

    private func chip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(Typography.cardMeta)
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.textPrimary.opacity(0.05)))
    }

    // MARK: - Gamified meters

    private var meters: some View {
        HStack(spacing: 22) {
            meter(title: "SPEED", value: model.speed, tier: model.speedTier, tint: speedTint)
            meter(title: "ACCURACY", value: model.accuracy, tier: model.accuracyTier, tint: accuracyTint)
        }
        .padding(.top, 2)
    }

    private func meter(title: String, value: Double, tier: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 9, weight: .bold)).tracking(0.8)
                    .foregroundStyle(Color.textMuted)
                Text(tier)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Text(String(format: "%.1f", value))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.textPrimary)
            }

            // Segmented meter — 10 pips, filled proportionally. Reads like a game bar.
            HStack(spacing: 2) {
                ForEach(0..<10) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Double(i) < value ? tint : Color.textPrimary.opacity(0.08))
                        .frame(height: 5)
                        .scaleEffect(x: appeared ? 1 : 0, anchor: .leading)
                        .animation(
                            .spring(response: 0.5, dampingFraction: 0.8).delay(Double(i) * 0.02),
                            value: appeared)
                }
            }
        }
        .frame(width: 150)
    }

    private func note(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11)).lineLimit(2)
        }
        .foregroundStyle(tint)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionColumn: some View {
        HStack(spacing: 8) {
            if isDownloaded {
                if isActive {
                    pill(text: "Selected", icon: "checkmark", filled: true)
                } else if isLoadingModel {
                    loadingIndicator
                } else {
                    Button(action: loadAndSelectModel) { pill(text: "Use", icon: nil, filled: false) }
                        .buttonStyle(.plain).help("Set as default model")
                }
                Button(action: deleteModel) {
                    Image(systemName: "trash").font(.system(size: 13))
                        .foregroundStyle(Color.textMuted).padding(8)
                        .background(Circle().fill(Color.textPrimary.opacity(isHovered ? 0.06 : 0)))
                }
                .buttonStyle(.plain).help("Delete model")
            } else if isDownloading {
                Button(action: { downloadService.cancelDownload(for: model.variant) }) {
                    pill(text: "Cancel", icon: "xmark", filled: false)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: { downloadService.downloadModel(variant: model.variant) }) {
                    pill(text: "Download", icon: "arrow.down", filled: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var loadingIndicator: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7).frame(width: 12, height: 12)
                Text(transcription.loadingStage.isEmpty ? "Loading…" : transcription.loadingStage)
                    .font(Typography.buttonLabelSmall)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Color.textPrimary.opacity(0.08)))
            .foregroundStyle(Color.textSecondary)

            if loadingElapsed > 15 {
                Text(loadingElapsed > 30 ? "Taking longer than expected…" : "\(Int(loadingElapsed))s")
                    .font(.system(size: 10))
                    .foregroundStyle(loadingElapsed > 30 ? Color.orange : Color.textMuted)
            }
        }
        .help("First load may take 10-30 seconds")
    }

    private func pill(text: String, icon: String?, filled: Bool) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
            Text(text).font(Typography.buttonLabelSmall)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Capsule().fill(filled ? Color.textPrimary : Color.textPrimary.opacity(0.06)))
        .foregroundStyle(filled ? Color.bgCard : Color.textPrimary)
    }

    private var downloadProgressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloading…").font(Typography.cardMeta).foregroundStyle(Color.textSecondary)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.textPrimary.opacity(0.08)).frame(height: 6)
                    Capsule().fill(Color.accentColor).frame(width: max(6, geo.size.width * progress), height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
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
                    stopLoadingTimer(); isLoadingModel = false; selectedModel = model.variant
                }
            } catch {
                await MainActor.run {
                    stopLoadingTimer(); isLoadingModel = false
                    loadError = error.localizedDescription
                }
            }
        }
    }

    private func stopLoadingTimer() {
        loadingTimer?.invalidate(); loadingTimer = nil
        loadingStartTime = nil; loadingElapsed = 0
    }
}

#Preview {
    VStack(spacing: 16) {
        ModelRow(model: AIModel.availableModels[6], selectedModel: .constant("x"), isRecommended: true)
        ModelRow(model: AIModel.availableModels[0], selectedModel: .constant("x"))
    }
    .padding()
    .frame(width: 640)
    .background(Color.bgApp)
}
