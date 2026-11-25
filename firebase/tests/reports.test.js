import assert from 'node:assert/strict';
import { after, beforeEach, test } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  collection, deleteDoc, doc, getDoc, getDocs, increment, limit, query, serverTimestamp, setDoc, Timestamp,
  updateDoc, writeBatch,
} from 'firebase/firestore';
import {
  createReport, DAY, HOUR, MINUTE, reportData, seedReport, seedVoteStamp, stampData, startEnvironment, vote,
} from './support.js';

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

// Votes are the only edits, so a reporter can't undo what they decide.
test('the reporter cannot edit their report', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE, { kind: 'blockedPath', expiresAt: Timestamp.fromMillis(Date.now() + HOUR) });
  const report = doc(alice(), 'reports', 'r1');
  await assertFails(updateDoc(report, { kind: 'construction' }));
  await assertFails(updateDoc(report, { coordinate: { latitude: 33.78, longitude: -84.4 } }));
  await assertFails(updateDoc(report, { expiresAt: Timestamp.fromMillis(Date.now() + 29 * DAY) }));
  await assertFails(updateDoc(report, { expiresAt: Timestamp.now() }));
  await assertFails(updateDoc(report, { id: 'r2' }));
  await assertFails(updateDoc(report, { reporterID: 'bob' }));
  await assertFails(updateDoc(report, { confirmations: 1 }));
});

test('the reporter cannot revive a report voted gone, or move a confirmed one', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  await assertSucceeds(vote(bob(), 'bob', 'r1', true));
  await assertFails(updateDoc(doc(alice(), 'reports', 'r1'), { coordinate: { latitude: 10, longitude: 10 } }));
  await assertSucceeds(vote(env.authenticatedContext('carol').firestore(), 'carol', 'r1', false));
  await assertSucceeds(vote(env.authenticatedContext('dave').firestore(), 'dave', 'r1', false, { report: {
    negativeConfirmations: increment(1), negativesSinceConfirm: increment(1), expiresAt: serverTimestamp(),
  } }));
  await assertFails(updateDoc(doc(alice(), 'reports', 'r1'), { expiresAt: Timestamp.fromMillis(Date.now() + 29 * DAY) }));
});

test("a user cannot edit or delete someone else's report", async () => {
  await seedReport(env, 'alice', 'r1');
  const report = doc(bob(), 'reports', 'r1');
  await assertFails(updateDoc(report, { kind: 'other' }));
  await assertFails(deleteDoc(report));
});

test('a report cannot expire later than its kind lasts', async () => {
  await assertFails(createReport(alice(), 'alice', 'r1', { expiresAt: Timestamp.fromMillis(Date.now() + 8 * DAY) }));
  await assertFails(createReport(alice(), 'alice', 'r2', {
    kind: 'blockedPath', expiresAt: Timestamp.fromMillis(Date.now() + 5 * HOUR),
  }));
  await assertFails(createReport(alice(), 'alice', 'r3', {
    kind: 'elevatorOut', expiresAt: Timestamp.fromMillis(Date.now() + 25 * HOUR),
  }));
});

test('a report can expire up to its kind lifetime', async () => {
  await assertSucceeds(createReport(alice(), 'alice', 'r1', {
    kind: 'elevatorOut', expiresAt: Timestamp.fromMillis(Date.now() + 24 * HOUR),
  }));
});

// The largest area the rules allow, so its checks stay within the rules' expression budget.
const area10 = Array.from({ length: 10 }, (_, i) => ({ latitude: 33.775 + i * 0.0001, longitude: -84.396 - (i % 2) * 0.0001 }));

test('a report with a 10-point area can be created and voted on', async () => {
  await assertSucceeds(createReport(alice(), 'alice', 'r1', { area: area10 }));
  await seedReport(env, 'alice', 'r2', 20 * MINUTE, { area: area10 });
  await assertSucceeds(vote(bob(), 'bob', 'r2', true));
  await assertSucceeds(vote(env.authenticatedContext('carol').firestore(), 'carol', 'r2', false));
});

test('a report from an app without the vote counts is still accepted', async () => {
  await assertSucceeds(createReport(alice(), 'alice', 'r1'));
});

