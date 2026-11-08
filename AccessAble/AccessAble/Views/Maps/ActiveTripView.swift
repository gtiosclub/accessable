import CoreLocation
import SwiftUI

/// Owner: Maps (2.x) + Interaction (3.x). The walking screen: the live camera or the map,
/// spoken announcements as red (obstacles) and blue (directions) bars, and Call Help /
/// microphone / Pause Trip.
///
/// With services it walks a real trip (`TripSessionViewModel`): the camera behind it is the
/// real camera pipeline, with none of the camera screen's own controls, and obstacle
/// warnings carry on in map view. Without services (previews) it shows only what is added.
struct ActiveTripView: View {
    @Environment(AppRouter.self) private var router
    @State private var session: TripSessionViewModel
    @State private var showsCommands = false
    private let services: AppServices?

    init(plan: TripPlan, services: AppServices? = nil) {
        _session = State(initialValue: TripSessionViewModel(plan: plan, services: services))
        self.services = services
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            background

            VStack(spacing: 10) {
                topBar
                    .padding(.horizontal, 24)
                if let status = session.directionsStatus {
                    Text(status)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.7), in: Capsule())
                        .padding(.horizontal, 24)
                        .accessibilityAddTraits(.updatesFrequently)
                }

                Spacer()

                AnnouncementStack(announcements: session.announcements)
                    .padding(.horizontal, 24)
                TripControlPanel(
                    isMicMuted: session.isMicMuted,
                    onCallHelp: { router.push(.callHelp) },
                    onMicrophone: { session.isMicMuted.toggle() },
                    onPauseTrip: { session.pause() }
                )
            }
            .accessibilityHidden(session.isRouteBlocked || session.isPaused)

            if session.isRouteBlocked {
                RouteBlockedScreen(
                    postsAnnouncement: !session.isSpokenByEngine,
                    onCallHelp: { router.push(.callHelp) },
                    onReroute: { session.reroute() },
                    onPause: { session.pause() },
                    onContinue: { session.resume() }
                )
                .transition(.opacity)
            }

            if session.isPaused {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                TripPausedCard(
                    isRecording: session.plan.isRecording,
                    onContinue: { session.resume() },
                    onExit: {
                        session.exit()
                        router.popToRoot()
                    },
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
        .task { await session.run() }
        .onChange(of: session.latestAnnouncement) { _, announcement in
            // On a real trip the announcement engine has already spoken it, through VoiceOver
            // when that is on; posting it again would read it twice.
            guard let announcement, !session.isSpokenByEngine else { return }
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

    /// The live camera, or the map with the real route once there is one. Leaving the camera
    /// view doesn't stop obstacle warnings: the session holds the camera for the whole trip.
    @ViewBuilder
    private var background: some View {
        if session.showsMap {
            CampusMap(routeLine: session.directions?.route?.coordinates.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            } ?? (services == nil ? SampleContent.sampleRouteLine : nil))
        } else if let services {
            LiveSceneView(services: services, mode: .walk, chrome: .cameraOnly)
        } else {
            CameraBackdrop()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            if session.plan.isRecording {
                Label("Recording", systemImage: "record.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.red, in: Capsule())
                    .accessibilityLabel("Recording route")
            }
            Spacer(minLength: 0)
            viewSwitch
            Spacer(minLength: 0)
            CircleIconButton(systemImage: "info", label: "Voice commands") {
                showsCommands = true
            }
        }
    }

    /// Camera or map, also switched by a two-finger swipe or the VoiceOver action.
    private var viewSwitch: some View {
        Picker("View", selection: $session.showsMap) {
            Label("Camera", systemImage: "camera").tag(false)
            Label("Map", systemImage: "map").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 200)
        .padding(4)
        .background(.black.opacity(0.6), in: Capsule())
        .accessibilityHint("Obstacle warnings continue in both views")
    }
}

/// Route Blocked Ahead: takes the whole screen, since the user has to choose before going on.
struct RouteBlockedScreen: View {
    var postsAnnouncement = true
    let onCallHelp: () -> Void
    let onReroute: () -> Void
    let onPause: () -> Void
    let onContinue: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 88, weight: .semibold))
                    .foregroundStyle(Theme.red)
                    .accessibilityHidden(true)
                Spacer()
                RouteBlockedCard(
                    postsAnnouncement: postsAnnouncement,
                    onCallHelp: onCallHelp,
                    onReroute: onReroute,
                    onPause: onPause,
                    onContinue: onContinue
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
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
    /// False when the announcement engine says "Route blocked ahead" itself.
    var postsAnnouncement = true
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
            if postsAnnouncement {
                AccessibilityNotification.Announcement("Route blocked ahead").post()
            }
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
