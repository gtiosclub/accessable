import { after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  Timestamp, doc, getDoc, runTransaction, serverTimestamp, setDoc, writeBatch,
} from 'firebase/firestore';
import { startEnvironment, seedCallPrerequisites } from './support.js';

// VOLUNTEER-6: matching a caller to a volunteer. Each helper below writes exactly what the
// apps write, so these tests check the same transactions the apps run.

const env = await startEnvironment();
beforeEach(() => env.clearFirestore());
after(() => env.cleanup());

const dbAs = (uid) => env.authenticatedContext(uid).firestore();
const secondsAgo = (s) => Timestamp.fromMillis(Date.now() - s * 1000);

// ---------- Setup (rules off) ----------

async function seed(path, id, data) {
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), path, id), data);
  });
}

async function read(path, id) {
  let data;
  await env.withSecurityRulesDisabled(async (context) => {
    data = (await getDoc(doc(context.firestore(), path, id))).data();
  });
  return data;
}

// An online volunteer with a fresh heartbeat who isn't ringing.
async function seedVolunteer(uid, overrides = {}) {
  await seedCallPrerequisites(env, 'fixture-caller', uid);
  return seed('volunteers', uid, {
    displayName: 'Sam', languages: ['English'], bio: '', isOnline: true, inCall: false,
    ringingCallId: null, ringingSince: null, lastSeen: Timestamp.now(), ...overrides,
  });
}

// `callerId` rang `volunteerId` `ago` seconds ago and nobody has answered yet.
async function seedRinging(callId, callerId, volunteerId, ago = 0) {
  await seed('calls', callId, {
    callerId, volunteerId, status: 'ringing', roomName: `call-${callId}`,
    createdAt: secondsAgo(ago), updatedAt: secondsAgo(ago),
  });
  await seedVolunteer(volunteerId, { ringingCallId: callId, ringingSince: secondsAgo(ago) });
}

// ---------- What the apps write ----------

// Ring: create the call and mark the volunteer as ringing, in one write.
function ringWrites(write, db, callerId, volunteerId, callId, ringingSince = serverTimestamp()) {
  write.set(doc(db, 'calls', callId), {
    callerId, volunteerId, status: 'ringing', roomName: `call-${callId}`,
    createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
  });
  write.update(doc(db, 'volunteers', volunteerId), { ringingCallId: callId, ringingSince });
}

// The caller's app: check the volunteer is free, then ring them (a transaction).
async function ring(db, callerId, volunteerId, callId) {
  await seedCallPrerequisites(env, callerId, volunteerId);
  return runTransaction(db, async (tx) => {
    const volunteer = (await tx.get(doc(db, 'volunteers', volunteerId))).data();
    const ringing = volunteer.ringingCallId && volunteer.ringingSince.toMillis() > Date.now() - 45_000;
    if (!volunteer.isOnline || volunteer.inCall || ringing) throw new Error('busy');
    ringWrites(tx, db, callerId, volunteerId, callId);
  });
}

// The same writes without the app's checks, to prove the rules alone block a bad ring.
async function ringBlindly(db, callerId, volunteerId, callId, ringingSince) {
  await seedCallPrerequisites(env, callerId, volunteerId);
  const batch = writeBatch(db);
  ringWrites(batch, db, callerId, volunteerId, callId, ringingSince);
  return batch.commit();
}

// The volunteer's app: accept only if the call still rings them (a transaction).
function accept(db, volunteerId, callId) {
  return runTransaction(db, async (tx) => {
    const callRef = doc(db, 'calls', callId);
    const meRef = doc(db, 'volunteers', volunteerId);
    const call = (await tx.get(callRef)).data();
    const me = (await tx.get(meRef)).data();
    if (call.status !== 'ringing' || me.ringingCallId !== callId) {
      throw new Error('This call was taken or ended.');
    }
    tx.update(callRef, { status: 'accepted', updatedAt: serverTimestamp() });
    tx.update(meRef, { inCall: true, ringingCallId: null, ringingSince: null, lastSeen: serverTimestamp() });
  });
}

function acceptBlindly(db, volunteerId, callId) {
  const batch = writeBatch(db);
  batch.update(doc(db, 'calls', callId), { status: 'accepted', updatedAt: serverTimestamp() });
  batch.update(doc(db, 'volunteers', volunteerId), {
    inCall: true, ringingCallId: null, ringingSince: null, lastSeen: serverTimestamp(),
  });
  return batch.commit();
}

