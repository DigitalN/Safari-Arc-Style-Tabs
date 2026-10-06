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
        SFSafariApplication.showPreferencesForExtension(withIdentifier: SideTabsBridge.extensionBundleIdentifier)
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
    @State private var now = Date()

    private var websiteAccess: Bool { store.hasData && !store.lacksWebsiteAccess }

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
                    Text("Your Safari tabs, in a sidebar. Setup takes about a minute.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)

            if let current = currentStep {
                VStack(spacing: 8) {
                    accessibilityStep(state(of: 0, current: current))
                    extensionStep(state(of: 1, current: current))
                    websiteStep(state(of: 2, current: current))
                }
                .padding(.horizontal, 16)
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
                    Toggle("Open Side Tabs when I log in", isOn: Binding(
                        get: { settings.launchAtLoginStatus() },
                        set: { settings.launchAtLogin = $0 }
                    ))
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
                if accessibility && extensionEnabled && !settings.hasCompletedSetup {
                    // From here on, Side Tabs starts quietly even if setup is left open.
                    settings.hasCompletedSetup = true
                }
                now = Date()
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
            Button("Open Safari Settings") { Permissions.openExtensionSettings() }
                .buttonStyle(.borderedProminent)
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
                SetupTip(systemImage: "star", text: "Drag a tab up into Bookmarks to keep a site at the top.")
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

            Section("General") {
                Toggle("Open at login", isOn: Binding(
                    get: { settings.launchAtLoginStatus() },
                    set: { settings.launchAtLogin = $0 }
                ))
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
        Button(settings.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
            app.toggleSidebar()
        }
        Divider()
        Text(store.isConnected ? "Safari extension: connected" : "Safari extension: not connected")
        if !Permissions.accessibilityGranted {
            Text("Accessibility access needed")
        }
        Button("Set Up…") { app.showWelcome() }
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
