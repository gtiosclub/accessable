import { after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { collection, deleteDoc, doc, getDoc, getDocs, serverTimestamp, setDoc, Timestamp, updateDoc } from 'firebase/firestore';
import { startEnvironment } from './support.js';

const env = await startEnvironment();
beforeEach(() => env.clearFirestore());
after(() => env.cleanup());
const preferences = (overrides = {}) => ({
  avoidStairs: true, avoidElevators: false, avoidSteepHills: false, preferWellLit: false, preferFootpaths: false,
  avoidAlleysAndDriveways: false, avoidServiceRoads: false, avoidUnpavedPaths: false, walkingSpeed: 'normal',
  updatedAt: serverTimestamp(), ...overrides
});
const ownDB = () => env.authenticatedContext('alice').firestore();
const ref = (db, uid = 'alice') => doc(db, 'users', uid, 'settings', 'routePreferences');
async function seed() { const db = ownDB(); await setDoc(ref(db), preferences()); return db; }

test('owner creates, reads, replaces, updates and deletes own route preferences', async () => {
  const db = await seed();
  assert.equal((await assertSucceeds(getDoc(ref(db)))).data().avoidStairs, true);
  await assertSucceeds(setDoc(ref(db), preferences({ avoidStairs: false, walkingSpeed: 'slow' })));
  await assertSucceeds(updateDoc(ref(db), { preferWellLit: true, updatedAt: serverTimestamp() }));
  const after = (await getDoc(ref(env.authenticatedContext('alice').firestore()))).data();
  assert.equal(after.walkingSpeed, 'slow');
  assert.equal(after.preferWellLit, true);
  await assertSucceeds(deleteDoc(ref(db)));
});

test('owner can read missing route preferences', async () => {
  const snap = await assertSucceeds(getDoc(ref(ownDB())));
  assert.equal(snap.exists(), false);
});

test('signed-out clients cannot read or write route preferences', async () => {
  await seed();
  const db = env.unauthenticatedContext().firestore();
  await assertFails(getDoc(ref(db)));
  await assertFails(setDoc(ref(db), preferences()));
  await assertFails(updateDoc(ref(db), { avoidStairs: false, updatedAt: serverTimestamp() }));
  await assertFails(deleteDoc(ref(db)));
});

test('other accounts cannot read, write or delete route preferences', async () => {
  await seed();
  const db = env.authenticatedContext('bob').firestore();
  await assertFails(getDoc(ref(db)));
  await assertFails(setDoc(ref(db), preferences()));
  await assertFails(updateDoc(ref(db), { avoidStairs: false, updatedAt: serverTimestamp() }));
  await assertFails(deleteDoc(ref(db)));
});

test('route preferences cannot be listed', async () => {
  const db = await seed();
  await assertFails(getDocs(collection(db, 'users', 'alice', 'settings')));
});

test('other settings documents stay closed', async () => {
  await assertFails(setDoc(doc(ownDB(), 'users', 'alice', 'settings', 'other'), preferences()));
});

for (const [name, overrides] of [
  ['non-bool preference', { avoidStairs: 'yes' }], ['null preference', { avoidElevators: null }],
  ['unknown walking speed', { walkingSpeed: 'run' }], ['non-string walking speed', { walkingSpeed: 1.2 }],
  ['client time', { updatedAt: Timestamp.fromMillis(0) }], ['extra field', { placeName: 'Home' }]
]) {
  test(`rejects ${name} on creation and update`, async () => {
    const db = ownDB();
    await assertFails(setDoc(ref(db), preferences(overrides)));
    await seed();
    await assertFails(updateDoc(ref(db), { updatedAt: serverTimestamp(), ...overrides }));
  });
}

test('every field is required', async () => {
  const data = preferences(); delete data.avoidUnpavedPaths;
  await assertFails(setDoc(ref(ownDB()), data));
});

test('updatedAt must change to server time on every write', async () => {
  const db = await seed();
  await assertFails(updateDoc(ref(db), { avoidStairs: false }));
});
