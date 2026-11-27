import SwiftUI

/// "Welcome to AccessAble": email and password, to sign in or create an account.
struct SignInView: View {
    @State private var model: SignInViewModel

    init(auth: any AuthService) {
        _model = State(initialValue: SignInViewModel(auth: auth))
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to").font(.subheadline)
                    Text("AccessAble").font(.title.bold())
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 12)

                field("Email") {
                    TextField("Email", text: $model.email, prompt: prompt("Enter email"))
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                field("Password") {
                    SecureField("Password", text: $model.password, prompt: prompt("Enter password"))
                        .textContentType(model.isCreatingAccount ? .newPassword : .password)
                }
                if model.isCreatingAccount {
                    field("Confirm password") {
                        SecureField("Confirm password", text: $model.confirmation, prompt: prompt("Enter password again"))
                            .textContentType(.newPassword)
                    }
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.5))
                        .accessibilityLabel("Error: \(error)")
                }
                Button(model.isCreatingAccount ? "Create account" : "Log In") {
                    Task { await model.submit() }
                }
                .buttonStyle(.pill(.primary))
                .accessibilityHint("Uses your email and password")
                .padding(.top, 8)
                Button(model.isCreatingAccount ? "Already have an account? Log in" : "New here? Sign up") {
                    model.isCreatingAccount.toggle()
                    model.password = ""
                    model.confirmation = ""
                }
                .foregroundStyle(Theme.cyan)
                .frame(maxWidth: .infinity)
                .minimumTapTarget()
                if model.isBusy { ProgressView("Signing in").tint(.white).frame(maxWidth: .infinity) }
            }
            .padding(.horizontal, 24)
            .padding(.top, 120)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .disabled(model.isBusy)
        .onChange(of: model.errorMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }

    private func field<Field: View>(_ label: String, @ViewBuilder content: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.footnote.bold()).accessibilityHidden(true)
            content()
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func prompt(_ text: String) -> Text {
        Text(text).foregroundStyle(.white.opacity(0.7))
    }
}

#Preview {
    SignInView(auth: PlaceholderAuthService(signedIn: false))
        .preferredColorScheme(.dark)
}
