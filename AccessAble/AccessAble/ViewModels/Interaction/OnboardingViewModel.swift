import Foundation
import Observation

// MARK: - Account config and backend seam

enum AccountRules {
    static let minPasswordLength = 6

    /// Returns an error message, or nil if the input is fine.
    static func validate(username: String, password: String) -> String? {
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter a username."
        }
        if password.count < minPasswordLength {
            return "Password must be at least \(minPasswordLength) characters."
        }
        return nil
    }
}

/// The one place the real backend plugs in. Throw an error to show its message on screen.
protocol AccountCreating {
    func createAccount(username: String, password: String) async throws
}

/// Placeholder until the backend is chosen. It saves nothing and always succeeds.
struct LocalAccountService: AccountCreating {
    func createAccount(username: String, password: String) async throws {
        // TODO: replace with the real account service.
    }
}

/// Owner: User Interaction (3.4). Onboarding: who's using the app → VoiceOver → account → settings → tutorial → done.
@MainActor
@Observable
final class OnboardingViewModel {
    enum Step: Hashable {
        case role
        case voiceOver
        case account
        case settings
        case tutorial
        case complete
    }

    private(set) var step: Step = .role
    private(set) var visionLevel: VisionLevel = .blind
    private(set) var usesVoiceOver = true
    private(set) var isCreatingAccount = false
    private(set) var accountError: String?

    @ObservationIgnored var accountService: AccountCreating = LocalAccountService()

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
        step = .account
    }

    func createAccount(username: String, password: String) async {
        if let message = AccountRules.validate(username: username, password: password) {
            accountError = message
            return
        }
        accountError = nil
        isCreatingAccount = true
        defer { isCreatingAccount = false }
        do {
            try await accountService.createAccount(username: username, password: password)
            step = .settings
        } catch {
            accountError = error.localizedDescription
        }
    }

    func finishSettings() {
        step = .tutorial
    }

    func finishTutorial() {
        step = .complete
    }

    func repeatTutorial() {
        step = .tutorial
    }
}
