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

// What `reply` returns for a native message whose reply Safari loses: the call never settles.
const HANG = Symbol("hang");

// Loads a fresh copy of background.js. `queryDelay` is how long tabs.query takes, to make
// a snapshot build overlap with other events. `reply(message, count)` answers each native message
// (`count` messages so far, this one included): a reply, a promise of one (to answer late), or HANG.
// `timeScale` shortens every timer background.js sets, so a check of its 4 s time limit doesn't take
// seconds. `hangLastFocused` makes windows.getLastFocused never answer. Heartbeats don't run by
// themselves; `heartbeat()` sends one as the timer would.
function load({ queryDelay = 20, tabCount = 5, reply = () => ({ appRunning: true }), timeScale = 1, hangLastFocused = false } = {}) {
    const sent = [];
    const updates = [];
    const created = [];
    const windowUpdates = [];
    const intervals = [];
    const listeners = {};
    const event = (name) => ({ addListener: (fn) => (listeners[name] ||= []).push(fn) });
    const tabs = Array.from({ length: tabCount }, (_, i) => ({
        id: i + 1, windowId: 1, index: i, title: `Tab ${i + 1}`, url: `https://example.com/${i + 1}`, active: i === 0,
    }));
    const browser = {
        windows: {
            WINDOW_ID_NONE: -1,
            getAll: async () => [{ id: 1, focused: true }],
            getLastFocused: () => (hangLastFocused ? new Promise(() => {}) : Promise.resolve({ id: 1, focused: true })),
            update: async (id, props) => { windowUpdates.push({ id, props }); return { id, ...props }; },
            onCreated: event("windows.created"), onRemoved: event("windows.removed"), onFocusChanged: event("windows.focus"),
        },
        tabs: {
            query: async () => { await sleep(queryDelay); return tabs.map((tab) => ({ ...tab })); },
            executeScript: async () => {},
            update: async (id, props) => { updates.push({ id, props }); return { ...tabs[id - 1], ...props }; },
            create: async (props) => { created.push(props); return { id: 100 + created.length, windowId: props.windowId ?? 1, index: 0, url: props.url }; },
            onCreated: event("created"), onActivated: event("activated"), onMoved: event("moved"),
            onAttached: event("attached"), onDetached: event("detached"), onUpdated: event("updated"),
            onRemoved: event("removed"), onReplaced: event("replaced"),
        },
        runtime: {
            sendNativeMessage: (id, message) => {
                const copy = JSON.parse(JSON.stringify(message));
                sent.push({ at: Date.now(), message: copy });
                const answer = reply(copy, sent.length);
                return answer === HANG ? new Promise(() => {}) : Promise.resolve(answer);
            },
            connectNative: () => ({ onMessage: { addListener() {} }, onDisconnect: { addListener() {} } }),
            onMessage: event("runtime.message"),
        },
        browserAction: { onClicked: event("action") },
    };
    // background.js asks for extra snapshots 1, 3 and 6 s after it starts, to catch windows
    // Safari restores late. They're left out so they can't land in the middle of a check. (An older
    // background.js, run through BACKGROUND_JS, has no refreshAfterStart: there they're told by delay.)
    const startupRefresh = (fn, ms) => (context.refreshAfterStart ? fn === context.refreshAfterStart : [1000, 3000, 6000].includes(ms));
    const timer = (fn, ms, ...args) => (startupRefresh(fn, ms) ? 0 : setTimeout(fn, (ms ?? 0) * timeScale, ...args));
    const context = vm.createContext({
        browser, console, setTimeout: timer, clearTimeout,
        setInterval: (fn, ms) => intervals.push({ fn, ms }), crypto: { randomUUID: () => "test-instance" },
        URL, fetch: async () => ({}), AbortController, FileReader: class {}, Date, Math,
    });
    vm.runInContext(source.replace('"use strict";', ""), context);
    const fire = (name, ...args) => (listeners[name] || []).forEach((fn) => fn(...args));
    const ofType = (type) => sent.filter((entry) => entry.message.type === type).map((entry) => entry.message);
    // Carries out a command from the app, as the port or a reply would deliver it.
    const run = (command) => context.runCommand({ instance: "test-instance", ...command });
    const heartbeat = () => intervals.filter((entry) => entry.ms === 5000).forEach((entry) => entry.fn());
    // Reads one of background.js's top-level variables.
    const state = (name) => vm.runInContext(name, context);
    return { sent, tabs, updates, created, windowUpdates, intervals, fire, ofType, run, heartbeat, state };
}

