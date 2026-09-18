import XCTest
import MLXLMCommon

@testable import voxbox

final class ChatTemplateRendererTests: XCTestCase {
    private let turns = [
        ChatTemplateRenderer.Turn(role: "system", content: "You tidy dictation."),
        ChatTemplateRenderer.Turn(role: "user", content: "Clean this: um hello"),
    ]

    func testLlama3TemplateIsByteExactWithoutBOS() {
        var renderer = ChatTemplateRenderer(family: .llama3)
        renderer.today = Date(timeIntervalSince1970: 1_724_000_000)  // 18 Aug 2024 UTC
        let expected =
            "<|start_header_id|>system<|end_header_id|>\n\n"
            + "Cutting Knowledge Date: December 2023\nToday Date: \(Self.llamaDate(renderer.today))\n\n"
            + "You tidy dictation.<|eot_id|>"
            + "<|start_header_id|>user<|end_header_id|>\n\nClean this: um hello<|eot_id|>"
            + "<|start_header_id|>assistant<|end_header_id|>\n\n"
        XCTAssertEqual(renderer.render(turns: turns), expected)
        XCTAssertFalse(renderer.render(turns: turns).contains("<|begin_of_text|>"), "BOS comes from the tokenizer")
    }

    func testLlama3AlwaysEmitsASystemHeader() {
        let renderer = ChatTemplateRenderer(family: .llama3)
        let rendered = renderer.render(turns: [ChatTemplateRenderer.Turn(role: "user", content: "hi")])
        XCTAssertTrue(rendered.hasPrefix("<|start_header_id|>system<|end_header_id|>\n\nCutting Knowledge Date"))
        XCTAssertTrue(rendered.contains("<|start_header_id|>user<|end_header_id|>\n\nhi<|eot_id|>"))
    }

    func testQwen3TemplateWithThinkingDisabled() {
        let renderer = ChatTemplateRenderer(family: .qwen3)
        XCTAssertEqual(
            renderer.render(turns: turns, enableThinking: false),
            "<|im_start|>system\nYou tidy dictation.<|im_end|>\n"
                + "<|im_start|>user\nClean this: um hello<|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n")
        XCTAssertEqual(
            renderer.render(turns: turns, enableThinking: true),
            "<|im_start|>system\nYou tidy dictation.<|im_end|>\n"
                + "<|im_start|>user\nClean this: um hello<|im_end|>\n"
                + "<|im_start|>assistant\n")
    }

    func testAdditionalContextControlsThinking() {
        let renderer = ChatTemplateRenderer(family: .qwen3)
        let messages: [[String: any Sendable]] = [["role": "user", "content": "hi"]]
        XCTAssertTrue(renderer.render(messages: messages, additionalContext: ["enable_thinking": false]).hasSuffix("<think>\n\n</think>\n\n"))
        XCTAssertTrue(renderer.render(messages: messages, additionalContext: nil).hasSuffix("<|im_start|>assistant\n"))
        XCTAssertEqual(ChatTemplateRenderer.turns(from: [["role": "user"], ["role": "user", "content": "x"]]).count, 1)
    }

    func testQwenCleanupDefaultsThinkingOffWhenContextIsNil() {
        let renderer = ChatTemplateRenderer(family: .qwen3)
        let messages: [[String: any Sendable]] = [["role": "user", "content": "hi"]]
        XCTAssertTrue(
            renderer.render(
                messages: messages, additionalContext: nil, defaultEnableThinking: false
            ).hasSuffix("<think>\n\n</think>\n\n"),
            "catalog cleanup must emit empty think tags even if additionalContext is nil")
    }

    func testCatalogTokenizerLoaderDefaultsQwenThinkingOff() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxbox-catalog-tok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{\"model_type\":\"qwen3\"}".utf8).write(
            to: directory.appendingPathComponent("config.json"))
        try Data(Self.qwenToyTokenizerJSON.utf8).write(
            to: directory.appendingPathComponent("tokenizer.json"))

        let tokenizer = try await CatalogTokenizerLoader(familyHint: .qwen3).load(from: directory)
        let ids = try tokenizer.applyChatTemplate(
            messages: [["role": "user", "content": "hi"]],
            tools: nil,
            additionalContext: nil)
        let decoded = tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
        // Toy vocab has no newline tokens, so the empty think block may
        // decode without the `\n\n`; the tags themselves are the signal
        // that thinking was forced off (thinking-on omits them entirely).
        XCTAssertTrue(
            decoded.contains("<think>") && decoded.contains("</think>"),
            "Qwen catalog tokenizer must default enableThinking off: \(decoded)")
    }

    private static func llamaDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM yyyy"
        return formatter.string(from: date)
    }

    /// Enough specials for the Qwen chat template to round-trip through decode.
    private static let qwenToyTokenizerJSON = """
        {
          "added_tokens": [
            {"id": 20, "content": "<|im_start|>", "special": true},
            {"id": 21, "content": "<|im_end|>", "special": true},
            {"id": 22, "content": "<think>", "special": true},
            {"id": 23, "content": "</think>", "special": true}
          ],
          "pre_tokenizer": {
            "type": "Split",
            "pattern": {"Regex": "'s|'t|'re|'ve|'m|'ll|'d| ?\\\\p{L}+| ?\\\\p{N}+| ?[^\\\\s\\\\p{L}\\\\p{N}]+|\\\\s+(?!\\\\S)|\\\\s+"},
            "behavior": "Isolated",
            "invert": false
          },
          "model": {
            "type": "BPE",
            "ignore_merges": false,
            "vocab": {"h": 0, "i": 1, "hi": 2, "Ġ": 3},
            "merges": ["h i"]
          }
        }
        """
}
