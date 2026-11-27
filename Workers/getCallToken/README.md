# getCallToken (Cloudflare Worker, free plan)

Hands out a short-lived LiveKit token for one accepted call (VOLUNTEER-6). The LiveKit API key
and secret live only here, as Worker secrets; the app never sees them.

## What it checks

1. **Who is asking.** `Authorization: Bearer <Firebase ID token>` must be signed by Google, issued
   for our Firebase project (`FIREBASE_PROJECT_ID` in `wrangler.toml`), and not expired.
2. **That they belong to the call.** It reads `calls/{callId}` through Firestore's REST API with that
   same ID token, so `firebase/firestore.rules` decide: only the call's caller and volunteer can read it.
3. **That the call was accepted.** Only then does it sign a LiveKit token, valid for 10 minutes,
   for that call's room (`call-<callId>`) and nothing else.

## Request

```
POST https://getcalltoken.<your-subdomain>.workers.dev
Authorization: Bearer <Firebase ID token>
Content-Type: application/json

{ "callId": "..." }
```

Response: `{ token, callId, roomName, callerId, volunteerId, expiresAt }`.
Errors: 400 bad request, 401 sign in again, 403 not part of the call, 409 not accepted yet.

## Deploy

```
cd Workers/getCallToken
npx wrangler login
npx wrangler secret put LIVEKIT_API_KEY      # once, from the LiveKit Cloud project
npx wrangler secret put LIVEKIT_API_SECRET   # once
npx wrangler deploy
```

Set `FIREBASE_PROJECT_ID` in `wrangler.toml` before the first deploy. Check it's running:

```
curl -X POST https://getcalltoken.<your-subdomain>.workers.dev
```

should answer `{"error":"Sign in first."}`.

The Firestore rules must be deployed too (`npx firebase deploy --only firestore:rules` from
`firebase/`), or the live database won't know the `calls` rules the Worker relies on.
