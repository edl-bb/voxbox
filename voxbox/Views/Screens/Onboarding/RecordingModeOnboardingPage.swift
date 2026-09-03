import SwiftUI

/// First-run choice between hold-to-record and toggle. The same setting
/// lives in Settings → Recording Mode and in the recorder pill's menu.
struct RecordingModeOnboardingPage: View {
    let action: () -> Void

    @AppStorage(RecordingMode.defaultsKey) private var recordingModeRaw: Int = RecordingMode.default.rawValue

    private var hotkeyLabel: String {
        let raw = UserDefaults.standard.string(forKey: HotkeyOption.defaultsKey) ?? ""
        let hotkey = HotkeyOption(rawValue: raw) ?? .default
        return RecordingHotkeyCopy.invocationLabel(for: hotkey)
    }

    private var selection: RecordingMode {
        RecordingMode(rawValue: recordingModeRaw) ?? .default
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Text("RECORDING")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .textCase(.uppercase)
                    .tracking(2)

                Text("How do you want to record?")
                    .font(.system(size: 40, weight: .regular, design: .serif))
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)

                Text(
                    "VoxBox records while you use the \(hotkeyLabel) key. Pick what a press does; you can change this any time in Settings or from the recorder pill."
                )
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .lineSpacing(3)
            }

            HStack(spacing: 16) {
                ForEach(RecordingMode.allCases) { mode in
                    OnboardingChoiceCard(
                        icon: mode.icon,
                        title: mode.displayName,
                        description: mode.detail,
                        isSelected: selection == mode
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) { recordingModeRaw = mode.rawValue }
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(.top, 44)

            Spacer()

            ContinueButton(isEnabled: true, action: action)
                .padding(.bottom, 48)
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 40)
    }
}

/// A selectable card with a radio indicator, used for onboarding choices.
struct OnboardingChoiceCard: View {
    let icon: String
    let title: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.brandAccentSoft : Color.textPrimary.opacity(0.05))
                            .frame(width: 44, height: 44)
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(isSelected ? Color.brandAccent : Color.textPrimary)
                    }
                    Spacer()
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Color.brandAccent : Color.textMuted)
                }

                Text(title)
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundStyle(Color.textPrimary)

                Text(description)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        isSelected ? Color.brandAccent.opacity(0.6) : Color.border.opacity(0.5),
                        lineWidth: isSelected ? 1.5 : 1)
            )
            .shadow(
                color: Color.black.opacity(isHovered || isSelected ? 0.10 : 0.04),
                radius: isHovered ? 14 : 8, x: 0, y: isHovered ? 8 : 4)
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

#Preview {
    RecordingModeOnboardingPage(action: {})
        .frame(width: 720, height: 560)
        .background(Color.bgApp)
}
