import Foundation

/// `probe` (design §6): the single source of the product's status. It never prompts and
/// works from zero permissions. Full Disk Access is read from opening chat.db read-only;
/// `missing` and `unreadable` are distinct from a permission denial.
final class Prober {
    private let location: MessagesLocation
    private let inspector: SystemInspector
    private let policy: PolicyService
    private let log: Logger

    init(location: MessagesLocation, inspector: SystemInspector, policy: PolicyService, log: Logger) {
        self.location = location
        self.inspector = inspector
        self.policy = policy
        self.log = log
    }

    func probe() -> ProbeResult {
        let database = databaseFacts()
        let running = inspector.messagesRunning()
        let automation = inspector.automation(ask: false)
        let signedIn = automation == .granted ? inspector.signedIn() : .unknown
        return ProbeResult(fullDiskAccess: database.access, db: database.state, automation: automation,
                           messagesRunning: running, signedIn: signedIn, userSession: inspector.userSession(),
                           policy: policy.state(), selfAliases: database.aliases)
    }

    /// Self aliases derived the same way the probe reports them (§9.4).
    func selfAliases() -> Result<[String], DBOpenFailure> {
        switch ChatDB.open(location) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let db):
            defer { db.close() }
            do {
                return .success(try db.selfAliases())
            } catch {
                return .failure(.unreadable(String(describing: error)))
            }
        }
    }

    private func databaseFacts() -> (access: FullDiskAccess, state: DBState, aliases: [String]?) {
        switch ChatDB.open(location) {
        case .success(let db):
            defer { db.close() }
            do {
                return (.granted, .readable, try db.selfAliases())
            } catch {
                log.event("self_aliases_failed", ["error": String(describing: error)])
                return (.granted, .readable, nil)
            }
        case .failure(.missing):
            return (directoryAccess(), .missing, nil)
        case .failure(.permissionDenied):
            return (.denied, .unreadable, nil)
        case .failure(.unreadable(let detail)):
            log.event("db_unreadable", ["detail": detail])
            return (.granted, .unreadable, nil)
        case .failure(.schemaUnexpected(let missing)):
            log.event("db_schema_unexpected", ["missing": missing.joined(separator: ",")])
            return (.granted, .schemaUnexpected, nil)
        }
    }

    /// With no chat.db, the Messages directory decides: a refused listing is a denial;
    /// a listable or absent directory shows no denial.
    private func directoryAccess() -> FullDiskAccess {
        guard let handle = opendir(location.directory) else {
            return errno == EPERM || errno == EACCES ? .denied : .granted
        }
        closedir(handle)
        return .granted
    }
}
