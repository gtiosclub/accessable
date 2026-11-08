import SwiftUI

/// Owner: Maps (2.x). Steps through route options to a place, one card at a time.
struct RoutePickerView: View {
    @Environment(AppRouter.self) private var router
    let place: SamplePlace
    let routes: [SampleRoute]
    @State private var index = 0

    init(place: SamplePlace, mode: RoutePlanMode) {
        self.place = place
        self.routes = SampleContent.routes(to: place, mode: mode)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraBackdrop()
            ScrollView {
                BottomCard {
                    Text("Destination: \(place.name)")
                        .font(.subheadline)
                    Text(routeTitle)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("\(route.minutes) minute walk")
                        .font(.title2)
                    RouteStepsList(steps: route.steps)
                        .padding(.top, 4)
                    VStack(spacing: 14) {
                        Button("Pick Route") {
                            router.push(.trip(TripPlan(place: place, route: route, isRecording: false)))
                        }
                        .buttonStyle(.pill(.primary))
                        .accessibilityHint("Starts walking this route")

                        HStack(spacing: 16) {
                            Button("Last Route") { index -= 1 }
                                .buttonStyle(.pill(.outline))
                                .disabled(index == 0)
                            Button("Next Route") { index += 1 }
                                .buttonStyle(.pill(.primary))
                                .disabled(index == routes.count - 1)
                        }
                    }
                    .padding(.top, 8)
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
            AccessibilityNotification.Announcement("Route \(index + 1) of \(routes.count): \(routeTitle), \(route.minutes) minute walk").post()
        }
    }

    private var route: SampleRoute { routes[index] }

    private var routeTitle: String {
        route.isRecorded ? "Recorded Route: \(route.title)" : route.title
    }
}

#Preview {
    NavigationStack {
        RoutePickerView(place: SampleContent.places[0], mode: .new)
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
