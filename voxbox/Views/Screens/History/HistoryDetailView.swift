import SwiftUI

/// Enhanced detail view for history items with audio playback
struct HistoryDetailView: View {
    let item: HistoryItem
    
    @StateObject private var audioPlayer = AudioPlayerService.shared
    @State private var showCopyAlert = false
    @State private var showCorrectionSheet = false
    @State private var correctionApplied = false
    /// Live transcript — starts as the stored item's text and updates in place
    /// when a correction is applied, so the fix is visible immediately.
    @State private var displayedTranscript = ""

    /// The engine text, kept by History for takes recorded on 1.3 or later.
    /// Offered as a second copy action; the view itself shows the output.
    private var rawTranscript: String? {
        guard let raw = item.rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
            raw != item.transcript
        else { return nil }
        return raw
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with date and duration
                HStack(alignment: .top) {
                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                        .font(Typography.caption)
                        .foregroundStyle(.gray)
                    
                    Spacer()
                    
                    Text(formatDuration(item.duration))
                        .font(Typography.labelMedium)
                        .foregroundStyle(Color.brandAccent)
                }
                
                // Badges and copy button
                HStack {
                    // Original badge
                    Text("Original")
                        .font(Typography.badge)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.brandAccent)
                        .foregroundStyle(.white)
                        .cornerRadius(12)

                    Spacer()

                    // Copy the processed output (what was pasted).
                    actionButton("Copy", icon: "doc.on.doc") {
                        copyToClipboard(text: displayedTranscript)
                    }

                    // Copy what the speech engine heard, before dictionary
                    // rules, Auto Edit and cleanup. Only kept from 1.3 on.
                    if let rawTranscript {
                        actionButton("Copy raw transcript", icon: "waveform.and.magnifyingglass") {
                            copyToClipboard(text: rawTranscript)
                        }
                        .help("The transcript as the speech engine heard it, before any cleanup")
                    }

                    // Quick dictionary correction: fix a misheard word here,
                    // save it as a rule for all future dictations, and get the
                    // corrected transcript back on the clipboard.
                    actionButton("Add Correction", icon: "character.book.closed") {
                        showCorrectionSheet = true
                    }
                    .help("Fix a misheard word, remember it in the Dictionary, and recopy this transcript")
                }

                Divider()

                // Transcript: always the processed output.
                Text(displayedTranscript)
                    .font(Typography.bodyMedium)
                    .textSelection(.enabled)
                    .padding(.vertical, 8)
                
                Divider()
                
                // Audio playback section
                if let audioURL = item.audioFileURL {
                    VStack(spacing: 16) {
                        // Recording label with duration
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.gray)
                                Text("Recording")
                                    .font(Typography.caption)
                                    .foregroundStyle(.gray)
                            }
                            
                            Spacer()
                            
