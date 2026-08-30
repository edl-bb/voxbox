import AppKit
import ApplicationServices
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

    func testTranscriptDeliveryModeDefaultsToAutoPaste() {
        XCTAssertEqual(TranscriptDeliveryMode.defaultMode, .autoPaste)
        XCTAssertEqual(TranscriptDeliveryMode.defaultsKey, "transcriptDeliveryMode")

        let suite = "voxbox.tests.delivery.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(defaults.object(forKey: TranscriptDeliveryMode.defaultsKey))
        XCTAssertEqual(TranscriptDeliveryMode.current(in: defaults), .autoPaste)
        XCTAssertEqual(
            defaults.string(forKey: TranscriptDeliveryMode.defaultsKey),
            TranscriptDeliveryMode.autoPaste.rawValue
        )
        XCTAssertFalse(TranscriptClipboardPreference.isEnabled(in: defaults))
        XCTAssertFalse(StreamingMode.isEnabled(in: defaults))
    }

    func testTranscriptDeliveryModeDisplayNamesMatchStageNames() {
        XCTAssertEqual(
            TranscriptDeliveryMode.clipboard.displayName,
            "Copy transcription to clipboard"
        )
        XCTAssertEqual(
            TranscriptDeliveryMode.autoPaste.displayName,
            "Auto paste transcription"
        )
        XCTAssertEqual(
            TranscriptDeliveryMode.streaming.displayName,
            "Stream transcription"
        )
        XCTAssertEqual(TranscriptDeliveryMode.clipboard.segmentLabel, "Copy to clipboard")
        XCTAssertEqual(TranscriptDeliveryMode.autoPaste.segmentLabel, "Auto-paste")
        XCTAssertEqual(TranscriptDeliveryMode.streaming.segmentLabel, "Stream")
        XCTAssertEqual(
            TranscriptDeliveryMode.clipboard.summary,
            "Copies the finished transcript to the clipboard."
        )
        XCTAssertEqual(
            TranscriptDeliveryMode.autoPaste.summary,
            "Waits until you stop, then pastes the finished transcript into the app you were in."
        )
        XCTAssertEqual(
            TranscriptDeliveryMode.streaming.summary,
            "The transcription is streamed into the destination text area as it appears and is processed."
        )
    }

    func testTranscriptDeliveryModeMigratesFromLegacyFlags() {
        func suiteDefaults() -> (UserDefaults, String) {
            let name = "voxbox.tests.delivery.migrate.\(UUID().uuidString)"
            return (UserDefaults(suiteName: name)!, name)
        }

        let (streamingDefaults, streamingSuite) = suiteDefaults()
        defer { streamingDefaults.removePersistentDomain(forName: streamingSuite) }
        streamingDefaults.set(true, forKey: StreamingMode.defaultsKey)
        XCTAssertEqual(TranscriptDeliveryMode.current(in: streamingDefaults), .streaming)

        let (clipboardDefaults, clipboardSuite) = suiteDefaults()
        defer { clipboardDefaults.removePersistentDomain(forName: clipboardSuite) }
        clipboardDefaults.set(true, forKey: TranscriptClipboardPreference.defaultsKey)
        XCTAssertEqual(TranscriptDeliveryMode.current(in: clipboardDefaults), .clipboard)

        let (neitherDefaults, neitherSuite) = suiteDefaults()
        defer { neitherDefaults.removePersistentDomain(forName: neitherSuite) }
        XCTAssertEqual(TranscriptDeliveryMode.current(in: neitherDefaults), .autoPaste)

        let (bothDefaults, bothSuite) = suiteDefaults()
        defer { bothDefaults.removePersistentDomain(forName: bothSuite) }
        bothDefaults.set(true, forKey: StreamingMode.defaultsKey)
        bothDefaults.set(true, forKey: TranscriptClipboardPreference.defaultsKey)
        XCTAssertEqual(TranscriptDeliveryMode.current(in: bothDefaults), .streaming)
        XCTAssertTrue(StreamingMode.isEnabled(in: bothDefaults))
        XCTAssertFalse(TranscriptClipboardPreference.isEnabled(in: bothDefaults))
    }

    func testClipboardCommitPlanNeverRequestsPaste() {
        XCTAssertEqual(
            TranscriptCommitPlanner.plan(
                mode: .clipboard, canPaste: true, restoreClipboard: true),
            .copyOnly
        )
        XCTAssertEqual(
            TranscriptCommitPlanner.plan(
                mode: .clipboard, canPaste: false, restoreClipboard: false),
            .copyOnly
        )
    }

    func testAutoPasteWithNoTargetStillCopies() {
        XCTAssertEqual(
            TranscriptCommitPlanner.plan(
                mode: .autoPaste, canPaste: false, restoreClipboard: true),
            .copyOnly
        )
        XCTAssertEqual(
            TranscriptCommitPlanner.plan(
                mode: .autoPaste, canPaste: true, restoreClipboard: true),
            .paste(restoreClipboard: true)
        )
        XCTAssertEqual(
            TranscriptCommitPlanner.plan(
                mode: .autoPaste, canPaste: true, restoreClipboard: false),
            .paste(restoreClipboard: false)
        )
        XCTAssertEqual(
            TranscriptCommitPlanner.plan(
                mode: .streaming, canPaste: false, restoreClipboard: true),
            .copyOnly
        )
        XCTAssertEqual(
            TranscriptCommitPlanner.plan(
                mode: .streaming, canPaste: true, restoreClipboard: true),
            .paste(restoreClipboard: true)
        )
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

    func testAppTintStaysReadableInDarkMode() {
        let nsColor = NSColor(Color.navyInk)

        func brightness(in appearance: NSAppearance) -> CGFloat {
            var value: CGFloat = 0
            appearance.performAsCurrentDrawingAppearance {
                nsColor.usingColorSpace(.sRGB)?
                    .getHue(nil, saturation: nil, brightness: &value, alpha: nil)
            }
            return value
        }

        let dark = brightness(in: NSAppearance(named: .darkAqua)!)
        let light = brightness(in: NSAppearance(named: .aqua)!)

        XCTAssertGreaterThan(
            dark,
            0.6,
            "Menu chevrons inherit the app tint and vanish on dark backgrounds if navyInk stays dark"
        )
        XCTAssertLessThan(light, 0.4)
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

    func testRestoreAllSelectsTheFnPresetAfterACustomShortcut() {
        let suite = "voxbox.tests.shortcut-reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(HotkeyOption.custom.rawValue, forKey: HotkeyOption.defaultsKey)
        ShortcutReset.restoreAll(in: defaults)

        XCTAssertEqual(
            defaults.string(forKey: HotkeyOption.defaultsKey),
            HotkeyOption.fn.rawValue
        )
    }

    func testClearingARecordedShortcutRestoresTheFactoryCombo() {
        let recorded = ShortcutReset.Recorded.copyLastTranscript
        let previous = ShortcutReset.capture(recorded)
        defer { ShortcutReset.restore(previous, for: recorded) }

        ShortcutReset.assignNonFactoryCombo(recorded)
        XCTAssertFalse(ShortcutReset.matchesFactory(recorded))

        ShortcutReset.recordedShortcutDidChange(cleared: true, for: recorded)
        XCTAssertTrue(ShortcutReset.matchesFactory(recorded))
    }

    func testRestoreAllRestoresRecordedShortcutsToFactoryCombos() {
        let copy = ShortcutReset.Recorded.copyLastTranscript
        let toggle = ShortcutReset.Recorded.toggleRecord
        let previousCopy = ShortcutReset.capture(copy)
        let previousToggle = ShortcutReset.capture(toggle)
        defer {
            ShortcutReset.restore(previousCopy, for: copy)
            ShortcutReset.restore(previousToggle, for: toggle)
        }

        ShortcutReset.assignNonFactoryCombo(copy)
        ShortcutReset.assignNonFactoryCombo(toggle)
        ShortcutReset.restoreRecordedShortcuts()

        XCTAssertTrue(ShortcutReset.matchesFactory(copy))
        XCTAssertTrue(ShortcutReset.matchesFactory(toggle))
    }

    func testStreamingModeSupportsAppleSpeechAndWhisperKit() {
        XCTAssertEqual(StreamingMode.defaultsKey, "streamingMode")
        XCTAssertTrue(StreamingMode.modelSupportsStreaming(AppleSpeechCatalog.variant))
        XCTAssertTrue(StreamingMode.modelSupportsStreaming("openai_whisper-tiny"))
        XCTAssertTrue(StreamingMode.modelSupportsStreaming("distil-whisper_distil-large-v3_594MB"))
        XCTAssertFalse(StreamingMode.modelSupportsStreaming(ParakeetCatalog.v3Variant))
        XCTAssertFalse(StreamingMode.modelSupportsStreaming(""))

        let suite = "voxbox.tests.streaming.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(StreamingMode.isEnabled(in: defaults))
        TranscriptDeliveryMode.set(.streaming, in: defaults)
        XCTAssertTrue(StreamingMode.isEnabled(in: defaults))
        TranscriptDeliveryMode.set(.autoPaste, in: defaults)
        XCTAssertFalse(StreamingMode.isEnabled(in: defaults))
    }

    func testFieldSpanSplicesReplacementAndClampsBounds() {
        let inserted = FieldSpan.splice(
            existing: "Hello world", start: 6, length: 0, replacement: "there ")
        XCTAssertEqual(inserted.value, "Hello there world")
        XCTAssertEqual(inserted.newLength, 6)

        let revised = FieldSpan.splice(
            existing: inserted.value, start: 6, length: 6, replacement: "friends ")
        XCTAssertEqual(revised.value, "Hello friends world")
        XCTAssertEqual(revised.newLength, 8)

        let reverted = FieldSpan.splice(
            existing: revised.value, start: 6, length: 8, replacement: "")
        XCTAssertEqual(reverted.value, "Hello world")
        XCTAssertEqual(reverted.newLength, 0)

        let clamped = FieldSpan.splice(
            existing: "Hi", start: 40, length: 8, replacement: "!")
        XCTAssertEqual(clamped.value, "Hi!")
        XCTAssertEqual(clamped.newLength, 1)

        let withEmoji = FieldSpan.splice(
            existing: "Hi 👋 there", start: 3, length: 2, replacement: "wave")
        XCTAssertEqual(withEmoji.value, "Hi wave there")
        XCTAssertEqual(withEmoji.newLength, 4)

        XCTAssertEqual(FieldSpan.region("Hello world", start: 6, length: 5), "world")
        XCTAssertNil(FieldSpan.region("Hi", start: 0, length: 8))
        XCTAssertEqual(FieldSpan.region("Hello world", start: 6, length: 5) == "world", true)
    }

    func testElectronShapedComposerSkipsAccessibilityRewrite() {
        XCTAssertEqual(
            LiveWriteStrategy.choose(hasWebMarkers: true, axValue: "\n"),
            .keystrokesOnly)
        XCTAssertEqual(
            LiveWriteStrategy.choose(hasWebMarkers: true, axValue: ""),
            .keystrokesOnly)
        XCTAssertEqual(
            LiveWriteStrategy.choose(hasWebMarkers: false, axValue: ""),
            .accessibilityRewrite)
        XCTAssertEqual(
            LiveWriteStrategy.choose(hasWebMarkers: true, axValue: "Hello"),
            .accessibilityRewrite)
        XCTAssertEqual(
            LiveWriteStrategy.choose(
                hasWebMarkers: false, axValue: "Hello", bundleIdentifier: "notion.id"),
            .keystrokesOnly)
        XCTAssertEqual(
            LiveWriteStrategy.choose(
                hasWebMarkers: false,
                axValue: "Hello",
                bundleIdentifier: "com.tinyspeck.slackmacgap"),
            .keystrokesOnly)
        XCTAssertFalse(LiveWriteStrategy.isElectronBundle("com.apple.Notes"))
        XCTAssertTrue(LiveWriteStrategy.isElectronBundle("com.todesktop.230313mzl4w4u92"))
    }

    func testKeystrokeCaretJumpMatchesNotionGlitch() {
        var field = KeystrokeField()
        field.apply(.type("This is"))
        field.caret = 0
        field.apply(.type(" a test right into notion. Yeah, OK, let’s just a bit silly"))
        XCTAssertEqual(
            field.text,
            " a test right into notion. Yeah, OK, let’s just a bit sillyThis is")
    }

    func testKeystrokeCaretRestoreKeepsNotionTranscriptInOrder() {
        XCTAssertFalse(CaretRestore.shouldMoveToEndOfLine(alreadyTyped: false))
        XCTAssertTrue(CaretRestore.shouldMoveToEndOfLine(alreadyTyped: true))
        XCTAssertEqual(CaretRestore.rightArrows(caret: 0, expected: 7), 7)
        XCTAssertEqual(CaretRestore.rightArrows(caret: 7, expected: 7), 0)

        var field = KeystrokeField()
        field.apply(.type("This is"))
        field.caret = 0
        if CaretRestore.shouldMoveToEndOfLine(alreadyTyped: true) {
            field.moveToEndOfLine()
        }
        field.apply(
            .type(" a test right into notion. Yeah, okay, that's just a bit silly."))
        XCTAssertEqual(
            field.text,
            "This is a test right into notion. Yeah, okay, that's just a bit silly.")
    }

    func testKeystrokeLivePlanOnlyAppends() {
        XCTAssertEqual(KeystrokeDelta.livePlan(previous: "", next: "Hello"), .type("Hello"))
        XCTAssertEqual(
            KeystrokeDelta.livePlan(previous: "Hello", next: "Hello there"),
            .type(" there"))
        XCTAssertEqual(KeystrokeDelta.livePlan(previous: "Hello there", next: "Hello"), .none)
        XCTAssertEqual(KeystrokeDelta.livePlan(previous: "Hello there", next: "Hi"), .none)
        XCTAssertEqual(KeystrokeDelta.livePlan(previous: "Hello", next: "Hello"), .none)
        XCTAssertEqual(
            KeystrokeDelta.livePlan(previous: "This is a test right into notion", next: "This"),
            .none)
        XCTAssertEqual(KeystrokeDelta.revertPlan(previous: "Hello there"), .delete(11))
        XCTAssertEqual(KeystrokeDelta.revertPlan(previous: ""), .none)
    }

    func testKeystrokeLivePlanRevisesTailAfterPhraseFinalizes() {
        XCTAssertEqual(
            KeystrokeDelta.livePlan(
                previous: "hello there this is a test",
                next: "Hello there this is a test of streaming"),
            .type(" of streaming"))
        XCTAssertEqual(
            KeystrokeDelta.livePlan(
                previous: "hello there this is a test of streaming and I keep talking",
                next: "Hello there this is a test. and I keep talking more"),
            .revise(delete: 32, type: ". and I keep talking more"))
        XCTAssertEqual(
            KeystrokeDelta.livePlan(
                previous: "a reasonably long hypothesis that should not be wiped",
                next: "OK"),
            .none)
    }

    func testUnicodeTypingChunksLongPhrases() {
        XCTAssertEqual(UnicodeTyping.chunks(""), [])
        XCTAssertEqual(UnicodeTyping.chunks("Hello"), ["Hello"])
        let phrase = String(repeating: "a", count: 45)
        XCTAssertEqual(
            UnicodeTyping.chunks(phrase),
            [String(repeating: "a", count: 20), String(repeating: "a", count: 20), "aaaaa"])
    }

    func testFormatterStripsCleanTextPreamble() {
        XCTAssertEqual(
            TranscriptFormatterService.stripModelPreamble("Here's the clean text:\nHello there."),
            "Hello there."
        )
        XCTAssertEqual(
            TranscriptFormatterService.stripModelPreamble("Cleaned text: Hello there."),
            "Hello there."
        )
        XCTAssertEqual(
            TranscriptFormatterService.stripModelPreamble("\"Hello there.\""),
            "Hello there."
        )
        XCTAssertEqual(
            TranscriptFormatterService.stripModelPreamble("Hello there."),
            "Hello there."
        )
    }

    func testNewWhisperKitCatalogVariantsAreOnCatalog() {
        XCTAssertEqual(
            AIModel.engineKind(for: "distil-whisper_distil-large-v3_594MB"),
            .whisper
        )
        XCTAssertEqual(
            AIModel.engineKind(for: "openai_whisper-large-v3-v20240930_626MB"),
            .whisper
        )
        XCTAssertTrue(StreamingMode.modelSupportsStreaming("distil-whisper_distil-large-v3_594MB"))
        XCTAssertTrue(
            AIModel.availableModels.contains { $0.variant == "distil-whisper_distil-large-v3_594MB" }
        )
        XCTAssertTrue(
            AIModel.availableModels.contains {
                $0.variant == "openai_whisper-large-v3-v20240930_626MB"
            }
        )
    }

    func testCatalogDecodeFilterDefaultsAndIncludes() {
        XCTAssertEqual(CatalogDecodeFilter.defaultFilter(streamingEnabled: false), .all)
        XCTAssertEqual(CatalogDecodeFilter.defaultFilter(streamingEnabled: true), .streaming)
        XCTAssertEqual(
            CatalogDecodeFilter.defaultFilter(
                streamingEnabled: false, selectedVariant: ParakeetCatalog.v3Variant),
            .batch
        )
        XCTAssertEqual(
            CatalogDecodeFilter.defaultFilter(
                streamingEnabled: false, selectedVariant: "openai_whisper-tiny"),
            .all
        )

        XCTAssertTrue(CatalogDecodeFilter.all.includes(variant: AppleSpeechCatalog.variant))
        XCTAssertTrue(CatalogDecodeFilter.all.includes(variant: ParakeetCatalog.v3Variant))
        XCTAssertTrue(CatalogDecodeFilter.streaming.includes(variant: AppleSpeechCatalog.variant))
        XCTAssertFalse(CatalogDecodeFilter.streaming.includes(variant: ParakeetCatalog.v3Variant))
        XCTAssertFalse(CatalogDecodeFilter.batch.includes(variant: AppleSpeechCatalog.variant))
        XCTAssertTrue(CatalogDecodeFilter.batch.includes(variant: ParakeetCatalog.v3Variant))
    }

    func testStreamingModeDisablesWhenBatchModelSelected() {
        let suite = "voxbox.tests.streaming.revert.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        TranscriptDeliveryMode.set(.streaming, in: defaults)
        XCTAssertTrue(
            StreamingMode.disableIfIncompatible(
                with: ParakeetCatalog.v3Variant, defaults: defaults))
        XCTAssertFalse(StreamingMode.isEnabled(in: defaults))
        XCTAssertEqual(TranscriptDeliveryMode.current(in: defaults), .autoPaste)

        TranscriptDeliveryMode.set(.streaming, in: defaults)
        XCTAssertFalse(
            StreamingMode.disableIfIncompatible(
                with: "openai_whisper-tiny", defaults: defaults))
        XCTAssertTrue(StreamingMode.isEnabled(in: defaults))

        XCTAssertFalse(StreamingMode.disableIfIncompatible(with: "", defaults: defaults))
        XCTAssertTrue(StreamingMode.isEnabled(in: defaults))
        XCTAssertFalse(
            StreamingMode.shouldRevertToBatch(for: "", streamingEnabled: true))
        XCTAssertTrue(
            StreamingMode.shouldRevertToBatch(
                for: ParakeetCatalog.v3Variant, streamingEnabled: true))
        XCTAssertTrue(
            StreamingMode.needsStreamingModel(
                variant: ParakeetCatalog.v3Variant, streamingEnabled: true))
        XCTAssertTrue(StreamingMode.needsStreamingModel(variant: "", streamingEnabled: true))
        XCTAssertFalse(
            StreamingMode.needsStreamingModel(
                variant: "openai_whisper-tiny", streamingEnabled: true))
        XCTAssertFalse(
            StreamingMode.needsStreamingModel(
                variant: ParakeetCatalog.v3Variant, streamingEnabled: false))
    }

    func testDictationTargetUsesElectronManualAccessibilityAttribute() {
        XCTAssertEqual(
            DictationTarget.manualAccessibilityAttribute as String,
            "AXManualAccessibility")
    }

    func testAXStringValueTreatsNoValueAsEmptyString() {
        XCTAssertEqual(AXStringValue.read(error: .success, value: "Hello" as CFTypeRef), "Hello")
        XCTAssertEqual(AXStringValue.read(error: .noValue, value: nil), "")
        XCTAssertNil(AXStringValue.read(error: .attributeUnsupported, value: nil))
        XCTAssertNil(AXStringValue.read(error: .success, value: 12 as CFTypeRef))
    }

    func testTargetFieldInserterWritesIntoAppKitTextField() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility is not trusted in this test host")
        }

        let field = NSTextField(string: "Hello ")
        field.isEditable = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = field
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(field.becomeFirstResponder())
        field.currentEditor()?.selectedRange = NSRange(
            location: (field.stringValue as NSString).length, length: 0)
        DictationTarget.processIdentifier = ProcessInfo.processInfo.processIdentifier

        let inserter = TargetFieldInserter()
        XCTAssertTrue(inserter.begin(), "AppKit text fields should bind for live rewrite")
        XCTAssertTrue(inserter.update("world"))
        XCTAssertEqual(field.stringValue, "Hello world")
        inserter.revert()
        XCTAssertEqual(field.stringValue, "Hello ")
        window.close()
    }

    func testTargetFieldInserterWritesIntoEmptyAppKitTextField() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility is not trusted in this test host")
        }

        let field = NSTextField(string: "")
        field.isEditable = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = field
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(field.becomeFirstResponder())
        DictationTarget.processIdentifier = ProcessInfo.processInfo.processIdentifier

        let inserter = TargetFieldInserter()
        XCTAssertTrue(inserter.begin())
        XCTAssertTrue(inserter.update("hello"))
        XCTAssertEqual(field.stringValue, "hello")
        inserter.revert()
        XCTAssertEqual(field.stringValue, "")
        window.close()
    }

    func testVersionComparisonTreatsPatchAsNewer() {
        XCTAssertTrue(AppVersion.isNewerVersion("1.0.4", than: "1.0.3"))
        XCTAssertFalse(AppVersion.isNewerVersion("1.0.3", than: "1.0.3"))
        XCTAssertFalse(AppVersion.isNewerVersion("1.0.2", than: "1.0.3"))
    }
}

/// Single-line composer used to replay keystroke plans. Caret is UTF-16.
private struct KeystrokeField {
    var text = ""
    var caret = 0

    mutating func apply(_ delta: KeystrokeDelta) {
        switch delta {
        case .none:
            return
        case .type(let suffix):
            insert(suffix)
        case .delete(let count):
            delete(count)
        case .revise(let count, let suffix):
            delete(count)
            insert(suffix)
        }
    }

    mutating func insert(_ suffix: String) {
        let ns = text as NSString
        let at = min(max(0, caret), ns.length)
        text = ns.substring(to: at) + suffix + ns.substring(from: at)
        caret = at + (suffix as NSString).length
    }

    mutating func delete(_ count: Int) {
        let ns = text as NSString
        let end = min(max(0, caret), ns.length)
        let start = max(0, end - count)
        text = ns.substring(to: start) + ns.substring(from: end)
        caret = start
    }

    mutating func moveToEndOfLine() {
        caret = (text as NSString).length
    }
}
