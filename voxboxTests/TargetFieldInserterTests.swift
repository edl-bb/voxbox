import XCTest

@testable import voxbox

final class TargetFieldInserterTests: XCTestCase {
    private func snapshot(_ stable: String, _ revisable: String = "") -> LiveWriteInput {
        LiveWriteInput(LiveTranscriptSnapshot(stable: stable, revisable: revisable))
    }

    // MARK: - Accessibility rewrite

    func testAccessibilityRewriteReplacesOnlyOurSpan() {
        let field = FakeFieldWriter(text: "Before.  After", caret: 8)
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .accessibilityRewrite, bundleIdentifier: "com.apple.Notes", spanStart: 8)
        XCTAssertEqual(inserter.deliveryMode, .fullText)

        XCTAssertEqual(inserter.update(snapshot("Hi")), .wrote(.axReplace, chars: 2))
        XCTAssertEqual(field.text, "Before. Hi After")
        XCTAssertEqual(inserter.update(snapshot("Hi", "there")), .wrote(.axReplace, chars: 8))
        XCTAssertEqual(field.text, "Before. Hi there After")
        XCTAssertEqual(inserter.update(snapshot("Hi there 👋", "friend")), .wrote(.axReplace, chars: 18))
        XCTAssertEqual(field.text, "Before. Hi there 👋 friend After")
        XCTAssertEqual(inserter.update(snapshot("Hi there 👋", "friend")), .held(.unchanged))

