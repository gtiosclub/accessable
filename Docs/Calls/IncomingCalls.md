# Volunteer incoming calls

Built on the uploaded volunteer-7 branch. This is the volunteer-side ringing feature. It reuses the existing MATCH transactions and Worker tokens; it does not create a Firebase project, change plans, deploy rules, or use the insecure development token server.

## Behavior

- `VolunteerCallHostView` sits above volunteer navigation in `RootView`. An incoming overlay covers the home/navigation and hides underlying accessibility elements, so the volunteer can answer from any screen in that host. It does not use a full-screen cover that would tear down the underlying listener when presented.
- While the app is active and the **local Online toggle** is on, `FirestoreIncomingCalls` listens to this volunteer's document and then the one call named by `ringingCallId`. Server `isOnline` must also be true. Going offline, backgrounding/locking, sign-out, stream errors, withdrawal, and terminal call status remove the appropriate listeners and stop ringing. Nothing wakes a locked phone; there is no push or CallKit.
- The incoming screen shows the caller's first name, **Accept**, and **Decline**. The original ring WAV loops softly and the shared haptic renderer plays short attention patterns every three seconds. Stopping a ring cancels future patterns without stopping unrelated guidance haptics.
- After the screen appears, VoiceOver focuses Accept and receives **"Incoming call from Alex"** once for that presentation. The screen supports accessibility Escape (decline), a modal accessibility boundary, large controls, and Dynamic Type with scrolling.
- Accept stops the alerts, calls `CallSignaling.accept(callID:)`, validates the returned ticket, then joins through `VideoCallSession.connect(with:)`. Clearing `ringingCallId` during that transaction must not dismiss an answer in progress. An accept/token failure announces exactly **"This call was taken or ended."** A connection/permission failure after acceptance has a separate message. Failed or cancelled joins attempt `endCall` to release the accepted reservation.
- While connected, the volunteer sees received caller video and has Mute/Unmute and End Call. The existing session publishes only the volunteer's microphone. Received tracks are exposed through a read-only main-actor accessor on the existing LiveKit service; tokens and the Room remain private.
- Decline dismisses immediately and calls the existing decline transaction. If the write fails, a visible/spoken message explains that the reservation will expire. Duplicate taps do not submit duplicate actions.
- The ringing screen dismisses after **at most 30 seconds**, measured against `ringingSince`; opening a delayed/cached offer does not grant another 30 seconds. Duplicate heartbeat/call snapshots do not restart the sound or deadline. An expired or dismissed call ID cannot immediately ring again.
- Timeout is a local dismissal, not a new transaction or scheduled backend job. A live caller normally skips at 30 seconds; if its app died, MATCH's existing 45-second stale-ring rule makes the volunteer ringable again. Accept cancels the ringing deadline because answering/connecting is no longer ringing.
- An in-flight Accept is cancelled and awaited before disconnect/cleanup, so returning late from the Worker cannot connect a call after the volunteer ended it or left the host.

## Name contract and rules review

New call records may contain `callerFirstName`, projected from the signed-in caller's own `users/{uid}.displayName` inside the existing ring transaction. Only the first whitespace-separated name is shared. This is a display label from the user's profile, not independently verified identity.

`firebase/firestore.rules` permits that optional field only if it matches the caller's profile-derived first name. It remains immutable after creation. Call documents are still readable only by the two participants. **The private users rules are unchanged**: volunteers cannot fetch the caller's profile. Old clients/calls without the new field remain supported and show **Caller**.

The backend/rules owner must review and deploy this additive rule change before testing the updated caller against the shared project. Otherwise the old strict call schema rejects the new name field. No rules or Worker were deployed from this workspace. Update both caller and volunteer apps when testing the name.

## Files and interfaces

- `IncomingCall`, `IncomingCallProviding`, `FirestoreIncomingCalls`: separate read-only inbox contract, with foreground/online listener lifetime and error propagation.
- `IncomingCallViewModel`: presentation, timeout, transaction/media handoff, race guards and cleanup.
- `IncomingCallAlerts`, `Resources/Calls/incoming-call.wav`: original audio asset and shared attention haptics.
- `VolunteerCallHostView`, `IncomingVolunteerCallView`: root host and accessible incoming/connected screen.
- `AppServices`: live inbox using the same PresenceService; empty placeholder by default and in previews.
- `PlaceholderCallSignaling.accept` now preserves its requested call ID, so the placeholder follows the ticket contract too.
- Existing `CallSignaling` and `VideoCallSession` methods are reused; no duplicate matching or token implementation. Root Package.swift, package versions, project signing and LiveKit/Worker secrets are untouched.

