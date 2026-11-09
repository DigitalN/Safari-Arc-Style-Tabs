import AppKit
import os.log
import Observation

/// Everything the sidebar shows: Safari's windows and tabs (from the extension), the
/// user's favorites and pinned items, and the custom names given to tabs.
@Observable
final class TabStore {
    struct WindowSelection: Equatable {
        let instance: String
        let window: BrowserWindow
    }

    /// A tab switch the sidebar asked for that Safari hasn't confirmed yet.
    private struct PendingActivation {
        let id: Int
        let key: TabKey
        let windowId: Int
        /// When the click started (the mouse-down, if there was one), to time the switch.
        let clickAt: Date
        /// When the switch was requested, to tell whether it's still worth waiting for.
        let requestedAt: Date
        /// How the switch was asked for, for the log.
        var path = "push"

        /// A switch that's gone unconfirmed this long was lost, or Safari went somewhere else
        /// first. Reports from Safari are no longer held back on its account, and Safari is asked
        /// where it is.
        static let lifetime: TimeInterval = 1

        var isFresh: Bool { Date().timeIntervalSince(requestedAt) < Self.lifetime }

        /// `requestedAt` as the extension's clock reads it (`Date.now()`: whole milliseconds since
        /// 1970, the same clock on this Mac). Nothing Safari did before this can be this click's doing.
        var requestedAtMilliseconds: Double { (requestedAt.timeIntervalSince1970 * 1000).rounded(.down) }
    }

    /// A tab switch the sidebar asked for, remembered for a while after it was confirmed, replaced
    /// or lost. Safari's report of a switch comes from the extension's page, which under load runs
    /// its listener seconds after Safari switched, so reports for clicks the sidebar made some time
    /// ago keep arriving. Each click is answered by at most one report, so a report is matched to
    /// the oldest click for its tab that it can answer; one that matches none is Safari's own doing.
    private struct SwitchAsk {
        let id: Int
        let key: TabKey
        let requestedAt: Date

        /// How long after a click its report is still looked for. Longer than the extension has
        /// been seen to take under heavy load: its listeners ran up to 20 s late in the worst run.
        /// Past this the report would be taken for Safari moving on by itself, which Safari's own
        /// tab bar then settles (see `Anchor`).
        static let lifetime: TimeInterval = 30

        var isRecent: Bool { Date().timeIntervalSince(requestedAt) < Self.lifetime }
        var requestedAtMilliseconds: Double { (requestedAt.timeIntervalSince1970 * 1000).rounded(.down) }
    }

    /// A window of one extension instance (a profile), as Safari numbers it.
    private struct WindowID: Hashable {
        let instance: String
        let windowId: Int
    }

    /// The tab the sidebar last put a window on, and since when: the tab it clicked, or the one
    /// Safari's own tab bar later said was selected. Remembered for a while after the click is
    /// confirmed, because the extension's messages arrive that late and out of order: one that says
    /// Safari is on another tab may only describe a state the click has already replaced. So while it is
    /// recent, a message from the extension can't move the window's highlight off this tab; it makes the
    /// sidebar ask Safari which tab is selected, and that answer decides (see `checkSelectedTab`).
    private struct Anchor {
        let tabId: Int
        /// When Safari was last known to be on the tab: the click, or the moment it was asked.
        /// Anything the extension started or saw before this is older than what the sidebar knows.
        let at: Date
        /// The click that put it there, or nil when it was Safari's own answer.
        let clickId: Int?

        var isRecent: Bool { Date().timeIntervalSince(at) < SwitchAsk.lifetime }
        var atMilliseconds: Double { (at.timeIntervalSince1970 * 1000).rounded(.down) }
    }

    private(set) var snapshots: [String: Snapshot] = [:] {
        // Any change to which tab is active (a snapshot, a report of a switch, a click) starts or
        // stops a tab's cleanup clock.
        didSet { cleanup.snapshotsChanged(from: oldValue, to: snapshots) }
    }
    /// Closes tabs nobody has looked at for a while, when that's turned on, and keeps the list for
    /// reopening them (TabCleanup.swift).
    let cleanup = TabCleanup()
    private(set) var lastMessageAt: Date?
    /// Favorites, shared by every profile, and each profile's Pinned list (#34, BookmarkLists.swift).
    private(set) var bookmarkLists = BookmarkLists()
    private(set) var customNames: [TabKey: CustomName] = [:]
    /// The tabs that belong to favorites and pinned items, listed under them instead of under Tabs
    /// (see BookmarkTabs).
    private(set) var bookmarkTabs = BookmarkTabs()

    var renaming: RenameTarget?

    /// Hints from SafariTracker, used to pick the window the sidebar is docked to.
    var safariIsFrontmost = false
    var dockedWindowTitle: String? {
        didSet {
            if dockedWindowTitle != oldValue {
                requestSnapshotIfUnknown(title: dockedWindowTitle)
                logShownSpace()
            }
        }
    }
    @ObservationIgnored private var lastSnapshotRequest = Date.distantPast
    /// The docked window's profile, read from its toolbar by SafariProfiles (#33), as `ProfileKey.rawValue`:
    /// "default", or the profile's UUID as its copy's snapshots carry it. Nil while it isn't known, in a private
    /// window, and where Safari has no profiles. `currentWindow` takes the docked window from that profile's copy.
    var dockedWindowProfile: String?

    @ObservationIgnored var sendCommand: (([String: Any]) -> Void)?
    @ObservationIgnored var onToggleSidebar: (() -> Void)?
    @ObservationIgnored var onRenameStateChanged: ((Bool) -> Void)?
    @ObservationIgnored var onOpenAddressBar: (() -> Void)?
    /// When the pointer last went down on the sidebar, so a switch is timed from the click.
    @ObservationIgnored var lastPointerDown: (() -> Date)?
    /// Switches a tab by pressing its button in Safari's tab bar (see TabBarPresser). The
    /// completion runs on the main thread and says whether it worked or the extension has to do it.
    @ObservationIgnored var pressTab: ((TabBarTarget, @escaping (TabBarPressOutcome) -> Void) -> Void)?
    /// Reads which tab Safari has selected in the window the sidebar is docked to (see
    /// TabBarPresser), given the titles of that window's tabs. The completion runs on the main thread.
    @ObservationIgnored var checkSelection: (([String?], @escaping (TabBarSelection) -> Void) -> Void)?

