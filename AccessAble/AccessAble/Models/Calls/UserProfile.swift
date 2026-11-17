import Foundation

/// Account role is independent of the user's vision/accessibility preferences.
enum UserRole: String, Codable, CaseIterable, Sendable {
    case caller
    case volunteer

    var title: String { self == .caller ? "Caller" : "Volunteer" }
}

struct UserProfile: Equatable, Sendable {
    let userID: String
    var role: UserRole
    var displayName: String
    var languages: [String]
    let createdAt: Date
}

enum UserProfileError: Error, LocalizedError, Sendable {
    case invalidProfile
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .invalidProfile: "Enter a name (up to 80 characters) and 1–10 languages (up to 40 characters each)."
        case .notConfigured: "Firebase is not configured. Add REPORT-1's local Firebase configuration."
        }
    }
}

enum UserProfileValidation {
    static func isValid(displayName: String, languages: [String]) -> Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName.count <= 80 && (1...10).contains(languages.count)
            && languages.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 40
            }
    }
}
