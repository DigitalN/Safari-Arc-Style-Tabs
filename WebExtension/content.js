"use strict";

// Reports the page's favicon URL to the background page. Safari's tabs API doesn't
// expose favicons, so this is how the sidebar learns which icon to show.
(() => {
    if (window.top !== window) return;

    // Injected twice (manifest + executeScript at startup): just report again.
    if (window.__sideTabsReportFavicon) {
        window.__sideTabsReportFavicon(true);
        return;
    }

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

    window.__sideTabsReportFavicon = report;
    report(false);

    // Sites like Gmail and Slack swap their favicon to show unread counts.
    const observer = new MutationObserver(() => {
        clearTimeout(timer);
        timer = setTimeout(() => report(false), 400);
    });
    if (document.head) {
        observer.observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ["href", "rel"] });
    }
})();
