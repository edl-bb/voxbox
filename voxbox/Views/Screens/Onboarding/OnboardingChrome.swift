import SwiftUI

/// Progress row shown on every step after Welcome.
struct OnboardingStepDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.dotSteps, id: \.rawValue) { step in
                Capsule()
                    .fill(step == current ? Color.textPrimary : Color.textSecondary.opacity(0.25))
                    .frame(width: step == current ? 22 : 8, height: 8)
                    .animation(.easeOut(duration: 0.25), value: current)
            }
        }
        .accessibilityLabel("Step \(current.rawValue) of \(OnboardingStep.allCases.count - 1)")
    }
}

/// Small uppercase label above a page title ("RECORDING").
struct OnboardingEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
            .textCase(.uppercase)
            .tracking(2)
    }
}

/// Quiet text button under the primary Continue.
struct OnboardingSkipButton: View {
    var title: String = "Skip for now"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.textSecondary)
        }
        .buttonStyle(.plain)
    }
}

/// A `FeatureCard` that can be chosen: 2pt border and a checkmark badge when
/// selected.
struct OnboardingSelectableCard: View {
    let icon: String
    let title: String
    let description: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(Color.textPrimary.opacity(isSelected ? 0.1 : 0.05))
                            .frame(width: 44, height: 44)
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.textPrimary)
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary.opacity(0.5))
                }
                Spacer().frame(height: 16)
                Text(title)
                    .font(.system(size: 16, weight: .medium, design: .serif))
                    .foregroundStyle(Color.textPrimary)
                Spacer().frame(height: 6)
                Text(description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(width: 220, height: 170, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.textPrimary : Color.textSecondary.opacity(isHovered ? 0.25 : 0.1),
                        lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: Color.black.opacity(isHovered || isSelected ? 0.1 : 0.05), radius: isHovered ? 16 : 10, x: 0, y: 6)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
