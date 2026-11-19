"use strict";

// Reports the page's favicon URL to the background page. Safari's tabs API doesn't
// expose favicons, so this is how the sidebar learns which icon to show.
(() => {
    if (window.top !== window) return;

    // Run again in a page that already has a copy: background.js's startup sweep injects one into a tab
    // whose report it never got (see collectExistingFavicons). The new copy takes over, so the page has one
    // observer, and the reports go through the extension that's running now, even if the older copy
    // belonged to a copy of the extension that has since been reloaded.
    if (window.__sideTabsFavicons) window.__sideTabsFavicons.stop();

    let lastReported = null;
    let timer = null;

    function sizeOf(link) {
        const value = link.sizes && link.sizes.value;
        if (!value) return 0;
        if (value.toLowerCase() === "any") return 64;
        const match = value.match(/(\d+)\s*x\s*(\d+)/i);
        return match ? parseInt(match[1], 10) : 0;
    }

    function score(link) {
        const rel = link.rel.toLowerCase().split(/\s+/);
        const isIcon = rel.includes("icon");
        const isTouchIcon = rel.includes("apple-touch-icon") || rel.includes("apple-touch-icon-precomposed");
        if (!isIcon && !isTouchIcon) return -1;
        if (rel.includes("mask-icon")) return -1;

        let points = isIcon ? 100 : 40;
        const size = sizeOf(link);
        if (size >= 32 && size <= 96) points += 30;
        else if (size > 96) points += 15;
        else if (size > 0) points += 10;

        const type = (link.type || "").toLowerCase();
        if (type.includes("svg") || /\.svg(\?|$)/i.test(link.href)) points += 20;
        return points;
    }

    function bestIcon() {
        let best = null;
        let bestScore = -1;
        for (const link of document.querySelectorAll("link[rel][href]")) {
            const points = score(link);
            if (points > bestScore && link.href) {
                best = link.href;
                bestScore = points;
            }
        }
        if (best) return best;
        if (location.protocol === "http:" || location.protocol === "https:") {
            return new URL("/favicon.ico", location.origin).href;
        }
        return null;
    }

    function report(force) {
        const url = bestIcon();
        if (!url || (url === lastReported && !force)) return;
        lastReported = url;
        browser.runtime.sendMessage({ type: "favicon", url }).catch(() => {});
    }

    // Sites like Gmail and Slack swap their favicon to show unread counts, and single-page apps add,
    // remove or replace icon links as they move between pages. Meanwhile scripts add <script> and <style>
    // nodes to <head> all the time, in background tabs too. Only <link>s pick the icon, so only a change to
    // one leads to a rescan: <head>'s own children are watched (icon links are children of <head>, so not
    // their subtrees), each <link> among them for the attributes the choice depends on, and <html>'s
    // children in case the page replaces <head> itself.
    const LINK_ATTRIBUTES = ["href", "rel", "sizes", "type"];
    const isElement = (node, name) => node.nodeType === 1 && node.localName === name;
    let head = null;

    const observer = new MutationObserver((records) => {
        let changed = false;
        for (const record of records) {
            if (record.type === "attributes") {
                if (isElement(record.target, "link")) changed = true;
            } else if (record.target === document.documentElement) {
                if (document.head !== head) {
                    watch();
                    changed = true;
                }
            } else {
                for (const node of record.addedNodes) {
                    if (isElement(node, "link")) {
                        watchLink(node);
                        changed = true;
                    }
                }
                for (const node of record.removedNodes) {
                    if (isElement(node, "link")) changed = true;
                }
            }
        }
        if (!changed) return;
        clearTimeout(timer);
        timer = setTimeout(() => report(false), 400);
    });

    function watchLink(link) {
        observer.observe(link, { attributes: true, attributeFilter: LINK_ATTRIBUTES });
    }

    function watch() {
        observer.disconnect();
        if (document.documentElement) observer.observe(document.documentElement, { childList: true });
        head = document.head;
        if (!head) return;
        observer.observe(head, { childList: true });
        for (const child of head.children) {
            if (isElement(child, "link")) watchLink(child);
        }
    }

    window.__sideTabsFavicons = {
        stop() {
            observer.disconnect();
            clearTimeout(timer);
        },
    };
    watch();
    report(false);
})();
