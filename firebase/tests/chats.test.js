import { after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  collection, deleteDoc, doc, getDoc, getDocs, limit, query, serverTimestamp, setDoc, Timestamp,
  updateDoc, where, writeBatch,
} from 'firebase/firestore';
import { startEnvironment } from './support.js';

const env = await startEnvironment();
beforeEach(() => env.clearFirestore());
after(() => env.cleanup());

const CHAT = 'alice_vic';
const dbFor = uid => env.authenticatedContext(uid).firestore();

// Trusted fixtures: a caller, a volunteer with a directory entry, and a second caller.
async function seedAccounts() {
  await env.withSecurityRulesDisabled(async context => {
    const db = context.firestore();
    const batch = writeBatch(db);
    const now = Timestamp.now();
    batch.set(doc(db, 'users', 'alice'), { role: 'caller', displayName: 'Alice Smith', languages: ['English'], createdAt: now });
    batch.set(doc(db, 'users', 'carol'), { role: 'caller', displayName: 'Carol', languages: ['English'], createdAt: now });
    batch.set(doc(db, 'users', 'vic'), { role: 'volunteer', displayName: 'Vic', languages: ['English'], createdAt: now });
    batch.set(doc(db, 'users', 'val'), { role: 'volunteer', displayName: 'Val', languages: ['English'], createdAt: now });
    batch.set(doc(db, 'volunteers', 'vic'), {
      displayName: 'Vic', languages: ['English'], bio: '', isOnline: false, inCall: false, lastSeen: now,
    });
    await batch.commit();
  });
}

const chatData = (overrides = {}) => ({
  callerId: 'alice', volunteerId: 'vic', volunteerName: 'Vic', callerFirstName: 'Alice',
  createdAt: serverTimestamp(), updatedAt: serverTimestamp(), ...overrides,
});
const messageData = (senderId, text = 'Hi there', overrides = {}) => ({ senderId, text, sentAt: serverTimestamp(), ...overrides });

/// What the app writes for the first message: the chat and the message in one batch.
function startChat(db, { chat = {}, message = {}, id = CHAT } = {}) {
  const batch = writeBatch(db);
  batch.set(doc(db, 'chats', id), chatData(chat));
  batch.set(doc(collection(db, 'chats', id, 'messages')), messageData('alice', 'Hi there', message));
  return batch.commit();
}

/// What the app writes for a later message: the message and the chat's updatedAt.
function reply(db, senderId, text = 'Sure', id = CHAT) {
  const batch = writeBatch(db);
  batch.update(doc(db, 'chats', id), { updatedAt: serverTimestamp() });
  batch.set(doc(collection(db, 'chats', id, 'messages')), messageData(senderId, text));
  return batch.commit();
}

test('a caller starts a chat and both parties can read and reply', async () => {
  await seedAccounts();
  await assertSucceeds(startChat(dbFor('alice')));
  await assertSucceeds(reply(dbFor('vic'), 'vic'));
  await assertSucceeds(reply(dbFor('alice'), 'alice', 'Thanks'));
  for (const uid of ['alice', 'vic']) {
    const messages = await assertSucceeds(getDocs(collection(dbFor(uid), 'chats', CHAT, 'messages')));
    assert.equal(messages.size, 3);
    await assertSucceeds(getDoc(doc(dbFor(uid), 'chats', CHAT)));
  }
});

test('the caller name may be left out but never forged', async () => {
  await seedAccounts();
  await assertFails(startChat(dbFor('alice'), { chat: { callerFirstName: 'Admin' } }));
  const { callerFirstName, ...withoutName } = chatData();
  const db = dbFor('alice');
  const batch = writeBatch(db);
  batch.set(doc(db, 'chats', CHAT), withoutName);
  batch.set(doc(collection(db, 'chats', CHAT, 'messages')), messageData('alice'));
  await assertSucceeds(batch.commit());
});

test('a party can listen to a chat that does not exist yet', async () => {
  await seedAccounts();
  const messages = await assertSucceeds(getDocs(collection(dbFor('alice'), 'chats', CHAT, 'messages')));
  assert.equal(messages.size, 0);
  const chat = await assertSucceeds(getDoc(doc(dbFor('alice'), 'chats', CHAT)));
  assert.equal(chat.exists(), false);
});

test('outsiders cannot read, list or write a chat', async () => {
  await seedAccounts();
  await startChat(dbFor('alice'));
  const carol = dbFor('carol');
  await assertFails(getDoc(doc(carol, 'chats', CHAT)));
  await assertFails(getDocs(collection(carol, 'chats', CHAT, 'messages')));
  await assertFails(reply(carol, 'carol'));
  await assertFails(getDocs(query(collection(carol, 'chats'), where('volunteerId', '==', 'vic'), limit(50))));
  await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), 'chats', CHAT)));
});

