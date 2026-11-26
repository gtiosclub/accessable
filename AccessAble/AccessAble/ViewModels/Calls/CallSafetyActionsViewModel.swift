import Foundation
import Observation

/// A confirmed save is required for success; a stalled network cannot trap navigation forever.
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
    @ObservationIgnored private let confirmationTimeout: Duration
    @ObservationIgnored private var pendingID: UUID?
    @ObservationIgnored private var waiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?

    private enum Action: Sendable {
        case report(CallReportReason, String)
        case block
        var isReport: Bool { if case .report = self { return true }; return false }
    }

    init(summary: CallSafetySummary, service: any CallSafetyService, confirmationTimeout: Duration = .seconds(20)) {
        self.summary = summary
        self.service = service
        self.confirmationTimeout = confirmationTimeout
    }

    func report() async {
        guard !isBusy, !reported else { return }
        guard CallSafetyReportLimit.length(of: details) <= CallSafetyReportLimit.maxLength else {
            message = CallSafetyError.invalidReport.errorDescription
            return
        }
        await perform(.report(reason, details.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func block() async {
        guard summary.canBlockVolunteer, !isBusy, !blocked else { return }
        await perform(.block)
    }

    private func perform(_ action: Action) async {
        let id = UUID()
        pendingID = id
        isBusy = true
        message = nil
        let service = service, summary = summary, timeout = confirmationTimeout
        // Firestore writes may not cooperate with Task cancellation while offline. An unstructured
        // operation plus a fenced continuation lets the UI recover without claiming cancellation
        // of a write that may still commit. Late results cannot alter a subsequent action.
        await withCheckedContinuation { continuation in
            waiter = continuation
            operation = Task { [weak self] in
                do {
                    switch action {
                    case .report(let reason, let details):
                        try await service.report(callID: summary.id, subjectID: summary.otherUserID, reason: reason, details: details)
                    case .block:
                        try await service.block(volunteerID: summary.otherUserID, callID: summary.id)
                    }
                    self?.finish(id, action: action, succeeded: true)
                } catch { self?.finish(id, action: action, succeeded: false) }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.finish(id, action: action, succeeded: false, timedOut: true)
            }
        }
    }

    private func finish(_ id: UUID, action: Action, succeeded: Bool, timedOut: Bool = false) {
        guard pendingID == id else { return }
        pendingID = nil
        deadline?.cancel(); deadline = nil
        if timedOut { operation?.cancel() }
        operation = nil
        isBusy = false
        if timedOut {
            message = "The server hasn't confirmed this save. It may still finish when connected. You can retry or leave this screen."
        } else if succeeded {
            if action.isReport { reported = true; message = "Report sent to the club moderators." }
            else { blocked = true; message = "Volunteer blocked. You won't be matched with them again." }
        } else {
            message = action.isReport ? "Couldn't send the report. Check your connection and retry."
                : "Couldn't save the block. Check your connection and try again."
        }
        let continuation = waiter
        waiter = nil
        continuation?.resume()
    }
}
