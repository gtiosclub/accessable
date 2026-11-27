import { after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  collection, deleteDoc, doc, getDoc, getDocs, limit, query, serverTimestamp, setDoc, Timestamp,
  updateDoc, where, writeBatch,
} from 'firebase/firestore';
import { startEnvironment } from './support.js';

// SAVE-1 (saves), HISTORY-1 (call history) and PROFILE-1 (profile details).

const env = await startEnvironment();
beforeEach(() => env.clearFirestore());
after(() => env.cleanup());

const dbFor = uid => env.authenticatedContext(uid).firestore();

async function seedAccounts() {
  await env.withSecurityRulesDisabled(async context => {
    const db = context.firestore();
    const batch = writeBatch(db);
    const now = Timestamp.now();
    batch.set(doc(db, 'users', 'alice'), { role: 'caller', displayName: '  Alice Smith', languages: ['English'], createdAt: now });
    batch.set(doc(db, 'users', 'carol'), { role: 'caller', displayName: 'Carol', languages: ['English'], createdAt: now });
    batch.set(doc(db, 'users', 'vic'), { role: 'volunteer', displayName: 'Vic Jones', languages: ['English'], createdAt: now });
    batch.set(doc(db, 'users', 'val'), { role: 'volunteer', displayName: 'Val', languages: ['English'], createdAt: now });
    batch.set(doc(db, 'volunteers', 'vic'), {
      displayName: 'Vic Jones', languages: ['English'], bio: '', isOnline: false, inCall: false, lastSeen: now,
    });
    await batch.commit();
  });
}

const save = (db, saver, saved, saverName, savedName, overrides = {}) =>
  setDoc(doc(db, 'saves', `${saver}_${saved}`), {
    saverId: saver, savedId: saved, saverName, savedName, createdAt: serverTimestamp(), ...overrides,
  });

// ---------- Saves ----------

test('a caller saves a volunteer, and each sees the other\'s save once it is mutual', async () => {
  await seedAccounts();
  await assertSucceeds(save(dbFor('alice'), 'alice', 'vic', 'Alice', 'Vic'));
  await assertSucceeds(save(dbFor('vic'), 'vic', 'alice', 'Vic', 'Alice'));
  // Each can read both directions of their own pair.
  for (const uid of ['alice', 'vic']) {
    await assertSucceeds(getDoc(doc(dbFor(uid), 'saves', 'alice_vic')));
    await assertSucceeds(getDoc(doc(dbFor(uid), 'saves', 'vic_alice')));
  }
  const mine = await assertSucceeds(getDocs(query(collection(dbFor('alice'), 'saves'), where('saverId', '==', 'alice'), limit(200))));
  assert.equal(mine.size, 1);
});

test('saves need the saver\'s own id, real first names, opposite roles and server time', async () => {
  await seedAccounts();
  const alice = dbFor('alice');
  await assertFails(save(alice, 'carol', 'vic', 'Carol', 'Vic'));
  await assertFails(save(alice, 'alice', 'vic', 'Admin', 'Vic'));
  await assertFails(save(alice, 'alice', 'vic', 'Alice', 'Victor'));
  await assertFails(save(alice, 'alice', 'carol', 'Alice', 'Carol'));
  await assertFails(save(dbFor('vic'), 'vic', 'val', 'Vic', 'Val'));
  await assertFails(save(alice, 'alice', 'nobody', 'Alice', 'Nobody'));
  await assertFails(save(alice, 'alice', 'vic', 'Alice', 'Vic', { createdAt: Timestamp.fromMillis(0) }));
  await assertFails(save(alice, 'alice', 'vic', 'Alice', 'Vic', { note: 'x' }));
  await assertFails(setDoc(doc(alice, 'saves', 'alice_val'), {
    saverId: 'alice', savedId: 'vic', saverName: 'Alice', savedName: 'Vic', createdAt: serverTimestamp(),
  }));
});

test('only the saver unsaves; nobody edits a save, and outsiders cannot read or list', async () => {
  await seedAccounts();
  await save(dbFor('alice'), 'alice', 'vic', 'Alice', 'Vic');
  await assertFails(deleteDoc(doc(dbFor('vic'), 'saves', 'alice_vic')));
  await assertFails(updateDoc(doc(dbFor('alice'), 'saves', 'alice_vic'), { savedName: 'Other' }));
  await assertFails(getDoc(doc(dbFor('carol'), 'saves', 'alice_vic')));
  await assertFails(getDocs(query(collection(dbFor('carol'), 'saves'), where('saverId', '==', 'alice'), limit(200))));
  await assertFails(getDocs(query(collection(dbFor('alice'), 'saves'), where('saverId', '==', 'alice'), limit(201))));
  await assertSucceeds(deleteDoc(doc(dbFor('alice'), 'saves', 'alice_vic')));
});

