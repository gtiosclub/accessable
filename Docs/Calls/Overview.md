# AccessAble — Calls overview

Shared decisions for the video-call feature. Every call task builds on these.

Release integration: [live services, rule hardening, deployment and the two-phone test log](Integration.md).

Volunteer ringing and answers: [incoming-call flow, rules contract and testing](IncomingCalls.md).

Two-iPhone media test: [LiveKit Debug harness and acceptance checklist](MediaTest.md).

Email/password accounts and role routing: [VOLUNTEER-2 setup and verification](SignIn.md).

**Rule for the whole feature: nothing costs money.** Every service stays on a free plan that
needs no credit card, and there is no paid Apple Developer account. Firebase itself is created by
REPORT-1 (#247); the call feature does not create a Firebase project or upgrade any plan.

## Services

| Piece | Where | Notes |
|---|---|---|
| Video | LiveKit Cloud, free Build plan | Hard-caps instead of charging. |
| Token endpoint | Cloudflare Worker `getCallToken`, free plan | MATCH-1 fills it in. Source in `Workers/getCallToken`. |
| Presence, signaling | Firestore in the Firebase project from REPORT-1 (Spark plan) | Signs in through the shared `AuthService` (`AuthUser.id`). Firebase config: see `Docs/Maps/Reports.md`. |
| Secrets | LiveKit API secret: Worker secret only. LiveKit URL: untracked `AccessAble/Config/Secrets.xcconfig` | The secret never goes in the app. |

## Decision 1: what "online" means

**Online means two things together:** the Online toggle is on, **and** AccessAble is open on screen
on an unlocked phone (any screen of the app counts).

Without the paid Apple membership there is no push and no CallKit, so nothing can wake the app.
iOS suspends the app a few seconds after it leaves the screen, which stops the listener and the
heartbeat. Once `lastSeen` is about 90 seconds old, callers skip that volunteer
(`Volunteer.staleAfter`, `Volunteer.isReachable`).

**Calls never arriving on a locked phone is expected, not a bug.**

## Decision 2: camera rule

`ARSessionManager` stays the app's **only** camera owner. During a call it pauses and LiveKit owns
the camera. CV and AR geo-tracking ([AR-2 · Run geo-tracking through ARSessionManager #237](https://github.com/gtiosclub/accessable/issues/237))
pause with it and resume when the call ends.

## Code map

- Protocols: `VolunteerDirectory`, `PresenceService`, `CallSignaling`, `VideoCallSession` in `Models/Services/ServiceProtocols.swift`.
- Types: `CallTicket`, `CallState`, `Volunteer` in `Models/Calls`.
- Placeholders and wiring: `PlaceholderServices.swift`, `AppServices` (`volunteers`, `presence`, `callSignaling`, `videoCall`).
- UI: `ViewModels/Calls`, `Views/Calls`. Stub screen: Developer Tools → Calls.

## Setup for each member

1. Copy `AccessAble/Config/Secrets.example.xcconfig` to `Secrets.xcconfig` and set `LIVEKIT_URL`.
2. Open the LiveKit Cloud and Cloudflare dashboards (shared logins/invites from the project owner).

## Volunteer settings and safety

See [Volunteer settings and call safety](VolunteerSettingsSafety.md) for persistent settings, invitation approval, consent, Report/Block, rules and rollout checks.
