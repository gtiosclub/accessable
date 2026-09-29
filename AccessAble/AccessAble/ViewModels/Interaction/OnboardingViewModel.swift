import Foundation
import Observation

/// Owner: User Interaction (3.4). Onboarding survey → GuidanceProfile.
@MainActor
@Observable
final class OnboardingViewModel {
    var visionLevel: VisionLevel = .blind
    var hasAcknowledgedSafetyDisclosure = false

    static let safetyDisclosure =
        "AccessAble is a mobility aid. It does not replace a white cane, guide dog, or your own judgement, " +
        "and it never tells you when it is safe to cross a street."

    var canFinish: Bool { hasAcknowledgedSafetyDisclosure }

    var profile: GuidanceProfile { .preset(for: visionLevel) }
}
