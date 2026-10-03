import Foundation

public enum LineVerdict: Equatable {
    case continueReading
    case shutdown
    case protocolError(String)
}

/// The serialized stdout: every response and notification goes through one writer, so
/// two lanes can never interleave a line.
public protocol LineOutput: AnyObject {
    func send(_ line: Data, onWritten: (() -> Void)?)
    func flush()
}

/// stdout as the wire: one serial queue, whole lines written with write(2) (no stdio
/// buffer), each line out before the next. A failed write (the engine went away) calls
/// `onBroken` once.
public final class StdoutWriter: LineOutput, NotificationSink {
    private let fd: Int32
    private let queue = DispatchQueue(label: "io.tezra.fermix.messages.stdout")
    private let onBroken: () -> Void

    public init(fd: Int32, onBroken: @escaping () -> Void) {
        self.fd = fd
        self.onBroken = onBroken
    }

    public func send(_ line: Data, onWritten: (() -> Void)?) {
        queue.async { [self] in
            let ok = Self.writeAll(fd, line + Data([0x0a]))
            onWritten?()
            if !ok { onBroken() }
        }
    }

    func notify(_ line: Data, onWritten: @escaping () -> Void) {
        send(line, onWritten: onWritten)
    }

    public func flush() {
        queue.sync {}
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}

public enum LineRead: Equatable {
    case line(Data)
    case eof
    case tooLong
    case failed(Int32)
}

/// Requests from stdin, one per line (a trailing CR is dropped). A line longer than
/// `maxLine` is a protocol error.
public final class LineReader {
    private let fd: Int32
    private let maxLine: Int
    private var buffer = Data()
    private var atEnd = false

    public init(fd: Int32, maxLine: Int = 4 << 20) {
        self.fd = fd
        self.maxLine = maxLine
    }

    public func next() -> LineRead {
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                guard newline - buffer.startIndex <= maxLine else { return .tooLong }
                var line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer = buffer.subdata(in: (newline + 1)..<buffer.endIndex)
                if line.last == 0x0d { line.removeLast() }
                return .line(line)
            }
            guard buffer.count <= maxLine else { return .tooLong }
            if atEnd {
                guard !buffer.isEmpty else { return .eof }
                defer { buffer = Data() }
                return .line(buffer)
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return .failed(errno) }
            if count == 0 { atEnd = true } else { buffer.append(contentsOf: chunk[0..<count]) }
        }
    }
}

public struct HelperInfo {
    let version: String
    let bundleId: String?
    let macos: String

    /// The bundle's version (build_app.sh writes it into Info.plist); a bare binary
    /// outside the bundle reports "unbundled".
    public static func current() -> HelperInfo {
        let bundle = Bundle.main
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macos = "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
        return HelperInfo(version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unbundled",
                          bundleId: bundle.bundleIdentifier, macos: macos)
    }
}

/// The request loop's dispatcher (design §6). The control plane (initialize, probe,
/// grant, policy.*, shutdown) never needs the database; the data plane checks the
/// database, the policy and (for sends) Automation on every call. Lanes: control is
/// serial (it may hold a dialog), reads run up to four at once, sends run strictly one
/// at a time. More than 32 outstanding requests are refused `busy`.
public final class Server {
    struct Services {
        let policy: PolicyService
        let prober: Prober
        let granter: Granter
        let sender: Sender
        let watcher: Watcher
        let feed: Feed
        let fetcher: AttachmentFetcher
        let ledger: Ledger
        let info: HelperInfo
        let location: MessagesLocation
    }

    static let maxOutstanding = 32
    /// How long shutdown and end-of-input wait for an in-flight send before exiting; the
    /// engine closes the port 2 s after `shutdown`. A send cut short stays `dispatched`
    /// in the ledger and is reconciled at the next start.
    static let drainTimeout: TimeInterval = 1