// The caller's app after 30 seconds: give up on this volunteer (a transaction).
// Fails if the call is no longer ringing; the caller then joins the accepted call.
function skip(db, volunteerId, callId) {
  return runTransaction(db, async (tx) => {
    const callRef = doc(db, 'calls', callId);
    const volunteerRef = doc(db, 'volunteers', volunteerId);
    const call = (await tx.get(callRef)).data();
    const volunteer = (await tx.get(volunteerRef)).data();
    if (call.status !== 'ringing') throw new Error('no longer ringing');
    tx.update(callRef, { status: 'skipped', updatedAt: serverTimestamp() });
    if (volunteer.ringingCallId === callId) {
      tx.update(volunteerRef, { ringingCallId: null, ringingSince: null });
    }
  });
}

function skipBlindly(db, volunteerId, callId) {
  const batch = writeBatch(db);
  batch.update(doc(db, 'calls', callId), { status: 'skipped', updatedAt: serverTimestamp() });
  batch.update(doc(db, 'volunteers', volunteerId), { ringingCallId: null, ringingSince: null });
  return batch.commit();
}

function decline(db, volunteerId, callId) {
  const batch = writeBatch(db);
  batch.update(doc(db, 'calls', callId), { status: 'declined', updatedAt: serverTimestamp() });
  batch.update(doc(db, 'volunteers', volunteerId), {
    ringingCallId: null, ringingSince: null, lastSeen: serverTimestamp(),
  });
  return batch.commit();
}

const winners = (results) => results.filter((r) => r.status === 'fulfilled').length;

// ---------- Ringing ----------

test('a caller rings a free, online volunteer', async () => {
  await seedVolunteer('sam');
  await assertSucceeds(ring(dbAs('alice'), 'alice', 'sam', 'c1'));
  assert.equal((await read('volunteers', 'sam')).ringingCallId, 'c1');
});

test('race: two callers ring the same volunteer at once and only one gets them', async () => {
  await seedVolunteer('sam');
  const results = await Promise.allSettled([
    ring(dbAs('alice'), 'alice', 'sam', 'c1'),
    ring(dbAs('bob'), 'bob', 'sam', 'c2'),
  ]);
  assert.equal(winners(results), 1);
  const winningCall = results[0].status === 'fulfilled' ? 'c1' : 'c2';
  assert.equal((await read('volunteers', 'sam')).ringingCallId, winningCall);
});

test('the rules stop a second caller even without the app check', async () => {
  await seedRinging('c1', 'alice', 'sam', 5);
  await assertFails(ringBlindly(dbAs('bob'), 'bob', 'sam', 'c2'));
});

test('a ring more than 45 seconds old is freed for the next caller', async () => {
  await seedRinging('c1', 'alice', 'sam', 60);
  await assertSucceeds(ringBlindly(dbAs('bob'), 'bob', 'sam', 'c2'));
  assert.equal((await read('volunteers', 'sam')).ringingCallId, 'c2');
});

test("ringingSince must be the server's clock, not the phone's", async () => {
  await seedVolunteer('sam');
  await assertFails(ringBlindly(dbAs('alice'), 'alice', 'sam', 'c1', Timestamp.now()));
});

test('callers cannot ring volunteers who are offline, in a call, or not heard from in 90 seconds', async () => {
  await seedVolunteer('off', { isOnline: false });
  await seedVolunteer('busy', { inCall: true });
  await seedVolunteer('stale', { lastSeen: secondsAgo(120) });
  const db = dbAs('alice');
  await assertFails(ringBlindly(db, 'alice', 'off', 'c1'));
  await assertFails(ringBlindly(db, 'alice', 'busy', 'c2'));
  await assertFails(ringBlindly(db, 'alice', 'stale', 'c3'));
});

