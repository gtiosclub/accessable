import Testing
@testable import AccessAble

struct PlaceholderAuthServiceTests {
    @Test
    func startsSignedInOrOutAsAsked() async {
        #expect(await PlaceholderAuthService().currentUser() == PlaceholderAuthService.sampleUser)
        #expect(await PlaceholderAuthService(signedIn: false).currentUser() == nil)
    }

    @Test
    func signingInAndOutUpdatesTheUserAndTellsListeners() async throws {
        let auth = PlaceholderAuthService(signedIn: false)
        var changes = auth.userChanges().makeAsyncIterator()
        #expect(await changes.next() == .some(nil))

        let user = try await auth.signIn(email: "a@example.com", password: "password")
        #expect(user == PlaceholderAuthService.sampleUser)
        #expect(await auth.currentUser() == user)
        #expect(await changes.next() == .some(user))

        try await auth.signOut()
        #expect(await auth.currentUser() == nil)
        #expect(await changes.next() == .some(nil))
    }
}
