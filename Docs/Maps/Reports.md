# Reports

Users report temporary obstacles (construction, a blocked path, a closed entrance, an elevator that is out) so that routes can avoid them. Reports live in Firestore in the app's one shared Firebase project, which Be My Eyes calls also use.

## Firebase project

- **Plan:** Spark (free). No credit card, Cloud Functions, Secret Manager, or Cloud Storage, so reports have no photos.
- **Services in use:** Firestore (`started in production mode) and Authentication with email and password. Anonymous sign-in is off.
- **App config:** `GoogleService-Info.plist` is kept out of git (see `.gitignore`). Ask the project owner for a copy and put it in `AccessAble/AccessAble/`, next to `AccessAbleApp.swift`.
- **App setup:** the Xcode project depends on `FirebaseAuth` and `FirebaseFirestore` (not the root `Package.swift`), and `AccessAbleApp.init()` calls `FirebaseApp.configure()` before anything else.
- **Accounts:** features sign in through the shared `AuthService` in `ServiceProtocols.swift`. It exposes only the user's ID (`AuthUser.id`), never their email or name.

## Data model

Swift: `Report` in `Models/Maps/Report.swift`. Firestore: one document per report in the `reports` collection, with the document ID equal to `id`.

| Field | Swift type | Firestore type | Notes |
|---|---|---|---|
| `id` | `String` | string | Must equal the document ID. |
| `kind` | `ReportKind` | string | One of `construction`, `blockedPath`, `closedEntrance`, `elevatorOut`, `other`. These values are stored, so they can't be renamed without migrating existing reports. |
| `coordinate` | `GeoCoordinate` | map `{latitude, longitude}` | Where the obstacle is. |
| `area` | `[GeoCoordinate]?` | list of maps, or absent | Optional outline for obstacles bigger than a point. 3 to 10 points. |
| `createdAt` | `Date` | timestamp | Must be the server timestamp, not the phone's clock. |
| `expiresAt` | `Date` | timestamp | After this the report is ignored. At most 30 days after `createdAt`. |
| `confirmations` | `Int` | number | Always 0 for now. Other users can't confirm reports yet; confirming will need its own rule. |
| `reporterID` | `String` | string | The reporter's `AuthUser` ID. The only user data a report holds. |

### Rate limits

`rateLimits/{userID}` holds a single field, `lastReportAt` (timestamp), recording when that user last created a report. It holds nothing else.

## Writing a report

A new report must be written in **one batch** with the reporter's rate-limit stamp:

1. Set `reports/{id}` with every field above, `reporterID` set to the signed-in user's ID, `confirmations` set to 0, and `createdAt` set to `FieldValue.serverTimestamp()`.
2. In the same batch, set `rateLimits/{userID}` to `{ lastReportAt: FieldValue.serverTimestamp() }`.

The rules reject a report written any other way.

## Reading reports

- Only signed-in users can read reports.
- Every query must set a limit of at most 200 (`.limit(to: 200)` or less). A query without a limit is rejected.
- Filter out expired reports (`expiresAt` in the past). Expired reports are not deleted automatically.

## Security rules

The rules are in `firebase/firestore.rules`.

- **Signed-in writes only:** every write requires a signed-in user.
- **Own reports only:** only the reporter can update or delete a report. `id`, `reporterID`, `createdAt`, and `confirmations` can never change. The reporter may change `kind`, `coordinate`, `area`, and `expiresAt` (for example, to end a report early).
- **Rate limit:** at most one new report per user per minute. The `rateLimits` document can't be deleted, so the limit can't be reset.
- **No personal data:** a report may contain only the fields in the table above, each with the right type and range.

### Ownership

This issue's owner owns `firestore.rules`. The calls team adds its rules by pull request for that owner to review. Rules in the repo take effect only once deployed to the Firebase project.

## Staying inside Spark's quotas

Spark has fixed daily Firestore limits on reads, writes, and deletes (see Firebase's pricing page for current numbers). The design keeps usage low:

- queries are capped at 200 reports,
- each user can create at most one report a minute,
- reports expire within 30 days, so routing only needs recent ones, and
- each report creation costs two writes (the report and the rate-limit stamp) plus one rule read.

## Routing with Valhalla

Reports are passed to Valhalla **on each route request** instead of being added to OpenStreetMap. OpenStreetMap discourages automated edits, and its changes take hours to days to reach Valhalla, which is too slow for temporary obstacles. Point reports can be sent as locations to avoid, and reports with an `area` as polygons to avoid.

## Local emulator

`firebase/` contains the emulator config. From that folder:

```
npm install
npm run emulators
```

The emulator runs locally, is free, and uses the `demo-accessable` project ID, so it never touches the real project. Rules tests will go in `firebase/tests/`.