test('a report cannot start with denials or a confirmation time', async () => {
  await assertFails(createReport(alice(), 'alice', 'r1', { negativeConfirmations: 1 }));
  await assertFails(createReport(alice(), 'alice', 'r1', { negativesSinceConfirm: 1 }));
  await assertFails(createReport(alice(), 'alice', 'r1', { lastConfirmedAt: serverTimestamp() }));
});

test('a report can start with zero denials', async () => {
  await assertSucceeds(createReport(alice(), 'alice', 'r1', { negativeConfirmations: 0, negativesSinceConfirm: 0 }));
});

test("a yes on someone else's report counts and extends it", async () => {
  await seedReport(env, 'alice', 'r1');
  await assertSucceeds(vote(bob(), 'bob', 'r1', true));
  const data = (await getDoc(doc(bob(), 'reports', 'r1'))).data();
  assert.equal(data.confirmations, 1);
  assert.equal(data.negativesSinceConfirm, 0);
});

test('a yes cannot shorten a report', async () => {
  await seedReport(env, 'alice', 'r1', 2 * MINUTE, { kind: 'blockedPath', expiresAt: Timestamp.fromMillis(Date.now() + 3 * DAY) });
  await assertFails(vote(bob(), 'bob', 'r1', true, { report: {
    confirmations: increment(1), negativesSinceConfirm: 0, expiresAt: Timestamp.fromMillis(Date.now() + 4 * HOUR),
  } }));
  await assertFails(vote(bob(), 'bob', 'r1', true, { report: {
    confirmations: increment(1), negativesSinceConfirm: 0, expiresAt: Timestamp.fromMillis(Date.now() + MINUTE),
  } }));
});

test('a yes keeps a report that already lasts longer than a lifetime', async () => {
  await seedReport(env, 'alice', 'r1', 2 * MINUTE, { kind: 'blockedPath', expiresAt: Timestamp.fromMillis(Date.now() + 3 * DAY) });
  await assertSucceeds(vote(bob(), 'bob', 'r1', true, { report: { confirmations: increment(1), negativesSinceConfirm: 0 } }));
});

test('a yes must set the expiry to one lifetime from now', async () => {
  await seedReport(env, 'alice', 'r1', 2 * MINUTE, { kind: 'blockedPath', expiresAt: Timestamp.fromMillis(Date.now() + HOUR) });
  const yes = (expiresAt) => ({ confirmations: increment(1), negativesSinceConfirm: 0, expiresAt });
  await assertFails(vote(bob(), 'bob', 'r1', true, { report: yes(Timestamp.fromMillis(Date.now() + 5 * HOUR)) }));
  await assertFails(vote(bob(), 'bob', 'r1', true, { report: yes(Timestamp.fromMillis(Date.now() + 2 * HOUR)) }));
  await assertFails(vote(bob(), 'bob', 'r1', true, { report: yes(Timestamp.fromMillis(Date.now() + 30 * DAY)) }));
  await assertSucceeds(vote(bob(), 'bob', 'r1', true, { report: yes(Timestamp.fromMillis(Date.now() + 4 * HOUR)) }));
});

test('a yes cannot be left at a lower expiry or without a new one', async () => {
  await seedReport(env, 'alice', 'r1', 2 * MINUTE, { kind: 'blockedPath', expiresAt: Timestamp.fromMillis(Date.now() + HOUR) });
  await assertFails(vote(bob(), 'bob', 'r1', true, { report: { confirmations: increment(1), negativesSinceConfirm: 0 } }));
});

test('a no counts a denial and leaves the expiry', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  const before = (await getDoc(doc(bob(), 'reports', 'r1'))).data();
  await assertSucceeds(vote(bob(), 'bob', 'r1', false));
  const after = (await getDoc(doc(bob(), 'reports', 'r1'))).data();
  assert.equal(after.negativeConfirmations, 1);
  assert.equal(after.negativesSinceConfirm, 1);
  assert.deepEqual(after.expiresAt, before.expiresAt);
});

test('a no cannot change the expiry before it is the second', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  await assertFails(vote(bob(), 'bob', 'r1', false, { report: {
    negativeConfirmations: increment(1), negativesSinceConfirm: increment(1), expiresAt: serverTimestamp(),
  } }));
});

