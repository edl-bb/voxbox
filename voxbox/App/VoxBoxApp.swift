//
//  VoxBoxApp.swift
//  VoxBox
//
//  Created by Karan Singh on 7/1/26 (as SpeakType).
//

import Combine
import KeyboardShortcuts
import SwiftData
import SwiftUI

@main
struct VoxBoxApp: App {
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("appTheme") private var appTheme: AppTheme = .system
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon: Bool = true
    @ObservedObject private var appearance = AppearanceController.shared

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    /// Onboarding is first-run only. Missing Accessibility must not hide the
    /// dashboard — auto-paste is optional; the permission pills stay in Settings.
    private var showsMainApp: Bool {
        hasCompletedOnboarding || isUITesting
    }

    init() {
        // Register bundled fonts (Satoshi, Source Sans 3) so Font.custom resolves
        // them regardless of what's installed on the machine.
        AppFonts.registerBundledFonts()

        // For UI testing: bypass onboarding automatically
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            hasCompletedOnboarding = true
        }
    }

    var body: some Scene {
        // Main Dashboard Window (Hidden by default, opened via Menu Bar or Dock)
        WindowGroup(id: "main-dashboard") {
            ThemeProvider {
                Group {
                    if showsMainApp {
                        MainView()
                    } else {
                        OnboardingView()
                    }
                }
            }
            .preferredColorScheme(appearance.resolvedScheme)
            .tint(Color.navyInk)
            .onAppear { appearance.apply(appTheme) }
            .onChange(of: appTheme) { _, theme in
                appearance.apply(theme)
            }
            .modifier(DashboardWindowOpener())
        }
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.hiddenTitleBar)
        .handlesExternalEvents(matching: ["main-dashboard", "open"])  // Only open for matching IDs
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .help) {
                Button("Release Notes") {
                    ReleaseNotesRoute.present()
                }
            }
        }

        Window("Release Notes", id: "release-notes") {
            ThemeProvider {
                ReleaseNotesView()
            }
            .preferredColorScheme(appearance.resolvedScheme)
            .onAppear { appearance.apply(appTheme) }
        }
        .defaultSize(width: 520, height: 620)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        // Note: Mini Recorder is now managed manually by AppDelegate -> MiniRecorderWindowController
        // to prevent SwiftUI from auto-opening the main dashboard on activation.

        // Menu Bar Extra (Always running listener). The label is the V-wave
        // monogram, animated while a recording is in progress.
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            ThemeProvider {
                MenuBarDashboardView(
                    openDashboard: openDashboard,
                    quit: { NSApplication.shared.terminate(nil) }
                )
            }
            .preferredColorScheme(appearance.resolvedScheme)
            .onAppear { appearance.apply(appTheme) }
            .onChange(of: appTheme) { _, theme in
                appearance.apply(theme)
            }
            .modifier(DashboardWindowOpener())
        } label: {
            MenuBarIconView()
        }
        .menuBarExtraStyle(.window)
    }

    private func openDashboard() {
        DashboardRoute.presentWindow()
    }

    private func openSettings() {
        guard showsMainApp else { return }
        DashboardRoute.open(.settings)
    }
}
