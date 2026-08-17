import AppKit
import SwiftUI

enum ReleaseNotesRoute {
    static func present() {
        DashboardRoute.openWindow?("release-notes")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ReleaseNotesView: View {
    private let entries: [ChangelogEntry]
    private let currentVersion: String

    init(
        entries: [ChangelogEntry] = ChangelogDocument.bundled(),
        currentVersion: String = AppVersion.currentVersion
    ) {
        self.entries = entries
        self.currentVersion = currentVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(entries) { entry in
                            versionSection(entry)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .background(Color.bgApp)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Release Notes")
                .font(Typography.displaySmall)
                .foregroundStyle(Color.textPrimary)
            Text("What’s new in VoxBox \(currentVersion)")
                .font(Typography.bodySmall)
                .foregroundStyle(Color.textMuted)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Release notes aren’t in this build.")
                .font(Typography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
            Text("They ship with each release from CHANGELOG.md.")
                .font(Typography.caption)
                .foregroundStyle(Color.textMuted)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func versionSection(_ entry: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.version)
                    .font(Typography.headlineMedium)
                    .foregroundStyle(Color.textPrimary)

                if let date = entry.date, !date.isEmpty {
                    Text(date)
                        .font(Typography.caption)
                        .foregroundStyle(Color.textMuted)
                }

                if entry.version == currentVersion {
                    Text("This version")
                        .font(Typography.captionBold)
                        .foregroundStyle(Color.accentPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentPrimary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            ChangelogMarkdownView(markdown: entry.markdown)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    // Same path as Help → Release Notes / Settings → Updates: the bundled CHANGELOG.md.
    ReleaseNotesView()
        .frame(width: 520, height: 560)
}
