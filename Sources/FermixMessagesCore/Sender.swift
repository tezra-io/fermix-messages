import Foundation

enum ScriptMode: String {
    case chatText = "chat_text"
    case participantText = "participant_text"
    case chatFile = "chat_file"
    case participantFile = "participant_file"
}

/// One send through the Messages dictionary. `target` is a chat GUID (chat modes) or a
/// normalized handle (participant modes); `payload` is the text or a staged POSIX path.
struct ScriptCommand: Equatable {
    let mode: ScriptMode
    let target: String
    let payload: String
}

enum ScriptOutcome: Equatable {
    case returned
    case failed(code: Int?, text: String)
    case timedOut
    case spawnFailed(String)
}

protocol MessagesScripting: AnyObject {
    func send(_ command: ScriptCommand) -> ScriptOutcome
}

/// `osascript` with a fixed script whose values arrive only through `on run argv`:
/// nothing a caller sends is ever interpolated into AppleScript source. The mode comes
/// first in argv, so a payload that starts with "-" is never read as an option.
final class OsascriptMessages: MessagesScripting {
    static let timeout: TimeInterval = 20
    static let account = "(1st account whose service type = iMessage)"
    static let script = [
        "on run argv",
        "set theMode to item 1 of argv",
        "set theTarget to item 2 of argv",
        "set thePayload to item 3 of argv",
        "if theMode is \"chat_text\" then",
        "tell application \"Messages\" to send thePayload to chat id theTarget",
        "else if theMode is \"participant_text\" then",
        "tell application \"Messages\" to send thePayload to participant theTarget of \(account)",
        "else if theMode is \"chat_file\" then",
        "set theFile to POSIX file thePayload",
        "tell application \"Messages\" to send theFile to chat id theTarget",
        "else if theMode is \"participant_file\" then",
        "set theFile to POSIX file thePayload",
        "tell application \"Messages\" to send theFile to participant theTarget of \(account)",
        "else",
        "error \"unknown send mode\" number -1700",
        "end if",
        "end run",
    ]

    static func arguments(for command: ScriptCommand) -> [String] {
        script.flatMap { ["-e", $0] } + [command.mode.rawValue, command.target, command.payload]
    }

    /// The AppleScript error number osascript ends its message with: "... (-1743)".
    static func errorNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return nil }
        return Int(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
    }

    func send(_ command: ScriptCommand) -> ScriptOutcome {
        let result: ChildResult
        do {
            result = try BoundedChild.run("/usr/bin/osascript", Self.arguments(for: command), timeout: Self.timeout)
        } catch {
            return .spawnFailed(String(describing: error))
        }
        switch result.termination {
        case .exited(0): return .returned
        case .timedOut: return .timedOut
        case .exited, .signaled:
            let text = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(code: Self.errorNumber(text), text: String(text.prefix(500)))
        }
    }
}

struct VerifyTiming {
    let timeout: TimeInterval
    let interval: TimeInterval

    static let standard = VerifyTiming(timeout: 8, interval: 0.25)
}

struct StagedFile {
    let path: String
    let sha256: String
}

/// Outbound staging under ~/Library/Messages/Attachments/Fermix/<uuid>/<name> (§8.3):
/// Messages keeps a reference to the file it sent, so the copy stays; the root is kept
/// under its cap by evicting the oldest entries on every stage.
struct Staging {
    let root: String
    let fileCap: Int64
    let rootCap: Int64
    let log: Logger

    static let standardFileCap: Int64 = 100 * 1024 * 1024
    static let standardRootCap: Int64 = 1024 * 1024 * 1024

    func stage(_ source: String) -> Result<StagedFile, CopyFailure> {
        var info = stat()
        guard stat(source, &info) == 0 else { return .failure(.io("stat: \(String(cString: strerror(errno)))")) }
        guard info.st_size <= fileCap else { return .failure(.tooLarge(Int64(info.st_size))) }
        let directory = root + "/" + UUID().uuidString
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            _ = try FileTree.evictOldest(in: root, toFit: Int64(info.st_size), cap: rootCap)
            try HelperPaths.ensurePrivateDirectory(directory)
        } catch {
            return .failure(.io("staging: \(error)"))
        }
        let destination = directory + "/" + FileNames.sanitize((source as NSString).lastPathComponent)
        switch FileCopy.copy(from: source, to: destination, cap: fileCap) {
        case .success(let copied):
            return .success(StagedFile(path: destination, sha256: copied.sha256))
        case .failure(let failure):
            do {
                try FileManager.default.removeItem(atPath: directory)
            } catch {
                log.event("staging_cleanup_failed", ["error": String(describing: error)])
            }
            return .failure(failure)
        }
    }
}

