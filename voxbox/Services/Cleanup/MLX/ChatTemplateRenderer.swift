import Foundation

/// Hand-written chat templates for the two catalog families. swift-transformers
/// 0.1.8 (pinned by WhisperKit) has no Jinja engine, so the official templates
/// are reproduced here byte for byte. The beginning-of-sequence token is left
/// to the tokenizer so it is never doubled.
nonisolated struct ChatTemplateRenderer: Sendable {
    let family: LocalModelFamily
    /// Llama 3 prints today's date in the system header. Injected for tests.
    var today: Date = Date()

    struct Turn: Equatable {
        var role: String
        var content: String
    }

    static func turns(from messages: [[String: any Sendable]]) -> [Turn] {
        messages.compactMap { message in
            guard let role = message["role"] as? String, let content = message["content"] as? String else {
                return nil
            }
            return Turn(role: role, content: content)
        }
    }

    func render(
        messages: [[String: any Sendable]],
        additionalContext: [String: any Sendable]?,
        defaultEnableThinking: Bool = true
    ) -> String {
        render(
            turns: Self.turns(from: messages),
            enableThinking: (additionalContext?["enable_thinking"] as? Bool) ?? defaultEnableThinking)
    }

    func render(turns: [Turn], enableThinking: Bool = true) -> String {
        switch family {
        case .llama3: return renderLlama3(turns)
        case .qwen3: return renderQwen3(turns, enableThinking: enableThinking)
        }
    }

    // MARK: - Llama 3.x Instruct

    private static let llamaDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM yyyy"
        return formatter
    }()

    private func renderLlama3(_ turns: [Turn]) -> String {
        var output = ""
        var remaining = turns
        let systemBody = remaining.first?.role == "system" ? remaining.removeFirst().content : ""
        output += "<|start_header_id|>system<|end_header_id|>\n\n"
        output += "Cutting Knowledge Date: December 2023\n"
        output += "Today Date: \(Self.llamaDate.string(from: today))\n\n"
        output += systemBody.trimmingCharacters(in: .whitespacesAndNewlines)
        output += "<|eot_id|>"
        for turn in remaining {
            output += "<|start_header_id|>\(turn.role)<|end_header_id|>\n\n"
            output += turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            output += "<|eot_id|>"
        }
        output += "<|start_header_id|>assistant<|end_header_id|>\n\n"
        return output
    }

    // MARK: - Qwen 3 (ChatML)

    private func renderQwen3(_ turns: [Turn], enableThinking: Bool) -> String {
        var output = ""
        for turn in turns {
            output += "<|im_start|>\(turn.role)\n\(turn.content)<|im_end|>\n"
        }
        output += "<|im_start|>assistant\n"
        if !enableThinking {
            output += "<think>\n\n</think>\n\n"
        }
        return output
    }
}