// ---------- Volunteer-started chat ----------

function startChatAsVolunteer(db) {
  const batch = writeBatch(db);
  batch.set(doc(db, 'chats', 'alice_vic'), {
    callerId: 'alice', volunteerId: 'vic', volunteerName: 'Vic Jones', callerFirstName: 'Alice',
    createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
  });
  batch.set(doc(collection(db, 'chats', 'alice_vic', 'messages')), { senderId: 'vic', text: 'Hi!', sentAt: serverTimestamp() });
  return batch.commit();
}

test('a volunteer starts a chat only once both have saved each other', async () => {
  await seedAccounts();
  await assertFails(startChatAsVolunteer(dbFor('vic')));
  await save(dbFor('vic'), 'vic', 'alice', 'Vic', 'Alice');
  await assertFails(startChatAsVolunteer(dbFor('vic')));
  await save(dbFor('alice'), 'alice', 'vic', 'Alice', 'Vic');
  await assertSucceeds(startChatAsVolunteer(dbFor('vic')));
});

// ---------- Call history ----------

async function seedCall(id, data) {
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), 'calls', id), {
      roomName: `call-${id}`, status: 'ended', createdAt: Timestamp.now(), updatedAt: Timestamp.now(), ...data,
    });
  });
}

test('each side lists only their own calls, within the limit', async () => {
  await seedAccounts();
  await seedCall('c1', { callerId: 'alice', volunteerId: 'vic' });
  await seedCall('c2', { callerId: 'carol', volunteerId: 'vic' });
  const calls = (db, field, uid, n = 100) => getDocs(query(collection(db, 'calls'), where(field, '==', uid), limit(n)));
  assert.equal((await assertSucceeds(calls(dbFor('alice'), 'callerId', 'alice'))).size, 1);
  assert.equal((await assertSucceeds(calls(dbFor('vic'), 'volunteerId', 'vic'))).size, 2);
  await assertFails(calls(dbFor('alice'), 'callerId', 'carol'));
  await assertFails(calls(dbFor('alice'), 'volunteerId', 'vic'));
  await assertFails(calls(dbFor('alice'), 'callerId', 'alice', 101));
});

test('answering may stamp acceptedAt once, at server time, and nothing else may', async () => {
  await seedAccounts();
  const answer = async (id, acceptedAt) => {
    await seedCall(id, { callerId: 'alice', volunteerId: 'vic', status: 'ringing' });
    await env.withSecurityRulesDisabled(async context => {
      await updateDoc(doc(context.firestore(), 'volunteers', 'vic'), { ringingCallId: id, ringingSince: Timestamp.now() });
    });
    const db = dbFor('vic');
    const batch = writeBatch(db);
    batch.update(doc(db, 'calls', id), { status: 'accepted', updatedAt: serverTimestamp(), acceptedAt });
    batch.update(doc(db, 'volunteers', 'vic'), { inCall: true, ringingCallId: null, ringingSince: null, lastSeen: serverTimestamp() });
    return batch.commit();
  };
  await assertFails(answer('early', Timestamp.fromMillis(0)));
  await assertSucceeds(answer('ok', serverTimestamp()));
  // Hanging up can't rewrite when the call began.
  await assertFails(updateDoc(doc(dbFor('alice'), 'calls', 'ok'), { status: 'ended', updatedAt: serverTimestamp(), acceptedAt: serverTimestamp() }));
  await assertSucceeds(updateDoc(doc(dbFor('alice'), 'calls', 'ok'), { status: 'ended', updatedAt: serverTimestamp() }));
});

// ---------- Profile details ----------

test('profile details are optional, checked, and editable by the owner', async () => {
  await seedAccounts();
  const ref = doc(dbFor('alice'), 'users', 'alice');
  await assertSucceeds(updateDoc(ref, { location: 'Atlanta, GA', condition: 'Partially sighted, right eye' }));
  await assertSucceeds(updateDoc(doc(dbFor('vic'), 'users', 'vic'), { availability: 'weekdays' }));
  await assertFails(updateDoc(ref, { availability: 'sometimes' }));
  await assertFails(updateDoc(ref, { location: 'x'.repeat(81) }));
  await assertFails(updateDoc(ref, { condition: 'x'.repeat(201) }));
  await assertFails(updateDoc(ref, { location: 42 }));
  await assertFails(updateDoc(ref, { phone: '555' }));
});

// ---------- Profile pictures ----------

