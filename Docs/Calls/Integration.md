# Real call integration and release checks

This update builds on volunteer8. The code and automated backend checks are prepared; deployment and two-phone acceptance are not complete.

## Live versus preview

`AppServices.live` explicitly supplies FirestoreVolunteerDirectory, FirestorePresenceService, FirestoreIncomingCalls and FirestoreCallSignaling when the existing Firebase app is configured, and always supplies the real LiveKitVideoCallSession. Missing Firebase uses `UnavailableCallServices` (empty directory, offline presence, explicit errors, no tickets). Missing/invalid CALL_TOKEN_URL fails before a caller reserves a volunteer or a volunteer accepts. Missing/invalid LIVEKIT_URL fails in the real media service. Neither condition silently substitutes simulated success.

`AppServices.preview` is now constructed directly from placeholders. It does not call live(), initialize Firebase presence/auth listeners, create a LiveKit service, or initialize real speech/GPS as a side effect. Placeholder call services remain available for unit tests and the existing incoming-call preview. Existing no-account Maps behavior remains available without Firebase.

Production connection URLs must be HTTPS for the Worker and WSS for LiveKit. The app's existing untracked config supplies them. The development token server and LiveKitMediaTest scheme are not used for full calls.

## Reusing the session

- Caller retry waits for the previous attempt, and failed/cancelled joins disconnect and attempt to end their accepted reservation. Terminal UI is exposed after cleanup, so Retry cannot overwrite an old ticket during cleanup.
- Hang-up cancels and waits for the pending placement before releasing the shared session. Cancellation is checked after a ticket arrives and after media connection.
- The real media service rejects overlapping joins and tickets for another signed-in account. Disconnect invalidates an in-flight join; a late Room connection is disconnected before it can publish media.
- Media monitoring stops/resets on cleanup. If the other participant never joins within 30 seconds, the session ends rather than stranding a volunteer indefinitely. The existing caller/volunteer view models then attempt the matching cleanup.
- No test here proves camera, audio, campus firewall traversal, cellular connectivity, or iPhone installation. Those still require devices.

## Rule hardening

- Calls remain get-only for their caller/volunteer; other callers and collection listing are denied.
- A call can enter ringing only as a new document with a fresh paired volunteer reservation, stamped with request.time in the same atomic write.
- A pre-seeded pointer cannot authorize a later standalone call creation. A stale ringing call cannot refresh its reservation instead of creating a new call.
- Volunteer creation cannot contain a ring or active call. Own profile/availability updates cannot forge/replace ring fields; clearing them requires the matching answered/declined/ended call state. Setting inCall true needs the answer transition.
- Existing acceptance, decline, skip, hang-up, 45-second stale-ring recovery and caller-first-name projection remain covered by the emulator suite. User/report privacy rules are unchanged.

Firestore rules cannot identify which Swift method was called or distinguish a transaction from a write batch with identical atomic effects. They enforce the matching operation's before/after invariants with get()/getAfter(). They do not trust a client-provided "transaction" flag.

## Validation completed in this workspace

- Firebase emulator: **99 tests passed** (existing tests plus 9 integration/security cases). Includes five ring → accept → end → free cycles on the same volunteer without resetting database state, alternating which side hangs up. This is backend state testing, not five physical calls.
- Worker: **7 tests passed**, with real RSA Firebase-token and HMAC LiveKit-token signing/verification using test keys. All external requests are mocked. Includes five distinct room-token requests, participant isolation, forged/wrong-project/expired tokens, ringing/ended refusal and missing configuration.
- `npx --yes wrangler@4 deploy --dry-run`: successfully bundles the Worker with Wrangler 4.168.0; no deployment.
- Changed Swift files parsed for syntax. Added four wiring/configuration tests and two caller lifecycle tests, including five cycles through one caller model/session. Xcode/Swift tests were not run; no Apple SDK is installed here.
- Actual rules deploy attempted for accessable-2f8fc: **failed authentication** (firebase login required).
- Actual Worker deploy attempted: **failed authentication** (no Cloudflare credentials in this noninteractive workspace). No temporary account was created and neither deployment completed.

## Deploy from an authenticated Mac terminal

Use the existing free Firebase Spark project and existing Cloudflare Workers Free account. These commands deploy rules and the Worker only; no Functions, billing upgrade, paid Apple membership, or new project is needed. Check the project/account shown before deploying. The repo currently targets Firebase **accessable-2f8fc** and Worker **getcalltoken**; the Cloudflare account is selected from your login, not hard-coded here. If multiple accounts are listed, set CLOUDFLARE_ACCOUNT_ID to the intended existing account ID.

