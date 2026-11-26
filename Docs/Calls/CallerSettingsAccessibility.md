# VOLUNTEER-11: caller settings, call results and accessibility

## Behavior

Settings → Volunteer calls now contains three device-local preferences, persisted across launches under `callerPreferences.v1`, separately from the existing guidance/profile data:

| Setting | Default | Effect |
| --- | --- | --- |
| Flashlight on start | Off | Requests the back-camera torch after the caller connects. Unsupported/failed torch requests show a recoverable error; the call stays connected. Flipping to the front camera still turns the light off. |
| Critical obstacle alerts during calls | On | Gates critical hazard events received by the announcement engine while a call is active. Critical non-hazard system events and navigation maneuvers retain their existing allowance. Outside calls, obstacle delivery is unchanged. |
| Call announcement volume | 100% | Sets AccessAble synthesized call prompts and allowed in-call announcements from 0–100%, in 10% steps. Ordinary out-of-call guidance keeps its existing volume. It does not change the volunteer's audio or iOS VoiceOver volume. |

These preferences follow the existing device-local Settings behavior; they do not sync between devices or belong to a Firestore account document. Missing/corrupt caller settings fall back to the defaults. Reset to Default Settings includes them; switching a guidance preset preserves them. The existing UserDefaults privacy declaration already covers this local storage.

`GuidanceProfile` and `SettingsPreferences` are unchanged, so existing saved data still decodes and the issue's conditional GuidanceProfile review requirement is not triggered. Normal PR review should include the User Interaction owner for the shared announcement engine/event and audio-session changes.

**Camera ownership stays unchanged:** ARSessionManager/CV and AR geo-tracking pause while LiveKit owns the caller camera. Enabling critical obstacle alerts does not restart CV or promise live camera-based obstacle detection during a call. It controls critical hazard events that reach the engine. Policy tests inject those events without taking the camera.

The engine checks the current preference when submitting, repeating and draining events. A repeat cannot bypass disabled in-call obstacle alerts. `AnnouncementEvent.isCallAnnouncement` defaults to false for existing producers and marks caller prompts/consent for the dedicated volume. While in a call, synthesized speech uses the application audio session without changing it to playback-only or deactivating it when speech ends, so LiveKit retains ownership of its microphone session.

## End-of-call and control behavior

Call results have a dedicated scrolling screen with a focused heading, outcome text, Report/Block (when an accepted call is known), retry, permission settings when needed, and Done. Report/Block reuse VOLUNTEER-10's `CallSafetyService`, validation, Firestore storage/rules and matching safeguards. There are no new server collections, rules, Worker endpoints or secrets in this issue.

Retry, Done and external Settings wait while a safety action is saving (up to 20 seconds); a caller cannot start another match while the block confirmation is pending. An unconfirmed/failed save releases navigation without marking the volunteer as blocked. The report sheet retains its state, focuses the reason on entry and announces results through accessibility focus. Dismissing it restores focus to the invoking report button or the successful result. Failed saves remain retryable. An unconfirmed save times out after 20 seconds with an explicit unknown-outcome message and re-enables navigation. Firestore may still commit later; the UI does not claim cancellation or success. Late responses are fenced so an old request cannot overwrite the next action’s result. As documented in VOLUNTEER-10, a report whose server acknowledgement is lost may create a second moderation record on retry; blocking is idempotent.

Mute, camera and flashlight controls expose their states. Pending control changes are serialized at the view-model level, and late results are fenced to the original call so they cannot change the next call's accessible state. End Call remains reachable while a control change is pending. VoiceOver Magic Tap ends an active caller call; Escape on the active call opens results by hanging up, and Escape on results returns when a safety save is not pending.

Volunteer previous-call reports, connection errors and status messages now live inside the scrolling settings Form instead of a potentially screen-filling bottom inset. The incoming overlay continues to hide the underlying settings from accessibility. Volunteer rows reflow vertically at accessibility text sizes while keeping the name/status and Call action separately reachable.

## Validation performed here

- 128 Firestore emulator tests passed (existing VOLUNTEER-10 backend regression suite).
- 10 Worker tests passed (existing token and eligibility regression suite).
- Changed/new Swift sources were syntax-parsed. This is not SDK/type checking or a build.
- The Git patch is checked against the uploaded base and against a text fixture containing `services.geoTracking = geoTracking` plus unrelated Maps protocol additions. This verifies patch preservation, not a merged Xcode build.
- Added 15 Swift tests in CallerSettingsTests.swift (including CallAnnouncementPolicyTests), CallerCallControlsTests.swift, CallAnnouncementIntegrationTests.swift and two additions to CallSafetyActionsTests.swift: persistence/migration fallback, reset/preset behavior, volume bounds/scope, live alert policy/repeat enforcement, torch ordering/failure/retry, retained safety summary, late-control-result fencing, bounded safety confirmation and ignored late safety results.

**Not run here:** Xcode build, Swift tests, Accessibility Inspector, real Dynamic Type layouts, physical-device audio/torch tests or VoiceOver interaction. No Apple toolchain/phones are available in this workspace. The objective remains pending until a teammate who did not build this feature completes the device flow below. Static review is not a VoiceOver sign-off.

