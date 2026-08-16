import SwiftUI
import XCTest
@testable import voxbox

final class PreferenceAndOnboardingTests: XCTestCase {

    func testSidebarPermissionChipsHideOnlyWhenBothGranted() {
        XCTAssertFalse(
            PermissionService.shouldShowSidebarStatus(micGranted: true, accessibilityGranted: true)
        )
        XCTAssertTrue(
            PermissionService.shouldShowSidebarStatus(micGranted: false, accessibilityGranted: true)
        )
        XCTAssertTrue(
            PermissionService.shouldShowSidebarStatus(micGranted: true, accessibilityGranted: false)
        )
        XCTAssertTrue(
            PermissionService.shouldShowSidebarStatus(micGranted: false, accessibilityGranted: false)
        )
    }

    func testCopyTranscriptToClipboardDefaultsOff() {
        XCTAssertFalse(TranscriptClipboardPreference.defaultEnabled)
        XCTAssertEqual(TranscriptClipboardPreference.defaultsKey, "copyTranscriptToClipboard")

        let suite = "voxbox.tests.clipboard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(TranscriptClipboardPreference.isEnabled(in: defaults))

        defaults.set(true, forKey: TranscriptClipboardPreference.defaultsKey)
        XCTAssertTrue(TranscriptClipboardPreference.isEnabled(in: defaults))

        defaults.set(false, forKey: TranscriptClipboardPreference.defaultsKey)
        XCTAssertFalse(TranscriptClipboardPreference.isEnabled(in: defaults))
    }

    func testParakeetIncompleteCacheIsNotInstalled() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxbox-parakeet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try Data("leftover".utf8).write(to: temp.appendingPathComponent("Decoder.mlmodelc"))

