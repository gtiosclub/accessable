# Volunteer settings and call safety (VOLUNTEER-10)

## Settings

Volunteer home now edits display name, comma-separated languages, Online by default and Keep screen awake while Online. Preferences are stored in `volunteerSettings/{uid}`; missing preferences default to both switches on. Name/languages use the existing shared `users/{uid}` profile and preserve its creation date. Public directory refresh preserves ringing and in-call state.

Saved Online preference is distinct from actual presence: only an approved volunteer in the foreground is Online. Backgrounding, locking, signing out or leaving volunteer home releases this feature's screen-awake request. Returning to the foreground reapplies the saved preference. A shared screen-awake coordinator counts overlapping call-screen requests, so an old screen disappearing cannot turn the timer back on underneath a new one. It restores the pre-existing idle-timer setting after the last request, preserving an existing Maps request. Presence writes are serialized; an Offline/background/sign-out cleanup cannot be overtaken by an earlier Online request still waiting for Firestore. Availability still depends on the existing heartbeat/lastSeen rules.

## Club invitations and consent

In the existing Firebase project's Firestore console, a trusted club administrator creates `volunteerInvites/{AUTH_UID}` with only `enabled: true` (Boolean). Verify the person's club membership and exact Firebase Authentication UID first. This collection is an eligibility directory, not a place for email addresses or private invitation notes. Signed-in clients can get an eligibility document; they cannot list or write invitations. Choosing the volunteer role does not approve an account. Pending volunteers see an invitation notice and cannot go Online. Set enabled false to revoke approval; subsequent online writes, heartbeats, matches, accepts and new token requests fail closed.

Call consent is recorded as `callConsents/{uid}` with version 1 and a server acceptedAt timestamp. The existing consent screen must save this record before matching. A device-local consent flag is no longer sufficient; existing callers will consent once again. The matching service and rules enforce this independently of the UI.

## Reports and blocks

After an accepted call, callers can Report or Block from the call result screen. Volunteers can Report from the home screen's last-call card. These controls use a dedicated view model, await the server before showing success and offer retry on failure. Buttons are disabled during a write, and a successful report or block cannot be submitted again from that result screen. Reopening the report sheet retains a successful result instead of creating another report. A network timeout can still leave the outcome of a report unknown; a retry may create a second moderation record. Blocking itself is idempotent through a transaction. Missed/declined rings do not create safety actions.

Reports go to `callSafetyReports/{autoID}`: callId, reporterId, subjectId, enumerated reason, optional details (at most 2,000 characters), server createdAt. Rules require an accepted/ended call and the actual other participant. Clients cannot read, change or delete reports. Trusted administrators review them in the Firebase console; no moderator dashboard or automated response is included. No media or LiveKit credentials are stored in a report.

Blocks go to `users/{callerUID}/blockedVolunteers/{volunteerUID}` with callId and server createdAt. Creation requires that caller's accepted/ended call with that volunteer. Blocks are durable and immutable from clients; there is no Unblock UI. The caller can list their blocks. The affected volunteer can get only their own block verdict (including its call reference/time), allowing the token Worker to check eligibility with either participant's authenticated token. Other users cannot read it; report contents and private profiles stay private.

Matching filters the block list, rechecks the block and invitation inside the matching transaction, and is independently restricted by Firestore rules. `existsAfter` also rejects a batch that tries to create a block and ring that volunteer together. A block made after ringing prevents acceptance and new token issuance. The updated Worker checks invitations and blocks for both participants before issuing a token. Already-issued tokens and connected rooms are not forcibly revoked; end-of-call blocking protects subsequent calls. An already displayed ring may remain until its usual timeout, but cannot be accepted after a block.

## Deployment and rollout (not performed here)

1. Review the shared `firebase/firestore.rules` changes with the REPORT owner. Seed approved club members' invitation documents before switching clients to these rules.
2. From `firebase`, run `npm ci` and `npm test`, then deploy the reviewed rules using the existing project's Firebase configuration: `npx firebase-tools deploy --only firestore:rules --project accessable-2f8fc` (confirm this existing repo project ID with the owner first).
3. From `Workers/getCallToken`, run `npm ci`, `npm test`, then `npx wrangler deploy` using the existing Worker and secrets.
4. Build the updated app in Xcode. Existing callers need server-recorded consent. Confirm the checks below with approved club accounts before any outside-club use.

No Firebase project, paid plan, Apple membership or new external service is created. Optional account deletion is deferred.

## Validation

- Passed: 128 Firestore emulator tests, including settings privacy/persistence, report validation, consent/invitation gates, block matching, concurrent block/match and same-batch block/ring protection.
- Passed: 10 token Worker tests, including blocked/revoked caller and volunteer rejection.
- Passed: Worker deployment dry run; syntax parsing of all 22 changed/new Swift files (not SDK/type checking or a build).
- Added: 20 Swift tests covering volunteer settings, Report/Block results and retry, ordered presence cleanup, and overlapping screen-awake requests. Not run here: Xcode build, Swift tests, two-phone or accessibility checks.
- Patch application is checked against the uploaded base and a text merge fixture containing the screenshot's Maps geoTracking assignment. This is not verification of an actual merged Xcode build.

Manual checks before rollout:

- Change all settings, relaunch and confirm persistence; display name/languages update without changing createdAt or resetting an active call.
- Confirm approved defaults turn Online on; keep-awake follows actual foreground Online state. Turn it off, background/lock, leave home and sign out; check idle-timer restoration and presence. Retry after a network failure.
- Finish a call, report from both sides and inspect the report privately in Firebase console. Block from the caller, relaunch and try that volunteer including a preferred-volunteer request: they must never ring for that caller. Another unblocked caller can still match them.
- Self-sign-up/role choice must not enable Online without an invitation. Revoke an invite and verify new matching/accept/token requests fail.
- Check every caller entry point presents consent before matching, including shortcuts/voice paths. Verify error announcements, VoiceOver labels and large-text scrolling.

## Applying over the Maps merge

The supplied volunteer9 ZIP lacks the merged geoTracking definitions. Use the accompanying Git patch on your existing merged clone instead of copying an entire project folder. If you already applied the first VOLUNTEER-10 download, use only the included upgrade patch; otherwise use the full VOLUNTEER-10 patch. Do not apply both. Three-way application preserves unrelated Maps changes, including `services.geoTracking = geoTracking`. If Git reports a conflict, retain both Maps wiring and call services; inspect the actual merged source and build it in Xcode.

## What remains outside automated validation

No Xcode toolchain or physical iPhones are available in this workspace. The 20 Swift tests are supplied for the existing AccessAbleTests target but were not run. Syntax parsing cannot catch SDK signatures, Swift concurrency diagnostics or runtime UI behavior. The feature is not signed off for outside-club use until the owner deploys the reviewed rules and Worker and the phone, accessibility, invitation and consent checks above pass. Account deletion was optional and is not included.
