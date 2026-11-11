import SwiftUI

/// Owner: User Interaction (3.4). Walks through where the main buttons are.
/// Buttons other than the one being explained are dimmed and do nothing; tapping the
/// highlighted one plays a success haptic and moves on.
struct TutorialView: View {
    let onFinish: () -> Void

    @State private var step: TutorialStep = .intro
    @State private var successCount = 0
    @AccessibilityFocusState private var isMessageFocused: Bool

    var body: some View {
        ZStack {
            CameraBackdrop()
            Color.black.opacity(0.35).ignoresSafeArea()
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    CircleIconButton(
                        systemImage: "info",
                        label: "Voice commands",
                        action: { tapped(.info) }
                    )
                    .disabled(step.target != .info)
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 24)

                messageCard
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)

                bottomControls
            }
        }
        .sensoryFeedback(.success, trigger: successCount)
        .onAppear { isMessageFocused = true }
        .onChange(of: step) { isMessageFocused = true }
    }

    private var messageCard: some View {
        VStack(alignment: .trailing, spacing: 16) {
            Text(step.message)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($isMessageFocused)
                .accessibilityLabel("Tutorial step \(step.rawValue + 1) of \(TutorialStep.allCases.count). \(step.message)")

            HStack(spacing: 16) {
                if step == .intro {
                    Button("Skip", action: onFinish)
                        .buttonStyle(.pill(.outline, size: .compact))
                        .accessibilityHint("Skips the tutorial")
                    Button("Start", action: advance)
                        .buttonStyle(.pill(.primary, size: .compact))
                } else {
                    Button("Back", action: goBack)
                        .buttonStyle(.pill(.outline, size: .compact))
                    Button(step == TutorialStep.allCases.last ? "Done" : "Next", action: advance)
                        .buttonStyle(.pill(.primary, size: .compact))
                }
            }
        }
        .padding(20)
        .background(.black, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    @ViewBuilder
    private var bottomControls: some View {
        if step == .searchDestination {
            Button("Search Destination") { tapped(.searchDestination) }
                .buttonStyle(.pill(.primary))
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        } else {
            TripControlPanel(
                isMicMuted: true,
                disabled: disabledControls,
                onCallHelp: { tapped(.callHelp) },
                onMicrophone: { tapped(.microphone) },
                onPauseTrip: { tapped(.pauseTrip) }
            )
        }
    }

    private var disabledControls: Set<TripControl> {
        let all: Set<TripControl> = [.callHelp, .microphone, .pauseTrip]
        switch step.target {
        case .callHelp: return all.subtracting([.callHelp])
        case .microphone: return all.subtracting([.microphone])
        case .pauseTrip: return all.subtracting([.pauseTrip])
        default: return all
        }
    }

    private func tapped(_ target: TutorialTarget) {
        guard target == step.target else { return }
        successCount += 1
        advance()
    }

    private func advance() {
        if let next = TutorialStep(rawValue: step.rawValue + 1) {
            step = next
        } else {
            onFinish()
        }
    }

    private func goBack() {
        if let previous = TutorialStep(rawValue: step.rawValue - 1) {
            step = previous
        }
    }
}

enum TutorialTarget: Hashable {
    case searchDestination
    case info
    case callHelp
    case microphone
    case pauseTrip
}

enum TutorialStep: Int, CaseIterable {
    case intro
    case searchDestination
    case info
    case callHelp
    case microphone
    case pauseTrip

    var target: TutorialTarget? {
        switch self {
        case .intro: nil
        case .searchDestination: .searchDestination
        case .info: .info
        case .callHelp: .callHelp
        case .microphone: .microphone
        case .pauseTrip: .pauseTrip
        }
    }

    var message: String {
        switch self {
        case .intro:
            "Welcome to a quick onboarding tutorial showing you where the buttons are. Clicking on the buttons will not activate them."
        case .searchDestination:
            "This is the landing page. To start a trip, click on \u{201C}Search Destination\u{201D} located at the bottom of the screen, and next to continue right above."
        case .info:
            "During navigation, click on the Info button on the top right corner to view a list of voice commands for quick actions."
        case .callHelp:
            "If needed, click the Call Help button, which allows you to video call a volunteer, located slightly above the bottom of the screen."
        case .microphone:
            "Unmute yourself so the AI agent can respond to your commands and questions. Button next to \u{201C}Call Help\u{201D}."
        case .pauseTrip:
            "The pause trip button can lead you to settings, continue, exit, or call for help."
        }
    }
}

#Preview {
    TutorialView {}
}
