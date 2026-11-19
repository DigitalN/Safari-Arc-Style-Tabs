"use strict";

// Checks for WebExtension/content.js against a stand-in page: a small DOM and a MutationObserver that
// delivers records the way the DOM standard says, honouring `subtree`, `childList`, `attributes` and
// `attributeFilter`. No Safari involved.
//
//   node Tests/ExtensionChecks/content-checks.js
//
// (scripts/run-checks.sh runs this.)

const fs = require("fs");
const path = require("path");
const vm = require("vm");

// CONTENT_JS points the checks at another copy, to see them fail on an older version.
const source = fs.readFileSync(process.env.CONTENT_JS || path.join(__dirname, "../../WebExtension/content.js"), "utf8");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let failures = 0;
function check(condition, message) {
    if (!condition) {
        failures++;
        console.log("FAIL:", message);
    }
}

// content.js waits 400 ms of quiet before a rescan; the checks run its timers 10 times faster.
const TIME_SCALE = 0.1;
const QUIET = 400 * TIME_SCALE + 30;

// A page at `url` whose <head> holds `headChildren` ([name, attributes] pairs). `withHead: false` leaves
// <head> out. `load()` runs a copy of content.js in it, as the manifest or an injection would.
function page({ url = "https://example.com/inbox", headChildren = [], withHead = true } = {}) {
    const observers = new Set();
    const messages = [];
    let timersSet = 0;
    const location = new URL(url);

    class Node {
        constructor(nodeType) {
            this.nodeType = nodeType;
            this.parentNode = null;
            this.childNodes = [];
        }
        get children() { return this.childNodes.filter((node) => node.nodeType === 1); }
        appendChild(node) { return this.insert(node); }
        insert(node, before = null) {
            if (node.parentNode) node.parentNode.removeChild(node);
            const at = before ? this.childNodes.indexOf(before) : this.childNodes.length;
            this.childNodes.splice(at, 0, node);
            node.parentNode = this;
            queueRecord({ type: "childList", target: this, addedNodes: [node], removedNodes: [] });
            return node;
        }
        removeChild(node) {
            this.childNodes.splice(this.childNodes.indexOf(node), 1);
            node.parentNode = null;
            queueRecord({ type: "childList", target: this, addedNodes: [], removedNodes: [node] });
            return node;
        }
        replaceChild(node, old) {
            const at = this.childNodes.indexOf(old);
            this.childNodes.splice(at, 1, node);
            old.parentNode = null;
            node.parentNode = this;
            queueRecord({ type: "childList", target: this, addedNodes: [node], removedNodes: [old] });
            return old;
        }
    }

    class Element extends Node {
        constructor(name, attributes = {}) {
            super(1);
            this.localName = name;
            this.nodeName = name.toUpperCase();
            this.attributes = { ...attributes };
        }
        getAttribute(name) { return this.attributes[name] ?? null; }
        setAttribute(name, value) {
            const oldValue = this.getAttribute(name);
            this.attributes[name] = String(value);
            queueRecord({ type: "attributes", target: this, attributeName: name, oldValue, addedNodes: [], removedNodes: [] });
        }
        get rel() { return this.attributes.rel ?? ""; }
        get href() { return this.attributes.href == null ? "" : new URL(this.attributes.href, location.href).href; }
        set href(value) { this.setAttribute("href", value); }
        get sizes() { return { value: this.attributes.sizes ?? "" }; }
        get type() { return this.attributes.type ?? ""; }
    }

    const element = (name, attributes, children = []) => {
        const node = new Element(name, attributes);
        for (const child of children) {
            node.childNodes.push(child);
            child.parentNode = node;
        }
        return node;
    };
    const text = (value) => Object.assign(new Node(3), { data: value });

    const html = element("html", {}, [
        ...(withHead ? [element("head", {}, headChildren.map(([name, attributes]) => element(name, attributes)))] : []),
        element("body"),
    ]);

    const document = {
        documentElement: html,
        get head() { return html.children.find((node) => node.localName === "head") || null; },
        get body() { return html.children.find((node) => node.localName === "body") || null; },
        querySelectorAll(selector) {
            if (selector !== "link[rel][href]") throw new Error(`the stand-in page doesn't know the selector ${selector}`);
            const found = [];
            const walk = (node) => {
                for (const child of node.children) {
                    if (child.localName === "link" && child.attributes.rel != null && child.attributes.href != null) found.push(child);
                    walk(child);
                }
            };
            walk(html);
            return found;
        },
        createElement: (name) => new Element(name),
        createTextNode: text,
    };

    // Delivers `record` to every observer the DOM standard says gets it: one watching the target, or one
    // watching an ancestor with `subtree`, for that kind of change (and, for an attribute, in its filter).
    function queueRecord(record) {
        for (const observer of observers) {
            for (let node = record.target; node; node = node.parentNode) {
                const options = observer.targets.get(node);
                if (!options || (node !== record.target && !options.subtree)) continue;
                const wanted = record.type === "childList"
                    ? options.childList
                    : options.attributes && (!options.attributeFilter || options.attributeFilter.includes(record.attributeName));
                if (wanted) {
                    observer.enqueue(record);
                    break;
                }
            }
        }
    }

    class MutationObserver {
        constructor(callback) {
            this.callback = callback;
            this.targets = new Map();
            this.records = [];
            observers.add(this);
        }
        observe(target, options) {
            const settings = { ...options };
            if (settings.attributeFilter && settings.attributes === undefined) settings.attributes = true;
            if (!settings.childList && !settings.attributes && !settings.characterData) {
                throw new TypeError("observe() needs childList, attributes or characterData");
            }
            this.targets.set(target, settings);
        }
        disconnect() {
            this.targets.clear();
            this.records = [];
        }
        enqueue(record) {
            this.records.push(record);
            if (this.records.length > 1) return;
            queueMicrotask(() => {
                const records = this.records;
                this.records = [];
                if (records.length) this.callback(records, this);
            });
        }
    }

    const context = vm.createContext({
        document, location, URL, MutationObserver,
        browser: { runtime: { sendMessage: async (message) => { messages.push(message); } } },
        setTimeout: (fn, ms) => { timersSet++; return setTimeout(fn, (ms ?? 0) * TIME_SCALE); },
        clearTimeout,
    });
    context.window = context;
    context.top = context;

    return {
        document, element, text, messages, observers,
        get head() { return document.head; },
        get timersSet() { return timersSet; },
        icons: () => messages.filter((message) => message.type === "favicon").map((message) => message.url),
        load: () => vm.runInContext(source.replace('"use strict";', ""), context),
        // Every node some observer of this page watches, and how.
        watched: () => [...observers].flatMap((observer) => [...observer.targets].map(([node, options]) => ({ node, options }))),
    };
}

