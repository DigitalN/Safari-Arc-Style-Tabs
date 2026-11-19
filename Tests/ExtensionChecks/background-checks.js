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
// themselves; `heartbeat()` sends one as the timer would. `ports` are the ports background.js connected
// for the app's commands, oldest first: `deliver(command)` sends one through a port as Safari would, and
// `drop()` has Safari report it disconnected. The first `connectFails` attempts to connect throw.
// `quiet` keeps background.js's warnings out of the output, for a check that expects them.
function load({ queryDelay = 20, tabCount = 5, reply = () => ({ appRunning: true }), timeScale = 1, hangLastFocused = false, connectFails = 0, quiet = false } = {}) {
    const sent = [];
    let queries = 0;
    const updates = [];
    const created = [];
    const windowUpdates = [];
    const windowsCreated = [];
    const intervals = [];
    const ports = [];
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
            create: async (props) => { windowsCreated.push(props); return { id: 9, focused: !!props.focused, tabs: [{ id: 900, windowId: 9 }] }; },
            onCreated: event("windows.created"), onRemoved: event("windows.removed"), onFocusChanged: event("windows.focus"),
        },
        tabs: {
            query: async () => { queries++; await sleep(queryDelay); return tabs.map((tab) => ({ ...tab })); },
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
            connectNative: () => {
                if (connectFails > 0) {
                    connectFails--;
                    throw new Error("no port");
                }
                const port = {
                    messageListeners: [], disconnectListeners: [], disconnected: false,
                    onMessage: { addListener: (fn) => port.messageListeners.push(fn) },
                    onDisconnect: { addListener: (fn) => port.disconnectListeners.push(fn) },
                    disconnect: () => { port.disconnected = true; },
                    deliver: (command) => port.messageListeners.forEach((fn) => fn({ name: "command", userInfo: command })),
                    drop: () => port.disconnectListeners.forEach((fn) => fn()),
                };
                ports.push(port);
                return port;
            },
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
        browser, console: quiet ? { ...console, warn: () => {} } : console, setTimeout: timer, clearTimeout,
        setInterval: (fn, ms) => intervals.push({ fn, ms }), crypto: { randomUUID: () => "test-instance" },
        URL, fetch: async () => ({}), AbortController, FileReader: class {}, Date, Math,
    });
    vm.runInContext(source.replace('"use strict";', ""), context);
    const fire = (name, ...args) => (listeners[name] || []).forEach((fn) => fn(...args));
    const ofType = (type) => sent.filter((entry) => entry.message.type === type).map((entry) => entry.message);
    // The messages about the windows: full snapshots, and the changes since the last one (#81).
    const states = () => sent.filter((entry) => isState(entry.message)).map((entry) => entry.message);
    // Carries out a command from the app, as the port or a reply would deliver it.
    const run = (command) => context.runCommand({ instance: "test-instance", ...command });
    const heartbeat = () => intervals.filter((entry) => entry.ms === 5000).forEach((entry) => entry.fn());
    // Reads one of background.js's top-level variables.
    const state = (name) => vm.runInContext(name, context);
    // How many times Safari was asked for every tab.
    const queryCount = () => queries;
    return { sent, tabs, updates, created, windowUpdates, windowsCreated, intervals, ports, fire, ofType, states, run, heartbeat, state, queryCount };
}

