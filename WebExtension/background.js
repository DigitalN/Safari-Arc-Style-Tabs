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

// How long a native message waits for its reply. The extension's handler always answers within about
// 3 s (its message to the app gives up after 1 s + 2 s), but Safari can lose the reply, and then the
// call never settles (#31). That was seen most right after a reinstall, but also in copies started by
// Safari's Settings or by runtime.reload. Past this limit a message counts as not delivered.
const REPLY_TIME_LIMIT_MS = 4000;

// Each background page instance (one per Safari profile) gets its own id so the
// app can keep profiles apart and notice when Safari restarts.
const instance = (crypto.randomUUID && crypto.randomUUID()) || `${Date.now()}-${Math.random().toString(16).slice(2)}`;

// Counts snapshots and `activated` reports together, so the app can tell which of two
// messages is newer even when they arrive out of order: each one is a separate native
// message, and nothing orders them on the way.
let seq = 0;
// The last snapshot the app confirmed receiving.
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

// What the sidebar shows about a tab, as one string, so a change to any of it can be told
// from a change it doesn't show.
function shownSignature(tab) {
    return JSON.stringify([
        tab.title ?? null,
        tab.url ?? null,
        !!tab.pinned,
        !!tab.audible,
        !!(tab.mutedInfo && tab.mutedInfo.muted),
        tab.status === "loading",
        tab.favIconUrl ?? null,
    ]);
}

// The shown state of each tab as of the last snapshot built.
let lastShown = new Map();

