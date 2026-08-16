import Cocoa
import Observation
import SwiftUI

enum TranscriptDelivery {
    case pasted
    case copiedToClipboard
}

class MiniRecorderWindowController: NSObject {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var lastActiveApp: NSRunningApplication?
    private var appActivationObserver: NSObjectProtocol?
    private var isObservingModels = false
    private var shouldRestoreClipboardAfterAutoPaste: Bool {
        UserDefaults.standard.object(forKey: "restoreClipboardAfterAutoPaste") as? Bool ?? true
    }

    /// When on, every completed transcript stays on the clipboard after
    /// dictation — even when it was also auto-pasted — so it can be pasted
    /// again anywhere. Off by default for new installs. Takes precedence over
    /// the clipboard-restore behavior.
    private var shouldKeepTranscriptOnClipboard: Bool {
        TranscriptClipboardPreference.isEnabled()
    }

    /// When on, the resting pill stays on screen even when idle. Default off:
    /// the recorder appears only while dictating and hides afterward (issue #100).
    private var alwaysShowIdlePill: Bool {
        UserDefaults.standard.bool(forKey: "alwaysShowRecorderPill")
    }

    /// Where the pill sits on screen. Read from UserDefaults each time it is
    /// repositioned, so the latest value is always used.
    private var pillPosition: PillPosition {
        if let raw = UserDefaults.standard.string(forKey: PillPosition.defaultsKey),
            let pos = PillPosition(rawValue: raw)
        {
            return pos
        }
        return .defaultPosition
    }

    /// Prepare the resting pill. Called once at launch. When "always show" is on
    /// the pill lives on screen and morphs into the recording HUD; when off it
    /// stays hidden until recording starts.
    func showIdleRecorder() {
        if panel == nil {
            setupPanel()
        }
        observeModelAvailability()
        applyIdleVisibilityPreference()
    }

    /// React to the "always show recorder pill" preference changing at runtime.
    func applyIdleVisibilityPreference() {
        if panel == nil {
            setupPanel()
        }
        guard let panel = panel else { return }
        guard !AudioRecordingService.shared.isRecording else { return }

        positionPanel()

        if needsModelDownload {
            panel.ignoresMouseEvents = false
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            return
        }

        if alwaysShowIdlePill {
            panel.ignoresMouseEvents = true
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        } else if panel.ignoresMouseEvents {
            // Only hide when idle — during an active session the panel is
            // interactive (ignoresMouseEvents == false), so leave it alone.
            panel.orderOut(nil)
        } else {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        }
    }

    /// React to the "recorder pill position" preference changing at runtime.
    /// Defer the move while a recording is in progress so the HUD doesn't
    /// teleport under the user's cursor; the next `startRecording()` /
    /// `showIdleRecorder()` will place it in the new spot.
    func applyPillPosition() {
        if panel == nil {
            setupPanel()
        }
        guard let panel = panel else { return }
        guard !AudioRecordingService.shared.isRecording else { return }
        guard panel.isVisible else { return }
        positionPanel()
    }

    /// Reposition the pill when the display configuration changes (external
    /// monitor connected/disconnected, dock resized, etc.) so it doesn't end
    /// up off-screen relative to the new layout. Deferred mid-recording so the
    /// HUD doesn't jump under the user's cursor; the next `startRecording()`
    /// / `showIdleRecorder()` will place it in the new spot.
    func handleScreenParametersChanged() {
        guard !AudioRecordingService.shared.isRecording else { return }
        positionPanel()
    }

    // Start recording - show panel and begin recording
    func startRecording() {
        rememberPasteTarget(from: NSWorkspace.shared.frontmostApplication)

        if panel == nil {
            setupPanel()
        }

        guard let panel = panel else { return }

        positionPanel()
        // Become interactive so the recording HUD (stop dot, hover controls) works.
        panel.ignoresMouseEvents = false

        // Show the idle pill first. Previous runs died after isListening=true and
        // never reached a deferred orderFront, so the HUD never appeared.
        if !panel.isVisible {
            print("Showing Mini Recorder Panel")
            panel.orderFrontRegardless()
        }

        NotificationCenter.default.post(name: .recordingStartRequested, object: nil)
    }

    /// Position the panel on its current screen according to the user's chosen
    /// `PillPosition`. Safe to call repeatedly (on show and on every resize).
    private func positionPanel() {
        guard let panel = panel else { return }
        let screen = panel.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }

