import AppKit
import SwiftUI

/// Stash a sidebar destination when the dashboard is opened from outside
/// (⌘, while the window is closed, or the no-model pill).
enum DashboardRoute {
    static var pending: SidebarItem?
    /// Bound from a living SwiftUI scene so we can open the WindowGroup in-process.
    static var openWindow: ((String) -> Void)?

    static func open(_ item: SidebarItem) {
        pending = item
        presentWindow()
        NotificationCenter.default.post(name: .dashboardRouteRequested, object: nil)
    }

    /// Switch sidebar page in the existing dashboard window. Does not open a new one.
    static func reveal(_ item: SidebarItem) {
        pending = item
        NotificationCenter.default.post(name: .dashboardRouteRequested, object: nil)
    }

    /// Show the dashboard in this process. Never uses `voxbox://` — Launch
    /// Services would hand that URL to `/Applications/VoxBox.app`.
    static func presentWindow() {
        if frontExistingDashboardWindow() { return }
        openWindow?("main-dashboard")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func frontExistingDashboardWindow() -> Bool {
        let match = NSApp.windows.first { window in
            if window is NSPanel { return false }
            if let id = window.identifier?.rawValue, id.contains("main-dashboard") {
                return true
            }
            let cls = String(describing: type(of: window))
            if cls.contains("StatusBar") || cls.contains("Popup") || cls.contains("MenuBar") {
                return false
            }
            return window.frame.width >= 600 && window.frame.height >= 400
        }
        guard let window = match else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

/// Captures `openWindow` from a mounted scene (menu bar or dashboard).
struct DashboardWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            DashboardRoute.openWindow = { id in
                openWindow(id: id)
            }
        }
    }
}

struct MainView: View {
    @State private var selection: SidebarItem? = .dashboard
    @AppStorage("hasShownModelPrompt") private var hasShownModelPrompt: Bool = false
    @State private var showStreamingRevertToast = false
    @State private var streamingRevertToastTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar - warmer background
            SidebarView(selection: $selection)
                .background(Color.bgSidebar)
            
            // Content area - white/light background
            ZStack {
                Color.bgContent
                    .ignoresSafeArea()
                
                contentView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.bgSidebar)
        .overlay(alignment: .bottom) {
            if showStreamingRevertToast {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.slash")
                        .foregroundStyle(Color.brandAccent)
                    Text(StreamingModeCopy.revertedToBatch)
                        .font(Typography.labelMedium)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Material.ultraThinMaterial)
                .background(Color.black.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(radius: 10)
                .padding(.horizontal, 32)
                .padding(.bottom, 30)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showStreamingRevertToast)
        .onAppear {
            if applyPendingRoute() { return }
            // If no model downloaded and haven't shown prompt, go to AI Models
            let hasModel = ModelDownloadService.hasDownloadedModel(
                in: ModelDownloadService.shared.downloadProgress)
            if !hasModel && !hasShownModelPrompt {
                hasShownModelPrompt = true
                selection = .aiModels
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dashboardRouteRequested)) { _ in
            _ = applyPendingRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { _ in
            _ = applyPendingRoute()
        }
        .onReceive(NotificationCenter.default.publisher(for: .streamingRevertedToBatch)) { _ in
            streamingRevertToastTask?.cancel()
            showStreamingRevertToast = true
            streamingRevertToastTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_200_000_000)
                guard !Task.isCancelled else { return }
                showStreamingRevertToast = false
            }
        }
    }

    /// Apply a pending sidebar route (Settings from ⌘,). Returns true if one ran.
    @discardableResult
    private func applyPendingRoute() -> Bool {
        guard let pending = DashboardRoute.pending else { return false }
        DashboardRoute.pending = nil
        selection = pending
        return true
    }
    
    @ViewBuilder
    private var contentView: some View {
        switch selection {
        case .dashboard:
            DashboardView(selection: $selection)
        case .transcribeAudio:
            TranscribeAudioView()
        case .history:
            HistoryView()
        case .dictionary:
            DictionaryView()
        case .statistics:
            StatisticsView()
        case .aiModels:
            AIModelsView()
        case .settings:
            SettingsView(
                onOpenDictionary: { selection = .dictionary },
                onOpenModels: {
                    selection = .aiModels
                }
            )
        case .none:
            DashboardView(selection: $selection)
        }
    }
}
