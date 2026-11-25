import Testing
@testable import AccessAble

@MainActor
struct SignInViewModelTests {
    @Test
    func missingCredentialsDoNotSignIn() async {
        let auth = PlaceholderAuthService(signedIn: false)
        let model = SignInViewModel(auth: auth)
        await model.submit()
        #expect(model.errorMessage != nil)
        #expect(await auth.currentUser() == nil)
    }

    @Test
    func mismatchedSignupPasswordsDoNotCreateAccount() async {
        let auth = PlaceholderAuthService(signedIn: false)
        let model = SignInViewModel(auth: auth)
        model.isCreatingAccount = true
        model.email = "alex@example.com"
        model.password = "password"
        model.confirmation = "different"
        await model.submit()
        #expect(model.errorMessage != nil)
        #expect(await auth.currentUser() == nil)
    }

    @Test
    func signInUsesSharedAuthAndClearsPassword() async {
        let auth = PlaceholderAuthService(signedIn: false)
        let model = SignInViewModel(auth: auth)
        model.email = "alex@example.com"
        model.password = "password"
        await model.submit()
        #expect(await auth.currentUser() == PlaceholderAuthService.sampleUser)
        #expect(model.password.isEmpty)
        #expect(!model.isBusy)
    }
}
