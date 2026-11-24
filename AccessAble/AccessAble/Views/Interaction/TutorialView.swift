import SwiftUI

enum TutorialIcon {
    static let settings = "gearshape"
    static let voiceCommands = "ear"
    static let map = "mappin.and.ellipse"
    static let camera = "camera"
    static let mic = "mic.slash"
}

struct TutorialStyle {
    // Message card
    var cardCornerRadius: CGFloat = 28
    var cardPadding: CGFloat = 24
    var cardHorizontalMargin: CGFloat = 24
    var cardBottomSpacing: CGFloat = 24
    var cardColor: Color = .black
    var messageFont: Font = .title3
    var messageColor: Color = .white
    var messageSpacing: CGFloat = 10
    var buttonSpacing: CGFloat = 16

    // Screen
    var screenEdgeMargin: CGFloat = 24
    var dimOpacity: Double = 0.35
    var mapBackdrop = BackdropAsset.map
    var pictureBackdrop = BackdropAsset.picture

    // The drawn controls being explained
    var controlCornerRadius: CGFloat = 16
    var controlHeight: CGFloat = 56
    var controlFont: Font = .title3.weight(.semibold)
    var circleButtonDiameter: CGFloat = 66
    var bottomCircleDiameter: CGFloat = 56
    var controlDimOpacity: Double = Theme.dimmedOpacity
    var glowColor: Color = .white
    var glowRadius: CGFloat = 10

    // Bottom panel on the trip screens
    var panelColor: Color = .black
    var panelCornerRadius: CGFloat = 36
    var panelHorizontalPadding: CGFloat = 24
    var panelSpacing: CGFloat = 16

    /// Tapping the lit control advances with a tick. Set false to make controls inert.
    var tapAdvances = true

    static let standard = TutorialStyle()
}

enum TutorialTarget: Hashable {
    case settings
    case searchDestination
    case landingMic
    case startRecordRoute
    case info
    case mapButton
    case callHelp
    case microphone
    case exitTrip
}

/// Which mock screen is drawn behind the message card.
enum TutorialLayout {
    case landing
    case routeOptions
    case trip
}

enum TutorialCardPosition {
    case center
    case bottom
}

/// One tutorial screen: its message, mock screen, lit control, and buttons.
struct TutorialPage: Identifiable {
    enum Leading { case back, skip, none }

    let id: String
    let message: String
    var layout: TutorialLayout = .trip
    var cardPosition: TutorialCardPosition = .bottom
    var target: TutorialTarget? = nil
    var leading: Leading = .back
    var primaryTitle = "Next"
    var backdrop: String? = nil
    var leadingIcon: String? = nil
}

enum TutorialContent {
    // Button labels on the drawn controls
    static let searchTitle = "Search Destination"
    static let callHelpTitle = "Call Help"
    static let exitTripTitle = "Exit Trip"

    static let pages: [TutorialPage] = [
        .init(id: "intro",
              message: "Welcome to a quick onboarding tutorial showing you where the buttons are. Clicking on the buttons will not activate them.",
              layout: .landing, cardPosition: .center, leading: .skip, primaryTitle: "Start"),
        .init(id: "settings",
              message: "To adjust settings and preferences, click on the Settings button on the top left corner. Settings are originally defaulted.",
              layout: .landing, target: .settings, leading: .none, primaryTitle: "Okay"),
        .init(id: "search",
              message: "This is the landing page. To start a trip, click on “Search Destination” located at the bottom of the screen, and next to continue right above.",
              layout: .landing, target: .searchDestination),
        .init(id: "landingMic",
              message: "To tell the AI assistant your commands, unmute yourself with this button.",
              layout: .landing, target: .landingMic),
        .init(id: "startRoute",
              message: "This is the navigation page. To record a new trip, click on “Start & Record New Route” located on the center of the screen, then tap on “Next” to continue.",
              layout: .routeOptions, target: .startRecordRoute),
        .init(id: "info",
              message: "During navigation, click on the “Info button” on the top right corner to view a list of voice commands for quick actions.",
              target: .info),
        .init(id: "map",
              message: "To see your location in a map view, click on the “Map” button, located at the top left corner of the screen.",
              target: .mapButton),
        .init(id: "callHelp",
              message: "If needed, click the “Call Help”, which allows you to video call a volunteer, located near the bottom of the screen.",
              target: .callHelp),
        // From here the top-left icon is the camera (Figma changes it after the map step).
        .init(id: "mic",
              message: "Unmute yourself so the AI agent can respond to your commands and questions. The “Mute” button is next to the “Call Help” button.",
              target: .microphone, leadingIcon: TutorialIcon.camera),
        .init(id: "exit",
              message: "The “Exit Trip” button can lead you to settings, continue, exit, or call for help.",
              target: .exitTrip, leadingIcon: TutorialIcon.camera),
    ]