From the clone root, deploy reviewed rules:

```bash
cd firebase
npm ci
npm test
npx --yes firebase-tools@15 login
npx --yes firebase-tools@15 deploy --only firestore:rules --project accessable-2f8fc
```

Then deploy the authenticated token Worker:

```bash
cd ../Workers/getCallToken
npm test
npx --yes wrangler@4 login
npx --yes wrangler@4 whoami
npx --yes wrangler@4 secret list
```

The list should contain LIVEKIT_API_KEY and LIVEKIT_API_SECRET. Reuse them if present. If either is missing, use the corresponding command below and paste the value into its private terminal prompt, never into a committed file or chat:

```bash
npx --yes wrangler@4 secret put LIVEKIT_API_KEY
npx --yes wrangler@4 secret put LIVEKIT_API_SECRET
```

The config declares both names as required, so deployment fails if they are missing. Deploy:

```bash
npx --yes wrangler@4 deploy
```

Keep the URL printed by Wrangler. If workers.dev needs registration, register the existing account's subdomain in Cloudflare and retry. Do not use --temporary, create a replacement project, or upgrade a plan to bypass authentication. Check successful CLI output and the published rules/Worker version in their dashboards; a local dry run is not a deploy.

Set CALL_TOKEN_URL in the app's untracked AccessAble/Config/Secrets.xcconfig to that HTTPS URL, using the existing https:/$()/ xcconfig form. LIVEKIT_URL must be the WSS URL of the project whose API secrets are in the Worker. The Firebase plist PROJECT_ID must match accessable-2f8fc. Do not overwrite a teammate's local signing team or commit Secrets.xcconfig, GoogleService-Info.plist or any API secret.

A POST to the configured Worker without a Firebase bearer token should return **401**, not a media token; a GET returns **405**. A 500 configuration response means required bindings are missing. App requests supply their own Firebase ID token automatically. Turn off LiveKit's development token server after the old media experiment is no longer needed.

## Two-phone acceptance procedure

Use the normal **AccessAble** scheme, not LiveKitMediaTest. Build/install the same code on two physical iPhones. Sign in as a caller and a volunteer in the shared Firebase project. Keep the volunteer Online, unlocked and on screen. Use headphones/separate rooms.

For every row below: caller requests help → volunteer rings with the first name → Accept → verify rear video and audio in BOTH directions → hang up → confirm both return to a usable state and volunteers/{uid} has inCall false and no ringingCallId. Alternate caller and volunteer hang-up. Do not restart either app between rows. A new call must have a new call ID/room; do not capture tokens in logs/screenshots.

1. Connect both phones to campus Wi-Fi. Complete five consecutive calls.
2. Between calls, disable Wi-Fi on both phones and confirm cellular data is in use. Keep the same app processes open and complete another five calls.
3. Exercise a decline, a 30-second unanswered ring, an accept/skip race, a failed connection and a cancelled request. Each must recover and allow another call.
4. Confirm microphone/camera indicators stop after hang-up, VoiceOver controls work, and camera guidance resumes when a caller still has an active AR client.

| Network | Call | Request/ring | Video + two-way audio | Hang-up/free | Result |
|---|---:|---|---|---|---|
| Campus Wi-Fi | 1 | Not run | Not run | Not run | Pending |
| Campus Wi-Fi | 2 | Not run | Not run | Not run | Pending |
| Campus Wi-Fi | 3 | Not run | Not run | Not run | Pending |
| Campus Wi-Fi | 4 | Not run | Not run | Not run | Pending |
| Campus Wi-Fi | 5 | Not run | Not run | Not run | Pending |
| Cellular | 1 | Not run | Not run | Not run | Pending |
| Cellular | 2 | Not run | Not run | Not run | Pending |
| Cellular | 3 | Not run | Not run | Not run | Pending |
| Cellular | 4 | Not run | Not run | Not run | Pending |
| Cellular | 5 | Not run | Not run | Not run | Pending |

Record device/iOS versions, date, deployed rules/Worker version, call IDs and observed failure messages in the PR. On campus Wi-Fi, record connection errors if media cannot establish; do not loosen authentication/rules or disable TLS to work around a network block. This objective is complete only after deployments and actual device rows pass; the emulator/Worker tests alone do not satisfy it.

References: https://firebase.google.com/docs/firestore/security/rules-conditions , https://firebase.google.com/docs/rules/manage-deploy , https://developers.cloudflare.com/workers/wrangler/configuration/ , https://developers.cloudflare.com/workers/configuration/secrets/
