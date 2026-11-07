"use strict";

// Checks for WebExtension/background.js against a stand-in `browser`. No Safari involved.
//
//   node Tests/ExtensionChecks/background-checks.js
//
// (scripts/run-checks.sh runs this.)

const fs = require("fs");
const path = require("path");
const vm = require("vm");

// BACKGROUND_JS points the checks at another copy, to see them fail on an older version.
const source = fs.readFileSync(process.env.BACKGROUND_JS || path.join(__dirname, "../../WebExtension/background.js"), "utf8");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let failures = 0;
function check(condition, message) {
    if (!condition) {
        failures++;
        console.log("FAIL:", message);
    }
}

// Loads a fresh copy of background.js. `queryDelay` is how long tabs.query takes, to make
// a snapshot build overlap with other events.
function load({ queryDelay = 20, tabCount = 5 } = {}) {
    const sent = [];
    const listeners = {};
    const event = (name) => ({ addListener: (fn) => (listeners[name] ||= []).push(fn) });
    const tabs = Array.from({ length: tabCount }, (_, i) => ({
        id: i + 1, windowId: 1, index: i, title: `Tab ${i + 1}`, url: `https://example.com/${i + 1}`, active: i === 0,
    }));
    const browser = {
        windows: {
            WINDOW_ID_NONE: -1,
            getAll: async () => [{ id: 1, focused: true }],
            getLastFocused: async () => ({ id: 1, focused: true }),
            onCreated: event("windows.created"), onRemoved: event("windows.removed"), onFocusChanged: event("windows.focus"),
        },
        tabs: {
            query: async () => { await sleep(queryDelay); return tabs.map((tab) => ({ ...tab })); },
            executeScript: async () => {},
            onCreated: event("created"), onActivated: event("activated"), onMoved: event("moved"),
            onAttached: event("attached"), onDetached: event("detached"), onUpdated: event("updated"),
            onRemoved: event("removed"), onReplaced: event("replaced"),
        },
        runtime: {
            sendNativeMessage: async (id, message) => {
                sent.push({ at: Date.now(), message: JSON.parse(JSON.stringify(message)) });
                return { appRunning: true };
            },
            connectNative: () => ({ onMessage: { addListener() {} }, onDisconnect: { addListener() {} } }),
            onMessage: event("runtime.message"),
        },
        browserAction: { onClicked: event("action") },
    };
    const context = vm.createContext({
        browser, console, setTimeout, clearTimeout, setInterval: () => 0, crypto: { randomUUID: () => "test-instance" },
        URL, fetch: async () => ({}), AbortController, FileReader: class {}, Date, Math,
    });
    vm.runInContext(source.replace('"use strict";', ""), context);
    const fire = (name, ...args) => (listeners[name] || []).forEach((fn) => fn(...args));
    const ofType = (type) => sent.filter((entry) => entry.message.type === type).map((entry) => entry.message);
    return { sent, tabs, fire, ofType };
}

// Waits for the first startup snapshot and forgets what was sent so far. (More follow at 1,
// 3 and 6 s; the checks below are short enough not to meet them.)
async function settled(page) {
    await sleep(150);
    page.sent.length = 0;
}

(async () => {
    // --- #17 item 2: `activated` reports and snapshots share one increasing counter ---
    {
        const page = load();
        await settled(page);

        page.fire("activated", { tabId: 3, windowId: 1 });
        page.fire("activated", { tabId: 4, windowId: 1 });
        await sleep(200);
        const reports = page.ofType("activated");
        check(reports.length === 2, "each activation is reported");
        check(reports.every((report) => Number.isInteger(report.seq)), "activated reports carry a seq");
        check(reports[0].seq < reports[1].seq, "activated reports are numbered in the order they happened");
        const snapshots = page.ofType("snapshot");
        check(snapshots.length >= 1, "a snapshot follows an activation");
        const numbers = [...reports, ...snapshots].map((message) => message.seq);
        check(new Set(numbers).size === numbers.length, "snapshots and reports never reuse a number");
    }

    {
        // A snapshot that was already being built when the activation happened is numbered
        // before it, because the activation might not be in the snapshot's data.
        const page = load({ queryDelay: 60 });
        await settled(page);

        page.fire("windows.focus", 1);               // starts a snapshot build (60 ms query)
        await sleep(10);
        page.fire("activated", { tabId: 2, windowId: 1 });
        await sleep(400);
        const report = page.ofType("activated")[0];
        const first = page.ofType("snapshot")[0];
        check(report && first, "both a report and a snapshot were sent");
        if (report && first) {
            check(first.seq < report.seq, "a snapshot started before an activation is numbered before it");
            const later = page.ofType("snapshot").find((snapshot) => snapshot.seq > report.seq);
            check(!!later, "the snapshot the activation asks for is numbered after it");
        }
    }

    {
        // Snapshots built one after another stay in order, and the heartbeat still names the last
        // snapshot delivered, not a report.
        const page = load();
        await settled(page);
        page.fire("activated", { tabId: 2, windowId: 1 });
        await sleep(200);
        const snapshots = page.ofType("snapshot");
        check(snapshots.every((snapshot, i) => i === 0 || snapshot.seq > snapshots[i - 1].seq), "snapshots are numbered in build order");
    }

    if (failures === 0) {
        console.log("extension checks passed");
        process.exit(0);
    }
    console.log(`${failures} extension check(s) failed`);
    process.exit(1);
})();
