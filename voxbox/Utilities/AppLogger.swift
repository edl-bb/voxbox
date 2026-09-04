import Foundation
import OSLog

/// Unified logging for VoxBox
/// Usage: AppLogger.service.info("Model downloaded")
nonisolated enum AppLogger {
    /// General app lifecycle events
    static let app = Logger(subsystem: subsystem, category: "App")
    
    /// Audio recording events
    static let audio = Logger(subsystem: subsystem, category: "Audio")
    
    /// Transcription and WhisperKit events
    static let transcription = Logger(subsystem: subsystem, category: "Transcription")
    
    /// Model download and management
    static let models = Logger(subsystem: subsystem, category: "Models")
    
    /// Clipboard and pasteboard operations
    static let clipboard = Logger(subsystem: subsystem, category: "Clipboard")
    
    /// Hotkey and keyboard shortcuts
    static let hotkeys = Logger(subsystem: subsystem, category: "Hotkeys")
    
    /// UI and window management
    static let ui = Logger(subsystem: subsystem, category: "UI")
    
    /// General service operations
    static let service = Logger(subsystem: subsystem, category: "Service")
    
    /// History and persistence
    static let history = Logger(subsystem: subsystem, category: "History")
    
    /// Permissions and system access
    static let permissions = Logger(subsystem: subsystem, category: "Permissions")
    
    private static let subsystem = "dev.edlittle.VoxBox"
}

// MARK: - Convenience Methods
nonisolated extension AppLogger {
    // Debug builds log message text in the clear so `log show` is usable
    // while developing; release builds keep the system default (private).
    // Messages carry lengths, counts and states, never transcript text.

    /// Log with emoji prefix for better visual scanning
    static func info(_ message: String, category: Logger = AppLogger.service) {
        #if DEBUG
            category.info("ℹ️ \(message, privacy: .public)")
        #else
            category.info("ℹ️ \(message)")
        #endif
    }

    static func debug(_ message: String, category: Logger = AppLogger.service) {
        #if DEBUG
            category.debug("🔍 \(message, privacy: .public)")
        #else
            category.debug("🔍 \(message)")
        #endif
    }

    static func error(_ message: String, error: Error? = nil, category: Logger = AppLogger.service) {
        #if DEBUG
            if let error = error {
                category.error("❌ \(message, privacy: .public): \(error.localizedDescription, privacy: .public)")
            } else {
                category.error("❌ \(message, privacy: .public)")
            }
        #else
            if let error = error {
                category.error("❌ \(message): \(error.localizedDescription)")
            } else {
                category.error("❌ \(message)")
            }
        #endif
    }

    static func warning(_ message: String, category: Logger = AppLogger.service) {
        #if DEBUG
            category.warning("⚠️ \(message, privacy: .public)")
        #else
            category.warning("⚠️ \(message)")
        #endif
    }

    static func success(_ message: String, category: Logger = AppLogger.service) {
        #if DEBUG
            category.info("✅ \(message, privacy: .public)")
        #else
            category.info("✅ \(message)")
        #endif
    }
}

