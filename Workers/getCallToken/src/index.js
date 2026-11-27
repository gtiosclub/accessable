// getCallToken (VOLUNTEER-6): hands out a short-lived LiveKit token for one accepted call.
//
// 1. Checks the Firebase ID token sent as "Authorization: Bearer <token>": signed by Google,
//    issued for our Firebase project, not expired.
// 2. Reads calls/{callId} through Firestore's REST API *with that same ID token*, so
//    firebase/firestore.rules decide whether this user belongs to the call.
// 3. Only if the call is accepted, signs a LiveKit token for that call's room.
//
// LIVEKIT_API_KEY and LIVEKIT_API_SECRET are Worker secrets; they never reach the app.
// FIREBASE_PROJECT_ID is set under [vars] in wrangler.toml.
//
// Request:  POST { "callId": "..." }  with  Authorization: Bearer <Firebase ID token>
// Response: { token, callId, roomName, callerId, volunteerId, expiresAt }

const GOOGLE_KEYS_URL =
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';
/** How long the app has to join the room with this token. */
const TOKEN_LIFETIME_SECONDS = 10 * 60;
/** Allowance for small clock differences between Google, Cloudflare and the phone. */
const CLOCK_SKEW_SECONDS = 60;

export default {
  async fetch(request, env) {
    try {
      return await handle(request, env);
    } catch (error) {
      if (error instanceof HttpError) return json({ error: error.message }, error.status);
      console.error(error);
      return json({ error: 'Something went wrong. Try again.' }, 500);
    }
  },
};

async function handle(request, env) {
  if (request.method !== 'POST') throw new HttpError(405, 'Use POST.');
  const projectId = env.FIREBASE_PROJECT_ID;
  if (!projectId || !env.LIVEKIT_API_KEY || !env.LIVEKIT_API_SECRET) {
    throw new HttpError(500, 'The token Worker is not configured.');
  }

  // 1. Who is asking?
  const idToken = (request.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!idToken) throw new HttpError(401, 'Sign in first.');
  const uid = await verifyFirebaseIdToken(idToken, projectId);

  const body = await request.json().catch(() => null);
  const callId = body?.callId;
  if (typeof callId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(callId)) {
    throw new HttpError(400, 'Missing or invalid callId.');
  }

  // 2. Do the rules say they belong to this call?
  const call = await readCall(callId, idToken, projectId);
  if (uid !== call.callerId && uid !== call.volunteerId) {
    throw new HttpError(403, 'You are not part of this call.');
  }
  if (call.status !== 'accepted') throw new HttpError(409, 'This call has not been accepted.');
  if (call.roomName !== `call-${callId}`) throw new HttpError(403, 'This call has the wrong room.');

  // Eligibility is checked for BOTH ticket recipients; the UI is not a trust boundary. No invites
  // for the demo: the rules already let only volunteer accounts be rung, so only blocks are checked here.
  const headers = { Authorization: `Bearer ${idToken}` };
  const base = `https://firestore.googleapis.com/v1/projects/${projectId}/databases/(default)/documents`;
  const blockResponse = await fetch(
    `${base}/users/${encodeURIComponent(call.callerId)}/blockedVolunteers/${encodeURIComponent(call.volunteerId)}`,
    { headers });
  if (blockResponse.status !== 404) {
    if (blockResponse.ok) throw new HttpError(403, 'This volunteer is blocked for this caller.');
    throw new HttpError(403, 'Call eligibility could not be verified.');
  }

  // 3. Only then: a token for this call's room and nothing else.
  const now = Math.floor(Date.now() / 1000);
  const expiresAt = now + TOKEN_LIFETIME_SECONDS;
  const token = await signLiveKitToken({
    apiKey: env.LIVEKIT_API_KEY,
    apiSecret: env.LIVEKIT_API_SECRET,
    identity: uid,
    room: call.roomName,
    now,
    expiresAt,
  });

  return json({
    token,
    callId,
    roomName: call.roomName,
    callerId: call.callerId,
    volunteerId: call.volunteerId,
    expiresAt: new Date(expiresAt * 1000).toISOString(),
  });
}

// ---------- Firebase ID tokens ----------

let googleKeys = null; // { keys: Map<kid, CryptoKey>, expiresAt: ms }
let lastUnknownKidRefresh = 0; // ms
// This runs before sign-in is checked, so a made-up kid must not refetch Google's keys every time.
const UNKNOWN_KID_REFRESH_MS = 60 * 1000;