test('a call must belong to the signed-in caller and use its own room', async () => {
  await seedVolunteer('sam');
  const db = dbAs('alice');
  const batch = writeBatch(db);
  batch.set(doc(db, 'calls', 'c1'), {
    callerId: 'bob', volunteerId: 'sam', status: 'ringing', roomName: 'call-c1',
    createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
  });
  batch.update(doc(db, 'volunteers', 'sam'), { ringingCallId: 'c1', ringingSince: serverTimestamp() });
  await assertFails(batch.commit());

  const otherRoom = writeBatch(db);
  otherRoom.set(doc(db, 'calls', 'c2'), {
    callerId: 'alice', volunteerId: 'sam', status: 'ringing', roomName: 'someone-elses-room',
    createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
  });
  otherRoom.update(doc(db, 'volunteers', 'sam'), { ringingCallId: 'c2', ringingSince: serverTimestamp() });
  await assertFails(otherRoom.commit());
});

// ---------- Answering ----------

test('the volunteer accepts a call that is still ringing them', async () => {
  await seedRinging('c1', 'alice', 'sam');
  await assertSucceeds(accept(dbAs('sam'), 'sam', 'c1'));
  assert.equal((await read('calls', 'c1')).status, 'accepted');
  assert.equal((await read('volunteers', 'sam')).inCall, true);
});

test('race: an accept and a skip at once, and exactly one wins', async () => {
  await seedRinging('c1', 'alice', 'sam', 29);
  const results = await Promise.allSettled([
    accept(dbAs('sam'), 'sam', 'c1'),
    skip(dbAs('alice'), 'sam', 'c1'),
  ]);
  assert.equal(winners(results), 1);
  const call = await read('calls', 'c1');
  const sam = await read('volunteers', 'sam');
  if (results[0].status === 'fulfilled') {
    assert.equal(call.status, 'accepted');
    assert.equal(sam.inCall, true);
  } else {
    assert.equal(call.status, 'skipped');
    assert.equal(sam.ringingCallId, null);
  }
});

test('after a skip the volunteer sees "This call was taken or ended."', async () => {
  await seedRinging('c1', 'alice', 'sam', 30);
  await assertSucceeds(skip(dbAs('alice'), 'sam', 'c1'));
  await assert.rejects(accept(dbAs('sam'), 'sam', 'c1'), /taken or ended/);
  await assertFails(acceptBlindly(dbAs('sam'), 'sam', 'c1'));
});

test('after an accept the skip fails, so the caller joins the call instead', async () => {
  await seedRinging('c1', 'alice', 'sam', 29);
  await assertSucceeds(accept(dbAs('sam'), 'sam', 'c1'));
  await assert.rejects(skip(dbAs('alice'), 'sam', 'c1'), /no longer ringing/);
  await assertFails(skipBlindly(dbAs('alice'), 'sam', 'c1'));
});

test('a volunteer cannot accept a call that rings someone else', async () => {
  await seedRinging('c1', 'alice', 'sam');
  await seedVolunteer('eve');
  await assertFails(acceptBlindly(dbAs('eve'), 'eve', 'c1'));
});

test('declining clears the ring so the next caller can ring them', async () => {
  await seedRinging('c1', 'alice', 'sam');
  await assertSucceeds(decline(dbAs('sam'), 'sam', 'c1'));
  assert.equal((await read('calls', 'c1')).status, 'declined');
  await assertSucceeds(ring(dbAs('bob'), 'bob', 'sam', 'c2'));
});

// ---------- Only the caller skips; only the two people read ----------

test('someone who is not the caller cannot skip', async () => {
  await seedRinging('c1', 'alice', 'sam', 30);
  await assertFails(skipBlindly(dbAs('eve'), 'sam', 'c1'));
  await assertFails(skip(dbAs('eve'), 'sam', 'c1'));
  // The volunteer can decline, but not "skip" themselves on the caller's behalf.
  await assertFails(skipBlindly(dbAs('sam'), 'sam', 'c1'));
});

test('only the caller and the volunteer can read a call', async () => {
  await seedRinging('c1', 'alice', 'sam');
  await assertSucceeds(getDoc(doc(dbAs('alice'), 'calls', 'c1')));
  await assertSucceeds(getDoc(doc(dbAs('sam'), 'calls', 'c1')));
  await assertFails(getDoc(doc(dbAs('eve'), 'calls', 'c1')));
});

test('either person can hang up an accepted call', async () => {
  await seedRinging('c1', 'alice', 'sam');
  await assertSucceeds(accept(dbAs('sam'), 'sam', 'c1'));
  const db = dbAs('alice');
  const batch = writeBatch(db);
  batch.update(doc(db, 'calls', 'c1'), { status: 'ended', updatedAt: serverTimestamp() });
  await assertSucceeds(batch.commit());
});
