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

    /// Each copy's windows, as the sidebar shows them. Set only when what it shows changes: a snapshot that shows
    /// the same as before leaves it alone, so nothing that watches it runs again for nothing (#81). So a snapshot's
    /// `seq` and `startedAt` here may be an older one's; the newest applied is in `appliedSeq`.
    private(set) var snapshots: [String: Snapshot] = [:] {
        // Any change to which tab is active (a snapshot, a report of a switch, a click) starts or
        // stops a tab's cleanup clock.
        didSet {
            refreshShown()
            cleanup.snapshotsChanged(from: oldValue, to: snapshots)
            settleSwitchPreview()
        }
    }
    /// The number of the newest snapshot (or changes) applied for each copy, which reports and heartbeats are
    /// compared with.
    @ObservationIgnored private var appliedSeq: [String: Int] = [:]
    /// Each copy's windows exactly as its last snapshot or changes said, untouched by reports of tab switches or the
    /// sidebar's own changes: what the copy counts its next changes from (#81).
    @ObservationIgnored private var copyStates: [String: Snapshot] = [:]
    /// When each copy was last asked for a full snapshot because changes didn't follow from what the app has.
    @ObservationIgnored private var fullSnapshotAskedAt: [String: Date] = [:]
    /// Each copy's windows as it last reported them: its last snapshot, with the highlight where its reports of
    /// tab switches since have put it. `snapshots` also has what the sidebar changed at once for a click, a
    /// close, a move or a mute; a window goes back to this when its command can't reach the extension (#67).
    @ObservationIgnored private var reportedSnapshots: [String: Snapshot] = [:]
    /// Closes tabs nobody has looked at for a while, when that's turned on, and keeps the list for
    /// reopening them (TabCleanup.swift).
    let cleanup = TabCleanup()
    /// When the extension last sent anything, on the awake clock (`uptime`), so sleep isn't silence (#45). Not
    /// observed: it changes with every message, and views only need `isConnected` (#83).
    @ObservationIgnored private(set) var lastMessageAt: TimeInterval?
    /// Whether the extension has sent anything in the last `connectedFor` seconds of awake time, for the menu bar
    /// menu and the empty sidebar. Set only when it changes, so a message doesn't update them (#83).
    private(set) var isConnected = false
    /// The one pending look at whether the extension has gone silent (`checkConnection`).
    @ObservationIgnored private var connectionCheck: DispatchWorkItem?
    /// Favorites, shared by every profile, and each profile's Pinned list (#34, BookmarkLists.swift).
    private(set) var bookmarkLists = BookmarkLists()
    private(set) var customNames: [TabKey: CustomName] = [:]
    /// The tabs that belong to favorites and pinned items, listed under them instead of under Tabs
    /// (see BookmarkTabs).
    private(set) var bookmarkTabs = BookmarkTabs()

    var renaming: RenameTarget?

    /// Hints from SafariTracker, used to pick the window the sidebar is docked to.
    var safariIsFrontmost = false {
        didSet {
            // Safari can hold a copy back while it's in the background (#45).
            if safariIsFrontmost, !oldValue {
                safariCameToFront()
            }
        }
    }
    var dockedWindowTitle: String? {
        didSet {
            if dockedWindowTitle != oldValue {
                refreshShown()
                dockedTitleChanged(from: oldValue)
                logShownSpace()
            }
        }
    }
    /// The docked window's profile, read from its toolbar by SafariProfiles (#33), as `ProfileKey.rawValue`:
    /// "default", or the profile's UUID as its copy's snapshots carry it. Nil while it isn't known, in a private
    /// window, and where Safari has no profiles. `currentWindow` takes the docked window from that profile's copy.
    var dockedWindowProfile: String? {
        didSet {
            if dockedWindowProfile != oldValue { refreshShown() }
        }
    }
    /// The docked window is a private window: in a Safari with profiles, the one kind of window without a
    /// profile button (SafariProfiles). Its copy is the default profile's.
    var dockedWindowIsPrivate = false {
        didSet {
            if dockedWindowIsPrivate != oldValue { refreshShown() }
        }
    }
    /// How many of Safari's windows are like the docked one, from their toolbars (SafariProfiles): of its
    /// profile, or private. A copy that lists that many can see them all, and is only behind on a title.
    var dockedLikeWindowCount: Int? {
        didSet {
            refreshShown()
            settleSwitchPreview()
            // A window like it opened: a title that fits nothing may now be a window its copy hasn't listed.
            if dockedLikeWindowCount != oldValue { scheduleDockedWindowCheck(restart: false) }
        }
    }
    /// The docked window has been open long enough for its copy to have reported it: about 2 s, and longer
    /// right after Side Tabs starts (SafariProfiles). Before that, a copy that doesn't list it yet says nothing.
    var dockedWindowSettled = false {
        didSet {
            refreshShown()
            settleSwitchPreview()
        }
    }
    /// The front window's profile while Side Tabs is off in it (SafariProfiles' id): the sidebar shows the row to turn
    /// it on in place of the sections (#33).
    var profileToTurnOn: UUID? {
        didSet {
            if profileToTurnOn != oldValue {
                refreshShown()
                settleSwitchPreview()
            }
        }
    }

    /// What the sidebar shows while a profile switch's window comes back from the Dock (#44): its guess at
    /// the switch's profile and window, in place of `currentWindow`, until Safari reports.
    struct SwitchPreview: Equatable {
        /// The switch's: a newer click supersedes it.
        let id: Int
        /// Nil only for a swipe to a profile whose copy Side Tabs hasn't learned yet (#72).
        var profile: ProfileKey?
        /// The profile's id in SafariProfiles, when it began the preview.
        var profileID: UUID? = nil
        var guess: SwitchGuess
        /// Safari has shown the switch's profile in front: the preview ends as soon as the sidebar's own choice
        /// is a window of that profile.
        var reported = false
        /// A swipe brought the page in (#72): it shows with no fade, and changes from it fade briefly.
        var swiped = false
    }
    /// Nil when the sidebar follows Safari, as it does but for a switch's window coming back from the Dock.
    private(set) var switchPreview: SwitchPreview? {
        didSet {
            if switchPreview != oldValue { refreshShown() }
        }
    }
    /// The sidebar's fade over to a switch's profile (SidebarFade): one set of sections, faded out over what was
    /// shown, swapped while nothing shows, and faded back in. Only a preview's start sets it going.
    private(set) var sidebarFade = SidebarFade() {
        didSet {
            if sidebarFade != oldValue { refreshShown() }
        }
    }
    /// What the sidebar showed when the fade began, kept on screen while it fades out.
    private(set) var fadingOutContent: ShownContent? {
        didSet {
            if fadingOutContent != oldValue { refreshShown() }
        }
    }

    /// Sends a command to the extension (ExtensionBridge.send). The closure it's given runs on the main thread
    /// if Safari couldn't take the command (#67).
    @ObservationIgnored var sendCommand: ((_ command: [String: Any], _ failed: @escaping () -> Void) -> Void)?
    @ObservationIgnored var onToggleSidebar: (() -> Void)?
    @ObservationIgnored var onRenameStateChanged: ((Bool) -> Void)?
    @ObservationIgnored var onOpenAddressBar: (() -> Void)?
    /// When the pointer last went down on the sidebar, so a switch is timed from the click.
    @ObservationIgnored var lastPointerDown: (() -> Date)?
    /// With "Minimize other profiles' windows" on (#42), switches to the profile with this key (a snapshot's
    /// `profile`) the way its button does, when it isn't the current profile, so a closed tab of it can reopen
    /// in its window, which may be minimized. Says whether a switch started; the closure it's given runs on the
    /// main thread once it's done, with whether the profile's window came to the front.
    @ObservationIgnored var switchProfileFirst: ((_ profile: String?, _ then: @escaping (Bool) -> Void) -> Bool)?
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
        // Copies already running haven't spoken to this launch of Side Tabs yet (#45).
        noteChance(at: uptime())
        scheduleCopyCheck()
    }

    // MARK: - Messages from the extension

    /// Handles a message given as JSON, read the way the app reads it (ExtensionMessage). For the checks in Tests/.
    func handleMessage(type: String, payload: Data, object: [String: Any]) -> [String: Any] {
        guard let message = ExtensionMessage(data: payload) else { return [:] }
        return handleMessage(message)
    }

    func handleMessage(_ message: ExtensionMessage) -> [String: Any] {
        let object = message.object
        noteMessageArrived()
        noteExtensionPath(object["extensionPath"] as? String)
        let sender = hear(from: object)
        if sender == .replaced {
            return [:]
        }
        var reply = answer(message)
        if sender == .backFromQuiet, let instance = object["instance"] as? String {
            // Its snapshot is from before it went quiet. The extension acts on `needSnapshot` in any reply,
            // but replies get lost (#37), so it's asked with a command too.
            reply["needSnapshot"] = true
            send(["action": "snapshot"], to: instance)
        }
        return reply
    }

    private func answer(_ message: ExtensionMessage) -> [String: Any] {
        let object = message.object
        switch message.type {
        case "snapshot":
            if let snapshot = message.snapshot {
                apply(snapshot)
            } else {
                NSLog("Side Tabs: bad snapshot: \(message.error.map(String.init(describing:)) ?? "?")")
            }
            return [:]

        case "changes":
            // What changed since a state of the copy's that the app took before (#81).
            guard let changes = message.changes else {
                NSLog("Side Tabs: bad changes: \(message.error.map(String.init(describing:)) ?? "?")")
                return [:]
            }
            return applyChanges(changes)

        case "icon":
            noteIcon(url: object["url"] as? String, data: object["data"] as? String)
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
            // A new copy: its first snapshot is on its way, unless it's here already.
            return ["needSnapshot": appliedSeq[object["instance"] as? String ?? ""] == nil]

        case "heartbeat":
            // The extension reports the last snapshot or changes it delivered; ask again if we missed one.
            let instance = object["instance"] as? String ?? ""
            let seq = object["seq"] as? Int ?? 0
            let applied = appliedSeq[instance] ?? -1
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

    /// Turns changes back into the snapshot they stand for, and applies it as one (#81): every rule between
    /// snapshots and reports holds for them as it does for snapshots. If the app hasn't got the state they're counted
    /// from (it missed a message, or started since), the copy is asked for a full snapshot.
    private func applyChanges(_ changes: SnapshotChanges) -> [String: Any] {
        let instance = changes.instance
        // Older than what the app has: already overtaken (a full snapshot sent after these got no reply in time).
        if let applied = appliedSeq[instance], changes.seq <= applied {
            log.info("ignoring older changes (\(changes.seq)) from \(instance.prefix(8), privacy: .public)")
            return [:]
        }
        guard let snapshot = copyStates[instance]?.applying(changes) else {
            let have = copyStates[instance].map { "\($0.seq)" } ?? "nothing"
            log.notice("changes \(changes.seq) from \(instance.prefix(8), privacy: .public) are counted from \(changes.base), but the app has \(have, privacy: .public); asking for a full snapshot")
            // The reply asks for it, but replies can be lost (#37), so a command asks too, once a second at most.
            if Date().timeIntervalSince(fullSnapshotAskedAt[instance] ?? .distantPast) > 1 {
                fullSnapshotAskedAt[instance] = Date()
                send(["action": "snapshot"], to: instance)
            }
            return ["needSnapshot": true]
        }
        apply(snapshot)
        return [:]
    }

    /// The icons the extension sent by a short name in place of a page's `data:` URL (#81), as base64, oldest first,
    /// so a favorite, a pinned item or a closed tab made from such a tab can keep its icon (`savedIconURL`).
    @ObservationIgnored private var namedIcons: [(name: String, data: String)] = []
    /// The prefix of those names (DATA_ICON_PREFIX in background.js).
    static let namedIconPrefix = "sidetabs-icon:"

    private func noteIcon(url: String?, data: String?) {
        guard let url, url.hasPrefix(Self.namedIconPrefix), let data, !data.isEmpty else { return }
        namedIcons.removeAll { $0.name == url }
        namedIcons.append((url, data))
        if namedIcons.count > 100 {
            namedIcons.removeFirst()
        }
    }

    /// A tab's icon URL as kept with a favorite, a pinned item or a closed tab, which outlive the extension's copy:
    /// a name for a `data:` icon (#81) becomes that `data:` URL again when the icon is here. Without it, the name
    /// still works while the copy that gave it runs.
    func savedIconURL(_ url: String?) -> String? {
        guard let url, url.hasPrefix(Self.namedIconPrefix),
              let data = namedIcons.last(where: { $0.name == url })?.data else { return url }
        return "data:application/octet-stream;base64," + data
    }

    private func apply(_ snapshot: Snapshot) {
        if let applied = appliedSeq[snapshot.instance], applied > snapshot.seq {
            return
        }
        let isNewInstance = snapshots[snapshot.instance] == nil
        appliedSeq[snapshot.instance] = snapshot.seq
        copyStates[snapshot.instance] = snapshot
        reportedSnapshots[snapshot.instance] = snapshot
        // Only when it shows something else (#81): the same windows again, as most snapshots are, change nothing.
        if snapshots[snapshot.instance].map({ !$0.hasSameContent(as: snapshot) }) ?? true {
            snapshots[snapshot.instance] = snapshot
        }
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
            if seq <= (appliedSeq[instance] ?? -1) || seq <= (lastActivation[instance]?.seq ?? -1) {
                log.info("ignoring an older tab switch report (\(seq)) from \(instance.prefix(8), privacy: .public)")
                return
            }
        }
        // It's what the copy says, whatever the sidebar makes of it below.
        if var copy = reportedSnapshots[instance], let index = copy.windows.firstIndex(where: { $0.id == windowId }),
           copy.windows[index].tabs.contains(where: { $0.id == tabId }) {
            for position in copy.windows[index].tabs.indices {
                copy.windows[index].tabs[position].active = copy.windows[index].tabs[position].id == tabId
            }
            reportedSnapshots[instance] = copy
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
        reportedSnapshots.removeAll()
        appliedSeq.removeAll()
        copyStates.removeAll()
        fullSnapshotAskedAt.removeAll()
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
        dockedAsks.removeAll()
        dockedCheck?.cancel()
        dockedCheck = nil
        dockedUnknownSince = nil
        if !liveInstances.isEmpty {
            liveInstances.removeAll()
        }
        // Its extension went with it; the next message from a new launch connects it again.
        connectionCheck?.cancel()
        connectionCheck = nil
        if isConnected {
            isConnected = false
            bridgeLog.notice("Safari quit; the extension no longer counts as connected")
        }
        scheduleCopyCheck()
    }

    /// Asks the extension for a full snapshot: only copy `copy` (#47), or every copy when it's nil, which is
    /// for when none can be told apart: Side Tabs starting, Safari launching, the Mac waking.
    func requestSnapshot(of copy: String? = nil) {
        if let copy {
            send(["action": "snapshot"], to: copy)
        } else {
            sendCommand?(["action": "snapshot"]) {}
        }
    }

    // MARK: - Asking about the docked window (#82, #47)
    //
    // Safari doesn't always tell extensions about windows it restores (Reopen Last Closed Window, a relaunch),
    // so when the docked window's title fits no window the copies list, its copy may have to be asked for a
    // snapshot. But a title nearly always fits nothing only for a moment: Accessibility reports a new title
    // before the extension reports the change (its lazy snapshot, 30–250 ms after the change and longer under
    // load), and before a copy's `activated` report of a tab switch made in Safari. A full snapshot costs Safari
    // a query of every window and tab, the app a decode, and the sidebar a redraw, and a page can change its
    // title every second. So the docked window's copy is asked only:
    //
    // - once the title has fitted nothing for `dockedAskWait`, longer than those reports take to arrive (and
    //   no later than `dockedAskLatest` after the docked window's title stopped fitting, however often it
    //   changes, so a restored window is asked about before it counts as unseen);
    // - while the docked window isn't one its copy can't see (`unseenDockedWindow`, #41): asking never helps;
    // - while its copy doesn't list as many windows as Safari has like it (`dockedLikeWindowCount`): a copy
    //   that does can see them all, and is only behind on a title;
    // - of the docked window's copy alone (`dockedCopiesToAsk`): every copy only when none can be told;
    // - at most `dockedAsksPerListing` times while the copy lists the same windows and the window stays docked,
    //   so a title that never fits (Safari titles the window other than its page) doesn't ask again and again.

    /// How long the docked window's title has to fit nothing before its copy is asked: longer than the
    /// extension's lazy snapshot of a change and a copy's `activated` report take to arrive. Also how long
    /// after an ask its copy is asked once more, if the window still fits nothing.
    static let dockedAskWait: TimeInterval = 0.7
    /// The longest the docked window's titles can go on fitting nothing before its copy is asked, counted from
    /// the first of them: under `ProfileRules.offAfter`, when a window its copy doesn't list counts as unseen.
    static let dockedAskLatest: TimeInterval = 1.3
    /// How many times a copy is asked about the docked window while it lists the same windows: once, and
    /// once more in case Safari was still restoring the window.
    static let dockedAsksPerListing = 2

    /// The pending look at whether to ask about the docked window.
    @ObservationIgnored private var dockedCheck: DispatchWorkItem?
    /// Since when the docked window's title has fitted no window, through any changes to it.
    @ObservationIgnored private var dockedUnknownSince: Date?
    /// The asks about the docked window since it was docked, by copy ("" for every copy): the windows the copy
    /// listed when it was last asked, and how many times it was asked while it listed them.
    @ObservationIgnored private var dockedAsks: [String: (listing: Set<String>, count: Int)] = [:]

    /// Another window is docked, or none (SafariProfiles): its copy may be asked about it afresh.
    func dockedWindowChanged() {
        dockedAsks.removeAll()
        dockedUnknownSince = nil
        scheduleDockedWindowCheck(restart: true)
    }

    private func dockedTitleChanged(from oldTitle: String?) {
        // The wait starts afresh unless the title before this one still fits nothing either.
        let wasUnknown = oldTitle.map { !$0.isEmpty && dockedWindows(title: $0).isEmpty } ?? false
        if !wasUnknown {
            dockedUnknownSince = nil
        }
        scheduleDockedWindowCheck(restart: true)
    }

    /// Looks at whether to ask about the docked window once its title has fitted nothing for `dockedAskWait`.
    /// A new title (`restart`) puts the look off until it has waited that long too, but no later than
    /// `dockedAskLatest` after the titles stopped fitting; anything else leaves a pending look where it is.
    private func scheduleDockedWindowCheck(restart: Bool) {
        guard let title = dockedWindowTitle, !title.isEmpty, dockedWindows(title: title).isEmpty else {
            dockedCheck?.cancel()
            dockedCheck = nil
            dockedUnknownSince = nil
            return
        }
        let now = Date()
        let since = dockedUnknownSince ?? now
        dockedUnknownSince = since
        if dockedCheck != nil, !restart { return }
        var wait = Self.dockedAskWait
        if restart {
            wait = max(0, min(wait, since.addingTimeInterval(Self.dockedAskLatest).timeIntervalSince(now)))
        }
        dockedCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dockedCheck = nil
            self.askAboutDockedWindowIfUnknown()
        }
        dockedCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func askAboutDockedWindowIfUnknown() {
        guard let title = dockedWindowTitle, !title.isEmpty, dockedWindows(title: title).isEmpty else {
            dockedUnknownSince = nil
            return
        }
        guard unseenDockedWindow == nil, !dockedCopyListsEveryLikeWindow else { return }
        var asked: [String] = []
        for copy in dockedCopiesToAsk.map({ $0 as [String?] }) ?? [nil] {
            let key = copy ?? ""
            let listing = Set(snapshots.values.filter { copy == nil || $0.instance == copy }.flatMap { snapshot in
                snapshot.windows.map { "\(snapshot.instance)/\($0.id)" }
            })
            let before = dockedAsks[key].flatMap { $0.listing == listing ? $0.count : nil } ?? 0
            guard before < Self.dockedAsksPerListing else { continue }
            dockedAsks[key] = (listing, before + 1)
            requestSnapshot(of: copy)
            asked.append(copy.map { "copy \($0.prefix(8))" } ?? "every copy")
        }
        guard !asked.isEmpty else { return }
        let waited = Int(Date().timeIntervalSince(dockedUnknownSince ?? Date()) * 1000)
        log.notice("the docked window has fitted no window the extension lists for \(waited) ms; asked \(asked.joined(separator: ", "), privacy: .public) for a snapshot")
        // In case Safari was still restoring the window, its copy is asked once more if it still fits nothing.
        scheduleDockedWindowCheck(restart: false)
    }

    /// The copies to ask about the docked window: its profile's (the default profile's for a private window),
    /// else the copy of the window the sidebar shows (#47). Empty when its profile's copy hasn't spoken yet: it
    /// sends a snapshot when it starts. Nil when no copy can be told: Side Tabs or Safari starting.
    private var dockedCopiesToAsk: [String]? {
        if let profile = dockedWindowIsPrivate ? "default" : dockedWindowProfile {
            let own = snapshots.values.filter { Self.isCopy($0, of: profile) }.map(\.instance).sorted()
            return own.isEmpty && snapshots.isEmpty ? nil : own
        }
        return currentWindow.map { [$0.instance] }
    }

    /// The docked window's live copy lists as many windows as Safari has like it (`dockedLikeWindowCount`): it
    /// can see them all, and is only behind on a title.
    private var dockedCopyListsEveryLikeWindow: Bool {
        guard let likeWindows = dockedLikeWindowCount, let profile = dockedWindowIsPrivate ? "default" : dockedWindowProfile else {
            return false
        }
        let windows = liveSnapshots.values.filter { Self.isCopy($0, of: profile) }.flatMap(\.windows)
        return windows.filter { $0.incognito == dockedWindowIsPrivate }.count >= max(likeWindows, 1)
    }

    // MARK: - Copies of the extension
    //
    // Each Safari profile where Side Tabs is on runs its own copy of the extension's background page, with
    // its own instance id (#28). A copy stops when Side Tabs is turned off in its profile, when the extension
    // reloads or is reinstalled (a new copy, with a new id, takes over), or when Safari quits. None of these
    // says goodbye, so a copy is judged by what it sends (#31):
    //
    // - Quiet: nothing of any kind from it for `quietAfter`, while it could have spoken (#45, CopySilence):
    //   the Mac asleep, the screen locked and the like don't count, and when they end every copy starts
    //   over. Nor does a pause in heartbeats the app asked for during one of them (#80). One timer looks at
    //   the moment the first live copy could go quiet (`scheduleCopyCheck`). Its windows aren't shown. Its
    //   snapshot stays in `snapshots`, and with it its bookmarks' tabs and cleanup's clocks, because under
    //   heavy load a copy that is running has gone that long without a word. Anything it sends shows its
    //   windows again.
    // - Gone: a newer copy of the same profile has reported (`replace`), or Safari quit
    //   (`safariDidTerminate`). Only then does its snapshot go, through the paths for an instance that's
    //   gone: its clocks are dropped and its bookmarks' tabs wait to be re-linked to the new copy's.
    //
    // Times here are on the Mac's awake clock (`uptime`), which stops while it sleeps.

    /// One copy of the extension's background page.
    private struct Copy {
        /// The copy's profile, as the extension's handler names it (`Snapshot.profile`): a UUID string,
        /// or nil for the default profile.
        var profile: String?
        /// When anything last came from it.
        var lastHeard: TimeInterval
        /// When Safari came to the front while it was silent, if it has since it last spoke: its silence
        /// counts from then. Once per silence, so a copy that has stopped still goes quiet (`safariCameToFront`).
        var extraChance: TimeInterval?
        /// It went quiet with Safari in the background, where Safari can hold its timers back.
        var quietInBackground = false
        /// It's live again on that extra chance, without having spoken.
        var onExtraChance = false
        /// Until when its heartbeats are paused, as its last message said (`heartbeatsPausedFor`, #80). Nil
        /// when they aren't.
        var pausedUntil: TimeInterval?
        /// It has been told to start heartbeating again since it last said it was paused.
        var toldToResume = false
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

    /// How long a copy can go without sending anything, while it could speak, before it counts as quiet and
    /// its windows are hidden. It sends something at least every 10 s, but under heavy load the extension has
    /// run up to 20 s late (#16–#22).
    static let quietAfter = CopySilence.allowance

    /// The copies of the extension that are running now: heard from within `quietAfter`, and not replaced by a
    /// newer copy of their profile. By instance id, as in `snapshots` and `TabKey`. Read-only.
    ///
    /// For telling whether Side Tabs is on in a profile (#33), see `hasLiveCopy(profile:)`. A copy that isn't
    /// live may still have a snapshot in `snapshots` (a quiet copy keeps it), but its windows aren't shown.
    /// Quiet usually means stopped, but it can also be a copy held up by heavy load: it's live again as soon
    /// as it sends anything.
    private(set) var liveInstances: Set<String> = [] {
        didSet {
            if liveInstances != oldValue { refreshShown() }
        }
    }

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

    /// Whether every copy has had its chance to speak since listening started: Side Tabs starting or Safari
    /// launching, and again after a hold that began before they had (CopySilence). Until then, a profile
    /// with no live copy may only have a copy that hasn't spoken yet, so Side Tabs doesn't count as off in
    /// it (#33, #45).
    private(set) var copiesHaveHadTheirChance = false

    /// Reads the wall-clock time, for the sidebar's fade (#44). Only the checks in Tests/ pass anything else.
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// Reads the Mac's awake time, which stops while it sleeps, for telling which copies are quiet (#45).
    /// Only the checks in Tests/ pass anything else.
    @ObservationIgnored var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Reads what's holding Safari's copies back now (HoldWatcher): the Mac asleep, the screen locked and
    /// the like. Read at every check, and whenever `holdsMayHaveChanged` says to. Only the checks in Tests/
    /// pass anything else.
    @ObservationIgnored var currentHolds: () -> Set<CopySilence.Hold> = { [] }
    /// When copies could speak, and since when their silence counts.
    @ObservationIgnored private var silence = CopySilence(listeningSince: ProcessInfo.processInfo.systemUptime)
    /// The copies heard from since Safari started, apart from replaced ones, by instance id.
    @ObservationIgnored private var copies: [String: Copy] = [:]
    /// Copies a newer copy of their profile replaced, and when.
    @ObservationIgnored private var replacedCopies: [String: TimeInterval] = [:]
    /// For a copy that replaced another: the replaced copy's window and tab ids, and the most of them it has
    /// reported so far (see `compareWithReplaced`).
    @ObservationIgnored private var replacedIds: [String: (since: TimeInterval, windows: Set<Int>, tabs: Set<Int>, most: Int)] = [:]
    /// The one timer for looking at the copies (`noteQuietCopies`), and when it's set for, on the awake clock:
    /// the moment the first live copy could go quiet, the copies will all have had their chance, or, during a
    /// hold, they're to be asked to stop heartbeating again. Nil when there's nothing to look at. Read by the
    /// checks in Tests/.
    @ObservationIgnored private var copyCheckTimer: DispatchSourceTimer?
    @ObservationIgnored private(set) var nextCopyCheck: TimeInterval?

    /// Notes a message from a copy of the extension.
    ///
    /// A copy not heard from before replaces any other copy of its profile: when the extension reloads or is
    /// reinstalled, Safari stops the old copy and starts a new one. Messages from a replaced copy after that
    /// were already on their way, and are ignored. If one keeps sending for `quietAfter`, though, it's running
    /// after all (a second Safari, say); it's taken back, without replacing anything in turn.
    private func hear(from object: [String: Any]) -> Sender {
        guard let instance = object["instance"] as? String else { return .live }
        let now = uptime()
        // The moment this copy could go quiet has moved.
        defer {
            notePause(of: instance, from: object, at: now)
            scheduleCopyCheck()
        }
        let profile = object["profile"] as? String
        if let replacedAt = replacedCopies[instance] {
            let since = now - replacedAt
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
            return .live
        }
        let silence = now - copy.lastHeard
        if copy.onExtraChance {
            log.notice("extension copy \(instance.prefix(8), privacy: .public) is sending again, \(Int(now - (copy.extraChance ?? now))) s after Safari came to the front")
        }
        copy.lastHeard = now
        copy.extraChance = nil
        copy.quietInBackground = false
        copy.onExtraChance = false
        if let profile {
            copy.profile = profile
        }
        copies[instance] = copy
        guard !liveInstances.contains(instance) else { return .live }
        liveInstances.insert(instance)
        log.notice("extension copy \(instance.prefix(8), privacy: .public) is sending again after \(Int(silence)) s; showing its windows")
        return .backFromQuiet
    }

    /// Takes what a message from a copy says about a pause in its heartbeats (#80). A copy that's still paused
    /// with no hold on missed the word that the hold ended, and is told again, once per pause.
    private func notePause(of instance: String, from object: [String: Any], at now: TimeInterval) {
        guard var copy = copies[instance] else { return }
        let milliseconds = (object["heartbeatsPausedFor"] as? NSNumber)?.doubleValue ?? 0
        guard milliseconds > 0 else {
            copy.pausedUntil = nil
            copy.toldToResume = false
            copies[instance] = copy
            return
        }
        copy.pausedUntil = now + min(milliseconds / 1000, CopySilence.pauseLength)
        if silence.holds.isEmpty, !copy.toldToResume {
            copy.toldToResume = true
            log.notice("extension copy \(instance.prefix(8), privacy: .public) still has heartbeats paused, \(Int(milliseconds / 1000)) s more; telling it to start again")
            send(["action": "resumeHeartbeats"], to: instance)
        }
        copies[instance] = copy
    }

    /// `old` has stopped for good, because `new`, a newer copy of the same profile, has reported. Its snapshot
    /// goes, and with it cleanup's clocks for its tabs (TabCleanup.noteViewing). Its bookmarks' tabs and its
    /// tabs' custom names go to `new`'s tabs on the same pages when `new` sends its first snapshot
    /// (BookmarkTabs.update and orphanNamesOfDeadInstances, as after Safari restarts).
    private func replace(_ old: String, by new: String, at now: TimeInterval) {
        copies[old] = nil
        replacedCopies[old] = now
        if liveInstances.contains(old) {
            liveInstances.remove(old)
        }
        lastActivation[old] = nil
        appliedSeq[old] = nil
        copyStates[old] = nil
        fullSnapshotAskedAt[old] = nil
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
        reportedSnapshots[old] = nil
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
        guard uptime() - old.since < Self.quietAfter else {
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

    /// Hides the windows of copies that have sent nothing for `quietAfter` while they could have spoken.
    /// Runs when the first live copy could have gone quiet, when every copy will have had its chance to speak,
    /// and during a hold when it's time to ask the copies to stop heartbeating, if any are known
    /// (`scheduleCopyCheck`). Reads the holds afresh first, so one that began or ended without a notification
    /// is noticed.
    func noteQuietCopies() {
        noteHolds()
        let now = uptime()
        defer { scheduleCopyCheck() }
        for (instance, copy) in copies where liveInstances.contains(instance) {
            let counted = silence.silence(lastHeard: copy.lastHeard, extraChance: copy.extraChance, pausedUntil: copy.pausedUntil, at: now)
            guard counted >= Self.quietAfter else { continue }
            liveInstances.remove(instance)
            copies[instance]?.quietInBackground = !safariIsFrontmost
            copies[instance]?.onExtraChance = false
            let heard = Int(now - copy.lastHeard)
            let before = heard > Int(counted) + 1 ? " (\(heard) s since it last spoke)" : ""
            log.notice("extension copy \(instance.prefix(8), privacy: .public) has sent nothing for \(Int(counted)) s\(before, privacy: .public)\(self.safariIsFrontmost ? "" : ", Safari in the background", privacy: .public); hiding its \(self.snapshots[instance]?.windows.count ?? 0) windows until it does")
        }
        noteChance(at: now)
        if !copies.isEmpty, let ask = silence.nextPauseAsk, now >= ask {
            askCopiesToPause(at: now)
        }
    }

    /// Something that can hold Safari's copies back has changed (HoldWatcher): the Mac slept or woke, the
    /// screen locked or unlocked, Safari was hidden or shown, and so on. Takes `currentHolds` at once, so a
    /// wake starts every copy over before any check can find it silent.
    func holdsMayHaveChanged() {
        noteHolds()
        noteChance(at: uptime())
        scheduleCopyCheck()
    }

    /// Safari has launched: its copies are all new, and none has spoken yet. Until they've had the time to,
    /// Side Tabs doesn't count as off in any profile (`copiesHaveHadTheirChance`).
    func safariDidLaunch() {
        let now = uptime()
        silence.startListening(at: now)
        log.notice("Safari launched; no profile counts as off for \(Int(Self.quietAfter)) s while its extension copies start")
        noteChance(at: now)
        scheduleCopyCheck()
    }

    /// Takes what's holding the copies back now. When the last hold ends, every copy starts over with a whole
    /// `quietAfter` to speak, and is asked for a snapshot at once, so the sidebar is current within a moment
    /// of waking.
    private func noteHolds() {
        let held = currentHolds()
        let before = silence.holds
        guard held != before else { return }
        let paused = silence.pauseAskedDuringHold
        let now = uptime()
        if silence.update(holds: held, at: now) {
            let missed = silence.missedResumeUntil.map { ", or until \(Int($0 - now + Self.quietAfter)) s from now if it isn't heard from first, since it may have missed this" } ?? ""
            log.notice("the extension's copies are no longer held back by \(CopySilence.describe(before), privacy: .public): each has \(Int(Self.quietAfter)) s to speak before it counts as quiet\(missed, privacy: .public); asking each for a snapshot\(paused ? " and to heartbeat again" : "", privacy: .public)")
            if paused {
                // A copy that misses this is silent until its pause runs out, which `silence` allows for.
                sendCommand?(["action": "resumeHeartbeats"]) {}
            }
            requestSnapshot()
        } else if before.isEmpty {
            log.notice("the extension's copies are held back by \(CopySilence.describe(held), privacy: .public); their silence doesn't count until that ends")
        } else {
            log.notice("the extension's copies are held back by \(CopySilence.describe(held), privacy: .public)")
        }
    }

    /// Updates `copiesHaveHadTheirChance`. The copy check looks again when they will have
    /// (`scheduleCopyCheck`).
    private func noteChance(at now: TimeInterval) {
        let had = silence.copiesHaveHadTheirChance(at: now)
        if copiesHaveHadTheirChance != had {
            copiesHaveHadTheirChance = had
            if had {
                log.notice("every extension copy has had \(Int(Self.quietAfter)) s to speak; Side Tabs can count as off in a profile again")
            }
        }
    }

    /// A hold has lasted `CopySilence.pauseAfter`, or `CopySilence.pauseRenewal` since the last ask: asks every
    /// copy to stop heartbeating for `CopySilence.pauseLength`, while their silence doesn't count anyway (#80).
    /// The ask says until when on the wall clock and for how long, and a copy stops at whichever comes first,
    /// so a copy never stays silent past `pauseLength` after the ask (the Mac sleeping in between only shortens
    /// it), nor long past it if the command was delivered late. A copy that misses an ask goes on heartbeating.
    /// Only while copies are known: with none (Safari not running, say), nothing is asked, and no timer runs for
    /// it.
    private func askCopiesToPause(at now: TimeInterval) {
        if !silence.pauseAskedDuringHold {
            log.notice("the extension's copies have been held back by \(CopySilence.describe(self.silence.holds), privacy: .public) for \(Int(CopySilence.pauseAfter)) s; asking them to stop heartbeating until that ends")
        }
        silence.notePauseAsked(at: now)
        let milliseconds = Int(CopySilence.pauseLength * 1000)
        let until = Int(clock().timeIntervalSince1970 * 1000) + milliseconds
        sendCommand?(["action": "pauseHeartbeats", "until": until, "ms": milliseconds]) {}
    }

    /// Safari came to the front. In the background, Safari can hold its extensions' timers back (its windows
    /// covered, say), so each copy that's silent now gets one more chance per silence: its silence counts from
    /// now. A copy that went quiet with Safari in the background shows its windows again meanwhile, and is
    /// asked for a snapshot. One that went quiet with Safari in front had its chance, and stays quiet; so does
    /// one that has had its extra chance and still not spoken, which is how a copy that has stopped goes quiet
    /// however often Safari comes to the front.
    private func safariCameToFront() {
        let now = uptime()
        for (instance, copy) in copies where copy.extraChance == nil {
            if liveInstances.contains(instance) {
                copies[instance]?.extraChance = now
            } else if copy.quietInBackground {
                copies[instance]?.extraChance = now
                copies[instance]?.onExtraChance = true
                liveInstances.insert(instance)
                log.notice("extension copy \(instance.prefix(8), privacy: .public) went quiet with Safari in the background; Safari is in front now, so its \(self.snapshots[instance]?.windows.count ?? 0) windows show again while it has \(Int(Self.quietAfter)) s more to speak")
                send(["action": "snapshot"], to: instance)
            }
        }
        scheduleCopyCheck()
    }

    /// When the copies next need looking at (see `nextCopyCheck`), on the awake clock, or nil for never.
    private func nextCopyCheckTime(at now: TimeInterval) -> TimeInterval? {
        var times: [TimeInterval] = []
        for (instance, copy) in copies where liveInstances.contains(instance) {
            if let quiet = silence.quietAt(lastHeard: copy.lastHeard, extraChance: copy.extraChance, pausedUntil: copy.pausedUntil) {
                times.append(quiet)
            }
        }
        if !copiesHaveHadTheirChance, let wait = silence.timeUntilCopiesHaveHadTheirChance(at: now) {
            times.append(now + wait)
        }
        // During a hold, only to ask copies to pause: with none known there's nothing to ask, and the hold's end
        // comes from HoldWatcher's notifications.
        if !copies.isEmpty, let ask = silence.nextPauseAsk {
            times.append(ask)
        }
        return times.min()
    }

    /// Sets the copy check's one timer for when the copies next need looking at, or stops it when they don't
    /// (#80). Called whenever that moment may have moved: a message from a copy, a hold beginning or ending,
    /// Safari launching, quitting or coming to the front, and each check. The timer has leeway, so macOS can
    /// line it up with other wakeups; it's never early, and a check that finds it a moment early sets it again.
    private func scheduleCopyCheck() {
        let now = uptime()
        guard let next = nextCopyCheckTime(at: now) else {
            copyCheckTimer?.cancel()
            copyCheckTimer = nil
            nextCopyCheck = nil
            return
        }
        guard next != nextCopyCheck || copyCheckTimer == nil else { return }
        nextCopyCheck = next
        // A moment past it, so the check doesn't find the copy a hair short of quiet.
        let delay = max(0, next - now) + 0.05
        let leeway = DispatchTimeInterval.milliseconds(Int(min(5, max(0.1, delay / 10)) * 1000))
        if let copyCheckTimer {
            copyCheckTimer.schedule(deadline: .now() + delay, repeating: .never, leeway: leeway)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.nextCopyCheck = nil
                self.noteQuietCopies()
            }
        }
        timer.schedule(deadline: .now() + delay, repeating: .never, leeway: leeway)
        copyCheckTimer = timer
        timer.resume()
    }

    /// A profile for the log: its UUID's first characters, never its name.
    private static func describe(_ profile: String?) -> String {
        profile.map { "profile \($0.prefix(8))" } ?? "default profile"
    }

    // MARK: - Which copy of the extension Safari runs (#67)

    /// Safari runs another copy of Side Tabs' extension, and registering this app's in its place didn't make it
    /// switch: where that copy is, for the notice at the top of the sidebar. Nil otherwise, and again as soon as
    /// this app's extension talks to it.
    private(set) var otherExtensionCopy: ExtensionCopyCheck.OtherCopy?
    /// Which copy Safari runs. Only the checks in Tests/ give it another app path.
    @ObservationIgnored var extensionCopies = ExtensionCopyCheck(appPath: Bundle.main.bundlePath)
    /// Registers this app's extension with macOS in place of other copies' (ExtensionRegistration), given the
    /// copy Safari runs when that's known. `done` runs on the main thread, with the other copies it found.
    @ObservationIgnored var repairExtensionRegistration: ((_ otherCopy: String?, _ done: @escaping (_ otherCopies: [String]) -> Void) -> Void)?
    @ObservationIgnored private let bridgeLog = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "bridge")

    /// Notes where the handler that passed on a message is (`extensionPath`; nil from an extension older than
    /// this app's).
    private func noteExtensionPath(_ path: String?) {
        let before = extensionCopies.lastSender
        let repair = extensionCopies.heard(extensionPath: path, at: uptime())
        if extensionCopies.lastSender != before {
            bridgeLog.notice("messages come from \(Self.describe(self.extensionCopies.lastSender), privacy: .public)")
        }
        if repair {
            startRepair(because: "Safari runs another copy's extension")
        }
        showOtherCopyIfNeeded()
    }

    /// A command failed with `SFErrorNoExtensionFound` (ExtensionBridge): Safari runs no extension of this app's.
    func commandFoundNoExtension() {
        if extensionCopies.commandFoundNoExtension(at: uptime()) {
            startRepair(because: "a command found no extension of this app's in Safari")
        }
        showOtherCopyIfNeeded()
    }

    private func startRepair(because reason: String) {
        guard let repairExtensionRegistration else { return }
        extensionCopies.repairStarted()
        var otherCopy: String?
        if case .other(let path) = extensionCopies.lastSender {
            otherCopy = path
        }
        bridgeLog.notice("\(reason, privacy: .public): registering this app's extension in place of other copies'")
        repairExtensionRegistration(otherCopy) { [weak self] others in
            guard let self else { return }
            extensionCopies.repairFinished(otherCopies: others, at: uptime())
        }
    }

    private func showOtherCopyIfNeeded() {
        let notice = extensionCopies.notice
        guard notice != otherExtensionCopy else { return }
        otherExtensionCopy = notice
        if let notice {
            bridgeLog.notice("Safari still runs another copy's extension, \(ExtensionCopyCheck.describe(notice.path), privacy: .public); the sidebar says where it is")
        } else {
            bridgeLog.notice("this app's extension talks to it now; the sidebar no longer shows the other copy")
        }
    }

    /// Where a message came from, for the log.
    private static func describe(_ sender: ExtensionCopyCheck.Sender?) -> String {
        switch sender {
        case .own: "this app's extension"
        case .other(let path): "another copy's extension, in \(ExtensionCopyCheck.describe(path))"
        case .unknown: "an extension that doesn't say where it is, older than this app"
        case nil: "no extension yet"
        }
    }

    // MARK: - Window selection

    var hasData: Bool { !snapshots.isEmpty }

    /// How long the extension can be silent, in awake time, before it counts as not connected. Well above the
    /// heartbeat's interval, so a missed heartbeat or two doesn't flip it.
    static let connectedFor: TimeInterval = 60

    /// A message from the extension: it's connected. `isConnected` is written only when it changes, and one
    /// check is pending at a time, for when the silence would reach `connectedFor` (#83).
    private func noteMessageArrived() {
        lastMessageAt = uptime()
        if !isConnected {
            isConnected = true
            bridgeLog.notice("the extension is connected")
        }
        if connectionCheck == nil {
            scheduleConnectionCheck(after: Self.connectedFor)
        }
    }

    /// Whether the extension has been silent for `connectedFor` seconds of awake time; if not, looks again when it
    /// would have been. Sleep doesn't count, as the awake clock stops. The checks in Tests/ call this directly.
    func checkConnection() {
        connectionCheck?.cancel()
        connectionCheck = nil
        guard isConnected else { return }
        let silent = lastMessageAt.map { uptime() - $0 } ?? .infinity
        if silent >= Self.connectedFor {
            isConnected = false
            bridgeLog.notice("the extension has been silent for \(Int(silent)) s; it no longer counts as connected")
        } else {
            scheduleConnectionCheck(after: Self.connectedFor - silent)
        }
    }

    private func scheduleConnectionCheck(after wait: TimeInterval) {
        connectionCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkConnection() }
        connectionCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.05, execute: work)
    }

    /// True when Safari reports tabs but no URLs or titles, which means the extension
    /// hasn't been allowed on websites yet. Kept (see `refreshShown`).
    private(set) var lacksWebsiteAccess = false

    private func computeLacksWebsiteAccess() -> Bool {
        var anyTab = false
        for snapshot in liveSnapshots.values {
            for window in snapshot.windows {
                for tab in window.tabs {
                    if tab.url != nil || tab.title != nil { return false }
                    anyTab = true
                }
            }
        }
        return anyTab
    }

    /// `currentWindow`, `shownContent`, `displayedContent` and `lacksWebsiteAccess` are kept rather than worked out
    /// at every read: views read them in every body run, and each sorted the snapshots or went through every tab
    /// (#81). This works them out again whenever something they depend on changes (each of those calls it), and sets
    /// each only when it differs, so views aren't told of a change that isn't one.
    private func refreshShown() {
        let window = computeCurrentWindow()
        if window != currentWindow {
            currentWindow = window
        }
        let shown = computeShownContent()
        if shown != shownContent {
            shownContent = shown
        }
        let displayed = sidebarFade.showsOldContents ? fadingOutContent : shown
        if displayed != displayedContent {
            displayedContent = displayed
        }
        let lacks = computeLacksWebsiteAccess()
        if lacks != lacksWebsiteAccess {
            lacksWebsiteAccess = lacks
        }
    }

    /// The Safari window the sidebar shows: the one most recently focused, cross-checked
    /// against the title of the window the panel is docked to. Only live copies' windows count.
    /// Kept (see `refreshShown`).
    private(set) var currentWindow: WindowSelection?

    private func computeCurrentWindow() -> WindowSelection? {
        // Another profile's window is never shown for one its own copy can't see (#41).
        if unseenDockedWindow != nil { return nil }
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

    /// The docked window, when the extension copy it belongs to can't see it (#41).
    struct UnseenWindow: Equatable {
        /// Its profile; nil for a private window.
        let profile: ProfileKey?
        /// The copy that should list it, but doesn't.
        let instance: String
    }

    /// The docked window, while its profile's live copy lists no window that matches it. After the extension
    /// reloads (every update), Safari keeps a non-default profile's windows that were already open from that
    /// profile's copy (#41, and #28 before it). The sidebar then lists the window's tabs from its tab bar
    /// rather than another window's (UnseenWindowTabs). Nil while its profile isn't known, while it has no
    /// live copy (Side Tabs is off there, which SafariProfiles handles), and when the copy can see it.
    var unseenDockedWindow: UnseenWindow? {
        guard dockedWindowSettled, let copy = Self.copyMissingDockedWindow(
            profile: dockedWindowProfile, isPrivate: dockedWindowIsPrivate, title: dockedWindowTitle,
            likeWindows: dockedLikeWindowCount, among: Array(liveSnapshots.values)
        ) else { return nil }
        return UnseenWindow(profile: dockedWindowIsPrivate ? nil : dockedWindowProfile.map(ProfileKey.init(rawValue:)), instance: copy.instance)
    }

    /// The live copy that should list the docked window but doesn't, if there is one: the copy of `profile`
    /// (the default profile's for a private window) lists none of its windows (private ones for a private
    /// window), or none whose tabs fit `title`, the docked window's, while Safari has more windows like it
    /// (`likeWindows`) than the copy lists. One that lists as many can see them all and is only behind on a
    /// title (a page that has just loaded). Any tab counts, not only the active one, for the same reason.
    static func copyMissingDockedWindow(profile: String?, isPrivate: Bool, title: String?, likeWindows: Int?, among copies: [Snapshot]) -> Snapshot? {
        guard let profile = isPrivate ? "default" : profile else { return nil }
        let own = copies.filter { isCopy($0, of: profile) }.sorted { $0.focusChangedAt > $1.focusChangedAt }
        guard let newest = own.first else { return nil }
        let windows = own.flatMap(\.windows).filter { $0.incognito == isPrivate }
        if windows.isEmpty {
            return newest
        }
        guard let title, !title.isEmpty else { return nil }
        let fits = windows.contains { window in
            window.tabs.contains { tab in
                guard let page = tab.title, !page.isEmpty else { return false }
                return isPrivate ? title.contains(page) : page == title || title.hasSuffix(" — " + page)
            }
        }
        if fits {
            return nil
        }
        if let likeWindows, windows.count >= likeWindows {
            return nil
        }
        return newest
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

    /// How a rename ended, for the log.
    enum RenameEnd: String {
        case returnKey = "Return"
        case escape = "Escape"
        case clickOutside = "a click outside the field"
        case resignKey = "the sidebar resigning key"
        case lostFocus = "the field losing focus"
        case anotherRename = "another rename starting"
        case gone = "what was renamed going away"
    }

    /// What's in the rename field now, and where the field is in the sidebar's window (top left origin, as SwiftUI's
    /// `.global`). RenameField keeps them, so a click outside the field can end the rename keeping what's typed.
    @ObservationIgnored private(set) var renameDraft: String?
    @ObservationIgnored private(set) var renameFieldFrame: CGRect?

    /// For the log: what's being renamed, never its name.
    private static func describe(_ target: RenameTarget) -> String {
        switch target {
        case .tab: "a tab"
        case .bookmark: "a favorite or pinned item"
        case .folder: "a folder"
        }
    }

    func beginRename(_ target: RenameTarget) {
        if renaming != nil {
            if let renameDraft {
                commitRename(renameDraft, how: .anotherRename)
            } else {
                cancelRename(how: .anotherRename)
            }
        }
        renaming = target
        renameDraft = nil
        renameFieldFrame = nil
        log.notice("renaming \(Self.describe(target), privacy: .public) began")
        onRenameStateChanged?(true)
    }

    /// The rename field for `target` changed: what's typed in it, and where it is.
    func renameFieldChanged(_ target: RenameTarget, text: String? = nil, frame: CGRect? = nil) {
        guard renaming == target else { return }
        if let text { renameDraft = text }
        if let frame { renameFieldFrame = frame }
    }

    /// A mouse-down while something is being renamed (#76 hand test): `point` is where it landed in the sidebar's window
    /// (top left origin), nil for anywhere else (Safari's window, another app, another of Side Tabs' windows). One
    /// outside the field ends the rename and keeps what's in the field. The click then goes on to do what it does.
    /// Says whether it ended a rename.
    @discardableResult
    func renameClick(at point: CGPoint?) -> Bool {
        guard renaming != nil else { return false }
        if let point, let frame = renameFieldFrame, frame.contains(point) { return false }
        if let renameDraft {
            commitRename(renameDraft, how: .clickOutside)
        } else {
            cancelRename(how: .clickOutside)
        }
        return true
    }

    /// Ends the rename, keeping `text`. With `target`, only if that's still what's being renamed: a field that's going
    /// away can report losing focus after another rename began.
    func commitRename(_ text: String, how: RenameEnd = .returnKey, of target: RenameTarget? = nil) {
        guard let renamed = renaming, target == nil || target == renamed else { return }
        let target = renamed
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
        case .folder(let id):
            if !name.isEmpty {
                bookmarkLists.updateFolder(id) { $0.name = name }
            }
        }
        renaming = nil
        renameDraft = nil
        renameFieldFrame = nil
        log.notice("renaming \(Self.describe(target), privacy: .public) ended by \(how.rawValue, privacy: .public)")
        scheduleSave()
        onRenameStateChanged?(false)
    }

    /// Ends the rename, keeping the old name. With `target`, only if that's still what's being renamed.
    func cancelRename(how: RenameEnd = .escape, of target: RenameTarget? = nil) {
        guard let renamed = renaming, target == nil || target == renamed else { return }
        renaming = nil
        renameDraft = nil
        renameFieldFrame = nil
        log.notice("renaming \(Self.describe(renamed), privacy: .public) ended by \(how.rawValue, privacy: .public), keeping the old name")
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

    /// The active tab of the window whose tabs the sidebar shows (`displayedContent`): during a switch, the
    /// guessed window's once the old contents have faded out.
    var activeTab: (tab: BrowserTab, instance: String)? {
        guard case .window(let selection)? = displayedContent, let tab = selection.window.tabs.first(where: \.active) else { return nil }
        return (tab, selection.instance)
    }

    func reloadActiveTab() {
        guard let active = activeTab else { return }
        reload(active.tab, instance: active.instance)
    }

    /// Opens Safari's own address bar, which has its full autocomplete. During a switch, Safari's key window is
    /// still the old profile's, while the bar shows the new one's page: the click waits until Safari reports the
    /// switch's window (#48).
    func openAddressBar() {
        guard switchPreview == nil else {
            heldCommands.append(("a click on the address bar", { [weak self] in self?.onOpenAddressBar?() }))
            log.notice("holding a click on the address bar until Safari reports the switch's window")
            return
        }
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
            sendActivation(of: tab, instance: instance, request: request)
        case .press(let target):
            // The press is made off the main thread; the extension's command is the fallback.
            guard let pressTab else {
                log.notice("tab switch via push: no way to press the tab bar")
                sendActivation(of: tab, instance: instance, request: request)
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
            // Only the clicked tab's copy can say (#47).
            self.requestSnapshot(of: request.key.instance)
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
            sendActivation(of: tab, instance: instance, request: request)
        }
    }

    /// If the command can't reach the extension, the click didn't happen as far as Safari knows: it isn't waited
    /// for, it holds no window on its tab, and the highlight goes back to where the copy last said it was.
    private func sendActivation(of tab: BrowserTab, instance: String, request: PendingActivation) {
        let window = WindowID(instance: instance, windowId: tab.windowId)
        send(["action": "activate", "tabId": tab.id], to: instance, window: tab.windowId) { [weak self] in
            guard let self else { return }
            switchAsks.removeAll { $0.id == request.id }
            if pendingActivation?.id == request.id {
                pendingActivation = nil
            }
            if anchors[window]?.clickId == request.id {
                anchors[window] = nil
            }
        }
    }

    /// Closes tabs of one window. The rows go at once; if the command can't reach the extension, they come back
    /// (#67), and `ifFailed` runs.
    func close(_ tabs: [BrowserTab], instance: String, ifFailed: (() -> Void)? = nil) {
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
        var unlinked = BookmarkTabs.Unlinked()
        changeBookmarkTabs { unlinked = $0.unlink(ids.map { TabKey(instance: instance, tabId: $0) }) }
        send(["action": "close", "tabIds": Array(ids)], to: instance, window: windowId) { [weak self] in
            guard let self else { return }
            // The tabs are still open, and still their bookmarks'.
            let bookmarks = Set(bookmarkLists.all.map(\.id))
            changeBookmarkTabs { $0.relink(unlinked, bookmarks: bookmarks) }
            ifFailed?()
        }
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

    /// Opens a new tab in the window the sidebar shows (#48). `ifFailed` runs if the command can't reach the extension.
    func newTab(url: String? = nil, ifFailed: (() -> Void)? = nil) {
        if heldForSwitch("a new tab", { [weak self] in self?.newTab(url: url, ifFailed: ifFailed) }) { return }
        guard let selection = shownWindow else {
            openInSafari(url ?? "")
            return
        }
        var command: [String: Any] = ["action": "create", "windowId": selection.window.id]
        if let url {
            command["url"] = url
        }
        send(command, to: selection.instance, undo: ifFailed)
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
        send(["action": "mute", "tabId": tab.id, "muted": muted], to: instance, window: tab.windowId)
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
        send(["action": "move", "tabId": tab.id, "index": destination], to: instance, window: tab.windowId)
    }

    func window(instance: String, id: Int) -> BrowserWindow? {
        snapshots[instance]?.windows.first { $0.id == id }
    }

    private func mutateWindow(instance: String, windowId: Int, _ body: (inout BrowserWindow) -> Void) {
        guard var snapshot = snapshots[instance],
              let index = snapshot.windows.firstIndex(where: { $0.id == windowId }) else { return }
        body(&snapshot.windows[index])
        // A change that changes nothing (the highlight already where it's moved to) isn't one (#81).
        guard snapshot.windows[index] != snapshots[instance]?.windows[index] else { return }
        snapshots[instance] = snapshot
    }

    /// Sends a command to one copy of the extension. If Safari can't take it (#67), `undo` puts back what the
    /// command changed besides the window, and the window it was for, `windowId`, goes back to how its copy last
    /// reported it: the sidebar never shows a tab closed, moved, muted or switched to when it isn't.
    func send(_ command: [String: Any], to instance: String, window windowId: Int? = nil, undo: (() -> Void)? = nil) {
        var command = command
        command["instance"] = instance
        let action = command["action"] as? String ?? "?"
        sendCommand?(command) { [weak self] in
            self?.commandFailed(action, instance: instance, windowId: windowId, undo: undo)
        }
    }

    private func commandFailed(_ action: String, instance: String, windowId: Int?, undo: (() -> Void)?) {
        undo?()
        guard let windowId else {
            log.notice("the extension didn't get “\(action, privacy: .public)”")
            return
        }
        let wentBack = putBack(windowId: windowId, of: instance)
        log.notice("the extension didn't get “\(action, privacy: .public)”; \(wentBack ? "its window shows what its copy last reported" : "its copy hasn't reported its window", privacy: .public)")
    }

    /// Puts a window back to how its copy last reported it (`reportedSnapshots`), except that a recent click
    /// that worked keeps the highlight on its tab, as against a snapshot (`holdAnchoredTabs`). Says whether there
    /// was a report to go back to.
    private func putBack(windowId: Int, of instance: String) -> Bool {
        guard var reported = reportedSnapshots[instance]?.windows.first(where: { $0.id == windowId }) else { return false }
        if let anchor = recentAnchor(of: WindowID(instance: instance, windowId: windowId)),
           reported.tabs.contains(where: { $0.id == anchor.tabId }) {
            for index in reported.tabs.indices {
                reported.tabs[index].active = reported.tabs[index].id == anchor.tabId
            }
        }
        mutateWindow(instance: instance, windowId: windowId) { window in
            window = reported
        }
        return true
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

    /// The profile of the window the sidebar shows (`currentWindow`), whose Favorites and Pinned list it
    /// shows. Nil while that's a private window, and while no window is shown.
    var currentWindowProfile: ProfileKey? {
        // A window its copy can't see shows its own profile's lists too (#41).
        currentWindow.flatMap { profile(of: $0.window, instance: $0.instance) } ?? unseenDockedWindow?.profile
    }

    /// The Favorites the sidebar shows: those of the current window's profile (#38), or of the profile a
    /// switch is bringing forward (#44). Nil in a private window, which shows Tabs only.
    var currentFavoritesList: BookmarkList? {
        shownProfile.map(BookmarkList.favorites)
    }

    /// The Pinned list the sidebar shows: that of the current window's profile, or of the profile a switch
    /// is bringing forward. Nil in a private window, which shows Tabs only.
    var currentPinnedList: BookmarkList? {
        shownProfile.map(BookmarkList.pinned)
    }

    // MARK: - A switch's window on its way in (#44)

    /// The window a page of the sidebar shows, for its rows' state: during a swipe (#72), the pages sliding in and out
    /// show other windows than the one commands act on.
    struct SidebarPageWindow: Equatable, Hashable {
        let instance: String
        let windowId: Int

        init(instance: String, windowId: Int) {
            self.instance = instance
            self.windowId = windowId
        }

        /// The window `content` shows, if it shows one.
        init?(_ content: ShownContent?) {
            guard case .window(let selection)? = content else { return nil }
            self.init(instance: selection.instance, windowId: selection.window.id)
        }
    }

    /// What a page of the sidebar shows (the one in place, or one sliding in or out during a swipe, #72).
    enum ShownContent: Equatable {
        case window(WindowSelection)
        /// A window its profile's copy can't see (#41): its profile's lists (none for a private window), and its
        /// tabs from the tab bar.
        case unseen(profile: ProfileKey?)
        /// A switch's profile whose window isn't known yet: its lists, and a placeholder for Tabs. No lists for a
        /// profile whose copy Side Tabs hasn't learned yet (a swipe's page, #72).
        case placeholder(ProfileKey?)
        /// Side Tabs is off in this profile (`SafariProfiles`' id): the row to turn it on, in place of the sections
        /// (#33), which would list another window's tabs.
        case turnOn(UUID)
    }

    /// The window whose tabs the sidebar shows: a switch's guessed window while there is one, otherwise
    /// `currentWindow`. Commands from the sidebar act on this window, never on one it doesn't show (#48): during a
    /// switch, Safari's front window is still the old profile's.
    var shownWindow: WindowSelection? {
        guard let preview = switchPreview else { return currentWindow }
        guard case .window(let selection) = content(for: preview.guess, profile: preview.profile, profileID: preview.profileID) else { return nil }
        return selection
    }

    /// What a guess shows for a profile: a swipe's incoming page (#72), and a switch's preview.
    func content(for guess: SwitchGuess, profile: ProfileKey?, profileID: UUID?) -> ShownContent {
        switch guess {
        case .window(let instance, let windowId):
            guard let window = liveSnapshots[instance]?.windows.first(where: { $0.id == windowId }) else { return .placeholder(profile) }
            return .window(WindowSelection(instance: instance, window: window))
        case .unseen: return .unseen(profile: profile)
        case .placeholder: return .placeholder(profile)
        case .turnOn: return profileID.map(ShownContent.turnOn) ?? .placeholder(profile)
        }
    }

    /// What the sidebar's sections show, or nil for none. Kept (see `refreshShown`).
    private(set) var shownContent: ShownContent?

    private func computeShownContent() -> ShownContent? {
        if let preview = switchPreview {
            return content(for: preview.guess, profile: preview.profile, profileID: preview.profileID)
        }
        return ownContent
    }

    /// What the sidebar shows without a preview: the row to turn Side Tabs on where it's off, else the window Safari
    /// has in front.
    private var ownContent: ShownContent? {
        if let id = profileToTurnOn {
            return .turnOn(id)
        }
        if let window = currentWindow {
            return .window(window)
        }
        return unseenDockedWindow.map { .unseen(profile: $0.profile) }
    }

    /// What the sections have on screen: while the old contents fade out, those; then `shownContent`. Kept (see
    /// `refreshShown`).
    private(set) var displayedContent: ShownContent?

    /// The profile whose Favorites and Pinned the sidebar shows.
    var shownProfile: ProfileKey? {
        if let preview = switchPreview { return preview.profile }
        return currentWindowProfile
    }

    /// What the sidebar would show without a preview, in a guess's terms.
    private var reportedContent: SwitchGuess? {
        if profileToTurnOn != nil {
            return .turnOn
        }
        if let window = currentWindow {
            return .window(instance: window.instance, windowId: window.window.id)
        }
        return unseenDockedWindow != nil ? .unseen : nil
    }

    /// A switch's window is coming back from the Dock, and should land at `arrivesAt`: the sidebar fades over to
    /// `guess` for `profile`, the old contents fully out and then the new in, ending as the window lands.
    /// Replaces an older switch's preview: while the old contents are still fading out, the newest guess comes
    /// in once they're out. `profileID`: the profile's id in SafariProfiles, which confirms the preview by it.
    func beginSwitchPreview(id: Int, profile: ProfileKey, profileID: UUID? = nil, guess: SwitchGuess, arrivesAt: Date) {
        let onScreen = displayedContent
        dropHeldCommands(because: "a newer switch began")
        switchPreview = SwitchPreview(id: id, profile: profile, profileID: profileID, guess: guess)
        var fade = sidebarFade
        let begun = fade.begin(arrivesAt: arrivesAt, now: clock())
        if begun.keepsOnScreen {
            fadingOutContent = onScreen
        }
        sidebarFade = fade
        scheduleFade(begun.timers)
        let landsIn = Int(arrivesAt.timeIntervalSince(clock()) * 1000)
        log.notice("the sidebar shows \(Self.describe(profile), privacy: .public) at the switch: \(Self.describe(guess), privacy: .public); fading out, then in, for the window to land in \(landsIn) ms")
        endPreviewAfterLifetime(id)
    }

    /// A swipe has brought `page` in with the fingers (#72): the sidebar keeps showing it until Safari reports the
    /// switch's window, with no fade, since the page is already there. Replaces any older preview, and stops a fade
    /// that was still going: the page slid in over it.
    func beginSwipePreview(id: Int, page: SwipePage) {
        dropHeldCommands(because: "a newer switch began")
        switchPreview = SwitchPreview(id: id, profile: page.profile, profileID: page.profileID, guess: page.guess, swiped: true)
        if !sidebarFade.isOver {
            var fade = sidebarFade
            fade.cancel()
            sidebarFade = fade
        }
        fadingOutContent = nil
        log.notice("the sidebar shows \(Self.describe(page.profile), privacy: .public) after a swipe: \(Self.describe(page.guess), privacy: .public)")
        endPreviewAfterLifetime(id)
    }

    private func endPreviewAfterLifetime(_ id: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + SwitchPreviewRules.lifetime) { [weak self] in
            guard let self, self.switchPreview?.id == id else { return }
            self.endSwitchPreview(because: "Safari didn't report the switch's window in time")
        }
    }

    /// Sets the fade's timers; each takes its step when it fires, and sets the next ones.
    private func scheduleFade(_ timers: [SidebarFade.Timer]) {
        for timer in timers {
            DispatchQueue.main.asyncAfter(deadline: .now() + timer.after) { [weak self] in
                guard let self else { return }
                var fade = self.sidebarFade
                let next = fade.fire(timer, now: self.clock())
                if fade != self.sidebarFade {
                    if timer.kind == .watchdog {
                        self.log.notice("the sidebar's fade was still going \(Int(SidebarFade.grace * 1000)) ms after its window should have landed; ended it")
                    }
                    self.sidebarFade = fade
                }
                if !fade.showsOldContents, self.fadingOutContent != nil {
                    self.fadingOutContent = nil
                }
                self.scheduleFade(next)
            }
        }
    }

    /// After a swipe, the page is the one swiped to; when what the sidebar shows changes from it anyway (a different
    /// window arrived, or the switch didn't work), a short fade, out and back in (#72). `onScreen`: what was on
    /// screen before the change.
    private func fadeAfterSwipe(from onScreen: ShownContent?) {
        guard onScreen != shownContent else { return }
        var fade = sidebarFade
        let now = clock()
        let begun = fade.begin(arrivesAt: now, now: now)
        if begun.keepsOnScreen {
            fadingOutContent = onScreen
        }
        sidebarFade = fade
        scheduleFade(begun.timers)
    }

    /// The switch has picked its window: a better guess replaces the first, with no second fade after a click, and
    /// with a short one after a swipe, whose page was already in place.
    func refineSwitchPreview(id: Int, guess: SwitchGuess) {
        guard var preview = switchPreview, preview.id == id, preview.guess != guess else { return }
        let onScreen = displayedContent
        preview.guess = guess
        switchPreview = preview
        log.notice("the switch picked its window: the sidebar now shows \(Self.describe(guess), privacy: .public)")
        if preview.swiped {
            fadeAfterSwipe(from: onScreen)
        }
    }

    /// Safari shows a window of `profile` in front, or of the profile SafariProfiles knows as `profileID`. The
    /// preview ends once the sidebar's own choice is that profile's: right away, or when the copy reports it.
    /// `profile` fills in the key of a swipe's profile whose copy wasn't known when the swipe started.
    func confirmSwitchPreview(profile: ProfileKey?, profileID: UUID? = nil) {
        guard var preview = switchPreview, !preview.reported else { return }
        let byID = profileID != nil && preview.profileID == profileID
        let byKey = profile != nil && preview.profile == profile
        guard byID || byKey else { return }
        preview.reported = true
        if preview.profile == nil, let profile {
            preview.profile = profile
        }
        switchPreview = preview
        settleSwitchPreview()
    }

    /// The sidebar goes back to following Safari: the switch failed, or another window came to the front. With no
    /// fade after a click; after a swipe, a short one if that changes what it shows.
    func endSwitchPreview(because reason: String) {
        guard let preview = switchPreview else { return }
        let onScreen = displayedContent
        switchPreview = nil
        log.notice("the sidebar follows Safari again: \(reason, privacy: .public)")
        dropHeldCommands(because: "the switch's profile didn't come to the front")
        if preview.swiped {
            fadeAfterSwipe(from: onScreen)
        }
    }

    /// Ends a reported preview once the sidebar's own choice is its profile's: it keeps what it showed if the guess
    /// was right, and otherwise changes to that, without a fade after a click and with a short one after a swipe.
    private func settleSwitchPreview() {
        guard let preview = switchPreview, preview.reported, let own = ownContent, let shown = reportedContent else { return }
        switch own {
        case .turnOn(let id):
            guard id == preview.profileID else { return }
        case .window, .unseen, .placeholder:
            guard let profile = preview.profile, currentWindowProfile == profile else { return }
        }
        let onScreen = displayedContent
        switchPreview = nil
        switch SwitchPreviewRules.report(preview.guess, shown: shown) {
        case .kept:
            log.notice("Safari reported the switch's window: the sidebar's guess was right")
        case .corrected:
            log.notice("Safari reported the switch's window: the sidebar changes from \(Self.describe(preview.guess), privacy: .public) to \(Self.describe(shown), privacy: .public)")
            if preview.swiped {
                fadeAfterSwipe(from: onScreen)
            }
        }
        runHeldCommands()
    }

    /// A guess for the log: never a title.
    private static func describe(_ guess: SwitchGuess) -> String {
        switch guess {
        case .window(let instance, let windowId): "window \(windowId) of copy \(instance.prefix(8))"
        case .placeholder: "its lists, with Tabs to come"
        case .unseen: "a window its copy can't see, from the tab bar"
        case .turnOn: "the row to turn Side Tabs on"
        }
    }

    /// A profile for the log: never its name.
    private static func describe(_ profile: ProfileKey?) -> String {
        guard let profile else { return "a profile whose copy isn't known yet" }
        return describe(profile.isDefault ? nil : profile.rawValue)
    }

    // MARK: - Commands during a switch (#48)

    /// Commands from the sidebar made while a switch's preview shows no window yet (its lists and a placeholder,
    /// a window its copy can't see, or the row to turn Side Tabs on), for the profile the preview shows. They run
    /// once Safari has reported that profile's window and the sidebar shows it; if the preview ends any other way,
    /// or a newer switch begins, they're dropped: they were meant for a page no longer shown.
    @ObservationIgnored private var heldCommands: [(what: String, run: () -> Void)] = []

    /// While a switch's preview is up and shows no window to act on, holds `command` (the same call again) until
    /// Safari reports the switch's window, and says it did; the caller then does nothing now.
    private func heldForSwitch(_ what: String, _ command: @escaping () -> Void) -> Bool {
        guard switchPreview != nil, shownWindow == nil else { return false }
        heldCommands.append((what, command))
        if heldCommands.count > 8 {
            heldCommands.removeFirst(heldCommands.count - 8)
        }
        log.notice("holding \(what, privacy: .public) until Safari reports the switch's window: the sidebar shows no window to act on yet")
        return true
    }

    private func runHeldCommands() {
        guard !heldCommands.isEmpty else { return }
        let held = heldCommands
        heldCommands = []
        log.notice("Safari reported the switch's window: running \(held.count) command(s) held for it")
        for command in held {
            command.run()
        }
    }

    private func dropHeldCommands(because reason: String) {
        guard !heldCommands.isEmpty else { return }
        log.notice("dropping \(self.heldCommands.count) command(s) held for a switch: \(reason, privacy: .public)")
        heldCommands = []
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
        guard let profile else {
            log.notice("the sidebar shows \(space, privacy: .public): no favorites or pinned")
            return
        }
        let favorites = bookmarkLists.items(in: .favorites(profile)).count
        let pinned = bookmarkLists.items(in: .pinned(profile)).count
        log.notice("the sidebar shows \(space, privacy: .public): \(favorites) favorites, \(pinned) pinned")
    }

    // MARK: - Favorites and Pinned

    func bookmarks(in list: BookmarkList) -> [Bookmark] {
        bookmarkLists.items(in: list)
    }

    /// The ids of the bookmarks a window shows: its profile's Favorites and Pinned list, and none in a
    /// private window. A tab only belongs to a bookmark its window shows, so links never cross profiles.
    func bookmarkIds(shownIn window: BrowserWindow, instance: String) -> Set<UUID> {
        Set(bookmarkLists.shown(in: profile(of: window, instance: instance)).map(\.id))
    }

    /// The bookmark's own tab in the window the sidebar shows, if it has one there. Wherever the
    /// tab has browsed to since, it's the bookmark's until it closes.
    func openTab(for bookmark: Bookmark) -> BrowserTab? {
        guard let selection = shownWindow else { return nil }
        return bookmarkTabs.tab(of: bookmark.id, in: selection.window, instance: selection.instance)
    }

    /// The bookmark's own tab in the window a page of the sidebar shows (`SidebarPageWindow`): during a swipe, a
    /// page that's sliding in or out isn't the window commands act on (#72). Nil for a page with no window.
    func openTab(for bookmark: Bookmark, inPage page: SidebarPageWindow?) -> BrowserTab? {
        guard let page, let window = window(instance: page.instance, id: page.windowId) else { return nil }
        return bookmarkTabs.tab(of: bookmark.id, in: window, instance: page.instance)
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
    /// opens its saved page in a new tab of that window, which becomes its tab.
    func open(_ bookmark: Bookmark, inNewTab: Bool = false) {
        if heldForSwitch("opening a bookmark", { [weak self] in self?.open(bookmark, inNewTab: inNewTab) }) { return }
        guard let selection = shownWindow else {
            if let unseen = unseenDockedWindow, unseen.profile != nil {
                openOutside(unseen, bookmark)
            } else {
                openInSafari(bookmark.url)
            }
            return
        }
        // Only in a window of its own profile (#48): never with another profile's logins, and a tab is never linked
        // across profiles. A click on a list still fading out during a switch is such a click.
        guard bookmarkIds(shownIn: selection.window, instance: selection.instance).contains(bookmark.id) else {
            log.notice("not opening a bookmark in a window whose profile doesn't list it")
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
        ], to: selection.instance) { [weak self] in
            // Nothing is opening: the next click tries again.
            self?.pendingBookmarkOpens[requestId] = nil
        }
    }

    /// Opens a favorite or pinned item clicked in a window its profile's copy can't see (#41). The copy can't
    /// name that window, so the page opens through it in one it can: its most recent window, brought forward,
    /// or a new window of the profile when it sees none. Either way it's in the right profile, and the sidebar
    /// follows to a window it lists in full.
    private func openOutside(_ unseen: UnseenWindow, _ bookmark: Bookmark) {
        let windows = liveSnapshots[unseen.instance]?.windows.filter { !$0.incognito } ?? []
        let last = liveSnapshots[unseen.instance]?.lastFocusedWindowId
        if let window = windows.first(where: { $0.id == last }) ?? windows.first {
            let requestId = UUID().uuidString
            pendingBookmarkOpens[requestId] = (bookmark.id, window.id, Date(), nil)
            log.notice("opening a bookmark from a window its copy can't see: in another window of the profile")
            send(["action": "create", "windowId": window.id, "url": bookmark.url, "requestId": requestId, "focus": true], to: unseen.instance) { [weak self] in
                self?.pendingBookmarkOpens[requestId] = nil
            }
        } else {
            log.notice("opening a bookmark from a window its copy can't see: in a new window of the profile")
            send(["action": "openWindow", "url": bookmark.url], to: unseen.instance)
        }
    }

    /// Makes a favorite or pinned item of the tab's page, at `index` in `list` (at the end without
    /// one). It's what dragging a tab onto Favorites or Pinned does, and the tab's menu.
    func addBookmark(from tab: BrowserTab, instance: String, to list: BookmarkList, at index: Int? = nil) {
        addBookmark(from: tab, instance: instance, to: list, in: PinnedPlace(parent: nil, index: index ?? .max))
    }

    /// Makes a favorite or pinned item of the tab's page at `place`: for Favorites, its index there; for Pinned, a
    /// place in its tree (#76), as a drop on Pinned gives.
    func addBookmark(from tab: BrowserTab, instance: String, to list: BookmarkList, in place: PinnedPlace) {
        guard let url = tab.url, !url.isEmpty else { return }
        let bookmark = Bookmark(
            title: displayTitle(for: tab, instance: instance),
            url: url,
            faviconURL: savedIconURL(tab.favIconUrl)
        )
        guard insert(bookmark, into: list, in: place) else { return }
        // The tab moves up as the new bookmark's tab, unless it's another bookmark's, or its window
        // doesn't show that list (another profile's, or a private window).
        if let window = window(instance: instance, id: tab.windowId),
           bookmarkIds(shownIn: window, instance: instance).contains(bookmark.id) {
            changeBookmarkTabs { $0.link(TabKey(instance: instance, tabId: tab.id), to: bookmark.id) }
        }
    }

    /// Add Bookmark for the current tab (the + in Pinned's header). It pins the tab in the current
    /// window's profile's Pinned list. A private window has no lists, so there it does nothing (and the
    /// sidebar shows no + there).
    func addBookmarkForCurrentTab() {
        if heldForSwitch("pinning the current tab", { [weak self] in self?.addBookmarkForCurrentTab() }) { return }
        guard let selection = shownWindow, let tab = selection.window.tabs.first(where: \.active),
              let profile = profile(of: selection.window, instance: selection.instance) else { return }
        addBookmark(from: tab, instance: selection.instance, to: .pinned(profile))
    }

    /// A link dragged in from a web page or Safari's address bar.
    func addBookmark(url: URL, to list: BookmarkList, at index: Int? = nil) {
        addBookmark(url: url, to: list, in: PinnedPlace(parent: nil, index: index ?? .max))
    }

    /// A link dragged in, at `place` (see `addBookmark(from:instance:to:in:)`).
    func addBookmark(url: URL, to list: BookmarkList, in place: PinnedPlace) {
        guard let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) else { return }
        insert(Bookmark(title: url.host() ?? url.absoluteString, url: url.absoluteString), into: list, in: place)
    }

    /// Says whether it went in: not into a folder that's gone, or another profile's.
    @discardableResult
    private func insert(_ bookmark: Bookmark, into list: BookmarkList, in place: PinnedPlace) -> Bool {
        switch list {
        case .favorites:
            bookmarkLists.insert(bookmark, into: list, at: place.index)
        case .pinned(let profile):
            guard bookmarkLists.insert(.bookmark(bookmark), intoPinnedOf: profile, at: place) else {
                log.notice("not adding a bookmark to \(list, privacy: .public) at \(place, privacy: .public): no such folder there")
                return false
            }
        }
        log.notice("added a bookmark to \(list, privacy: .public), which has \(self.bookmarkLists.items(in: list).count) now")
        scheduleSave()
        return true
    }

    /// Takes a favorite or pinned item out of its list. Its tabs stay open, back under Tabs.
    func removeBookmark(_ bookmark: Bookmark) {
        guard let list = bookmarkLists.list(containing: bookmark.id) else { return }
        bookmarkLists.remove(bookmark.id)
        changeBookmarkTabs { $0.forget(bookmark: bookmark.id) }
        log.notice("removed a bookmark from \(list, privacy: .public), which has \(self.bookmarkLists.items(in: list).count) now")
        scheduleSave()
    }

    /// A favorite or pinned item dragged onto Tabs (#75): it's removed from its list, as Remove from Pinned
    /// does, and its tab in the window the sidebar shows lands at `slot` in the Tabs list, in Safari's tab bar
    /// too. One with no tab in that window opens its saved page there as a new tab. Either way the tab shows its
    /// page's own title: neither the bookmark's name nor a name the tab had before it was pinned carries over.
    /// Its tabs in the profile's other windows stay open, back under Tabs there.
    func unpin(_ id: UUID, toListedSlot slot: Int) {
        if heldForSwitch("unpinning a bookmark", { [weak self] in self?.unpin(id, toListedSlot: slot) }) { return }
        guard let selection = shownWindow, let bookmark = bookmarkLists.bookmark(id),
              let location = bookmarkLists.location(of: id),
              // Only from a window of its own profile, the only one whose lists the sidebar shows (#48).
              bookmarkIds(shownIn: selection.window, instance: selection.instance).contains(id) else { return }
        let tab = bookmarkTabs.tab(of: id, in: selection.window, instance: selection.instance)
        // Where in Safari's tab order the slot is, worked out while the bookmark's tab (if any) is still left
        // out of the Tabs list, as it is in the slot the drag showed.
        let index = Self.tabIndex(forListedSlot: slot, listed: tabsListed(in: selection.window, instance: selection.instance), in: selection.window)
        removeBookmark(bookmark)
        if let tab {
            let key = TabKey(instance: selection.instance, tabId: tab.id)
            if customNames[key] != nil {
                customNames[key] = nil
                scheduleSave()
            }
            moveTab(tab, instance: selection.instance, toListedSlot: slot)
        } else {
            var command: [String: Any] = ["action": "create", "windowId": selection.window.id, "url": bookmark.url]
            if let index {
                command["index"] = index
            }
            send(command, to: selection.instance) { [weak self] in
                // No tab opened, so the bookmark comes back where it was rather than being lost.
                guard let self, bookmarkLists.bookmark(id) == nil else { return }
                bookmarkLists.insert(bookmark, at: location)
                log.notice("the extension didn't open an unpinned bookmark's page; it's back in \(location.list, privacy: .public)")
                scheduleSave()
            }
        }
    }

    /// Where a tab put at `slot` in the Tabs list (`listed`, which leaves out bookmarks' tabs) goes among all the
    /// window's tabs: just before the tab listed there now, or just after the last one listed. Nil when nothing is
    /// listed, which leaves the place to Safari.
    static func tabIndex(forListedSlot slot: Int, listed: [BrowserTab], in window: BrowserWindow) -> Int? {
        if listed.indices.contains(slot), let position = window.tabs.firstIndex(where: { $0.id == listed[slot].id }) {
            return position
        }
        if let last = listed.last, let position = window.tabs.firstIndex(where: { $0.id == last.id }) {
            return position + 1
        }
        return nil
    }

    func replaceBookmarkWithCurrentPage(_ bookmark: Bookmark) {
        if heldForSwitch("replacing a bookmark with the current page", { [weak self] in self?.replaceBookmarkWithCurrentPage(bookmark) }) { return }
        guard let selection = shownWindow,
              let tab = selection.window.tabs.first(where: \.active),
              let url = tab.url,
              bookmarkLists.bookmark(bookmark.id) != nil,
              // Only with a page of its own profile's window (#48).
              bookmarkIds(shownIn: selection.window, instance: selection.instance).contains(bookmark.id) else { return }
        bookmarkLists.update(bookmark.id) { saved in
            saved.url = url
            saved.faviconURL = savedIconURL(tab.favIconUrl)
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
    /// list, or moving between its profile's Favorites and Pinned, where it keeps its tabs. It stays
    /// within its profile (#38): a move to another profile's list is refused.
    func moveBookmark(_ id: UUID, to list: BookmarkList, at index: Int) {
        guard let from = bookmarkLists.list(containing: id) else { return }
        guard from.profile == list.profile else {
            log.notice("not moving a bookmark from \(from, privacy: .public) to \(list, privacy: .public): lists don't cross profiles")
            return
        }
        bookmarkLists.move(id, to: list, at: index)
        if from != list {
            log.notice("moved a bookmark from \(from, privacy: .public) to \(list, privacy: .public)")
            // Its profile's windows show both lists, so it keeps its tabs. Any a window doesn't show are let
            // go all the same, so no link outlives the rule.
            changeBookmarkTabs { tabs in
                for snapshot in snapshots.values {
                    tabs.unlinkTabs(in: snapshot) { bookmarkIds(shownIn: $0, instance: snapshot.instance) }
                }
            }
        }
        scheduleSave()
    }

    // MARK: - Folders in Pinned (#76)

    /// A Pinned list's tree of pinned items and folders. Empty for a Favorites list, which has no folders.
    func pinnedTree(in list: BookmarkList) -> [PinnedNode] {
        guard case .pinned(let profile) = list else { return [] }
        return bookmarkLists.pinnedTree(of: profile)
    }

    func folder(_ id: UUID) -> PinnedFolder? {
        bookmarkLists.folder(id)?.folder
    }

    /// Where "New Folder" puts the folder: at the end of the top level (from Pinned's header or blank space), just
    /// below a pinned item or folder at its level (from its row), or at the top inside a folder (from the folder's).
    enum NewFolderSpot {
        case end
        case below(UUID)
        case inside(UUID)
    }

    /// "New Folder" in a Pinned list's menus. The folder starts empty and open, is named "New Folder", and goes
    /// straight into rename. The folders it's in open, so it's in view.
    func newFolder(in list: BookmarkList, _ spot: NewFolderSpot) {
        guard case .pinned(let profile) = list else { return }
        let place: PinnedPlace
        switch spot {
        case .end:
            place = .end(of: nil)
        case .below(let id):
            guard let (owner, at) = bookmarkLists.pinnedPlace(of: id), owner == profile else { return }
            place = PinnedPlace(parent: at.parent, index: at.index + 1)
        case .inside(let id):
            guard bookmarkLists.pinnedPlace(of: id)?.profile == profile else { return }
            place = PinnedPlace(parent: id, index: 0)
        }
        let folder = PinnedFolder(name: "New Folder", isOpen: true, children: [])
        guard bookmarkLists.insert(.folder(folder), intoPinnedOf: profile, at: place) else { return }
        for outer in bookmarkLists.pinnedTree(of: profile).ancestors(of: folder.id) {
            bookmarkLists.updateFolder(outer) { $0.isOpen = true }
        }
        log.notice("added a folder to \(list, privacy: .public) at \(place, privacy: .public)")
        scheduleSave()
        beginRename(.folder(folder.id))
    }

    /// Opens or closes a folder. Saved, so it stays that way after a restart.
    func setFolderOpen(_ id: UUID, _ isOpen: Bool) {
        guard let folder = folder(id), folder.isOpen != isOpen else { return }
        bookmarkLists.updateFolder(id) { $0.isOpen = isOpen }
        scheduleSave()
    }

    /// A click on a folder's row.
    func toggleFolder(_ id: UUID) {
        guard let folder = folder(id) else { return }
        setFolderOpen(id, !folder.isOpen)
    }

    /// The tabs of the pinned items inside a folder, at any depth, that are open in the window a page of the
    /// sidebar shows (`SidebarPageWindow`).
    func openTabs(inFolder id: UUID, inPage page: SidebarPageWindow?) -> [BrowserTab] {
        guard let folder = folder(id) else { return [] }
        return folder.children.flattenedBookmarks.compactMap { openTab(for: $0, inPage: page) }
    }

    /// A folder's Close Tabs: closes the open tabs of every pinned item inside it, at any depth, in the window the
    /// sidebar shows.
    func closeTabs(inFolder id: UUID) {
        guard let selection = shownWindow, let folder = folder(id) else { return }
        let tabs = folder.children.flattenedBookmarks.compactMap(openTab(for:))
        guard !tabs.isEmpty else { return }
        close(tabs, instance: selection.instance)
    }

    /// Asks whether to delete a folder that holds pinned items, in front of Safari, and answers on the main thread
    /// (AppDelegate). The question says the bookmarks inside go too.
    @ObservationIgnored var confirmFolderDeletion: ((_ answer: @escaping (Bool) -> Void) -> Void)?

    /// The question `confirmFolderDeletion` asks, word for word (#76).
    static let folderDeletionQuestion = "Deleting this folder will also delete all bookmarks inside. Are you sure?"

    /// Delete Folder: removes the folder and everything in it. With a pinned item anywhere inside, only once that's
    /// confirmed (`confirmFolderDeletion`); an empty folder, or one holding only empty folders, goes at once. The open
    /// tabs of the items inside stay open, back under Tabs, as Remove from Pinned leaves them.
    func deleteFolder(_ id: UUID) {
        guard let folder = folder(id) else { return }
        if folder.children.flattenedBookmarks.isEmpty {
            removeFolder(id)
            return
        }
        guard let confirmFolderDeletion else {
            log.notice("not deleting a folder with bookmarks inside: there's no one to ask")
            return
        }
        confirmFolderDeletion { [weak self] confirmed in
            guard confirmed else { return }
            self?.removeFolder(id)
        }
    }

    private func removeFolder(_ id: UUID) {
        guard let (_, profile) = bookmarkLists.folder(id), let removed = bookmarkLists.removeFolder(id) else { return }
        changeBookmarkTabs { tabs in
            for bookmark in removed {
                tabs.forget(bookmark: bookmark.id)
            }
        }
        switch renaming {
        case .folder(let renamed)? where folder(renamed) == nil:
            cancelRename(how: .gone)
        case .bookmark(let renamed)? where bookmarkLists.bookmark(renamed) == nil:
            cancelRename(how: .gone)
        default:
            break
        }
        log.notice("deleted a folder with \(removed.count) bookmarks from \(BookmarkList.pinned(profile), privacy: .public)")
        scheduleSave()
    }

    /// A drop on Pinned (#76): a favorite, a pinned item or a folder moves to `place` in the profile's Pinned list
    /// (given as it would be with it taken out). Never into another profile's list, or a folder into itself.
    func moveToPinned(_ id: UUID, list: BookmarkList, in place: PinnedPlace) {
        guard case .pinned(let profile) = list else { return }
        let from = bookmarkLists.list(containing: id) ?? bookmarkLists.folder(id).map { .pinned($0.profile) }
        guard let from else { return }
        guard from.profile == profile else {
            log.notice("not moving from \(from, privacy: .public) to \(list, privacy: .public): lists don't cross profiles")
            return
        }
        guard bookmarkLists.movePinned(id, in: profile, to: place) else {
            log.notice("not moving to \(place, privacy: .public) in \(list, privacy: .public): a folder can't go inside itself")
            return
        }
        if from != list {
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
        /// The default profile's favorites. Before there were profiles' lists this held every bookmark,
        /// and Side Tabs 1.2.5 still reads it as its bookmarks, so it's still written (#38). It's only read
        /// when `favorites` is missing: then these become the default profile's favorites.
        var bookmarks: [Bookmark]
        /// Each profile's Favorites, by `ProfileKey.rawValue` (#38). Missing from files saved before
        /// favorites belonged to profiles, or by a version that didn't know the key.
        var favorites: [String: [Bookmark]]?
        /// Each profile's Pinned list, by `ProfileKey.rawValue`. Missing from files saved before it existed.
        /// Since there are folders (#76) it holds every pinned item, at any depth, in display order, so Side Tabs
        /// 1.3.3 still reads the file; it's only read when `pinnedTree` is missing.
        var pinned: [String: [Bookmark]]?
        /// Each profile's Pinned tree, folders and all (#76). Missing from files saved before there were folders, or
        /// by a version without them, which drops the key.
        var pinnedTree: [String: [PinnedNode]]?
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
        bookmarkLists = BookmarkLists(favorites: state.favorites, bookmarks: state.bookmarks, pinned: state.pinned ?? [:], pinnedTree: state.pinnedTree)
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
            bookmarks: bookmarkLists.items(in: .favorites(.defaultProfile)),
            favorites: bookmarkLists.savedFavorites,
            pinned: bookmarkLists.savedPinned,
            pinnedTree: bookmarkLists.savedPinnedTree,
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
