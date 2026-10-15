const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const messages = [];
const event = { addListener() {} };
let duplicateFails = false;
let activeCreates = 0;
let nativeReply = async () => ({ appRunning: true });
let migrationCreates = 0, migrationClosed = false, privateDestination = false, storageFails = false, migrationNavigated = false;
const migrationStorage = {};

const browser = {
  windows: { WINDOW_ID_NONE: -1, onCreated: event, onRemoved: event, onFocusChanged: event, getLastFocused: async () => null, get: async () => ({ id: 10, incognito: privateDestination }) },
  tabs: {
    onCreated: event, onActivated: event, onMoved: event, onAttached: event, onDetached: event, onUpdated: event, onRemoved: event,
    get: async (id) => { if (id >= 100 && migrationClosed) throw Error('closed'); return { id, windowId: 10, index: 2, url: migrationNavigated ? 'https://example.com/changed' : 'https://example.com' }; },
    duplicate: async () => { if (duplicateFails) throw Error('unsupported'); return { id: 42 }; },
    create: async (properties) => { if (properties.active === false) { migrationCreates++; return { id: 100 + migrationCreates }; } activeCreates++; return { id: 43 }; },
    query: async () => [],
  },
  storage: { local: {
    get: async (key) => ({ [key]: migrationStorage[key] }),
    set: async (values) => { if (storageFails) throw Error('disk full'); Object.assign(migrationStorage, values); },
  } },
  runtime: { onMessage: event, connectNative: () => ({ onMessage: event, onDisconnect: event }),
    sendNativeMessage: async (_, message) => { messages.push(message); return nativeReply(message); } },
  browserAction: { onClicked: event },
};
const context = vm.createContext({ browser, console, URL, crypto: { randomUUID: () => 'profile' }, setTimeout() {}, setInterval() {}, clearTimeout() {} });
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), context);
(async () => {
  await vm.runInContext('runCommand({ action: "duplicate", instance: "profile", tabId: 1, requestId: "request-a" })', context);
  assert.equal(messages.find(m => m.requestId === 'request-a').tabId, 42);
  duplicateFails = true;
  await vm.runInContext('runCommand({ action: "duplicate", instance: "profile", tabId: 1, requestId: "request-b" })', context);
  assert.equal(messages.find(m => m.requestId === 'request-b').tabId, 43);
  await vm.runInContext('runCommand({ action: "create", instance: "profile", requestId: "request-c" })', context);
  assert.equal(messages.find(m => m.requestId === 'request-c').tabId, 43);
  const count = messages.length;
  await vm.runInContext('runCommand({ action: "duplicate", instance: "wrong-profile", tabId: 1, requestId: "ignored" })', context);
  assert.equal(messages.length, count);
  const queued = 'runCommand({ action: "create", instance: "profile", commandID: "click-a", requestId: "saved-pin", url: "https://example.com" })';
  const beforeQueue = activeCreates;
  await Promise.all([vm.runInContext(queued, context), vm.runInContext(queued, context)]);
  assert.equal(activeCreates, beforeQueue + 1, 'concurrent delivery opens a saved pin exactly once');
  assert.equal(messages.filter(m => m.type === 'commandAck' && m.commandAcks[0] === 'click-a').length, 2, 'duplicate deliveries are re-acknowledged');
  assert.ok(messages.some(m => m.type === 'created' && m.requestId === 'saved-pin'), 'pin creation replies retain membership request');
  nativeReply = async (message) => message.type === 'commandPoll' ? {
    appRunning: true, commands: [{ action: 'create', instance: 'profile', commandID: 'poll-pin', requestId: 'poll-created', url: 'https://example.com' }],
  } : { appRunning: true };
  await vm.runInContext('pollCommands()', context);
  await vm.runInContext('pollCommands()', context);
  assert.equal(activeCreates, beforeQueue + 2, 'poll fallback works without native push and retries do not open twice');
  const acks = messages.filter(m => m.type === 'commandAck').length;
  await vm.runInContext('runCommand({ action: "create", instance: "other", commandID: "wrong-profile" })', context);
  assert.equal(messages.filter(m => m.type === 'commandAck').length, acks, 'wrong profile neither executes nor acknowledges');
  assert.ok(messages.filter(m => m.type === 'commandPoll').every(m => m.commandTransport === 'queue-v1'), 'pull requests negotiate duplicate-safe protocol');
  let releasePoll;
  nativeReply = (message) => message.type === 'commandPoll' ? new Promise(resolve => { releasePoll = resolve; }) : Promise.resolve({ appRunning: true });
  const pollsBefore = messages.filter(m => m.type === 'commandPoll').length;
  const waiting = vm.runInContext('pollCommands()', context);
  await vm.runInContext('pollCommands()', context);
  assert.equal(messages.filter(m => m.type === 'commandPoll').length, pollsBefore + 1, 'only one command poll can be outstanding');
  releasePoll({ appRunning: true }); await waiting;
  nativeReply = async () => ({ appRunning: true });
  const command = (requestId) => `runCommand({ action: "migrationCreate", instance: "profile", windowId: 10, url: "https://example.com", requestId: "${requestId}" })`;
  await Promise.all([vm.runInContext(command('arc-a'), context), vm.runInContext(command('arc-a'), context)]);
  assert.equal(migrationCreates, 1, 'concurrent duplicate commands create once');
  assert.equal(messages.find(m => m.requestId === 'arc-a').type, 'migrationCreated');
  await vm.runInContext(command('arc-a'), context);
  assert.equal(migrationCreates, 1, 'completed command not repeated');
  migrationClosed = true;
  await vm.runInContext(command('arc-a'), context);
  assert.equal(messages.filter(m => m.requestId === 'arc-a').at(-1).type, 'migrationAttention');
  assert.equal(migrationCreates, 1, 'closed tab never reopened');
  migrationClosed = false;
  migrationNavigated = true;
  await vm.runInContext(command('arc-a'), context);
  assert.equal(messages.filter(m => m.requestId === 'arc-a').at(-1).type, 'migrationAttention');
  assert.equal(migrationCreates, 1, 'navigated tab not reassigned or recreated');
  migrationNavigated = false;
  migrationStorage['arc-import:arc-uncertain'] = { state: 'creating', instance: 'profile' };
  await vm.runInContext(command('arc-uncertain'), context);
  assert.equal(migrationCreates, 1, 'interrupted intent does not create blindly');
  assert.equal(messages.find(m => m.requestId === 'arc-uncertain').type, 'migrationAttention');
  migrationStorage['arc-import:arc-old'] = { state: 'done', instance: 'old-session', tabId: 1 };
  await vm.runInContext(command('arc-old'), context);
  assert.equal(migrationCreates, 1, 'old Safari session does not create blindly');
  privateDestination = true;
  await vm.runInContext(command('arc-private'), context);
  assert.equal(migrationCreates, 1, 'private destination rejected');
  privateDestination = false;
  storageFails = true;
  await vm.runInContext(command('arc-storage'), context);
  assert.equal(migrationCreates, 1, 'storage failure prevents creation');
  console.log('Passed 4 extension command checks, 8 command-delivery checks, and 12 migration safety checks.');
})().catch(error => { console.error(error); process.exitCode = 1; });
