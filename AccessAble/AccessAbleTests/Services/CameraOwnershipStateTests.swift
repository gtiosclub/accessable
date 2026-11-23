import Foundation
import Testing
@testable import AccessAble

struct CameraOwnershipStateTests {
    @Test func resumesAnExistingARClient() throws {
        var state = CameraOwnershipState()
        let started = state.requestARStart()
        #expect(started)
        let owner = try state.acquireForCall()
        let released = state.releaseFromCall(owner)
        #expect(released == true)
        #expect(state.callOwner == nil)
    }

    @Test func idleCameraDoesNotStartARAfterCall() throws {
        var state = CameraOwnershipState()
        let owner = try state.acquireForCall()
        let released = state.releaseFromCall(owner)
        #expect(released == false)
    }

    @Test func newARClientWaitsForCallToEnd() throws {
        var state = CameraOwnershipState()
        let owner = try state.acquireForCall()
        let started = state.requestARStart()
        #expect(!started)
        let released = state.releaseFromCall(owner)
        #expect(released == true)
    }

    @Test func lastARClientLeavingPreventsRestart() throws {
        var state = CameraOwnershipState()
        _ = state.requestARStart()
        let owner = try state.acquireForCall()
        state.requestARStop()
        let released = state.releaseFromCall(owner)
        #expect(released == false)
    }

    @Test func secondCallCannotTakeTheCamera() throws {
        var state = CameraOwnershipState()
        let owner = try state.acquireForCall()
        #expect(throws: CameraOwnershipError.alreadyInCall) { try state.acquireForCall() }
        #expect(state.callOwner == owner)
    }

    @Test func staleReleaseCannotResumeAR() throws {
        var state = CameraOwnershipState()
        _ = state.requestARStart()
        let owner = try state.acquireForCall()
        let staleRelease = state.releaseFromCall(UUID())
        #expect(staleRelease == nil)
        #expect(state.callOwner == owner)
        let released = state.releaseFromCall(owner)
        #expect(released == true)
        let releasedAgain = state.releaseFromCall(owner)
        #expect(releasedAgain == nil)
    }
}
