import SwiftUI

/// Owner: Maps (2.x) + Interaction (3.x). The walking screen: camera or map, spoken
/// announcements, and Call Help / microphone / Pause Trip.
/// Front end only: announcements are samples and voice commands are simulated.
struct ActiveTripView: View {
    @Environment(AppRouter.self) private var router
    @State private var session: TripSessionViewModel
    @State private var showsCommands = false

    init(plan: TripPlan) {
        _session = State(initialValue: TripSessionViewModel(plan: plan))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if session.showsMap {
                CampusMap(routeLine: SampleContent.sampleRouteLine)
            } else {
                CameraBackdrop()
            }

            VStack(spacing: 12) {
                HStack {
                    if session.plan.isRecording {
                        Label("Recording route", systemImage: "record.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.red, in: Capsule())
                    }
                    Spacer()
                    CircleIconButton(systemImage: "info", label: "Voice commands") {
                        showsCommands = true
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                if session.isRouteBlocked {
                    RouteBlockedCard(
                        onCallHelp: { router.push(.callHelp) },
                        onReroute: { session.reroute() },
                        onPause: { session.pause() },
                        onContinue: { session.resume() }
                    )
                    .transition(.move(edge: .bottom))
                } else {
                    AnnouncementStack(announcements: session.announcements)
                        .padding(.horizontal, 24)
                    TripControlPanel(
                        isMicMuted: session.isMicMuted,
                        onCallHelp: { router.push(.callHelp) },
                        onMicrophone: { session.isMicMuted.toggle() },
                        onPauseTrip: { session.pause() }
                    )
                }
            }

            if session.isPaused {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                TripPausedCard(
                    isRecording: session.plan.isRecording,
                    onContinue: { session.resume() },
                    onExit: { router.popToRoot() },
                    onSettings: { router.push(.settings) },
                    onCallHelp: { router.push(.callHelp) }
                )
                .padding(.horizontal, 24)
                .frame(maxHeight: .infinity)
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.isPaused)
        .animation(.easeInOut(duration: 0.25), value: session.isRouteBlocked)
        .animation(.easeInOut(duration: 0.25), value: session.showsMap)
        .gesture(TwoFingerSwipe { session.showsMap.toggle() })
        .accessibilityAction(named: session.showsMap ? "Show camera view" : "Show map view") {
            session.showsMap.toggle()
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: session.latestAnnouncement) { _, announcement in
            guard let announcement else { return }
            AccessibilityNotification.Announcement(announcement.text).post()
        }
        .sheet(isPresented: $showsCommands) {
            VoiceCommandsSheet(
                onTry: { command in
                    showsCommands = false
                    if !session.run(command), command == .callHelp {
                        router.push(.callHelp)
                    }
                },
                onSimulateBlockedRoute: {
                    showsCommands = false
                    session.simulateBlockedRoute()
                }
            )
        }
    }
}

struct TripPausedCard: View {
    let isRecording: Bool
    let onContinue: () -> Void
    let onExit: () -> Void
    let onSettings: () -> Void
    let onCallHelp: () -> Void

    @AccessibilityFocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Trip Paused")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isTitleFocused)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("Continue Walking", action: onContinue)
                .buttonStyle(.pill(.primary))
            Button("Exit Trip", action: onExit)
                .buttonStyle(.pill(.destructive))
                .accessibilityHint(isRecording ? "Ends the trip and saves the recorded route" : "Ends the trip")
            HStack(spacing: 14) {
                Button("Settings", action: onSettings)
                    .buttonStyle(.pill(.outline))
                Button("Call Help", action: onCallHelp)
                    .buttonStyle(.pill(.outline))
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { isTitleFocused = true }
    }

    private var message: String {
        isRecording
            ? "Recorded new trip will be paused here; will be continued if continued walking, and will be saved if exit trip now."
            : "Directions are paused here. Continue walking when you're ready, or exit the trip."
    }
}

struct RouteBlockedCard: View {
    let onCallHelp: () -> Void
    let onReroute: () -> Void
    let onPause: () -> Void
    let onContinue: () -> Void

    @AccessibilityFocusState private var isTitleFocused: Bool

    var body: some View {
        BottomCard {
            VStack(spacing: 14) {
                Text("Route Blocked Ahead")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($isTitleFocused)
                Text("Something is blocking the path ahead. Would you like a safer route?")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button("Call Help", action: onCallHelp)
                    .buttonStyle(.pill(.outline))
                Button("Re-Route", action: onReroute)
                    .buttonStyle(.pill(.destructive))
                    .accessibilityHint("Finds a safer route")
                Button("Pause Trip", action: onPause)
                    .buttonStyle(.pill(.destructive))
                Button("Continue Walking", action: onContinue)
                    .buttonStyle(.pill(.primary))
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .onAppear {
            isTitleFocused = true
            AccessibilityNotification.Announcement("Route blocked ahead").post()
        }
    }
}

#Preview("Walking") {
    NavigationStack {
        ActiveTripView(plan: TripPlan(place: SampleContent.places[0], route: nil, isRecording: false))
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}

#Preview("Paused card") {
    ZStack {
        CameraBackdrop()
        TripPausedCard(isRecording: true, onContinue: {}, onExit: {}, onSettings: {}, onCallHelp: {})
            .padding(24)
    }
}
