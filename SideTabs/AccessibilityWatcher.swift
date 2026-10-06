import AppKit
import ApplicationServices
import os.log

/// Whether the app may use the Accessibility API.
///
/// On macOS 27, `AXIsProcessTrusted()` has been seen to disagree with System Settings, so
/// also try a real request against the Dock (always running): it fails with
/// `.apiDisabled` exactly when access is missing.
enum AccessibilityAccess {
    static var isGranted: Bool {
        if AXIsProcessTrusted() {
            return true
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return false
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(dock.processIdentifier),
            kAXRoleAttribute as CFString,
            &value
        )
        return error == .success
    }
}

/// macOS often keeps telling a running app it isn't trusted for Accessibility after the
/// user grants access, and AX calls can keep failing until the app restarts. So while
/// untrusted, ask a fresh copy of our own executable (which gets the current answer),
/// and relaunch once access is granted.
final class AccessibilityWatcher {
    static let checkArgument = "--check-accessibility"
    /// Passed to the relaunched copy so it brings setup back to show the next step.
    static let resumeSetupArgument = "--resume-setup"

    var onGranted: (() -> Void)?

    private var timer: Timer?
    private var token: NSObjectProtocol?
    private var checking = false
    private let log = Logger(subsystem: SideTabsBridge.appBundleIdentifier, category: "accessibility")

    func start() {
        let probe = AccessibilityAccess.isGranted
        log.notice("AXIsProcessTrusted: \(AXIsProcessTrusted()), AX API probe: \(probe)")
        guard !probe else { return }
        log.notice("waiting for Accessibility access")

        // Posted whenever the Accessibility list in System Settings changes.
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.check()
            }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let token {
            DistributedNotificationCenter.default().removeObserver(token)
        }
        token = nil
    }

    private func check() {
        guard timer != nil, !checking else { return }
        if AccessibilityAccess.isGranted {
            granted()
            return
        }
        guard let executable = Bundle.main.executableURL else { return }

        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.checkArgument]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let trusted = process.terminationStatus == 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                if trusted {
                    self.granted()
                }
            }
        }
        checking = true
        do {
            try process.run()
        } catch {
            checking = false
        }
    }

    private func granted() {
        guard timer != nil else { return }
        stop()
        log.notice("Accessibility access granted; relaunching")
        onGranted?()
    }

    /// Starts a new copy of the app once this one has quit, picking up setup where it left off.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\" --args \"$2\"", "sh", Bundle.main.bundlePath, resumeSetupArgument]
        try? process.run()
        NSApp.terminate(nil)
    }
}
