import SwiftUI

/// Owner: Maps (2.x). A chosen place: name, address, the real walking route to it (distance,
/// time and steps), and how to start.
struct PlaceDetailView: View {
    @Environment(AppRouter.self) private var router
    /// What the route and trip screens take. For a place from search, made from the destination.
    let place: SamplePlace
    /// Picked in search; nil for My Location.
    var origin: SamplePlace?
    @State private var details: PlaceDetailViewModel

    /// Steps shown before "+ N more steps".
    private static let previewStepCount = 3

    /// A sample saved or recent place. Its coordinate is real, so its route is too.
    init(place: SamplePlace, origin: SamplePlace? = nil, services: AppServices) {
        let destination = Destination(
            name: place.name,
            coordinate: GeoCoordinate(latitude: place.latitude, longitude: place.longitude),
            address: place.address.isEmpty ? nil : place.address
        )
        self.place = place
        self.origin = origin
        _details = State(initialValue: PlaceDetailViewModel(destination: destination, services: services))
    }

    /// A real place picked from search results.
    init(destination: Destination, origin: SamplePlace? = nil, services: AppServices) {
        place = SamplePlace(destination: destination)
        self.origin = origin
        _details = State(initialValue: PlaceDetailViewModel(destination: destination, services: services))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraBackdrop()
            ScrollView {
                BottomCard {
                    Text(details.destination.name)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    if let address = details.destination.address {
                        Text(address)
                            .font(.subheadline.weight(.semibold))
                    }
                    Label("From: \(origin?.name ?? "My Location")", systemImage: origin == nil ? "location.fill" : "circle.inset.filled")
                        .font(.subheadline)
                        .accessibilityLabel("From \(origin?.name ?? "my location")")
                    routeDetails
                        .padding(.top, 4)
                    VStack(spacing: 14) {
                        Button("Start & Record New Route") {
                            router.push(.trip(TripPlan(place: place, route: nil, isRecording: true, origin: origin)))
                        }
                        .buttonStyle(.pill(.destructive))
                        .accessibilityHint("Starts walking and saves the route you take")

                        if place.recordedRouteCount > 0 {
                            Button("Start Recorded Route") { router.push(.routes(place, .recorded, origin: origin)) }
                                .buttonStyle(.pill(.primary))
                        }
                        Button("Start New Route") { router.push(.routes(place, .new, origin: origin)) }
                            .buttonStyle(.pill(.primary))
                        Button("Back") { router.pop() }
                            .buttonStyle(.pill(.outline))
                    }
                    .padding(.top, 8)
                }
                .foregroundStyle(.white)
            }
            .defaultScrollAnchor(.bottom)
            .scrollBounceBehavior(.basedOnSize)
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { router.pop() }
        // Route ready and route failed, spoken as on the Trip screen.
        .announcesRoute(details.planner)
        .task { await details.start() }
    }

    /// The walking route, or why it isn't here yet.
    @ViewBuilder
    private var routeDetails: some View {
        if let summary = details.summary {
            VStack(alignment: .leading, spacing: 8) {
                Label(summary, systemImage: "figure.walk")
                    .font(.headline)
                    .accessibilityLabel(summary.replacingOccurrences(of: " · ", with: ", "))
                if origin != nil {
                    Text("Walking directions start where you are.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
                VStack(alignment: .leading, spacing: 6) {
                    // A preview only, so the card fits under the title; the trip reads every step.
                    ForEach(Array(details.steps.prefix(Self.previewStepCount).enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).")
                                .monospacedDigit()
                                .accessibilityHidden(true)
                            Text(step)
                                .lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Step \(index + 1), \(step)")
                    }
                    let remaining = details.steps.count - Self.previewStepCount
                    if remaining > 0 {
                        Text(remaining == 1 ? "+ 1 more step" : "+ \(remaining) more steps")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .font(.subheadline)
            }
        } else if let message = details.errorMessage {
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                Button("Try again") { details.retry() }
                    .buttonStyle(.pill(.outline, size: .compact))
                    .accessibilityHint("Asks for the walking route again")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.red.opacity(0.25), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if details.needsLocationAccess {
            Label("Location is off. Turn it on in Settings to see the walking route.", systemImage: "location.slash.fill")
                .font(.subheadline)
        } else {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                Text("Finding a walking route…")
                    .font(.subheadline)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// "Walk out the house / Walk 50 ft • Walk past 1 crossroad …"
struct RouteStepsList: View {
    let steps: [SampleRouteStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(steps, id: \.self) { step in
                Text(step.text)
                ForEach(step.details, id: \.self) { detail in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "•").accessibilityHidden(true)
                        Text(detail)
                    }
                    .padding(.leading, 8)
                }
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Route steps")
    }
}

#Preview {
    NavigationStack {
        PlaceDetailView(place: SampleContent.places[0], services: .preview)
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}

#Preview("From search") {
    NavigationStack {
        PlaceDetailView(destination: Destination(
            name: "Clough Undergraduate Learning Commons",
            coordinate: GeoCoordinate(latitude: 33.7746, longitude: -84.3964),
            address: "266 4th St NW, Atlanta, GA"
        ), services: .preview)
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
