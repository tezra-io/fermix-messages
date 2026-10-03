import Foundation

/// The production wiring for one FERMIX_HOME: the real Messages location, the login
/// keychain item, the AppKit consent dialog and the Mac inspector. The one-shot commands
/// use the control plane only; `serve` adds the ledger and the data plane.
final class Runtime {
    let log: Logger
    let location: MessagesLocation
    let paths: HelperPaths
    let inspector: MacSystemInspector
    let policy: PolicyService
    let prober: Prober
    let granter: Granter

    init(home: String, log: Logger) throws {
        self.log = log
        paths = try HelperPaths.resolve(home: home)
        location = .forCurrentUser()
        let inspector = MacSystemInspector(bundleURL: Bundle.main.bundleURL, log: log)
        self.inspector = inspector
        let location = location
        policy = PolicyService(store: try KeychainPolicyStore(home: paths.home), prompter: AlertConsentPrompter(),
                               now: Date.init, userSession: { inspector.userSession() },
                               selfAliases: { ChatDB.readSelfAliases(location) }, log: log)
        prober = Prober(location: location, inspector: inspector, policy: policy, log: log,
                        helperVersion: HelperInfo.current().version)
        granter = Granter(inspector: inspector, prober: prober)
    }

    func makeServer(output: StdoutWriter) throws -> Server {
        try paths.prepare()
        let ledger = try Ledger.open(path: paths.ledger)
        try ledger.prune(now: Date())
        let location = location
        let inspector = inspector
        let feed = Feed(location: location, policy: policy, ledger: ledger, emitted: EmittedRegistry(), log: log,
                        now: Date.init)
        let sender = Sender(
            ledger: ledger, database: { ChatDB.open(location) }, scripting: OsascriptMessages(),
            staging: Staging(root: location.stagingRoot, fileCap: Staging.standardFileCap,
                             rootCap: Staging.standardRootCap),
            outbox: paths.outbox, policy: policy, automation: { inspector.automation(ask: false) }, now: Date.init,
            timing: .standard, log: log,
            onReconciled: { event in output.notify(Wire.encodeNotification(.sendReconciled, event)) {} })
        let watcher = Watcher(location: location, feed: feed, sink: output, log: log, now: Date.init)
        watcher.start()
        let fetcher = AttachmentFetcher(feed: feed, inbox: paths.inbox, converter: ToolConverter(),
                                        cap: Staging.standardFileCap, log: log, now: Date.init)
        let services = Server.Services(policy: policy, prober: prober, granter: granter, sender: sender,
                                       watcher: watcher, feed: feed, fetcher: fetcher, ledger: ledger,
                                       info: .current(), location: location)
        return Server(services: services, output: output, log: log)
    }
}
