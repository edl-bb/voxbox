import AVFoundation
import Combine
import CoreMedia
import SwiftUI

struct MiniRecorderView: View {
    @ObservedObject private var audioRecorder = AudioRecordingService.shared
    private var transcription: TranscriptionManager { TranscriptionManager.shared }
    @State private var isListening = false

    @State private var isProcessing = false
    @State private var statusMessage = "Transcribing..."
    @State private var isWarmingUp = false
    @State private var showAccessibilityWarning = false
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    @AppStorage(ModelSelection.defaultsKey) private var selectedModel: String = ModelSelection.none
    @AppStorage("recordingMode") private var recordingMode: Int = 0
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage: String = "auto"
    @AppStorage("recentTranscriptionLanguages") private var recentLanguagesString: String = ""
    private let quickLanguageDefaults = ["en", "es", "fr", "de", "hi", "pt", "ja", "zh"]

    private var recentLanguageCodes: [String] {
        recentLanguagesString.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    private var quickLanguageCodes: [String] {
        var orderedCodes: [String] = []
        let candidateCodes = [transcriptionLanguage] + recentLanguageCodes + quickLanguageDefaults

        for code in candidateCodes where code != "auto" {
            guard !orderedCodes.contains(code) else { continue }
            guard GeneralSettingsTab.whisperLanguages.contains(where: { $0.code == code }) else {
                continue
            }
            orderedCodes.append(code)
        }

        return Array(orderedCodes.prefix(6))
    }

    private func updateRecentLanguages(code: String) {
        guard code != "auto" else { return }
        var recents = recentLanguageCodes.filter { $0 != code }
        recents.insert(code, at: 0)
        recentLanguagesString = recents.prefix(5).joined(separator: ",")
    }

    private func setLanguage(_ code: String) {
        transcriptionLanguage = code
        updateRecentLanguages(code: code)
    }

    private var currentLanguageLabel: String {
        if transcriptionLanguage == "auto" { return "Auto" }
        return spokenLanguageDisplayName(for: transcriptionLanguage)
    }

    private var spokenLanguageHelpText: String {
        if transcriptionLanguage == "auto" {
            return "Spoken language hint: Auto-detect. SpeakType will try to detect the language you are speaking."
        }

        return
            "Spoken language hint: \(spokenLanguageDisplayName(for: transcriptionLanguage)). If this does not match the language you actually speak, the result may be inaccurate or come back in the wrong language."
    }

    private var currentInputDeviceName: String {
        guard
            let selectedDeviceId = audioRecorder.selectedDeviceId,
            let device = audioRecorder.availableDevices.first(where: { $0.uniqueID == selectedDeviceId })
        else {
            return "No input selected"
        }

        return device.localizedName
    }

    private var inputDeviceHelpText: String {
        "Input device: \(currentInputDeviceName). Change microphones without going back to Settings."
    }

    private var isAccessibilityEnabled: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - State for Escape key cancellation
    @State private var cancelCommit = false
    @State private var globalEscapeMonitor: Any?
    @State private var localEscapeMonitor: Any?

    // MARK: - State for Animation
    @State private var phase: CGFloat = 0

    /// Whether the pill is hovered — reveals the mic/mode controls inline.
    @State private var expanded = false

    // MARK: - Recorder helpers

    /// Compact language label for the always-visible tag ("Auto" or "EN").
    private var currentLanguageShort: String {
        transcriptionLanguage == "auto" ? "Auto" : transcriptionLanguage.uppercased()
    }

    /// First word of the selected input device, for a compact chip ("MacBook").
    private var shortDeviceName: String {
        let name = currentInputDeviceName
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    private func elapsedString(_ now: Date) -> String {
        guard let start = audioRecorder.recordingStartTime else { return "0:00" }
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Shared chip styling for the recorder's labeled controls (icon + word + chevron).
    private func recorderChipLabel(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .semibold))
            DoubleChevronIcon(color: .white.opacity(0.45))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    private var languageControl: some View {
        Menu {
            Button("Auto-detect") { setLanguage("auto") }
            if !quickLanguageCodes.isEmpty {
                Divider()
                ForEach(quickLanguageCodes, id: \.self) { code in
                    if let lang = GeneralSettingsTab.whisperLanguages.first(where: { $0.code == code }) {
                        Button(lang.name) { setLanguage(code) }
                    }
                }
            }
            Divider()
            Menu("More languages") {
                ForEach(GeneralSettingsTab.whisperLanguages, id: \.code) { lang in
                    Button(lang.name) { setLanguage(lang.code) }
                }
            }
            if !recentLanguageCodes.isEmpty {
                Divider()
                Button("Clear recents") { recentLanguagesString = "" }
            }
        } label: {
            recorderChipLabel(icon: "globe", text: currentLanguageShort)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .tint(.white.opacity(0.9))
        .fixedSize()
        .help(spokenLanguageHelpText)
    }

    private var micControl: some View {
        Menu {
            if audioRecorder.availableDevices.isEmpty {
                Button("No input devices found") {}.disabled(true)
            } else {
                ForEach(audioRecorder.availableDevices, id: \.uniqueID) { device in
                    Button {
                        selectAudioDevice(device.uniqueID)
                    } label: {
                        if audioRecorder.selectedDeviceId == device.uniqueID {
                            Label(device.localizedName, systemImage: "checkmark")
                        } else {
                            Text(device.localizedName)
                        }
                    }
                }
            }
            Divider()
            Button("Refresh inputs") { audioRecorder.fetchAvailableDevices() }
        } label: {
            recorderChipLabel(icon: "mic.fill", text: shortDeviceName)
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .tint(.white.opacity(0.9))
        .fixedSize()
        .help(inputDeviceHelpText)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var modeControl: some View {
        Menu {
            Button {
                recordingMode = 0
            } label: {
                if recordingMode == 0 {
                    Label("Hold to talk", systemImage: "checkmark")
                } else {
                    Text("Hold to talk")
                }
            }
            Button {
                recordingMode = 1
            } label: {
                if recordingMode == 1 {
                    Label("Toggle on / off", systemImage: "checkmark")
                } else {
                    Text("Toggle on / off")
                }
            }
        } label: {
            recorderChipLabel(
                icon: recordingMode == 0 ? "hand.tap.fill" : "repeat.1",
                text: recordingMode == 0 ? "Hold" : "Toggle")
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .tint(.white.opacity(0.9))
        .fixedSize()
        .help("Recording mode")
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    // MARK: - Live waveform
    // Samples come from AudioRecordingService.liveWaveSamples (peak amplitude per
    // audio buffer while recording). Rendered with a SwiftUI Canvas so it redraws
    // on every sample change.
    private static let waveBarWidth: CGFloat = 2.5
    private static let waveBarSpacing: CGFloat = 2.0

    // Default Init for Preview
    init(onCommit: ((String) -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            backgroundView

            if isWarmingUp || transcription.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                    Text("Warming up model...")
                        .font(Typography.labelMedium)
                        .foregroundColor(.white.opacity(0.9))
                }
                .transition(.opacity)
            } else if isProcessing {
                Text(statusMessage)
                    .font(Typography.labelMedium)
                    .foregroundColor(.white)
                    .transition(.opacity)
            } else {
                HStack(spacing: 12) {
                    stopButton

                    // Waveform — live render of the actual microphone input.
                    // Calm/flat when silent, peaks on speech.
                    Canvas { context, size in
                        let raw = audioRecorder.liveWaveSamples
                        guard !raw.isEmpty else { return }
                        let step = Self.waveBarWidth + Self.waveBarSpacing
                        let maxBars = max(1, Int(size.width / step))
                        // Noise-gate, then auto-gain to the recent peak so the
                        // waveform stays lively and well-scaled at any volume.
                        let visible = raw.suffix(maxBars).map { max(0, $0 - 0.02) }
                        let recentPeak = max(visible.max() ?? 0, 0.05)
                        let midY = size.height / 2
                        for (i, sample) in visible.enumerated() {
                            let norm = CGFloat(min(1, sample / recentPeak))
                            let barHeight = max(2.5, norm * size.height)
                            let x = CGFloat(i) * step
                            let rect = CGRect(
                                x: x, y: midY - barHeight / 2,
                                width: Self.waveBarWidth, height: barHeight)
                            context.fill(
                                Path(roundedRect: rect, cornerRadius: Self.waveBarWidth / 2),
                                with: .color(.white.opacity(0.9)))
                        }
                    }
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)

                    // Elapsed recording time.
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        Text(elapsedString(context.date))
                            .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundColor(.white.opacity(0.55))
                    }

                    // Mic + mode: revealed inline on hover, each clearly labeled.
                    if expanded {
                        micControl
                        modeControl
                    }

                    // Language: always available, compact.
                    languageControl
                }
                .padding(.horizontal, 16)
                .transition(.opacity)
            }
        }
        .frame(width: 420, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 3)
        .animation(.easeInOut(duration: 0.18), value: expanded)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) { expanded = hovering }
        }
        .contextMenu {
            modelSelectionMenu
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingStartRequested)) { _ in
            startRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingStopRequested)) { _ in
            stopAndTranscribe()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingCancelRequested)) { _ in
            cancelRecording()
        }
        .onAppear {
            initializedService()
            audioRecorder.fetchAvailableDevices()

            // Set up Escape key monitors
            globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    Task { @MainActor in self.handleEscape() }
                }
            }
            localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    Task { @MainActor in self.handleEscape() }
                    return nil  // swallow Escape
                }
                return event
            }
        }
        .onDisappear {
            if let globalEscapeMonitor = globalEscapeMonitor {
                NSEvent.removeMonitor(globalEscapeMonitor)
            }
            if let localEscapeMonitor = localEscapeMonitor {
                NSEvent.removeMonitor(localEscapeMonitor)
            }
            audioRecorder.stopSessionIfIdle()
        }
        .onChange(of: isListening) {
            // Only animate when actually recording to save CPU
            if isListening {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    phase = .pi * 4
                }
            } else {
                phase = 0
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            // Ensure focus if needed
        }
        .background(
            KeyEventHandlerView(onEscape: {
                handleEscape()
            })
        )
        .alert("Accessibility Permission Required", isPresented: $showAccessibilityWarning) {
            Button("Open Settings") {
                if let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Continue Anyway", role: .cancel) {}
        } message: {
            Text(
                "Accessibility is disabled. Transcribed text will be copied to clipboard but won't auto-paste into apps.\n\nEnable it in System Settings → Privacy & Security → Accessibility."
            )
        }
    }

    // MARK: - Subviews

    private var stopButton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.36, blue: 0.34),
                            Color(red: 0.90, green: 0.15, blue: 0.15),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 32, height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
                )
                .shadow(color: Color(red: 1.0, green: 0.2, blue: 0.2).opacity(0.45), radius: 7, x: 0, y: 1)

            // Inner stop square.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white)
                .frame(width: 10, height: 10)
        }
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture {
            handleHotkeyTrigger()
        }
    }

    private var backgroundView: some View {
        ZStack {
            // Frosted blur base, clipped to the pill.
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow, cornerRadius: 25)
                .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))

            // Depth: subtly lighter at the top, darker at the bottom.
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.17), Color(white: 0.07)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(0.92)

            // Glass highlight along the top edge.
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )

            // Hairline border, brighter up top for a lit-from-above feel.
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
    }

    @ViewBuilder
    private var modelSelectionMenu: some View {
        ForEach(AIModel.availableModels) { model in
            Button {
                let previousModel = selectedModel
                selectedModel = model.variant

                // Pre-load the new model immediately so the first transcription isn't slow
                if model.variant != previousModel {
                    Task {
                        await MainActor.run { isWarmingUp = true }
                        do {
                            try await transcription.loadModel(variant: model.variant)
                            debugLog("Model pre-loaded after switch: \(model.variant)")
                        } catch {
                            debugLog("Model pre-load failed: \(error.localizedDescription)")
                        }
                        await MainActor.run { isWarmingUp = false }
                    }
                }
            } label: {
                if selectedModel == model.variant {
                    Label(model.name, systemImage: "checkmark")
                } else {
                    Text(model.name)
                }
            }
        }
    }

    // MARK: - Logic

    private func initializedService() {
        // Pre-warm the audio capture session for instant first recording
        audioRecorder.prewarmSession()

        guard !selectedModel.isEmpty else {
            debugLog("No model selected - skipping initialization")
            return
        }

        Task {
            debugLog("Initializing WhisperService with model: \(selectedModel)")
            do {
                try await transcription.loadModel(variant: selectedModel)
                debugLog("Model preloaded successfully")
            } catch {
                debugLog("Model preload failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleHotkeyTrigger() {
        if isListening {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    private func cancelRecording() {
        cancelCommit = true

        guard isListening || audioRecorder.isRecording else {
            isProcessing = false
            onCancel?()
            return
        }

        Task {
            _ = await audioRecorder.stopRecording(discardOutput: true)

            await MainActor.run {
                isListening = false
                isProcessing = false
                statusMessage = "Transcribing..."
                onCancel?()
            }
        }
    }

    private func startRecording() {
        guard !isProcessing else {
            debugLog("Already processing, ignoring start request")
            return
        }

        guard !isListening else {
            debugLog("Already listening, ignoring duplicate start request")
            return
        }

        // Check if accessibility is enabled - warn but don't block
        if !isAccessibilityEnabled {
            showAccessibilityWarning = true
        }

        // Check if model is selected BEFORE starting recording
        guard !selectedModel.isEmpty else {
            debugLog("No model selected - showing error")
            isProcessing = true
            statusMessage = "No model selected"

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                isProcessing = false
                onCancel?()
            }
            return
        }

        // Check if model is downloaded
        let progress = ModelDownloadService.shared.downloadProgress[selectedModel] ?? 0
        guard progress >= 1.0 else {
            debugLog("Model not downloaded - showing error")
            isProcessing = true
            statusMessage = "Model not downloaded"

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                isProcessing = false
                onCancel?()
            }
            return
        }

        cancelCommit = false

        debugLog("Starting recording...")
        audioRecorder.startRecording()
        isListening = true
    }

    private func selectAudioDevice(_ deviceId: String) {
        guard audioRecorder.selectedDeviceId != deviceId else { return }

        let shouldResumeRecording = isListening

        Task {
            if shouldResumeRecording {
                await MainActor.run {
                    isListening = false
                    isProcessing = true
                    statusMessage = "Switching input..."
                }

                _ = await audioRecorder.stopRecording(discardOutput: true)
            }

            await MainActor.run {
                audioRecorder.selectedDeviceId = deviceId
            }

            guard shouldResumeRecording else { return }

            audioRecorder.startRecording()

            await MainActor.run {
                isProcessing = false
                isListening = true
            }
        }
    }

    private func stopAndTranscribe() {
        debugLog("stopAndTranscribe called")

        guard isListening || audioRecorder.isRecording else {
            debugLog("Not listening, ignoring duplicate stop request")
            return
        }

        // Check if model is selected
        guard !selectedModel.isEmpty else {
            debugLog("No model selected - cannot transcribe")
            Task { @MainActor in
                isListening = false
                isProcessing = false
                statusMessage = "No AI model selected. Go to Settings → AI Models to download one."

                // Show error for 3 seconds
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                onCancel?()
            }
            return
        }

        Task {
            let url = await audioRecorder.stopRecording()
            debugLog("stopRecording returned: \(url?.absoluteString ?? "nil")")

            guard let url = url else {
                debugLog("No recording URL, cancelling")
                await MainActor.run {
                    isListening = false
                    onCancel?()
                }
                return
            }

            await MainActor.run {
                isListening = false
                isProcessing = true
                statusMessage = "Transcribing..."
            }

            // Always use the final full-recording transcription for committed output.
            // Chunk stitching caused repeated phrases at boundaries across languages.
            await processRecording(url: url)
        }
    }

    private func handleEscape() {
        guard isListening || isProcessing || isWarmingUp || transcription.isLoading else { return }

        debugLog("Escape pressed - cancelling immediate commit")
        cancelCommit = true

        if isListening {
            Task {
                let url = await audioRecorder.stopRecording()

                await MainActor.run {
                    isListening = false
                    isProcessing = true
                    statusMessage = "Stopping transcription..."
                }

                if let url = url {
                    // Let it process in the background and save to history, but don't commit to UI
                    await processRecording(url: url)
                } else {
                    await MainActor.run {
                        onCancel?()
                    }
                }
            }
        } else {
            // Already processing, just show stopping and quickly dismiss
            statusMessage = "Stopping transcription..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                onCancel?()
            }
        }
    }

    private func debugLog(_ message: String) {
        let logPath = "/tmp/speaktype_debug.log"
        let logEntry = "[\(Date())] \(message)\n"
        if let data = logEntry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }

    private func processRecording(url: URL) async {
        debugLog("processRecording started with url: \(url.lastPathComponent)")
        do {
            // Ensure model is loaded before transcribing
            if !transcription.isInitialized || transcription.currentModelVariant != selectedModel
            {
                debugLog("Loading model: \(selectedModel)")
                await MainActor.run { statusMessage = "Warming up model — first use is slower..." }
                do {
                    try await transcription.loadModel(variant: selectedModel)
                    debugLog("Model loaded successfully")
                } catch {
                    debugLog("Model load failed: \(error.localizedDescription)")
                    await MainActor.run {
                        statusMessage = "Model load failed"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.isProcessing = false
                            self.onCancel?()
                        }
                    }
                    return
                }
            }

            debugLog("Starting transcription...")
            // If user has already cancelled (pressed Escape), skip transcription UI updates
            // but still run the transcription in the background to save to history
            if !cancelCommit {
                await MainActor.run { statusMessage = "Transcribing..." }
            }
            let text = try await transcription.transcribe(audioFile: url, language: transcriptionLanguage)
            debugLog("Transcription result: \(text.prefix(50))...")

            guard !text.isEmpty else {
                debugLog("Empty text, cancelling")
                await MainActor.run {
                    statusMessage = "No speech detected"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.isProcessing = false
                        self.onCancel?()
                    }
                }
                return
            }

            let duration = await getAudioDuration(url: url)
            let modelName =
                AIModel.availableModels.first(where: { $0.variant == selectedModel })?.name
                ?? selectedModel
            HistoryService.shared.addItem(
                transcript: text,
                duration: duration,
                audioFileURL: url,
                modelUsed: modelName,
                transcriptionTime: nil
            )

            debugLog("Calling onCommit...")
            await MainActor.run {
                if !cancelCommit {
                    onCommit?(text)
                }
                isProcessing = false

                // If we cancelled by dismissing early, the window might already be closed,
                // but if we waited for it (e.g. short transcription), close it now.
                if cancelCommit {
                    onCancel?()
                }
            }
            debugLog("onCommit called successfully")
        } catch {
            debugLog("Error: \(error.localizedDescription)")
            await MainActor.run {
                statusMessage = "Transcription failed"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.isProcessing = false
                    self.onCancel?()
                }
            }
        }
    }

    private func getAudioDuration(url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            return 0
        }
    }

    private func spokenLanguageDisplayName(for code: String) -> String {
        if code == "auto" { return "Auto-detect" }
        return GeneralSettingsTab.whisperLanguages.first(where: { $0.code == code })?.name ?? code
    }
}

// MARK: - Helper Shapes & Views

struct ChevronShape: Shape {
    let pointsUp: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()

        if pointsUp {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        return path
    }
}

struct DoubleChevronIcon: View {
    let color: Color

    var body: some View {
        VStack(spacing: 1) {
            ChevronShape(pointsUp: true)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 7, height: 4)

            ChevronShape(pointsUp: false)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 7, height: 4)
        }
        .frame(width: 8, height: 10)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active

        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.masksToBounds = true

        return visualEffectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.layer?.cornerRadius = cornerRadius
    }
}

// MARK: - Key Event Handler

struct KeyEventHandlerView: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCaptureView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? KeyCaptureView {
            view.onEscape = onEscape
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
    }

    class KeyCaptureView: NSView {
        var onEscape: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {  // Escape key
                onEscape?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
