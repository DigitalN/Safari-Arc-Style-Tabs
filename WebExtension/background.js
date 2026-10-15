"use strict";

// Side Tabs background page.
//
// Mirrors Safari's windows and tabs to the Side Tabs app, and carries out the
// commands the app sends back (switch, close, open, move, ...).
//
//   extension -> app : browser.runtime.sendNativeMessage -> SafariWebExtensionHandler -> CFMessagePort
//   app -> extension : SFSafariApplication.dispatchMessage -> the port opened with connectNative

// Safari ignores this value and always talks to the containing app.
const NATIVE_APP_ID = "com.digitaln.sidetabs";
const WINDOW_ID_NONE = browser.windows.WINDOW_ID_NONE ?? -1;
const HEARTBEAT_MS = 5000;
const COMMAND_TRANSPORT = "queue-v1";

// Each background page instance (one per Safari profile) gets its own id so the
// app can keep profiles apart and notice when Safari restarts.
const instance = (crypto.randomUUID && crypto.randomUUID()) || `${Date.now()}-${Math.random().toString(16).slice(2)}`;

let seq = 0;
let sentSeq = 0;
let focusedWindowId = WINDOW_ID_NONE;
let lastFocusedWindowId = null;
let focusChangedAt = Date.now();

// Favicon URLs reported by content.js, keyed by tab id.
const favicons = new Map();

// ---------------------------------------------------------------------------
// Snapshots

function serializeTab(tab) {
    return {
        id: tab.id,
        windowId: tab.windowId,
        index: tab.index,
        title: tab.title ?? null,
        url: tab.url ?? null,
        active: !!tab.active,
        pinned: !!tab.pinned,
        audible: !!tab.audible,
        muted: !!(tab.mutedInfo && tab.mutedInfo.muted),
        loading: tab.status === "loading",
        favIconUrl: favicons.get(tab.id) || tab.favIconUrl || null,
    };
}

async function buildSnapshot() {
    // Query tabs directly rather than windows.getAll({ populate: true }), which can
    // return windows without their tabs while Safari is still restoring them.
    const [windows, tabs] = await Promise.all([browser.windows.getAll(), browser.tabs.query({})]);

    const tabsByWindow = new Map();
    for (const tab of tabs) {
        if (!tabsByWindow.has(tab.windowId)) tabsByWindow.set(tab.windowId, []);
        tabsByWindow.get(tab.windowId).push(tab);
    }

    const known = new Map(windows.filter((w) => !w.type || w.type === "normal").map((w) => [w.id, w]));
    for (const windowId of tabsByWindow.keys()) {
        if (!known.has(windowId) && !windows.some((w) => w.id === windowId)) {
            known.set(windowId, { id: windowId, focused: windowId === focusedWindowId, incognito: false });
        }
    }

    return {
        type: "snapshot",
        capabilities: ["arcMigrationV1"],
        instance,
        seq: ++seq,
        focusedWindowId,
        lastFocusedWindowId,
        focusChangedAt,
        windows: [...known.values()].map((w) => ({
            id: w.id,
            focused: !!w.focused,
            incognito: !!w.incognito,
            tabs: (tabsByWindow.get(w.id) || []).sort((a, b) => a.index - b.index).map(serializeTab),
        })),
    };
}

let sendTimer = null;
let sending = false;
let resendRequested = false;
let retryDelay = 250;

function scheduleSnapshot(delay = 30) {
    if (sendTimer) return;
    sendTimer = setTimeout(flushSnapshot, delay);
}

async function flushSnapshot() {
    sendTimer = null;
    if (sending) {
        resendRequested = true;
        return;
    }
    sending = true;
    let delivered = false;
    try {
        const snapshot = await buildSnapshot();
        const reply = await postToApp(snapshot);
        delivered = !!(reply && reply.appRunning);
        if (delivered) sentSeq = snapshot.seq;
    } catch (error) {
        console.warn("Side Tabs: snapshot failed", error);
    } finally {
        // The app may be starting up, or Safari may still be restoring windows: try again.
        if (!delivered) {
            setTimeout(() => scheduleSnapshot(0), retryDelay);
            retryDelay = Math.min(retryDelay * 2, 15000);
        } else {
            retryDelay = 250;
        }
        sending = false;
        if (resendRequested) {
            resendRequested = false;
            scheduleSnapshot(0);
        }
    }
}

async function postToApp(message) {
    try {
        const reply = await browser.runtime.sendNativeMessage(NATIVE_APP_ID, { ...message, commandTransport: COMMAND_TRANSPORT });
        handleReply(reply);
        return reply;
    } catch (error) {
        console.warn("Side Tabs: could not reach the app", error);
        return null;
    }
}

function handleReply(reply) {
    if (!reply || typeof reply !== "object") return;
    if (reply.needSnapshot) scheduleSnapshot(0);
    if (Array.isArray(reply.commands)) reply.commands.forEach(runCommand);
}

// ---------------------------------------------------------------------------
// Commands from the app