    private let services: Services
    private let output: LineOutput
    private let log: Logger
    private let control = Server.lane("control", width: 1)
    private let reads = Server.lane("reads", width: 4)
    private let sends = Server.lane("sends", width: 1)
    private let lock = NSLock()
    private var initialized = false
    private var outstanding = 0

    init(services: Services, output: LineOutput, log: Logger) {
        self.services = services
        self.output = output
        self.log = log
    }

    private static func lane(_ name: String, width: Int) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "io.tezra.fermix.messages.\(name)"
        queue.maxConcurrentOperationCount = width
        return queue
    }

    public func handle(_ line: Data) -> LineVerdict {
        let request: Request
        switch Wire.decodeRequest(line) {
        case .success(let decoded): request = decoded
        case .failure(let failure):
            log.event("protocol_error", ["reason": failure.reason])
            return .protocolError(failure.reason)
        }
        guard isInitialized || request.method == Method.initialize.rawValue else {
            write(request.id, Result<EmptyResult, HelperError>.failure(
                HelperError(.notInitialized, "initialize must be the first request")))
            return .continueReading
        }
        guard let method = Method(rawValue: request.method) else {
            write(request.id, Result<EmptyResult, HelperError>.failure(
                HelperError(.protocolMismatch, "unknown method \(request.method)")))
            return .continueReading
        }
        switch method {
        case .initialize:
            write(request.id, initialize(request))
            return .continueReading
        case .shutdown:
            finish()
            write(request.id, Result<EmptyResult, HelperError>.success(EmptyResult()))
            output.flush()
            return .shutdown
        default:
            enqueue(method, request)
            return .continueReading
        }
    }

    /// Stops taking work, lets an in-flight send finish within `drainTimeout`, stops the
    /// watcher and closes the ledger. Called once, before the process exits 0.
    public func finish() {
        [control, reads, sends].forEach { $0.cancelAllOperations() }
        let drained = DispatchSemaphore(value: 0)
        let sends = sends
        Thread.detachNewThread {
            sends.waitUntilAllOperationsAreFinished()
            drained.signal()
        }
        if drained.wait(timeout: .now() + Self.drainTimeout) == .timedOut {
            log.event("shutdown_send_in_flight", ["note": "left dispatched; reconciled at the next start"])
        }
        services.watcher.stop()
        services.ledger.close()
        log.event("shutdown")
    }

    private var isInitialized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return initialized
    }

    private func initialize(_ request: Request) -> Result<InitializeResult, HelperError> {
        let params: InitializeParams
        switch request.params(InitializeParams.self) {
        case .success(let decoded): params = decoded
        case .failure(let error): return .failure(error)
        }
        guard params.protocolVersion == Wire.protocolVersion else {
            return .failure(HelperError(
                .protocolMismatch, "helper speaks protocol \(Wire.protocolVersion), client asked for \(params.protocolVersion)",
                data: ["helper": .int(Int64(Wire.protocolVersion)), "client": .int(Int64(params.protocolVersion))]))
        }
        lock.lock()
        initialized = true
        lock.unlock()
        log.event("initialized", ["client": params.client ?? "unnamed"])
        // Sends a previous process left dispatched are settled first on the send lane,
        // and announced as send.reconciled now that a client is listening.
        let sender = services.sender
        sends.addOperation { sender.reconcile() }
        return .success(InitializeResult(protocolVersion: Wire.protocolVersion, helperVersion: services.info.version,
                                         macosVersion: services.info.macos, bundleId: services.info.bundleId,
                                         dbGeneration: ChatDB.generation(of: services.location.chatDB)))
    }

    private func enqueue(_ method: Method, _ request: Request) {
        lock.lock()
        let admitted = outstanding < Self.maxOutstanding
        if admitted { outstanding += 1 }
        lock.unlock()
        guard admitted else {
            write(request.id, Result<EmptyResult, HelperError>.failure(
                HelperError(.busy, "more than \(Self.maxOutstanding) outstanding requests")))
            return
        }
        lane(for: method).addOperation { [self] in
            output.send(perform(method, request), onWritten: nil)
            lock.lock()
            outstanding -= 1
            lock.unlock()
        }
    }

    private func lane(for method: Method) -> OperationQueue {
        switch method {
        case .probe, .grant, .policyGet, .policySet, .initialize, .shutdown: return control
        case .sendText, .sendFile: return sends
        case .watchSubscribe, .watchUnsubscribe, .messagesAfter, .attachmentFetch: return reads
        }
    }

    private func perform(_ method: Method, _ request: Request) -> Data {
        let id = request.id
        switch method {
        case .probe: return reply(id, Result<ProbeResult, HelperError>.success(services.prober.probe()))
        case .grant: return reply(id, request.params(GrantParams.self).flatMap { services.granter.grant($0.service) })
        case .policyGet: return reply(id, services.policy.get())
        case .policySet: return reply(id, request.params(PolicySetParams.self).flatMap(services.policy.set))
        case .watchSubscribe:
            return reply(id, request.params(SubscribeParams.self).flatMap(services.watcher.subscribe))
        case .watchUnsubscribe:
            services.watcher.unsubscribe()
            return reply(id, Result<EmptyResult, HelperError>.success(EmptyResult()))
        case .messagesAfter: return reply(id, request.params(MessagesAfterParams.self).flatMap(services.feed.after))
        case .sendText: return reply(id, request.params(SendTextParams.self).flatMap(services.sender.sendText))
        case .sendFile: return reply(id, request.params(SendFileParams.self).flatMap(services.sender.sendFile))
        case .attachmentFetch:
            return reply(id, request.params(AttachmentFetchParams.self).flatMap(services.fetcher.fetch))
        case .initialize, .shutdown:
            preconditionFailure("\(method.rawValue) is answered inline")
        }
    }

    private func write<T: Encodable>(_ id: Int64, _ result: Result<T, HelperError>) {
        output.send(reply(id, result), onWritten: nil)
    }

    private func reply<T: Encodable>(_ id: Int64, _ result: Result<T, HelperError>) -> Data {
        switch result {
        case .success(let value): return Wire.encodeResult(id: id, value)
        case .failure(let error):
            log.event("request_failed", ["id": String(id), "kind": error.kind.rawValue])
            return Wire.encodeError(id: id, error)
        }
    }
}

