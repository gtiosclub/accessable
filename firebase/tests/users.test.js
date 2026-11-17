import { after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { collection, deleteDoc, doc, getDoc, getDocs, serverTimestamp, setDoc, Timestamp, updateDoc } from 'firebase/firestore';
import { startEnvironment } from './support.js';

const env = await startEnvironment();
beforeEach(() => env.clearFirestore());
after(() => env.cleanup());
const profile = (overrides = {}) => ({ role: 'caller', displayName: 'Alice', languages: ['English'], createdAt: serverTimestamp(), ...overrides });
const ownDB = () => env.authenticatedContext('alice').firestore();
async function seed() { const db = ownDB(); await setDoc(doc(db, 'users', 'alice'), profile()); return db; }

test('owner creates, reads, edits and deletes own profile; role survives a new client', async () => {
  const db = await seed();
  const ref = doc(db, 'users', 'alice');
  const before = (await getDoc(ref)).data();
  await assertSucceeds(updateDoc(ref, { role: 'volunteer', displayName: 'Alice K', languages: ['English', 'Korean'] }));
  const reopened = env.authenticatedContext('alice').firestore();
  const after = (await assertSucceeds(getDoc(doc(reopened, 'users', 'alice')))).data();
  assert.equal(after.role, 'volunteer');
  assert.deepEqual(after.languages, ['English', 'Korean']);
  assert.ok(after.createdAt.isEqual(before.createdAt));
  await assertSucceeds(deleteDoc(ref));
});

test('owner can read a missing profile to enter onboarding', async () => {
  const snap = await assertSucceeds(getDoc(doc(ownDB(), 'users', 'alice')));
  assert.equal(snap.exists(), false);
});

test('signed-out clients cannot read, create, update or delete profiles', async () => {
  await seed();
  const db = env.unauthenticatedContext().firestore();
  const ref = doc(db, 'users', 'alice');
  await assertFails(getDoc(ref));
  await assertFails(setDoc(doc(db, 'users', 'new'), profile()));
  await assertFails(updateDoc(ref, { role: 'volunteer' }));
  await assertFails(deleteDoc(ref));
});

test('other accounts cannot read, create, overwrite, update or delete a profile', async () => {
  await seed();
  const db = env.authenticatedContext('bob').firestore();
  const ref = doc(db, 'users', 'alice');
  await assertFails(getDoc(ref));
  await assertFails(setDoc(doc(db, 'users', 'charlie'), profile()));
  await assertFails(setDoc(ref, profile()));
  await assertFails(updateDoc(ref, { displayName: 'Bob' }));
  await assertFails(deleteDoc(ref));
});

test('profiles cannot be enumerated', async () => {
  await seed();
  await assertFails(getDocs(collection(ownDB(), 'users')));
});

test('createdAt must be server time and stays immutable on updates', async () => {
  const db = ownDB();
  await assertFails(setDoc(doc(db, 'users', 'alice'), profile({ createdAt: Timestamp.fromMillis(0) })));
  await seed();
  await assertFails(updateDoc(doc(db, 'users', 'alice'), { createdAt: serverTimestamp() }));
});

for (const [name, overrides] of [
  ['unknown role', { role: 'admin' }], ['missing role', { role: null }],
  ['empty name', { displayName: '' }], ['blank name', { displayName: '   ' }],
  ['long name', { displayName: 'a'.repeat(81) }], ['non-string name', { displayName: 7 }],
  ['empty languages', { languages: [] }], ['not a language list', { languages: 'English' }],
  ['non-string language', { languages: ['English', 42] }], ['blank language', { languages: [' '] }],
  ['long language', { languages: ['a'.repeat(41)] }], ['too many languages', { languages: Array(11).fill('English') }],
  ['last language invalid', { languages: [...Array(9).fill('English'), 42] }],
  ['extra field', { admin: true }], ['invalid timestamp', { createdAt: 'today' }]
]) {
  test(`rejects ${name} on creation and update`, async () => {
    const db = ownDB(); const ref = doc(db, 'users', 'alice');
    await assertFails(setDoc(ref, profile(overrides)));
    await setDoc(ref, profile());
    await assertFails(updateDoc(ref, overrides));
  });
}

test('all four fields are required', async () => {
  const data = profile(); delete data.languages;
  await assertFails(setDoc(doc(ownDB(), 'users', 'alice'), data));
});
