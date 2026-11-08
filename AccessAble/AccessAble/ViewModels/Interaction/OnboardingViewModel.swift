import Foundation
import Observation

/// Owner: User Interaction (3.4). Onboarding: who's using the app → VoiceOver → tutorial → done.
@MainActor
@Observable
final class OnboardingViewModel {
    enum Step: Hashable {
        case role
        case voiceOver
        case tutorial
        case complete
    }

    private(set) var step: Step = .role
    private(set) var visionLevel: VisionLevel = .blind
    private(set) var usesVoiceOver = true

    static let safetyDisclosure =
        "AccessAble is a mobility aid. It does not replace a white cane, guide dog, or your own judgement, " +
        "and it never tells you when it is safe to cross a street."

    var profile: GuidanceProfile { .preset(for: visionLevel) }

    func chooseRole(_ level: VisionLevel) {
        visionLevel = level
        step = .voiceOver
    }

    func answerVoiceOver(_ usesVoiceOver: Bool) {
        self.usesVoiceOver = usesVoiceOver
        step = .tutorial
    }

    func finishTutorial() {
        step = .complete
    }

    func repeatTutorial() {
        step = .tutorial
    }
}