        XCTAssertEqual(
            inserter.finalize(raw: "Hi there 👋 friend", cleaned: "Hi there 👋, friend."),
            .inField)
        XCTAssertEqual(field.text, "Before. Hi there 👋, friend. After")
        XCTAssertFalse(inserter.isActive)
    }

    func testAccessibilityRewriteFreezesOnDriftAndLeavesFieldAlone() {
        let field = FakeFieldWriter()
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .accessibilityRewrite, bundleIdentifier: nil, spanStart: 0)
        XCTAssertEqual(inserter.update(snapshot("Hello there")), .wrote(.axReplace, chars: 11))

        // The user (or the app) inserts text in front of our span.
        field.text = "X" + field.text

        XCTAssertEqual(inserter.update(snapshot("Hello there friend")), .frozen(.drift))
        XCTAssertEqual(inserter.deliveryMode, .none)
        XCTAssertEqual(inserter.update(snapshot("Hello there friend again")), .frozen(.drift))
        XCTAssertEqual(field.text, "XHello there")

        XCTAssertEqual(inserter.finalize(raw: "Hello there friend", cleaned: "Hello there, friend."), .unverified)
        XCTAssertEqual(field.text, "XHello there")
    }

    func testChromiumNoopBeforeFirstWriteSwitchesToKeystrokesOnce() {
        let field = FakeFieldWriter(text: "existing ", caret: 9)
        field.axSetIsNoop = true
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .accessibilityRewrite, bundleIdentifier: "com.google.Chrome", spanStart: 9)

        XCTAssertEqual(inserter.update(snapshot("Hello", "there")), .wrote(.append, chars: 5))
        XCTAssertEqual(inserter.strategy, .keystrokesOnly)
        XCTAssertEqual(inserter.deliveryMode, .stableOnly)
        XCTAssertEqual(field.text, "existing Hello")
        XCTAssertEqual(field.selectionLength, 0, "no span left selected for the next burst to replace")

        XCTAssertEqual(inserter.update(snapshot("Hello there", "friend")), .wrote(.append, chars: 6))
        XCTAssertEqual(field.text, "existing Hello there")
    }

    func testWebContentNeverMovesSelectionBeforeAWriteVerifies() {
        // Chromium contenteditable with a draft already in it: value sets are
        // ignored, selection sets are honoured. The old code selected first
        // and sent the caret to the start of the box.
        let field = FakeFieldWriter(text: "Existing draft ", caret: 15)
        field.axSetIsNoop = true
        let inserter = TargetFieldInserter()
        inserter.bind(
            writer: field, strategy: .accessibilityRewrite, bundleIdentifier: "com.example.web",
            spanStart: 15, isWebContent: true)

        XCTAssertEqual(inserter.update(snapshot("Hello", "there")), .wrote(.append, chars: 5))
        XCTAssertFalse(field.ops.contains { $0.hasPrefix("setSelection") }, "\(field.ops)")
        XCTAssertFalse(field.ops.contains { $0.hasPrefix("setSelectedText") })
        XCTAssertEqual(field.text, "Existing draft Hello")
        XCTAssertEqual(inserter.strategy, .keystrokesOnly)
    }

    func testWebContentValueWriteParksCaretOnlyAfterVerifying() {
        let field = FakeFieldWriter(text: "Draft ", caret: 6)
        let inserter = TargetFieldInserter()
        inserter.bind(
            writer: field, strategy: .accessibilityRewrite, bundleIdentifier: "com.apple.Safari",
            spanStart: 6, isWebContent: true)
        XCTAssertEqual(inserter.update(snapshot("Hello")), .wrote(.axReplace, chars: 5))
        XCTAssertEqual(field.text, "Draft Hello")
        XCTAssertEqual(field.caret, 11)
        let setValueIndex = field.ops.firstIndex { $0.hasPrefix("setValue") }!
        let setSelectionIndex = field.ops.firstIndex { $0.hasPrefix("setSelection") }!
        XCTAssertLessThan(setValueIndex, setSelectionIndex)
    }

    func testAccessibilityRefusedAfterWritingFreezesInsteadOfTyping() {
        let field = FakeFieldWriter()
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .accessibilityRewrite, bundleIdentifier: nil, spanStart: 0)
        XCTAssertEqual(inserter.update(snapshot("Hello")), .wrote(.axReplace, chars: 5))

        field.axSetIsNoop = true
        XCTAssertEqual(inserter.update(snapshot("Hello there")), .frozen(.axRefused))
        XCTAssertFalse(field.ops.contains { $0.hasPrefix("type(") })
        XCTAssertEqual(field.text, "Hello")
        XCTAssertEqual(inserter.finalize(raw: "Hello there", cleaned: "Hello there."), .unverified)
    }

    func testAccessibilityFinalWriteFailureClearsSpanAndHandsOffToPaste() {
        let field = FakeFieldWriter(text: "Pre ", caret: 4)
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .accessibilityRewrite, bundleIdentifier: nil, spanStart: 4)
        XCTAssertEqual(inserter.update(snapshot("Hello there")), .wrote(.axReplace, chars: 11))
        XCTAssertEqual(field.text, "Pre Hello there")

        field.rejectNonEmptySets = true
        XCTAssertEqual(inserter.finalize(raw: "Hello there", cleaned: "Hello there, friend."), .notWritten)
        XCTAssertEqual(field.text, "Pre ", "our span is gone so the paste path can deliver without a mix")
    }

    func testAccessibilityFinalizeWithNothingDeliveredStillWritesCleanedText() {
        let field = FakeFieldWriter()
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .accessibilityRewrite, bundleIdentifier: nil, spanStart: 0)
        XCTAssertEqual(inserter.finalize(raw: "hello", cleaned: "Hello."), .inField)
        XCTAssertEqual(field.text, "Hello.")
    }

    func testAccessibilityRevertRemovesSpanOnlyWhenItStillMatches() {
        let field = FakeFieldWriter(text: "AB", caret: 1)
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .accessibilityRewrite, bundleIdentifier: nil, spanStart: 1)
        _ = inserter.update(snapshot("Hello"))
        XCTAssertEqual(field.text, "AHelloB")
        inserter.revert()
        XCTAssertEqual(field.text, "AB")
        XCTAssertFalse(inserter.isActive)

        inserter.bind(writer: field, strategy: .accessibilityRewrite, bundleIdentifier: nil, spanStart: 1)
        _ = inserter.update(snapshot("Hello"))
        field.text = "ZZ" + field.text
        inserter.revert()
        XCTAssertEqual(field.text, "ZZAHelloB", "drifted span is left alone")
    }

    // MARK: - Append-only keystrokes

    func testKeystrokesMidTextStayAtTheCaretAcrossPauses() {
        // Claude: caret mid-text, no caret reset. Each committed burst must
        // land where the previous one ended, not at the end of the block.
        let field = FakeFieldWriter(text: "Intro paragraph.\n\nClosing line.", caret: 17)
        let inserter = TargetFieldInserter()
        inserter.bind(
            writer: field, strategy: .keystrokesOnly, bundleIdentifier: "com.anthropic.claudefordesktop",
            spanStart: 17, isElectronApp: true, isWebContent: true)

        XCTAssertEqual(inserter.update(snapshot("Hello there", "this is")), .wrote(.append, chars: 11))
        XCTAssertEqual(field.text, "Intro paragraph.\nHello there\nClosing line.")
        XCTAssertEqual(inserter.update(snapshot("Hello there this is a test", "")), .wrote(.append, chars: 15))
        XCTAssertEqual(field.text, "Intro paragraph.\nHello there this is a test\nClosing line.")
        XCTAssertFalse(field.ops.contains { $0.hasPrefix("moveCaret") })
        XCTAssertEqual(inserter.caretMovedCount, 0)

        XCTAssertEqual(
            inserter.finalize(raw: "Hello there this is a test", cleaned: "Hello there, this is a test."),
            .rawInField)
        XCTAssertEqual(field.text, "Intro paragraph.\nHello there this is a test\nClosing line.")
    }

    func testKeystrokesLogCaretMovesWithoutActingOnThem() {
        let field = FakeFieldWriter()
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .keystrokesOnly, bundleIdentifier: "com.example.resetting", spanStart: 0)
        _ = inserter.update(snapshot("Hello there"))
        // The app moves the caret between bursts.
        field.caret = 0
        _ = inserter.update(snapshot("Hello there friend"))
        XCTAssertEqual(inserter.caretMovedCount, 1)
        XCTAssertFalse(field.ops.contains { $0.hasPrefix("moveCaret") })
    }

    func testKeystrokesTypeOnlyStableWordsAndSurviveCaretReset() {
        // Escape hatch for an app that really does reset the caret.
        let field = FakeFieldWriter()
        field.resetCaretToStartAfterType = true
        let inserter = TargetFieldInserter()
        inserter.bind(
            writer: field, strategy: .keystrokesOnly, bundleIdentifier: "com.tinyspeck.slackmacgap",
            spanStart: 0, caretRestore: .some(.endOfDocument))
        XCTAssertEqual(inserter.deliveryMode, .stableOnly)

        XCTAssertEqual(inserter.update(snapshot("", "hello")), .held(.unchanged))
        XCTAssertEqual(field.text, "")

        XCTAssertEqual(inserter.update(snapshot("Hello there", "this is")), .wrote(.append, chars: 11))
        XCTAssertEqual(field.text, "Hello there")
        XCTAssertEqual(field.caret, 0, "Slack reset the caret after the burst")

        XCTAssertEqual(
            inserter.update(snapshot("Hello there this is a test", "of streaming")),
            .wrote(.append, chars: 15))
        XCTAssertEqual(field.text, "Hello there this is a test")
        XCTAssertTrue(field.ops.contains("moveCaret(endOfDocument)"))
        XCTAssertFalse(field.text.contains("of streaming"), "revisable text is never typed")

        XCTAssertEqual(
            inserter.update(snapshot("hello there this is a test", "")),
            .held(.stableDiverged))
        XCTAssertEqual(field.text, "Hello there this is a test")
        XCTAssertFalse(field.ops.contains { $0.hasPrefix("deleteBackward") }, "never deletes mid-take")
    }

    func testKeystrokesDoNotRestoreCaretInEditors() {
        let field = FakeFieldWriter(text: "let x = 1\n\nlet y = 2", caret: 10)
        let inserter = TargetFieldInserter()
        inserter.bind(
            writer: field, strategy: .keystrokesOnly, bundleIdentifier: "com.todesktop.230313mzl4w4u92",
            spanStart: 10, isElectronApp: true)
        _ = inserter.update(snapshot("// note"))
        _ = inserter.update(snapshot("// note about y"))
        XCTAssertEqual(field.text, "let x = 1\n// note about y\nlet y = 2")
        XCTAssertFalse(field.ops.contains { $0.hasPrefix("moveCaret") })
    }

    func testEndOfLineCaretRestoreReproducesMidParagraphJump() {
        // Documents the old bug: Cmd+→ after a caret reset lands at the end
        // of the first visual line, and the next burst is typed there.
        let field = FakeFieldWriter()
        field.visualLineWidth = 20
        field.type("This is a test of streaming into notion")
        field.caret = 0
        field.moveCaret(.endOfLine)
        field.type(" and more")
        XCTAssertEqual(field.text, "This is a test of st and morereaming into notion")

        let fixed = FakeFieldWriter()
        fixed.visualLineWidth = 20
        fixed.type("This is a test of streaming into notion")
        fixed.caret = 0
        fixed.moveCaret(.endOfDocument)
        fixed.type(" and more")
        XCTAssertEqual(fixed.text, "This is a test of streaming into notion and more")
    }

    func testKeystrokesHoldWhenDestinationIsNotFrontmost() {
        let field = FakeFieldWriter()
        var frontmost = true
        let inserter = TargetFieldInserter()
        inserter.bind(
            writer: field, strategy: .keystrokesOnly, bundleIdentifier: "com.tinyspeck.slackmacgap",
            spanStart: 0, isTargetFrontmost: { frontmost })
        XCTAssertEqual(inserter.update(snapshot("Hello")), .wrote(.append, chars: 5))
        frontmost = false
        XCTAssertEqual(inserter.update(snapshot("Hello there")), .held(.stableDiverged))
        XCTAssertEqual(field.text, "Hello")
        XCTAssertEqual(inserter.finalize(raw: "Hello there", cleaned: "Hello there."), .unverified)
        XCTAssertEqual(field.text, "Hello")
    }

    func testKeystrokeRevertDeletesGraphemesNotUTF16Units() {
        let field = FakeFieldWriter(text: "AB", caret: 2)
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .keystrokesOnly, bundleIdentifier: nil, spanStart: 2)
        _ = inserter.update(snapshot("Hi 👋 there"))
        XCTAssertEqual(field.text, "ABHi 👋 there")
        inserter.revert()
        XCTAssertEqual(field.text, "AB")
        XCTAssertTrue(field.ops.contains("deleteBackward(10)"), "10 graphemes, 11 UTF-16 units")
    }

    // MARK: - Finalize over keystrokes

    func testKeystrokeFinalizeCompletesRawThenLandsWhenCleanedMatches() {
        let field = FakeFieldWriter()
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .keystrokesOnly, bundleIdentifier: nil, spanStart: 0)
        _ = inserter.update(snapshot("Hello there"))
        XCTAssertEqual(
            inserter.finalize(raw: "Hello there friend", cleaned: "Hello there friend"),
            .inField)
        XCTAssertEqual(field.text, "Hello there friend")
    }

    func testKeystrokeFinalizeTypesCleanedTailWhenItOnlyExtends() {
        let field = FakeFieldWriter()
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .keystrokesOnly, bundleIdentifier: nil, spanStart: 0)
        _ = inserter.update(snapshot("Hello there"))
        XCTAssertEqual(
            inserter.finalize(raw: "Hello there friend", cleaned: "Hello there friend."),
            .inField)
        XCTAssertEqual(field.text, "Hello there friend.")
    }

    func testKeystrokeFinalizeKeepsRawWhenCleanedRewrites() {
        let field = FakeFieldWriter()
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .keystrokesOnly, bundleIdentifier: nil, spanStart: 0)
        _ = inserter.update(snapshot("um hello there"))
        XCTAssertEqual(
            inserter.finalize(raw: "um hello there friend", cleaned: "Hello there, friend."),
            .rawInField)
        XCTAssertEqual(field.text, "um hello there friend")
        XCTAssertFalse(field.ops.contains { $0.hasPrefix("deleteBackward") })
    }

    func testKeystrokeFinalizeToleratesTrailingWhitespaceFromTheLastBurst() {
        // Apple finals can end in a space; the engine trims its final text.
        let field = FakeFieldWriter()
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .keystrokesOnly, bundleIdentifier: nil, spanStart: 0)
        _ = inserter.update(snapshot("Hello there. "))
        XCTAssertEqual(field.text, "Hello there. ")

        XCTAssertEqual(
            inserter.finalize(raw: "Hello there. This is it", cleaned: "Hello there. This is it."),
            .inField)
        XCTAssertEqual(field.text, "Hello there. This is it.", "no doubled space at the seam")

        let unchanged = FakeFieldWriter()
        let second = TargetFieldInserter()
        second.bind(writer: unchanged, strategy: .keystrokesOnly, bundleIdentifier: nil, spanStart: 0)
        _ = second.update(snapshot("Hello there. "))
        XCTAssertEqual(second.finalize(raw: "Hello there.", cleaned: "Hello there."), .inField)
        XCTAssertEqual(unchanged.text, "Hello there. ")
    }

    func testKeystrokeFinalizeReportsPartialWhenRawDiverged() {
        let field = FakeFieldWriter()
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .keystrokesOnly, bundleIdentifier: nil, spanStart: 0)
        _ = inserter.update(snapshot("Hello there"))
        XCTAssertEqual(
            inserter.finalize(raw: "Hello their friend", cleaned: "Hello their friend."),
            .partialInField)
        XCTAssertEqual(field.text, "Hello there")
    }

    func testKeystrokeFinalizeWithNothingTypedHandsOffToPaste() {
        let field = FakeFieldWriter()
        let inserter = TargetFieldInserter()
        inserter.bind(writer: field, strategy: .keystrokesOnly, bundleIdentifier: nil, spanStart: 0)
        _ = inserter.update(snapshot("", "just a hypothesis"))
        XCTAssertEqual(inserter.finalize(raw: "just a hypothesis", cleaned: "Just a hypothesis."), .notWritten)
        XCTAssertEqual(field.text, "")
    }

    func testUnboundInserterReportsNotBound() {
        let inserter = TargetFieldInserter()
        XCTAssertEqual(inserter.update(snapshot("Hello")), .notBound)
        XCTAssertEqual(inserter.finalize(raw: "Hello", cleaned: "Hello."), .notWritten)
        XCTAssertEqual(inserter.deliveryMode, .none)
    }
}