    /// Buttons on the route-options mock screen, top to bottom.
    /// The first is the one the tutorial lights up.
    static let routeOptions = [
        "Start & Record New Route",
        "Start Recorded Route",
        "Start New Route",
        "Back",
    ]
}

/// A drawn control: dim until it is the one being explained, then full color with a glow.
struct TutorialControlStyle: ButtonStyle {
    var fill: Color
    var foreground: Color
    var stroke: Color?
    var cornerRadius: CGFloat
    var dimOpacity: Double
    var glowColor: Color
    var glowRadius: CGFloat
    /// Light text dims with its button; dark text on a cyan button stays solid, as in Figma.
    var dimsForeground: Bool

    func makeBody(configuration: Configuration) -> some View {
        ControlBody(configuration: configuration, style: self)
    }

    private struct ControlBody: View {
        let configuration: ButtonStyleConfiguration
        let style: TutorialControlStyle
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            configuration.label
                .foregroundStyle(style.foreground.opacity(isEnabled || !style.dimsForeground ? 1 : style.dimOpacity))
                .background(style.fill.opacity(isEnabled ? 1 : style.dimOpacity), in: shape)
                .overlay {
                    if let stroke = style.stroke {
                        shape.strokeBorder(stroke.opacity(isEnabled ? 1 : style.dimOpacity), lineWidth: 2)
                    }
                }
                .shadow(color: isEnabled ? style.glowColor : .clear, radius: style.glowRadius)
                .opacity(configuration.isPressed ? 0.75 : 1)
        }
    }
}

/// Owner: User Interaction (3.4).
struct TutorialView: View {
    let onFinish: () -> Void
    var pages: [TutorialPage] = TutorialContent.pages
    var style: TutorialStyle = .standard

    @State private var index = 0
    @AccessibilityFocusState private var isMessageFocused: Bool

    private var page: TutorialPage { pages[index] }

    private var backdropName: String {
        page.backdrop ?? (page.layout == .trip ? style.pictureBackdrop : style.mapBackdrop)
    }

    private func isLit(_ target: TutorialTarget) -> Bool {
        page.target == target
    }

