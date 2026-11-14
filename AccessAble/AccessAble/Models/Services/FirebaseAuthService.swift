import FirebaseAuth
import Foundation

@MainActor
final class FirebaseAuthService: AuthService {
    private nonisolated let users = Broadcaster<AuthUser?>(replaysLatest: true)
    private var listener: AuthStateDidChangeListenerHandle?
    
    init() {
        users.send(Auth.auth().currentUser.map {AuthUser(id: $0.uid)})
        listener = Auth.auth().addStateDidChangeListener({ [users] _, user in users.send(user.map {AuthUser(id: $0.uid)})
        })
    }
    
    nonisolated func userChanges() -> AsyncStream<AuthUser?> {
        users.stream()
    }
    
    nonisolated func currentUser() async -> AuthUser? {
        Auth.auth().currentUser.map { AuthUser(id: $0.uid)}
    }
    
    nonisolated func signIn(email: String, password: String) async throws -> AuthUser {
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            return AuthUser(id: result.user.uid)
        } catch {
            throw AuthError(firebaseError: error)
        }
    }
    
    nonisolated func createAccount(email: String, password: String) async throws -> AuthUser {
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            return AuthUser(id: result.user.uid)
        } catch {
            throw AuthError(firebaseError: error)
        }
    }
    
    nonisolated func signOut() async throws {
        do {
            try Auth.auth().signOut()
        } catch {
            throw AuthError(firebaseError: error)
        }
    }
}

private extension AuthError {
    init(firebaseError error: Error) {
        switch AuthErrorCode(rawValue: (error as NSError).code) {
        case .invalidEmail: self = .invalidEmail
        case .invalidCredential, .wrongPassword, .userNotFound: self = .invalidCredentials
        case .emailAlreadyInUse: self = .emailAlreadyInUse
        case .weakPassword: self = .weakPassword
        case .tooManyRequests: self = .tooManyAttemps
        case .networkError: self = .network
        default: self = .unknown
        }
    }
}


