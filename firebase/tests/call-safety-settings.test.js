import { after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { collection, deleteDoc, doc, getDoc, getDocs, runTransaction, serverTimestamp, setDoc, Timestamp, updateDoc, writeBatch } from 'firebase/firestore';
import { startEnvironment } from './support.js';

const env = await startEnvironment();
beforeEach(() => env.clearFirestore());
after(() => env.cleanup());
const as = uid => env.authenticatedContext(uid).firestore();
async function seed({ consent = true } = {}) {
  await env.withSecurityRulesDisabled(async context => {
    const db = context.firestore(), batch = writeBatch(db);
    for (const [id, role] of [['caller', 'caller'], ['helper', 'volunteer'], ['another', 'caller']]) {
      batch.set(doc(db, 'users', id), { role, displayName: id, languages: ['English'], createdAt: Timestamp.now() });
    }
    batch.set(doc(db, 'volunteers', 'helper'), { displayName: 'Sam', languages: ['English'], bio: '',
      isOnline: true, inCall: false, ringingCallId: null, ringingSince: null,
      lastSeen: Timestamp.fromMillis(Date.now() - 30_000) });
    if (consent) batch.set(doc(db, 'callConsents', 'caller'), { version: 1, acceptedAt: Timestamp.now() });
    batch.set(doc(db, 'callConsents', 'another'), { version: 1, acceptedAt: Timestamp.now() });
    batch.set(doc(db, 'calls', 'past'), { callerId: 'caller', volunteerId: 'helper', status: 'ended',
      roomName: 'call-past', createdAt: Timestamp.now(), updatedAt: Timestamp.now() });
    await batch.commit();
  });
}
function prefs(overrides = {}) { return { onlineByDefault: true, keepScreenAwake: true, updatedAt: serverTimestamp(), ...overrides }; }
function report(overrides = {}) { return { callId: 'past', reporterId: 'caller', subjectId: 'helper', reason: 'other', details: 'Test report', createdAt: serverTimestamp(), ...overrides }; }
function block(db = as('caller')) {
  return setDoc(doc(db, 'users', 'caller', 'blockedVolunteers', 'helper'), { callId: 'past', createdAt: serverTimestamp() });
}
function ring(id = 'next', caller = 'caller') {
  const db = as(caller), batch = writeBatch(db);
  batch.set(doc(db, 'calls', id), { callerId: caller, volunteerId: 'helper', status: 'ringing', roomName: `call-${id}`,
    createdAt: serverTimestamp(), updatedAt: serverTimestamp() });
  batch.update(doc(db, 'volunteers', 'helper'), { ringingCallId: id, ringingSince: serverTimestamp() });
  return batch.commit();
}
function accept(id) {
  const db = as('helper'), batch = writeBatch(db);
  batch.update(doc(db, 'calls', id), { status: 'accepted', updatedAt: serverTimestamp() });
  batch.update(doc(db, 'volunteers', 'helper'), { inCall: true, ringingCallId: null, ringingSince: null, lastSeen: serverTimestamp() });
  return batch.commit();
}

test('settings persist for the same volunteer across fresh clients', async () => {
  await seed();
  await assertSucceeds(setDoc(doc(as('helper'), 'volunteerSettings', 'helper'), prefs()));
  await assertSucceeds(updateDoc(doc(as('helper'), 'volunteerSettings', 'helper'), prefs({ onlineByDefault: false, keepScreenAwake: false })));
  const stored = (await assertSucceeds(getDoc(doc(as('helper'), 'volunteerSettings', 'helper')))).data();
  assert.equal(stored.onlineByDefault, false); assert.equal(stored.keepScreenAwake, false);
});
test('settings are private to their owner and require the volunteer role', async () => {
  await seed();
  await assertSucceeds(setDoc(doc(as('helper'), 'volunteerSettings', 'helper'), prefs()));
  await assertFails(getDoc(doc(as('caller'), 'volunteerSettings', 'helper')));
  await assertFails(setDoc(doc(as('caller'), 'volunteerSettings', 'helper'), prefs()));
  await assertFails(setDoc(doc(as('caller'), 'volunteerSettings', 'caller'), prefs()));
  await assertFails(getDocs(collection(as('helper'), 'volunteerSettings')));
});
for (const bad of [{ onlineByDefault: 'true' }, { keepScreenAwake: null }, { updatedAt: Timestamp.now() }, { admin: true }]) {
  test(`reject invalid settings ${JSON.stringify(bad)}`, async () => {
    await seed(); await assertFails(setDoc(doc(as('helper'), 'volunteerSettings', 'helper'), prefs(bad)));
  });
}
test('profile edits preserve account creation date and can refresh directory without clearing call state', async () => {
  await seed();
  const before = (await getDoc(doc(as('helper'), 'users', 'helper'))).data();
  await assertSucceeds(updateDoc(doc(as('helper'), 'users', 'helper'), { displayName: 'Sam Kim', languages: ['English', 'Korean'] }));
  await assertSucceeds(updateDoc(doc(as('helper'), 'volunteers', 'helper'), { displayName: 'Sam Kim', languages: ['English', 'Korean'], lastSeen: serverTimestamp() }));
  const after = (await getDoc(doc(as('helper'), 'users', 'helper'))).data();
  assert.ok(before.createdAt.isEqual(after.createdAt)); assert.deepEqual(after.languages, ['English', 'Korean']);
  assert.equal((await getDoc(doc(as('helper'), 'volunteers', 'helper'))).data().ringingCallId, null);
});
test('both participants can submit a safety report but nobody can read or mutate reports from the app', async () => {
  await seed();
  await assertSucceeds(setDoc(doc(as('caller'), 'callSafetyReports', 'one'), report()));
  await assertSucceeds(setDoc(doc(as('helper'), 'callSafetyReports', 'two'), report({ reporterId: 'helper', subjectId: 'caller' })));
  for (const uid of ['caller', 'helper', 'another']) await assertFails(getDoc(doc(as(uid), 'callSafetyReports', 'one')));
  await assertFails(getDocs(collection(as('caller'), 'callSafetyReports')));
  await assertFails(updateDoc(doc(as('caller'), 'callSafetyReports', 'one'), { details: 'edited' }));
  await assertFails(deleteDoc(doc(as('caller'), 'callSafetyReports', 'one')));
});
for (const bad of [{ reporterId: 'another' }, { subjectId: 'stranger' }, { callId: 'missing' }, { details: 'x'.repeat(2001) }, { reason: 'unsupported' }, { admin: true }]) {
  test(`reject invalid safety report ${Object.keys(bad)[0]}`, async () => {
    await seed(); await assertFails(setDoc(doc(as('caller'), 'callSafetyReports', 'invalid'), report(bad)));
  });
}
// The rules' size() counts UTF-16 code units, and the app counts details the same way:
// an emoji outside the BMP is 2, a Korean syllable is 1.
test('report details are limited to 2000 UTF-16 code units', async () => {
  await seed();
  await assertSucceeds(setDoc(doc(as('caller'), 'callSafetyReports', 'emoji'), report({ details: '\u{1F600}'.repeat(1000) })));
  await assertFails(setDoc(doc(as('caller'), 'callSafetyReports', 'emoji-over'), report({ details: '\u{1F600}'.repeat(1001) })));
  await assertSucceeds(setDoc(doc(as('caller'), 'callSafetyReports', 'korean'), report({ details: '\uD55C'.repeat(2000) })));
});
test('an outsider and a signed-out client cannot fabricate reports', async () => {
  await seed();
  await assertFails(setDoc(doc(as('another'), 'callSafetyReports', 'bad'), report({ reporterId: 'another' })));
  await assertFails(setDoc(doc(env.unauthenticatedContext().firestore(), 'callSafetyReports', 'anon'), report()));
});
test('caller block persists and prevents even a forced/preferred match; another caller can still ring', async () => {
  await seed(); await assertSucceeds(block());
  assert.ok((await getDoc(doc(as('caller'), 'users', 'caller', 'blockedVolunteers', 'helper'))).exists());
  assert.equal((await getDocs(collection(as('caller'), 'users', 'caller', 'blockedVolunteers'))).size, 1);
  await assertFails(ring());
  await assertSucceeds(ring('different-caller', 'another'));
});
test('only the caller can create a block, and it must refer to their call with that volunteer', async () => {
  await seed();
  await assertFails(block(as('helper')));
  await assertFails(block(as('another')));
  await assertFails(setDoc(doc(as('caller'), 'users', 'caller', 'blockedVolunteers', 'stranger'), { callId: 'past', createdAt: serverTimestamp() }));
});
test('target can get only its block verdict, cannot list blockers or read caller private profile', async () => {
  await seed(); await block();
  await assertSucceeds(getDoc(doc(as('helper'), 'users', 'caller', 'blockedVolunteers', 'helper')));
  await assertFails(getDocs(collection(as('helper'), 'users', 'caller', 'blockedVolunteers')));
  await assertFails(getDoc(doc(as('helper'), 'users', 'caller')));
  await assertFails(getDoc(doc(as('another'), 'users', 'caller', 'blockedVolunteers', 'helper')));
  await assertFails(updateDoc(doc(as('caller'), 'users', 'caller', 'blockedVolunteers', 'helper'), { callId: 'new' }));
  await assertFails(deleteDoc(doc(as('caller'), 'users', 'caller', 'blockedVolunteers', 'helper')));
});
test('a block committed after ring creation prevents later acceptance', async () => {
  await seed(); await ring(); await block();
  await assertFails(accept('next'));
});
test('one atomic batch cannot create a block and ring the same volunteer', async () => {
  await seed();
  const db = as('caller'), batch = writeBatch(db);
  batch.set(doc(db, 'users', 'caller', 'blockedVolunteers', 'helper'), { callId: 'past', createdAt: serverTimestamp() });
  batch.set(doc(db, 'calls', 'same-batch'), { callerId: 'caller', volunteerId: 'helper', status: 'ringing', roomName: 'call-same-batch', createdAt: serverTimestamp(), updatedAt: serverTimestamp() });
  batch.update(doc(db, 'volunteers', 'helper'), { ringingCallId: 'same-batch', ringingSince: serverTimestamp() });
  await assertFails(batch.commit());
});
test('block-versus-match transaction rechecks the block and never permits acceptance after it commits', async () => {
  await seed();
  const db = as('caller');
  const matching = runTransaction(db, async tx => {
    const blockRef = doc(db, 'users', 'caller', 'blockedVolunteers', 'helper');
    if ((await tx.get(blockRef)).exists()) throw new Error('blocked');
    await tx.get(doc(db, 'volunteers', 'helper'));
    tx.set(doc(db, 'calls', 'racing'), { callerId: 'caller', volunteerId: 'helper', status: 'ringing', roomName: 'call-racing', createdAt: serverTimestamp(), updatedAt: serverTimestamp() });
    tx.update(doc(db, 'volunteers', 'helper'), { ringingCallId: 'racing', ringingSince: serverTimestamp() });
  });
  const results = await Promise.allSettled([matching, block()]);
  assert.equal(results[1].status, 'fulfilled');
  if (results[0].status === 'fulfilled') await assertFails(accept('racing'));
});
test('no caller consent means no ringing, even with an approved online volunteer', async () => {
  await seed({ consent: false }); await assertFails(ring());
  await assertSucceeds(setDoc(doc(as('caller'), 'callConsents', 'caller'), { version: 1, acceptedAt: serverTimestamp() }));
  await assertSucceeds(ring());
});
test('consent cannot be forged for another user, backdated or silently changed', async () => {
  await seed({ consent: false });
  await assertFails(setDoc(doc(as('another'), 'callConsents', 'caller'), { version: 1, acceptedAt: serverTimestamp() }));
  await assertFails(setDoc(doc(as('caller'), 'callConsents', 'caller'), { version: 2, acceptedAt: serverTimestamp() }));
  await assertFails(setDoc(doc(as('caller'), 'callConsents', 'caller'), { version: 1, acceptedAt: Timestamp.now() }));
  await assertSucceeds(setDoc(doc(as('caller'), 'callConsents', 'caller'), { version: 1, acceptedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(as('caller'), 'callConsents', 'caller'), { version: 2 }));
  await assertFails(getDoc(doc(as('helper'), 'callConsents', 'caller')));
});
// Demo: no invites. Signing up as a volunteer is enough to go Online and be rung.
test('any volunteer account can go online and take a call without an invitation', async () => {
  await seed();
  await env.withSecurityRulesDisabled(async context => { await deleteDoc(doc(context.firestore(), 'volunteers', 'helper')); });
  await assertSucceeds(setDoc(doc(as('helper'), 'volunteers', 'helper'), { displayName: 'Sam', languages: ['English'], bio: '', isOnline: true, inCall: false, lastSeen: serverTimestamp() }));
  await assertSucceeds(ring());
  await assertSucceeds(accept('next'));
});
test('a caller account cannot list itself as a volunteer or be rung', async () => {
  await seed();
  await env.withSecurityRulesDisabled(async context => {
    const db = context.firestore();
    await deleteDoc(doc(db, 'volunteers', 'helper'));
    await updateDoc(doc(db, 'users', 'helper'), { role: 'caller' });
  });
  await assertFails(setDoc(doc(as('helper'), 'volunteers', 'helper'), { displayName: 'Sam', languages: ['English'], bio: '', isOnline: true, inCall: false, lastSeen: serverTimestamp() }));
});

test('saving profile and preferences while ringing preserves the incoming call', async () => {
  await seed(); await ring('profile-ring');
  const db = as('helper');
  await assertSucceeds(setDoc(doc(db, 'volunteerSettings', 'helper'), prefs({ keepScreenAwake: false })));
  await assertSucceeds(updateDoc(doc(db, 'users', 'helper'), { displayName: 'New name', languages: ['Korean'] }));
  await assertSucceeds(updateDoc(doc(db, 'volunteers', 'helper'), { displayName: 'New name', languages: ['Korean'], lastSeen: serverTimestamp() }));
  const volunteer = (await getDoc(doc(db, 'volunteers', 'helper'))).data();
  assert.equal(volunteer.ringingCallId, 'profile-ring');
  assert.equal(volunteer.inCall, false);
  await assertSucceeds(accept('profile-ring'));
});
test('profile refresh during an accepted call does not free the volunteer for another match', async () => {
  await seed(); await ring('active-profile'); await accept('active-profile');
  const db = as('helper');
  await assertSucceeds(updateDoc(doc(db, 'volunteers', 'helper'), { displayName: 'Sam Kim', languages: ['Korean'], lastSeen: serverTimestamp() }));
  assert.equal((await getDoc(doc(db, 'volunteers', 'helper'))).data().inCall, true);
  await assertFails(ring('should-not-ring', 'another'));
});
test('a missed ringing call cannot be used to fabricate a completed-call report or block', async () => {
  await seed(); await ring('not-accepted');
  await assertFails(setDoc(doc(as('caller'), 'callSafetyReports', 'missed'), report({ callId: 'not-accepted' })));
  await assertFails(setDoc(doc(as('caller'), 'users', 'caller', 'blockedVolunteers', 'helper'), { callId: 'not-accepted', createdAt: serverTimestamp() }));
});
test('a volunteer can always turn Offline', async () => {
  await seed();
  await assertSucceeds(updateDoc(doc(as('helper'), 'volunteers', 'helper'), { isOnline: false, lastSeen: serverTimestamp() }));
  assert.equal((await getDoc(doc(as('helper'), 'volunteers', 'helper'))).data().isOnline, false);
});
