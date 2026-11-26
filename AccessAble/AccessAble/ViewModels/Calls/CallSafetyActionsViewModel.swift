import Foundation
import Observation

/// Keeps a failed action retryable and never acknowledges an unconfirmed server write.
@MainActor
@Observable
final class CallSafetyActionsViewModel {
    let summary: CallSafetySummary
    var reason: CallReportReason = .other
    var details = ""
    private(set) var isBusy = false
    private(set) var reported = false
    private(set) var blocked = false
    private(set) var message: String?
    @ObservationIgnored private let service: any CallSafetyService

    init(summary: CallSafetySummary, service: any CallSafetyService) {
        self.summary = summary
        self.service = service
    }

    func report() async {
        guard !isBusy, !reported else { return }
        guard CallSafetyReportLimit.length(of: details) <= CallSafetyReportLimit.maxLength else {
            message = CallSafetyError.invalidReport.errorDescription
            return
        }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            try await service.report(callID: summary.id, subjectID: summary.otherUserID,
                                     reason: reason, details: details.trimmingCharacters(in: .whitespacesAndNewlines))
            reported = true
            message = "Report sent to the club moderators."
        } catch {
            message = "Couldn't send the report. Check your connection and retry."
        }
    }

    func block() async {
        guard summary.canBlockVolunteer, !isBusy, !blocked else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            try await service.block(volunteerID: summary.otherUserID, callID: summary.id)
            blocked = true
            message = "Volunteer blocked. You won't be matched with them again."
        } catch {
            message = "Couldn't save the block. Check your connection and try again."
        }
    }
}