async function buildSnapshot() {
    // The number is taken before asking Safari anything. Every report numbered lower
    // happened before the queries below, so the snapshot includes it; a higher-numbered one
    // may or may not be in it, and the app applies it after the snapshot.
    const snapshotSeq = ++seq;
    // And the time, on the clock the app reads (Date.now()): what Safari reports below describes
    // a moment after this, so a sidebar click made after it may not be in the snapshot.
    const startedAt = Date.now();
    // Query tabs directly rather than windows.getAll({ populate: true }), which can
    // return windows without their tabs while Safari is still restoring them.
    const [windows, tabs] = await Promise.all([browser.windows.getAll(), browser.tabs.query({})]);

    lastShown = new Map(tabs.map((tab) => [tab.id, shownSignature(tab)]));

    const tabsByWindow = new Map();
    for (const tab of tabs) {
        if (!tabsByWindow.has(tab.windowId)) tabsByWindow.set(tab.windowId, []);
        tabsByWindow.get(tab.windowId).push(tab);
    }

    const known = new Map(windows.filter((w) => !w.type || w.type === "normal").map((w) => [w.id, w]));
    for (const windowId of tabsByWindow.keys()) {
        if (!known.has(windowId) && !windows.some((w) => w.id === windowId)) {
            const incognito = tabsByWindow.get(windowId).some((tab) => tab.incognito);
            known.set(windowId, { id: windowId, focused: windowId === focusedWindowId, incognito });
        }
    }

    return {
        type: "snapshot",
        instance,
        seq: snapshotSeq,
        startedAt,
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
let sendDue = 0;
let sending = false;
let resendRequested = false;
let retryDelay = 250;
let lastFlushAt = 0;

// Asks for a snapshot in `delay` ms. An earlier request replaces a pending later one, so a
// slow background refresh (see scheduleLazySnapshot) never holds up an urgent one.
function scheduleSnapshot(delay = 30) {
    const due = Date.now() + delay;
    if (sendTimer) {
        if (sendDue <= due) return;
        clearTimeout(sendTimer);
    }
    sendDue = due;
    sendTimer = setTimeout(flushSnapshot, delay);
}

// For changes that can wait, like a page loading in the background: every snapshot asks
// Safari for all windows and tabs, so while pages load these are spaced out rather than
// sent one after another, which would keep Safari busy and delay the commands that matter.
const LAZY_SNAPSHOT_MS = 250;

function scheduleLazySnapshot() {
    scheduleSnapshot(Math.max(30, lastFlushAt + LAZY_SNAPSHOT_MS - Date.now()));
}

async function flushSnapshot() {
    sendTimer = null;
    lastFlushAt = Date.now();
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
        // The app may be starting up, Safari may still be restoring windows, or the reply was lost
        // (postToApp gives up waiting for it): try again.
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

// Whether any message from this copy has had a reply yet, on time or late. Until one has, the hello is
// sent again (see sayHello).
let heardFromApp = false;

// Sends a message to the app. Resolves with the reply, or with null if the message couldn't be
// delivered: an error, or no reply within REPLY_TIME_LIMIT_MS. It never waits longer than that, so a
// lost reply can't hold up whatever comes next. A reply that turns up later goes to handleLateReply.
function postToApp(message) {
    const sentAt = Date.now();
    return new Promise((resolve) => {
        let settled = false;
        const timer = setTimeout(() => {
            if (settled) return;
            settled = true;
            noteNoReply(message);
            resolve(null);
        }, REPLY_TIME_LIMIT_MS);
        let call;
        try {
            call = Promise.resolve(browser.runtime.sendNativeMessage(NATIVE_APP_ID, message));
        } catch (error) {
            call = Promise.reject(error);
        }
        call.then((reply) => {
            heardFromApp = true;
            if (settled) {
                handleLateReply(reply, message, Date.now() - sentAt);
                return;
            }
            settled = true;
            clearTimeout(timer);
            try {
                handleReply(reply);
            } catch (error) {
                console.warn("Side Tabs: could not handle the app's reply", error);
            }
            resolve(reply);
        }, (error) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            console.warn("Side Tabs: could not reach the app", error);
            resolve(null);
        });
    });
}

function handleReply(reply) {
    if (!reply || typeof reply !== "object") return;
    if (reply.needSnapshot) scheduleSnapshot(0);
    if (Array.isArray(reply.commands)) reply.commands.forEach(runCommand);
}

// A reply that came after its message's time limit. By then the message counted as not delivered,
// was sent again if it matters, and the app may have moved on. So any commands in it are dropped: a
// late `activate`, for one, would put Safari back on a tab the user has since left (#20). A request
// for a snapshot is safe at any time.
function handleLateReply(reply, message, milliseconds) {
    noteLateReply(message, milliseconds);
    if (reply && typeof reply === "object" && reply.needSnapshot) scheduleSnapshot(0);
}

// Sends a message that the app can safely receive twice, and sends it again, with back-off, until it's
// delivered or `tries` have failed. Used for `created`: without it, a lost one leaves a bookmark's new
// tab under Tabs.
async function postUntilDelivered(message, tries = 3) {
    for (let attempt = 0; attempt < tries; attempt++) {
        if (attempt > 0) await new Promise((resolve) => setTimeout(resolve, 250 * 2 ** (attempt - 1)));
        const reply = await postToApp(message);
        if (reply && reply.appRunning) return reply;
    }
    return null;
}

// Messages that got no reply in time, and replies that came late, are told to the app's log (see
// DEVELOPMENT.md), a limited number of times per copy. Only message types and counts: nothing about
// the tabs.
let noReplyCount = 0;
let lateReplyCount = 0;
let replyNotesLeft = 20;

function noteNoReply(message) {
    noReplyCount++;
    if (message.type === "log" || replyNotesLeft <= 0) return;
    replyNotesLeft--;
    postToApp({
        type: "log", instance,
        message: `no reply within ${REPLY_TIME_LIMIT_MS} ms to "${message.type}" (${noReplyCount} so far); counted as not delivered`,
    });
}

function noteLateReply(message, milliseconds) {
    lateReplyCount++;
    if (message.type === "log" || replyNotesLeft <= 0) return;
    replyNotesLeft--;
    postToApp({
        type: "log", instance,
        message: `the reply to "${message.type}" came ${milliseconds} ms after it was sent, past the time limit (${lateReplyCount} so far)`,
    });
}

// ---------------------------------------------------------------------------
// Commands from the app

async function runCommand(command) {
    if (!command || typeof command !== "object") return;
    if (command.instance && command.instance !== instance) return;

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

        case "create": {
            const properties = { active: command.active ?? true };
            if (command.windowId != null) properties.windowId = command.windowId;
            if (command.url) properties.url = command.url;
            if (command.index != null) properties.index = command.index;
            const tab = await browser.tabs.create(properties);
            if (command.requestId) {
                // The app ignores a repeat, so this can be sent again if the first one isn't delivered.
                postUntilDelivered({ type: "created", instance, requestId: command.requestId, tabId: tab.id });
            }
            // A closed tab reopened from cleanup's list in another window than the current one (its
            // own profile's) brings that window forward, so it doesn't open out of sight.
            if (command.focus) await browser.windows.update(tab.windowId, { focused: true });
            break;
        }

        case "move":
            await browser.tabs.move(command.tabId, { index: command.index });
            break;

        case "duplicate":
            await duplicateTab(command.tabId);
            break;

        case "reload":
            await browser.tabs.reload(command.tabId);
            break;

        case "navigate":
            await browser.tabs.update(command.tabId, { url: command.url, active: true });
            break;

        case "mute":
            await browser.tabs.update(command.tabId, { muted: !!command.muted });
            // Safari sends no tabs.onUpdated for a mute change (the keys it sends were logged:
            // none for muting), so the sidebar would keep the old icon until something else
            // caused a snapshot.
            scheduleSnapshot();
            break;

        case "fetchIcons":
            (command.urls ?? []).forEach(sendIcon);
            break;
        }
    } catch (error) {
        console.warn("Side Tabs: command failed", command, error);
        // Whatever the app assumed is now wrong; send it the truth.
        scheduleSnapshot(0);
    }
}

