import Foundation

/// `grant` (design §6, §10.2): the two actions that need the owner. Both return the
/// probe afterwards; both need the owner's console session, where TCC can show a
/// prompt and System Settings can open.
final class Granter {
    private let inspector: SystemInspector
    private let prober: Prober

    init(inspector: SystemInspector, prober: Prober) {
        self.inspector = inspector
        self.prober = prober
    }

    func grant(_ service: Service) -> Result<ProbeResult, HelperError> {
        guard inspector.userSession() else {
            return .failure(HelperError(.noUserSession, "granting needs a logged-in console session"))
        }
        switch service {
        case .automation:
            // Automation is asked of a running Messages; then the one system prompt.
            if !inspector.messagesRunning() { _ = inspector.launchMessages() }
            _ = inspector.automation(ask: true)
        case .fullDiskAccess:
            // There is no request API: register the bundle so the pane can list it, open
            // the pane, and reveal the bundle for a drag-in.
            inspector.registerBundle()
            inspector.openFullDiskAccessPane()
            inspector.revealBundle()
        }
        return .success(prober.probe())
    }
}
