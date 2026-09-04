//
//  ModelSelection.swift
//  VoxBox
//
//  Single source of truth for the user's selected transcription model.
//
//  The selection is stored once, in UserDefaults under `selectedModelVariant`, and
//  read via @AppStorage from every screen. Previously an unused `AppSettings.selectedModel`
//  enum shadowed this, and the @AppStorage default diverged between screens (the
//  dashboard defaulted to a concrete variant while others defaulted to empty), so
//  "no model selected" meant different things in different places.
//

import Foundation

enum ModelSelection {
    /// UserDefaults key backing the user's chosen model variant.
    static let defaultsKey = "selectedModelVariant"

    /// Value meaning "no model selected yet" — the single shared default.
    static let none = ""

    /// Built-in Apple SpeechAnalyzer starter variant.
    static let appleStarterVariant = AppleSpeechCatalog.variant

    /// True when the user has already stored a concrete model choice.
    static func hasExplicitSelection(in defaults: UserDefaults = .standard) -> Bool {
        let value = defaults.string(forKey: defaultsKey) ?? none
        return !value.isEmpty
    }

    /// Select Apple for new / unchosen installs only. Existing Parakeet or
    /// Whisper picks are left untouched.
    @discardableResult
    static func applyStarterIfNeeded(
        in defaults: UserDefaults = .standard,
        appleReady: Bool
    ) -> String {
        if hasExplicitSelection(in: defaults) {
            return defaults.string(forKey: defaultsKey) ?? none
        }
        guard appleReady else { return none }
        defaults.set(appleStarterVariant, forKey: defaultsKey)
        return appleStarterVariant
    }
}

/// Legacy copy-to-clipboard toggle. Delivery is now `TranscriptDeliveryMode`;
/// this key is only read to migrate, and `isEnabled` follows clipboard mode.
enum TranscriptClipboardPreference {
    static let defaultsKey = "copyTranscriptToClipboard"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        TranscriptDeliveryMode.current(in: defaults) == .clipboard
    }
}

/// Pill labels used after dictation and when no model is installed.
enum PillStatusCopy {
    static let transcribing = "Transcribing..."
    static let tidyingUp = "Tidying up..."
    static let noDestination = "No destination. Copied to clipboard..."
    static let noModels = "No models detected. Click to download a model"
}

/// First-load copy while CoreML compiles a newly chosen model into memory.
enum ModelLoadCopy {
    static let preparing = "Preparing the model for use…"
    static let firstLoadHint = "First load can take a moment"
    static let takingLonger = "Taking longer than expected…"
}
