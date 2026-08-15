import SwiftUI

/// Compact mic + Accessibility indicators. Green when granted; tap to enable
/// or open System Settings to manage the grant.
struct PermissionStatusBar: View {
    @ObservedObject private var permissions = PermissionService.shared
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            PermissionStatusChip(
                icon: "mic.fill",
                label: compact ? nil : "Mic",
                isGranted: permissions.isMicGranted,
                helpText: permissions.isMicGranted
                    ? "Microphone is on. Click to manage in System Settings."
                    : "Microphone is off. Click to enable.",
                action: {
                    if permissions.isMicGranted {
                        permissions.manageMicrophone()
                    } else {
                        permissions.requestMicrophone()
                    }
                }
            )
            PermissionStatusChip(
                icon: "hand.raised.fill",
                label: compact ? nil : "Access",
                isGranted: permissions.isAccessibilityGranted,
                helpText: permissions.isAccessibilityGranted
                    ? "Accessibility is on. Click to manage in System Settings."
                    : "Accessibility is off. Auto-paste is unavailable. Click to enable.",
                action: {
                    if permissions.isAccessibilityGranted {
                        permissions.manageAccessibility()
                    } else {
                        permissions.requestAccessibility()
                    }
                }
            )
        }
        .onAppear { permissions.refresh() }
    }
}

private struct PermissionStatusChip: View {
    let icon: String
    let label: String?
    let isGranted: Bool
    let helpText: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(isGranted ? Color.green : Color.orange)
            .padding(.horizontal, label == nil ? 7 : 8)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(
                        (isGranted ? Color.green : Color.orange)
                            .opacity(isHovered ? 0.16 : 0.10)
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        (isGranted ? Color.green : Color.orange).opacity(0.35),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { isHovered = $0 }
    }
}
