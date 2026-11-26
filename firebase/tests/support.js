import { readFileSync } from 'node:fs';
import { initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { doc, increment, serverTimestamp, Timestamp, writeBatch } from 'firebase/firestore';

export const MINUTE = 60 * 1000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;

export function startEnvironment() {
  return initializeTestEnvironment({
    projectId: 'demo-accessable',
    firestore: { rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8') },
  });
}

export function reportData(uid, id, overrides = {}) {
  return {
    id,
    kind: 'construction',
    coordinate: { latitude: 33.7756, longitude: -84.3963 },
    createdAt: serverTimestamp(),
    expiresAt: Timestamp.fromMillis(Date.now() + DAY),
    confirmations: 0,
    reporterID: uid,
    ...overrides,
  };
}

export function stampData(id) {
  return { lastReportAt: serverTimestamp(), lastReportId: id };
}

/// Writes a report the way the app must: in one batch with the reporter's rate-limit stamp, merged
/// so a vote stamp stays.
export function createReport(db, uid, id, overrides = {}) {
  const batch = writeBatch(db);
  batch.set(doc(db, 'reports', id), reportData(uid, id, overrides));
  batch.set(doc(db, 'rateLimits', uid), stampData(id), { merge: true });
  return batch.commit();
}

/// Puts a report and its stamp in place without the rules, dated `ageMs` ago.
export async function seedReport(env, uid, id, ageMs = 2 * 60 * 1000, overrides = {}) {
  const at = Timestamp.fromMillis(Date.now() - ageMs);
  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const batch = writeBatch(db);
    batch.set(doc(db, 'reports', id), reportData(uid, id, { createdAt: at, ...overrides }));
    batch.set(doc(db, 'rateLimits', uid), { lastReportAt: at, lastReportId: id });
    await batch.commit();
  });
}

/// Puts `uid`'s vote stamp in place without the rules, dated `ageMs` ago.
export async function seedVoteStamp(env, uid, ageMs) {
  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const batch = writeBatch(db);
    batch.set(doc(db, 'rateLimits', uid), { lastVoteAt: Timestamp.fromMillis(Date.now() - ageMs), lastVoteReportId: 'earlier' }, { merge: true });
    await batch.commit();
  });
}

/// A vote the way the app writes one: the private vote, the report's counts and the vote stamp
/// in one batch. `report` replaces the report changes; `vote` and `stamp` false leave them out.
export function vote(db, uid, id, isStillPresent, { report, vote = true, stamp = true } = {}) {
  const batch = writeBatch(db);
  if (vote) batch.set(doc(db, 'reports', id, 'votes', uid), { isStillPresent, votedAt: serverTimestamp() });
  batch.update(doc(db, 'reports', id), report ?? (isStillPresent
    ? { confirmations: increment(1), negativesSinceConfirm: 0, expiresAt: Timestamp.fromMillis(Date.now() + 7 * DAY) }
    : { negativeConfirmations: increment(1), negativesSinceConfirm: increment(1) }));
  if (stamp) batch.set(doc(db, 'rateLimits', uid), { lastVoteAt: serverTimestamp(), lastVoteReportId: id }, { merge: true });
  return batch.commit();
}