let commandPollTimer = null;
let commandPolling = false;
let commandPollAgain = false;

function scheduleCommandPoll(delay = 0) {
    if (commandPollTimer != null) clearTimeout(commandPollTimer);
    commandPollTimer = setTimeout(pollCommands, delay);
}

async function pollCommands() {
    commandPollTimer = null;
    if (commandPolling) { commandPollAgain = true; return; }
    commandPolling = true;
    let delay = 5000;
    try {
        const reply = await postToApp({ type: "commandPoll", instance });
        if (reply?.appRunning) delay = Math.max(100, Math.min(5000, reply.commandPollIntervalMs ?? 250));
    } finally {
        commandPolling = false;
        scheduleCommandPoll(commandPollAgain ? 0 : delay);
        commandPollAgain = false;
    }
}

// The native queue expires after 15 seconds. Keep IDs much longer than that, so
// concurrent replies, lost acknowledgements, and push wakeups cannot create twice.
const receivedCommands = new Map();
async function runCommand(command) {
    if (!command || typeof command !== "object") return;
    if (command.instance && command.instance !== instance) return;
    if (command.action === "pollCommands") { scheduleCommandPoll(); return; }
    if (typeof command.commandID === "string") {
        const id = command.commandID;
        const duplicate = receivedCommands.has(id);
        receivedCommands.set(id, Date.now());
        // Claim synchronously before any await or acknowledgement can deliver it again.
        for (const [key, at] of receivedCommands) {
            if (Date.now() - at > 120000) receivedCommands.delete(key);
        }
        postToApp({ type: "commandAck", instance, commandAcks: [id] });
        if (duplicate) return;
    }

    try {
        switch (command.action) {
        case "snapshot":
            scheduleSnapshot(0);
            break;

        case "activate":
            await browser.tabs.update(command.tabId, { active: true });
            break;

        case "close":
            await browser.tabs.remove(command.tabIds ?? [command.tabId]);
            break;

        case "migrationCreate":
            await migrationCreate(command);
            break;

        case "create": {
            const properties = { active: command.active ?? true };
            if (command.windowId != null) properties.windowId = command.windowId;
            if (command.url) properties.url = command.url;
            if (command.index != null) properties.index = command.index;
            const tab = await browser.tabs.create(properties);
            if (command.requestId) {
                postToApp({ type: "created", instance, requestId: command.requestId, tabId: tab.id });
            }
            break;
        }

        case "move":
            await browser.tabs.move(command.tabId, { index: command.index });
            break;

        case "duplicate": {
            const duplicate = await duplicateTab(command.tabId);
            if (duplicate && command.requestId) {
                await postToApp({ type: "created", instance, requestId: command.requestId, tabId: duplicate.id });
            }
            break;
        }

        case "reload":
            await browser.tabs.reload(command.tabId);
            break;

        case "navigate":
            await browser.tabs.update(command.tabId, { url: command.url, active: true });
            break;

        case "mute":
            await browser.tabs.update(command.tabId, { muted: !!command.muted });
            break;
        }
    } catch (error) {
        console.warn("Side Tabs: command failed", command, error);
        // Whatever the app assumed is now wrong; send it the truth.
        scheduleSnapshot(0);
    }
}

// A durable intent is stored BEFORE creation. An interrupted intent is uncertain,
// never permission to blindly create another tab. Completed/closed requests stay done.
const migrationRequests = new Map();
async function migrationCreate(command) {
    const token = command.requestId;
    if (typeof token !== "string" || !token || !/^https?:|^about:blank$/.test(command.url ?? "")) return;
    if (migrationRequests.has(token)) return migrationRequests.get(token);
    const work = (async () => {
        const key = `arc-import:${token}`;
        const attention = (message) => postToApp({ type: "migrationAttention", instance, requestId: token, message });
        if (!browser.storage?.local) return attention("Persistent extension storage is unavailable. No tab was opened.");
        try {
            const previous = (await browser.storage.local.get(key))[key];
            if (previous) {
                if (previous.state === "done" && previous.instance === instance) {
                    // A completed request must never reopen a tab the user closed.
                    let existing;
                    try { existing = await browser.tabs.get(previous.tabId); }
                    catch { return attention("This tab was created previously and has since been closed. It was not reopened."); }
                    if (existing.windowId !== previous.windowId || existing.url !== previous.url) {
                        return attention("This tab moved or navigated after creation. Review it manually; no duplicate was opened.");
                    }
                    return postToApp({ type: "migrationCreated", instance, requestId: token, tabId: previous.tabId });
                }
                return attention("An earlier attempt may have opened this tab, possibly in a previous Safari session. Check Safari manually; no duplicate was opened.");
            }
            // Do not accept private destinations even if the native app has stale state.
            const window = await browser.windows.get(command.windowId);
            if (window.incognito) return attention("Private windows cannot receive imported tabs.");
            await browser.storage.local.set({ [key]: { state: "creating", instance, url: command.url } });
            const tab = await browser.tabs.create({ windowId: command.windowId, url: command.url, active: false });
            await browser.storage.local.set({ [key]: { state: "done", instance, tabId: tab.id, windowId: tab.windowId ?? command.windowId, url: tab.url ?? command.url } });
            return postToApp({ type: "migrationCreated", instance, requestId: token, tabId: tab.id });
        } catch {
            return attention("Safari could not confirm creation. The request is retained for manual review; it will not be repeated automatically.");
        }
    })();
    migrationRequests.set(token, work);
    try { return await work; }
    finally { migrationRequests.delete(token); }
}

