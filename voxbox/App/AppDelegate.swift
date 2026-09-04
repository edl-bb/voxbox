import Combine
import KeyboardShortcuts
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var miniRecorderController: MiniRecorderWindowController?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var hotkeyEventTap: CFMachPort?
    private var hotkeyEventTapSource: CFRunLoopSource?
    var isHotkeyPressed = false
    private var cancellables = Set<AnyCancellable>()
    private var lastHandledHotkeyTimestamp: TimeInterval = 0
    private var lastHandledHotkeyPressedState = false
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One-time migration for the VoxBox rebrand: move the old SpeakType
        // Application Support folder (downloaded models, recordings) to the
        // new name so nothing has to re-download.
        migrateLegacyStorageIfNeeded()

        AppearanceController.shared.apply(AppTheme.stored)

        // Scan local models at launch so the pill does not race an empty
        // downloadProgress map when the dashboard has never appeared.
        _ = ModelDownloadService.shared

        miniRecorderController = MiniRecorderWindowController()
        // Prepare the resting pill. It stays hidden until recording unless the
        // user opts into always showing it (issue #100).
        miniRecorderController?.showIdleRecorder()

        // React to the "always show recorder pill" toggle at runtime.
        NotificationCenter.default.addObserver(
            forName: .recorderIdleVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.miniRecorderController?.applyIdleVisibilityPreference()
        }

        // React to the "recorder pill position" change at runtime. The
        // controller defers the actual move while a recording is in progress
        // so the HUD doesn't jump under the user's cursor.
        NotificationCenter.default.addObserver(
            forName: .recorderPillPositionChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.miniRecorderController?.applyPillPosition()
        }

        // Reposition the pill when displays change (external monitor
        // connected/disconnected, dock resized, etc.) so it doesn't end up
        // off-screen relative to the new layout.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.miniRecorderController?.handleScreenParametersChanged()
        }

        // Pin the process Dock tile to the in-app mark. Launch Services otherwise
        // keeps the icon from /Applications/VoxBox.app when this debug product
        // is also named voxbox.app (APFS is case-insensitive).
        applyDockIcon()

        // Only show the Dock icon while the dashboard is actually open; otherwise
        // live quietly in the menu bar.
        observeWindowsForDockIcon()

        // Setup dynamic hotkey monitoring based on user selection
        setupHotkeyMonitoring()
        PermissionService.shared.startMonitoring()

        // Enforce local data retention (auto-delete old WAVs / expired
        // transcripts) now and hourly from here on.
        RetentionService.shared.start()

        UpdateService.shared.showUpdateWindowPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.showUpdateWindow()
            }
            .store(in: &cancellables)

        // Daily check is opt-in (Settings → Updates). Off by default so a
        // fresh install never contacts the network on its own.
        UpdateService.shared.checkForUpdatesOnLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Rename `~/Library/Application Support/SpeakType` → `VoxBox` once, so
    /// models and recordings from a pre-rebrand install carry over. No-op when
    /// there is nothing to migrate or the new folder already exists.
    private func migrateLegacyStorageIfNeeded() {
        let fileManager = FileManager.default
        guard
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return }

        let legacy = appSupport.appendingPathComponent("SpeakType", isDirectory: true)
        let current = appSupport.appendingPathComponent("VoxBox", isDirectory: true)

        guard fileManager.fileExists(atPath: legacy.path),
            !fileManager.fileExists(atPath: current.path)
        else { return }

        do {
            try fileManager.moveItem(at: legacy, to: current)
            AppLogger.info("Migrated legacy SpeakType storage to VoxBox", category: AppLogger.app)
        } catch {
            AppLogger.error(
                "Legacy storage migration failed", error: error, category: AppLogger.app)
        }
    }

    // MARK: - Dock icon visibility (accessory ↔ regular)

    /// VoxBox should feel like a menu-bar app: the Dock icon appears only while
    /// the main dashboard window is open, and disappears (leaving the menu-bar
    /// item + floating pill) once it's closed. We do this by flipping the app's
    /// activation policy between `.regular` (Dock icon) and `.accessory` (no Dock
    /// icon, still in the menu bar) as dashboard windows open and close.
    private func observeWindowsForDockIcon() {
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDockIconVisibility()
            }
        }
        // `willClose` fires while the window is still in `NSApp.windows`; re-check
        // on the next runloop tick, once it has actually left the list.
        nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            [weak self] _ in
            DispatchQueue.main.async { self?.refreshDockIconVisibility() }
        }
        // Settle the initial state once SwiftUI has had a chance to open any
        // launch window.
        DispatchQueue.main.async { [weak self] in self?.refreshDockIconVisibility() }
    }

    /// Whether a window is the main dashboard (as opposed to the menu-bar extra
    /// popover, the borderless recorder pill panel, or a system status window) —
    /// i.e. the only kind of window that should light up the Dock icon.
    private func isDashboardWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        if window is NSPanel { return false }  // recorder pill + menu-bar popover
        if let id = window.identifier?.rawValue, id.contains("main-dashboard") { return true }
        // Fallback for windows SwiftUI doesn't tag: a large content window that
        // isn't a system status/popup window.
        let cls = String(describing: type(of: window))
        if cls.contains("StatusBar") || cls.contains("Popup") || cls.contains("MenuBar") {
            return false
        }
        return window.frame.width >= 600 && window.frame.height >= 400
    }

    private func refreshDockIconVisibility() {
        let dashboardOpen = NSApp.windows.contains(where: isDashboardWindow)
        let target: NSApplication.ActivationPolicy = dashboardOpen ? .regular : .accessory
        let current = NSApp.activationPolicy()
        guard current != target else { return }
        NSApp.setActivationPolicy(target)
        if target == .regular {
            applyDockIcon()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Force this process's Dock / Cmd-Tab tile to this bundle's app icon so
    /// Launch Services cannot keep showing /Applications/VoxBox.app.
    ///
    /// Prefer the compiled AppIcon (full-bleed Liquid Glass). AppLogo is the
    /// 824-on-1024 branding plate — Dock would nest that squircle and the mark
    /// would sit ~10% small — so the fallback scales the plate to fill.
    private func applyDockIcon() {
        if let icon = NSImage(named: NSImage.applicationIconName), icon.size.width > 0 {
            NSApp.applicationIconImage = icon
            return
        }
        guard let logo = NSImage(named: "AppLogo") else { return }
        NSApp.applicationIconImage = Self.dockIconFillingBrandingPlate(logo)
    }

    /// Scale the 824-on-1024 branding plate so it fills a 1024pt Dock tile.
    private static func dockIconFillingBrandingPlate(_ logo: NSImage) -> NSImage {
        let canvas: CGFloat = 1024
        let scale = canvas / 824
        let size = NSSize(width: canvas, height: canvas)
        let image = NSImage(size: size)
        let pixels = Int(canvas * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return logo }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let drawSide = canvas * scale
        let origin = (canvas - drawSide) / 2
        logo.draw(
            in: NSRect(x: origin, y: origin, width: drawSide, height: drawSide),
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Emoji Picker Suppression

    /// Terminal emulators (and editors with integrated terminals) that render the
    /// synthetic F19 from `suppressEmojiPicker()` as stray control characters in
    /// the prompt. We skip emoji-picker suppression while one of these is
    /// frontmost so the injected key never leaks into the terminal.
    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "co.zeit.hyper",
        "org.tabby",
        "com.microsoft.VSCode",
        "com.vscodium",
        "com.todesktop.230313mzl4w4u92",  // Cursor
    ]

    /// Whether the frontmost app is a terminal where injecting a synthetic key
    /// would surface as visible garbage characters.
    private static func isFrontmostAppTerminal() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return terminalBundleIdentifiers.contains(bundleID)
    }

    /// F19 — posted by suppressEmojiPicker(). The synthetic event inherits the live
    /// modifier state (including the held Fn flag), so the modifier-combo cancel
    /// guard must ignore this key code or it cancels the recording it just started.
    private static let emojiSuppressionKeyCode: CGKeyCode = 0x50  // F19 (80)

    /// Whether pressing the Globe/Fn key is configured to show the emoji picker.
    /// The synthetic-F19 suppression is only needed in that case; injecting it
    /// otherwise (Do Nothing / Change Input Source / Dictation) just causes the
    /// macOS alert beep for an unhandled key. Reads `AppleFnUsageType` from
    /// com.apple.HIToolbox: 0 = Do Nothing, 1 = Change Input Source,
    /// 2 = Show Emoji & Symbols, 3 = Start Dictation.
    private static func globeKeyShowsEmojiPicker() -> Bool {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        if let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int {
            return value == 2
        }
        // Unknown → assume it could show the picker, so we still suppress it.
        return true
    }

    private func suppressEmojiPicker() {
        // A robust way to suppress the emoji picker is to post a harmless keydown/keyup
        // with the F19 key (a non-modifier key), which immediately breaks the Globe key's double-tap
        // or press-and-release listener without causing a spurious flagsChanged event.
        let dummyKeyCode = Self.emojiSuppressionKeyCode
        let eventSource = CGEventSource(stateID: .hidSystemState)

        if let keyDown = CGEvent(
            keyboardEventSource: eventSource, virtualKey: dummyKeyCode, keyDown: true)
        {
            keyDown.post(tap: .cghidEventTap)
        }

        if let keyUp = CGEvent(
            keyboardEventSource: eventSource, virtualKey: dummyKeyCode, keyDown: false)
        {
            keyUp.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Hotkey Monitoring

    private static var didRegisterHotkeyMonitors = false

    private func setupHotkeyMonitoring() {
        guard !Self.didRegisterHotkeyMonitors else { return }
        Self.didRegisterHotkeyMonitors = true
        setupSuppressingHotkeyEventTap()
        setupCustomShortcutHandlers()

        // Add global monitor for hotkey events
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleHotkeyEvent(event)
        }

        // Add local monitor for hotkey events (same logic)
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleHotkeyEvent(event)
            return event
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleModifierComboEvent(event)
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleModifierComboEvent(event)
            return event
        }
    }

    private func setupSuppressingHotkeyEventTap() {
        guard hotkeyEventTap == nil else { return }

        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            return appDelegate.handleHotkeyEventTap(type: type, event: event)
        }

        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            print("Failed to create suppressing hotkey event tap")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        hotkeyEventTap = eventTap
        hotkeyEventTapSource = runLoopSource
    }

    private func handleHotkeyEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let hotkeyEventTap {
                CGEvent.tapEnable(tap: hotkeyEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let currentHotkey = getSelectedHotkey()
        guard currentHotkey == .fn else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == currentHotkey.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let isPressed = event.flags.contains(.maskSecondaryFn)
        DispatchQueue.main.async { [weak self] in
            self?.handleHotkeyStateChange(isPressed: isPressed)
        }

        // Suppress the Fn flagsChanged event so terminal apps do not receive raw CSI sequences.
        return nil
    }

    private func handleHotkeyEvent(_ event: NSEvent) {
        let currentHotkey = getSelectedHotkey()
        guard event.keyCode == currentHotkey.keyCode else { return }

        let isPressed = event.modifierFlags.contains(currentHotkey.modifierFlag)
        handleHotkeyStateChange(isPressed: isPressed)
    }

    private func handleHotkeyStateChange(isPressed: Bool) {
        guard !isDuplicateHotkeyEvent(isPressed: isPressed) else { return }

        let currentHotkey = getSelectedHotkey()
        if isPressed && !isHotkeyPressed {
            isHotkeyPressed = true

            // Only inject the synthetic F19 when the Globe/Fn key is actually
            // configured to show the emoji picker — otherwise there's nothing to
            // suppress and the unhandled F19 just triggers the macOS alert beep.
            // Also skipped for terminals, which echo it as stray control characters.
            if currentHotkey == .fn && !Self.isFrontmostAppTerminal()
                && Self.globeKeyShowsEmojiPicker()
            {
                suppressEmojiPicker()
            }

            if RecordingMode.current() == .toggle {
                if AudioRecordingService.shared.isRecording {
                    miniRecorderController?.stopRecording()
                } else {
                    miniRecorderController?.startRecording()
                }
            } else {
                miniRecorderController?.startRecording()
            }
        } else if !isPressed && isHotkeyPressed {
            isHotkeyPressed = false

            if RecordingMode.current() == .hold {
                miniRecorderController?.stopRecording()
            }
        }
    }

    /// Wire the user-recorded key combination (HotkeyOption.custom, e.g. ⌘D).
    /// KeyboardShortcuts delivers keyDown/keyUp for the recorded combo, which
    /// maps cleanly onto both recording modes: hold-to-record uses down/up,
    /// toggle mode flips on each press. Handlers are inert unless the selected
    /// hotkey is the custom one, so a stored combo can't fire while Fn is active.
    private func setupCustomShortcutHandlers() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            guard let self, self.getSelectedHotkey() == .custom else { return }

            if RecordingMode.current() == .toggle {
                if AudioRecordingService.shared.isRecording {
                    self.miniRecorderController?.stopRecording()
                } else {
                    self.miniRecorderController?.startRecording()
                }
            } else {
                self.miniRecorderController?.startRecording()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            guard let self, self.getSelectedHotkey() == .custom else { return }
            guard RecordingMode.current() == .hold else { return }
            self.miniRecorderController?.stopRecording()
        }

        KeyboardShortcuts.onKeyDown(for: .copyLastTranscript) { [weak self] in
            self?.miniRecorderController?.copyLastTranscriptToClipboard()
        }
    }

    private func handleModifierComboEvent(_ event: NSEvent) {
        guard isHotkeyPressed else { return }
        guard RecordingMode.current() == .hold else { return }
        guard !event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return }
        guard event.keyCode != getSelectedHotkey().keyCode else { return }
        // Ignore the synthetic F19 posted by suppressEmojiPicker() — it carries the
        // held Fn flag and would otherwise cancel the recording immediately.
        guard event.keyCode != Self.emojiSuppressionKeyCode else { return }

        isHotkeyPressed = false
        miniRecorderController?.cancelRecording()
    }

    private func isDuplicateHotkeyEvent(isPressed: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let isDuplicate =
            abs(now - lastHandledHotkeyTimestamp) < 0.05
            && lastHandledHotkeyPressedState == isPressed

        lastHandledHotkeyTimestamp = now
        lastHandledHotkeyPressedState = isPressed
        return isDuplicate
    }

    private func getSelectedHotkey() -> HotkeyOption {
        // Migration: Check if old useFnKey setting exists
        if UserDefaults.standard.object(forKey: "useFnKey") != nil {
            let useFnKey = UserDefaults.standard.bool(forKey: "useFnKey")
            if useFnKey {
                UserDefaults.standard.set(HotkeyOption.fn.rawValue, forKey: "selectedHotkey")
                UserDefaults.standard.removeObject(forKey: "useFnKey")
                return .fn
            }
        }

        if let rawValue = UserDefaults.standard.string(forKey: "selectedHotkey"),
            let option = HotkeyOption(rawValue: rawValue)
        {
            return option
        }

        return .fn
    }

    // MARK: - Update Checking
    //
    // Launch-time checks run only when the user has opted into "Check for
    // updates daily". Otherwise the app stays offline until they tap
    // "Check for Updates" (or download a model).

    private func showUpdateWindow() {
        guard let update = UpdateService.shared.availableUpdate else { return }

        let updateSheetView = UpdateSheet(update: update)
        let hostingController = NSHostingController(rootView: updateSheetView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Software Update"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.isMovableByWindowBackground = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
