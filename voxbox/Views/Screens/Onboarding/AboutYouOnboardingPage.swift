import SwiftUI

/// Settings › About you, asked once right after the cleanup level. Only
/// shown for Light and Polish (`OnboardingStep.next(cleanup:)`). The fields
/// save as you type, so Continue and Skip both just move on.
struct AboutYouOnboardingPage: View {
    let continueAction: () -> Void
    let skipAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                OnboardingEyebrow(text: "About you")

                Text("Who's dictating?")
                    .font(Typography.onboardingTitle)
                    .foregroundStyle(Color.textPrimary)

                Text("A line about your work and the names you use help cleanup spell what the speech engine mishears: Xero, not \"zero\". It stays on this Mac and never adds words you didn't say.")
                    .font(Typography.bodyLarge)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .lineSpacing(3)
            }

            AboutYouFields(font: Typography.bodyMedium)
                .frame(maxWidth: 480)
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.bgCard))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.textSecondary.opacity(0.1), lineWidth: 1))
                .padding(.top, 32)

            Text("You can change this any time in Cleanup.")
                .font(Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .padding(.top, 16)

            Spacer()

            VStack(spacing: 14) {
                ContinueButton(isEnabled: true, action: continueAction)
                OnboardingSkipButton(action: skipAction)
            }
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 40)
    }
}