const link = (attributes) => ["link", attributes];

(async () => {
    // --- #84 p1: only <link> changes in <head> lead to a rescan ---
    {
        const tab = page({ headChildren: [
            ["meta", { charset: "utf-8" }],
            link({ rel: "stylesheet", href: "/site.css" }),
            link({ rel: "icon", href: "/unread-0.png" }),
            ["script", { src: "/app.js" }],
        ] });
        tab.load();
        await sleep(10);
        check(JSON.stringify(tab.icons()) === JSON.stringify(["https://example.com/unread-0.png"]), `the icon is reported at start (got ${JSON.stringify(tab.icons())})`);
        check(tab.watched().every(({ options }) => !options.subtree), "nothing is watched with subtree");
        check(tab.watched().some(({ node, options }) => node === tab.head && options.childList && !options.attributes),
            "<head> is watched for its children, not its attributes");

        // What scripts, ad and analytics code do all the time:
        const timers = tab.timersSet;
        const script = tab.head.appendChild(tab.element("script", { src: "https://ads.example.net/tag.js" }));
        tab.head.appendChild(tab.element("style"));
        tab.head.appendChild(tab.element("meta", { name: "theme-color", content: "#fff" }));
        tab.head.appendChild(tab.text("\n"));
        script.setAttribute("src", "https://ads.example.net/tag2.js");
        tab.head.removeChild(script);
        tab.head.children.find((node) => node.localName === "meta").setAttribute("charset", "utf-8");
        tab.document.body.appendChild(tab.element("div"));
        await sleep(QUIET);
        check(tab.timersSet === timers, `scripts, styles, metas and text added to or removed from <head> schedule no rescan (${tab.timersSet - timers} scheduled)`);
        check(tab.icons().length === 1, "and report nothing");

        // Gmail and Slack swap the icon's href to show an unread count.
        const icon = tab.head.children.find((node) => node.rel === "icon");
        icon.href = "/unread-3.png";
        await sleep(QUIET);
        check(tab.icons().at(-1) === "https://example.com/unread-3.png", "a page swapping its icon's href is reported");
        const before = tab.icons().length;
        for (let i = 4; i < 9; i++) icon.href = `/unread-${i}.png`;
        await sleep(QUIET);
        check(tab.icons().length === before + 1 && tab.icons().at(-1) === "https://example.com/unread-8.png",
            "a burst of swaps is reported once, with the last icon");

        // A link that becomes an icon by its rel, and the attributes the choice depends on.
        const preload = tab.head.appendChild(tab.element("link", { rel: "preload", href: "/logo.svg" }));
        await sleep(QUIET);
        check(tab.icons().at(-1) === "https://example.com/unread-8.png", "a link that isn't an icon reports nothing new");
        preload.setAttribute("rel", "icon");
        await sleep(QUIET);
        check(tab.icons().at(-1) === "https://example.com/logo.svg", "a link whose rel changes to icon is reported");
        icon.setAttribute("type", "image/svg+xml");
        icon.setAttribute("sizes", "32x32");
        await sleep(QUIET);
        check(tab.icons().at(-1) === "https://example.com/unread-8.png", "a change to an icon's sizes or type is looked at too");
    }

    {
        // A single-page app adds its icon link late, then changes it as it moves between pages.
        const tab = page({ headChildren: [["title", {}]] });
        tab.load();
        await sleep(10);
        check(tab.icons().at(-1) === "https://example.com/favicon.ico", "a page without an icon link reports /favicon.ico");
        const late = tab.document.createElement("link");
        late.attributes.rel = "icon";
        late.attributes.href = "/app-icon.png";
        tab.head.appendChild(late);
        await sleep(QUIET);
        check(tab.icons().at(-1) === "https://example.com/app-icon.png", "a <link rel=icon> added late is reported");
        late.href = "/app-icon-dark.png";
        await sleep(QUIET);
        check(tab.icons().at(-1) === "https://example.com/app-icon-dark.png", "and so is a later change to its href");

        // React Helmet and the like replace the link rather than change it.
        const replacement = tab.element("link", { rel: "icon", href: "/settings.png" });
        tab.head.replaceChild(replacement, late);
        await sleep(QUIET);
        check(tab.icons().at(-1) === "https://example.com/settings.png", "an icon link replaced by another is reported");
        tab.head.removeChild(replacement);
        await sleep(QUIET);
        check(tab.icons().at(-1) === "https://example.com/favicon.ico", "removing the icon link goes back to /favicon.ico");
    }

    {
        // A page that replaces <head> itself, and one that has none until a script adds it.
        const tab = page({ headChildren: [link({ rel: "icon", href: "/old.png" })] });
        tab.load();
        await sleep(10);
        const oldHead = tab.head;
        const newHead = tab.element("head", {}, [tab.element("link", { rel: "icon", href: "/new.png" })]);
        tab.document.documentElement.replaceChild(newHead, oldHead);
        await sleep(QUIET);
        check(tab.icons().at(-1) === "https://example.com/new.png", "a replaced <head> is looked at");
        newHead.children[0].href = "/newer.png";
        await sleep(QUIET);
        check(tab.icons().at(-1) === "https://example.com/newer.png", "and its links are watched from then on");
        const timers = tab.timersSet;
        tab.document.documentElement.replaceChild(tab.element("body"), tab.document.body);
        await sleep(QUIET);
        check(tab.timersSet === timers, "a replaced <body> schedules no rescan");

        const bare = page({ withHead: false });
        bare.load();
        await sleep(10);
        const added = bare.element("head", {}, [bare.element("link", { rel: "icon", href: "/late-head.png" })]);
        bare.document.documentElement.insert(added, bare.document.body);
        await sleep(QUIET);
        check(bare.icons().at(-1) === "https://example.com/late-head.png", "a page whose <head> is added later is looked at");
    }

    {
        // Run a second time in the same page (background.js's startup sweep into a tab whose report it missed):
        // it reports again, and from then on there's one observer, not two.
        const tab = page({ headChildren: [link({ rel: "icon", href: "/a.png" })] });
        tab.load();
        await sleep(10);
        tab.load();
        await sleep(10);
        check(tab.icons().length === 2, `a second run reports the icon again (${tab.icons().length} reports)`);
        tab.head.children[0].href = "/b.png";
        await sleep(QUIET);
        check(tab.icons().length === 3 && tab.icons().at(-1) === "https://example.com/b.png",
            `and a later change is reported once (${tab.icons().length - 2} reports)`);
    }

    {
        // Frames other than the top one report nothing.
        const tab = page({ headChildren: [link({ rel: "icon", href: "/a.png" })] });
        const done = [];
        vm.runInContext(source.replace('"use strict";', ""), vm.createContext({
            window: { top: {} }, document: tab.document, location: new URL("https://example.com/frame"), URL,
            MutationObserver: class { observe() { done.push("observed"); } },
            browser: { runtime: { sendMessage: async () => { done.push("reported"); } } },
            setTimeout, clearTimeout,
        }));
        await sleep(10);
        check(done.length === 0, `a frame doesn't observe or report (${done.join(", ")})`);
    }

    if (failures === 0) {
        console.log("content script checks passed");
        process.exit(0);
    }
    console.log(`${failures} content script check(s) failed`);
    process.exit(1);
})();
