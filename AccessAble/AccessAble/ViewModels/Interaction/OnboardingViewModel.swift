import Foundation
import Observation

/// Account role and profile details precede the existing accessibility tutorial.
@MainActor
@Observable
final class OnboardingViewModel {
    enum Step: Hashable {
        case accountRole
        case accountDetails
        case role
        case voiceOver
        case tutorial
        case complete
    }

    private(set) var step: Step
    private(set) var visionLevel: VisionLevel = .blind
    private(set) var usesVoiceOver = true

    private(set) var accountRole: UserRole = .caller
    var displayName = ""
    var languageText = "English"
    var languages: [String] {
        languageText.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }
    var canContinueDetails: Bool {
        UserProfileValidation.isValid(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines), languages: languages)
    }

    init(includesAccount: Bool = true) { step = includesAccount ? .accountRole : .role }

    func chooseAccountRole(_ role: UserRole) {
        accountRole = role
        step = .accountDetails
    }

    func returnToAccountRole() { step = .accountRole }

    func finishAccountDetails() {
        guard canContinueDetails else { return }
        step = .role
    }

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