        XCTAssertFalse(ParakeetCatalog.isPresent(at: temp, variant: ParakeetCatalog.v3Variant))
        XCTAssertFalse(ParakeetCatalog.isPresent(at: temp, variant: ParakeetCatalog.v2Variant))
        XCTAssertFalse(ParakeetCatalog.isPresent(at: temp, variant: ParakeetCatalog.ctc110mVariant))
    }

    func testHasDownloadedModelRequiresCompletedProgress() {
        XCTAssertFalse(ModelDownloadService.hasDownloadedModel(in: [:]))
        XCTAssertFalse(ModelDownloadService.hasDownloadedModel(in: ["tiny": 0.4]))
        XCTAssertTrue(ModelDownloadService.hasDownloadedModel(in: ["tiny": 1.0]))
        XCTAssertTrue(ModelDownloadService.hasDownloadedModel(in: ["tiny": 0.2, "base": 1.0]))
    }

    func testPillStatusCopyMatchesProductCopy() {
        XCTAssertEqual(PillStatusCopy.transcribing, "Transcribing...")
        XCTAssertEqual(PillStatusCopy.tidyingUp, "Tidying up...")
        XCTAssertEqual(PillStatusCopy.noDestination, "No destination. Copied to clipboard...")
        XCTAssertEqual(
            PillStatusCopy.noModels,
            "No models detected. Click to download a model"
        )
        XCTAssertEqual(ModelLoadCopy.preparing, "Preparing the model for use…")
        XCTAssertEqual(ModelLoadCopy.firstLoadHint, "First load can take a moment")
        XCTAssertEqual(ModelLoadCopy.takingLonger, "Taking longer than expected…")
    }

    func testUpdateSigningTeamIsConfigured() {
        XCTAssertFalse(UpdateService.trustedUpdateTeamIdentifier.isEmpty)
        XCTAssertEqual(UpdateService.trustedUpdateTeamIdentifier, "K8S7G9UFR8")
        XCTAssertEqual(UpdateService.trustedUpdateBundleIdentifier, "dev.edlittle.VoxBox")
    }

    func testSystemThemeReevaluatesAgainstMacAppearance() {
        XCTAssertEqual(AppTheme.resolvedColorScheme(for: .light, systemIsDark: true), .light)
        XCTAssertEqual(AppTheme.resolvedColorScheme(for: .dark, systemIsDark: false), .dark)
        XCTAssertEqual(AppTheme.resolvedColorScheme(for: .system, systemIsDark: true), .dark)
        XCTAssertEqual(AppTheme.resolvedColorScheme(for: .system, systemIsDark: false), .light)

        let suite = "voxbox.tests.appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(AppTheme.systemIsDark(defaults: defaults))
        defaults.set("Dark", forKey: "AppleInterfaceStyle")
        XCTAssertTrue(AppTheme.systemIsDark(defaults: defaults))
        defaults.set("Light", forKey: "AppleInterfaceStyle")
        XCTAssertFalse(AppTheme.systemIsDark(defaults: defaults))
    }

    func testAppleEngineKindRoutesFromCatalogVariant() {
        XCTAssertEqual(AIModel.engineKind(for: AppleSpeechCatalog.variant), .apple)
        XCTAssertEqual(TranscriptionEngineKind.apple.displayName, "Apple")
        XCTAssertEqual(TranscriptionEngineKind.apple.rawValue, "apple")
        XCTAssertTrue(TranscriptionEngineKind.allCases.contains(.apple))
        XCTAssertEqual(AIModel.models(for: .apple).map(\.variant), [AppleSpeechCatalog.variant])
    }

    func testRecommendedModelIsAppleStarter() {
        let recommended = AIModel.recommendedModel()
        XCTAssertEqual(recommended.engine, .apple)
        XCTAssertEqual(recommended.variant, AppleSpeechCatalog.variant)
        XCTAssertEqual(
            AIModel.recommendationReason(for: recommended),
            "Built-in Apple speech — Get started with built in models, or download a model that fits your needs better."
        )
    }

    func testModelSelectionAppliesAppleOnlyWhenEmpty() {
        let suite = "voxbox.tests.apple-starter.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(ModelSelection.hasExplicitSelection(in: defaults))
        XCTAssertEqual(ModelSelection.applyStarterIfNeeded(in: defaults, appleReady: false), ModelSelection.none)
        XCTAssertFalse(ModelSelection.hasExplicitSelection(in: defaults))

        XCTAssertEqual(
            ModelSelection.applyStarterIfNeeded(in: defaults, appleReady: true),
            AppleSpeechCatalog.variant
        )
        XCTAssertTrue(ModelSelection.hasExplicitSelection(in: defaults))
        XCTAssertEqual(
            defaults.string(forKey: ModelSelection.defaultsKey),
            AppleSpeechCatalog.variant
        )

        defaults.set(ParakeetCatalog.v3Variant, forKey: ModelSelection.defaultsKey)
        XCTAssertEqual(
            ModelSelection.applyStarterIfNeeded(in: defaults, appleReady: true),
            ParakeetCatalog.v3Variant
        )
        XCTAssertEqual(
            defaults.string(forKey: ModelSelection.defaultsKey),
            ParakeetCatalog.v3Variant
        )
    }

    func testStartRecordingHintUsesCurrentInvocationCommand() {
        XCTAssertEqual(
            RecordingHotkeyCopy.startRecordingHint(selectedHotkey: .fn),
            "Press Fn to start recording"
        )
        XCTAssertEqual(
            RecordingHotkeyCopy.startRecordingHint(selectedHotkey: .rightCommand),
            "Press Right ⌘ to start recording"
        )
        XCTAssertEqual(
            RecordingHotkeyCopy.startRecordingHint(selectedHotkey: .leftOption),
            "Press Left ⌥ to start recording"
        )
        XCTAssertEqual(
            RecordingHotkeyCopy.startRecordingHint(
                selectedHotkey: .custom,
                customShortcutDescription: "⌘D"
            ),
            "Press ⌘D to start recording"
        )
        XCTAssertEqual(
            RecordingHotkeyCopy.startRecordingHint(selectedHotkey: .custom),
            "Press your shortcut to start recording"
        )
        XCTAssertEqual(HotkeyOption.default, .fn)
        XCTAssertEqual(HotkeyOption.defaultsKey, "selectedHotkey")
    }

    func testVersionComparisonTreatsPatchAsNewer() {
        XCTAssertTrue(AppVersion.isNewerVersion("1.0.4", than: "1.0.3"))
        XCTAssertFalse(AppVersion.isNewerVersion("1.0.3", than: "1.0.3"))
        XCTAssertFalse(AppVersion.isNewerVersion("1.0.2", than: "1.0.3"))
    }
}