    /// Names whose tab ids are gone (Safari restarted), keyed by URL so they can be
    /// given back to the restored tabs.
    @ObservationIgnored private var orphanNames: [String: String] = [:]
    /// Tabs being opened for bookmarks, by request id. `tab` is set once the extension says which
    /// tab it opened, which can be before a snapshot has it.
    @ObservationIgnored private var pendingBookmarkOpens: [String: (bookmark: UUID, windowId: Int, at: Date, tab: TabKey?)] = [:]
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    /// The last tab switch the sidebar asked for, until Safari confirms it or it goes stale.
    @ObservationIgnored private var pendingActivation: PendingActivation?
    @ObservationIgnored private var activationCount = 0
    /// The tab switches the sidebar asked for lately, oldest first (see SwitchAsk).
    @ObservationIgnored private var switchAsks: [SwitchAsk] = []
    /// Where the sidebar last put each window (see Anchor).
    @ObservationIgnored private var anchors: [WindowID: Anchor] = [:]
    /// Counts the clicks and the reports of tab switches, so an answer from Safari's tab bar can be told
    /// to have come too late: if either has happened since it was asked for, something newer decides.
    @ObservationIgnored private var eventCount = 0
    /// The newest `activated` report applied for each extension instance, so an older one that
    /// arrives late is ignored, and a snapshot older than it doesn't undo it.
    /// `heldBack` is set for a report that didn't move the highlight because a click was waiting
    /// for another tab, which a snapshot started before it mustn't do either.
    @ObservationIgnored private var lastActivation: [String: (seq: Int, windowId: Int, tabId: Int, heldBack: Bool)] = [:]
    @ObservationIgnored private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "store")

    /// Where bookmarks and tab names are kept. Only the checks in Tests/ pass anything else.
    @ObservationIgnored private let stateURL: URL

    init(stateURL: URL = TabStore.defaultStateURL) {
        self.stateURL = stateURL
        load()
        cleanup.onChange = { [weak self] in self?.scheduleSave() }
    }

    // MARK: - Messages from the extension

    func handleMessage(type: String, payload: Data, object: [String: Any]) -> [String: Any] {
        lastMessageAt = Date()
        let sender = hear(from: object)
        if sender == .replaced {
            return [:]
        }
        var reply = answer(type: type, payload: payload, object: object)
        if sender == .backFromQuiet, let instance = object["instance"] as? String {
            // Its snapshot is from before it went quiet. The extension acts on `needSnapshot` in any reply,
            // but replies get lost (#37), so it's asked with a command too.
            reply["needSnapshot"] = true
            send(["action": "snapshot"], to: instance)
        }
        return reply
    }

    private func answer(type: String, payload: Data, object: [String: Any]) -> [String: Any] {
        switch type {
        case "snapshot":
            do {
                apply(try JSONDecoder().decode(Snapshot.self, from: payload))
            } catch {
                NSLog("Side Tabs: bad snapshot: \(error)")
            }
            return [:]

        case "activated":
            // Safari switched tabs. The extension sends this the moment it happens, ahead of the
            // snapshot, which takes longer to build with many tabs.
            if let instance = object["instance"] as? String,
               let windowId = object["windowId"] as? Int,
               let tabId = object["tabId"] as? Int {
                applyActivation(instance: instance, windowId: windowId, tabId: tabId, seq: object["seq"] as? Int, at: object["at"] as? Double)
            }
            return [:]

        case "log":
            // Something the extension wants in the system log, which is where its console
            // output can be read without Safari's developer tools.
            // Each copy of the extension sends its own, so the line says which (#37).
            let copy = (object["instance"] as? String).map { " \($0.prefix(8))" } ?? ""
            log.notice("extension\(copy, privacy: .public): \(object["message"] as? String ?? "", privacy: .public)")
            return [:]

        case "hello":
            return ["needSnapshot": true]

        case "heartbeat":
            // The extension reports the last snapshot it delivered; ask again if we missed one.
            let instance = object["instance"] as? String ?? ""
            let seq = object["seq"] as? Int ?? 0
            let applied = snapshots[instance]?.seq ?? -1
            if !instance.isEmpty, applied < seq || snapshots[instance] == nil {
                // A snapshot is missing. The reply asks for it, but replies can be lost for minutes after
                // the extension reloads (#37), so a command asks too: it doesn't depend on the reply.
                send(["action": "snapshot"], to: instance)
            }
            return ["needSnapshot": applied < seq || seq == 0]

        case "toggleSidebar":
            onToggleSidebar?()
            return [:]

        case "created":
            if let requestId = object["requestId"] as? String,
               let instance = object["instance"] as? String,
               let tabId = object["tabId"] as? Int,
               let pending = pendingBookmarkOpens[requestId], pending.tab == nil {
                let key = TabKey(instance: instance, tabId: tabId)
                pendingBookmarkOpens[requestId]?.tab = key
                linkOpenedTab(key, to: pending.bookmark, windowId: pending.windowId)
            }
            return [:]

        default:
            return [:]
        }
    }

    private func apply(_ snapshot: Snapshot) {
        if let existing = snapshots[snapshot.instance], existing.seq > snapshot.seq {
            return
        }
        let isNewInstance = snapshots[snapshot.instance] == nil
        snapshots[snapshot.instance] = snapshot
        let tabCounts = snapshot.windows.map { String($0.tabs.count) }.joined(separator: "+")
        log.info("snapshot \(snapshot.seq) from \(snapshot.instance.prefix(8), privacy: .public): \(snapshot.windows.count) windows, tabs \(tabCounts, privacy: .public), focused \(snapshot.focusedWindowId ?? -1)")
        compareWithReplaced(snapshot)
        if isNewInstance {
            orphanNamesOfDeadInstances()
        }
        reconcileNames(with: snapshot)
        updateBookmarkTabs(with: snapshot)

        // A report sent after this snapshot was started can have arrived first. The snapshot
        // may not know about it yet, so it must not move the highlight back. (Not one that was
        // held back for a click waiting on another tab: the highlight stays where the click put it.)
        if let last = lastActivation[snapshot.instance], last.seq > snapshot.seq, !last.heldBack {
            moveHighlight(instance: snapshot.instance, windowId: last.windowId, tabId: last.tabId)
        }

        holdAnchoredTabs(against: snapshot)

        if let pending = pendingActivation, pending.key.instance == snapshot.instance {
            let showsClicked = snapshot.windows.contains { $0.tabs.contains { $0.id == pending.key.tabId && $0.active } }
            let startedAfterClick = snapshot.startedAt.map { $0 >= pending.requestedAtMilliseconds }
            if pending.isFresh, let startedAfterClick, !(showsClicked && startedAfterClick) {
                // The click's switch is on its way, and the snapshot doesn't have it: one started
                // before the click shows the state the click is about to change, and one started
                // after it can still be ahead of Safari's switch (a press takes effect a few
                // milliseconds on, an extension command a hundred or more). Either way it isn't Safari's
                // answer: the click's report is, and it also says when Safari goes somewhere else. If
                // that never comes, Safari is asked again once the wait is over. (`holdAnchoredTabs` has
                // kept the highlight on the clicked tab.)
                if tab(for: pending.key) == nil {
                    pendingActivation = nil
                    log.notice("the clicked tab is gone; no longer waiting for it")
                }
            } else if showsClicked {
                confirmActivation(pending)
            } else if !pending.isFresh {
                dropStalePending()
            }
        }
    }

    /// Keeps a snapshot from moving a window's highlight off the tab the sidebar put the window on while
    /// that is recent (see `Anchor`). A snapshot is the extension's picture of Safari as of the moment it
    /// started building it (`startedAt`), and under load it arrives seconds after that, so:
    ///
    /// - One started before the sidebar put the window on its tab shows the state that was replaced. It
    ///   never moves the highlight, however late it is, unless the tab is gone from the window.
    /// - One started after it that shows another tab may be right (Safari moved on) or may have been
    ///   built before the switch took effect. The highlight stays, and Safari's tab bar is asked which
    ///   tab is selected; that answer decides. If it can't say, the snapshot is believed.
    ///
    /// A snapshot without a `startedAt` (an extension page from before it was sent) can't be told apart
    /// from a new one and is believed as before.
    private func holdAnchoredTabs(against snapshot: Snapshot) {
        guard let startedAt = snapshot.startedAt else { return }
        for window in snapshot.windows {
            let id = WindowID(instance: snapshot.instance, windowId: window.id)
            guard let anchor = recentAnchor(of: id),
                  window.tabs.contains(where: { $0.id == anchor.tabId }),
                  let shown = window.tabs.first(where: \.active)?.id,
                  shown != anchor.tabId else { continue }
            moveHighlight(instance: snapshot.instance, windowId: window.id, tabId: anchor.tabId)
            guard startedAt >= anchor.atMilliseconds else { continue }
            checkSelectedTab(in: id, because: "a snapshot showing another tab") { [self] in
                // Safari can't say. A click that is still being waited for keeps the highlight: its
                // switch is on its way, and a snapshot can be ahead of it (a press takes effect a few
                // milliseconds on, a command a hundred or more). Its report, or the check a second
                // later, settles it. Otherwise the snapshot is taken as it always was.
                if let pending = pendingActivation, pending.isFresh, pending.key == TabKey(instance: id.instance, tabId: anchor.tabId) {
                    return
                }
                anchors[id] = Anchor(tabId: shown, at: Date(timeIntervalSince1970: startedAt / 1000), clickId: nil)
                moveHighlight(instance: snapshot.instance, windowId: window.id, tabId: shown)
            }
        }
    }

    /// Moves the highlight to the tab Safari says it switched to, without waiting for a snapshot.
    /// `seq` numbers the report together with the instance's snapshots; without one (an older
    /// extension still running) the report is taken as the newest. `at` is when the extension
    /// saw the switch (`Date.now()`), which says whether it came before or after the last click.
    ///
    /// A report that would move the highlight off the tab the sidebar put the window on doesn't
    /// do it by itself while that is recent: it asks Safari's tab bar which tab is selected, and
    /// that answer decides (`checkSelectedTab`).
    private func applyActivation(instance: String, windowId: Int, tabId: Int, seq: Int?, at: Double?) {
        // Any report is news for a check of Safari's tab bar that is on its way (see `eventCount`).
        eventCount += 1
        if let seq {
            // Reports are separate messages and can arrive out of order. One older than a
            // snapshot or report already applied describes a tab Safari has since left.
            if seq <= (snapshots[instance]?.seq ?? -1) || seq <= (lastActivation[instance]?.seq ?? -1) {
                log.info("ignoring an older tab switch report (\(seq)) from \(instance.prefix(8), privacy: .public)")
                return
            }
        }
        let reported = TabKey(instance: instance, tabId: tabId)
        let window = WindowID(instance: instance, windowId: windowId)
        let anchor = recentAnchor(of: window)
        // What the report means for the switch the sidebar is waiting for:
        var heldBack = false    // it describes a state the click has already replaced
        var confirms = false    // it is the click's own switch
        var movedOnAfter: Int?  // Safari went somewhere else after the click (this many ms after it)
        var askSafari = false   // it would move the highlight off the tab the sidebar put the window on
        var believeIfUnknown = true // ... and if Safari can't say, it is taken as it always was
        let pending = pendingActivation
        let waitingInWindow = pending.map { $0.isFresh && $0.key.instance == instance && tab(for: $0.key)?.windowId == windowId } ?? false
        // A stamped report that answers one of the sidebar's own clicks: the oldest click on this
        // tab that was made before the page saw the switch (it can't answer a click made after).
        if let at, let index = switchAsks.firstIndex(where: { $0.key == reported && $0.isRecent && $0.requestedAtMilliseconds <= at }) {
            let ask = switchAsks.remove(at: index)
            if ask.id == pending?.id {
                confirms = true
            } else if let anchor, ask.id != anchor.clickId {
                // Most likely the answer to an earlier click than the newest one in this window,
                // whether or not that one has been confirmed since: the highlight is already on the
                // newer one, and moving it back would only make it jump, or leave it on a tab Safari
                // left. But a click whose report was lost leaves its ask behind, and a later move
                // of Safari's own to that tab would look the same, so Safari is asked; if it can't say,
                // the report is held back.
                heldBack = true
                askSafari = true
                believeIfUnknown = false
            }
        } else if let pending, reported == pending.key || waitingInWindow {
            // A switch Safari made before the click asked for its own isn't the click's doing.
            let beforeClick = at.map { $0 < pending.requestedAtMilliseconds } ?? false
            if reported == pending.key {
                confirms = !beforeClick
            } else if let at, !beforeClick {
                // Another tab in the window the click is switching. With a stamp from after the click
                // that doesn't answer any click of the sidebar's, it is Safari going somewhere on its
                // own (its own tab bar, ⌘1–9, a closed tab). Without a stamp, or with one from before
                // the click, it is the report of an earlier click's switch (an extension that sends
                // no stamps can't be told otherwise).
                movedOnAfter = Int(at - pending.requestedAtMilliseconds)
                askSafari = true
            } else {
                heldBack = true
            }
        } else if let anchor, anchor.tabId != tabId {
            // Nothing is waiting for this report, but the sidebar put the window on another tab not
            // long ago. A report stamped before that is older than what the sidebar knows; any other
            // may be Safari moving on, or the late report of a click whose ask has expired.
            if let at, at < anchor.atMilliseconds {
                heldBack = true
            } else {
                askSafari = true
            }
        }
        if let seq {
            lastActivation[instance] = (seq, windowId, tabId, heldBack || askSafari)
        }
        if askSafari {
            checkSelectedTab(in: window, because: "a report of a switch to another tab") { [self] in
                // Safari can't say: the report is taken as it always was (or, if it most likely
                // answers an earlier click, stays held back).
                guard believeIfUnknown else { return }
                if let seq, lastActivation[instance]?.seq == seq {
                    lastActivation[instance]?.heldBack = false
                }
                if let movedOnAfter, let pending, pendingActivation?.id == pending.id {
                    pendingActivation = nil
                    log.notice("Safari switched to another tab \(movedOnAfter) ms after the click; no longer waiting for the clicked tab")
                }
                let believedAt = at.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
                anchors[window] = Anchor(tabId: tabId, at: believedAt, clickId: nil)
                moveHighlight(instance: instance, windowId: windowId, tabId: tabId)
            }
        } else if !heldBack {
            moveHighlight(instance: instance, windowId: windowId, tabId: tabId)
        }
        if let pending {
            if confirms {
                confirmActivation(pending)
            } else if !pending.isFresh {
                dropStalePending()
            }
        }
    }

    private func recentAnchor(of window: WindowID) -> Anchor? {
        anchors[window].flatMap { $0.isRecent ? $0 : nil }
    }

    /// Asks Safari's tab bar which tab it has selected in `window`, and lets that decide where the
    /// highlight is. Used when a message from the extension would move the highlight off the tab the
    /// sidebar put the window on: the extension runs late under load, so what it says may be old, but
    /// Accessibility answers in about ten milliseconds whatever the load.
    ///
    /// The read happens off the main thread. Its answer is dropped if a click or a report has arrived
    /// since it was asked for, because that is newer than the answer. `whenUnknown` runs when Safari's
    /// tab bar can't be asked or can't say (the buttons don't line up with the window's tabs, or Safari
    /// didn't answer in time), so the message is taken the way it was before this check existed.
    private func checkSelectedTab(in window: WindowID, because why: String, final: Bool = false, whenUnknown fallback: @escaping () -> Void) {
        guard let checkSelection, let selection = currentWindow,
              selection.instance == window.instance, selection.window.id == window.windowId else {
            fallback()
            return
        }
        let tabs = selection.window.tabs
        let eventsBefore = eventCount
        let asked = Date()
        checkSelection(tabs.map(\.title)) { [weak self] answer in
            guard let self else { return }
            if answer == .superseded { return }
            guard self.eventCount == eventsBefore else {
                self.log.info("Safari's selected tab (\(why, privacy: .public)) was read, but a click or a report has come since; not using it")
                return
            }
            switch answer {
            case .tab(let position) where tabs.indices.contains(position):
                self.log.notice("Safari's selected tab (\(why, privacy: .public)) is the one at position \(position)")
                self.settle(on: tabs[position].id, in: window, asked: asked, final: final)
            case .tab, .unknown:
                var reason = "the position doesn't fit the window's tabs"
                if case .unknown(let said) = answer { reason = said }
                self.log.notice("Safari's selected tab (\(why, privacy: .public)) can't be told: \(reason, privacy: .public)")
                fallback()
            case .superseded:
                break
            }
        }
    }

    /// Puts the highlight on the tab Safari's tab bar says is selected, and ends the wait for a click
    /// that this settles: confirmed if Safari is on the clicked tab, otherwise Safari is somewhere
    /// else and the click isn't waited for any more. The exception is a click whose command to the
    /// extension is still on its way: Safari hasn't gone there yet, and the highlight stays. (Not when
    /// the click has been waited for as long as it's worth, `final`.)
    private func settle(on tabId: Int, in window: WindowID, asked: Date, final: Bool) {
        if let pending = pendingActivation, pending.key.instance == window.instance,
           tab(for: pending.key)?.windowId == window.windowId {
            if pending.key.tabId == tabId {
                confirmActivation(pending)
            } else if !final && pending.isFresh && pending.path != "accessibility" {
                return
            } else {
                pendingActivation = nil
                log.notice("Safari is on another tab than the clicked one; no longer waiting for it")
            }
        }
        let clickId = anchors[window]?.tabId == tabId ? anchors[window]?.clickId : nil
        anchors[window] = Anchor(tabId: tabId, at: asked, clickId: clickId)
        moveHighlight(instance: window.instance, windowId: window.windowId, tabId: tabId)
    }

    private func dropStalePending() {
        pendingActivation = nil
        log.notice("tab switch was never confirmed; no longer waiting for it")
    }

    private func moveHighlight(instance: String, windowId: Int, tabId: Int) {
        mutateWindow(instance: instance, windowId: windowId) { window in
            guard window.tabs.contains(where: { $0.id == tabId }) else { return }
            for index in window.tabs.indices {
                window.tabs[index].active = window.tabs[index].id == tabId
            }
        }
    }

    private func confirmActivation(_ pending: PendingActivation) {
        pendingActivation = nil
        let milliseconds = Int(Date().timeIntervalSince(pending.clickAt) * 1000)
        log.notice("tab switch confirmed by Safari \(milliseconds) ms after the click (via \(pending.path, privacy: .public))")
    }

    /// Safari quit: forget its tabs but remember names by URL for next launch.
    func safariDidTerminate() {
        snapshots.removeAll()
        lastActivation.removeAll()
        switchAsks.removeAll()
        anchors.removeAll()
        pendingActivation = nil
        orphanNamesOfDeadInstances()
        changeBookmarkTabs { $0.safariDidTerminate() }
        pendingBookmarkOpens.removeAll()
        renaming = nil
        copies.removeAll()
        replacedCopies.removeAll()
        replacedIds.removeAll()
        if !liveInstances.isEmpty {
            liveInstances.removeAll()
        }
    }

    func requestSnapshot() {
        lastSnapshotRequest = Date()
        sendCommand?(["action": "snapshot"])
    }

    /// Safari doesn't always tell extensions about windows it restores (Reopen Last Closed
    /// Window, relaunch), so when the docked window matches nothing we know, ask again.
    private func requestSnapshotIfUnknown(title: String?) {
        guard let title, !title.isEmpty else { return }
        guard dockedWindows(title: title).isEmpty, Date().timeIntervalSince(lastSnapshotRequest) > 0.5 else { return }
        requestSnapshot()
        // Titles can lag behind while a page loads; check once more shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.dockedWindowTitle == title else { return }
            if self.dockedWindows(title: title).isEmpty {
                self.requestSnapshot()
            }
        }
    }

    // MARK: - Copies of the extension
    //
    // Each Safari profile where Side Tabs is on runs its own copy of the extension's background page, with
    // its own instance id (#28). A copy stops when Side Tabs is turned off in its profile, when the extension
    // reloads or is reinstalled (a new copy, with a new id, takes over), or when Safari quits. None of these
    // says goodbye, so a copy is judged by what it sends (#31):
    //
    // - Quiet: nothing of any kind from it for `quietAfter`. Its windows aren't shown. Its snapshot stays in
    //   `snapshots`, and with it its bookmarks' tabs and cleanup's clocks, because under heavy load a copy
    //   that is running has gone that long without a word. Anything it sends shows its windows again.
    // - Gone: a newer copy of the same profile has reported (`replace`), or Safari quit
    //   (`safariDidTerminate`). Only then does its snapshot go, through the paths for an instance that's
    //   gone: its clocks are dropped and its bookmarks' tabs wait to be re-linked to the new copy's.

    /// One copy of the extension's background page.
    private struct Copy {
        /// The copy's profile, as the extension's handler names it (`Snapshot.profile`): a UUID string,
        /// or nil for the default profile.
        var profile: String?
        /// When anything last came from it.
        var lastHeard: Date
    }

    /// What a message says about the copy that sent it (see `hear`).
    private enum Sender {
        /// A copy that's running, or a message that doesn't say which copy sent it.
        case live
        /// A copy that was quiet. Its windows show again, and it's asked for a new snapshot.
        case backFromQuiet
        /// A copy that a newer copy of its profile has replaced. The message was already on its way; it's ignored.
        case replaced
    }

    /// How long a copy can go without sending anything before it counts as quiet and its windows are hidden.
    /// It sends a heartbeat every 5 s, but under heavy load the extension has run up to 20 s late (#16–#22).
    static let quietAfter: TimeInterval = 30
    /// How often copies are checked for having gone quiet, while there are any.
    static let quietCheckInterval: TimeInterval = 5

    /// The copies of the extension that are running now: heard from within `quietAfter`, and not replaced by a
    /// newer copy of their profile. By instance id, as in `snapshots` and `TabKey`. Read-only.
    ///
    /// For telling whether Side Tabs is on in a profile (#33), see `hasLiveCopy(profile:)`. A copy that isn't
    /// live may still have a snapshot in `snapshots` (a quiet copy keeps it), but its windows aren't shown.
    /// Quiet usually means stopped, but it can also be a copy held up by heavy load: it's live again as soon
    /// as it sends anything.
    private(set) var liveInstances: Set<String> = []

    /// Whether a live copy (see `liveInstances`) reports for `profile`: a profile's UUID string as
    /// `Snapshot.profile` has it, or nil for the default profile.
    func hasLiveCopy(profile: String?) -> Bool {
        liveInstances.contains { copies[$0]?.profile == profile }
    }

    /// The snapshots of the live copies: the windows the sidebar can show, the tabs cleanup can close and the
    /// windows it reopens tabs in. A quiet copy's snapshot stays in `snapshots`, but isn't here.
    var liveSnapshots: [String: Snapshot] {
        snapshots.filter { liveInstances.contains($0.key) }
    }

    /// Reads the time for telling which copies are quiet. Only the checks in Tests/ pass anything else.
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// The copies heard from since Safari started, apart from replaced ones, by instance id.
    @ObservationIgnored private var copies: [String: Copy] = [:]
    /// Copies a newer copy of their profile replaced, and when.
    @ObservationIgnored private var replacedCopies: [String: Date] = [:]
    /// For a copy that replaced another: the replaced copy's window and tab ids, and the most of them it has
    /// reported so far (see `compareWithReplaced`).
    @ObservationIgnored private var replacedIds: [String: (since: Date, windows: Set<Int>, tabs: Set<Int>, most: Int)] = [:]
    @ObservationIgnored private var quietCheckScheduled = false

    /// Notes a message from a copy of the extension.
    ///
    /// A copy not heard from before replaces any other copy of its profile: when the extension reloads or is
    /// reinstalled, Safari stops the old copy and starts a new one. Messages from a replaced copy after that
    /// were already on their way, and are ignored. If one keeps sending for `quietAfter`, though, it's running
    /// after all (a second Safari, say); it's taken back, without replacing anything in turn.
    private func hear(from object: [String: Any]) -> Sender {
        guard let instance = object["instance"] as? String else { return .live }
        let now = clock()
        let profile = object["profile"] as? String
        if let replacedAt = replacedCopies[instance] {
            let since = now.timeIntervalSince(replacedAt)
            guard since >= Self.quietAfter else {
                log.notice("ignoring a message from extension copy \(instance.prefix(8), privacy: .public), replaced \(Int(since)) s ago")
                return .replaced
            }
            replacedCopies[instance] = nil
            copies[instance] = Copy(profile: profile, lastHeard: now)
            liveInstances.insert(instance)
            log.notice("extension copy \(instance.prefix(8), privacy: .public) was replaced \(Int(since)) s ago but is still sending; taking it back")
            return .backFromQuiet
        }
        guard var copy = copies[instance] else {
            log.notice("new extension copy \(instance.prefix(8), privacy: .public), \(Self.describe(profile), privacy: .public)")
            for (other, known) in copies where known.profile == profile {
                replace(other, by: instance, at: now)
            }
            copies[instance] = Copy(profile: profile, lastHeard: now)
            liveInstances.insert(instance)
            scheduleQuietCheck()
            return .live
        }
        let silence = now.timeIntervalSince(copy.lastHeard)
        copy.lastHeard = now
        if let profile {
            copy.profile = profile
        }
        copies[instance] = copy
        guard !liveInstances.contains(instance) else { return .live }
        liveInstances.insert(instance)
        log.notice("extension copy \(instance.prefix(8), privacy: .public) is sending again after \(Int(silence)) s; showing its windows")
        return .backFromQuiet
    }

    /// `old` has stopped for good, because `new`, a newer copy of the same profile, has reported. Its snapshot
    /// goes, and with it cleanup's clocks for its tabs (TabCleanup.noteViewing). Its bookmarks' tabs and its
    /// tabs' custom names go to `new`'s tabs on the same pages when `new` sends its first snapshot
    /// (BookmarkTabs.update and orphanNamesOfDeadInstances, as after Safari restarts).
    private func replace(_ old: String, by new: String, at now: Date) {
        copies[old] = nil
        replacedCopies[old] = now
        if liveInstances.contains(old) {
            liveInstances.remove(old)
        }
        lastActivation[old] = nil
        anchors = anchors.filter { $0.key.instance != old }
        switchAsks.removeAll { $0.key.instance == old }
        if pendingActivation?.key.instance == old {
            pendingActivation = nil
        }
        guard let snapshot = snapshots[old] else {
            log.notice("extension copy \(old.prefix(8), privacy: .public) is replaced by \(new.prefix(8), privacy: .public), a newer copy of its profile; it had sent no snapshot")
            return
        }
        snapshots[old] = nil
        let tabs = Set(snapshot.windows.flatMap(\.tabs).map(\.id))
        replacedIds[new] = (now, Set(snapshot.windows.map(\.id)), tabs, -1)
        log.notice("extension copy \(old.prefix(8), privacy: .public) is replaced by \(new.prefix(8), privacy: .public), a newer copy of its profile; dropping its \(snapshot.windows.count) windows and \(tabs.count) tabs")
    }

    /// Logs how many of a replaced copy's window and tab ids the copy that replaced it reports: from its first
    /// snapshot, and again whenever more of them turn up, for `quietAfter`. It says whether Safari keeps tab ids
    /// when the extension reloads or is reinstalled. If it does, bookmarks' tabs could move to the new copy
    /// instead of waiting for a tab on the saved page. Counts only.
    private func compareWithReplaced(_ snapshot: Snapshot) {
        guard let old = replacedIds[snapshot.instance] else { return }
        guard clock().timeIntervalSince(old.since) < Self.quietAfter else {
            replacedIds[snapshot.instance] = nil
            return
        }
        let tabs = Set(snapshot.windows.flatMap(\.tabs).map(\.id))
        let windows = Set(snapshot.windows.map(\.id))
        let sameTabs = tabs.intersection(old.tabs).count
        let sameWindows = windows.intersection(old.windows).count
        guard sameTabs + sameWindows > old.most else { return }
        replacedIds[snapshot.instance]?.most = sameTabs + sameWindows
        log.notice("new extension copy \(snapshot.instance.prefix(8), privacy: .public) reports \(tabs.count) tabs in \(windows.count) windows: \(sameTabs) of the replaced copy's \(old.tabs.count) tab ids and \(sameWindows) of its \(old.windows.count) window ids are among them")
    }

    /// Hides the windows of copies that have sent nothing for `quietAfter`. Runs every few seconds while there
    /// are copies.
    func noteQuietCopies() {
        let now = clock()
        for (instance, copy) in copies where liveInstances.contains(instance) {
            let silence = now.timeIntervalSince(copy.lastHeard)
            guard silence >= Self.quietAfter else { continue }
            liveInstances.remove(instance)
            log.notice("extension copy \(instance.prefix(8), privacy: .public) has sent nothing for \(Int(silence)) s; hiding its \(self.snapshots[instance]?.windows.count ?? 0) windows until it does")
        }
    }

    private func scheduleQuietCheck() {
        guard !quietCheckScheduled else { return }
        quietCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietCheckInterval) { [weak self] in
            guard let self else { return }
            self.quietCheckScheduled = false
            self.noteQuietCopies()
            if !self.copies.isEmpty {
                self.scheduleQuietCheck()
            }
        }
    }

    /// A profile for the log: its UUID's first characters, never its name.
    private static func describe(_ profile: String?) -> String {
        profile.map { "profile \($0.prefix(8))" } ?? "default profile"
    }

    // MARK: - Window selection

    var hasData: Bool { !snapshots.isEmpty }

    var isConnected: Bool {
        guard let lastMessageAt else { return false }
        return Date().timeIntervalSince(lastMessageAt) < 60
    }

    /// True when Safari reports tabs but no URLs or titles, which means the extension
    /// hasn't been allowed on websites yet.
    var lacksWebsiteAccess: Bool {
        let tabs = liveSnapshots.values.flatMap { $0.windows.flatMap(\.tabs) }
        return !tabs.isEmpty && tabs.allSatisfy { $0.url == nil && $0.title == nil }
    }

    /// The Safari window the sidebar shows: the one most recently focused, cross-checked
    /// against the title of the window the panel is docked to. Only live copies' windows count.
    var currentWindow: WindowSelection? {
        let ordered = liveSnapshots.values.sorted { $0.focusChangedAt > $1.focusChangedAt }
        var best: WindowSelection?
        // Not simply the newest focus change: a copy that lost focus reports that too (#36).
        let ranked = Self.ranked(ordered, dockedProfile: dockedWindowProfile)
        for snapshot in ranked {
            let focused = (snapshot.focusedWindowId ?? -1) >= 0 ? snapshot.focusedWindowId : snapshot.lastFocusedWindowId
            if let focused, let window = snapshot.windows.first(where: { $0.id == focused }) {
                best = WindowSelection(instance: snapshot.instance, window: window)
                break
            }
        }
        if best == nil, let snapshot = ranked.first(where: { !$0.windows.isEmpty }) {
            best = WindowSelection(instance: snapshot.instance, window: snapshot.windows[0])
        }

        if let title = dockedWindowTitle, !title.isEmpty, let current = best {
            // Another profile's window on the same page isn't the docked one, once its profile is known.
            let dockedCopies = Set(ranked.filter { Self.isCopy($0, of: dockedWindowProfile) }.map(\.instance))
            let matches = dockedWindows(title: title).filter { dockedCopies.isEmpty || dockedCopies.contains($0.instance) }
            if matches.count == 1, matches[0] != current {
                return matches[0]
            }
        }
        return best
    }

    /// The order `currentWindow` tries the extension copies in (#36), from `ordered`, newest focus change first:
    ///
    /// 1. The copy of the docked window's profile, which is known from the window's toolbar
    ///    (`dockedWindowProfile`), whatever the copies' focus reports say.
    /// 2. Copies that have a focused window. A copy that loses focus to another profile's window can't see that
    ///    window, so it reports none, often with a newer time than the copy that gained it. It mustn't come first.
    /// 3. The rest, whose last focused window decides only when no copy has a focused one (Safari in the
    ///    background, or the gaining copy's report still on its way).
    static func ranked(_ ordered: [Snapshot], dockedProfile: String?) -> [Snapshot] {
        func rank(_ snapshot: Snapshot) -> Int {
            if isCopy(snapshot, of: dockedProfile) { return 0 }
            return (snapshot.focusedWindowId ?? -1) >= 0 ? 1 : 2
        }
        return ordered.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// Whether `snapshot` is from the copy of `profile` (a `ProfileKey.rawValue`; the default profile's copy sends
    /// no profile).
    private static func isCopy(_ snapshot: Snapshot, of profile: String?) -> Bool {
        guard let profile else { return false }
        return (snapshot.profile ?? "default") == profile
    }

    private func activeTitle(of window: BrowserWindow) -> String? {
        window.tabs.first(where: \.active)?.title
    }

    /// The windows that `title`, the title Safari gives the docked window, can belong to. Safari
    /// titles a window after its current page; in a profile the page title follows the profile's
    /// name and an em dash ("Personal — Apple"); and a private window adds a note (“Apple, Private
    /// Browsing”, worded for the user's language), so there the page title only has to be in it.
    ///
    /// The profile's name isn't known here, so a title fits a window when it ends with the
    /// window's page title after a " — ". A page title can contain " — " itself, and then a
    /// shorter page title in another window fits as well ("Docs — Intro" ends with " — Intro"),
    /// so of the windows that fit, only those with the longest page title are returned. That one is
    /// the right window; the shorter one would need the profile to be called "Docs".
    private func dockedWindows(title: String) -> [WindowSelection] {
        var matches: [(selection: WindowSelection, length: Int)] = []
        for snapshot in liveSnapshots.values {
            for window in snapshot.windows {
                guard let active = activeTitle(of: window), !active.isEmpty else { continue }
                if active == title || title.hasSuffix(" — " + active) || window.incognito && title.contains(active) {
                    matches.append((WindowSelection(instance: snapshot.instance, window: window), active.count))
                }
            }
        }
        let longest = matches.map(\.length).max()
        return matches.filter { $0.length == longest }.map(\.selection)
    }

    // MARK: - Tab names

    func displayTitle(for tab: BrowserTab, instance: String) -> String {
        if let custom = customNames[TabKey(instance: instance, tabId: tab.id)]?.name {
            return custom
        }
        return pageTitle(for: tab)
    }

    func pageTitle(for tab: BrowserTab) -> String {
        if let title = tab.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let host = tab.host, !host.isEmpty {
            return host
        }
        if let url = tab.url, !url.isEmpty, !url.hasPrefix("about:"), !url.hasPrefix("favorites:") {
            return url
        }
        return "New Tab"
    }

    func hasCustomName(_ key: TabKey) -> Bool {
        customNames[key] != nil
    }

    func resetName(_ key: TabKey) {
        customNames[key] = nil
        scheduleSave()
    }

    func beginRename(_ target: RenameTarget) {
        renaming = target
        onRenameStateChanged?(true)
    }

    func commitRename(_ text: String) {
        guard let target = renaming else { return }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .tab(let key):
            let tab = tab(for: key)
            if name.isEmpty || name == tab.map(pageTitle(for:)) {
                customNames[key] = nil
            } else {
                customNames[key] = CustomName(name: name, url: tab?.url)
            }
        case .bookmark(let id):
            if !name.isEmpty {
                bookmarkLists.update(id) { $0.title = name }
            }
        }
        renaming = nil
        scheduleSave()
        onRenameStateChanged?(false)
    }

    func cancelRename() {
        guard renaming != nil else { return }
        renaming = nil
        onRenameStateChanged?(false)
    }

    private func reconcileNames(with snapshot: Snapshot) {
        let tabs = snapshot.windows.flatMap(\.tabs)
        let tabsByID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names = customNames

        for (key, custom) in names where key.instance == snapshot.instance {
            if let tab = tabsByID[key.tabId] {
                if custom.url != tab.url, tab.url != nil {
                    names[key]?.url = tab.url
                }
            } else {
                names[key] = nil
            }
        }

        if !orphanNames.isEmpty {
            for tab in tabs {
                let key = TabKey(instance: snapshot.instance, tabId: tab.id)
                guard names[key] == nil, let url = tab.url, let name = orphanNames.removeValue(forKey: url) else { continue }
                names[key] = CustomName(name: name, url: url)
            }
        }

        if names != customNames {
            customNames = names
            scheduleSave()
        }
    }

    private func orphanNamesOfDeadInstances() {
        let live = Set(snapshots.keys)
        var names = customNames
        for (key, custom) in customNames where !live.contains(key.instance) {
            if let url = custom.url {
                orphanNames[url] = custom.name
            }
            names[key] = nil
        }
        if names != customNames {
            customNames = names
            scheduleSave()
        }
    }

    // MARK: - Address bar

    var activeTab: (tab: BrowserTab, instance: String)? {
        guard let selection = currentWindow, let tab = selection.window.tabs.first(where: \.active) else { return nil }
        return (tab, selection.instance)
    }

    func reloadActiveTab() {
        guard let active = activeTab else { return }
        reload(active.tab, instance: active.instance)
    }

    /// Opens Safari's own address bar, which has its full autocomplete.
    func openAddressBar() {
        onOpenAddressBar?()
    }

    // MARK: - Tab commands

    func tab(for key: TabKey) -> BrowserTab? {
        snapshots[key.instance]?.windows.lazy.flatMap(\.tabs).first { $0.id == key.tabId }
    }

    func activate(_ tab: BrowserTab, instance: String) {
        let key = TabKey(instance: instance, tabId: tab.id)
        // A click on the tab the sidebar shows as active is not skipped: the highlight can be wrong
        // (a report that never arrived, a window Safari restored without telling the extension), and
        // then the tab to switch to is the one it shows. Safari says whether it already shows the
        // tab: the press path reads the tab bar's selected button first and presses nothing if
        // it's this one (see `pressFinished`).
        let now = Date()
        let pointerDown = lastPointerDown?() ?? .distantPast
        activationCount += 1
        let request = PendingActivation(
            id: activationCount,
            key: key,
            windowId: tab.windowId,
            clickAt: now.timeIntervalSince(pointerDown) < 1.5 ? pointerDown : now,
            requestedAt: now
        )
        // Safari's report of this switch, when it comes, answers this click and no other; reports
        // of earlier clicks can still be on their way (see SwitchAsk).
        switchAsks.removeAll { !$0.isRecent }
        switchAsks.append(SwitchAsk(id: request.id, key: key, requestedAt: now))
        if switchAsks.count > 16 {
            switchAsks.removeFirst(switchAsks.count - 16)
        }
        eventCount += 1
        anchors = anchors.filter { $0.value.isRecent }
        anchors[WindowID(instance: instance, windowId: tab.windowId)] = Anchor(tabId: tab.id, at: now, clickId: request.id)
        pendingActivation = request
        scheduleCheck(of: request)
        let plan = switchPlan(for: tab, instance: instance)
        mutateWindow(instance: instance, windowId: tab.windowId) { window in
            for index in window.tabs.indices {
                window.tabs[index].active = window.tabs[index].id == tab.id
            }
        }

        switch plan {
        case .push(let why):
            log.notice("tab switch via push: \(why, privacy: .public)")
            sendActivation(of: tab, instance: instance)
        case .press(let target):
            // The press is made off the main thread; the extension's command is the fallback.
            guard let pressTab else {
                log.notice("tab switch via push: no way to press the tab bar")
                sendActivation(of: tab, instance: instance)
                return
            }
            pendingActivation?.path = "accessibility"
            pressTab(target) { [weak self] outcome in
                self?.pressFinished(outcome, request: request, tab: tab, instance: instance)
            }
        }
    }

    /// Once a click has waited as long as it's worth, if Safari still hasn't said it switched,
    /// asks where it is. A snapshot is the safe thing to ask: whatever it says is true, and it
    /// can't move Safari. (A command to switch could be run late, after a newer click that
    /// switched Safari some other way, and would undo it. See `pressFinished`.)
    private func scheduleCheck(of request: PendingActivation) {
        DispatchQueue.main.asyncAfter(deadline: .now() + PendingActivation.lifetime) { [weak self] in
            guard let self, self.pendingActivation?.id == request.id else { return }
            self.log.notice("tab switch wasn't confirmed within a second; asking Safari where it is")
            self.requestSnapshot()
            // The extension may be too starved to answer (under load its snapshots came back seconds old,
            // or not at all), so Safari's tab bar is asked too, and settles the highlight and the wait.
            self.checkSelectedTab(
                in: WindowID(instance: request.key.instance, windowId: request.windowId),
                because: "the switch wasn't confirmed within a second",
                final: true,
                whenUnknown: {}
            )
        }
    }

    /// How a click switches the tab: by pressing its button in Safari's tab bar, or by the
    /// extension. The extension is used whenever the button can't be told for certain.
    private enum SwitchPlan {
        case press(TabBarTarget)
        case push(why: String)
    }

    private func switchPlan(for tab: BrowserTab, instance: String) -> SwitchPlan {
        // The tab bar is the docked window's, which is the window the sidebar lists.
        guard let selection = currentWindow, selection.instance == instance, selection.window.id == tab.windowId else {
            return .push(why: "the tab is in a window other than the one the sidebar shows")
        }
        let tabs = selection.window.tabs
        guard let position = tabs.firstIndex(where: { $0.id == tab.id }) else {
            return .push(why: "the tab isn't in its window's list")
        }
        return .press(TabBarTarget(title: tab.title, position: position, windowTitles: tabs.map(\.title)))
    }

    private func pressFinished(_ outcome: TabBarPressOutcome, request: PendingActivation, tab: BrowserTab, instance: String) {
        switch outcome {
        case .superseded:
            break
        case .alreadySelected:
            // Safari's own tab bar does nothing for the tab that's already selected, and neither does
            // this: no press, and no report of a switch will come, so nothing is waited for or checked
            // a second later. The highlight is already on the tab.
            switchAsks.removeAll { $0.id == request.id }
            if pendingActivation?.id == request.id {
                pendingActivation = nil
            }
            log.notice("tab switch via accessibility: Safari already shows the tab; nothing pressed")
        case .pressed(let milliseconds):
            // Safari did what the button does before it answered, so there is nothing more to
            // send. In particular no command for the extension to run a second later "just in
            // case": under load the extension runs commands seconds late, after the user has
            // clicked something else, and a late `activate` puts Safari back on the old tab (#20).
            // If the press was somehow acknowledged and not acted on, the check scheduled with
            // the click puts the sidebar back where Safari is.
            log.notice("tab switch via accessibility: pressed the tab bar's button \(milliseconds) ms after the click")
        case .fallback(let reason):
            // Only if this is still the click being waited for. If a newer click replaced it, Safari
            // confirmed it, or Safari went to another tab meanwhile, a late command would only pull
            // Safari the wrong way.
            guard pendingActivation?.id == request.id else {
                log.notice("tab switch via accessibility fell back (\(reason, privacy: .public)), but the switch was confirmed, replaced by a newer click, or overtaken by Safari meanwhile")
                return
            }
            log.notice("tab switch via push: accessibility fell back (\(reason, privacy: .public))")
            pendingActivation?.path = "push after accessibility fell back"
            sendActivation(of: tab, instance: instance)
        }
    }

    private func sendActivation(of tab: BrowserTab, instance: String) {
        send(["action": "activate", "tabId": tab.id], to: instance)
    }

    func close(_ tabs: [BrowserTab], instance: String) {
        guard let windowId = tabs.first?.windowId else { return }
        let ids = Set(tabs.map(\.id))
        mutateWindow(instance: instance, windowId: windowId) { window in
            let closingActive = window.tabs.contains { ids.contains($0.id) && $0.active }
            if closingActive, let activeIndex = window.tabs.firstIndex(where: \.active) {
                // Safari usually selects the tab to the right; guess the same so the highlight doesn't blink.
                let remaining = window.tabs.enumerated().filter { !ids.contains($0.element.id) }
                if let next = remaining.first(where: { $0.offset > activeIndex }) ?? remaining.last {
                    window.tabs[next.offset].active = true
                }
            }
            window.tabs.removeAll { ids.contains($0.id) }
        }
        // A bookmark whose tab this was is closed again at once, so a click on it opens its saved page.
        changeBookmarkTabs { $0.unlink(ids.map { TabKey(instance: instance, tabId: $0) }) }
        send(["action": "close", "tabIds": Array(ids)], to: instance)
    }

    /// Closes the other tabs listed under Tabs. Bookmarks' tabs aren't listed there, so they stay open.
    func closeOtherTabs(than tab: BrowserTab, instance: String, bookmarksShown: Bool = true) {
        guard let window = window(instance: instance, id: tab.windowId) else { return }
        let listed = tabsListed(in: window, instance: instance, bookmarksShown: bookmarksShown)
        close(listed.filter { $0.id != tab.id && !$0.pinned }, instance: instance)
    }

    /// Closes the tabs listed below this one under Tabs (bookmarks' tabs aren't listed there).
    func closeTabsBelow(_ tab: BrowserTab, instance: String, bookmarksShown: Bool = true) {
        guard let window = window(instance: instance, id: tab.windowId) else { return }
        let listed = tabsListed(in: window, instance: instance, bookmarksShown: bookmarksShown)
        guard let index = listed.firstIndex(where: { $0.id == tab.id }) else { return }
        close(Array(listed[(index + 1)...]), instance: instance)
    }

    func newTab(url: String? = nil) {
        guard let selection = currentWindow else {
            openInSafari(url ?? "")
            return
        }
        var command: [String: Any] = ["action": "create", "windowId": selection.window.id]
        if let url {
            command["url"] = url
        }
        send(command, to: selection.instance)
    }

    func duplicate(_ tab: BrowserTab, instance: String) {
        send(["action": "duplicate", "tabId": tab.id], to: instance)
    }

    func reload(_ tab: BrowserTab, instance: String) {
        send(["action": "reload", "tabId": tab.id], to: instance)
    }

    func setMuted(_ muted: Bool, tab: BrowserTab, instance: String) {
        // Safari doesn't report a mute change, so the icon changes here at once; the extension
        // sends a snapshot after the command, which settles it either way.
        mutateWindow(instance: instance, windowId: tab.windowId) { window in
            if let index = window.tabs.firstIndex(where: { $0.id == tab.id }) {
                window.tabs[index].muted = muted
            }
        }
        send(["action": "mute", "tabId": tab.id, "muted": muted], to: instance)
    }

    func copyLink(_ url: String?) {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    /// Moves a tab to `index` (its position once moved) and tells Safari.
    func moveTab(_ tab: BrowserTab, instance: String, to index: Int) {
        var destination = index
        mutateWindow(instance: instance, windowId: tab.windowId) { window in
            guard let from = window.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            let moved = window.tabs.remove(at: from)
            destination = min(max(index, 0), window.tabs.count)
            window.tabs.insert(moved, at: destination)
            for position in window.tabs.indices {
                window.tabs[position].index = position
            }
        }
        guard destination != tab.index else { return }
        send(["action": "move", "tabId": tab.id, "index": destination], to: instance)
    }

    private func window(instance: String, id: Int) -> BrowserWindow? {
        snapshots[instance]?.windows.first { $0.id == id }
    }

    private func mutateWindow(instance: String, windowId: Int, _ body: (inout BrowserWindow) -> Void) {
        guard var snapshot = snapshots[instance],
              let index = snapshot.windows.firstIndex(where: { $0.id == windowId }) else { return }
        body(&snapshot.windows[index])
        snapshots[instance] = snapshot
    }

    private func send(_ command: [String: Any], to instance: String) {
        var command = command
        command["instance"] = instance
        sendCommand?(command)
    }

    private func openInSafari(_ url: String) {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return }
        let urls = URL(string: url).map { [$0] } ?? []
        NSWorkspace.shared.open(urls, withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Profiles (#34)

    /// The profile a window belongs to, from the snapshot that lists it (`Snapshot.profile`, which the
    /// default profile's copy of the extension doesn't send). Nil for a private window: it belongs to
    /// no profile, though the default profile's copy is the one that reports it.
    func profile(of window: BrowserWindow, instance: String) -> ProfileKey? {
        guard !window.incognito else { return nil }
        return ProfileKey(snapshotProfile: snapshots[instance]?.profile)
    }

    /// The profile of the window the sidebar shows (`currentWindow`), whose Pinned list it shows. Nil
    /// while that's a private window, and while no window is shown.
    var currentWindowProfile: ProfileKey? {
        currentWindow.flatMap { profile(of: $0.window, instance: $0.instance) }
    }

    /// The Pinned list the sidebar shows: that of the current window's profile. Nil in a private
    /// window, which has no Pinned section.
    var currentPinnedList: BookmarkList? {
        currentWindowProfile.map(BookmarkList.pinned)
    }

    /// The profile last named in the log by `logShownSpace`.
    @ObservationIgnored private var loggedSpace: String?

    /// Logs whose window the sidebar shows when that changes from one profile (or a private window)
    /// to another, with how many favorites and pinned items it shows then. Never a profile's name.
    private func logShownSpace() {
        guard let selection = currentWindow else { return }
        let profile = profile(of: selection.window, instance: selection.instance)
        let space = profile.map { $0.isDefault ? "the default profile" : "profile \($0.rawValue.prefix(8))" } ?? "a private window"
        guard space != loggedSpace else { return }
        loggedSpace = space
        let pinned = profile.map { bookmarkLists.items(in: .pinned($0)).count }.map(String.init) ?? "no"
        log.notice("the sidebar shows \(space, privacy: .public): \(self.favorites.count) favorites, \(pinned, privacy: .public) pinned")
    }

    // MARK: - Favorites and Pinned

    /// The favorites, shared by every profile and shown in private windows too.
    var favorites: [Bookmark] { bookmarkLists.favorites }

    func bookmarks(in list: BookmarkList) -> [Bookmark] {
        bookmarkLists.items(in: list)
    }

    /// The ids of the bookmarks a window shows: the favorites, and its profile's Pinned list. A tab
    /// only belongs to a bookmark its window shows.
    func bookmarkIds(shownIn window: BrowserWindow, instance: String) -> Set<UUID> {
        Set(bookmarkLists.shown(in: profile(of: window, instance: instance)).map(\.id))
    }

    /// The bookmark's own tab in the window the sidebar shows, if it has one there. Wherever the
    /// tab has browsed to since, it's the bookmark's until it closes.
    func openTab(for bookmark: Bookmark) -> BrowserTab? {
        guard let selection = currentWindow else { return nil }
        return bookmarkTabs.tab(of: bookmark.id, in: selection.window, instance: selection.instance)
    }

    /// What a press on a favorite's tile or a pinned row does on mouse-down. One whose tab is open in
    /// this window switches to it at once, like a tab row. Otherwise nothing happens until the button
    /// goes up, and then `open(_:inNewTab:)` opens it: a press that turns into a drag to reorder mustn't
    /// open a tab. A press with ⌘ always waits, and opens an ordinary new tab. Says whether the press
    /// waits for the button to go up.
    func pressBookmark(_ bookmark: Bookmark, command: Bool) -> Bool {
        if !command, openTab(for: bookmark) != nil {
            open(bookmark)
            return false
        }
        return true
    }

    /// Opens a favorite or pinned item in the window the sidebar shows: switches to its tab there, or
    /// opens its saved page in a new tab of that window (so a favorite's tab opens in the profile of the
    /// window it's clicked in), which becomes its tab.
    func open(_ bookmark: Bookmark, inNewTab: Bool = false) {
        guard let selection = currentWindow else {
            openInSafari(bookmark.url)
            return
        }
        if !inNewTab, let tab = openTab(for: bookmark) {
            activate(tab, instance: selection.instance)
            return
        }
        // An ordinary tab that is on the saved page becomes the bookmark's, rather than a second
        // copy opening.
        if !inNewTab, let tab = tabOnSavedPage(of: bookmark, in: selection) {
            changeBookmarkTabs { $0.link(TabKey(instance: selection.instance, tabId: tab.id), to: bookmark.id) }
            activate(tab, instance: selection.instance)
            return
        }
        // A quick second click can arrive before a snapshot has the tab the first one opened; don't
        // open two. Once a snapshot has it, the click switches to it (above), and once it's closed,
        // a click opens a new one.
        pendingBookmarkOpens = pendingBookmarkOpens.filter { Date().timeIntervalSince($0.value.at) < 2 }
        let opening = pendingBookmarkOpens.values.contains { pending in
            pending.bookmark == bookmark.id && pending.windowId == selection.window.id
                && pending.tab.map { bookmarkTabs.bookmark(owning: $0) == bookmark.id && tab(for: $0) == nil } ?? true
        }
        if !inNewTab, opening {
            return
        }
        let requestId = UUID().uuidString
        pendingBookmarkOpens[requestId] = (bookmark.id, selection.window.id, Date(), nil)
        send([
            "action": "create",
            "windowId": selection.window.id,
            "url": bookmark.url,
            "requestId": requestId,
        ], to: selection.instance)
    }

    /// Makes a favorite or pinned item of the tab's page, at `index` in `list` (at the end without
    /// one). It's what dragging a tab onto Favorites or Pinned does, and the tab's menu.
    func addBookmark(from tab: BrowserTab, instance: String, to list: BookmarkList, at index: Int? = nil) {
        guard let url = tab.url, !url.isEmpty else { return }
        let bookmark = Bookmark(
            title: displayTitle(for: tab, instance: instance),
            url: url,
            faviconURL: tab.favIconUrl
        )
        insert(bookmark, into: list, at: index)
        // The tab moves up as the new bookmark's tab, unless it's another bookmark's, or its window
        // doesn't show that list (another profile's Pinned list).
        if let window = window(instance: instance, id: tab.windowId),
           bookmarkIds(shownIn: window, instance: instance).contains(bookmark.id) {
            changeBookmarkTabs { $0.link(TabKey(instance: instance, tabId: tab.id), to: bookmark.id) }
        }
    }

    /// Add Bookmark for the current tab (the + in Pinned's header). It pins the tab in the current
    /// window's profile's Pinned list. A private window has none, so there it adds to Favorites.
    func addBookmarkForCurrentTab() {
        guard let selection = currentWindow, let tab = selection.window.tabs.first(where: \.active) else { return }
        let list = profile(of: selection.window, instance: selection.instance).map(BookmarkList.pinned) ?? .favorites
        addBookmark(from: tab, instance: selection.instance, to: list)
    }

    /// A link dragged in from a web page or Safari's address bar.
    func addBookmark(url: URL, to list: BookmarkList, at index: Int? = nil) {
        guard let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else { return }
        insert(Bookmark(title: url.host() ?? url.absoluteString, url: url.absoluteString), into: list, at: index)
    }

    private func insert(_ bookmark: Bookmark, into list: BookmarkList, at index: Int?) {
        bookmarkLists.insert(bookmark, into: list, at: index)
        log.notice("added a bookmark to \(list, privacy: .public), which has \(self.bookmarkLists.items(in: list).count) now")
        scheduleSave()
    }

    /// Takes a favorite or pinned item out of its list. Its tabs stay open, back under Tabs.
    func removeBookmark(_ bookmark: Bookmark) {
        guard let list = bookmarkLists.list(containing: bookmark.id) else { return }
        bookmarkLists.remove(bookmark.id)
        changeBookmarkTabs { $0.forget(bookmark: bookmark.id) }
        log.notice("removed a bookmark from \(list, privacy: .public), which has \(self.bookmarkLists.items(in: list).count) now")
        scheduleSave()
    }

    func replaceBookmarkWithCurrentPage(_ bookmark: Bookmark) {
        guard let selection = currentWindow,
              let tab = selection.window.tabs.first(where: \.active),
              let url = tab.url,
              bookmarkLists.bookmark(bookmark.id) != nil else { return }
        bookmarkLists.update(bookmark.id) { saved in
            saved.url = url
            saved.faviconURL = tab.favIconUrl
        }
        // The tab showing the page becomes the bookmark's too, if the bookmark has none in this window
        // (and the tab isn't another bookmark's). The bookmark's own tab is already.
        if bookmarkTabs.tab(of: bookmark.id, in: selection.window, instance: selection.instance) == nil,
           bookmarkIds(shownIn: selection.window, instance: selection.instance).contains(bookmark.id) {
            changeBookmarkTabs { $0.link(TabKey(instance: selection.instance, tabId: tab.id), to: bookmark.id) }
        }
        scheduleSave()
    }

    /// Moves a favorite or pinned item to `index` in `list` (its position once moved): reordering a
    /// list, or moving from one list to the other. A pinned item moved to Favorites becomes shared, and
    /// keeps its tabs. A favorite moved to Pinned lets go of its tabs in windows that don't show that
    /// list (other profiles' and private ones), which go back under Tabs there.
    func moveBookmark(_ id: UUID, to list: BookmarkList, at index: Int) {
        let from = bookmarkLists.list(containing: id)
        guard bookmarkLists.move(id, to: list, at: index) else { return }
        if let from, from != list {
            log.notice("moved a bookmark from \(from, privacy: .public) to \(list, privacy: .public)")
            changeBookmarkTabs { tabs in
                for snapshot in snapshots.values {
                    tabs.unlinkTabs(in: snapshot) { bookmarkIds(shownIn: $0, instance: snapshot.instance) }
                }
            }
        }
        scheduleSave()
    }

    /// An ordinary tab in the window on the bookmark's saved page: the one showing, or the first.
    private func tabOnSavedPage(of bookmark: Bookmark, in selection: WindowSelection) -> BrowserTab? {
        let page = bookmark.url.comparableURL
        let candidates = selection.window.tabs.filter {
            $0.url?.comparableURL == page && bookmarkTabs.bookmark(owning: TabKey(instance: selection.instance, tabId: $0.id)) == nil
        }
        return candidates.first(where: \.active) ?? candidates.first
    }

    /// A tab opened for a bookmark becomes its tab, unless the bookmark already has one in that
    /// window (Open in New Tab on an open bookmark gives an ordinary tab), or was removed or moved to
    /// a list that window doesn't show meanwhile.
    private func linkOpenedTab(_ key: TabKey, to bookmark: UUID, windowId: Int) {
        guard bookmarkLists.bookmark(bookmark) != nil else { return }
        if let window = window(instance: key.instance, id: windowId) {
            guard bookmarkIds(shownIn: window, instance: key.instance).contains(bookmark),
                  bookmarkTabs.tab(of: bookmark, in: window, instance: key.instance) == nil else { return }
        }
        changeBookmarkTabs { $0.link(key, to: bookmark) }
    }

    private func updateBookmarkTabs(with snapshot: Snapshot) {
        let before = bookmarkTabs.owners.count
        changeBookmarkTabs { tabs in
            tabs.update(with: snapshot, live: Set(snapshots.keys), bookmarks: bookmarkLists.all) {
                bookmarkIds(shownIn: $0, instance: snapshot.instance)
            }
        }
        let after = bookmarkTabs.owners.count
        if after != before {
            log.notice("bookmarks' tabs: \(before) before snapshot \(snapshot.seq), \(after) after")
        }
        logShownSpace()
    }

    /// Changes the links on a copy, so views aren't told of a change when nothing changed, and saves
    /// them when something did.
    private func changeBookmarkTabs(_ change: (inout BookmarkTabs) -> Void) {
        var tabs = bookmarkTabs
        change(&tabs)
        guard tabs != bookmarkTabs else { return }
        bookmarkTabs = tabs
        scheduleSave()
    }

    // MARK: - Persistence

    private struct SavedName: Codable {
        let instance: String
        let tabId: Int
        let name: CustomName
    }

    private struct SavedState: Codable {
        /// Cleanup's clocks and its list of closed tabs. Missing from files saved before it existed.
        var cleanup: TabCleanup.Saved?
        /// The favorites. Before there were Pinned lists this held every bookmark, which became the
        /// favorites as they were (#34).
        var bookmarks: [Bookmark]
        /// Each profile's Pinned list, by `ProfileKey.rawValue`. Missing from files saved before it existed.
        var pinned: [String: [Bookmark]]?
        var names: [SavedName]
        var orphanNames: [String: String]
        /// Which tabs belong to bookmarks, and the extension instances running when they were saved
        /// (#25). Optional, so a file saved before there were any still loads.
        var bookmarkTabs: [BookmarkTabs.Saved]?
        var instances: [String]?
    }

    static var defaultStateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Side Tabs", directoryHint: .isDirectory).appending(path: "state.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        cleanup.restore(state.cleanup)
        bookmarkLists = BookmarkLists(favorites: state.bookmarks, pinned: state.pinned ?? [:])
        orphanNames = state.orphanNames
        customNames = Dictionary(
            state.names.map { (TabKey(instance: $0.instance, tabId: $0.tabId), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        bookmarkTabs = BookmarkTabs(saved: state.bookmarkTabs ?? [], instances: state.instances ?? [], bookmarks: bookmarkLists.all)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func save() {
        let state = SavedState(
            cleanup: cleanup.saved,
            bookmarks: bookmarkLists.favorites,
            pinned: bookmarkLists.savedPinned,
            names: customNames.map { SavedName(instance: $0.key.instance, tabId: $0.key.tabId, name: $0.value) },
            orphanNames: orphanNames,
            bookmarkTabs: bookmarkTabs.saved,
            instances: bookmarkTabs.savedInstances
        )
        do {
            let url = stateURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            NSLog("Side Tabs: could not save state: \(error)")
        }
    }
}
