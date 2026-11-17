import Foundation
import Testing
@testable import AccessAble

struct CameraOwnershipStateTests {
    @Test func resumesAnExistingARClient() throws {
        var state = CameraOwnershipState()
        #expect(state.requestARStart())
        let owner = try state.acquireForCall()
        #expect(state.releaseFromCall(owner) == true)
        #expect(state.callOwner == nil)
    }

    @Test func idleCameraDoesNotStartARAfterCall() throws {
        var state = CameraOwnershipState()
        let owner = try state.acquireForCall()
        #expect(state.releaseFromCall(owner) == false)
    }

    @Test func newARClientWaitsForCallToEnd() throws {
        var state = CameraOwnershipState()
        let owner = try state.acquireForCall()
        #expect(!state.requestARStart())
        #expect(state.releaseFromCall(owner) == true)
    }

    @Test func lastARClientLeavingPreventsRestart() throws {
        var state = CameraOwnershipState()
        _ = state.requestARStart()
        let owner = try state.acquireForCall()
        state.requestARStop()
        #expect(state.releaseFromCall(owner) == false)
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
        #expect(state.releaseFromCall(UUID()) == nil)
        #expect(state.callOwner == owner)
        #expect(state.releaseFromCall(owner) == true)
        #expect(state.releaseFromCall(owner) == nil)
    }
}
