import Foundation
import Observation

@MainActor
@Observable
final class SignInViewModel {
    var email = ""
    var password = ""
    var confirmation = ""
    var isCreatingAccount = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private let auth: any AuthService

    init(auth: any AuthService) { self.auth = auth }

    func submit() async {
        guard !isBusy else { return }
        errorMessage = nil
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Enter your email and password."; return
        }
        guard !isCreatingAccount || (password == confirmation && password.count >= 6) else {
            errorMessage = "Use at least six password characters and matching passwords."; return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            if isCreatingAccount {
                _ = try await auth.createAccount(email: email, password: password)
            } else {
                _ = try await auth.signIn(email: email, password: password)
            }
            password = ""
            confirmation = ""
        } catch {
            switch error as? AuthError {
            case .invalidEmail: errorMessage = "Enter a valid email address."
            case .invalidCredentials: errorMessage = "The email or password is incorrect."
            case .emailAlreadyInUse: errorMessage = "This email already has an account. Try signing in."
            case .weakPassword: errorMessage = "Choose a stronger password with at least six characters."
            case .tooManyAttempts: errorMessage = "Too many attempts. Please try again later."
            case .network: errorMessage = "Check your connection and try again."
            default: errorMessage = "We couldn't sign you in. Please try again."
            }
        }
    }
}
