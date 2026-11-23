import { after, beforeEach, test } from 'node:test';
import { assertFails } from '@firebase/rules-unit-testing';
import { collection, deleteDoc, doc, getDoc, getDocs, limit, query, setDoc } from 'firebase/firestore';
import { createReport, seedReport, stampData, startEnvironment } from './support.js';

const env = await startEnvironment();
beforeEach(() => env.clearFirestore());
after(() => env.cleanup());

test('a collection with no rules can be neither read nor written', async () => {
  const db = env.authenticatedContext('alice').firestore();
  await assertFails(getDoc(doc(db, 'unconfiguredCollection', 'alice')));
  await assertFails(setDoc(doc(db, 'unconfiguredCollection', 'alice'), { name: 'Alice' }));
});

test('a signed-out user cannot read reports', async () => {
  await seedReport(env, 'alice', 'r1');
  const db = env.unauthenticatedContext().firestore();
  await assertFails(getDoc(doc(db, 'reports', 'r1')));
  await assertFails(getDocs(query(collection(db, 'reports'), limit(10))));
});

test('a signed-out user cannot write a report or a rate-limit stamp', async () => {
  const db = env.unauthenticatedContext().firestore();
  await assertFails(createReport(db, 'alice', 'r1'));
  await assertFails(setDoc(doc(db, 'rateLimits', 'alice'), stampData('r1')));
});

test("a user cannot read someone else's rate-limit stamp", async () => {
  await seedReport(env, 'alice', 'r1');
  const db = env.authenticatedContext('bob').firestore();
  await assertFails(getDoc(doc(db, 'rateLimits', 'alice')));
});

test('a rate-limit stamp cannot be deleted', async () => {
  await seedReport(env, 'alice', 'r1');
  const db = env.authenticatedContext('alice').firestore();
  await assertFails(deleteDoc(doc(db, 'rateLimits', 'alice')));
});
