import SwiftUI

/// Owner: Maps (2.x). Steps through route options to a place, one card at a time.
///
/// A new route is the real walking route from Valhalla. Valhalla returns one, so there is one
/// option until preferences add another (such as fewest stairs); Last and Next show once there
/// is more than one. Pick Route hands that exact route to the trip. Recorded routes are still
/// samples.
struct RoutePickerView: View {
    @Environment(AppRouter.self) private var router
    let place: SamplePlace
    let mode: RoutePlanMode
    let origin: SamplePlace?
    /// Recorded routes only; samples until recording is wired in.
    let sampleRoutes: [SampleRoute]
    @State private var details: PlaceDetailViewModel
    @State private var index = 0

    /// - Parameter planned: The route the details screen already found, so it isn't asked for again.
    init(
        place: SamplePlace,
        mode: RoutePlanMode,
        origin: SamplePlace? = nil,
        planned: PlannedRoute? = nil,
        services: AppServices
    ) {
        self.place = place
        self.mode = mode
        self.origin = origin
        sampleRoutes = mode == .recorded ? SampleContent.routes(to: place, mode: .recorded) : []
        let destination = planned?.destination ?? Destination(
            name: place.name,
            coordinate: GeoCoordinate(latitude: place.latitude, longitude: place.longitude),
            address: place.address.isEmpty ? nil : place.address
        )
        _details = State(initialValue: PlaceDetailViewModel(destination: destination, services: services, planned: planned))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraBackdrop()
            ScrollView {
                BottomCard {
                    Text("Destination: \(place.name)")
                        .font(.subheadline)
                    switch mode {
                    case .new: walkingRoute
                    case .recorded: recordedRoute
                    }
                    Button("Back") { router.pop() }
                        .buttonStyle(.plain)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: AccessibilityMetrics.minimumTapTarget)
                }
                .foregroundStyle(.white)
            }
            .defaultScrollAnchor(.bottom)
            .scrollBounceBehavior(.basedOnSize)
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { router.pop() }
        .onChange(of: index) {
            AccessibilityNotification.Announcement("Route \(index + 1) of \(sampleRoutes.count): \(recordedTitle), \(sampleRoute.minutes) minute walk").post()
        }
        .modifier(RealRouteModifier(details: details, isActive: mode == .new))
    }

    // MARK: - New: the real route

    @ViewBuilder
    private var walkingRoute: some View {
        Text("Walking Route")
            .font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
        RoutePreview(details: details, origin: origin)
            .padding(.top, 4)
        Button("Pick Route") {
            guard let planned = details.plannedRoute else { return }
            router.push(.trip(TripPlan(place: place, route: nil, isRecording: false, origin: origin, plannedRoute: planned)))
        }
        .buttonStyle(.pill(.primary))
        .disabled(details.plannedRoute == nil)
        .opacity(details.plannedRoute == nil ? Theme.dimmedOpacity : 1)
        .accessibilityHint(details.plannedRoute == nil ? "Available once the route is found" : "Starts walking this route")
        .padding(.top, 8)
    }

    // MARK: - Recorded: samples

    @ViewBuilder
    private var recordedRoute: some View {
        Text(recordedTitle)
            .font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
        Text("\(sampleRoute.minutes) minute walk")
            .font(.title2)
        RouteStepsList(steps: sampleRoute.steps)
            .padding(.top, 4)
        VStack(spacing: 14) {
            Button("Pick Route") {
                router.push(.trip(TripPlan(place: place, route: sampleRoute, isRecording: false, origin: origin)))
            }
            .buttonStyle(.pill(.primary))
            .accessibilityHint("Starts walking this route")

            if sampleRoutes.count > 1 {
                HStack(spacing: 16) {
                    Button("Last Route") { index -= 1 }
                        .buttonStyle(.pill(.outline))
                        .disabled(index == 0)
                    Button("Next Route") { index += 1 }
                        .buttonStyle(.pill(.primary))
                        .disabled(index == sampleRoutes.count - 1)
                }
            }
        }
        .padding(.top, 8)
    }

    private var sampleRoute: SampleRoute { sampleRoutes[index] }

    private var recordedTitle: String { "Recorded Route: \(sampleRoute.title)" }
}

/// Finds the real route and speaks when it arrives or fails; nothing for recorded routes.
private struct RealRouteModifier: ViewModifier {
    let details: PlaceDetailViewModel
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content
                .announcesRoute(details.planner)
                .task { await details.start() }
        } else {
            content
        }
    }
}

#Preview {
    NavigationStack {
        RoutePickerView(place: SampleContent.places[0], mode: .new, services: .preview)
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
