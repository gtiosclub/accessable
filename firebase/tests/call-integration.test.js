import { after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { collection, deleteDoc, doc, getDoc, getDocs, runTransaction, serverTimestamp, setDoc, Timestamp, updateDoc, writeBatch } from 'firebase/firestore';
import { startEnvironment, seedCallPrerequisites } from './support.js';

const env = await startEnvironment();
beforeEach(() => env.clearFirestore());
after(() => env.cleanup());
const as = uid => env.authenticatedContext(uid).firestore();
async function seed(overrides = {}) {
  await seedCallPrerequisites(env, 'caller', 'helper');
  await env.withSecurityRulesDisabled(async context => {
    const db = context.firestore();
    await setDoc(doc(db, 'users', 'helper'), { role: 'volunteer', displayName: 'Sam', languages: ['English'], createdAt: Timestamp.now() });
    await setDoc(doc(db, 'volunteers', 'helper'), {
      displayName: 'Sam', languages: ['English'], bio: '', isOnline: true, inCall: false,
      lastSeen: Timestamp.now(), ringingCallId: null, ringingSince: null, ...overrides,
    });
  });
}
function data(id) {
  return { callerId: 'caller', volunteerId: 'helper', status: 'ringing', roomName: `call-${id}`,
    createdAt: serverTimestamp(), updatedAt: serverTimestamp() };
}
async function ring(id) {
  const db = as('caller');
  await runTransaction(db, async tx => {
    const ref = doc(db, 'volunteers', 'helper');
    const current = (await tx.get(ref)).data();
    assert.equal(current.inCall, false); assert.equal(current.ringingCallId, null);
    tx.set(doc(db, 'calls', id), data(id));
    tx.update(ref, { ringingCallId: id, ringingSince: serverTimestamp() });
  });
}
test('five complete matching cycles reuse the same volunteer without resetting state', async () => {
  await seed();
  for (let i = 1; i <= 5; i++) {
    const id = `cycle-${i}`;
    await assertSucceeds(ring(id));
    const db = as('helper');
    await assertSucceeds(runTransaction(db, async tx => {
      const call = doc(db, 'calls', id), volunteer = doc(db, 'volunteers', 'helper');
      assert.equal((await tx.get(call)).data().status, 'ringing');
      assert.equal((await tx.get(volunteer)).data().ringingCallId, id);
      tx.update(call, { status: 'accepted', updatedAt: serverTimestamp() });
      tx.update(volunteer, { inCall: true, ringingCallId: null, ringingSince: null, lastSeen: serverTimestamp() });
    }));
    await assertFails(getDoc(doc(as('outsider'), 'calls', id)));
    // Either side may hang up. The volunteer observes remote departure and frees itself.
    if (i % 2) await assertSucceeds(updateDoc(doc(as('caller'), 'calls', id), { status: 'ended', updatedAt: serverTimestamp() }));
    const batch = writeBatch(db);
    if (!(i % 2)) batch.update(doc(db, 'calls', id), { status: 'ended', updatedAt: serverTimestamp() });
    batch.update(doc(db, 'volunteers', 'helper'), { inCall: false, ringingCallId: null, ringingSince: null, lastSeen: serverTimestamp() });
    await assertSucceeds(batch.commit());
    const current = (await getDoc(doc(db, 'volunteers', 'helper'))).data();
    assert.equal(current.inCall, false); assert.equal(current.ringingCallId, null);
    assert.equal((await getDoc(doc(as('caller'), 'calls', id))).data().status, 'ended');
  }
});
test('call collections cannot be listed, even by a caller', async () => {
  await seed(); await ring('private');
  await assertFails(getDocs(collection(as('caller'), 'calls')));
  await assertFails(getDocs(collection(env.unauthenticatedContext().firestore(), 'calls')));
});
test('a standalone call create cannot set ringing without a paired reservation', async () => {
  await seed();
  await assertFails(setDoc(doc(as('caller'), 'calls', 'forged'), data('forged')));
});
test('the volunteer cannot forge their own reservation or clear one without an answer', async () => {
  await seed();
  await assertFails(updateDoc(doc(as('helper'), 'volunteers', 'helper'), {
    inCall: true, lastSeen: serverTimestamp(),
  }));
  await assertFails(updateDoc(doc(as('helper'), 'volunteers', 'helper'), {
    ringingCallId: 'forged', ringingSince: serverTimestamp(), lastSeen: serverTimestamp(),
  }));
  await ring('real');
  await assertFails(updateDoc(doc(as('helper'), 'volunteers', 'helper'), {
    ringingCallId: null, ringingSince: null, lastSeen: serverTimestamp(),
  }));
});

test('a caller can read their own call but not a different callers call', async () => {
  await seed(); await ring('mine');
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), 'calls', 'someone-elses'), {
      callerId: 'different-caller', volunteerId: 'different-helper', status: 'accepted',
      roomName: 'call-someone-elses', createdAt: Timestamp.now(), updatedAt: Timestamp.now(),
    });
  });
  await assertSucceeds(getDoc(doc(as('caller'), 'calls', 'mine')));
  await assertFails(getDoc(doc(as('caller'), 'calls', 'someone-elses')));
});

test('an ended call cannot be set back to ringing', async () => {
  await seed(); await ring('once');
  await assertSucceeds(updateDoc(doc(as('caller'), 'calls', 'once'), { status: 'ended', updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(as('caller'), 'calls', 'once'), { status: 'ringing', updatedAt: serverTimestamp() }));
});
test('a pre-existing pointer cannot authorize a later standalone call creation', async () => {
  await seed({ ringingCallId: 'preseeded', ringingSince: Timestamp.now() });
  await assertFails(setDoc(doc(as('caller'), 'calls', 'preseeded'), data('preseeded')));
});
test('an old ringing call cannot be reused to refresh a stale reservation', async () => {
  await seed(); await ring('old');
  await env.withSecurityRulesDisabled(async context => {
    await updateDoc(doc(context.firestore(), 'volunteers', 'helper'), { ringingSince: Timestamp.fromMillis(Date.now() - 60_000) });
  });
  await assertFails(updateDoc(doc(as('caller'), 'volunteers', 'helper'), { ringingCallId: 'old', ringingSince: serverTimestamp() }));
});
test('a volunteer cannot create a document already carrying a ring or active call', async () => {
  await seed();
  for (const extra of [{ inCall: true }, { ringingCallId: 'fake', ringingSince: serverTimestamp() }]) {
    await env.withSecurityRulesDisabled(async context => { await deleteDoc(doc(context.firestore(), 'volunteers', 'helper')); });
    const db = as('helper');
    await assertFails(setDoc(doc(db, 'volunteers', 'helper'), {
      displayName: 'Sam', languages: ['English'], bio: '', isOnline: true,
      inCall: false, lastSeen: serverTimestamp(), ...extra,
    }));
  }
});