/// The one mutation lane's work (design §8.2). Callers run it strictly one request at a
/// time; the ledger row is committed (synchronous=FULL) before AppleScript runs, the
/// outgoing row is verified for up to 8 s, and the outcome is one of three words.
final class Sender {
    private enum Payload {
        case text(String)
        case file(String)
    }

    private enum Verification {
        case recorded(guid: String, rowid: Int64)
        case ghost(String)
        case missing
    }

    private let ledger: Ledger
    private let database: () -> Result<ChatDB, DBOpenFailure>
    private let scripting: MessagesScripting
    private let staging: Staging
    private let outbox: String
    private let policy: PolicyService
    private let automation: () -> AutomationState
    private let now: () -> Date
    private let timing: VerifyTiming
    private let log: Logger
    private let onReconciled: (ReconciledEvent) -> Void

    init(ledger: Ledger, database: @escaping () -> Result<ChatDB, DBOpenFailure>, scripting: MessagesScripting,
         staging: Staging, outbox: String, policy: PolicyService, automation: @escaping () -> AutomationState,
         now: @escaping () -> Date, timing: VerifyTiming, log: Logger,
         onReconciled: @escaping (ReconciledEvent) -> Void) {
        self.ledger = ledger
        self.database = database
        self.scripting = scripting
        self.staging = staging
        self.outbox = outbox
        self.policy = policy
        self.automation = automation
        self.now = now
        self.timing = timing
        self.log = log
        self.onReconciled = onReconciled
    }

    func sendText(_ params: SendTextParams) -> Result<SendResult, HelperError> {
        send(to: params.to, key: params.idempotencyKey, payload: .text(params.text))
    }

    func sendFile(_ params: SendFileParams) -> Result<SendResult, HelperError> {
        send(to: params.to, key: params.idempotencyKey, payload: .file(params.path))
    }

    private func send(to rawTo: String, key: String, payload: Payload) -> Result<SendResult, HelperError> {
        let db: ChatDB
        switch database() {
        case .success(let opened): db = opened
        case .failure(let failure): return .failure(failure.helperError)
        }
        defer { db.close() }
        let stored: StoredPolicy
        switch policy.requireConfirmed() {
        case .success(let value): stored = value
        case .failure(let error): return .failure(error)
        }
        let state = automation()
        guard state != .denied && state != .notDetermined else {
            return .failure(.permissionDenied(.automation, "Automation of Messages is not granted"))
        }
        reconcile(db)
        guard case .success(let to) = Handles.normalize(rawTo), stored.allowed.contains(to) else {
            log.event("send_refused", ["class": "policy_violation", "to": Handles.redact(rawTo)])
            return .failure(.policyViolation(handle: rawTo, "recipient is outside the confirmed policy"))
        }
        do {
            if let existing = try ledger.find(key) {
                log.event("send_replayed", ["key": key, "state": existing.state.rawValue])
                return .success(existing.outcome)
            }
            return try dispatch(db, to: to, key: key, payload: payload)
        } catch {
            log.event("send_ledger_failed", ["key": key, "error": String(describing: error)])
            return .failure(HelperError(.dbUnreadable, "send ledger: \(error)"))
        }
    }

    /// A refused request (a path outside the outbox, a file over the cap) is an error
    /// response and leaves no ledger row: nothing was attempted.
    private func dispatch(_ db: ChatDB, to: String, key: String, payload: Payload) throws
        -> Result<SendResult, HelperError> {
        let chat = try db.directChat(handle: to)
        var textHash: String?
        var fileHash: String?
        let body: String
        switch payload {
        case .text(let text):
            body = text
            textHash = FileCopy.sha256(text)
        case .file(let path):
            switch prepareFile(path) {
            case .success(let staged):
                body = staged.path
                fileHash = staged.sha256
            case .failure(let refusal):
                log.event("send_refused", ["key": key, "class": refusal.kind.rawValue])
                return .failure(refusal)
            }
        }
        let command = Self.command(chat: chat, to: to, payload: payload, body: body)
        let row = LedgerRow(key: key, chat: chat?.guid ?? "", to: to, textSHA256: textHash, fileSHA256: fileHash,
                            watermark: try db.maxRowid(), state: .dispatched, startedAt: now(), guid: nil,
                            rowid: nil, finishedAt: nil, failureClass: nil, detail: nil)
        try ledger.insertDispatched(row)
        log.event("send_dispatched", ["key": key, "to": Handles.redact(to), "mode": command.mode.rawValue])
        let result = try conclude(db, row: row, outcome: scripting.send(command), payload: payload)
        try ledger.prune(now: now())
        return .success(result)
    }

