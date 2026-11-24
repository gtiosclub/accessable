import { readFileSync } from 'node:fs';
import { initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { doc, serverTimestamp, Timestamp, writeBatch } from 'firebase/firestore';

export const DAY = 24 * 60 * 60 * 1000;

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
    negativeConfirmations: 0,
    isRemoved: false,
    confirmationResponses: {},
    ...overrides,
  };
}

export function stampData(id) {
  return { lastReportAt: serverTimestamp(), lastReportId: id };
}

/// Writes a report the way the app must: in one batch with the reporter's rate-limit stamp.
export function createReport(db, uid, id, overrides = {}) {
  const batch = writeBatch(db);
  batch.set(doc(db, 'reports', id), reportData(uid, id, overrides));
  batch.set(doc(db, 'rateLimits', uid), stampData(id));
  return batch.commit();
}

/// Puts a report and its stamp in place without the rules, dated `ageMs` ago.
export async function seedReport(env, uid, id, ageMs = 2 * 60 * 1000) {
  const at = Timestamp.fromMillis(Date.now() - ageMs);
  await env.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const batch = writeBatch(db);
    batch.set(doc(db, 'reports', id), reportData(uid, id, { createdAt: at }));
    batch.set(doc(db, 'rateLimits', uid), { lastReportAt: at, lastReportId: id });
    await batch.commit();
  });
}
