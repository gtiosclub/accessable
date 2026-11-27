import { after, beforeEach, test } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  Timestamp, collection, deleteDoc, doc, getDoc, getDocs, limit, query,
  serverTimestamp, setDoc, updateDoc,
} from 'firebase/firestore';
import { startEnvironment, seedCallPrerequisites } from './support.js';

const env = await startEnvironment();
beforeEach(() => env.clearFirestore());
after(() => env.cleanup());

const dbAs = (uid) => env.authenticatedContext(uid).firestore();
const signedOutDB = () => env.unauthenticatedContext().firestore();

const volunteer = (overrides = {}) => ({
  displayName: 'Sam',
  languages: ['English'],
  bio: '',
  isOnline: true,
  inCall: false,
  lastSeen: serverTimestamp(),
  ...overrides,
});

// Writes directly, skipping the rules.
async function seed(path, id, data) {
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), path, id), data);
  });
}

const seedRole = async (uid, role) => {
  if (role === 'volunteer') await seedCallPrerequisites(env, 'fixture-caller', uid);
  return seed('users', uid, { role, displayName: 'Sam', languages: ['English'], createdAt: Timestamp.now() });
};

// A volunteer document whose last heartbeat was `secondsAgo` seconds ago.
const seedVolunteer = async (uid, secondsAgo = 0) => {
  await seedCallPrerequisites(env, 'fixture-caller', uid);
  return seed('volunteers', uid, volunteer({ lastSeen: Timestamp.fromMillis(Date.now() - secondsAgo * 1000) }));
};

test('signed-out users cannot read volunteers', async () => {
  await seedVolunteer('sam');
  await assertFails(getDoc(doc(signedOutDB(), 'volunteers', 'sam')));
});

test('signed-in users can read a volunteer and list up to 100', async () => {
  await seedVolunteer('sam');
  const db = dbAs('alice');
  await assertSucceeds(getDoc(doc(db, 'volunteers', 'sam')));
  await assertSucceeds(getDocs(query(collection(db, 'volunteers'), limit(100))));
});

test('listing needs a limit of at most 100', async () => {
  const db = dbAs('alice');
  await assertFails(getDocs(collection(db, 'volunteers')));
  await assertFails(getDocs(query(collection(db, 'volunteers'), limit(101))));
});

test('a volunteer can create their own document', async () => {
  await seedRole('sam', 'volunteer');
  await assertSucceeds(setDoc(doc(dbAs('sam'), 'volunteers', 'sam'), volunteer()));
});

test('callers cannot add themselves to the directory', async () => {
  await seedRole('carl', 'caller');
  await assertFails(setDoc(doc(dbAs('carl'), 'volunteers', 'carl'), volunteer()));
});

test("nobody can create or edit someone else's document", async () => {
  await seedRole('sam', 'volunteer');
  await assertFails(setDoc(doc(dbAs('eve'), 'volunteers', 'sam'), volunteer()));
  await seedVolunteer('sam', 120);
  await assertFails(updateDoc(doc(dbAs('eve'), 'volunteers', 'sam'), {
    isOnline: false, lastSeen: serverTimestamp(),
  }));
});

test('lastSeen must be the server time, so nobody can fake being online', async () => {
  await seedRole('sam', 'volunteer');
  const future = Timestamp.fromMillis(Date.now() + 365 * 24 * 60 * 60 * 1000);
  await assertFails(setDoc(doc(dbAs('sam'), 'volunteers', 'sam'), volunteer({ lastSeen: future })));
});

test('extra fields such as an email are rejected', async () => {
  await seedRole('sam', 'volunteer');
  await assertFails(setDoc(doc(dbAs('sam'), 'volunteers', 'sam'), volunteer({ email: 'sam@example.com' })));
});

test('a volunteer can turn Online off at any time', async () => {
  await seedVolunteer('sam');
  await assertSucceeds(updateDoc(doc(dbAs('sam'), 'volunteers', 'sam'), {
    isOnline: false, lastSeen: serverTimestamp(),
  }));
});

test('heartbeats closer than 20 seconds apart are rejected', async () => {
  await seedVolunteer('sam', 5);
  await assertFails(updateDoc(doc(dbAs('sam'), 'volunteers', 'sam'), { lastSeen: serverTimestamp() }));
});

test('a heartbeat 30 seconds after the last one is allowed', async () => {
  await seedVolunteer('sam', 30);
  await assertSucceeds(updateDoc(doc(dbAs('sam'), 'volunteers', 'sam'), { lastSeen: serverTimestamp() }));
});

test('a volunteer can delete their own document but not anyone else\'s', async () => {
  await seedVolunteer('sam');
  await assertFails(deleteDoc(doc(dbAs('eve'), 'volunteers', 'sam')));
  await assertSucceeds(deleteDoc(doc(dbAs('sam'), 'volunteers', 'sam')));
});