## Source accessibility review

| Screen | Source changes/checks | Device checks still required |
| --- | --- | --- |
| Sign in/sign up and role onboarding | Existing native fields, protected password fields, labeled submit/error states and shared onboarding preserved | Keyboard traversal, error announcements, role step at largest text |
| Caller settings | Native named toggles, adjustable percentage slider, explanatory text, existing reset/Done | Rotor adjustment, persistence after relaunch, maximum text size |
| Volunteer list | Vertical layout at accessibility sizes; distinct status label and named Call action | Long names/languages, offline row and loading/empty/error states |
| Consent | Existing scrolling disclosure/buttons retained; app prompt gets call volume | Focus order, cancel/agree, server error and retry; consent must precede matching |
| Calling/connected caller | Scrolling relative fonts, named/stateful controls, spoken transitions/errors, Magic Tap and Escape | Ringing/connecting/remote-end/permission/network failures, microphone/camera/torch states |
| Call results | Focused heading, scrollable result and large action buttons | Focus after local/remote end and failed connection, retry and Done |
| Report sheet | Native reason/details fields; success/error focus; focus return | Keyboard and long details, failed save/retry, success, cancel, no duplicate action |
| Block confirmation/result | Native confirmation; focused success/error; retry/Done gated during save | Cancel vs confirm, offline failure, blocked matching after relaunch |
| Volunteer settings and previous call | All statuses/results scroll inside Form; sign-out errors spoken | Invitation/loading errors, foreground Online and keep-awake, report card and sign out |
| Incoming volunteer call | Modal traits/background hidden; labeled actions; spoken accepting/connecting/connected; named mute state | Ring/Accept/Decline/timeout, caller video label, microphone error, remote end |

The existing Developer Tools media harness is not the production test route; use the normal AccessAble scheme and authenticated matching/Worker flow.

## Required independent teammate test

Use two physical iPhones with the same current build, existing deployed VOLUNTEER-10 rules/Worker, a caller who can consent, and an approved club volunteer. Keep the volunteer's phone unlocked and foregrounded. The tester must be someone who did not implement this feature. Enable VoiceOver and use Screen Curtain if comfortable; do not guide them by pointing to controls.

1. Sign in and complete any role/onboarding step. Reach caller Settings using VoiceOver only. Change all three call preferences, adjust the volume slider, relaunch and verify persistence. Reset and verify defaults.
2. Open the volunteer list. Read a volunteer's name, availability and languages, then use their named Call action. Verify offline volunteers cannot be called. Repeat using the main Call a volunteer entry point.
3. If this account has no recorded consent, read it, cancel once, reopen and agree. Simulate a consent-save error and retry. No ring may start before consent saves.
4. Hear ringing/connection progress. On the volunteer phone, accept using VoiceOver. Both parties must hear each other. While connected, mute/unmute, flip front/back, and toggle torch. Confirm spoken states match the real media. With flashlight-on-start enabled, verify the back torch after connection; an unsupported torch must not end the call.
5. Check call prompts at low/high saved app volume with VoiceOver off, then enable VoiceOver and verify iOS speech remains understandable and independently controlled. Ensure a navigation/critical prompt does not stop the call's microphone. A synthetic critical-hazard policy test is covered by Swift tests; camera CV remains paused during the call.
6. End via the named End Call button, then repeat with Magic Tap. Repeat with the remote participant ending. Results must get sensible focus and every action must be reachable without sight.
7. Open Report, choose a reason, enter details and submit. Verify a report document through the trusted moderator console. Simulate a failed save and retry; success must not be announced until confirmed. Close the sheet and verify focus return.
8. Cancel Block once, then confirm it. During saving, Retry/Done must wait. Verify the block record. Relaunch and request that same volunteer again: they must never ring for this caller; an unblocked caller can still match them.
9. Check connecting failure, missing microphone/camera permission, declined/unanswered calls and lost network. For a stalled Report/Block, wait up to 20 seconds: an unconfirmed message must restore navigation; it must not announce success. A later server response must not replace the result of another action. Reach the recovery actions by VoiceOver. Report/Block should only be offered when the app knows an accepted call and its participants.
10. Repeat every production screen/state above at default text, largest standard text and largest accessibility text on the smallest available phone. Use long display names/languages/details, the keyboard, Bold Text and landscape where supported. Check for clipping, overlapping text, unreachable buttons, illogical focus, color-only status and obscured errors. Use Accessibility Inspector in Xcode as a supplement to the device test.

Record results in the PR rather than checking boxes based on source review:

| Tester (not the author) | Device/iOS | Build/commit | VoiceOver-only full call | Largest text pass | Report/Block verified | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Pending | Pending | Pending | Not run | Not run | Not run on devices | |

Keep outside-club use gated on VOLUNTEER-10's invitation, consent and Report/Block checks as well as this accessibility sign-off.

## Apple references

- https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/usesapplicationaudiosession
- https://developer.apple.com/documentation/avfaudio/avspeechutterance/volume
- https://developer.apple.com/documentation/swiftui/accessibilityfocusstate
- https://developer.apple.com/documentation/accessibility/performing-accessibility-testing-for-your-app
