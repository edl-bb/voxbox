import SwiftUI

/// Renders changelog markdown with visible headings and nested list indents.
struct ChangelogMarkdownView: View {
    let markdown: String

    var body: some View {
        let blocks = ChangelogMarkdown.blocks(in: markdown)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: ChangelogMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(ChangelogMarkdown.inline(text))
                .font(headingFont(level))
                .foregroundStyle(Color.textPrimary)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)

        case .listItem(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(depth == 0 ? "•" : "–")
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 12, alignment: .center)
                Text(ChangelogMarkdown.inline(text))
                    .font(Typography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph(let text):
            Text(ChangelogMarkdown.inline(text))
                .font(Typography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1, 2: return Typography.headlineLarge
        case 3: return Typography.headlineMedium
        default: return Typography.headlineSmall
        }
    }
}
