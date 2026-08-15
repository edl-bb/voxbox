import ApplicationServices
import AppKit
import AVFoundation
import Combine
import Foundation

final class PermissionService: ObservableObject {
    static let shared = PermissionService()

    @Published private(set) var isMicGranted = false
    @Published private(set) var isAccessibilityGranted = false

    var arePermissionsGranted: Bool {
        isMicGranted && isAccessibilityGranted
    }

    private var timer: Timer?
    private var didStartMonitoring = false

    private init() {
        refresh()
    }

    func startMonitoring() {
        guard !didStartMonitoring else { return }
        didStartMonitoring = true
        refresh()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibility = AXIsProcessTrusted()
        if mic != isMicGranted { isMicGranted = mic }
        if accessibility != isAccessibilityGranted { isAccessibilityGranted = accessibility }
    }

    func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refresh()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        default:
            openSettings(pane: "Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        if AXIsProcessTrusted() {
            openSettings(pane: "Privacy_Accessibility")
            return
        }
        ClipboardService.shared.requestAccessibilityPermission()
        refresh()
    }

    func manageMicrophone() {
        openSettings(pane: "Privacy_Microphone")
    }

    func manageAccessibility() {
        openSettings(pane: "Privacy_Accessibility")
    }

    private func openSettings(pane: String) {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        {
            NSWorkspace.shared.open(url)
        }
    }
}