test('anyone signed in sees a picture; only its owner sets it, small and at server time', async () => {
  await seedAccounts();
  const { Bytes } = await import('firebase/firestore');
  const jpeg = Bytes.fromUint8Array(new Uint8Array([0xff, 0xd8, 0xff, 0xd9]));
  const ref = uid => doc(dbFor(uid), 'avatars', 'alice');
  await assertSucceeds(setDoc(ref('alice'), { jpeg, updatedAt: serverTimestamp() }));
  await assertSucceeds(getDoc(ref('vic')));
  await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), 'avatars', 'alice')));
  await assertFails(setDoc(ref('vic'), { jpeg, updatedAt: serverTimestamp() }));
  await assertFails(setDoc(ref('alice'), { jpeg, updatedAt: Timestamp.fromMillis(0) }));
  await assertFails(setDoc(ref('alice'), { jpeg: 'not bytes', updatedAt: serverTimestamp() }));
  const big = Bytes.fromUint8Array(new Uint8Array(200001));
  await assertFails(setDoc(ref('alice'), { jpeg: big, updatedAt: serverTimestamp() }));
  await assertFails(getDocs(collection(dbFor('vic'), 'avatars')));
  await assertFails(deleteDoc(ref('vic')));
  await assertSucceeds(deleteDoc(ref('alice')));
});

// ---------- Volunteer calling a caller ----------

function volunteerRing(db, id, overrides = {}) {
  return setDoc(doc(db, 'calls', id), {
    callerId: 'alice', volunteerId: 'vic', status: 'ringing', roomName: `call-${id}`,
    createdAt: serverTimestamp(), updatedAt: serverTimestamp(), startedBy: 'volunteer', ...overrides,
  });
}

test('a volunteer rings a caller only once both have saved each other', async () => {
  await seedAccounts();
  await assertFails(volunteerRing(dbFor('vic'), 'r1'));
  await save(dbFor('vic'), 'vic', 'alice', 'Vic', 'Alice');
  await assertFails(volunteerRing(dbFor('vic'), 'r1'));
  await save(dbFor('alice'), 'alice', 'vic', 'Alice', 'Vic');
  await assertSucceeds(volunteerRing(dbFor('vic'), 'r1'));
  // Not as someone else, not to another volunteer, not with a made-up room.
  await assertFails(volunteerRing(dbFor('val'), 'r2', { volunteerId: 'vic' }));
  await assertFails(volunteerRing(dbFor('vic'), 'r3', { roomName: 'call-other' }));
  await assertFails(volunteerRing(dbFor('alice'), 'r4', { volunteerId: 'alice' }));
});

test('the caller answers or declines a volunteer ring; either side hangs up', async () => {
  await seedAccounts();
  await save(dbFor('vic'), 'vic', 'alice', 'Vic', 'Alice');
  await save(dbFor('alice'), 'alice', 'vic', 'Alice', 'Vic');
  await volunteerRing(dbFor('vic'), 'a');
  await volunteerRing(dbFor('vic'), 'd');
  // The caller sees rings meant for them.
  const rings = await assertSucceeds(getDocs(query(collection(dbFor('alice'), 'calls'),
    where('callerId', '==', 'alice'), where('status', '==', 'ringing'), where('startedBy', '==', 'volunteer'), limit(5))));
  assert.equal(rings.size, 2);
  // The volunteer can't answer their own ring.
  await assertFails(updateDoc(doc(dbFor('vic'), 'calls', 'a'), { status: 'accepted', updatedAt: serverTimestamp() }));
  await assertSucceeds(updateDoc(doc(dbFor('alice'), 'calls', 'a'),
    { status: 'accepted', updatedAt: serverTimestamp(), acceptedAt: serverTimestamp() }));
  await assertSucceeds(updateDoc(doc(dbFor('alice'), 'calls', 'd'), { status: 'declined', updatedAt: serverTimestamp() }));
  await assertSucceeds(updateDoc(doc(dbFor('vic'), 'calls', 'a'), { status: 'ended', updatedAt: serverTimestamp() }));
});

test('a block stops a volunteer ring and its answer', async () => {
  await seedAccounts();
  await save(dbFor('vic'), 'vic', 'alice', 'Vic', 'Alice');
  await save(dbFor('alice'), 'alice', 'vic', 'Alice', 'Vic');
  await volunteerRing(dbFor('vic'), 'b');
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), 'users', 'alice', 'blockedVolunteers', 'vic'), { callId: 'b', createdAt: Timestamp.now() });
  });
  await assertFails(volunteerRing(dbFor('vic'), 'b2'));
  await assertFails(updateDoc(doc(dbFor('alice'), 'calls', 'b'), { status: 'accepted', updatedAt: serverTimestamp() }));
});