        let origin = PillPosition.origin(
            for: pillPosition,
            panelSize: panel.frame.size,
            visibleFrame: visibleFrame
        )
        let rounded = NSPoint(x: origin.x.rounded(), y: origin.y.rounded())
        if panel.frame.origin != rounded {
            panel.setFrameOrigin(rounded)
        }
    }

    /// Return the pill to its passive resting state. When "always show" is off
    /// (the default) this hides the recorder so it only appears while dictating.
    private func returnToIdle() {
        applyIdleVisibilityPreference()
    }

    private var needsModelDownload: Bool {
        UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
            && !ModelDownloadService.shared.hasAnyDownloadedModel
    }

    private func observeModelAvailability() {
        guard !isObservingModels else { return }
        isObservingModels = true
        trackModelAvailability()
    }

    private func trackModelAvailability() {
        withObservationTracking {
            _ = ModelDownloadService.shared.hasAnyDownloadedModel
        } onChange: { [weak self] in
            let controller = self
            Task { @MainActor in
                controller?.applyIdleVisibilityPreference()
                controller?.trackModelAvailability()
            }
        }
    }

    // Stop recording - trigger transcription and paste
    func stopRecording() {
        // 1. Hide recorder immediately - REMOVED so it shows "Transcribing..."
        // panel?.orderOut(nil)

        // Keep focus unchanged while the hotkey is still being released.
        // Re-activation happens later during commit, right before auto-paste.
        NotificationCenter.default.post(name: .recordingStopRequested, object: nil)
    }

    func cancelRecording() {
        NotificationCenter.default.post(name: .recordingCancelRequested, object: nil)
    }

    /// Copy the newest history transcript. Recovery path when auto-paste missed
    /// the focused field — does not re-paste, just puts the text on the clipboard.
    func copyLastTranscriptToClipboard() {
        if let text = HistoryService.shared.lastTranscript {
            ClipboardService.shared.copy(text: text)
            NotificationCenter.default.post(name: .lastTranscriptCopied, object: nil)
            AppLogger.info("Copied last transcript to clipboard", category: AppLogger.clipboard)
        } else {
            NotificationCenter.default.post(name: .lastTranscriptCopyFailed, object: nil)
            AppLogger.info("Copy last transcript: nothing to copy", category: AppLogger.clipboard)
        }

        guard let panel = panel else { return }
        positionPanel()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func setupPanel() {
        // Initialize View with callbacks
        observeAppActivations()

        let recorderView = MiniRecorderView(
            onCommit: { [weak self] text in
                await self?.handleCommit(text: text) ?? .copiedToClipboard
            },
            onCancel: { [weak self] in
                // Don't hide — the pill stays on screen and settles back to idle.
                self?.returnToIdle()
            }
        )

        // Initialize hosting controller with transparent background view
        // Wrap in AnyView because .background() changes the type from MiniRecorderView to some View
        hostingController = NSHostingController(
            rootView: AnyView(recorderView.background(Color.clear)))

        // Fixed window, big enough for the largest phase. The pill morphs purely in
        // SwiftUI, centered inside. A window that never resizes means the animation
        // is smooth with no boundary clipping.
        let fixedSize = NSSize(width: 520, height: 84)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: fixedSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true  // idle by default — clicks pass through

        // Use the hosting view directly as the content view (NOT contentViewController)
        // so the window size is never driven by the SwiftUI content, and clamp the
        // size so nothing can resize it.
        if let hostView = hostingController?.view {
            hostView.frame = NSRect(origin: .zero, size: fixedSize)
            hostView.autoresizingMask = [.width, .height]
            hostView.wantsLayer = true
            hostView.layer?.backgroundColor = NSColor.clear.cgColor
            p.contentView = hostView
        }
        p.minSize = fixedSize
        p.maxSize = fixedSize
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = false  // stay put — positioned by positionPanel() per user preference
        p.hasShadow = false  // Disable system shadow to avoid transparency artifacts (View has its own shadow)

        // Window Behavior
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false  // Keep floating even if focus lost
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true

        self.panel = p
    }

    private func observeAppActivations() {
        guard appActivationObserver == nil else { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.rememberPasteTarget(from: app)
        }
    }

    private func rememberPasteTarget(from app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastActiveApp = app
    }

    private func resolvedPasteTarget() -> NSRunningApplication? {
        guard let app = lastActiveApp, !app.isTerminated else { return nil }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app
    }

    private func handleCommit(text: String) async -> TranscriptDelivery {
        let accessibilityTrusted = ClipboardService.shared.isAccessibilityTrusted
        let target = resolvedPasteTarget()
        let canPaste = accessibilityTrusted && target != nil

        if !canPaste {
            ClipboardService.shared.copy(text: text)
            print(
                "⚠️ Auto-paste unavailable — transcript copied to clipboard"
            )
            return .copiedToClipboard
        }

        let previousClipboard: ClipboardService.ClipboardSnapshot?
        if !shouldKeepTranscriptOnClipboard && shouldRestoreClipboardAfterAutoPaste {
            previousClipboard = ClipboardService.shared.copyForTemporaryPaste(text: text)
        } else {
            previousClipboard = nil
            ClipboardService.shared.copy(text: text)
        }

        await MainActor.run {
            self.returnToIdle()
        }

        _ = await MainActor.run {
            target?.activate()
        }

        try? await Task.sleep(nanoseconds: 500_000_000)

        await MainActor.run {
            ClipboardService.shared.paste()
        }

        guard let previousClipboard else { return .pasted }

        try? await Task.sleep(nanoseconds: 350_000_000)

        await MainActor.run {
            ClipboardService.shared.restore(previousClipboard, ifCurrentStringMatches: text)
        }
        return .pasted
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText =
            "VoxBox needs Accessibility permission to automatically paste transcriptions into the active app.\n\nYour transcription has been copied to the clipboard.\n\nTo enable auto-paste, grant permission in:\nSystem Settings → Privacy & Security → Accessibility"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
