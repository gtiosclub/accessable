import SwiftUI

/// Owner: User Interaction (3.4). First-launch flow: role → VoiceOver → tutorial → done.
struct OnboardingView: View {
    @Environment(AppViewModel.self) private var app
    @State private var viewModel = OnboardingViewModel()

    var body: some View {
        Group {
            switch viewModel.step {
            case .role:
                RoleQuestionView { viewModel.chooseRole($0) }
            case .voiceOver:
                VoiceOverQuestionView { viewModel.answerVoiceOver($0) }
            case .tutorial:
                TutorialView { viewModel.finishTutorial() }
            case .complete:
                OnboardingCompleteView(
                    onContinue: finish,
                    onRepeatTutorial: { viewModel.repeatTutorial() }
                )
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.step)
    }

    private func finish() {
        app.preferences.usesSystemScreenReader = viewModel.usesVoiceOver
        app.completeOnboarding(with: viewModel.profile)
    }
}

/// "Welcome to AccessAble" title block shared by the first two questions.
private struct WelcomeTitle: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Welcome to")
                .font(.title.bold())
            Text("AccessAble")
                .font(.system(size: 56, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct RoleQuestionView: View {
    let onChoose: (VisionLevel) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                WelcomeTitle()
                AppLogo(size: 180)
                Text("Are you a")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                VStack(spacing: 20) {
                    Button("Sighted Volunteer") { onChoose(.sighted) }
                        .buttonStyle(.pill(.primary))
                        .accessibilityLabel("I am a sighted volunteer")
                    Button("Blind/Low Vision User") { onChoose(.blind) }
                        .buttonStyle(.pill(.primary))
                        .accessibilityLabel("I am blind or have low vision")
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .background(Color.black.ignoresSafeArea())
    }
}

struct VoiceOverQuestionView: View {
    let onAnswer: (Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                WelcomeTitle()
                Text("Do you use VoiceOver?")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                VStack(spacing: 20) {
                    Button("Yes") { onAnswer(true) }
                        .buttonStyle(.pill(.primary))
                        .accessibilityLabel("Yes, I use VoiceOver")
                    Button("No") { onAnswer(false) }
                        .buttonStyle(.pill(.destructive))
                        .accessibilityLabel("No, I don't use VoiceOver")
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .background(Color.black.ignoresSafeArea())
    }
}

struct OnboardingCompleteView: View {
    let onContinue: () -> Void
    let onRepeatTutorial: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                AppLogo(size: 170)
                    .padding(.bottom, 8)
                Text("Onboarding Successful")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("You're all set and ready to get started with your experience")
                    .font(.body)
                    .multilineTextAlignment(.center)
                VStack(spacing: 24) {
                    Button("Continue", action: onContinue)
                        .buttonStyle(.pill(.primary))
                    Button("Repeat Tutorial", action: onRepeatTutorial)
                        .buttonStyle(.pill(.outline))
                }
                .padding(.top, 24)
                Text(OnboardingViewModel.safetyDisclosure)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .background(Theme.navy.ignoresSafeArea())
    }
}

#Preview("Onboarding") {
    OnboardingView()
        .environment(AppViewModel(defaults: UserDefaults(suiteName: "preview-onboarding") ?? .standard, services: .preview))
        .preferredColorScheme(.dark)
}

#Preview("Complete") {
    OnboardingCompleteView(onContinue: {}, onRepeatTutorial: {})
}
