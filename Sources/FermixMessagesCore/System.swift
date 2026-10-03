import AppKit
import CoreGraphics
import CoreServices
import Foundation

/// The parts of the Mac the control plane reads and the grant flow acts on. Production
/// is `MacSystemInspector`; tests script a fake, so no test needs Messages or TCC.
protocol SystemInspector: AnyObject {
    /// `AEDeterminePermissionToAutomateTarget` against Messages. With `ask` the one
    /// system prompt may appear; without it this never prompts.
    func automation(ask: Bool) -> AutomationState
    func messagesRunning() -> Bool
    func signedIn() -> Tri
    func userSession() -> Bool
    /// Starts Messages without bringing it forward; true once it is running.
    func launchMessages() -> Bool
    func registerBundle()
    func openFullDiskAccessPane()
    func revealBundle()
}

final class MacSystemInspector: SystemInspector {
    static let messagesBundleId = "com.apple.MobileSMS"
    static let fullDiskAccessPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
        + "LaunchServices.framework/Support/lsregister"
    static let signedInScript = "tell application \"Messages\" to get enabled of (1st account whose service type = iMessage)"
    static let askTimeout: TimeInterval = 110
    static let launchTimeout: TimeInterval = 10
    static let signedInTimeout: TimeInterval = 10
    static let lsregisterTimeout: TimeInterval = 30

    private let bundleURL: URL
    private let log: Logger

    init(bundleURL: URL, log: Logger) {
        self.bundleURL = bundleURL
        self.log = log
    }

    func automation(ask: Bool) -> AutomationState {
        guard ask else { return Self.automationState(Self.determinePermission(ask: false)) }
        // The prompt waits for a human; it is bounded so a grant job cannot hang the
        // control lane. Unanswered, the state reads as it does without asking.
        let answered = DispatchSemaphore(value: 0)
        let box = StatusHolder()
        Thread.detachNewThread {
            box.status = Self.determinePermission(ask: true)
            answered.signal()
        }
        guard answered.wait(timeout: .now() + Self.askTimeout) == .success else {
            log.event("automation_prompt_unanswered", ["timeout_s": String(Int(Self.askTimeout))])
            return Self.automationState(Self.determinePermission(ask: false))
        }
        return Self.automationState(box.status)
    }

    static func automationState(_ status: OSStatus) -> AutomationState {
        switch status {
        case noErr: return .granted
        case -1743: return .denied
        case -1744: return .notDetermined
        default: return .unknown
        }
    }

    private static func determinePermission(ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let created = messagesBundleId.withCString { pointer in
            AECreateDesc(fourCharCode("bund"), pointer, strlen(pointer), &target)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, fourCharCode("****"), fourCharCode("****"), ask)
    }

    private static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    func messagesRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.messagesBundleId).isEmpty
    }

    func signedIn() -> Tri {
        do {
            let result = try BoundedChild.run("/usr/bin/osascript", ["-e", Self.signedInScript],
                                              timeout: Self.signedInTimeout)
            let state = Self.signedInState(result)
            if state == .unknown {
                log.event("signed_in_unknown", ["termination": "\(result.termination)",
                                                "stderr": String(result.stderrText.prefix(200))])
            }
            return state
        } catch {
            log.event("signed_in_spawn_failed", ["error": String(describing: error)])
            return .unknown
        }
    }

    /// `true`/`false` from the script; "no such account" (-1728, -1719) is not signed in;
    /// anything else (a timeout, another error) is unknown.
    static func signedInState(_ result: ChildResult) -> Tri {
        if result.termination == .exited(0) {
            switch result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "true": return .yes
            case "false": return .no
            default: return .unknown
            }
        }
        if case .exited = result.termination,
           result.stderrText.contains("(-1728)") || result.stderrText.contains("(-1719)") {
            return .no
        }
        return .unknown
    }

    func userSession() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session[kCGSessionOnConsoleKey as String] as? Bool) == true
    }

    func launchMessages() -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.messagesBundleId) else {
            log.event("messages_app_not_found")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let log = self.log
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            if let error { log.event("messages_launch_failed", ["error": error.localizedDescription]) }
        }
        let deadline = Date().addingTimeInterval(Self.launchTimeout)
        while Date() < deadline {
            if messagesRunning() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        log.event("messages_launch_timeout", ["timeout_s": String(Int(Self.launchTimeout))])
        return false
    }

    func registerBundle() {
        do {
            let result = try BoundedChild.run(Self.lsregister, ["-f", bundleURL.path], timeout: Self.lsregisterTimeout)
            log.event("lsregister", ["termination": "\(result.termination)"])
        } catch {
            log.event("lsregister_failed", ["error": String(describing: error)])
        }
    }

    func openFullDiskAccessPane() {
        guard let url = URL(string: Self.fullDiskAccessPane) else {
            preconditionFailure("the Full Disk Access pane URL is a constant")
        }
        let opened = NSWorkspace.shared.open(url)
        log.event("open_full_disk_access_pane", ["opened": String(opened)])
    }

    func revealBundle() {
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        log.event("reveal_bundle", ["path": bundleURL.path])
    }

    private final class StatusHolder {
        private let lock = NSLock()
        private var value: OSStatus = 0

        var status: OSStatus {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                value = newValue
                lock.unlock()
            }
        }
    }
}
