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

struct WelcomeView: View {
    let onDone: () -> Void

    @Environment(TabStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var extensionEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set Up Side Tabs")
                        .font(.title2.bold())
                    Text("Three steps and your Safari tabs move into a sidebar.")
                        .foregroundStyle(.secondary)
                }
            }

            SetupStep(
                number: 1,
                title: "Allow Accessibility access",
                detail: "Lets Side Tabs keep the sidebar attached to your Safari window and make room for it. In System Settings → Privacy & Security → \(Permissions.accessibilityPaneName), turn on Side Tabs. If it's already on but the sidebar doesn't appear, select Side Tabs, click −, then + to add it again.",
                done: accessibility
            ) {
                Button("Grant Access…") { Permissions.requestAccessibility() }
                Button("Open Privacy Settings") { Permissions.openAccessibilitySettings() }
                    .buttonStyle(.link)
            }

            SetupStep(
                number: 2,
                title: "Turn on the Safari extension",
                detail: "In Safari Settings → Extensions, check the box next to Side Tabs.",
                done: extensionEnabled
            ) {
                Button("Open Safari Extensions") { Permissions.openExtensionSettings() }
            }

            SetupStep(
                number: 3,
                title: "Allow it on every website",
                detail: "Select Side Tabs in that list, click Edit Websites…, and set “When visiting other websites” to Allow. Safari hides tab titles and icons from the sidebar until you do.",
                done: store.hasData && !store.lacksWebsiteAccess
            ) {
                Button("Open Safari Extensions") { Permissions.openExtensionSettings() }
            }

            Divider()

            HStack {
                Toggle("Open Side Tabs when I log in", isOn: Binding(
                    get: { settings.launchAtLoginStatus() },
                    set: { settings.launchAtLogin = $0 }
                ))
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .task {
            while !Task.isCancelled {
                accessibility = Permissions.accessibilityGranted
                extensionEnabled = await Permissions.extensionEnabled()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct SetupStep<Actions: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.2))
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !done {
                    HStack(spacing: 12) { actions }
                        .padding(.top, 2)
                }
            }
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
        Text("Side Tabs \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
        Button("Check for Updates…") { NSWorkspace.shared.open(AppLocation.releasesURL) }
        Divider()
        Button("Quit Side Tabs") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