async function googleKey(kid) {
  const stale = !googleKeys || Date.now() >= googleKeys.expiresAt;
  // Google rotates its keys; an unknown kid triggers a refresh, at most once a minute.
  const unknown = googleKeys && !googleKeys.keys.has(kid);
  if (unknown && !stale && Date.now() - lastUnknownKidRefresh < UNKNOWN_KID_REFRESH_MS) return undefined;
  if (stale || unknown) {
    if (unknown) lastUnknownKidRefresh = Date.now();
    const response = await fetch(GOOGLE_KEYS_URL);
    if (!response.ok) throw new Error(`Google keys: HTTP ${response.status}`);
    const maxAge = Number(/max-age=(\d+)/.exec(response.headers.get('Cache-Control') ?? '')?.[1] ?? 3600);
    const { keys } = await response.json();
    const imported = new Map();
    for (const jwk of keys) {
      imported.set(jwk.kid, await crypto.subtle.importKey(
        'jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify'],
      ));
    }
    googleKeys = { keys: imported, expiresAt: Date.now() + maxAge * 1000 };
  }
  return googleKeys.keys.get(kid);
}

/** Returns the user's ID (AuthUser.id in the app) or throws 401. */
async function verifyFirebaseIdToken(token, projectId) {
  const invalid = new HttpError(401, 'Your sign-in expired. Sign in again.');
  const parts = token.split('.');
  if (parts.length !== 3) throw invalid;
  const [headerPart, payloadPart, signaturePart] = parts;

  let header;
  let payload;
  try {
    header = JSON.parse(decodeText(headerPart));
    payload = JSON.parse(decodeText(payloadPart));
  } catch {
    throw invalid;
  }
  if (header.alg !== 'RS256' || typeof header.kid !== 'string') throw invalid;

  const key = await googleKey(header.kid);
  if (!key) throw invalid;
  const signed = new TextEncoder().encode(`${headerPart}.${payloadPart}`);
  const valid = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, base64UrlToBytes(signaturePart), signed);
  if (!valid) throw invalid;

  const now = Math.floor(Date.now() / 1000);
  const ok = payload.aud === projectId
    && payload.iss === `https://securetoken.google.com/${projectId}`
    && typeof payload.sub === 'string' && payload.sub.length > 0 && payload.sub.length <= 128
    && typeof payload.exp === 'number' && payload.exp > now
    && typeof payload.iat === 'number' && payload.iat <= now + CLOCK_SKEW_SECONDS
    && typeof payload.auth_time === 'number' && payload.auth_time <= now + CLOCK_SKEW_SECONDS;
  if (!ok) throw invalid;
  return payload.sub;
}

// ---------- Firestore (REST, with the user's own ID token) ----------

async function readCall(callId, idToken, projectId) {
  const url = `https://firestore.googleapis.com/v1/projects/${projectId}`
    + `/databases/(default)/documents/calls/${callId}`;
  const response = await fetch(url, { headers: { Authorization: `Bearer ${idToken}` } });
  // 403: the rules refused (not part of the call). 404: no such call.
  if (response.status === 403 || response.status === 404) {
    throw new HttpError(403, 'You are not part of this call.');
  }
  // Firestore refused the sign-in itself, e.g. it expired between our check and this read.
  if (response.status === 401) throw new HttpError(401, 'Your sign-in expired. Sign in again.');
  if (!response.ok) throw new Error(`Firestore: HTTP ${response.status}`);
  const { fields = {} } = await response.json();
  const text = (name) => fields[name]?.stringValue;
  return {
    callerId: text('callerId'),
    volunteerId: text('volunteerId'),
    status: text('status'),
    roomName: text('roomName'),
  };
}

// ---------- LiveKit token (an HS256 JWT signed with the API secret) ----------

async function signLiveKitToken({ apiKey, apiSecret, identity, room, now, expiresAt }) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const claims = {
    iss: apiKey,
    sub: identity,
    nbf: now - 10,
    exp: expiresAt,
    // This room only. Both sides may send audio and video and receive the other's.
    video: { room, roomJoin: true, canPublish: true, canSubscribe: true },
  };
  const unsigned = `${encodeJson(header)}.${encodeJson(claims)}`;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(apiSecret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(unsigned));
  return `${unsigned}.${bytesToBase64Url(new Uint8Array(signature))}`;
}

// ---------- Helpers ----------

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  });
}

function encodeJson(value) {
  return bytesToBase64Url(new TextEncoder().encode(JSON.stringify(value)));
}

function decodeText(part) {
  return new TextDecoder().decode(base64UrlToBytes(part));
}

function bytesToBase64Url(bytes) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64UrlToBytes(text) {
  const base64 = text.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}
