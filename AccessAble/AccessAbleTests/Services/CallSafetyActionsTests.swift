import Foundation
import Testing
@testable import AccessAble

@MainActor
struct CallSafetyActionsTests {
    private let callerSummary = CallSafetySummary(id: "finished-call", otherUserID: "helper", canBlockVolunteer: true)

    @Test func successfulReportUsesTheCallParticipantsAndCannotDoubleSubmit() async {
        let service = SafetyRecorder()
        let model = CallSafetyActionsViewModel(summary: callerSummary, service: service)
        model.reason = .unsafeAdvice
        model.details = "  Please review this call.  "
        await model.report()
        await model.report()
        let reports = await service.reports
        #expect(model.reported && !model.isBusy)
        #expect(reports.count == 1)
        #expect(reports.first?.callID == "finished-call")
        #expect(reports.first?.subjectID == "helper")
        #expect(reports.first?.reason == .unsafeAdvice)
        #expect(reports.first?.details == "Please review this call.")
    }

    @Test func failedReportRemainsRetryableWithoutShowingSuccess() async {
        let service = SafetyRecorder()
        let model = CallSafetyActionsViewModel(summary: callerSummary, service: service)
        await service.setFailing(true)
        await model.report()
        #expect(!model.reported && !model.isBusy)
        #expect(model.message?.contains("Couldn't send") == true)
        await service.setFailing(false)
        await model.report()
        #expect(model.reported)
        #expect(await service.reports.count == 1)
    }

    @Test func overlongDetailsAreRejectedBeforeSending() async {
        let service = SafetyRecorder()
        let model = CallSafetyActionsViewModel(summary: callerSummary, service: service)
        model.details = String(repeating: "x", count: 2001)
        await model.report()
        #expect(!model.reported)
        #expect(await service.reports.isEmpty)
        #expect(model.message == CallSafetyError.invalidReport.errorDescription)
    }

    /// Counted like the rules count (UTF-16), so 1001 emoji are over the limit though they look like 1001 letters.
    @Test func detailsAreCountedTheWayTheRulesCount() async {
        #expect(CallSafetyReportLimit.length(of: String(repeating: "\u{1F600}", count: 1000)) == 2000)
        #expect(CallSafetyReportLimit.length(of: String(repeating: "\u{D55C}", count: 2000)) == 2000)
        let service = SafetyRecorder()
        let model = CallSafetyActionsViewModel(summary: callerSummary, service: service)
        model.details = String(repeating: "\u{1F600}", count: 1001)
        await model.report()
        #expect(!model.reported)
        #expect(await service.reports.isEmpty)
    }

    @Test func blockIsAcknowledgedOnlyAfterSuccessAndCanRetry() async {
        let service = SafetyRecorder()
        let model = CallSafetyActionsViewModel(summary: callerSummary, service: service)
        await service.setFailing(true)
        await model.block()
        #expect(!model.blocked && !model.isBusy)
        await service.setFailing(false)
        await model.block()
        await model.block()
        #expect(model.blocked)
        let blocks = await service.blocks
        #expect(blocks.count == 1)
        #expect(blocks.first?.callID == "finished-call")
        #expect(blocks.first?.volunteerID == "helper")
    }

    @Test func volunteerCanReportCallerButCannotUseTheCallerOnlyBlockAction() async {
        let service = SafetyRecorder()
        let summary = CallSafetySummary(id: "call", otherUserID: "caller", canBlockVolunteer: false)
        let model = CallSafetyActionsViewModel(summary: summary, service: service)
        await model.block()
        #expect(await service.blocks.isEmpty)
        await model.report()
        #expect(model.reported)
        #expect(await service.reports.first?.subjectID == "caller")
    }

    @Test func submittingTwiceWhileTheServerIsPendingMakesOneRequest() async {
        let service = SafetyRecorder()
        await service.pauseReports()
        let model = CallSafetyActionsViewModel(summary: callerSummary, service: service)
        let first = Task { await model.report() }
        await service.waitForPendingReport()
        #expect(model.isBusy && !model.reported)
        await model.report()
        await model.block()
        #expect(await service.blocks.isEmpty)
        await service.finishReport()
        await first.value
        #expect(model.reported && !model.isBusy)
        #expect(await service.reports.count == 1)
    }
}

private actor SafetyRecorder: CallSafetyService {
    struct Report: Sendable { let callID: String; let subjectID: String; let reason: CallReportReason; let details: String }
    struct Block: Sendable { let volunteerID: String; let callID: String }
    private(set) var reports: [Report] = []
    private(set) var blocks: [Block] = []
    private var failing = false
    private var paused = false
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func setFailing(_ value: Bool) { failing = value }
    func pauseReports() { paused = true }
    func waitForPendingReport() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finishReport() { paused = false; pending?.resume(); pending = nil }
    func hasConsent() async throws -> Bool { true }
    func acceptConsent() async throws {}
    func report(callID: String, subjectID: String, reason: CallReportReason, details: String) async throws {
        if paused {
            await withCheckedContinuation { pending = $0; waiter?.resume(); waiter = nil }
        }
        if failing { throw CallSafetyError.unavailable }
        reports.append(Report(callID: callID, subjectID: subjectID, reason: reason, details: details))
    }
    func block(volunteerID: String, callID: String) async throws {
        if failing { throw CallSafetyError.unavailable }
        blocks.append(Block(volunteerID: volunteerID, callID: callID))
    }
}