                            Text(formatTime(audioPlayer.currentTime))
                                .font(Typography.caption)
                                .foregroundStyle(.gray)
                                .monospacedDigit()
                        }
                        
                        // Waveform visualization
                        WaveformView(
                            audioURL: audioURL,
                            currentTime: $audioPlayer.currentTime,
                            duration: $audioPlayer.duration
                        )
                        
                        // Playback controls
                        HStack(spacing: 20) {
                            // Folder/file icon
                            Button(action: {
                                NSWorkspace.shared.activateFileViewerSelecting([audioURL])
                            }) {
                                Image(systemName: "folder")
                                    .font(.title3)
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                            .help("Show in Finder")
                            
                            Spacer()
                            
                            // Play/Pause button
                            Button(action: togglePlayback) {
                                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color.brandAccent)
                            }
                            .buttonStyle(.plain)
                            
                            Spacer()
                            
                            // Refresh/restart button
                            Button(action: {
                                audioPlayer.seek(to: 0)
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.title3)
                                    .foregroundStyle(.green)
                            }
                            .buttonStyle(.plain)
                            .help("Restart")
                        }
                        .padding(.vertical, 8)
                    }
                    .padding()
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(12)
                }
                
                Divider()
                
                // Metrics section
                VStack(alignment: .leading, spacing: 12) {
                    // Audio Duration
                    HStack {
                        Image(systemName: "waveform.circle")
                            .foregroundStyle(.gray)
                        Text("Audio Duration")
                            .font(Typography.bodySmall)
                            .foregroundStyle(.gray)
                        Spacer()
                        Text(formatDuration(item.duration))
                            .font(Typography.bodySmall)
                            .foregroundStyle(.white)
                    }
                    
                    // Transcription Model
                    if let model = item.modelUsed {
                        HStack {
                            Image(systemName: "cpu")
                                .foregroundStyle(.gray)
                            Text("Transcription Model")
                                .font(Typography.bodySmall)
                                .foregroundStyle(.gray)
                            Spacer()
                            Text(model)
                                .font(Typography.bodySmall)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                    
                    // Transcription Time
                    if let transcriptionTime = item.transcriptionTime {
                        HStack {
                            Image(systemName: "clock")
                                .foregroundStyle(.gray)
                            Text("Transcription Time")
                                .font(Typography.bodySmall)
                                .foregroundStyle(.gray)
                            Spacer()
                            Text(formatDuration(transcriptionTime))
                                .font(Typography.bodySmall)
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color.contentBackground)
        .navigationTitle("Transcript Details")
        .onAppear {
            displayedTranscript = item.transcript
            if let audioURL = item.audioFileURL {
                audioPlayer.loadAudio(from: audioURL)
            }
        }
        .sheet(isPresented: $showCorrectionSheet) {
            TranscriptCorrectionSheet { misheard, correct, wholeWord in
                let corrected = DictionaryService.shared.addCorrectionAndApply(
                    trigger: misheard,
                    replacement: correct,
                    matchWholeWord: wholeWord,
                    itemID: item.id
                )
                if let corrected {
                    displayedTranscript = corrected
                    correctionApplied = true
                }
            }
        }
        .alert("Correction applied", isPresented: $correctionApplied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "The rule was added to your Dictionary, this transcript was updated, and the corrected text is on your clipboard."
            )
        }
        .onDisappear {
            audioPlayer.stop()
        }
        .alert("Copied", isPresented: $showCopyAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Transcript copied to clipboard.")
        }
    }
    
    // MARK: - Helper Methods
    
    private func togglePlayback() {
        if audioPlayer.isPlaying {
            audioPlayer.pause()
        } else {
            audioPlayer.play()
        }
    }
    
    /// The header's pill buttons share one look.
    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(Typography.labelMedium)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.brandAccent)
            .foregroundStyle(.white)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private func copyToClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        showCopyAlert = true
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "0s"
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Quick correction sheet

/// Capture a "the model heard X, I meant Y" correction. The rule is saved to
/// the Dictionary (so every future dictation is fixed automatically), the
/// current transcript is rewritten with it, and the corrected text lands on
/// the clipboard for immediate re-pasting.
struct TranscriptCorrectionSheet: View {
    /// (misheardText, correctText, matchWholeWord)
    let onSave: (String, String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var misheard = ""
    @State private var correct = ""
    @State private var matchWholeWord = true

    private var isValid: Bool {
        !misheard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Correction")
                .font(Typography.displaySmall)
                .foregroundStyle(Color.textPrimary)

            Text(
                "Saved to your Dictionary so future dictations are fixed automatically. This transcript is updated and recopied to the clipboard right away."
            )
            .font(Typography.captionSmall)
            .foregroundStyle(Color.textMuted)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("The model heard")
                    .font(Typography.labelLarge)
                    .foregroundStyle(Color.textPrimary)
                TextField("", text: $misheard, prompt: Text("figjam"))
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("You meant")
                    .font(Typography.labelLarge)
                    .foregroundStyle(Color.textPrimary)
                TextField("", text: $correct, prompt: Text("FigJam"))
                    .textFieldStyle(.roundedBorder)
            }

            Toggle(isOn: $matchWholeWord) {
                Text("Match whole words only")
                    .font(Typography.bodySmall)
                    .foregroundStyle(Color.textPrimary)
            }
            .toggleStyle(.switch)

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save & Recopy") {
                    onSave(
                        misheard.trimmingCharacters(in: .whitespacesAndNewlines),
                        correct,
                        matchWholeWord
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

#Preview {
    HistoryDetailView(
        item: HistoryItem(
            id: UUID(),
            date: Date(),
            transcript: "Hello, hello, hello, hello, hello.",
            duration: 3.4,
            audioFileURL: nil,
            modelUsed: "Large v3 Turbo (Quantized)",
            transcriptionTime: 1.3
        )
    )
}