/// `fermix-messages serve --home DIR`: the request loop on a background thread, the main
/// thread left to the run loop the consent dialog needs.
enum Serve {
    static func run(home: String) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let log = Logger.standardError()
        let runtime: Runtime
        do {
            runtime = try Runtime(home: home, log: log)
        } catch {
            log.event("serve_refused", ["error": String(describing: error)])
            exit(ExitCode.usage)
        }
        let output = StdoutWriter(fd: STDOUT_FILENO) {
            log.event("stdout_closed")
            exit(ExitCode.io)
        }
        let server: Server
        do {
            server = try runtime.makeServer(output: output)
        } catch {
            log.event("serve_failed", ["error": String(describing: error)])
            exit(ExitCode.io)
        }
        log.event("serving", ["version": HelperInfo.current().version])
        Thread.detachNewThread { readLoop(server, output: output, log: log) }
        dispatchMain()
    }

    private static func readLoop(_ server: Server, output: LineOutput, log: Logger) -> Never {
        let reader = LineReader(fd: STDIN_FILENO)
        while true {
            switch reader.next() {
            case .line(let line):
                switch server.handle(line) {
                case .continueReading: continue
                case .shutdown: exit(ExitCode.ok)
                case .protocolError:
                    output.flush()
                    exit(ExitCode.protocolError)
                }
            case .eof:
                log.event("stdin_closed")
                server.finish()
                output.flush()
                exit(ExitCode.ok)
            case .tooLong:
                log.event("protocol_error", ["reason": "line too long"])
                output.flush()
                exit(ExitCode.protocolError)
            case .failed(let code):
                log.event("stdin_failed", ["errno": String(code)])
                exit(ExitCode.io)
            }
        }
    }
}
