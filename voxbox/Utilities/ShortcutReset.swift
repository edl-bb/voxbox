import AppKit
import Foundation
import KeyboardShortcuts

/// Restores factory keyboard shortcuts after the user has customized them.
///
/// The KeyboardShortcuts recorder clears a combo to empty; VoxBox treats that
/// as revert-to-preset rather than "no shortcut". Restore Defaults also puts
/// the primary hotkey back on Fn.
enum ShortcutReset {
    enum Recorded {
        case toggleRecord
        case copyLastTranscript

        var name: KeyboardShortcuts.Name {
            switch self {
            case .toggleRecord: return .toggleRecord
            case .copyLastTranscript: return .copyLastTranscript
            }
        }
    }

#if DEBUG
    struct Capture {
        fileprivate let shortcut: KeyboardShortcuts.Shortcut?
    }

    static func capture(_ recorded: Recorded) -> Capture {
        Capture(shortcut: KeyboardShortcuts.getShortcut(for: recorded.name))
    }

    static func restore(_ capture: Capture, for recorded: Recorded) {
        KeyboardShortcuts.setShortcut(capture.shortcut, for: recorded.name)
    }

    static func assignNonFactoryCombo(_ recorded: Recorded) {
        KeyboardShortcuts.setShortcut(.init(.d, modifiers: [.command]), for: recorded.name)
    }

    static func matchesFactory(_ recorded: Recorded) -> Bool {
        KeyboardShortcuts.getShortcut(for: recorded.name) == recorded.name.defaultShortcut
    }
#endif

    static func restorePrimaryHotkey(in defaults: UserDefaults = .standard) {
        defaults.set(HotkeyOption.default.rawValue, forKey: HotkeyOption.defaultsKey)
    }

    static func restoreRecordedShortcuts() {
        KeyboardShortcuts.reset(.toggleRecord, .copyLastTranscript)
    }

    static func restoreAll(in defaults: UserDefaults = .standard) {
        restorePrimaryHotkey(in: defaults)
        restoreRecordedShortcuts()
    }

    static func recordedShortcutDidChange(cleared: Bool, for recorded: Recorded) {
        guard cleared else { return }
        KeyboardShortcuts.reset(recorded.name)
    }

    static func recordedShortcutDidChange(
        _ shortcut: KeyboardShortcuts.Shortcut?,
        for recorded: Recorded
    ) {
        recordedShortcutDidChange(cleared: shortcut == nil, for: recorded)
    }
}
