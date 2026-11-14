import Foundation

struct AuthUser: Equatable, Sendable {
    let id: String
}

enum AuthError: Error, Equatable, Sendable {
    case invalidEmail
    case invalidCredentials
    case emailAlreadyInUse
    case weakPassword
    case tooManyAttemps
    case network
    case unknown
}

