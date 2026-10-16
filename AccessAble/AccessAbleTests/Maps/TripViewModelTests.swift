import Testing
@testable import AccessAble

/// Reports one fixed authorization and finishes, so `TripViewModel.start()` returns once it is consumed.
private struct FixedAuthorizationProvider: LocationProvider {
    let authorization: LocationAuthorization

    func locationSamples() -> AsyncStream<LocationSample> {
        AsyncStream { continuation in continuation.finish() }
    }

    func headingSamples() -> AsyncStream<HeadingSample> {
        AsyncStream { continuation in continuation.finish() }
    }

    func authorizationStates() -> AsyncStream<LocationAuthorization> {
        AsyncStream { continuation in
            continuation.yield(authorization)
            continuation.finish()
        }
    }

    func requestAuthorization() async {}
}

@MainActor
struct TripViewModelTests {
    @Test(arguments: [
        (LocationAuthorization.notDetermined, false),
        (.restricted, true),
        (.denied, true),
        (.authorized(preciseAccuracy: true), false),
        (.authorized(preciseAccuracy: false), true),
    ])
    func needsLocationAccess(_ authorization: LocationAuthorization, expected: Bool) async {
        var services = AppServices.preview
        services.location = FixedAuthorizationProvider(authorization: authorization)
        // The placeholder's trip stream finishes, so start() returns instead of running for the view's lifetime.
        services.trip = PlaceholderTripProvider()
        let viewModel = TripViewModel(services: services)

        await viewModel.start()

        #expect(viewModel.locationAuthorization == authorization)
        #expect(viewModel.needsLocationAccess == expected)
    }

    @Test(arguments: [
        (LocationAuthorization.notDetermined, false),
        (.restricted, false),
        (.denied, false),
        (.authorized(preciseAccuracy: true), true),
        (.authorized(preciseAccuracy: false), true),
    ])
    func showsUserLocation(_ authorization: LocationAuthorization, expected: Bool) async {
        var services = AppServices.preview
        services.location = FixedAuthorizationProvider(authorization: authorization)
        services.trip = PlaceholderTripProvider()
        let viewModel = TripViewModel(services: services)

        await viewModel.start()

        #expect(viewModel.showsUserLocation == expected)
    }
}