final class LiveSnapshotTests: XCTestCase {
    func testJoinInsertsOneSpaceUnlessSeamHasWhitespace() {
        XCTAssertEqual(LiveTranscriptSnapshot.join("", "tail"), "tail")
        XCTAssertEqual(LiveTranscriptSnapshot.join("head", ""), "head")
        XCTAssertEqual(LiveTranscriptSnapshot.join("head", "tail"), "head tail")
        XCTAssertEqual(LiveTranscriptSnapshot.join("head ", "tail"), "head tail")
        XCTAssertEqual(LiveTranscriptSnapshot.join("head", " tail"), "head tail")
        XCTAssertEqual(LiveTranscriptSnapshot(stable: "a", revisable: "b").fullText, "a b")
    }

    func testStableAccumulatedWithJoinStaysPrefixOfFullText() {
        var stable = ""
        for final in ["Hello there.", "This is a test.", " And more"] {
            stable = LiveTranscriptSnapshot.join(stable, final)
            let snap = LiveTranscriptSnapshot(stable: stable, revisable: "tail")
            XCTAssertTrue(snap.fullText.hasPrefix(stable))
        }
        XCTAssertEqual(stable, "Hello there. This is a test. And more")
    }

    func testWhisperDigestIgnoresNonTextState() {
        let a = WhisperLiveDigest(confirmed: ["Hello"], unconfirmed: ["there"], current: "th")
        let b = WhisperLiveDigest(confirmed: ["Hello"], unconfirmed: ["there"], current: "th")
        let c = WhisperLiveDigest(confirmed: ["Hello"], unconfirmed: ["there"], current: "this")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