    private static func command(chat: DirectChat?, to: String, payload: Payload, body: String) -> ScriptCommand {
        switch (payload, chat) {
        case (.text, let chat?): return ScriptCommand(mode: .chatText, target: chat.guid, payload: body)
        case (.text, nil): return ScriptCommand(mode: .participantText, target: to, payload: body)
        case (.file, let chat?): return ScriptCommand(mode: .chatFile, target: chat.guid, payload: body)
        case (.file, nil): return ScriptCommand(mode: .participantFile, target: to, payload: body)
        }
    }

    private func prepareFile(_ path: String) -> Result<StagedFile, HelperError> {
        switch SafePath.resolve(path, under: outbox) {
        case .failure(let refusal):
            return .failure(HelperError(.pathRefused, "path is not a file under the outbox (\(refusal.reason))"))
        case .success(let real):
            switch staging.stage(real) {
            case .success(let staged): return .success(staged)
            case .failure(.tooLarge(let bytes)): return .failure(.tooLarge(bytes: bytes, cap: staging.fileCap))
            case .failure(let other): return .failure(HelperError(.pathRefused, "staging failed: \(other)"))
            }
        }
    }

    /// AppleScript's own refusals are definitive pre-dispatch failures; anything else
    /// (returned, timed out, another error) is settled by looking for the outgoing row.
    private func conclude(_ db: ChatDB, row: LedgerRow, outcome: ScriptOutcome, payload: Payload) throws -> SendResult {
        switch outcome {
        case .failed(code: -1743, let text):
            return try finishFailed(row, .automationRefused, detail: text)
        case .failed(code: -1728, let text):
            return try finishFailed(row, .chatNotFound, detail: text)
        case .spawnFailed(let text):
            return try finishFailed(row, .sendTimeout, detail: "osascript did not start: \(text)")
        case .returned, .timedOut, .failed:
            break
        }
        var scriptText: String?
        if case .failed(_, let text) = outcome { scriptText = text }
        let verdict = verify(db, row: row, payload: payload)
        if case .recorded(let guid, let rowid) = verdict {
            try ledger.finish(row.key, state: .recorded, guid: guid, rowid: rowid, failureClass: nil,
                              detail: scriptText, at: now())
            log.event("send_recorded", ["key": row.key, "rowid": String(rowid)])
            return .recorded(guid: guid, rowid: rowid)
        }
        var finding = "no outgoing row within \(Int(timing.timeout)) s"
        if case .ghost(let shape) = verdict { finding = shape }
        let timeoutClass: ErrorKind? = outcome == .timedOut ? .sendTimeout : nil
        let words = [scriptText, outcome == .timedOut ? "osascript timed out" : nil, finding]
            .compactMap { $0 }.joined(separator: "; ")
        try ledger.finish(row.key, state: .uncertain, guid: nil, rowid: nil, failureClass: timeoutClass,
                          detail: words, at: now())
        log.event("send_uncertain", ["key": row.key, "detail": finding])
        return SendResult(disposition: .uncertain, guid: nil, rowid: nil, failureClass: timeoutClass)
    }

    private func finishFailed(_ row: LedgerRow, _ kind: ErrorKind, detail: String) throws -> SendResult {
        try ledger.finish(row.key, state: .failed, guid: nil, rowid: nil, failureClass: kind, detail: detail, at: now())
        log.event("send_failed", ["key": row.key, "class": kind.rawValue])
        return .failed(kind)
    }

    /// Polls for the outgoing row: is_from_me, in the resolved chat (or the direct chat
    /// for the handle), above the watermark, iMessage on both handle and chat, with the
    /// same text or an attachment. A row of the ghost shape (SMS service, or no body and
    /// no attachment) settles the send as uncertain at once.
    private func verify(_ db: ChatDB, row: LedgerRow, payload: Payload) -> Verification {
        let deadline = Date().addingTimeInterval(timing.timeout)
        repeat {
            switch scan(db, row: row, payload: payload) {
            case .some(let verdict): return verdict
            case .none: Thread.sleep(forTimeInterval: timing.interval)
            }
        } while Date() < deadline
        return .missing
    }