const isState = (message) => message.type === "snapshot" || message.type === "changes";

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
        const snapshots = page.states();
        check(snapshots.length >= 1, "a snapshot follows an activation");
        const numbers = [...reports, ...snapshots].map((message) => message.seq);
        check(new Set(numbers).size === numbers.length, "snapshots and reports never reuse a number");
    }

    {
        // A snapshot that was already being built when the activation happened is numbered
        // before it, because the activation might not be in the snapshot's data.
        const page = load({ queryDelay: 60 });
        await settled(page);

        page.run({ action: "snapshot" });            // starts a snapshot build (60 ms query)
        await sleep(10);
        page.fire("activated", { tabId: 2, windowId: 1 });
        await sleep(400);
        const report = page.ofType("activated")[0];
        const first = page.states()[0];
        check(report && first, "both a report and a snapshot were sent");
        if (report && first) {
            check(first.seq < report.seq, "a snapshot started before an activation is numbered before it");
            const later = page.states().find((snapshot) => snapshot.seq > report.seq);
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
        const snapshots = page.states();
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
        page.run({ action: "snapshot" });            // starts a snapshot build (80 ms query)
        await sleep(20);
        page.fire("activated", { tabId: 2, windowId: 1 });
        await sleep(400);
        const entry = page.sent.find((item) => isState(item.message));
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
                const next = page.states().find((item) => item.seq > report.seq);
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
            return page.states().length;
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
        const count = page.states().length;
        check(count > 0 && count <= 6, `40 title updates over ~0.4 s sent ${count} snapshots`);
    }

    // --- #21 item 2: Safari sends no tabs.onUpdated for a mute, so the app is sent a snapshot ---
    {
        const page = load();
        await settled(page);
        await page.run({ action: "mute", tabId: 2, muted: true });
        await sleep(200);
        check(page.updates.length === 1 && page.updates[0].props.muted === true, "the mute command mutes the tab");
        check(page.states().length >= 1, "and a snapshot follows it, without Safari reporting any update");

        page.sent.length = 0;
        await page.run({ action: "mute", tabId: 2, muted: false });
        await sleep(200);
        check(page.states().length >= 1, "and one follows an unmute");
    }

    {
        // The commands Safari reports on its own aren't given a second snapshot.
        const page = load();
        await settled(page);
        page.updates.length = 0;
        await page.run({ action: "activate", tabId: 2 });
        await sleep(100);
        check(page.updates.length === 1 && page.updates[0].props.active === true, "the activate command switches the tab");
        check(page.states().length === 0, "and sends no snapshot of its own: Safari reports the switch");
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

    // --- #41: a pinned item clicked in a window Safari doesn't share with the copy opens in a new window ---
    {
        const page = load();
        await settled(page);
        await page.run({ action: "openWindow", url: "https://example.com/pinned" });
        check(page.windowsCreated.length === 1 && page.windowsCreated[0].url === "https://example.com/pinned" && page.windowsCreated[0].focused === true,
            "the openWindow command opens a new, focused window with the page");
        check(page.created.length === 0, "and no tab in another window");
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
        check(page.states().length >= 2, "a snapshot whose reply never comes is sent again");
        check(page.state("sending") === false, "and the copy isn't left waiting for that reply");
        const logs = page.ofType("log").map((message) => message.message);
        check(logs.some((line) => line.startsWith(`no reply within 4000 ms to "snapshot"`)), "and the app's log hears of the lost reply");
        page.sent.length = 0;
        page.fire("windows.removed", 1);
        await sleep(50);
        check(page.states().length === 1, "a later change is still sent");
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
        const times = page.sent.filter((entry) => isState(entry.message)).map((entry) => entry.at);
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
        check(page.states().length >= 1, "the first snapshot doesn't wait for the hello's reply");
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
        check(page.states().length >= 3, "and snapshots keep being tried");
        check(page.intervals.some((entry) => entry.ms === 5000), "and heartbeats run");
    }

    {
        // Safari never answers which window was focused last: the copy starts anyway.
        const stuck = load({ timeScale: FAST, queryDelay: 2, hangLastFocused: true });
        await sleep(150);
        check(stuck.ofType("hello").length === 1 && stuck.states().length >= 1,
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
        check(page.states().length === 1, "but its request for a snapshot is");
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
        check(page.states().length === 1, "a switch report waiting for its reply doesn't hold up the snapshot after it");
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

    {
        // Lost replies are logged by message type, often at first and then more and more rarely, so a copy
        // that loses every heartbeat's reply for minutes stays visible in the log without filling it.
        const page = load({ timeScale: FAST, queryDelay: 2, reply: (message) => (message.type === "heartbeat" ? HANG : { appRunning: true }) });
        await settled(page);
        for (let i = 0; i < 13; i++) page.heartbeat();
        await sleep(LIMIT * 2);
        const lines = page.ofType("log").map((message) => message.message).filter((line) => line.includes(`to "heartbeat"`));
        check(lines.length === 6, `13 lost heartbeat replies are logged 6 times: the first five and the 10th (got ${lines.length})`);
        check(lines.at(-1)?.includes("(10 so far)"), "each line says how many so far");
        check(!page.ofType("log").some((message) => message.message.includes(`to "snapshot"`)), "and other types are counted apart");
    }

    // --- #37: a command runs once, however many times it arrives ---

    const activations = (page) => page.updates.filter((update) => update.props.active === true).map((update) => update.id);
    const logLines = (page) => page.ofType("log").map((message) => message.message);

    {
        // The same command delivered twice through one port runs once.
        const page = load({ timeScale: FAST, queryDelay: 2 });
        await settled(page);
        check(page.ports.length === 1, "background.js connects one port for the app's commands");
        page.ports[0].deliver({ action: "activate", tabId: 2, id: "L-1" });
        page.ports[0].deliver({ action: "activate", tabId: 2, id: "L-1" });
        await sleep(20);
        check(JSON.stringify(activations(page)) === "[2]", `a command that arrives twice runs once (ran for tabs ${JSON.stringify(activations(page))})`);
        check(logLines(page).some((line) => line.startsWith(`skipped a repeated command ("activate"), both times through port 1`)),
            "and the log says it came twice through the same port");
        page.ports[0].deliver({ action: "activate", tabId: 3, id: "L-2" });
        await sleep(20);
        check(JSON.stringify(activations(page)) === "[2,3]", "a command with another id runs");
        page.ports[0].deliver({ action: "activate", tabId: 4 });
        page.ports[0].deliver({ action: "activate", tabId: 4 });
        await sleep(20);
        check(JSON.stringify(activations(page)) === "[2,3,4,4]", "commands without an id, from an older app, run every time");
    }

    {
        // A command that came through one port and comes again through the port that replaced it runs once,
        // and the log tells the two ways apart.
        const page = load({ timeScale: FAST, queryDelay: 2 });
        await settled(page);
        page.ports[0].deliver({ action: "activate", tabId: 2, id: "L-1" });
        page.ports[0].drop();
        check(page.ports.length === 1, "a port isn't replaced at once when Safari says it disconnected");
        page.ports[0].deliver({ action: "activate", tabId: 3, id: "L-2" });
        await sleep(20);
        check(JSON.stringify(activations(page)) === "[2,3]", "a command still coming through it meanwhile isn't lost");
        await sleep(3000 * FAST + 30);
        check(page.ports.length === 2, "3 s later a new port is connected");
        check(page.ports[0].disconnected, "and the old one is disconnected first");
        check(logLines(page).some((line) => line.startsWith("port 1 disconnected")) && logLines(page).includes("connected port 2"),
            "the log shows the port changing");
        page.ports[1].deliver({ action: "activate", tabId: 2, id: "L-1" });
        await sleep(20);
        check(JSON.stringify(activations(page)) === "[2,3]", "a command that comes again through the new port isn't run again");
        check(logLines(page).some((line) => line.includes("first through port 1, then through port 2")), "and the log names both ports");

        // The old port goes on delivering: none of it is run.
        page.ports[0].deliver({ action: "activate", tabId: 4, id: "L-3" });
        page.ports[1].deliver({ action: "activate", tabId: 5, id: "L-4" });
        await sleep(20);
        check(JSON.stringify(activations(page)) === "[2,3,5]", "a message through a port that was replaced is ignored, one through the current port isn't");
        check(logLines(page).some((line) => line.startsWith("ignored a message through port 1, which port 2 replaced")),
            "and the log says a replaced port still delivered");

        // The old port's disconnect, coming late, doesn't drop the current port.
        page.ports[0].drop();
        await sleep(3000 * FAST * 2);
        check(page.ports.length === 2 && !page.ports[1].disconnected, "an old port's disconnect doesn't drop the current port");
        page.ports[1].deliver({ action: "activate", tabId: 1, id: "L-5" });
        await sleep(20);
        check(activations(page).at(-1) === 1, "which still runs commands");

        // Safari reporting the current port disconnected twice leads to one new port, not two.
        page.ports[1].drop();
        page.ports[1].drop();
        await sleep(3000 * FAST * 3);
        check(page.ports.length === 3, `two disconnects of one port connect one new port (${page.ports.length - 2} connected)`);
    }

    {
        // A failed connect is tried again once, after 5 s.
        const page = load({ timeScale: FAST, queryDelay: 2, connectFails: 1, quiet: true });
        await sleep(5000 * FAST + 50);
        check(page.ports.length === 1, `after a failed connect, one port is connected later (${page.ports.length})`);
        page.ports[0]?.deliver({ action: "activate", tabId: 3, id: "L-1" });
        await sleep(20);
        check(JSON.stringify(activations(page)) === "[3]", "and it runs commands");
    }

    {
        // A command for another copy is left alone, and doesn't use up its id here.
        const page = load({ timeScale: FAST, queryDelay: 2 });
        await settled(page);
        page.ports[0].deliver({ action: "activate", tabId: 2, id: "L-1", instance: "another-copy" });
        await sleep(20);
        check(activations(page).length === 0 && !logLines(page).some((line) => line.startsWith("skipped")),
            "a command for another copy isn't run, and isn't counted as a repeat");
    }


    // --- #81: changes, not everything ---

    // What one tab in the stand-in looks like to Safari's tabs.onUpdated.
    const updateTab = (page, id, change) => {
        const tab = page.tabs.find((item) => item.id === id);
        Object.assign(tab, change);
        page.fire("updated", id, change, { ...tab });
    };
    const lastState = (page) => page.states().at(-1);

    {
        // After the first snapshot, a change sends only the tab that changed, counted from the last state the app took.
        const page = load();
        await settled(page);
        const base = page.state("sentSeq");
        check(base > 0, "the first snapshot was delivered");
        updateTab(page, 2, { title: "Renamed" });
        await sleep(400);
        const states = page.states();
        check(states.length === 1 && states[0].type === "changes", `a title change sends changes, not a snapshot (sent ${states.map((m) => m.type)})`);
        const changes = states[0];
        if (changes) {
            check(changes.base === base, "counted from the last state the app took");
            check(changes.seq > base, "and numbered after it");
            check(Number.isInteger(changes.startedAt), "stamped with when it was taken, like a snapshot");
            check(changes.tabs?.length === 1 && changes.tabs[0].id === 2 && changes.tabs[0].title === "Renamed",
                `with only the changed tab, whole (${JSON.stringify(changes.tabs)})`);
            check(!changes.windows && !changes.windowIds && !changes.focus, "and nothing about windows or focus");
            check(page.state("sentSeq") === changes.seq, "the heartbeat names the changes once they're delivered");
        }

        // The next change is counted from those changes.
        page.sent.length = 0;
        updateTab(page, 3, { status: "loading" });
        await sleep(400);
        const next = lastState(page);
        check(next?.type === "changes" && next.base === changes?.seq && next.tabs?.length === 1 && next.tabs[0].loading === true,
            "the next changes are counted from the last ones");

        // A change that ends where it began sends only a number and a time.
        page.sent.length = 0;
        updateTab(page, 3, { status: "complete" });
        updateTab(page, 3, { status: "loading" });
        await sleep(400);
        const same = lastState(page);
        check(same?.type === "changes" && JSON.stringify(Object.keys(same).sort()) === JSON.stringify(["base", "instance", "seq", "startedAt", "type"]),
            `a state that matches the last one sends only its number and time (${JSON.stringify(same)})`);
        check(JSON.stringify(same ?? {}).length < 150, "which is a few bytes");
    }

    {
        // Moving or closing a tab sends the window's new list of tabs, and no tab.
        const page = load();
        await settled(page);
        page.tabs[0].index = 2;
        page.tabs[2].index = 0;
        page.fire("moved", 1, { windowId: 1, fromIndex: 0, toIndex: 2 });
        await sleep(200);
        const moved = lastState(page);
        check(moved?.type === "changes" && JSON.stringify(moved.windows) === JSON.stringify([{ id: 1, focused: true, incognito: false, tabIds: [3, 2, 1, 4, 5] }]),
            `a move sends the window's tabs in their new order (${JSON.stringify(moved?.windows)})`);
        check(moved && !moved.tabs, "and no tab: a tab's place isn't part of it");

        page.sent.length = 0;
        page.tabs.splice(1, 1);
        page.tabs.forEach((tab) => { if (tab.index > 1) tab.index -= 1; });
        page.fire("removed", 2, { windowId: 1 });
        await sleep(200);
        const closed = lastState(page);
        check(closed?.type === "changes" && JSON.stringify(closed.windows?.[0]?.tabIds) === JSON.stringify([3, 1, 4, 5]) && !closed.tabs,
            `a closed tab is left out of its window's list, and no other tab is sent (${JSON.stringify(closed)})`);

        // A new window with a tab: the windows in order, the new window, and its tab.
        page.sent.length = 0;
        page.tabs.push({ id: 20, windowId: 2, index: 0, title: "Other", url: "https://example.com/other", active: true });
        page.fire("windows.created", { id: 2 });
        await sleep(200);
        const opened = lastState(page);
        check(opened?.type === "changes" && JSON.stringify(opened.windowIds) === "[1,2]", "a new window sends the windows in order");
        check(JSON.stringify(opened?.windows) === JSON.stringify([{ id: 2, focused: false, incognito: false, tabIds: [20] }]), "and the new window with its tabs");
        check(opened?.tabs?.length === 1 && opened.tabs[0].id === 20, "and its tab");
    }

    {
        // Focus moving, in or out of Safari, sends the new focus without asking Safari for every tab again, in every
        // profile's copy. Switching away from Safari and back sends no full snapshot.
        const page = load();
        await settled(page);
        const queries = page.queryCount();
        page.fire("windows.focus", -1);
        await sleep(100);
        const away = lastState(page);
        check(away?.type === "changes", "focus leaving Safari sends changes");
        check(away?.focus?.focusedWindowId === -1 && away.focus.lastFocusedWindowId === 1 && Number.isFinite(away.focus.focusChangedAt),
            `with the new focus (${JSON.stringify(away?.focus)})`);
        check(JSON.stringify(away?.windows) === JSON.stringify([{ id: 1, focused: false, incognito: false }]), "and the window that lost it, without its tabs");
        check(away && !away.tabs, "and no tab");
        page.fire("windows.focus", 1);
        await sleep(100);
        const back = lastState(page);
        check(back?.type === "changes" && back.focus?.focusedWindowId === 1 && back.base === away?.seq, "focus coming back sends changes too");
        check(page.queryCount() === queries, `and Safari wasn't asked for its tabs for either (${page.queryCount() - queries} times)`);
        check(page.states().every((message) => message.type === "changes"), "no full snapshot was sent");
        check(!!back && !!away && back.startedAt === away.startedAt && back.startedAt < away.focus.focusChangedAt,
            "its time is that of the tabs it carries, from before focus moved");

        // Focus moving to a window the app hasn't been told of asks Safari: it restores windows without saying so.
        page.sent.length = 0;
        page.tabs.push({ id: 40, windowId: 4, index: 0, title: "Restored", url: "https://example.com/restored", active: true });
        page.fire("windows.focus", 4);
        await sleep(100);
        check(page.queryCount() === queries + 1, "focus moving to a window the app hasn't got asks Safari");
        check(JSON.stringify(lastState(page)?.windowIds) === "[1,4]" && lastState(page)?.focus?.focusedWindowId === 4,
            "and sends the window with the focus");
        page.fire("windows.focus", 1);
        await sleep(100);

        // A focus change with a change to a tab still on its way asks Safari.
        page.sent.length = 0;
        updateTab(page, 4, { title: "Busy" });
        page.fire("windows.focus", -1);
        await sleep(100);
        check(page.queryCount() === queries + 2, "a focus change after a tab change asks Safari");
        const both = lastState(page);
        check(both?.focus?.focusedWindowId === -1 && both.tabs?.some((tab) => tab.id === 4 && tab.title === "Busy"),
            "and sends both");
    }

    {
        // A full snapshot again: for a snapshot command, when a reply asks for one, and after a message that wasn't
        // delivered.
        let refuse = 0;
        let askAgain = 0;
        const page = load({ reply: (message) => {
            if (message.type === "changes" && refuse > 0) { refuse--; return { appRunning: false }; }
            if (message.type === "changes" && askAgain > 0) { askAgain--; return { appRunning: true, needSnapshot: true }; }
            return { appRunning: true };
        } });
        await settled(page);
        await page.run({ action: "snapshot" });
        await sleep(100);
        check(lastState(page)?.type === "snapshot", "a snapshot command sends a full snapshot, even with nothing changed");

        page.sent.length = 0;
        refuse = 1;
        updateTab(page, 2, { title: "Lost" });
        await sleep(800);
        const afterLoss = page.states().map((message) => message.type);
        check(JSON.stringify(afterLoss) === JSON.stringify(["changes", "snapshot"]), `changes that weren't delivered are followed by a full snapshot (${afterLoss})`);

        page.sent.length = 0;
        askAgain = 1;
        updateTab(page, 2, { title: "Gap" });
        await sleep(400);
        const afterGap = page.states().map((message) => message.type);
        check(JSON.stringify(afterGap) === JSON.stringify(["changes", "snapshot"]), `a reply that asks for a snapshot gets a full one (${afterGap})`);
        check(page.state("sentSeq") === lastState(page)?.seq, "and the heartbeat names the full one, not the changes the app didn't take");

        page.sent.length = 0;
        page.heartbeat();
        await sleep(10);
        page.sent.length = 0;
        updateTab(page, 2, { title: "Fine" });
        await sleep(400);
        check(lastState(page)?.type === "changes", "after that, changes again");
    }

    {
        // Now and then a change goes out as a full snapshot, in case the app's copy has drifted; a state with nothing
        // new doesn't.
        const page = load();
        await settled(page);
        page.state("lastFullSnapshotAt = Date.now() - FULL_SNAPSHOT_MS - 1");
        page.fire("updated", 1, { status: "complete" }, { ...page.tabs[0] });
        await sleep(400);
        check(lastState(page)?.type === "changes", "a state with nothing new isn't made a full snapshot");
        page.sent.length = 0;
        updateTab(page, 1, { title: "Later" });
        await sleep(400);
        check(lastState(page)?.type === "snapshot", "a change long after the last full snapshot is sent as one");
        page.sent.length = 0;
        updateTab(page, 1, { title: "Later still" });
        await sleep(400);
        check(lastState(page)?.type === "changes", "and the next one as changes");
    }

    {
        // A page's icon in a data: URL goes to the app once, by a short name, never in the snapshots.
        const page = load();
        await settled(page);
        const dataURL = "data:image/png;base64," + "QUJD".repeat(500);
        page.fire("runtime.message", { type: "favicon", url: dataURL }, { tab: { id: 2 } });
        await sleep(200);
        const withIcon = lastState(page);
        const name = withIcon?.tabs?.find((tab) => tab.id === 2)?.favIconUrl;
        check(typeof name === "string" && name.startsWith("sidetabs-icon:") && name.length < 40, `the snapshot carries a short name for the icon (${name?.slice(0, 40)})`);
        check(!JSON.stringify(page.states()).includes("data:"), "and never the data: URL");
        const icons = page.ofType("icon");
        check(icons.length === 1 && icons[0].url === name && icons[0].data === "QUJD".repeat(500), "the icon goes to the app once, under that name");
        updateTab(page, 2, { title: "Again" });
        await page.run({ action: "snapshot" });
        await sleep(400);
        check(page.ofType("icon").length === 1, "and isn't sent again with later changes or snapshots");
        check(page.states().filter((message) => message.type === "snapshot").at(-1)?.windows[0].tabs[1].favIconUrl === name,
            "full snapshots carry the same name");
        await page.run({ action: "fetchIcons", urls: [name] });
        await sleep(50);
        check(page.ofType("icon").length === 2 && page.ofType("icon")[1].data === "QUJD".repeat(500), "the app can ask for it by name");
        await page.run({ action: "fetchIcons", urls: ["sidetabs-icon:unknown"] });
        await sleep(50);
        check(page.ofType("icon").length === 3 && page.ofType("icon")[2].data === null, "a name this copy doesn't know gets no icon");
    }

    {
        // Changes in a window the sidebar isn't showing wait longer: about a second after the last state, rather than
        // a quarter of one.
        const page = load();
        await settled(page);
        page.tabs.push({ id: 30, windowId: 2, index: 0, title: "Back", url: "https://example.com/back", active: true });
        page.fire("windows.created", { id: 2 });
        await sleep(100);
        const flushed = page.sent.filter((entry) => isState(entry.message)).at(-1)?.at;
        page.sent.length = 0;
        const tab = page.tabs.find((item) => item.id === 30);
        tab.title = "Back loading";
        page.fire("updated", 30, { title: tab.title }, { ...tab });
        await sleep(1300);
        const late = page.sent.find((entry) => isState(entry.message));
        check(!!late && late.at - flushed >= 950, `a change in an unfocused window waits about a second (${late && late.at - flushed} ms)`);

        page.sent.length = 0;
        updateTab(page, 1, { title: "Front" });
        const fired = Date.now();
        await sleep(600);
        const soon = page.sent.find((entry) => isState(entry.message));
        check(!!soon && soon.at - fired <= 400, `one in the focused window doesn't (${soon && soon.at - fired} ms)`);

        // With Safari in the background, the window focused last is the one the sidebar shows.
        page.fire("windows.focus", -1);
        await sleep(100);
        page.sent.length = 0;
        updateTab(page, 1, { title: "Still shown" });
        const firedAgain = Date.now();
        await sleep(600);
        const shown = page.sent.find((entry) => isState(entry.message));
        check(!!shown && shown.at - firedAgain <= 400, `nor in the window focused last, with Safari in the background (${shown && shown.at - firedAgain} ms)`);
    }

    if (failures === 0) {
        console.log("extension checks passed");
        process.exit(0);
    }
    console.log(`${failures} extension check(s) failed`);
    process.exit(1);
})();