async function duplicateTab(tabId) {
    if (browser.tabs.duplicate) {
        try {
            return await browser.tabs.duplicate(tabId);
        } catch (error) {
            // Fall through to the manual version.
        }
    }
    const tab = await browser.tabs.get(tabId);
    if (tab.url) return await browser.tabs.create({ windowId: tab.windowId, index: tab.index + 1, url: tab.url });
}

let port = null;

function connectPort() {
    try {
        port = browser.runtime.connectNative(NATIVE_APP_ID);
        port.onMessage.addListener((message) => {
            const payload = message && message.userInfo ? message.userInfo : message;
            if (payload && Array.isArray(payload.commands)) payload.commands.forEach(runCommand);
            else runCommand(payload);
        });
        port.onDisconnect.addListener(() => {
            port = null;
            setTimeout(connectPort, 3000);
        });
    } catch (error) {
        console.warn("Side Tabs: connectNative failed", error);
        setTimeout(connectPort, 5000);
    }
}

// ---------------------------------------------------------------------------
// Browser events

function originOf(url) {
    try {
        return new URL(url).origin;
    } catch {
        return null;
    }
}

browser.tabs.onCreated.addListener(() => scheduleSnapshot());
browser.tabs.onActivated.addListener(() => scheduleSnapshot(0));
browser.tabs.onMoved.addListener(() => scheduleSnapshot());
browser.tabs.onAttached.addListener(() => scheduleSnapshot());
browser.tabs.onDetached.addListener(() => scheduleSnapshot());

browser.tabs.onUpdated.addListener((tabId, changeInfo) => {
    if (changeInfo.url) {
        // Keep the old icon while navigating within a site; drop it when the site changes.
        const known = favicons.get(tabId);
        if (known && originOf(known) !== originOf(changeInfo.url) && !known.startsWith("data:")) favicons.delete(tabId);
    }
    scheduleSnapshot();
});

browser.tabs.onRemoved.addListener((tabId) => {
    favicons.delete(tabId);
    scheduleSnapshot();
});

if (browser.tabs.onReplaced) {
    browser.tabs.onReplaced.addListener((addedTabId, removedTabId) => {
        if (favicons.has(removedTabId)) {
            favicons.set(addedTabId, favicons.get(removedTabId));
            favicons.delete(removedTabId);
        }
        scheduleSnapshot();
    });
}

browser.windows.onCreated.addListener(() => scheduleSnapshot());
browser.windows.onRemoved.addListener(() => scheduleSnapshot());
browser.windows.onFocusChanged.addListener((windowId) => {
    focusedWindowId = windowId;
    if (windowId !== WINDOW_ID_NONE) lastFocusedWindowId = windowId;
    focusChangedAt = Date.now();
    scheduleSnapshot(0);
    scheduleCommandPoll();
});

browser.runtime.onMessage.addListener((message, sender) => {
    if (!message || message.type !== "favicon" || !sender.tab || !message.url) return;
    if (favicons.get(sender.tab.id) === message.url) return;
    favicons.set(sender.tab.id, message.url);
    scheduleSnapshot();
});

browser.browserAction.onClicked.addListener(() => {
    postToApp({ type: "toggleSidebar", instance, launchApp: true });
});

// ---------------------------------------------------------------------------
// Startup

async function collectExistingFavicons() {
    // Content scripts only run on pages loaded after the extension starts, so ask
    // the tabs that are already open for their icons.
    const tabs = await browser.tabs.query({});
    for (const tab of tabs) {
        if (!tab.url || !/^https?:/.test(tab.url)) continue;
        browser.tabs.executeScript(tab.id, { file: "content.js" }).catch(() => {});
    }
}

(async function start() {
    try {
        const window = await browser.windows.getLastFocused();
        if (window) {
            lastFocusedWindowId = window.id;
            if (window.focused) focusedWindowId = window.id;
        }
    } catch {
        // No windows yet.
    }

    connectPort();
    await postToApp({ type: "hello", instance, launchApp: true });
    scheduleCommandPoll();
    scheduleSnapshot(0);
    // Safari restores windows and tabs for a while after launch, not always with events.
    for (const delay of [1000, 3000, 6000]) setTimeout(() => scheduleSnapshot(0), delay);
    collectExistingFavicons().catch(() => {});

    setInterval(() => postToApp({ type: "heartbeat", instance, seq: sentSeq }), HEARTBEAT_MS);
})();