## Verify on your Mac

1. Copy the updated folder's **contents** into your existing clone. Keep the clone's `.git` and your untracked configs. Do not copy the inner AccessAble app folder to the repository root.
2. Open `AccessAble/AccessAble.xcodeproj`, resolve packages, and build with the normal **AccessAble** scheme. New Swift files and the WAV are picked up by the project's existing synchronized folder group; do not add duplicate references.
3. Run the AccessAbleTests target, including `IncomingCallViewModelTests` (12 cases). These use fake signaling, media and alert services and do not contact Firebase or LiveKit.
4. For an offline UI smoke test, open `VolunteerCallHostView.swift` and run the **Incoming call (placeholders)** interactive preview. It should show Alex, ring/haptic where supported, and support Accept/Decline or timeout. Placeholder Accept simulates a connected session; it does not transmit media. Restart the preview for a new offer. Test VoiceOver on a physical device as well.
5. For real calls, use REPORT's existing Firebase config and email/password accounts, the shared deployed rules, and your existing untracked `Secrets.xcconfig` with **LIVEKIT_URL** and the authenticated Worker **CALL_TOKEN_URL**. This flow does not use LIVEKIT_DEV_TOKEN_SERVER_ID or the LiveKitMediaTest scheme.
6. Sign in as a volunteer, enable Online, and keep the app open on an unlocked phone. On another device sign in as a caller whose display name is Alex Rivera, then place a call using the existing caller flow. Use separate rooms or headphones to prevent feedback.

### Device acceptance checklist (still to perform)

- [ ] Build succeeds and all new Swift tests pass in Xcode.
- [ ] Online + foreground volunteer sees **Incoming call from Alex**, hears a ring, and feels attention haptics.
- [ ] VoiceOver announces the incoming name; Accept and Decline have useful labels/hints and can both be activated. Background content cannot receive accessibility focus while the overlay is open.
- [ ] Large accessibility text sizes keep both controls readable and reachable by scrolling.
- [ ] Accept joins using the existing Worker/VideoCallSession, stops ringing, shows caller video, and passes audio both ways. Repeated taps submit one accept.
- [ ] Decline stops ringing, dismisses the overlay, and the caller proceeds to the next volunteer.
- [ ] With the caller killed while ringing, the overlay stops by 30 seconds and the reservation is ringable again after the existing 45-second stale threshold. There is no automatic local delete/write on timeout.
- [ ] Caller cancellation/skip dismisses the volunteer's ring promptly. Duplicate/heartbeat updates do not restart it.
- [ ] Accept racing with skip/end announces **This call was taken or ended.** and does not join a room.
- [ ] End during an in-flight answer cannot later produce a ghost connection. A failed media join attempts to free the accepted reservation.
- [ ] Local Online off, app inactive/background/locked, and sign-out stop incoming alerts/listeners; another person's stale server-side Online flag does not bypass the local toggle.
- [ ] Disconnect/remote departure returns to volunteer home and allows a new incoming call.
- [ ] Ring audibility and VoiceOver coexist on the target phone's current volume, mute, headset and audio-session settings. This ordinary in-app ring does not promise silent-mode override or locked-phone ringing.

## Validation completed here

- `cd firebase && npm ci && npm test`: **90 tests passed, 0 failed**, including existing matching/race/report rules and 11 new incoming-name/privacy/listener checks. Uses the local demo emulator, not the live project.
- New Swift files were parsed for syntax and the ring WAV was validated. This is not a Swift type-check or an app build.
- Xcode, Swift test execution, actual Firestore/Worker/LiveKit calls, audible sound, physical haptics and VoiceOver are **unverified** in this Linux workspace.

Apple references: https://developer.apple.com/documentation/accessibility/accessibilitynotification/announcement and https://developer.apple.com/documentation/swiftui/accessibilityfocusstate

Firestore string validation: https://firebase.google.com/docs/reference/rules/rules.String.html
