import KeyboardShortcuts
import SwiftUI

/// Hold-to-talk versus toggle, chosen before the first take. Continue writes
/// the choice; Skip leaves the stored preference alone.
struct RecordingModeOnboardingPage: View {
    let continueAction: () -> Void
    let skipAction: () -> Void

    @AppStorage(HotkeyOption.defaultsKey) private var selectedHotkey: HotkeyOption = .fn
    @State private var selection: RecordingMode = RecordingMode.current()

    private var hotkeyLabel: String {
        RecordingHotkeyCopy.invocationLabel(
            for: selectedHotkey,
            customShortcutDescription: KeyboardShortcuts.getShortcut(for: .toggleRecord)?.description)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                OnboardingEyebrow(text: "Recording")

                Text("How do you want to talk?")
                    .font(Typography.onboardingTitle)
                    .foregroundStyle(Color.textPrimary)

                Text(RecordingMode.onboardingSubtitle(hotkey: hotkeyLabel))
                    .font(Typography.bodyLarge)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .lineSpacing(3)
            }

            HStack(spacing: 20) {
                ForEach(RecordingMode.allCases) { mode in
                    OnboardingSelectableCard(
                        icon: mode.icon,
                        title: mode.onboardingTitle,
                        description: mode.onboardingDescription(hotkey: hotkeyLabel),
                        isSelected: selection == mode,
                        action: { selection = mode })
                }
            }
            .padding(.top, 36)

            Text(RecordingMode.onboardingTip)
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.top, 20)

            Spacer()

            VStack(spacing: 14) {
                ContinueButton(isEnabled: true) {
                    selection.save()
                    continueAction()
                }
                OnboardingSkipButton(action: skipAction)
                    .help("Hold to talk stays the default. Change it later from the recorder pill or Settings.")
            }
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 40)
    }
}
