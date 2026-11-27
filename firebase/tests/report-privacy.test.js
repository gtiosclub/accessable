import assert from 'node:assert/strict';
import { after, beforeEach, test } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  collection, deleteDoc, doc, getDoc, getDocs, serverTimestamp, setDoc, Timestamp, writeBatch,
} from 'firebase/firestore';
import {
  createReport, MINUTE, reportData, seedLegacyReport, seedReport, stampData, startEnvironment, vote,
} from './support.js';

const env = await startEnvironment();
beforeEach(() => env.clearFirestore());
after(() => env.cleanup());

const alice = () => env.authenticatedContext('alice').firestore();
const bob = () => env.authenticatedContext('bob').firestore();

test('a report is created with its reporter named only in their private record', async () => {
  await assertSucceeds(createReport(alice(), 'alice', 'r1'));
  await assertSucceeds(getDoc(doc(alice(), 'users', 'alice', 'reports', 'r1')));
});

test('a report cannot be created without its private record', async () => {
  await assertFails(createReport(alice(), 'alice', 'r1', {}, { own: false }));
});

test('a report cannot name its reporter', async () => {
  await assertFails(createReport(alice(), 'alice', 'r1', { reporterID: 'alice' }));
  await assertFails(createReport(alice(), 'alice', 'r1', { reporterID: 'bob' }));
});

test('a report cannot leave out the empty reporter that older apps read', async () => {
  const { reporterID, ...rest } = reportData('r1');
  const db = alice();
  const batch = writeBatch(db);
  batch.set(doc(db, 'reports', 'r1'), rest);
  batch.set(doc(db, 'rateLimits', 'alice'), stampData('r1'), { merge: true });
  batch.set(doc(db, 'users', 'alice', 'reports', 'r1'), { createdAt: serverTimestamp() });
  await assertFails(batch.commit());
});

test("no one else can read or list a user's reports", async () => {
  await seedReport(env, 'alice', 'r1');
  await assertSucceeds(getDocs(collection(alice(), 'users', 'alice', 'reports')));
  await assertFails(getDoc(doc(bob(), 'users', 'alice', 'reports', 'r1')));
  await assertFails(getDocs(collection(bob(), 'users', 'alice', 'reports')));
});

test("a private record cannot be made for someone else's report or another user", async () => {
  const db = alice();
  const forBob = writeBatch(db);
  forBob.set(doc(db, 'reports', 'r1'), reportData('r1'));
  forBob.set(doc(db, 'rateLimits', 'alice'), stampData('r1'), { merge: true });
  forBob.set(doc(db, 'users', 'bob', 'reports', 'r1'), { createdAt: serverTimestamp() });
  await assertFails(forBob.commit());

  await seedReport(env, 'bob', 'r2');
  await assertFails(setDoc(doc(alice(), 'users', 'alice', 'reports', 'r2'), { createdAt: serverTimestamp() }));
});

test('a private record is made only with its report, and holds only its time', async () => {
  await assertFails(setDoc(doc(alice(), 'users', 'alice', 'reports', 'r1'), { createdAt: serverTimestamp() }));
  const db = alice();
  const extra = writeBatch(db);
  extra.set(doc(db, 'reports', 'r1'), reportData('r1'));
  extra.set(doc(db, 'rateLimits', 'alice'), stampData('r1'), { merge: true });
  extra.set(doc(db, 'users', 'alice', 'reports', 'r1'), { createdAt: serverTimestamp(), latitude: 33.7756 });
  await assertFails(extra.commit());
  const phoneTime = writeBatch(db);
  phoneTime.set(doc(db, 'reports', 'r1'), reportData('r1'));
  phoneTime.set(doc(db, 'rateLimits', 'alice'), stampData('r1'), { merge: true });
  phoneTime.set(doc(db, 'users', 'alice', 'reports', 'r1'), { createdAt: Timestamp.now() });
  await assertFails(phoneTime.commit());
});

test('a private record cannot be changed', async () => {
  await seedReport(env, 'alice', 'r1');
  await assertFails(setDoc(doc(alice(), 'users', 'alice', 'reports', 'r1'), { createdAt: serverTimestamp() }));
});

test('the reporter cannot vote on their own report, but someone else can', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  await assertFails(vote(alice(), 'alice', 'r1', true));
  await assertFails(vote(alice(), 'alice', 'r1', false));
  await assertSucceeds(vote(bob(), 'bob', 'r1', true));
});

test('the reporter can delete their report and its record together; someone else cannot', async () => {
  await seedReport(env, 'alice', 'r1');
  await assertFails(deleteDoc(doc(bob(), 'reports', 'r1')));
  await assertFails(deleteDoc(doc(bob(), 'users', 'alice', 'reports', 'r1')));
  const db = alice();
  const batch = writeBatch(db);
  batch.delete(doc(db, 'reports', 'r1'));
  batch.delete(doc(db, 'users', 'alice', 'reports', 'r1'));
  await assertSucceeds(batch.commit());
  await env.withSecurityRulesDisabled(async (context) => {
    const admin = context.firestore();
    assert.equal((await getDoc(doc(admin, 'reports', 'r1'))).exists(), false);
    assert.equal((await getDoc(doc(admin, 'users', 'alice', 'reports', 'r1'))).exists(), false);
  });
});

test('a record cannot be deleted while its report exists, so the reporter still cannot vote', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  await assertFails(deleteDoc(doc(alice(), 'users', 'alice', 'reports', 'r1')));
  await assertFails(vote(alice(), 'alice', 'r1', true));
});

test("a record can be deleted once its report has gone", async () => {
  await seedReport(env, 'alice', 'r1');
  await env.withSecurityRulesDisabled(async (context) => {
    await deleteDoc(doc(context.firestore(), 'reports', 'r1'));
  });
  await assertSucceeds(deleteDoc(doc(alice(), 'users', 'alice', 'reports', 'r1')));
});

test('a report from before the private records still holds back its reporter, who can delete it', async () => {
  await seedLegacyReport(env, 'alice', 'r1');
  await assertFails(vote(alice(), 'alice', 'r1', true));
  await assertFails(deleteDoc(doc(bob(), 'reports', 'r1')));
  await assertSucceeds(vote(bob(), 'bob', 'r1', true));
  await assertSucceeds(deleteDoc(doc(alice(), 'reports', 'r1')));
});
