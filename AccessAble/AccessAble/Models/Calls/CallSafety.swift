import Foundation

enum CallReportReason: String, CaseIterable, Identifiable, Sendable {
    case harassment, inappropriateBehavior, unsafeAdvice, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .harassment: "Harassment"
        case .inappropriateBehavior: "Inappropriate behavior"
        case .unsafeAdvice: "Unsafe advice"
        case .other: "Other"
        }
    }
}

struct CallSafetySummary: Identifiable, Equatable, Sendable {
    let id: String
    let otherUserID: String
    let canBlockVolunteer: Bool
}

struct VolunteerPreferences: Equatable, Sendable {
    var onlineByDefault = true
    var keepScreenAwake = true
}

enum CallSafetyError: LocalizedError, Equatable, Sendable {
    case unavailable, signedOut, invalidReport, invitationRequired, consentRequired, blocked
    var errorDescription: String? {
        switch self {
        case .unavailable: "Account and call settings aren't available on this phone."
        case .signedOut: "Sign in to continue."
        case .invalidReport: "Choose a reason and keep the report under 2,000 characters."
        case .invitationRequired: "Only volunteer accounts can go online. Sign up as a volunteer to take calls."
        case .consentRequired: "Read and accept the call consent screen before calling."
        case .blocked: "This volunteer is blocked for this caller."
        }
    }
}

/// How long report details may be. Counted the way the Firestore rules' `size()` counts, in UTF-16
/// code units (an emoji can be 2 or more), so a report the screen allows is never refused.
enum CallSafetyReportLimit {
    static let maxLength = 2000
    static func length(of details: String) -> Int { details.utf16.count }
}
