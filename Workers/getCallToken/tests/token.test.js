import { after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import worker from '../src/index.js';

const project = 'demo-accessable';
const keys = await webcrypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048,
  publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify']);
const jwk = await webcrypto.subtle.exportKey('jwk', keys.publicKey);
jwk.kid = 'offline-test-key';
const env = { FIREBASE_PROJECT_ID: project, LIVEKIT_API_KEY: 'fixture-key', LIVEKIT_API_SECRET: 'fixture-secret-not-a-real-key' };
const originalFetch = globalThis.fetch;
let callStatus, callerID, firestoreStatus, invited, blocked, inviteStatus, blockStatus;
beforeEach(() => {
  callStatus = 'accepted'; callerID = 'caller'; firestoreStatus = 200; invited = true; blocked = false; inviteStatus = 200; blockStatus = null;
  globalThis.fetch = async (url, options) => {
    url = String(url);
    if (url.includes('googleapis.com/service_accounts/v1/jwk/')) {
      return Response.json({ keys: [jwk] }, { headers: { 'cache-control': 'max-age=3600' } });
    }
    assert.ok(url.startsWith(`https://firestore.googleapis.com/v1/projects/${project}/`));
    assert.ok(options.headers.Authorization.startsWith('Bearer '));
    if (firestoreStatus !== 200) return new Response('', { status: firestoreStatus });
    if (url.includes('/volunteerInvites/') && inviteStatus !== 200) return new Response('', { status: inviteStatus });
    if (url.includes('/blockedVolunteers/') && blockStatus !== null) return new Response('', { status: blockStatus });
    if (url.includes('/volunteerInvites/')) return Response.json({ fields: { enabled: { booleanValue: invited } } });
    if (url.includes('/blockedVolunteers/')) return blocked ? Response.json({ fields: {} }) : new Response('', { status: 404 });
    const id = url.split('/').at(-1);
    return Response.json({ fields: {
      callerId: { stringValue: callerID }, volunteerId: { stringValue: 'helper' },
      status: { stringValue: callStatus }, roomName: { stringValue: `call-${id}` },
    } });
  };
});
after(() => { globalThis.fetch = originalFetch; });
const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
async function idToken(uid = 'caller', overrides = {}) {
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${encode({ alg: 'RS256', kid: jwk.kid })}.${encode({
    aud: project, iss: `https://securetoken.google.com/${project}`, sub: uid,
    iat: now, auth_time: now, exp: now + 300, ...overrides,
  })}`;
  const signature = await webcrypto.subtle.sign('RSASSA-PKCS1-v1_5', keys.privateKey, Buffer.from(unsigned));
  return `${unsigned}.${Buffer.from(signature).toString('base64url')}`;
}
async function request(token, callId = 'one', config = env) {
  const response = await worker.fetch(new Request('https://worker.example', {
    method: 'POST', headers: token ? { Authorization: `Bearer ${token}`, 'content-type': 'application/json' } : {},
    body: JSON.stringify({ callId }),
  }), config);
  return { response, body: await response.json() };
}
test('five accepted calls mint separate room-scoped tokens without restarting Worker', async () => {
  const auth = await idToken();
  for (let i = 1; i <= 5; i++) {
    const id = `call-${i}`;
    const { response, body } = await request(auth, id);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(body.callId, id);
    const [head, payload, sig] = body.token.split('.');
    const claims = JSON.parse(Buffer.from(payload, 'base64url'));
    assert.equal(claims.sub, 'caller'); assert.equal(claims.video.room, `call-${id}`);
    assert.equal(claims.video.roomJoin, true); assert.equal(claims.video.roomAdmin, undefined);
    const key = await webcrypto.subtle.importKey('raw', Buffer.from(env.LIVEKIT_API_SECRET), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
    assert.equal(await webcrypto.subtle.verify('HMAC', key, Buffer.from(sig, 'base64url'), Buffer.from(`${head}.${payload}`)), true);
  }
});
test('the matching volunteer can obtain their own ticket', async () => {
  const { response, body } = await request(await idToken('helper'));
  assert.equal(response.status, 200);
  assert.equal(JSON.parse(Buffer.from(body.token.split('.')[1], 'base64url')).sub, 'helper');
});
test('unauthenticated and unrelated users cannot get call tickets', async () => {
  assert.equal((await request(null)).response.status, 401);
  assert.equal((await request(await idToken('stranger'))).response.status, 403);
});
test('wrong project, expired token and forged signature are rejected', async () => {
  for (const overrides of [{ aud: 'wrong-project' }, { exp: 1 }]) {
    assert.equal((await request(await idToken('caller', overrides))).response.status, 401);
  }
  const token = (await idToken()).split('.');
  token[1] = encode({ sub: 'caller' });
  assert.equal((await request(token.join('.'))).response.status, 401);
});
test('ringing and ended calls do not get media tokens', async () => {
  for (const status of ['ringing', 'ended']) {
    callStatus = status;
    assert.equal((await request(await idToken())).response.status, 409);
  }
});
test('Firestore denial and missing calls remain forbidden', async () => {
  for (const status of [403, 404]) {
    firestoreStatus = status;
    assert.equal((await request(await idToken())).response.status, 403);
  }
});
test('missing server secrets fail closed; invalid call IDs are rejected', async () => {
  assert.equal((await request(await idToken(), 'one', { FIREBASE_PROJECT_ID: project })).response.status, 500);
  assert.equal((await request(await idToken(), '../other')).response.status, 400);
});

test('both caller and volunteer tokens are refused after a block or invitation revocation', async () => {
  for (const uid of ['caller', 'helper']) {
    blocked = true;
    assert.equal((await request(await idToken(uid))).response.status, 403);
    blocked = false; invited = false;
    assert.equal((await request(await idToken(uid))).response.status, 403);
    invited = true;
  }
});

test('missing, forbidden or unavailable invitation never produces a media token', async () => {
  for (const status of [403, 404, 503]) {
    inviteStatus = status;
    const result = await request(await idToken());
    assert.equal(result.response.status, 403);
    assert.equal(result.body.token, undefined);
  }
});
test('block lookup errors fail closed for both participants', async () => {
  for (const uid of ['caller', 'helper']) {
    for (const status of [403, 500, 503]) {
      blockStatus = status;
      const result = await request(await idToken(uid));
      assert.equal(result.response.status, 403);
      assert.equal(result.body.token, undefined);
    }
  }
});
