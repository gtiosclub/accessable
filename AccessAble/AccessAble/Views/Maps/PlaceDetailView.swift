import SwiftUI

/// Owner: Maps (2.x). A chosen place: address, recorded route, and how to start.
struct PlaceDetailView: View {
    @Environment(AppRouter.self) private var router
    let place: SamplePlace
    /// Picked in search; nil for My Location.
    var origin: SamplePlace?

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraBackdrop()
            ScrollView {
                BottomCard {
                    Text(place.name)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(place.address)
                        .font(.subheadline.weight(.semibold))
                    Label("From: \(origin?.name ?? "My Location")", systemImage: origin == nil ? "location.fill" : "circle.inset.filled")
                        .font(.subheadline)
                        .accessibilityLabel("From \(origin?.name ?? "my location")")
                    if place.recordedRouteCount > 0 {
                        RouteStepsList(steps: SampleContent.walkSteps)
                            .padding(.top, 4)
                    }
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
        PlaceDetailView(place: SampleContent.places[0])
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
