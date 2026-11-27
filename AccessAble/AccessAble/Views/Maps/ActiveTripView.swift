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
    /// Where a report goes, set by the button that opens the choices, so it is what that button said.
    @State private var reportSource: ReportSource?
    /// Report was tried from Voice Commands: its choices open once the sheet has closed, since a
    /// dialog can't open while the sheet is still going.
    @State private var reportsAfterCommands = false
    private let services: AppServices?

    init(plan: TripPlan, services: AppServices? = nil, recentPlaces: RecentPlacesStore? = nil) {
        _session = State(initialValue: TripSessionViewModel(plan: plan, services: services, recentPlaces: recentPlaces))
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

                if session.isReportingAvailable {
                    Button("Report a problem here") {
                        reportSource = .here
                    }
                    .buttonStyle(.pill(.outline, size: .compact))
                    .accessibilityHint("Choose the problem at your location")
                }

                Spacer()

                AnnouncementStack(announcements: session.announcements)
                    .padding(.horizontal, 24)
                if let question = session.reportQuestion {
                    reportQuestionBar(question)
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                }
                if let state = voiceState {
                    voiceCaption(state)
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                }
                TripControlPanel(
                    isMicMuted: session.isMicOff,
                    onCallHelp: { router.push(.callHelp) },
                    onMicrophone: { Task { await session.toggleMicrophone() } },
                    onPauseTrip: { session.pause() },
                    hasArrived: session.hasArrived,
                    onEndTrip: {
                        session.exit()
                        router.popToRoot()
                    }
                )
            }
            .accessibilityHidden(session.isRouteBlocked || session.isPaused)

            if session.isRouteBlocked {
                RouteBlockedScreen(
                    postsAnnouncement: !session.isSpokenByEngine,
                    onCallHelp: { router.push(.callHelp) },
                    onReroute: { session.reroute() },
                    onPause: { session.pause() },
                    onContinue: { session.resume() },
                    onReport: session.isReportingAvailable ? { reportSource = .routeAhead } : nil
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
        .animation(.easeInOut(duration: 0.2), value: voiceState)
        .animation(.easeInOut(duration: 0.2), value: session.reportQuestion)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            session.onCallHelp = { router.push(.call(nil)) }
            await session.run()
        }
        .onChange(of: session.latestAnnouncement) { _, announcement in
            // On a real trip the announcement engine has already spoken it, through VoiceOver
            // when that is on; posting it again would read it twice.
            guard let announcement, !session.isSpokenByEngine else { return }
            AccessibilityNotification.Announcement(announcement.text).post()
        }
        .confirmationDialog(
            "What kind of problem?",
            isPresented: Binding(get: { reportSource != nil }, set: { if !$0 { reportSource = nil } }),
            titleVisibility: .visible,
            presenting: reportSource
        ) { source in
            ForEach(ReportKind.allCases) { kind in
                Button(kind.title) {
                    Task { await session.submitReport(kind: kind, useRouteAhead: source == .routeAhead) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { source in
            Text(source == .routeAhead
                 ? "Choose the problem just ahead on your route."
                 : "Choose the problem at your location.")
        }
        .sheet(isPresented: $showsCommands, onDismiss: {
            guard reportsAfterCommands else { return }
            reportsAfterCommands = false
            reportSource = .here
        }) {
            VoiceCommandsSheet(
                onTry: { command in
                    showsCommands = false
                    guard !session.run(command) else { return }
                    switch command {
                    case .callHelp: router.push(.callHelp)
                    case .reportProblem: reportsAfterCommands = true
                    default: break
                    }
                },
                onSimulateBlockedRoute: {
                    showsCommands = false
                    session.simulateBlockedRoute()
                },
                listsReport: session.isReportingAvailable
            )
        }
    }

    /// Where the person is, or just ahead on the route (from Route Blocked Ahead).
    private enum ReportSource {
        case here
        case routeAhead
    }

    private enum VoiceState: Equatable {
        case listening(String)
        case answering
        case lookingAgain
    }

    private var voiceState: VoiceState? {
        if let heard = session.heard { return .listening(heard) }
        if session.isLookingAgain { return .lookingAgain }
        if session.isAnswering { return .answering }
        return nil
    }

    /// What the mic is doing: the words as they are heard, then thinking.
    private func voiceCaption(_ state: VoiceState) -> some View {
        HStack(spacing: 10) {
            switch state {
            case .listening(let heard):
                Image(systemName: "waveform")
                    .foregroundStyle(Theme.red)
                    .symbolEffect(.variableColor.iterative)
                Text(heard.isEmpty ? "Listening…" : heard)
                    .lineLimit(2)
            case .answering:
                ProgressView().tint(.white)
                Text("Thinking…")
            case .lookingAgain:
                ProgressView().tint(.white)
                Text("Looking… turn slowly")
            }
            Spacer(minLength: 0)
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.4)))
        // VoiceOver users hear the reply when it comes; the live words would talk over them.
        .accessibilityHidden(true)
    }

    /// Yes and No for the report question that was just said, while its answer is waited for. Not a dialog, so the
    /// trip screen stays usable and the question goes away by itself.
    private func reportQuestionBar(_ question: OpenReportQuestion) -> some View {
        VStack(spacing: 10) {
            Text(question.text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                // said aloud already; the buttons carry it for VoiceOver
                .accessibilityHidden(true)
            HStack(spacing: 12) {
                Button("Yes") { Task { await session.answer(question, isStillPresent: true) } }
                    .buttonStyle(.pill(.primary, size: .compact))
                    .accessibilityLabel("Yes, still there")
                    .accessibilityHint(question.text)
                Button("No") { Task { await session.answer(question, isStillPresent: false) } }
                    .buttonStyle(.pill(.outline, size: .compact))
                    .accessibilityLabel("No, it's gone")
                    .accessibilityHint(question.text)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.4)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question.text)
    }

    /// The live camera, or the map with the real route once there is one. Leaving the camera
    /// view doesn't stop obstacle warnings: the session holds the camera for the whole trip.
    @ViewBuilder
    private var background: some View {
        if session.showsMap {
            CampusMap(
                routeLine: session.directions?.route?.coordinates.map(\.clCoordinate),
                destination: session.directions?.destination ?? Destination(
                    name: session.plan.place.name,
                    coordinate: GeoCoordinate(latitude: session.plan.place.latitude, longitude: session.plan.place.longitude)
                ),
                accessibilityLabel: session.mapAccessibilityLabel,
                reports: session.mapReports
            )
        } else if let services, session.isCameraReady {
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
    /// Nil hides the report button, where reporting isn't available.
    let onReport: (() -> Void)?

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
                    onContinue: onContinue,
                    onReport: onReport
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
    /// Nil hides the report button, where reporting isn't available.
    let onReport: (() -> Void)?

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
                if let onReport {
                    Button("Report the blockage", action: onReport)
                        .buttonStyle(.pill(.outline))
                        .accessibilityHint("Reports the problem just ahead on your route")
                }
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

#if DEBUG
#Preview("Walking") {
    NavigationStack {
        ActiveTripView(plan: TripPlan(place: MapsPreviewData.place, route: nil, isRecording: false))
    }
    .environment(AppRouter())
    .preferredColorScheme(.dark)
}
#endif

#Preview("Paused card") {
    ZStack {
        CameraBackdrop()
        TripPausedCard(isRecording: true, onContinue: {}, onExit: {}, onSettings: {}, onCallHelp: {})
            .padding(24)
    }
}
