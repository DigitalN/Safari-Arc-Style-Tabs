const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const messages = [];
const event = { addListener() {} };
let duplicateFails = false;
const browser = {
  windows: { WINDOW_ID_NONE: -1, onCreated: event, onRemoved: event, onFocusChanged: event, getLastFocused: async () => null },
  tabs: {
    onCreated: event, onActivated: event, onMoved: event, onAttached: event, onDetached: event, onUpdated: event, onRemoved: event,
    get: async (id) => ({ id, windowId: 10, index: 2, url: 'https://example.com' }),
    duplicate: async () => { if (duplicateFails) throw Error('unsupported'); return { id: 42 }; },
    create: async () => ({ id: 43 }),
    query: async () => [],
  },
  runtime: { onMessage: event, connectNative: () => ({ onMessage: event, onDisconnect: event }),
    sendNativeMessage: async (_, message) => { messages.push(message); return { appRunning: true }; } },
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
  console.log('Passed 4 extension command checks.');
})().catch(error => { console.error(error); process.exitCode = 1; });
