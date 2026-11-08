import ARKit
import SceneKit
import SwiftUI

/// Owner: Computer Vision (1.1). The live camera screen.
///
/// What users see is kept to what matters: the camera, one outline around the nearest thing
/// in the path that they asked to hear about, a colour-coded status strip that says the same
/// thing the voice does, and the controls along the bottom. In debug builds a wrench in the
/// toolbar adds the developer tools: every detection box, the pipeline readout, and the
/// field-test recorder.
///
/// Requires a real device — ARKit world tracking does not run in the Simulator — and a
/// LiDAR device for the floor, obstacle and kerb readouts.
struct LiveSceneView: View {
    @Environment(AppViewModel.self) private var app
    @State private var viewModel: LiveSceneViewModel
    @State private var asksDestination = false
    @State private var destination = ""
    /// Developer tools are compiled into debug builds only, and off until switched on.
    @AppStorage("liveSceneShowsDeveloperTools") private var showsDeveloperTools = false

    init(services: AppServices) {
        _viewModel = State(initialValue: LiveSceneViewModel(services: services))
    }

    private var isDeveloperMode: Bool {
        #if DEBUG
        showsDeveloperTools
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            if let error = viewModel.errorMessage {
                unavailable(error)
            } else {
                preview
                VStack(spacing: 10) {
                    modePicker
                    if let event = viewModel.visibleAnnouncement {
                        AnnouncementBanner(event: event)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if isDeveloperMode {
                        fieldTestControls
                    }
                    Spacer()
                    if isDeveloperMode {
                        readout
                    }
                    if let message = viewModel.navigationMessage {
                        Text(message)
                            .font(.headline)
                            .foregroundStyle(viewModel.navigation?.phase == .notFound ? Color.red : Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                    statusStrip
                    controlBar
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .animation(.easeInOut(duration: 0.25), value: viewModel.visibleAnnouncement?.id)
            }
        }
        .navigationTitle("Live detection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            #if DEBUG
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsDeveloperTools.toggle()
                } label: {
                    Image(systemName: showsDeveloperTools ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
                }
                .accessibilityLabel(showsDeveloperTools ? "Hide developer tools" : "Show developer tools")
            }
            #endif
        }
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
        .alert("Where do you want to go?", isPresented: $asksDestination) {
            TextField("For example: the chair, exit, room 210", text: $destination)
            Button("Go") { viewModel.navigate(to: destination) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Then turn slowly all the way around so the camera can find it.")
        }
    }

    // MARK: - For users

    private var preview: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let analyzer = viewModel.analyzer {
                    ARCameraPreview(session: analyzer.sessionManager.session)
                }

                if isDeveloperMode {
                    ForEach(viewModel.observation.detections) { detection in
                        DetectionBox(
                            detection: detection,
                            rect: rect(for: detection, in: geometry.size)
                        )
                    }
                }

                // The geometry's unnamed obstacles are clusters of depth points whose boxes
                // cover half the screen; the status strip speaks for them instead.
                if let focus = viewModel.focus, focus.label != Detection.obstacleLabel,
                   let caption = viewModel.focusCaption {
                    FocusOutline(
                        caption: caption,
                        color: statusColor,
                        rect: rect(for: focus, in: geometry.size)
                    )
                    .transition(.opacity)
                }

                Image(systemName: "viewfinder")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(radius: 2)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .animation(.easeOut(duration: 0.2), value: viewModel.focus.map { $0.trackID ?? $0.id })
            // The outline is for sighted users; VoiceOver gets the status strip instead.
            .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }

    private func rect(for detection: Detection, in size: CGSize) -> CGRect {
        aspectFillRect(
            normalizedBox: detection.boundingBox,
            imageAspectRatio: viewModel.imageAspectRatio,
            viewSize: size
        )
    }

    /// Clear / caution / stop, in the colour and words of the current warning.
    private var statusStrip: some View {
        let status = viewModel.status
        return HStack(spacing: 14) {
            Image(systemName: statusSymbol(status.level, side: viewModel.warning?.side))
                .font(.title.weight(.semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.title2.weight(.bold))
                if let detail = status.detail {
                    Text(detail)
                        .font(.headline)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(status.level == .starting ? Color.primary : Color.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(statusBackground(status.level), in: RoundedRectangle(cornerRadius: 20))
        .animation(.easeInOut(duration: 0.2), value: status)
        .accessibilityElement(children: .combine)
        .accessibilityValue(viewModel.spokenSummary)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var statusColor: Color {
        switch viewModel.status.level {
        case .stop: .red
        case .caution: .orange
        case .clear, .starting: .green
        }
    }

    /// Stop is always a hand. Otherwise an arrow points the way the advice sends the user.
    private func statusSymbol(_ level: LiveSceneViewModel.PathStatus.Level, side: TurnSide?) -> String {
        switch (level, side) {
        case (.starting, _): "camera"
        case (.clear, _): "checkmark.circle.fill"
        case (.stop, _): "hand.raised.fill"
        case (.caution, .left): "arrow.up.left.circle.fill"
        case (.caution, .right): "arrow.up.right.circle.fill"
        case (.caution, nil): "exclamationmark.triangle.fill"
        }
    }

    private func statusBackground(_ level: LiveSceneViewModel.PathStatus.Level) -> AnyShapeStyle {
        switch level {
        case .starting: AnyShapeStyle(.regularMaterial)
        case .clear: AnyShapeStyle(Color.green.opacity(0.85))
        case .caution: AnyShapeStyle(Color.orange.opacity(0.9))
        case .stop: AnyShapeStyle(Color.red.opacity(0.9))
        }
    }

    /// Walk / Find / Read / Describe, after Magnifier's detection modes.
    private var modePicker: some View {
        Picker("Mode", selection: $viewModel.mode) {
            ForEach(LiveMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.large)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityHint("Walk warns about obstacles. Find takes you somewhere. Read reads signs aloud. Describe tells you what is around you.")
    }

    /// What each mode can do, plus the alert settings.
    private var controlBar: some View {
        HStack(spacing: 10) {
            switch viewModel.mode {
            case .walk:
                identifyButton
            case .find:
                if viewModel.isNavigating {
                    controlButton("Stop guiding", systemImage: "xmark.circle.fill", tint: .red) {
                        viewModel.stopNavigating()
                    }
                } else {
                    controlButton("Take me to…", systemImage: "location.north.circle.fill") {
                        asksDestination = true
                    }
                    .accessibilityHint("Type what to find. Turn around slowly, then follow the spoken directions.")
                }
            case .read:
                controlButton("Read again", systemImage: "text.bubble.fill") {
                    viewModel.readAgain()
                }
                .disabled(viewModel.lastReading == nil)
                .accessibilityHint("Repeats the last sign that was read.")
            case .describe:
                controlButton("Describe", systemImage: "eye.fill") {
                    viewModel.describe()
                }
                .disabled(viewModel.isDescribing)
                .accessibilityHint("Describes what the camera sees.")
                identifyButton
            }

            alertMenu
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }

    private var identifyButton: some View {
        controlButton("Identify", systemImage: "viewfinder") {
            viewModel.identifyPointedAt()
        }
        .accessibilityHint("Identifies text or an object near the center of the camera.")
    }

    private func controlButton(
        _ title: String, systemImage: String, tint: Color = .accentColor, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.title2)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }

    /// The danger bar and warning distance (saved in the profile, so trips use them too).
    private var alertMenu: some View {
        @Bindable var app = app
        return Menu {
            Picker("Warn me about", selection: $app.profile.alertFilter.minimumDanger) {
                ForEach(DangerLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.menu)
            Picker("Warn me within", selection: $app.profile.alertFilter.maximumDistance) {
                ForEach(AlertFilter.distanceChoices, id: \.self) { distance in
                    Text(String(format: "%g metres", distance)).tag(distance)
                }
            }
            .pickerStyle(.menu)
            Toggle("Vibration", isOn: channelBinding(.haptics, in: $app.profile))
            // Steering beeps from the side to move towards; best with headphones.
            Toggle("Sound cues", isOn: channelBinding(.spatialAudio, in: $app.profile))
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                Text("Alerts")
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Alerts")
        .accessibilityValue(
            "\(app.profile.alertFilter.minimumDanger.displayName), within "
                + String(format: "%g metres", app.profile.alertFilter.maximumDistance)
                + (app.profile.channels.contains(.haptics) ? ", vibration on" : ", vibration off")
                + (app.profile.channels.contains(.spatialAudio) ? ", sound cues on" : ", sound cues off")
        )
        .accessibilityHint("Choose how dangerous and how close something must be before you are warned, and whether the phone vibrates.")
    }

    private func channelBinding(_ channel: GuidanceChannels, in profile: Binding<GuidanceProfile>) -> Binding<Bool> {
        Binding(
            get: { profile.wrappedValue.channels.contains(channel) },
            set: { isOn in
                if isOn { profile.wrappedValue.channels.insert(channel) } else { profile.wrappedValue.channels.remove(channel) }
            }
        )
    }

    // MARK: - Developer tools

    /// Record / mark controls for running the device validation checklist.
    private var fieldTestControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    viewModel.toggleRecording()
                } label: {
                    Label(viewModel.isRecording ? "Stop" : "Record", systemImage: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .tint(viewModel.isRecording ? .red : .accentColor)

                Menu {
                    ForEach(LiveSceneViewModel.checklistMarks, id: \.self) { label in
                        Button(label) { viewModel.mark(label) }
                    }
                } label: {
                    Label("Mark step", systemImage: "flag")
                }
                .disabled(!viewModel.isRecording)

                Spacer()
            }
            .buttonStyle(.bordered)

            if viewModel.isRecording, let name = viewModel.recordingName {
                Text("● \(name)" + (viewModel.lastMark.map { " — \($0)" } ?? ""))
                    .font(.caption2.monospacedDigit())
                    .lineLimit(2)
            }
            if viewModel.isRecording {
                elevationTestControls
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Ground truth is deliberately entered rather than inferred from the scenario label:
    /// a "low curb" varies by site, and its tape-measured height is calibration evidence.
    private var elevationTestControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Elevation test setup")
                .font(.caption.weight(.semibold))
            TextField("Physical setup (e.g. east entrance curb)", text: $viewModel.elevationPhysicalSetup)
            TextField("Surface (concrete, carpet, asphalt…)", text: $viewModel.elevationSurfaceType)
            HStack {
                TextField("Expected height m", text: $viewModel.elevationExpectedHeight)
                    .keyboardType(.decimalPad)
                TextField("Edge distance m", text: $viewModel.elevationExpectedDistance)
                    .keyboardType(.decimalPad)
            }
            Menu(viewModel.elevationExpectedHazard) {
                ForEach(["step / curb", "stairs", "ramp", "drop-off", "missing-depth edge", "obstacle control"], id: \.self) { value in
                    Button(value) { viewModel.elevationExpectedHazard = value }
                }
            }
            HStack {
                Button("Record setup") { viewModel.recordElevationSetup() }
                    .disabled(viewModel.hasActiveElevationSetup)
                Menu("Record outcome") {
                    ForEach(["tester heard warning", "warning missing", "wrong warning", "false warning", "inconclusive"], id: \.self) { outcome in
                        Button(outcome) { viewModel.recordElevationOutcome(outcome) }
                    }
                }
            }
            .buttonStyle(.bordered)
            if let message = viewModel.elevationValidationMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Elevation setup error: \(message)")
            }
        }
        .font(.caption)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(viewModel.floorDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)

            ForEach(Array(viewModel.hazards.enumerated()), id: \.offset) { _, hazard in
                Text(viewModel.hazardLine(hazard))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(hazard.type == .dropOff ? Color.red : Color.orange)
            }

            ForEach(viewModel.approaching) { threat in
                Text(viewModel.approachLine(threat))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(threat.timeToApproach <= 1.5 ? Color.red : Color.orange)
            }

            ForEach(viewModel.crowds) { crowd in
                Text(viewModel.crowdLine(crowd))
                    .font(.subheadline)
                    .foregroundStyle(.teal)
            }

            Text(viewModel.countsDescription)
                .font(.subheadline)

            if let performance = viewModel.performanceDescription {
                Text(performance)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let stages = viewModel.stagesDescription {
                Text(stages)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(viewModel.sessionDescription)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Camera guidance unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            // The usual cause is the Simulator, which has neither ARKit nor a camera.
            Text(message + "\n\nThe Simulator cannot run ARKit. Run on a physical iPhone, or try people detection on a photo instead.")
        } actions: {
            NavigationLink {
                PhotoDetectionView()
            } label: {
                Label("Detect people in a photo", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// One detection's rectangle plus its label.
private struct DetectionBox: View {
    let detection: Detection
    let rect: CGRect

    private var color: Color {
        switch detection.origin {
        case .model: .green
        case .geometric: .orange
        case .mesh: .blue
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(color, lineWidth: 3)
                .frame(width: rect.width, height: rect.height)

            Text(caption)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(color, in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.black)
                .offset(y: -18)
        }
        .offset(x: rect.minX, y: rect.minY)
    }

    private var caption: String {
        guard let distance = detection.distance else {
            return "\(detection.label) \(Int(detection.confidence * 100))%"
        }
        return String(format: "%@ %.1fm", detection.label, distance)
    }
}

/// The one outline users see: a soft rounded box in the status colour, with what it is and
/// how far. It glides to new positions rather than jumping (see `preview`).
private struct FocusOutline: View {
    let caption: String
    let color: Color
    let rect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(color, lineWidth: 4)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .frame(width: rect.width, height: rect.height)

            Text(caption)
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(color, in: Capsule())
                .foregroundStyle(.white)
                .offset(x: 8, y: -16)
        }
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// Renders the app's shared ARKit session, so the preview and the detections come from
/// the same frames.
private struct ARCameraPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