    var body: some View {
        ZStack {
            CameraBackdrop()
            BackdropImage(name: backdropName)
            Color.black.opacity(style.dimOpacity).ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, style.screenEdgeMargin)

                Spacer(minLength: 24)

                if page.cardPosition == .bottom {
                    messageCard
                        .padding(.horizontal, style.cardHorizontalMargin)
                        .padding(.bottom, style.cardBottomSpacing)
                }

                bottomControls
            }
            .overlay {
                if page.cardPosition == .center {
                    messageCard
                        .padding(.horizontal, style.cardHorizontalMargin)
                }
            }
        }
        .onAppear { isMessageFocused = true }
        .onChange(of: index) { isMessageFocused = true }
    }

    private var messageCard: some View {
        VStack(alignment: .trailing, spacing: style.messageSpacing) {
            Text(page.message)
                .font(style.messageFont)
                .foregroundStyle(style.messageColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($isMessageFocused)
                .accessibilityLabel("Tutorial step \(index + 1) of \(pages.count). \(page.message)")

            HStack(spacing: style.buttonSpacing) {
                leadingButton
                Button(page.primaryTitle) { advance(haptic: index == 0 ? .success : .light) }
                    .buttonStyle(.pill(.primary, size: .compact))
            }
        }
        .padding(style.cardPadding)
        .background(style.cardColor, in: RoundedRectangle(cornerRadius: style.cardCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var leadingButton: some View {
        switch page.leading {
        case .back:
            Button("Back", action: goBack)
                .buttonStyle(.pill(.outline, size: .compact))
        case .skip:
            Button("Skip", action: skip)
                .buttonStyle(.pill(.outline, size: .compact))
                .accessibilityHint("Skips the tutorial")
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var topBar: some View {
        switch page.layout {
        case .landing:
            HStack {
                circleControl(TutorialIcon.settings, label: "Settings", target: .settings)
                Spacer()
                circleControl(TutorialIcon.voiceCommands, label: "Voice commands", target: .info)
            }
        case .trip:
            let icon = page.leadingIcon ?? TutorialIcon.map
            HStack {
                circleControl(icon,
                              label: icon == TutorialIcon.camera ? "Camera view" : "Map view",
                              target: .mapButton)
                Spacer()
                circleControl(TutorialIcon.voiceCommands, label: "Voice commands", target: .info)
            }
        case .routeOptions:
            EmptyView()
        }
    }

    @ViewBuilder
    private var bottomControls: some View {
        switch page.layout {
        case .landing:
            HStack(spacing: 14) {
                rectControl(TutorialContent.searchTitle, target: .searchDestination,
                            fill: Theme.cyan, foreground: .black)
                micControl(target: .landingMic)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

        case .routeOptions:
            BottomCard {
                ForEach(Array(TutorialContent.routeOptions.enumerated()), id: \.offset) { i, title in
                    routeOptionControl(index: i, title: title)
                }
            }

        case .trip:
            VStack(spacing: style.panelSpacing) {
                HStack(spacing: 14) {
                    rectControl(TutorialContent.callHelpTitle, target: .callHelp,
                                fill: Theme.cyan, foreground: .black)
                    micControl(target: .microphone)
                }
                rectControl(TutorialContent.exitTripTitle, target: .exitTrip,
                            fill: Theme.red, foreground: .white, dimsForeground: true)
            }
            .padding(.horizontal, style.panelHorizontalPadding)
            .padding(.top, 24)
            .padding(.bottom, 12)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: style.panelCornerRadius,
                    topTrailingRadius: style.panelCornerRadius,
                    style: .continuous
                )
                .fill(style.panelColor)
                .ignoresSafeArea(edges: .bottom)
            )
        }
    }

    private func controlStyle(
        fill: Color,
        foreground: Color,
        radius: CGFloat,
        stroke: Color? = nil,
        dimsForeground: Bool = false
    ) -> TutorialControlStyle {
        TutorialControlStyle(
            fill: fill,
            foreground: foreground,
            stroke: stroke,
            cornerRadius: radius,
            dimOpacity: style.controlDimOpacity,
            glowColor: style.glowColor,
            glowRadius: style.glowRadius,
            dimsForeground: dimsForeground
        )
    }

    /// Round icon button.
    private func circleControl(
        _ icon: String,
        label: String,
        target: TutorialTarget,
        diameter: CGFloat? = nil,
        fill: Color = Theme.cyan,
        foreground: Color = .black,
        dimsForeground: Bool = false
    ) -> some View {
        let size = diameter ?? style.circleButtonDiameter
        return Button { tapped(target) } label: {
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .medium))
                .frame(width: size, height: size)
        }
        .buttonStyle(controlStyle(fill: fill, foreground: foreground, radius: size / 2,
                                  dimsForeground: dimsForeground))
        .disabled(!isLit(target))
        .accessibilityLabel(label)
    }

    /// The red microphone button beside Search Destination / Call Help.
    private func micControl(target: TutorialTarget) -> some View {
        circleControl(TutorialIcon.mic, label: "Unmute microphone", target: target,
                      diameter: style.bottomCircleDiameter,
                      fill: Theme.red, foreground: .white, dimsForeground: true)
    }

    /// Rectangular button.
    private func rectControl(
        _ title: String,
        target: TutorialTarget,
        lit: Bool? = nil,
        fill: Color,
        foreground: Color,
        stroke: Color? = nil,
        dimsForeground: Bool = false
    ) -> some View {
        Button { tapped(target) } label: {
            Text(title)
                .font(style.controlFont)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: style.controlHeight)
        }
        .buttonStyle(controlStyle(fill: fill, foreground: foreground, radius: style.controlCornerRadius,
                                  stroke: stroke, dimsForeground: dimsForeground))
        .disabled(!(lit ?? isLit(target)))
    }

    @ViewBuilder
    private func routeOptionControl(index i: Int, title: String) -> some View {
        let isFirst = i == 0
        let isLast = i == TutorialContent.routeOptions.count - 1
        rectControl(
            title,
            target: .startRecordRoute,
            lit: isFirst && isLit(.startRecordRoute),
            fill: isFirst ? Theme.red : (isLast ? Color.clear : Theme.cyan),
            foreground: isFirst ? .white : (isLast ? Theme.textOffWhite : .black),
            stroke: isLast ? Theme.cyan : nil,
            dimsForeground: isFirst || isLast
        )
    }

    private func tapped(_ target: TutorialTarget) {
        guard style.tapAdvances, target == page.target else { return }
        advance(haptic: .selection)
    }

    /// Plays `haptic` for the tap and moves on. After the last page, the tutorial is complete:
    /// a success follows the tap's haptic, a moment later so the two can be told apart.
    private func advance(haptic: InteractionHaptic) {
        Haptics.play(haptic)
        if index + 1 < pages.count {
            index += 1
        } else {
            onFinish()
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                Haptics.play(.success)
            }
        }
    }

    private func skip() {
        Haptics.play(.selection)
        onFinish()
    }

    private func goBack() {
        guard index > 0 else { return }
        Haptics.play(.light)
        index -= 1
    }
}

#Preview {
    TutorialView {}
}
