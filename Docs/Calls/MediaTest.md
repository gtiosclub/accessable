# LiveKit audio/video device test

This is a temporary Debug-only transport test, not the final call UI. It bypasses sign-in and matching, joins one fixed room, and uses LiveKit Cloud's insecure development token server. MATCH-1 must replace that token source with the authenticated Cloudflare Worker. Nothing is deployed by this change; no new service, paid plan, Apple membership, or local Valhalla server is needed.

## What is implemented

- Dedicated `LiveKitMediaTest` Xcode scheme opens the harness through `-LiveKitMediaTest`. The normal AccessAble scheme still opens the normal app. Release builds compile out the harness and development token code.
- Both test roles request fresh tokens for `accessable-call-test`; each connection gets a unique identity. Do not use this public test room for private conversations or run several independent pairs in it.
- Caller publishes the rear wide-angle camera and microphone. Volunteer publishes only microphone and renders subscribed caller video. No LiveKit Components package is needed: the existing core SDK supplies `SwiftUIVideoView`.
- Remote audio is subscribed/played by LiveKit automatically. The harness shows track counts and speaking detection, but a human must verify actual audibility in both directions.
- Permission rejection, missing configuration, token/connection/publication failures are shown without printing credentials. Simulator use is rejected. A failed join disconnects partial media before returning the camera.
- Disconnect, leaving the harness, or backgrounding the app ends the test. Brief inactive transitions, such as permission sheets, do not. Both phones must stay unlocked with the app on screen.
- The existing `ARSceneAnalyzer` hands off its exact shared `ARSessionManager`; it does not create a second AR session or alter clients' hold counts. The manager blocks AR starts/reconfiguration and frame delivery while a call owns it. After LiveKit disconnects, it restarts AR only if clients still request it. CV and any geo-tracking using that shared session pause with the session. Six ownership-state tests cover resume, idle, delayed start, client stop, competing ownership, and stale release.
- Camera and microphone usage text now explains calls and transmission through LiveKit.

## Your one-time LiveKit step

1. Open your existing project at https://cloud.livekit.io.
2. Open **Settings > Project** and enable **Development token server**.
3. Copy the **Token server ID** displayed below the toggle. This is not your API key or API secret. Do not paste either API credential into the app.

Official guide: https://docs.livekit.io/frontends/build/authentication/development-token-server/

## Configure and build on your Mac

1. Check out this branch with git (`gh pr checkout 302`). Keep your GoogleService-Info.plist and Secrets.xcconfig.
2. Open `AccessAble/Config/Secrets.xcconfig`. If it does not exist, copy `Secrets.example.xcconfig` to `Secrets.xcconfig` in that folder. Keep the existing LIVEKIT_URL line and add:

   ```xcconfig
   LIVEKIT_DEV_TOKEN_SERVER_ID = paste_your_token_server_id_here
   ```

   Do not use quotes, angle brackets, the project URL, or an API key here. This file is already ignored. The ID is injected into the test process by the scheme; it is not added to the app Info.plist or Release binary.

3. Open `AccessAble/AccessAble.xcodeproj` in Xcode. The existing resolved LiveKit version is 2.19.0; this implementation uses that version's `DevelopmentTokenSource`, `TokenRequestOptions`, `Room`, and camera APIs. Leave the root Package.swift alone.
4. In Xcode's scheme menu next to the Run button, choose **LiveKitMediaTest**. If it is not immediately visible, use Product > Scheme > Manage Schemes and check the shared scheme.
5. Connect the first physical iPhone, unlock it, enable Developer Mode if Xcode asks, select it as the destination, and Run. Use your existing free Personal Team for signing. The harness opens directly without Firebase sign-in.
6. Select **Caller**, tap **Join as caller**, and allow microphone and camera access. Keep the app open.
7. Install/run the same scheme on the second physical iPhone. Select **Volunteer**, tap **Join as volunteer**, and allow microphone access. Both devices must use the same LiveKit project/token server ID. Each teammate may build on their own Mac with their own free Personal Team.

The room is created on connection; there is no manual room creation, no agent to deploy, and no Worker to implement for this test. LIVEKIT_URL remains the normal app configuration; the test uses the URL returned with the development token to avoid project/token mismatch.

