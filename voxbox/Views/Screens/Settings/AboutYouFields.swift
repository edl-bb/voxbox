import SwiftUI

/// The two About you fields, shared by Settings and the onboarding
/// step. Both write straight to the settings Light and Polish read
/// (`TranscriptFormatterService.speakerContext`).
struct AboutYouFields: View {
    @AppStorage(TranscriptFormatterService.speakerAboutKey) private var speakerAbout: String = ""
    @AppStorage(TranscriptFormatterService.speakerVocabularyKey) private var speakerVocabulary: String = ""

    var font: Font = Typography.bodySmall

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(
                label: "What you do",
                text: $speakerAbout,
                prompt: "e.g. Ops lead at a design studio. I dictate Slack messages, emails and notes for AI agents.",
                lines: 2...4)
            field(
                label: "Names and terms you use",
                text: $speakerVocabulary,
                prompt: "Separated by commas: Jules, Xero, Okta, BigQuery",
                lines: 1...3)
        }
    }

    private func field(label: String, text: Binding<String>, prompt: String, lines: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Typography.captionBold)
                .foregroundStyle(Color.textSecondary)
            TextField(label, text: text, prompt: Text(prompt), axis: .vertical)
                .lineLimit(lines)
                .textFieldStyle(.roundedBorder)
                .font(font)
        }
    }
}
