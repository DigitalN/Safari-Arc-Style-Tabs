import ApplicationServices
import SafariServices
import SwiftUI

enum Permissions {
    static var accessibilityGranted: Bool { AccessibilityAccess.isGranted }

    /// macOS 27 renamed the Accessibility list in Privacy & Security.
    static var accessibilityPaneName: String {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            ? "Device Control and Data Access"
            : "Accessibility"
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func extensionEnabled() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: SideTabsBridge.extensionBundleIdentifier) { state, _ in
                continuation.resume(returning: state?.isEnabled ?? false)
            }
        }
    }

    static func openExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: SideTabsBridge.extensionBundleIdentifier) { error in
            guard error != nil else { return }
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = "Open Safari Settings"
                alert.informativeText = "In Safari, choose Settings → Extensions and turn on Side Tabs. If it isn't listed, follow the ‘Side Tabs isn't listed?’ help in setup."
                alert.addButton(withTitle: "Open Safari")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    openSafari()
                }
            }
        }
    }

    static func openSafari() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariTracker.safariBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openSafariTestPage() {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SafariTracker.safariBundleID) else { return }
        NSWorkspace.shared.open([URL(string: "https://example.com")!], withApplicationAt: safari,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}

/// First-run setup: one step at a time, coming back to the front as each step is done in
/// System Settings or Safari, and ending on a summary of where things are.
struct WelcomeView: View {
    /// "Start Browsing" on the final screen.
    let onFinish: () -> Void
    /// "Finish Later": close without marking setup complete.
    let onLater: () -> Void
    /// A step was just completed elsewhere; bring this window back to the front.
    let onStepCompleted: () -> Void

    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var extensionEnabled = false
    @State private var askedForAccessibilityAt: Date?
    @State private var askedForExtensionAt: Date?
    @State private var showExtensionHelp = false
    @State private var now = Date()

    private var websiteAccess: Bool {
        store.isConnected && store.snapshots.values.contains { snapshot in
            snapshot.windows.contains { window in
                window.tabs.contains { tab in
                    guard let raw = tab.url, let url = URL(string: raw), url.host != nil else { return false }
                    return url.scheme == "https" || url.scheme == "http"
                }
            }
        }
    }