    private func scan(_ db: ChatDB, row: LedgerRow, payload: Payload) -> Verification? {
        let candidates: [DecodedRow]
        do {
            candidates = try outgoing(db, after: row.watermark, chat: row.chat, to: row.to)
        } catch {
            log.event("verify_read_failed", ["key": row.key, "error": String(describing: error)])
            return nil
        }
        for candidate in candidates {
            if let ghost = Self.ghostShape(candidate) { return .ghost(ghost) }
            if Self.matches(candidate, payload: payload) {
                return .recorded(guid: candidate.raw.guid, rowid: candidate.raw.rowid)
            }
        }
        return nil
    }

    private func outgoing(_ db: ChatDB, after watermark: Int64, chat: String, to: String) throws -> [DecodedRow] {
        try db.rows(after: watermark, limit: 256).filter { raw in
            guard raw.isFromMe else { return false }
            if !chat.isEmpty && raw.chatGuid == chat { return true }
            let identifier = raw.chatIdentifier.flatMap { Handles.normalize($0).successValue }
            return identifier == to && raw.chatGuid.contains(";-;")
        }.map { raw in
            DecodedRow(raw, attachments: try db.attachments(messageRowid: raw.rowid), now: now())
        }
    }

    static func ghostShape(_ row: DecodedRow) -> String? {
        if row.raw.chatService != "iMessage" { return "ghost row: chat service \(row.raw.chatService ?? "none")" }
        if let service = row.raw.handleService, service != "iMessage" { return "ghost row: handle service \(service)" }
        if (row.text ?? "").isEmpty && row.attachments.isEmpty { return "ghost row: empty body" }
        return nil
    }

    private static func matches(_ row: DecodedRow, payload: Payload) -> Bool {
        switch payload {
        case .text(let text): return row.text == text
        case .file: return !row.attachments.isEmpty
        }
    }

    // MARK: - Reconciliation

    /// Settles every `dispatched` row left by a previous process (§8.2): a matching
    /// outgoing row above the watermark makes it recorded, otherwise uncertain. Deferred,
    /// with a log line, while chat.db is unreadable.
    @discardableResult
    func reconcile() -> [ReconciledEvent] {
        switch database() {
        case .success(let db):
            defer { db.close() }
            return reconcile(db)
        case .failure(let failure):
            do {
                let pending = try ledger.dispatched()
                if !pending.isEmpty {
                    log.event("reconcile_deferred", ["pending": String(pending.count), "db": "\(failure)"])
                }
            } catch {
                log.event("reconcile_failed", ["error": String(describing: error)])
            }
            return []
        }
    }

    @discardableResult
    private func reconcile(_ db: ChatDB) -> [ReconciledEvent] {
        let pending: [LedgerRow]
        do {
            pending = try ledger.dispatched()
        } catch {
            log.event("reconcile_failed", ["error": String(describing: error)])
            return []
        }
        var events: [ReconciledEvent] = []
        for row in pending {
            guard let event = settle(db, row) else { continue }
            events.append(event)
            onReconciled(event)
        }
        return events
    }

    private func settle(_ db: ChatDB, _ row: LedgerRow) -> ReconciledEvent? {
        do {
            let match = try outgoing(db, after: row.watermark, chat: row.chat, to: row.to).first { candidate in
                Self.ghostShape(candidate) == nil && (row.fileSHA256 != nil
                    ? !candidate.attachments.isEmpty
                    : candidate.text.map(FileCopy.sha256) == row.textSHA256)
            }
            let detail = "reconciled after a restart"
            if let match {
                try ledger.finish(row.key, state: .recorded, guid: match.raw.guid, rowid: match.raw.rowid,
                                  failureClass: nil, detail: detail, at: now())
                log.event("send_reconciled", ["key": row.key, "disposition": "recorded"])
                return ReconciledEvent(idempotencyKey: row.key, disposition: .recorded, guid: match.raw.guid)
            }
            try ledger.finish(row.key, state: .uncertain, guid: nil, rowid: nil, failureClass: nil, detail: detail,
                              at: now())
            log.event("send_reconciled", ["key": row.key, "disposition": "uncertain"])
            return ReconciledEvent(idempotencyKey: row.key, disposition: .uncertain, guid: nil)
        } catch {
            log.event("reconcile_failed", ["key": row.key, "error": String(describing: error)])
            return nil
        }
    }
}