test('a volunteer lists only their own chats, within the limit', async () => {
  await seedAccounts();
  await startChat(dbFor('alice'));
  const vic = dbFor('vic');
  const own = await assertSucceeds(getDocs(query(collection(vic, 'chats'), where('volunteerId', '==', 'vic'), limit(50))));
  assert.equal(own.size, 1);
  await assertFails(getDocs(query(collection(vic, 'chats'), where('volunteerId', '==', 'vic'), limit(51))));
  await assertFails(getDocs(query(collection(vic, 'chats'), limit(50))));
});

test('only a caller starts a chat, under their own id, with a volunteer account', async () => {
  await seedAccounts();
  // A volunteer can't open a chat with a caller.
  await assertFails(startChat(dbFor('vic'), { chat: { callerId: 'vic', volunteerId: 'alice' }, id: 'vic_alice' }));
  // Posing as another caller, or an id that doesn't name the parties.
  await assertFails(startChat(dbFor('carol'), { chat: { callerFirstName: 'Carol' } }));
  await assertFails(startChat(dbFor('alice'), { id: 'alice_val' }));
  // A caller account isn't a volunteer; a volunteer without a directory entry has no name to show.
  await assertFails(startChat(dbFor('alice'), { chat: { volunteerId: 'carol', volunteerName: 'Carol' }, id: 'alice_carol' }));
  await assertFails(startChat(dbFor('alice'), { chat: { volunteerId: 'val', volunteerName: 'Val' }, id: 'alice_val' }));
  // The volunteer's name must match their directory entry.
  await assertFails(startChat(dbFor('alice'), { chat: { volunteerName: 'Someone else' } }));
  await assertFails(startChat(dbFor('alice'), { chat: { createdAt: Timestamp.fromMillis(0) } }));
});

test('a message needs its chat, the sender\'s own id, server time and real text', async () => {
  await seedAccounts();
  const alice = dbFor('alice');
  // No chat yet: a bare message is refused.
  await assertFails(setDoc(doc(collection(alice, 'chats', CHAT, 'messages')), messageData('alice')));
  await startChat(alice);
  const send = (data) => {
    const batch = writeBatch(alice);
    batch.update(doc(alice, 'chats', CHAT), { updatedAt: serverTimestamp() });
    batch.set(doc(collection(alice, 'chats', CHAT, 'messages')), data);
    return batch.commit();
  };
  await assertFails(send(messageData('vic')));
  await assertFails(send(messageData('alice', '')));
  await assertFails(send(messageData('alice', '   \n ')));
  await assertFails(send(messageData('alice', 'x'.repeat(1001))));
  await assertSucceeds(send(messageData('alice', 'x'.repeat(1000))));
  await assertSucceeds(send(messageData('alice', '\nhello\n')));
  await assertFails(send(messageData('alice', 'Hi', { sentAt: Timestamp.fromMillis(0) })));
  await assertFails(send(messageData('alice', 'Hi', { extra: true })));
  // A message without moving the chat's updatedAt.
  await assertFails(setDoc(doc(collection(alice, 'chats', CHAT, 'messages')), messageData('alice')));
});

test('messages and chats cannot be edited or deleted, except the chat order', async () => {
  await seedAccounts();
  const alice = dbFor('alice');
  await startChat(alice);
  const [message] = (await getDocs(collection(alice, 'chats', CHAT, 'messages'))).docs;
  await assertFails(updateDoc(message.ref, { text: 'edited' }));
  await assertFails(deleteDoc(message.ref));
  await assertFails(deleteDoc(doc(alice, 'chats', CHAT)));
  await assertFails(updateDoc(doc(alice, 'chats', CHAT), { volunteerName: 'Other' }));
  await assertFails(updateDoc(doc(dbFor('vic'), 'chats', CHAT), { callerFirstName: 'Mallory' }));
});

test('a block stops the chat both ways', async () => {
  await seedAccounts();
  await startChat(dbFor('alice'));
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), 'users', 'alice', 'blockedVolunteers', 'vic'), { callId: 'c1', createdAt: Timestamp.now() });
  });
  await assertFails(reply(dbFor('vic'), 'vic'));
  await assertFails(reply(dbFor('alice'), 'alice'));
});

test('a blocked volunteer cannot be sent a new chat', async () => {
  await seedAccounts();
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), 'users', 'alice', 'blockedVolunteers', 'vic'), { callId: 'c1', createdAt: Timestamp.now() });
  });
  await assertFails(startChat(dbFor('alice')));
});
