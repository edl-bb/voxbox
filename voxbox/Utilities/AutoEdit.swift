import Foundation

/// Deterministic filler-word strip and space tidy. Instant, offline, no model.
/// Distinct from on-device AI cleanup, which can also drop fillers but only
/// on longer dictations and only when Apple Intelligence is available.
enum AutoEdit {
    static let defaultsKey = "enableAutoEdit"

    private static let fillerWordPattern =
        #"(?i)(^|[\s,.;:!?])(?:uh+|um+|umm+|uhm+|erm+|hmm+)(?=$|[\s,.;:!?])[,.;:!?]?"#

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func apply(to text: String) -> String {
        guard isEnabled else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var edited = text.replacingOccurrences(
            of: fillerWordPattern,
            with: "$1",
            options: .regularExpression
        )
        edited = edited.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        edited = edited.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return edited.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
