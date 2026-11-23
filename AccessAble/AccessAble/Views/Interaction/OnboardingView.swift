import SwiftUI

struct OnboardingView: View {
    @Environment(AppViewModel.self) private var app
    @State private var viewModel = OnboardingViewModel()

    var body: some View {
        Group {
            switch viewModel.step {
            case .role:
                RoleQuestionView { viewModel.chooseRole($0) }
            case .voiceOver:
                VoiceOverQuestionView { answer in
                    viewModel.answerVoiceOver(answer)
                    app.profile = viewModel.profile
                    app.preferences.usesSystemScreenReader = answer
                }
            case .account:
                AccountCreationView(
                    error: viewModel.accountError,
                    isLoading: viewModel.isCreatingAccount
                ) { username, password in
                    Task { await viewModel.createAccount(username: username, password: password) }
                }
            case .settings:
                NavigationStack {
                    SettingsView(app: app) { viewModel.finishSettings() }
                }
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
        app.hasCompletedOnboarding = true
    }
}

/// "Welcome to AccessAble" title block shared by the first questions.
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

/// Look and wording of the account screen. Edit values here to match Figma.
struct AccountFormStyle {
    var title = "Create an account"
    var usernameLabel = "Username"
    var usernamePlaceholder = "Create username"
    var passwordLabel = "Password"
    var passwordPlaceholder = "At least 6 characters"
    var buttonTitle = "Create Account"
    var fieldColor = Color(white: 0.22)
    var fieldCornerRadius: CGFloat = 16
    var fieldHeight: CGFloat = 49
    var fieldHorizontalPadding: CGFloat = 16
    var spacing: CGFloat = 16

    static let standard = AccountFormStyle()
}

struct AccountCreationView: View {
    let error: String?
    let isLoading: Bool
    var style: AccountFormStyle = .standard
    let onCreate: (String, String) -> Void

    @State private var username = ""
    @State private var password = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: style.spacing) {
                WelcomeTitle()
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)

                Text(style.title)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)

                field(style.usernameLabel) {
                    TextField(style.usernamePlaceholder, text: $username)
                        .font(.title3)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                field(style.passwordLabel) {
                    SecureField(style.passwordPlaceholder, text: $password)
                        .font(.title3)
                }

                if let error {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(Theme.red)
                        .accessibilityLabel("Error: \(error)")
                }

                Button(style.buttonTitle) { onCreate(username, password) }
                    .buttonStyle(.pill(.primary))
                    .disabled(isLoading)
                    .overlay { if isLoading { ProgressView().tint(.black) } }
                    .padding(.top, 8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .background(Color.black.ignoresSafeArea())
        .onChange(of: error) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    private func field<Field: View>(_ label: String, @ViewBuilder content: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.semibold))
            content()
                .padding(.horizontal, style.fieldHorizontalPadding)
                .frame(minHeight: style.fieldHeight)
                .background(style.fieldColor, in: RoundedRectangle(cornerRadius: style.fieldCornerRadius, style: .continuous))
        }
    }
}

struct OnboardingCompleteView: View {
    let onContinue: () -> Void
    let onRepeatTutorial: () -> Void

    private let accent = Color(red: 0.76, green: 0.97, blue: 0.96) // light cyan

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                AppLogo(size: 170)
                    .padding(.bottom, 16)

                Text("Onboarding Successful")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                Text("You're all set and ready to get started with your experience")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)

                VStack(spacing: 24) {
                    Button("Continue", action: onContinue)
                        .buttonStyle(OnboardingButtonStyle(
                            fill: accent,
                            foreground: .black,
                            border: nil
                        ))
                    Button("Repeat Tutorial", action: onRepeatTutorial)
                        .buttonStyle(OnboardingButtonStyle(
                            fill: .black,
                            foreground: accent,
                            border: accent
                        ))
                }
                .padding(.top, 38)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .background(Color.black.ignoresSafeArea())
    }
}

private struct OnboardingButtonStyle: ButtonStyle {
    let fill: Color
    let foreground: Color
    let border: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.bold())
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(fill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                if let border {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(border, lineWidth: 2)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

#Preview("Onboarding") {
    OnboardingView()
        .environment(AppViewModel(defaults: UserDefaults(suiteName: "preview-onboarding") ?? .standard, services: .preview))
        .preferredColorScheme(.dark)
}

#Preview("Account") {
    AccountCreationView(error: nil, isLoading: false) { _, _ in }
        .preferredColorScheme(.dark)
}

#Preview("Complete") {
    OnboardingCompleteView(onContinue: {}, onRepeatTutorial: {})
}
