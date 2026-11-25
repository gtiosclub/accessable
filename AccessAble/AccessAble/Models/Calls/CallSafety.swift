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
        case .invitationRequired: "A club invitation is required to volunteer. Contact the club for approval."
        case .consentRequired: "Read and accept the call consent screen before calling."
        case .blocked: "This volunteer is blocked for this caller."
        }
    }
}