The scheme supplies the launch argument and environment variable only when launched from Xcode. For this test, Run from Xcode rather than tapping an old Home Screen installation. If the missing-ID message appears, check the untracked xcconfig path and the LiveKitMediaTest scheme's Run > Arguments > Environment Variables: LIVEKIT_DEV_TOKEN_SERVER_ID should have value `$(LIVEKIT_DEV_TOKEN_SERVER_ID)` and be checked. Rebuild after changing configuration.

## Two-phone acceptance check (must be completed on devices)

Use headphones or separate rooms to prevent speaker feedback. Use Wi-Fi or cellular with working internet; the phones need not share a local network.

- [ ] Both phones connect to `accessable-call-test`; each shows one other participant.
- [ ] Caller sees its local rear-camera preview; pointing the back of the phone at an object shows that object.
- [ ] Volunteer sees that moving object and the harness reports receiving video frames. A local caller preview alone does not prove remote delivery.
- [ ] Volunteer has no local camera publication and is not asked for camera access on a fresh install.
- [ ] Caller says a phrase; volunteer hears and repeats it correctly.
- [ ] Volunteer says a different phrase; caller hears and repeats it correctly.
- [ ] Disconnect stops capture/playback and removes the peer from the other phone. Rejoin works.
- [ ] Background/lock ends this harness connection. Return to the foreground and explicitly rejoin.
- [ ] Denying a permission gives an actionable message. Enable it under iPhone Settings > Apps > AccessAble before retrying.
- [ ] If testing alongside a running AR client, verify its frames stop during call ownership and resume only after disconnect. Pure ownership tests do not prove hardware release timing.

Record device models, iOS versions, test date, audio/video results, and any failures in your PR. No two-phone test has been performed in the Linux coding workspace. An Xcode build and the Swift tests are also still required; no Xcode/Apple SDK is available there.

Free Personal Team provisioning profiles expire after **7 days**. Expect to rebuild/reinstall from Xcode weekly; an expired installation is not a LiveKit failure.
Source: https://developer.apple.com/help/account/basics/about-your-developer-account/

## Privacy manifest review

Reviewed the app's existing `PrivacyInfo.xcprivacy` and the resolved LiveKit **2.19.0** source at commit `43c1c0870e51eedbfd95b20b1b5c43a767886786`:

- LiveKit's Package.swift processes its own `Sources/LiveKit/PrivacyInfo.xcprivacy` resource. Its manifest declares SystemBootTime reasons **35F9.1** and **8FFB.1**. Those are SDK declarations; do not copy them into the app's manifest as new app API use.
- Kept the app's existing UserDefaults reason **CA92.1**, tracking setting, and collected-data declarations. Added an explanatory comment rather than inventing new required-reason entries.
- This harness does not invoke recording, egress, upload-to-storage, or file persistence. It sends live media to room participants. Both purpose strings explicitly describe calls.
- Permission strings and privacy manifests serve different purposes. Real-time transmission alone does not justify inventing an AudioData collection declaration: Apple's collection definition depends on access/retention beyond servicing the real-time request. Before production, review actual Cloud metadata retention, account identity linkage, recording choices, and the complete app's data practices; this is not a production privacy certification.
- On the Mac, verify the resolved SDK/transitive framework privacy resources are present in Xcode's archive/privacy report when available. The packaged WebRTC/FFI binaries and an Xcode archive could not be inspected in Linux. This source review does not replace that check. Recheck the manifests if the SDK version changes.

Sources:
- https://github.com/livekit/client-sdk-swift/blob/43c1c0870e51eedbfd95b20b1b5c43a767886786/Package.swift
- https://github.com/livekit/client-sdk-swift/blob/43c1c0870e51eedbfd95b20b1b5c43a767886786/Sources/LiveKit/PrivacyInfo.xcprivacy
- https://developer.apple.com/app-store/app-privacy-details/

## End the experiment

Disconnect both phones. Disable the development token server in LiveKit Cloud when no longer testing. Use the normal AccessAble scheme to return to sign-in/home screens. MATCH-1 must provide authenticated Worker tokens before this becomes a real call feature; do not expose the Debug harness as the production call flow.
