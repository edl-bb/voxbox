import Foundation

/// The first-run pages in order. Returning users who only lost a TCC grant
/// start at permissions and finish there.
nonisolated enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case globeKey
    case permissions
    case recordingMode
    case cleanup
    case model

    static func first(startAtPermissions: Bool) -> OnboardingStep {
        startAtPermissions ? .permissions : .welcome
    }

    /// The page after this one; nil finishes onboarding.
    func next(startAtPermissions: Bool) -> OnboardingStep? {
        if startAtPermissions, self == .permissions { return nil }
        switch self {
        case .welcome: return .globeKey
        case .globeKey: return .permissions
        case .permissions: return .recordingMode
        case .recordingMode: return .cleanup
        case .cleanup: return .model
        case .model: return nil
        }
    }

    /// The model page hosts a full catalog list and uses tighter outer padding.
    var contentPadding: CGFloat {
        self == .model ? 16 : 40
    }
}
