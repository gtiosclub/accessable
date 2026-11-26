import { after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { doc, getDoc, onSnapshot, serverTimestamp, setDoc, Timestamp, updateDoc, writeBatch } from 'firebase/firestore';
import { startEnvironment, seedCallPrerequisites } from './support.js';

const env = await startEnvironment();
beforeEach(() => env.clearFirestore());
after(() => env.cleanup());
const as = (uid) => env.authenticatedContext(uid).firestore();

async function seed(name = 'Alex Rivera') {
  await seedCallPrerequisites(env, 'caller', 'helper');
  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'users', 'caller'), {
      role: 'caller', displayName: name, languages: ['English'], createdAt: Timestamp.now(),
    });
    await setDoc(doc(db, 'volunteers', 'helper'), {
      displayName: 'Sam', languages: ['English'], bio: '', isOnline: true, inCall: false,
      ringingCallId: null, ringingSince: null, lastSeen: Timestamp.now(),
    });
  });
}

function ring(name, includeName = true) {
  const db = as('caller');
  const batch = writeBatch(db);
  const call = {
    callerId: 'caller', volunteerId: 'helper', status: 'ringing', roomName: 'call-incoming',
    createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
  };
  if (includeName) call.callerFirstName = name;
  batch.set(doc(db, 'calls', 'incoming'), call);
  batch.update(doc(db, 'volunteers', 'helper'), { ringingCallId: 'incoming', ringingSince: serverTimestamp() });
  return batch.commit();
}

test('volunteer reads the projected first name without access to caller private profile', async () => {
  await seed();
  await assertSucceeds(ring('Alex'));
  const call = await assertSucceeds(getDoc(doc(as('helper'), 'calls', 'incoming')));
  assert.equal(call.data().callerFirstName, 'Alex');
  assert.equal(call.data().displayName, undefined);
  await assertFails(getDoc(doc(as('helper'), 'users', 'caller')));
  await assertFails(getDoc(doc(as('stranger'), 'calls', 'incoming')));
});

test('first name projection handles leading whitespace and non-Latin names', async () => {
  await seed(' \t김 예은');
  await assertSucceeds(ring('김'));
});

for (const name of ['SomeoneElse', 'Alex Rivera', '', null, 42, 'A'.repeat(81)]) {
  test(`rejects invalid or spoofed caller name ${JSON.stringify(name)}`, async () => {
    await seed();
    await assertFails(ring(name));
  });
}

test('legacy caller without projected name still rings; UI uses Caller fallback', async () => {
  await seed();
  await assertSucceeds(ring(undefined, false));
});

test('neither participant can change the first name after creation', async () => {
  await seed();
  await ring('Alex');
  for (const uid of ['caller', 'helper']) {
    await assertFails(updateDoc(doc(as(uid), 'calls', 'incoming'), {
      callerFirstName: 'Eve', updatedAt: serverTimestamp(),
    }));
  }
});

test('own volunteer listener sees ringingCallId and its removal on transactional decline', async () => {
  await seed();
  const db = as('helper');
  const seen = [];
  let unsubscribe;
  const nextID = (expected) => new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { unsubscribe?.(); reject(new Error('listener timeout')); }, 4000);
    unsubscribe = onSnapshot(doc(db, 'volunteers', 'helper'), (snapshot) => {
      const id = snapshot.data()?.ringingCallId ?? null;
      seen.push(id);
      if (id === expected) { clearTimeout(timeout); unsubscribe(); resolve(); }
    }, (error) => { clearTimeout(timeout); reject(error); });
  });
  const ringing = nextID('incoming');
  await ring('Alex');
  await ringing;
  const cleared = nextID(null);
  const batch = writeBatch(db);
  batch.update(doc(db, 'calls', 'incoming'), { status: 'declined', updatedAt: serverTimestamp() });
  batch.update(doc(db, 'volunteers', 'helper'), {
    ringingCallId: null, ringingSince: null, lastSeen: serverTimestamp(),
  });
  await assertSucceeds(batch.commit());
  await cleared;
  assert.ok(seen.includes('incoming'));
  assert.equal(seen.at(-1), null);
});
