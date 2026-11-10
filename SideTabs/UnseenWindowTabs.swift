import AppKit
import Observation
import os.log

/// The tabs of the docked window while its profile's extension copy can't see it (#41,
/// `TabStore.unseenDockedWindow`), read from the window's tab bar through Accessibility.
///
/// After the extension reloads (every update), Safari keeps a profile's windows that were already open from
/// that profile's copy: `windows.getAll` gives it none of them. The sidebar then lists what the tab bar shows,
/// titles and which tab is selected, and switches and closes tabs by pressing their buttons, the way
/// TabBarPresser switches tabs for every window. Accessibility gives no addresses or icons, and the extension
/// can't act on the window, so there's no drag and nothing that needs the extension.
///
/// Reads happen off the main thread, only for the docked window, and only while it's unseen: when it becomes
/// unseen, when its title changes (a tab switch or a page loading), when another window is docked, and after
/// a press or close here. No timer. The one exception is a switch's target that its copy can't see (#44): its
/// tab bar is read as the switch picks it, so the sidebar can fade over to its tabs while it comes back from
/// the Dock, and what was read stays when it's docked.
@Observable
final class UnseenWindowTabs {
    struct Tab: Identifiable, Equatable {
        /// Its place in the tab bar, from 0 at the left.
        let position: Int
        /// Never logged.
        let title: String?
        var id: Int { position }
    }

    /// Left to right, as last read.
    private(set) var tabs: [Tab] = []
    /// The selected tab's position: what the tab bar said, or the one just clicked until it says again.
    private(set) var selected: Int?

    /// A window's only tab has no close action in Safari.
    var canClose: Bool { tabs.count > 1 }

    @ObservationIgnored private let tracker: SafariTracker
    @ObservationIgnored private let store: TabStore
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var readAgain = false
    @ObservationIgnored private var lastUnseen: TabStore.UnseenWindow?
    /// A switch's target whose tabs were read before it was docked (#44).
    @ObservationIgnored private var previewWindow: AXUIElement?
    @ObservationIgnored private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "profiles")

    init(tracker: SafariTracker, store: TabStore) {
        self.tracker = tracker
        self.store = store
    }

    func start() {
        observe()
        changed()
    }

    /// Another window is docked: what was read belongs to the last one, unless it was read for this one as a
    /// switch's target.
    func dockedWindowChanged(to window: AXUIElement?) {
        let wasPreviewed = previewWindow.flatMap { previewed in window.map { CFEqual(previewed, $0) } } ?? false
        previewWindow = nil
        if !wasPreviewed {
            tabs = []
            selected = nil
        }
        if store.unseenDockedWindow != nil {
            read()
        }
    }

    /// A switch's target is a window its copy can't see (#44): reads its tab bar now, for the sidebar to show
    /// while it comes back from the Dock.
    func preview(_ window: AXUIElement) {
        previewWindow = window
        tabs = []
        selected = nil
        tracker.readTabs(of: window) { [weak self] items in
            guard let self, let previewed = self.previewWindow, CFEqual(previewed, window), let items else { return }
            self.tabs = items.enumerated().map { Tab(position: $0.offset, title: $0.element.title) }
            self.selected = items.firstIndex { $0.isSelected == true }
        }
    }

    private func observe() {
        withObservationTracking {
            _ = store.unseenDockedWindow
            _ = store.dockedWindowTitle
            _ = store.switchPreview
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.changed()
                    self.observe()
                }
            }
        }
    }

    private func changed() {
        // While the sidebar shows a switch's target its copy can't see, what was read for it stays.
        let previewing = store.switchPreview?.guess == .unseen
        if previewWindow != nil, !previewing {
            // The switch it was read for is over, or went elsewhere.
            previewWindow = nil
        }
        let unseen = store.unseenDockedWindow
        if unseen != lastUnseen {
            switch (lastUnseen, unseen) {
            case (_, let now?):
                let kind = now.profile.map { $0.isDefault ? "the default profile's" : "profile \($0.rawValue.prefix(8))'s" } ?? "a private"
                log.notice("the docked window is \(kind, privacy: .public) window its copy doesn't list; listing its tabs from the tab bar")
            case (_?, nil):
                log.notice("the docked window's copy lists it again (or it's another window now); back to the full list")
            default:
                break
            }
            lastUnseen = unseen
        }
        if unseen != nil {
            read()
        } else if !previewing, !tabs.isEmpty || selected != nil {
            tabs = []
            selected = nil
        }
    }

    /// Reads the docked window's tab bar. One read at a time; asked for meanwhile, it reads once more after.
    func read() {
        // A switch's target isn't docked yet: the docked window's tabs aren't the ones shown.
        guard previewWindow == nil else { return }
        guard !reading else {
            readAgain = true
            return
        }
        reading = true
        tracker.readTabs { [weak self] items in
            guard let self else { return }
            self.reading = false
            if let items, self.store.unseenDockedWindow != nil, self.previewWindow == nil {
                let tabs = items.enumerated().map { Tab(position: $0.offset, title: $0.element.title) }
                if tabs != self.tabs {
                    self.tabs = tabs
                }
                let selected = items.firstIndex { $0.isSelected == true }
                if selected != self.selected {
                    self.selected = selected
                }
            }
            if self.readAgain {
                self.readAgain = false
                self.read()
            }
        }
    }

    /// Switches to the tab by pressing its button, on mouse-down. The highlight moves at once.
    func select(_ tab: Tab) {
        guard selected != tab.position else { return }
        selected = tab.position
        tracker.pressTab(target(for: tab)) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .pressed(let milliseconds):
                self.log.notice("switched a tab of a window its copy can't see by pressing its button, in \(milliseconds) ms")
            case .fallback(let reason):
                // The extension can't switch it either: it can't see the window.
                self.log.notice("couldn't press the tab's button in a window its copy can't see: \(reason, privacy: .public)")
            case .alreadySelected, .superseded:
                break
            }
            self.read()
        }
    }

    /// Closes the tab with its button's close action.
    func close(_ tab: Tab) {
        tracker.closeTab(target(for: tab)) { [weak self] problem in
            guard let self else { return }
            if let problem {
                self.log.notice("couldn't close a tab of a window its copy can't see: \(problem, privacy: .public)")
            }
            self.read()
        }
    }

    /// What TabBarMatcher needs to find the tab's button: its title and place, among the titles just read.
    private func target(for tab: Tab) -> TabBarTarget {
        TabBarTarget(title: tab.title, position: tab.position, windowTitles: tabs.map(\.title))
    }
}
