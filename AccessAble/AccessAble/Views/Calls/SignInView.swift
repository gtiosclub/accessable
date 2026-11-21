import SwiftUI

struct SignInView: View {
    @State private var model: SignInViewModel

    init(auth: any AuthService) {
        _model = State(initialValue: SignInViewModel(auth: auth))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $model.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $model.password)
                        .textContentType(model.isCreatingAccount ? .newPassword : .password)
                    if model.isCreatingAccount {
                        SecureField("Confirm password", text: $model.confirmation)
                            .textContentType(.newPassword)
                    }
                } header: {
                    Text("One account for reports and calls")
                }
                if let error = model.errorMessage {
                    Section { Text(error).foregroundStyle(.red).accessibilityLabel("Error: \(error)") }
                }
                Section {
                    Button(model.isCreatingAccount ? "Create account" : "Sign in") {
                        Task { await model.submit() }
                    }
                    .minimumTapTarget()
                    .accessibilityHint("Uses your email and password")
                    Button(model.isCreatingAccount ? "Already have an account? Sign in" : "New here? Sign up") {
                        model.isCreatingAccount.toggle()
                        model.password = ""
                        model.confirmation = ""
                    }
                    .minimumTapTarget()
                    if model.isBusy { ProgressView("Signing in") }
                }
            }
            .disabled(model.isBusy)
            .navigationTitle(model.isCreatingAccount ? "Sign up" : "Sign in")
        }
        .onChange(of: model.errorMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }
}
