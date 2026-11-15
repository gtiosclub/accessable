import { after, beforeEach, test } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  collection, deleteDoc, doc, getDoc, getDocs, limit, query, serverTimestamp, setDoc, Timestamp, updateDoc,
  writeBatch,
} from 'firebase/firestore';
import { createReport, DAY, reportData, seedReport, stampData, startEnvironment } from './support.js';

const env = await startEnvironment();
beforeEach(() => env.clearFirestore());
after(() => env.cleanup());

const alice = () => env.authenticatedContext('alice').firestore();
const bob = () => env.authenticatedContext('bob').firestore();

test('a signed-in user can create a report with its rate-limit stamp', async () => {
  await assertSucceeds(createReport(alice(), 'alice', 'r1'));
});

test('a report with an area outline can be created', async () => {
  const area = [
    { latitude: 33.775, longitude: -84.396 },
    { latitude: 33.776, longitude: -84.396 },
    { latitude: 33.776, longitude: -84.397 },
  ];
  await assertSucceeds(createReport(alice(), 'alice', 'r1', { area }));
});

test('a report cannot be created without the rate-limit stamp', async () => {
  const db = alice();
  await assertFails(setDoc(doc(db, 'reports', 'r1'), reportData('alice', 'r1')));
});

test('a report cannot name another user as its reporter', async () => {
  await assertFails(createReport(alice(), 'alice', 'r1', { reporterID: 'bob' }));
});

test("a report's id must match its document ID", async () => {
  await assertFails(createReport(alice(), 'alice', 'r1', { id: 'other' }));
});

test("a report's creation time must be the server's, not the phone's", async () => {
  await assertFails(createReport(alice(), 'alice', 'r1', { createdAt: Timestamp.fromMillis(Date.now() - 1000) }));
});

test('a report cannot start with confirmations', async () => {
  await assertFails(createReport(alice(), 'alice', 'r1', { confirmations: 5 }));
});

test('a report cannot have an unknown kind', async () => {
  await assertFails(createReport(alice(), 'alice', 'r1', { kind: 'pothole' }));
});

test('a report cannot have a coordinate off the globe', async () => {
  await assertFails(createReport(alice(), 'alice', 'r1', { coordinate: { latitude: 91, longitude: 0 } }));
  await assertFails(createReport(alice(), 'alice', 'r1', { coordinate: { latitude: 0, longitude: 181 } }));
});

test('a report cannot expire in the past or more than 30 days out', async () => {
  await assertFails(createReport(alice(), 'alice', 'r1', { expiresAt: Timestamp.fromMillis(Date.now() - 1000) }));
  await assertFails(createReport(alice(), 'alice', 'r1', { expiresAt: Timestamp.fromMillis(Date.now() + 31 * DAY) }));
});

test('an area must have 3 to 10 valid points', async () => {
  const point = { latitude: 33.775, longitude: -84.396 };
  await assertFails(createReport(alice(), 'alice', 'r1', { area: [point, point] }));
  await assertFails(createReport(alice(), 'alice', 'r1', { area: Array(11).fill(point) }));
  await assertFails(createReport(alice(), 'alice', 'r1', { area: [point, point, { latitude: 95, longitude: 0 }] }));
});

test('a report cannot carry extra fields such as personal data', async () => {
  await assertFails(createReport(alice(), 'alice', 'r1', { email: 'alice@example.com' }));
  await assertFails(createReport(alice(), 'alice', 'r1', { coordinate: { latitude: 0, longitude: 0, name: 'Alice' } }));
});

test('one batch cannot create more than one report', async () => {
  const db = alice();
  const batch = writeBatch(db);
  batch.set(doc(db, 'reports', 'r1'), reportData('alice', 'r1'));
  batch.set(doc(db, 'reports', 'r2'), reportData('alice', 'r2'));
  batch.set(doc(db, 'rateLimits', 'alice'), stampData('r1'));
  await assertFails(batch.commit());
});

test('a second report within a minute is rejected', async () => {
  await seedReport(env, 'alice', 'r1', 30 * 1000);
  await assertFails(createReport(alice(), 'alice', 'r2'));
});

test('a second report after a minute is accepted', async () => {
  await seedReport(env, 'alice', 'r1', 2 * 60 * 1000);
  await assertSucceeds(createReport(alice(), 'alice', 'r2'));
});

test("one user's rate limit does not hold back another user", async () => {
  await seedReport(env, 'alice', 'r1', 30 * 1000);
  await assertSucceeds(createReport(bob(), 'bob', 'r2'));
});

test("a user cannot write someone else's rate-limit stamp", async () => {
  await assertFails(setDoc(doc(bob(), 'rateLimits', 'alice'), stampData('r1')));
});

test('a rate-limit stamp cannot hold extra fields or a phone-clock time', async () => {
  const db = alice();
  await assertFails(setDoc(doc(db, 'rateLimits', 'alice'), { ...stampData('r1'), email: 'alice@example.com' }));
  await assertFails(setDoc(doc(db, 'rateLimits', 'alice'), { ...stampData('r1'), lastReportAt: Timestamp.now() }));
});

test('signed-in users can read reports with a limit of at most 200', async () => {
  await seedReport(env, 'alice', 'r1');
  const db = bob();
  await assertSucceeds(getDoc(doc(db, 'reports', 'r1')));
  await assertSucceeds(getDocs(query(collection(db, 'reports'), limit(200))));
  await assertFails(getDocs(query(collection(db, 'reports'), limit(201))));
  await assertFails(getDocs(collection(db, 'reports')));
});

test('the reporter can change kind, coordinate, area and expiry', async () => {
  await seedReport(env, 'alice', 'r1');
  await assertSucceeds(updateDoc(doc(alice(), 'reports', 'r1'), {
    kind: 'blockedPath',
    coordinate: { latitude: 33.78, longitude: -84.4 },
    expiresAt: Timestamp.now(),
  }));
});

test('the reporter cannot change id, reporter, creation time or confirmations', async () => {
  await seedReport(env, 'alice', 'r1');
  const report = doc(alice(), 'reports', 'r1');
  await assertFails(updateDoc(report, { id: 'r2' }));
  await assertFails(updateDoc(report, { reporterID: 'bob' }));
  await assertFails(updateDoc(report, { createdAt: serverTimestamp() }));
  await assertFails(updateDoc(report, { confirmations: 1 }));
});

test('an update must still be a valid report', async () => {
  await seedReport(env, 'alice', 'r1');
  const report = doc(alice(), 'reports', 'r1');
  await assertFails(updateDoc(report, { kind: 'pothole' }));
  await assertFails(updateDoc(report, { expiresAt: Timestamp.fromMillis(Date.now() + 31 * DAY) }));
});

test("a user cannot edit or delete someone else's report", async () => {
  await seedReport(env, 'alice', 'r1');
  const report = doc(bob(), 'reports', 'r1');
  await assertFails(updateDoc(report, { kind: 'other' }));
  await assertFails(deleteDoc(report));
});

test('the reporter can delete their own report', async () => {
  await seedReport(env, 'alice', 'r1');
  await assertSucceeds(deleteDoc(doc(alice(), 'reports', 'r1')));
});