test('the second no since the last yes ends the report now', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  await assertSucceeds(vote(bob(), 'bob', 'r1', false));
  const carol = env.authenticatedContext('carol').firestore();
  await assertFails(vote(carol, 'carol', 'r1', false));
  await assertFails(vote(carol, 'carol', 'r1', false, { report: {
    negativeConfirmations: increment(1), negativesSinceConfirm: increment(1),
    expiresAt: Timestamp.fromMillis(Date.now() + HOUR),
  } }));
  await assertSucceeds(vote(carol, 'carol', 'r1', false, { report: {
    negativeConfirmations: increment(1), negativesSinceConfirm: increment(1), expiresAt: serverTimestamp(),
  } }));
  const data = (await getDoc(doc(bob(), 'reports', 'r1'))).data();
  assert.ok(data.expiresAt.toMillis() <= Date.now() + MINUTE);
});

test('a yes resets the denials, so the next no does not end the report', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  await assertSucceeds(vote(bob(), 'bob', 'r1', false));
  const carol = env.authenticatedContext('carol').firestore();
  await assertFails(vote(carol, 'carol', 'r1', true, { report: {
    confirmations: increment(1), expiresAt: Timestamp.fromMillis(Date.now() + 7 * DAY),
  } }));
  await assertSucceeds(vote(carol, 'carol', 'r1', true));
  const dave = env.authenticatedContext('dave').firestore();
  await assertSucceeds(vote(dave, 'dave', 'r1', false));
  const data = (await getDoc(doc(bob(), 'reports', 'r1'))).data();
  assert.equal(data.negativeConfirmations, 2);
  assert.equal(data.negativesSinceConfirm, 1);
  assert.ok(data.expiresAt.toMillis() > Date.now() + DAY);
});

test('a no is refused for the first 10 minutes of a report', async () => {
  await seedReport(env, 'alice', 'r1', 5 * MINUTE);
  await assertFails(vote(bob(), 'bob', 'r1', false));
  await assertSucceeds(vote(bob(), 'bob', 'r1', true));
});

test('a user can vote only once on a report', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  await assertSucceeds(vote(bob(), 'bob', 'r1', true));
  await seedVoteStamp(env, 'bob', 2 * MINUTE);
  await assertFails(vote(bob(), 'bob', 'r1', true));
  await assertFails(vote(bob(), 'bob', 'r1', false));
});

test('a vote needs the vote stamp, a minute after the last', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  await seedReport(env, 'carol', 'r2', 20 * MINUTE);
  await assertFails(vote(bob(), 'bob', 'r1', true, { stamp: false }));
  await seedVoteStamp(env, 'bob', 30 * 1000);
  await assertFails(vote(bob(), 'bob', 'r1', true));
  await seedVoteStamp(env, 'bob', 2 * MINUTE);
  await assertSucceeds(vote(bob(), 'bob', 'r1', true));
  await assertFails(vote(bob(), 'bob', 'r2', true));
});

test('a vote stamp does not hold back a report, nor a report stamp a vote', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  await seedVoteStamp(env, 'bob', 10 * 1000);
  await assertSucceeds(createReport(bob(), 'bob', 'r2'));
  await seedReport(env, 'carol', 'r3', 10 * 1000);
  await assertSucceeds(vote(env.authenticatedContext('carol').firestore(), 'carol', 'r1', true));
});

test('a vote needs its vote document, and the vote document the matching count', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  await assertFails(vote(bob(), 'bob', 'r1', true, { vote: false }));
  await assertFails(vote(bob(), 'bob', 'r1', false, { report: {
    confirmations: increment(1), negativesSinceConfirm: 0, expiresAt: Timestamp.fromMillis(Date.now() + 7 * DAY),
  } }));
  const db = bob();
  const batch = writeBatch(db);
  batch.set(doc(db, 'reports', 'r1', 'votes', 'bob'), { isStillPresent: true, votedAt: serverTimestamp() });
  batch.set(doc(db, 'rateLimits', 'bob'), { lastVoteAt: serverTimestamp() }, { merge: true });
  await assertFails(batch.commit());
});

