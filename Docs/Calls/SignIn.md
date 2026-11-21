# VOLUNTEER-2: accounts and roles

Calls and reports reuse REPORT-1's Firebase project and `AuthService`. There is no new Firebase project, paid plan, Apple sign-in, or deployment in this change.

## Flow

RootView observes the shared authentication stream. Signed-out users see email/password sign-in or account creation. An authenticated user without a profile completes onboarding: caller/volunteer role, display name, comma-separated languages, then the existing guidance preferences. Account role and vision preferences are independent. Without the Firebase config file the app skips accounts and uses the original onboarding and home, as before this change. Volunteers skip the caller guidance questions. Callers sign out from Settings.

`FirestoreUserProfileStore` persists `users/{uid}` with `role`, `displayName`, `languages`, and a server-generated `createdAt`. Existing profiles keep their creation timestamp. Each sign-in or app relaunch reloads the profile; callers enter the existing home flow and volunteers enter VolunteerHomeView. A read error offers Retry instead of treating the account as a new user. Both homes support sign-out. Volunteer availability and real calling remain later tasks.

AppServices supplies the store through `UserProfileStore`. Previews use an in-memory profile and shared placeholder auth; the live app requires REPORT-1's Firebase configuration. Firebase Auth handles session persistence. Onboarding guidance preferences retain their existing local storage behavior.

## Mac setup and checks

1. Open `AccessAble/AccessAble.xcodeproj`, resolve packages, and use REPORT-1's existing untracked `GoogleService-Info.plist` configuration. See `Docs/Maps/Reports.md`. Email/password sign-in must be enabled in that existing project.
2. The live project's Firestore rules must match `firebase/firestore.rules`, or loading and saving profiles fails with a permission error. An owner deploys them from `firebase/`: `firebase deploy --only firestore:rules --project <project ID>`. Redeploy whenever this file changes on `maps`.
3. Build the app and run the AccessAbleTests target. Swift tests were added for profile/session behavior and form validation, but could not be run in the Linux workspace.
4. Create a new account, choose Caller, enter a name/languages, finish onboarding, and verify the existing home appears. Sign out.
5. Create another account as Volunteer and verify the volunteer home. Close and relaunch the app: the volunteer role should remain. Sign out and sign back into the caller account to verify account-specific routing.
6. Check the user's document has the four fields above. Check a network/profile-read failure offers Retry rather than onboarding.

## Rules review and tests

Submit `firebase/firestore.rules` to REPORT-1's owner for review with this PR. These rules allow only the authenticated owner to get/create/update/delete their own user document; listing users is denied. Required fields and values are validated, creation uses server time, and updates cannot change `createdAt` or add privilege fields. A public volunteer directory must use a separate collection in its owning task.

From `firebase/`, run `npm ci`, then `npm test`. Node and Java are required by the existing emulator harness. All 51 emulator tests passed, including report regression tests and 22 user-profile tests. The tests use a demo project and do not deploy rules. Rules were deployed to the live project on 2026-11-21.

Keep GoogleService-Info.plist, Secrets.xcconfig, API secrets, and node_modules out of commits. The root Package.swift and LiveKit/Worker setup are unchanged.
