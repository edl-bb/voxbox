import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @ObservedObject private var permissions = PermissionService.shared

    private var needsPermissionAttention: Bool {
        PermissionService.shouldShowSidebarStatus(
            micGranted: permissions.isMicGranted,
            accessibilityGranted: permissions.isAccessibilityGranted
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Space for traffic lights
            Spacer()
                .frame(height: SidebarConstants.topInset)

            // Logo Header
            SidebarHeader()
                .padding(.horizontal, SidebarConstants.horizontalPadding)
                .padding(.bottom, SidebarConstants.headerBottomPadding)

            // Navigation Items
            VStack(spacing: SidebarConstants.itemSpacing) {
                ForEach(SidebarItem.allCases) { item in
                    SidebarButton(
                        item: item,
                        isSelected: selection == item,
                        action: { selection = item }
                    )
                }
            }
            .padding(.horizontal, SidebarConstants.itemHorizontalPadding)

            Spacer()

            if needsPermissionAttention {
                PermissionStatusBar()
                    .padding(.horizontal, SidebarConstants.itemHorizontalPadding)
                    .padding(.bottom, 12)
            }

            // In-flight model downloads — visible from anywhere in the app,
            // not just Settings → AI Models. Hidden when nothing is active.
            ActiveDownloadsView()
                .padding(.horizontal, SidebarConstants.itemHorizontalPadding)
                .padding(.bottom, 10)

            // Ed's branding link
            Button(action: {
                NSWorkspace.shared.open(URL(string: "https://edlittle.dev")!)
            }) {
                Text("Made by Ed")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Color.textMuted.opacity(0.25))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .padding(.bottom, 6)

            // Build version indicator — debug only, never shown in production
            #if DEBUG
                Text(buildVersionString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.textMuted.opacity(0.35))
                    .padding(.bottom, 14)
            #else
                Spacer().frame(height: 14)
            #endif
        }
        .frame(width: SidebarConstants.width)
        .onAppear { permissions.refresh() }
    }

    private var buildVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(version) (\(buildTimestamp))"
    }
}

// MARK: - Constants

private enum SidebarConstants {
    static let width: CGFloat = 260
    static let topInset: CGFloat = 52
    static let horizontalPadding: CGFloat = 20
    static let itemHorizontalPadding: CGFloat = 14
    static let headerBottomPadding: CGFloat = 28
    static let itemSpacing: CGFloat = 2
    static let bottomPadding: CGFloat = 20
    static let iconSize: CGFloat = 17
    static let itemVerticalPadding: CGFloat = 11
    static let itemCornerRadius: CGFloat = 8
}

// MARK: - Components

private struct SidebarHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)

            Text("VoxBox")
                .font(Typography.sidebarLogo)
                .foregroundStyle(Color.textPrimary)

            Spacer()
        }
    }
}

struct SidebarButton: View {
    let item: SidebarItem
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: SidebarConstants.iconSize))
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textMuted)
                    .frame(width: 20)

                Text(item.rawValue)
                    .font(isSelected ? Typography.sidebarItemActive : Typography.sidebarItem)
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, SidebarConstants.itemVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: SidebarConstants.itemCornerRadius)
                    .fill(isSelected ? Color.bgSelected : (isHovered ? Color.bgHover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Sidebar Items

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case transcribeAudio = "Transcribe Audio"
    case history = "History"
    case dictionary = "Dictionary"
    case statistics = "Statistics"
    case aiModels = "AI Models"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .transcribeAudio: return "waveform"
        case .history: return "doc.text"
        case .dictionary: return "character.book.closed"
        case .statistics: return "chart.bar"
        case .aiModels: return "cpu"
        case .settings: return "gearshape"
        }
    }
}
