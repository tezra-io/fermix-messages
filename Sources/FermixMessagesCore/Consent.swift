import AppKit
import Foundation

public enum ConsentAnswer: String {
    case approved
    case cancelled
    case timedOut = "timed_out"
}

/// What the owner is asked: every handle, in the dialog's display form, and the posture
/// derived for them. Only the dedicated posture reaches the dialog: an owner who is this
/// Mac's own account is refused before it.
public struct ConsentRequest: Equatable {
    public let owner: String
    public let handles: [String]

    public var title: String {
        "Allow Fermix to exchange iMessages with \(Self.list(handles.map(Handles.display)))?"
    }

    public var detail: String {
        "Fermix will answer messages that \(Handles.display(owner)) sends to this Mac's account."
    }

    static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}

public protocol ConsentPrompter: AnyObject {
    func ask(_ request: ConsentRequest) -> ConsentAnswer
}

/// The native consent dialog, shown by this LSUIElement process itself: the helper comes
/// forward as an accessory app and runs one modal alert on the main thread. Unanswered,
/// the alert is aborted after `timeout` (under the engine's 180 s job budget) and the
/// answer is `timedOut`, never an approval.
public final class AlertConsentPrompter: ConsentPrompter {
    public static let approveTitle = "Approve"
    public static let cancelTitle = "Cancel"
    let timeout: TimeInterval

    public init(timeout: TimeInterval = 170) {
        self.timeout = timeout
    }

    public func ask(_ request: ConsentRequest) -> ConsentAnswer {
        let timeout = timeout
        return MainThread.sync {
            MainActor.assumeIsolated { Self.runAlert(request, timeout: timeout) }
        }
    }

    @MainActor
    private static func runAlert(_ request: ConsentRequest, timeout: TimeInterval) -> ConsentAnswer {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        app.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.title
        alert.informativeText = request.detail
        alert.addButton(withTitle: approveTitle)
        alert.addButton(withTitle: cancelTitle)
        let timer = Timer(timeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated { NSApplication.shared.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let response = alert.runModal()
        timer.invalidate()
        switch response {
        case .alertFirstButtonReturn: return .approved
        case .abort: return .timedOut
        default: return .cancelled
        }
    }
}

/// Runs a closure on the main thread and waits for it; inline when already there.
enum MainThread {
    static func sync<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }
}