// Waits for the first startup snapshot and forgets what was sent so far.
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

    // --- #19 item 1: each `activated` report says when the switch was seen, on the clock the app reads ---
    {
        const page = load();
        await settled(page);

        const before = Date.now();
        page.fire("activated", { tabId: 3, windowId: 1 });
        await sleep(30);
        const middle = Date.now();
        page.fire("activated", { tabId: 4, windowId: 1 });
        const after = Date.now();
        await sleep(200);
        const reports = page.ofType("activated");
        check(reports.length === 2, "both activations are reported");
        check(reports.every((report) => Number.isInteger(report.at)), "activated reports carry a timestamp (Date.now())");
        if (reports.length === 2 && reports.every((report) => Number.isInteger(report.at))) {
            check(reports[0].at >= before && reports[0].at <= middle, "a report is stamped when the switch was seen");
            check(reports[1].at >= middle && reports[1].at <= after, "and the next one is stamped when that happened");
        }
    }

    // --- #19 item 2: each snapshot says when its build started, before it asked Safari anything ---
    {
        const page = load({ queryDelay: 80 });
        await settled(page);

        const before = Date.now();
        page.fire("windows.focus", 1);               // starts a snapshot build (80 ms query)
        await sleep(20);
        page.fire("activated", { tabId: 2, windowId: 1 });
        await sleep(400);
        const entry = page.sent.find((item) => item.message.type === "snapshot");
        const report = page.ofType("activated")[0];
        check(!!entry && !!report, "a snapshot and a report were sent");
        if (entry && report) {
            const snapshot = entry.message;
            check(Number.isInteger(snapshot.startedAt), "snapshots carry the time their build started (Date.now())");
            if (Number.isInteger(snapshot.startedAt)) {
                check(snapshot.startedAt >= before, "it is a current time");
                check(entry.at - snapshot.startedAt >= 60,
                    `it is when the build started, not when it finished: the queries took 80 ms (sent ${entry.at - snapshot.startedAt} ms later)`);
                check(snapshot.startedAt < report.at, "a snapshot started before an activation is stamped before it");
                const next = page.ofType("snapshot").find((item) => item.seq > report.seq);
                check(!next || next.startedAt >= report.at, "and the one the activation asks for is stamped after it");
            }
        }
    }

    // --- #17 item 8: changes the sidebar shows reach it, whatever key Safari reports them under ---
    {
        const page = load();
        await settled(page);
        const snapshotsAfter = async (action) => {
            page.sent.length = 0;
            action();
            await sleep(450);
            return page.ofType("snapshot").length;
        };
        const unchanged = { ...page.tabs[0] };

        check((await snapshotsAfter(() => page.fire("updated", 1, { title: "New" }, { ...unchanged, title: "New" }))) >= 1,
            "a title change is sent");
        check((await snapshotsAfter(() => page.fire("updated", 1, { status: "loading" }, { ...unchanged, title: "New", status: "loading" }))) >= 1,
            "a status change is sent");
        check((await snapshotsAfter(() => page.fire("updated", 1, { mutedInfo: { muted: true } }, { ...unchanged, title: "New", status: "loading" }))) >= 1,
            "a mute change is sent");
        check((await snapshotsAfter(() => page.fire("updated", 1, { unreadCount: 3 }, { ...unchanged, title: "New" }))) >= 1,
            "a key nobody knew about is sent");
        check((await snapshotsAfter(() => page.fire("updated", 1, {}, { ...unchanged, title: "New" }))) >= 1,
            "an empty changeInfo is sent");

        // The snapshots above rebuilt lastShown from the tab list, which still says "Tab 1".
        // Changes that really aren't shown stay quiet:
        check((await snapshotsAfter(() => page.fire("updated", 1, { isArticle: true }, { ...unchanged }))) === 0,
            "a change the sidebar doesn't show is not sent");
        check((await snapshotsAfter(() => page.fire("updated", 1, { attention: true, isInReaderMode: false }, { ...unchanged }))) === 0,
            "several unshown changes are not sent");

        // ...unless the tab itself shows that something the sidebar displays has changed.
        check((await snapshotsAfter(() => page.fire("updated", 1, { isArticle: true }, { ...unchanged, title: "(3) Inbox" }))) >= 1,
            "a title change reported without a title key is still sent");
        const logs = page.ofType("log").map((message) => message.message);
        check(logs.some((line) => line.includes("shown change reported only as: isArticle")),
            "the app is told when Safari reports a shown change without its key");
    }

    {
        // Which keys Safari sends is reported once per distinct set, not once per event.
        const page = load();
        await settled(page);
        for (let i = 0; i < 20; i++) page.fire("updated", 1, { title: `t${i}` }, { ...page.tabs[0], title: `t${i}` });
        page.fire("updated", 1, { status: "loading", title: "x" }, { ...page.tabs[0] });
        page.fire("updated", 1, { title: "z", status: "complete" }, { ...page.tabs[0] });
        await sleep(300);
        const keyLogs = page.ofType("log").map((message) => message.message).filter((line) => line.includes("changeInfo keys"));
        check(keyLogs.length === 2, `each distinct key set is logged once (got ${JSON.stringify(keyLogs)})`);
        check(keyLogs.some((line) => line.endsWith("changeInfo keys: status,title")), "keys are sorted so the same set always reads the same");
    }

    {
        // A page loading fires a stream of updates; they still go out spaced apart, not one each.
        const page = load();
        await settled(page);
        for (let i = 0; i < 40; i++) {
            page.fire("updated", 1, { title: `x${i}` }, { ...page.tabs[0], title: `x${i}` });
            await sleep(10);
        }
        await sleep(700);
        const count = page.ofType("snapshot").length;
        check(count > 0 && count <= 6, `40 title updates over ~0.4 s sent ${count} snapshots`);
    }

    // --- #21 item 2: Safari sends no tabs.onUpdated for a mute, so the app is sent a snapshot ---
    {
        const page = load();
        await settled(page);
        await page.run({ action: "mute", tabId: 2, muted: true });
        await sleep(200);
        check(page.updates.length === 1 && page.updates[0].props.muted === true, "the mute command mutes the tab");
        check(page.ofType("snapshot").length >= 1, "and a snapshot follows it, without Safari reporting any update");

        page.sent.length = 0;
        await page.run({ action: "mute", tabId: 2, muted: false });
        await sleep(200);
        check(page.ofType("snapshot").length >= 1, "and one follows an unmute");
    }

    {
        // The commands Safari reports on its own aren't given a second snapshot.
        const page = load();
        await settled(page);
        page.updates.length = 0;
        await page.run({ action: "activate", tabId: 2 });
        await sleep(100);
        check(page.updates.length === 1 && page.updates[0].props.active === true, "the activate command switches the tab");
        check(page.ofType("snapshot").length === 0, "and sends no snapshot of its own: Safari reports the switch");
    }

    // --- #27: a tab reopened from cleanup's list in another profile's window brings that window forward ---
    {
        const page = load();
        await settled(page);
        await page.run({ action: "create", windowId: 5, url: "https://example.com/back", focus: true });
        check(page.created.length === 1 && page.created[0].windowId === 5 && page.created[0].url === "https://example.com/back",
            "the create command opens the page in the window it names");
        check(page.windowUpdates.length === 1 && page.windowUpdates[0].id === 5 && page.windowUpdates[0].props.focused === true,
            "and, asked to, brings that window forward");
        await page.run({ action: "create", windowId: 1, url: "https://example.com/here" });
        check(page.created.length === 2 && page.windowUpdates.length === 1, "otherwise no window is brought forward");
    }

    // --- #31: no lost reply can stop a copy ---
    // These run background.js's timers 50 times faster: its 4 s time limit takes 80 ms here.
    const FAST = 0.02;
    const LIMIT = 4000 * FAST;

    {
        // A snapshot whose reply never comes doesn't hold up the ones after it.
        let lost = 0;
        const page = load({ timeScale: FAST, queryDelay: 2, reply: (message) => {
            if (message.type === "snapshot" && lost === 0) {
                lost++;
                return HANG;
            }
            return { appRunning: true };
        } });
        await sleep(LIMIT * 3);
        check(lost === 1, "the first snapshot's reply was lost");
        check(page.ofType("snapshot").length >= 2, "a snapshot whose reply never comes is sent again");
        check(page.state("sending") === false, "and the copy isn't left waiting for that reply");
        const logs = page.ofType("log").map((message) => message.message);
        check(logs.some((line) => line.startsWith(`no reply within 4000 ms to "snapshot"`)), "and the app's log hears of the lost reply");
        page.sent.length = 0;
        page.fire("windows.removed", 1);
        await sleep(50);
        check(page.ofType("snapshot").length === 1, "a later change is still sent");
    }

    {
        // While every snapshot's reply is lost, changes keep going out, one snapshot per time limit rather than
        // in a burst, and heartbeats go on.
        const page = load({ timeScale: FAST, queryDelay: 2, reply: (message) => (message.type === "snapshot" ? HANG : { appRunning: true }) });
        const started = Date.now();
        while (Date.now() - started < LIMIT * 8) {
            page.fire("updated", 1, { title: "x" }, { ...page.tabs[0], title: `x${Date.now()}` });
            await sleep(10);
        }
        const times = page.sent.filter((entry) => entry.message.type === "snapshot").map((entry) => entry.at);
        check(times.length >= 5, `snapshots keep going out while their replies are lost (${times.length} in ${LIMIT * 8} ms)`);
        const gaps = times.slice(1).map((at, i) => at - times[i]);
        check(gaps.every((gap) => gap >= LIMIT - 10), `one at a time, each after the last one's time limit (gaps ${gaps.join(", ")} ms)`);
        page.heartbeat();
        page.heartbeat();
        check(page.ofType("heartbeat").length === 2, "and heartbeats still go out");
    }

    {
        // A hello whose reply never comes: snapshots and heartbeats start anyway, without waiting for it.
        const page = load({ timeScale: FAST, queryDelay: 2, reply: (message) => (message.type === "hello" ? HANG : { appRunning: true }) });
        await sleep(LIMIT / 2);
        check(page.ofType("hello").length === 1, "the hello was sent");
        check(page.ofType("snapshot").length >= 1, "the first snapshot doesn't wait for the hello's reply");
        check(page.intervals.some((entry) => entry.ms === 5000), "heartbeats are started without waiting for it either");
        page.heartbeat();
        check(page.ofType("heartbeat").length === 1, "and they go out");
        await sleep(LIMIT * 4);
        check(page.ofType("hello").length === 1, "since the snapshots had replies, the hello isn't sent again");
    }

    {
        // Nothing has a reply: the hello is sent again, with back-off, a few times at most.
        const page = load({ timeScale: FAST, queryDelay: 2, reply: () => HANG });
        await sleep(1500);
        const hellos = page.sent.filter((entry) => entry.message.type === "hello").map((entry) => entry.at);
        check(hellos.length === 6, `with no reply to anything, the hello is sent again 5 times (sent ${hellos.length})`);
        const gaps = hellos.slice(1).map((at, i) => at - hellos[i]);
        check(gaps.every((gap, i) => i === 0 || gap > gaps[i - 1]), `further and further apart (gaps ${gaps.join(", ")} ms)`);
        check(page.ofType("snapshot").length >= 3, "and snapshots keep being tried");
        check(page.intervals.some((entry) => entry.ms === 5000), "and heartbeats run");
    }

    {
        // Safari never answers which window was focused last: the copy starts anyway.
        const stuck = load({ timeScale: FAST, queryDelay: 2, hangLastFocused: true });
        await sleep(150);
        check(stuck.ofType("hello").length === 1 && stuck.ofType("snapshot").length >= 1,
            "a copy whose question about the focused window is never answered still says hello and sends snapshots");
    }

    {
        // A reply that turns up after its time limit: its request for a snapshot is used, its commands aren't.
        let answerLate;
        const page = load({ timeScale: FAST, queryDelay: 2, reply: (message) => {
            if (message.type === "snapshot" && !answerLate) return new Promise((resolve) => { answerLate = resolve; });
            return { appRunning: true };
        } });
        await sleep(LIMIT * 3);
        check(!!answerLate, "the first snapshot is waiting for its reply");
        page.sent.length = 0;
        page.updates.length = 0;
        answerLate({ appRunning: true, needSnapshot: true, commands: [{ action: "activate", tabId: 3 }] });
        await sleep(50);
        check(page.updates.length === 0, "a command in a reply that came after the time limit isn't run");
        check(page.ofType("snapshot").length === 1, "but its request for a snapshot is");
        check(page.ofType("log").some((message) => message.message.startsWith(`the reply to "snapshot" came`)),
            "and the app's log hears of the late reply");
        check(page.state("sending") === false, "and nothing is left waiting");
    }

    {
        // A reply on time still has its commands run.
        let answered = false;
        const page = load({ timeScale: FAST, queryDelay: 2, reply: (message) => {
            if (message.type === "heartbeat" && !answered) {
                answered = true;
                return { appRunning: true, commands: [{ action: "activate", tabId: 2 }] };
            }
            return { appRunning: true };
        } });
        await settled(page);
        page.heartbeat();
        await sleep(20);
        check(page.updates.length === 1 && page.updates[0].id === 2, "a command in a reply that came in time is run");
    }

    {
        // A tab switch report whose reply is lost doesn't hold up the snapshot it asks for, and its late reply
        // can't run a command.
        let answerLate;
        const page = load({ timeScale: FAST, queryDelay: 2, reply: (message) => {
            if (message.type === "activated") return new Promise((resolve) => { answerLate = resolve; });
            return { appRunning: true };
        } });
        await settled(page);
        page.fire("activated", { tabId: 3, windowId: 1 });
        await sleep(30);
        check(page.ofType("snapshot").length === 1, "a switch report waiting for its reply doesn't hold up the snapshot after it");
        await sleep(LIMIT * 2);
        page.updates.length = 0;
        answerLate({ appRunning: true, commands: [{ action: "activate", tabId: 4 }] });
        await sleep(30);
        check(page.updates.length === 0, "and a late reply to the report runs no command");
        check(page.ofType("activated").length === 1, "the report isn't sent again: the snapshot covers it");
    }

    {
        // The report of a tab opened for a bookmark is sent again until it's delivered: without it the tab
        // stays under Tabs. The app ignores a repeat.
        let tries = 0;
        const page = load({ timeScale: FAST, queryDelay: 2, reply: (message) => {
            if (message.type === "created") return ++tries === 1 ? HANG : { appRunning: true };
            return { appRunning: true };
        } });
        await settled(page);
        await page.run({ action: "create", windowId: 1, url: "https://example.com/new", requestId: "r1" });
        await sleep(LIMIT * 4);
        const reports = page.ofType("created");
        check(reports.length === 2, `a "created" report that got no reply is sent again, and not after it's delivered (sent ${reports.length})`);
        check(reports.every((report) => report.requestId === "r1" && report.tabId === 101), "the same report each time");

        const away = load({ timeScale: FAST, queryDelay: 2, reply: (message) => ({ appRunning: message.type !== "created" }) });
        await settled(away);
        await away.run({ action: "create", windowId: 1, url: "https://example.com/new", requestId: "r2" });
        await sleep(LIMIT * 4);
        check(away.ofType("created").length === 3, `while the app doesn't take it, it's tried 3 times (sent ${away.ofType("created").length})`);
    }

    {
        // The toolbar button's toggle isn't sent again: it may have arrived, and a second one would undo it.
        const page = load({ timeScale: FAST, queryDelay: 2, reply: (message) => (message.type === "toggleSidebar" ? HANG : { appRunning: true }) });
        await settled(page);
        page.fire("action");
        await sleep(LIMIT * 4);
        check(page.ofType("toggleSidebar").length === 1, "a toggle whose reply is lost isn't sent again");
    }

    if (failures === 0) {
        console.log("extension checks passed");
        process.exit(0);
    }
    console.log(`${failures} extension check(s) failed`);
    process.exit(1);
})();
