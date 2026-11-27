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
    /// Shown and edited on the Profile tab (PROFILE-1).
    var details = ProfileDetails()
}

/// Optional profile details. Limits must match firestore.rules.
struct ProfileDetails: Equatable, Sendable {
    static let maxLocationLength = 80
    static let maxConditionLength = 200

    var location = ""
    /// A caller's vision, for example "Partially sighted, right eye".
    var condition = ""
    /// A volunteer's schedule; nil until they pick one.
    var availability: VolunteerAvailability?

    var isValid: Bool {
        location.count <= Self.maxLocationLength && condition.count <= Self.maxConditionLength
    }
}

/// When a volunteer is Online.
enum VolunteerAvailability: String, CaseIterable, Sendable {
    case always
    /// Monday to Friday, 9 AM to 5 PM, while the app is open.
    case weekdays
    /// Only when they turn Online on.
    case manual

    var title: String {
        switch self {
        case .always: "Always available"
        case .weekdays: "Available Mon–Fri 9am–5pm"
        case .manual: "Only when I turn on available"
        }
    }

    /// Whether the schedule has this volunteer Online at `date`; nil leaves it to the Online toggle.
    func isScheduledOnline(at date: Date, calendar: Calendar = .current) -> Bool? {
        switch self {
        case .always: return true
        case .manual: return nil
        case .weekdays:
            let parts = calendar.dateComponents([.weekday, .hour], from: date)
            guard let weekday = parts.weekday, let hour = parts.hour else { return false }
            // weekday: 1 is Sunday, 7 is Saturday.
            return (2...6).contains(weekday) && (9..<17).contains(hour)
        }
    }
}

enum UserProfileError: Error, LocalizedError, Sendable {
    case invalidProfile
    case notConfigured
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .invalidProfile: "Enter a name (up to 80 characters) and 1–10 languages (up to 40 characters each)."
        case .notConfigured: "Firebase is not configured. Add REPORT-1's local Firebase configuration."
        case .permissionDenied: "Your account couldn't be accessed. Please try again later."
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
