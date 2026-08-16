import AppKit
import Combine
import SwiftUI

extension AppTheme {
    static let defaultsKey = "appTheme"

    static var stored: AppTheme {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
            let theme = AppTheme(rawValue: raw)
        {
            return theme
        }
        return .system
    }

    /// macOS Light/Dark setting, independent of any `NSApp.appearance` override.
    static func systemIsDark(defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// System is not "no scheme" — it is Light or Dark as macOS is right now.
    static func resolvedColorScheme(for theme: AppTheme, systemIsDark: Bool) -> ColorScheme {
        switch theme {
        case .light: return .light
        case .dark: return .dark
        case .system: return systemIsDark ? .dark : .light
        }
    }
}

/// Owns the live Light/Dark value so System can be re-evaluated without
/// remounting the dashboard (which would dump the user out of Settings).
final class AppearanceController: ObservableObject {
    static let shared = AppearanceController()

    @Published private(set) var resolvedScheme: ColorScheme

    private var currentTheme: AppTheme
    private var systemObserver: NSObjectProtocol?

    private init() {
        let theme = AppTheme.stored
        currentTheme = theme
        resolvedScheme = AppTheme.resolvedColorScheme(
            for: theme,
            systemIsDark: AppTheme.systemIsDark()
        )
        systemObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemAppearanceChange()
        }
    }

    deinit {
        if let systemObserver {
            DistributedNotificationCenter.default.removeObserver(systemObserver)
        }
    }

    func apply(_ theme: AppTheme) {
        currentTheme = theme
        let scheme = AppTheme.resolvedColorScheme(
            for: theme,
            systemIsDark: AppTheme.systemIsDark()
        )
        resolvedScheme = scheme
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }

    private func handleSystemAppearanceChange() {
        guard currentTheme == .system else { return }
        apply(.system)
    }
}
