import SwiftUI

/// Signed-in profile setup: account role → details → guidance → VoiceOver → tutorial.
struct OnboardingView: View {
    @Environment(AppViewModel.self) private var app
    @State private var viewModel: OnboardingViewModel
    let onSave: ((UserRole, String, [String]) async throws -> Void)?
    let onSignOut: (() async throws -> Void)?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(includesAccount: Bool = true,
         onSave: ((UserRole, String, [String]) async throws -> Void)? = nil,
         onSignOut: (() async throws -> Void)? = nil) {
        _viewModel = State(initialValue: OnboardingViewModel(includesAccount: includesAccount))
        self.onSave = onSave
        self.onSignOut = onSignOut
    }

    var body: some View {
        Group {
            switch viewModel.step {
            case .accountRole:
                VStack(spacing: 24) {
                    Text("How will you use AccessAble?").font(.title.bold())
                    Button("Caller — get assistance") { viewModel.chooseAccountRole(.caller) }
                        .buttonStyle(.pill(.primary))
                        .accessibilityHint("Choose to request assistance from volunteers")
                    Button("Volunteer — offer assistance") { viewModel.chooseAccountRole(.volunteer) }
                        .buttonStyle(.pill(.primary))
                    if let onSignOut {
                        Button("Sign out") {
                            Task {
                                do { try await onSignOut() }
                                catch { errorMessage = "Couldn't sign out. Please try again." }
                            }
                        }.frame(minHeight: 44)
                    }
                }.padding(24)
            case .accountDetails:
                accountDetails
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
        .disabled(isSaving)
        .overlay { if isSaving { ProgressView("Saving your profile").padding().background(.regularMaterial) } }
        .alert("Account setup", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .animation(.easeInOut(duration: 0.25), value: viewModel.step)
    }

    private var accountDetails: some View {
        @Bindable var model = viewModel
        return NavigationStack {
            Form {
                Text("Account role: \(model.accountRole.title)")
                TextField("Display name", text: $model.displayName).textContentType(.name)
                TextField("Languages, separated by commas", text: $model.languageText)
                    .accessibilityHint("For example, English, Korean")
                Button("Continue") {
                    if model.accountRole == .volunteer { finish() } else { model.finishAccountDetails() }
                }
                    .disabled(!model.canContinueDetails).frame(minHeight: 44)
                if !model.canContinueDetails {
                    Text("Enter your name and at least one language to continue.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Change account role") { model.returnToAccountRole() }
                    .frame(minHeight: 44)
            }.navigationTitle("Your profile")
        }
    }

    private func finish() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                if let onSave {
                    try await onSave(viewModel.accountRole,
                        viewModel.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                        viewModel.languages)
                }
                if viewModel.accountRole == .caller {
                    app.preferences.usesSystemScreenReader = viewModel.usesVoiceOver
                    app.completeOnboarding(with: viewModel.profile)
                }
            } catch {
                errorMessage = (error as? UserProfileError)?.localizedDescription
                    ?? "Couldn't save your profile. Check your connection and try again."
            }
        }
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
                Text("Choose your guidance preferences")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                VStack(spacing: 20) {
                    Button("Sighted / standard guidance") { onChoose(.sighted) }
                        .buttonStyle(.pill(.primary))
                        .accessibilityLabel("Sighted guidance preferences")
                    Button("Blind / low vision guidance") { onChoose(.blind) }
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