test('a vote document is only for its own voter, with only the answer and time', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  const db = bob();
  const forCarol = writeBatch(db);
  forCarol.set(doc(db, 'reports', 'r1', 'votes', 'carol'), { isStillPresent: true, votedAt: serverTimestamp() });
  forCarol.update(doc(db, 'reports', 'r1'), {
    confirmations: increment(1), negativesSinceConfirm: 0, expiresAt: Timestamp.fromMillis(Date.now() + 7 * DAY),
  });
  forCarol.set(doc(db, 'rateLimits', 'bob'), { lastVoteAt: serverTimestamp() }, { merge: true });
  await assertFails(forCarol.commit());

  const extra = writeBatch(db);
  extra.set(doc(db, 'reports', 'r1', 'votes', 'bob'), { isStillPresent: true, votedAt: serverTimestamp(), name: 'Bob' });
  extra.update(doc(db, 'reports', 'r1'), {
    confirmations: increment(1), negativesSinceConfirm: 0, expiresAt: Timestamp.fromMillis(Date.now() + 7 * DAY),
  });
  extra.set(doc(db, 'rateLimits', 'bob'), { lastVoteAt: serverTimestamp() }, { merge: true });
  await assertFails(extra.commit());
});

test('the reporter cannot vote on their own report', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  await assertFails(vote(alice(), 'alice', 'r1', true));
  await assertFails(vote(alice(), 'alice', 'r1', false));
});

test('an expired report cannot be voted on', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE, { expiresAt: Timestamp.fromMillis(Date.now() - MINUTE) });
  await assertFails(vote(bob(), 'bob', 'r1', true));
});

test('a vote cannot change the kind, place or reporter', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  const yes = { confirmations: increment(1), negativesSinceConfirm: 0, expiresAt: Timestamp.fromMillis(Date.now() + 7 * DAY) };
  await assertFails(vote(bob(), 'bob', 'r1', true, { report: { ...yes, kind: 'other' } }));
  await assertFails(vote(bob(), 'bob', 'r1', true, { report: { ...yes, coordinate: { latitude: 0, longitude: 0 } } }));
  await assertFails(vote(bob(), 'bob', 'r1', true, { report: { ...yes, reporterID: 'bob' } }));
  await assertFails(vote(bob(), 'bob', 'r1', true, { report: { ...yes, negativeConfirmations: 0 } }));
});

test('a vote must change its count by exactly one', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  const expiresAt = Timestamp.fromMillis(Date.now() + 7 * DAY);
  await assertFails(vote(bob(), 'bob', 'r1', true, { report: { confirmations: increment(2), negativesSinceConfirm: 0, expiresAt } }));
  await assertFails(vote(bob(), 'bob', 'r1', true, { report: { confirmations: 0, negativesSinceConfirm: 0, expiresAt } }));
  await assertFails(vote(bob(), 'bob', 'r1', false, { report: { negativeConfirmations: increment(2), negativesSinceConfirm: increment(1) } }));
  await assertFails(vote(bob(), 'bob', 'r1', false, { report: { negativeConfirmations: increment(1), negativesSinceConfirm: increment(2) } }));
  await assertFails(vote(bob(), 'bob', 'r1', false, { report: { negativeConfirmations: increment(1) } }));
});

test("a vote is readable only by its voter, and votes can't be listed", async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  await assertSucceeds(vote(bob(), 'bob', 'r1', true));
  await assertSucceeds(getDoc(doc(bob(), 'reports', 'r1', 'votes', 'bob')));
  await assertFails(getDoc(doc(alice(), 'reports', 'r1', 'votes', 'bob')));
  await assertFails(getDocs(collection(bob(), 'reports', 'r1', 'votes')));
});

test('a vote cannot be changed or deleted', async () => {
  await seedReport(env, 'alice', 'r1', 20 * MINUTE);
  await assertSucceeds(vote(bob(), 'bob', 'r1', true));
  await assertFails(updateDoc(doc(bob(), 'reports', 'r1', 'votes', 'bob'), { isStillPresent: false }));
  await assertFails(deleteDoc(doc(bob(), 'reports', 'r1', 'votes', 'bob')));
});

test('a vote stamp cannot hold a phone-clock time or extra fields', async () => {
  await assertFails(setDoc(doc(bob(), 'rateLimits', 'bob'), { lastVoteAt: Timestamp.now() }));
  await assertFails(setDoc(doc(bob(), 'rateLimits', 'bob'), { lastVoteAt: serverTimestamp(), email: 'bob@example.com' }));
  await assertFails(setDoc(doc(alice(), 'rateLimits', 'bob'), { lastVoteAt: serverTimestamp() }));
});

test('the reporter can delete their own report', async () => {
  await seedReport(env, 'alice', 'r1');
  await assertSucceeds(deleteDoc(doc(alice(), 'reports', 'r1')));
});
