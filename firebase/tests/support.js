import { readFileSync } from 'node:fs';
import { initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { doc, getDoc, increment, serverTimestamp, setDoc, Timestamp, writeBatch } from 'firebase/firestore';

export const MINUTE = 60 * 1000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;

export function startEnvironment() {
  return initializeTestEnvironment({
    projectId: 'demo-accessable',
    firestore: { rules: readFileSync(new URL('../firestore.rules', import.meta.url), 'utf8') },
  });
}

/// A report as the app writes one. It doesn't name its reporter: `reporterID` is always empty, and the report is
/// listed in the reporter's private `users/{uid}/reports` instead.
export function reportData(id, overrides = {}) {
  return {
    id,
    kind: 'construction',
    coordinate: { latitude: 33.7756, longitude: -84.3963 },
    createdAt: serverTimestamp(),
    expiresAt: Timestamp.fromMillis(Date.now() + DAY),
    confirmations: 0,
    reporterID: '',
    ...overrides,
  };
}

export function stampData(id) {
  return { lastReportAt: serverTimestamp(), lastReportId: id };
}

/// Writes a report the way the app must: in one batch with the reporter's rate-limit stamp, merged
/// so a vote stamp stays, and their private record of it. `own` false leaves that record out.
export function createReport(db, uid, id, overrides = {}, { own = true } = {}) {
  const batch = writeBatch(db);
  batch.set(doc(db, 'reports', id), reportData(id, overrides));
  batch.set(doc(db, 'rateLimits', uid), stampData(id), { merge: true });
  if (own) batch.set(doc(db, 'users', uid, 'reports', id), { createdAt: serverTimestamp() });
  return batch.commit();
}

/// Puts a report, its stamp and its reporter's record of it in place without the rules, dated `ageMs` ago.
export async function seedReport(env, uid, id, ageMs = 2 * 60 * 1000, overrides = {}) {
  const at = Timestamp.fromMillis(Date.now() - ageMs);
  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const batch = writeBatch(db);
    batch.set(doc(db, 'reports', id), reportData(id, { createdAt: at, ...overrides }));
    batch.set(doc(db, 'rateLimits', uid), { lastReportAt: at, lastReportId: id });
    batch.set(doc(db, 'users', uid, 'reports', id), { createdAt: at });
    await batch.commit();
  });
}

/// Puts a report from before the private records in place without the rules: it names its reporter, who has no
/// record of it.
export async function seedLegacyReport(env, uid, id, ageMs = 20 * 60 * 1000) {
  const at = Timestamp.fromMillis(Date.now() - ageMs);
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), 'reports', id), reportData(id, { createdAt: at, reporterID: uid }));
  });
}

// Trusted fixture prerequisites: the caller's consent, and the volunteer's account, which the app
// creates at sign-up. There are no invites; a volunteer account is enough to be rung.
export async function seedCallPrerequisites(env, caller, volunteer) {
  await env.withSecurityRulesDisabled(async context => {
    const db = context.firestore();
    const batch = writeBatch(db);
    batch.set(doc(db, 'callConsents', caller), { version: 1, acceptedAt: Timestamp.now() });
    if (!(await getDoc(doc(db, 'users', volunteer))).exists()) {
      batch.set(doc(db, 'users', volunteer), { role: 'volunteer', displayName: volunteer, languages: ['English'], createdAt: Timestamp.now() });
    }
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
