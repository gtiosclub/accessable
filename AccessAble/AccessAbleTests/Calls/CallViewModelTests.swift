import Foundation
import Testing
@testable import AccessAble

/// Uses the placeholder signaling and video session, so no call leaves the test.
@MainActor
struct CallViewModelTests {
    private func makeViewModel() -> CallViewModel {
        var services = AppServices.preview
        services.callSignaling = PlaceholderCallSignaling()
        services.videoCall = PlaceholderVideoCallSession()
        let sam = Volunteer(id: "volunteer-1", name: "Sam", availableUntil: "Until 4 PM", isOnline: true)
        return CallViewModel(services: services, volunteer: sam)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        while !condition() { await Task.yield() }
    }

    @Test
    func startingConnectsToThePartner() async {
        let viewModel = makeViewModel()
        // start() keeps listening for call states until it is cancelled.
        let call = Task { await viewModel.start() }
        defer { call.cancel() }

        await waitUntil { viewModel.state == .connected }
        #expect(viewModel.statusText == "Connected to Sam")
    }

    @Test
    func hangingUpEndsTheCall() async {
        let viewModel = makeViewModel()
        let call = Task { await viewModel.start() }
        defer { call.cancel() }
        await waitUntil { viewModel.state == .connected }

        await viewModel.hangUp()

        #expect(viewModel.state == .ended(.hungUp))
        #expect(viewModel.statusText == "Call ended")
    }

    @Test
    func toggleMuteFlipsIsMuted() async {
        let viewModel = makeViewModel()
        let call = Task { await viewModel.start() }
        defer { call.cancel() }
        await waitUntil { viewModel.state == .connected }

        await viewModel.toggleMute()
        #expect(viewModel.isMuted)
        await viewModel.toggleMute()
        #expect(!viewModel.isMuted)
    }
}