    /// The first step that isn't done yet; nil once everything is.
    private var currentStep: Int? {
        [accessibility, extensionEnabled, websiteAccess].firstIndex(of: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Side Tabs")
                        .font(.title2.bold())
                    Text("Your Safari tabs, in a sidebar. We'll guide you through setup.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)

            if let current = currentStep {
                ScrollView {
                    VStack(spacing: 8) {
                        accessibilityStep(state(of: 0, current: current))
                        extensionStep(state(of: 1, current: current))
                        websiteStep(state(of: 2, current: current))
                    }
                    .padding(.horizontal, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: current == 1 && showExtensionHelp ? 440 : 320)
                .padding(.bottom, 20)
            } else {
                finished
            }

            Divider()

            HStack {
                if let current = currentStep {
                    Text("Step \(current + 1) of 3")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Finish Later", action: onLater)
                } else {
                    Text("Side Tabs opens and quits with Safari.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Start Browsing", action: onFinish)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .animation(.snappy(duration: 0.25), value: currentStep)
        .onChange(of: currentStep) { previous, current in
            if let previous, current != previous {
                onStepCompleted()
            }
        }
        .task {
            while !Task.isCancelled {
                accessibility = Permissions.accessibilityGranted
                extensionEnabled = await Permissions.extensionEnabled()
                now = Date()
                if !extensionEnabled, let asked = askedForExtensionAt,
                   now.timeIntervalSince(asked) > 10 {
                    showExtensionHelp = true
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func state(of step: Int, current: Int) -> SetupStepState {
        step < current ? .done : step == current ? .current : .upcoming
    }

    // MARK: Steps

    private func accessibilityStep(_ state: SetupStepState) -> some View {
        SetupStepCard(number: 1, title: "Let Side Tabs follow Safari's window", state: state) {
            Text("It keeps the sidebar attached to Safari and makes room for it. Turn on Side Tabs in the list that opens, and it restarts itself when it's done.")
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Button("Allow Access…") {
                    askedForAccessibilityAt = Date()
                    Permissions.requestAccessibility()
                }
                .buttonStyle(.borderedProminent)
                Button("Open Privacy & Security") {
                    askedForAccessibilityAt = Date()
                    Permissions.openAccessibilitySettings()
                }
                .buttonStyle(.link)
            }
            if let asked = askedForAccessibilityAt, now.timeIntervalSince(asked) > 15 {
                SetupHint("Already turned on? In Privacy & Security → \(Permissions.accessibilityPaneName), select Side Tabs and click −, then click + and choose Side Tabs from Applications.")
            }
        }
    }

    private func extensionStep(_ state: SetupStepState) -> some View {
        SetupStepCard(number: 2, title: "Turn on the extension in Safari", state: state) {
            Text("In the Safari Settings window that opens, check the box next to Side Tabs.")
                .foregroundStyle(.secondary)
            Button("Open Safari Settings") {
                askedForExtensionAt = Date()
                Permissions.openExtensionSettings()
            }
                .buttonStyle(.borderedProminent)
            DisclosureGroup("Side Tabs isn't listed or won't stay enabled?", isExpanded: $showExtensionHelp) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This free build isn't signed for distribution through Apple. On another Mac, Safari may require its unsigned-extension setting:")
                    Text("1. In Safari → Settings → Advanced, turn on **Show features for web developers**.")
                    Text("2. Open the **Developer** tab in Safari Settings and turn on **Allow unsigned extensions**. macOS may ask for your password.")
                    Text("3. Return to **Extensions** and turn on **Side Tabs**.")
                    Text("Safari resets Allow unsigned extensions when it quits. If Side Tabs stops working after reopening Safari, repeat steps 2 and 3. You can reopen this setup from Applications.")
                    Button("Show Side Tabs in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
        }
    }

    private func websiteStep(_ state: SetupStepState) -> some View {
        SetupStepCard(number: 3, title: "Let it see your tabs' names and icons", state: state) {
            Text("Safari asks before an extension can read pages. In Safari Settings → Extensions:")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Label("Click **Edit Websites…** next to Side Tabs", systemImage: "1.circle.fill")
                Label("Set **When visiting other websites** to **Allow**", systemImage: "2.circle.fill")
            }
            .foregroundStyle(.secondary)
            Button("Open Safari Settings") { Permissions.openExtensionSettings() }
                .buttonStyle(.borderedProminent)
            SetupHint("After allowing websites, open a web page in a regular Safari window so we can confirm it's working. Safari's Start Page can't confirm website access. Private windows need separate extension permission.")
            Button("Open a Test Page in Safari") { Permissions.openSafariTestPage() }
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're all set")
                        .font(.title3.bold())
                    Text("Your tabs are now in the sidebar next to Safari.")
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SetupTip(systemImage: "sidebar.left", text: "Side Tabs lives in your menu bar. Use it to show or hide the sidebar and to open Settings.")
                SetupTip(systemImage: "star", text: "Drag a tab into Pinned to keep a site at the top.")
                SetupTip(systemImage: "pencil", text: "Double-click a tab to rename it.")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}

enum SetupStepState {
    case done, current, upcoming
}

/// One setup step. Only the current step shows its instructions and buttons.
private struct SetupStepCard<Content: View>: View {
    let number: Int
    let title: String
    let state: SetupStepState
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(state == .done ? Color.green : state == .current ? Color.accentColor : Color.secondary.opacity(0.2))
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state == .current ? .white : .secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(state == .upcoming ? .secondary : .primary)
                    .padding(.top, 3)
                if state == .current {
                    content
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(state == .current ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(state == .current ? Color.accentColor.opacity(0.3) : Color.clear)
        )
    }
}

private struct SetupHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "lightbulb")
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.yellow.opacity(0.15)))
    }
}

private struct SetupTip: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Sidebar") {
                Toggle("Show sidebar", isOn: $settings.sidebarVisible)
                Toggle(isOn: $settings.autoHideSidebar) {
                    Text("Automatically hide sidebar")
                    Text("Move to Safari’s left edge to reveal it. Move away to hide it and keep the full page width.")
                }.disabled(!settings.sidebarVisible)
                LabeledContent("Width") {
                    HStack {
                        Slider(value: $settings.width, in: AppSettings.widthRange, step: 10)
                        Text("\(Int(settings.width)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Picker("Close buttons", selection: $settings.closeButtonMode) {
                    Text("Current tab and on hover").tag(AppSettings.CloseButtonMode.hover)
                    Text("Every tab").tag(AppSettings.CloseButtonMode.always)
                }
                Toggle("Show bookmarks", isOn: $settings.showBookmarks)
            }

            Section("Tab Cleanup") {
                Picker("Clean up unpinned tabs", selection: $settings.tabCleanupInterval) {
                    ForEach(TabCleanupInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                Text("Closes unpinned tabs after this much inactivity. Pinned tabs, Favorites, private tabs, and each window’s current tab are kept. Tabs playing audio or loading are also kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Text("Side Tabs opens automatically with Safari and quits when Safari quits.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: $settings.updatesAutomatically) {
                    Text("Update automatically")
                    Text("Checks GitHub when Safari starts and installs new versions when you're not using your Mac.")
                }
            }

            Section {
                PermissionRow()
            } header: {
                Text("Permissions")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PermissionRow: View {
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var extensionEnabled = false

    var body: some View {
        Group {
            LabeledContent("Accessibility") {
                if accessibility {
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Grant Access…") { Permissions.requestAccessibility() }
                }
            }
            LabeledContent("Safari extension") {
                if extensionEnabled {
                    Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Open Safari Extensions") { Permissions.openExtensionSettings() }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                accessibility = Permissions.accessibilityGranted
                extensionEnabled = await Permissions.extensionEnabled()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

struct MenuContent: View {
    let app: AppDelegate

    @Environment(AppSettings.self) private var settings
    @Environment(TabStore.self) private var store

    var body: some View {
        Button(settings.autoHideSidebar && settings.sidebarVisible ? "Show or Hide Sidebar" : settings.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
            app.toggleSidebar()
        }
        Divider()
        Text(store.isConnected ? "Safari extension: connected" : "Safari extension: not connected")
        if !Permissions.accessibilityGranted {
            Text("Accessibility access needed")
        }
        Button("Set Up…") { app.showWelcome() }
        Toggle("Automatically Hide Sidebar", isOn: Binding(get: { settings.autoHideSidebar }, set: { settings.autoHideSidebar = $0 }))
        Button("Import from Arc…") { app.showArcImport() }
        Button("Settings…") { app.showSettings() }
            .keyboardShortcut(",")
        Divider()
        Text("Side Tabs \(Updater.currentVersion)")
        switch app.updater.status {
        case .idle:
            Button("Check for Updates…") { app.updater.checkNow() }
        case .checking:
            Text("Checking for Updates…")
        case .downloading(let version):
            Text("Downloading Side Tabs \(version)…")
        case .ready(let version):
            Button("Restart to Update to \(version)") { app.updater.checkNow() }
        }
        Divider()
        Button("Quit Side Tabs") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
