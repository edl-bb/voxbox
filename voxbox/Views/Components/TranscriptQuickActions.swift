import SwiftUI

/// Copy (with a "Copied" flash) and Play/Stop for one transcript. The
/// dashboard's recent list and the History list share it so the two feel
/// like the same control.
struct TranscriptQuickActions: View {
    let item: HistoryItem
    @State private var showCopySuccess = false
    @ObservedObject private var audioPlayer = AudioPlayerService.shared

    private var hasAudio: Bool {
        guard let url = item.audioFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var isPlayingThisItem: Bool {
        audioPlayer.isPlaying && audioPlayer.currentAudioURL == item.audioFileURL
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: copyToClipboard) {
                HStack(spacing: 4) {
                    Image(systemName: showCopySuccess ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                    Text(showCopySuccess ? "Copied" : "Copy")
                        .font(Typography.captionSmall)
                }
                .foregroundStyle(showCopySuccess ? Color.accentSuccess : Color.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.bgHover)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Copy the transcript")

            if hasAudio {
                Button(action: togglePlayback) {
                    HStack(spacing: 4) {
                        Image(systemName: isPlayingThisItem ? "stop.fill" : "play.fill")
                            .font(.system(size: 11))
                        Text(isPlayingThisItem ? "Stop" : "Play")
                            .font(Typography.captionSmall)
                    }
                    .foregroundStyle(isPlayingThisItem ? Color.brandAccent : Color.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.bgHover)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(isPlayingThisItem ? "Stop playback" : "Play the recording")
            }
        }
    }

    private func togglePlayback() {
        guard let url = item.audioFileURL else { return }
        if isPlayingThisItem {
            audioPlayer.stop()
            return
        }
        if audioPlayer.currentAudioURL != url {
            audioPlayer.loadAudio(from: url)
        }
        audioPlayer.play()
    }

    private func copyToClipboard() {
        ClipboardService.shared.copy(text: item.transcript)
        withAnimation { showCopySuccess = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showCopySuccess = false }
        }
    }
}