async function duplicateTab(tabId) {
    if (browser.tabs.duplicate) {
        try {
            await browser.tabs.duplicate(tabId);
            return;
        } catch (error) {
            // Fall through to the manual version.
        }
    }
    const tab = await browser.tabs.get(tabId);
    if (tab.url) await browser.tabs.create({ windowId: tab.windowId, index: tab.index + 1, url: tab.url });
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
// Favicons
//
// The app gets its icons from here rather than downloading them itself: connecting to a
// router or other device on the local network would make macOS ask for Local Network
// access. Safari has it already.

const ICON_TIMEOUT_MS = 10000;
const ICON_MAX_BYTES = 512 * 1024;

async function sendIcon(url) {
    let data = null;
    try {
        data = await fetchIcon(url);
    } catch {
        // Unreachable, too slow, or not allowed: the app shows a letter instead.
    }
    postToApp({ type: "icon", instance, url, data });
}

// The icon as base64, or null.
async function fetchIcon(url) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), ICON_TIMEOUT_MS);
    try {
        const response = await fetch(url, { cache: "force-cache", signal: controller.signal });
        if (!response.ok) return null;
        const blob = await response.blob();
        if (!blob.size || blob.size > ICON_MAX_BYTES) return null;
        const dataURL = await new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(reader.result);
            reader.onerror = () => reject(reader.error);
            reader.readAsDataURL(blob);
        });
        return dataURL.slice(dataURL.indexOf(",") + 1);
    } finally {
        clearTimeout(timer);
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
browser.tabs.onActivated.addListener((info) => {
    // Building a snapshot takes a while with many tabs; the app only needs this much to
    // move the highlight and know the switch happened. `at` is when the switch was seen, on the
    // same clock the app reads (Date.now()), so the app can tell a switch from before a sidebar
    // click from one after it. `seq` only orders Safari's own messages among themselves.
    postToApp({ type: "activated", instance, seq: ++seq, at: Date.now(), windowId: info.windowId, tabId: info.tabId });
    scheduleSnapshot(0);
});
browser.tabs.onMoved.addListener(() => scheduleSnapshot());
browser.tabs.onAttached.addListener(() => scheduleSnapshot());
browser.tabs.onDetached.addListener(() => scheduleSnapshot());

// `changeInfo` keys for changes the sidebar doesn't show. Anything else, including a key
// that isn't known here and an empty `changeInfo`, may be a change to a title or an icon
// that Safari reports under another name, so it gets a snapshot.
const UNSHOWN_CHANGES = new Set([
    "attention", "autoDiscardable", "discarded", "frozen", "hidden", "isArticle", "isInReaderMode",
    "sharingState", "successorTabId",
]);

function changeMayBeShown(changeInfo) {
    const keys = Object.keys(changeInfo || {});
    return keys.length === 0 || keys.some((key) => !UNSHOWN_CHANGES.has(key));
}

// Tells the app which `changeInfo` keys Safari sends, once per distinct combination, so
// the system log shows what Safari really reports (see /usr/bin/log in DEVELOPMENT.md).
const loggedChangeKeys = new Set();

function noteChangeKeys(changeInfo, what = "changeInfo keys") {
    const keys = Object.keys(changeInfo || {}).sort().join(",") || "(none)";
    const message = `tabs.onUpdated ${what}: ${keys}`;
    if (loggedChangeKeys.has(message) || loggedChangeKeys.size >= 60) return;
    loggedChangeKeys.add(message);
    postToApp({ type: "log", instance, message });
}

browser.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    if (changeInfo.url) {
        // Keep the old icon while navigating within a site; drop it when the site changes.
        const known = favicons.get(tabId);
        if (known && originOf(known) !== originOf(changeInfo.url) && !known.startsWith("data:")) favicons.delete(tabId);
    }
    noteChangeKeys(changeInfo);
    if (changeMayBeShown(changeInfo)) {
        scheduleLazySnapshot();
    } else if (tab && shownSignature(tab) !== lastShown.get(tabId)) {
        // Only keys for changes the sidebar doesn't show, yet something it does show differs
        // from the last snapshot: Safari reported that change without its usual key.
        noteChangeKeys(changeInfo, "shown change reported only as");
        scheduleLazySnapshot();
    }
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

// The first message: it tells the app this copy has started, and has the extension's handler open the
// app if it isn't running. Safari can lose the reply (see REPLY_TIME_LIMIT_MS), so it's sent again,
// with back-off, until any message from this copy has had a reply, a few times at most. Nothing waits
// for it: snapshots and heartbeats start at once.
const HELLO_RETRIES = 5;

async function sayHello(attempt = 0) {
    const reply = await postToApp({ type: "hello", instance, launchApp: true });
    if (reply || heardFromApp || attempt >= HELLO_RETRIES) return;
    setTimeout(() => sayHello(attempt + 1), Math.min(1000 * 2 ** attempt, 15000));
}

// Safari restores windows and tabs for a while after launch, not always with events.
const STARTUP_REFRESH_MS = [1000, 3000, 6000];

function refreshAfterStart() {
    scheduleSnapshot(0);
}

(async function start() {
    try {
        // Not worth waiting long for: focus changes fill this in too.
        const window = await Promise.race([
            browser.windows.getLastFocused(),
            new Promise((resolve) => setTimeout(() => resolve(null), 2000)),
        ]);
        if (window) {
            lastFocusedWindowId = window.id;
            if (window.focused) focusedWindowId = window.id;
        }
    } catch {
        // No windows yet.
    }

    connectPort();
    sayHello();
    scheduleSnapshot(0);
    for (const delay of STARTUP_REFRESH_MS) setTimeout(refreshAfterStart, delay);
    collectExistingFavicons().catch(() => {});

    setInterval(() => postToApp({ type: "heartbeat", instance, seq: sentSeq }), HEARTBEAT_MS);
})();
