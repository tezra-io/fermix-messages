import Foundation
import Testing
@testable import FermixMessagesCore

/// The wire as written by the server: responses and notifications, in order.
final class CapturingOutput: LineOutput, NotificationSink {
    private let lock = NSLock()
    private var collected: [Data] = []

    func send(_ line: Data, onWritten: (() -> Void)?) {
        lock.lock()
        collected.append(line)
        lock.unlock()
        onWritten?()
    }

    func notify(_ line: Data, onWritten: @escaping () -> Void) {
        send(line, onWritten: onWritten)
    }

    func flush() {}

    var objects: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return collected.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func response(_ id: Int, timeout: TimeInterval = 5) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = objects.first(where: { ($0["id"] as? NSNumber)?.intValue == id }) { return found }
            Thread.sleep(forTimeInterval: 0.005)
        } while Date() < deadline
        return nil
    }

    func errorKind(_ id: Int) -> String? {
        (response(id)?["error"] as? [String: Any])?["kind"] as? String
    }

    func result(_ id: Int) -> [String: Any]? {
        response(id)?["result"] as? [String: Any]
    }
}

final class BlockingInspector: SystemInspector {
    let gate = DispatchSemaphore(value: 0)
    func automation(ask: Bool) -> AutomationState { .granted }
    func messagesRunning() -> Bool {
        gate.wait()
        return true
    }
    func signedIn() -> Tri { .yes }
    func userSession() -> Bool { true }
    func launchMessages() -> Bool { true }
    func registerBundle() {}
    func openFullDiskAccessPane() {}
    func revealBundle() {}
}

final class ServerHarness {
    let watch: WatchHarness
    let output = CapturingOutput()
    let inspector: SystemInspector

    init(policy: StoredPolicy? = .dedicated(guests: ["guest@example.com"]), inspector: SystemInspector? = nil) {
        watch = WatchHarness(policy: policy)
        let fake = FakeInspector()
        fake.running = true
        fake.automationState = .granted
        self.inspector = inspector ?? fake
    }

    lazy var server: Server = {
        let base = watch.base
        let prober = Prober(location: watch.fixture.location, inspector: inspector, policy: base.policy,
                            log: base.log.logger, helperVersion: "0.1.0-test")
        let sender = Sender(ledger: base.ledger, database: { [location = watch.fixture.location] in
                                ChatDB.open(location)
                            }, scripting: base.messages,
                            staging: Staging(root: watch.fixture.location.stagingRoot, fileCap: 1 << 20, rootCap: 1 << 30),
                            outbox: base.paths.outbox, policy: base.policy, automation: { .granted }, now: Date.init,
                            timing: VerifyTiming(timeout: 0.5, interval: 0.02), log: base.log.logger,
                            onReconciled: { [output] event in
                                output.notify(Wire.encodeNotification(.sendReconciled, event)) {}
                            })
        let services = Server.Services(
            policy: base.policy, prober: prober, granter: Granter(inspector: inspector, prober: prober),
            sender: sender, watcher: Watcher(location: watch.fixture.location, feed: watch.feed, sink: output,
                                             log: base.log.logger, now: Date.init),
            feed: watch.feed,
            fetcher: AttachmentFetcher(feed: watch.feed, inbox: base.paths.inbox, converter: FakeConverter(),
                                       cap: 1 << 20, log: base.log.logger, now: Date.init),
            ledger: base.ledger,
            info: HelperInfo(version: "0.1.0-test", bundleId: "io.tezra.fermix.messages", macos: "27.0.0"),
            location: watch.fixture.location)
        return Server(services: services, output: output, log: base.log.logger)
    }()

    @discardableResult
    func send(_ json: String) -> LineVerdict {
        server.handle(Data(json.utf8))
    }

    func initialize() {
        send(#"{"id":0,"method":"initialize","params":{"protocol_version":1,"client":"test"}}"#)
        precondition(output.result(0) != nil, "initialize did not answer")
    }
}

@Suite struct ServerTests {
    @Test func everythingBeforeInitializeIsNotInitialized() {
        let harness = ServerHarness()
        harness.send(#"{"id":1,"method":"probe"}"#)
        harness.send(#"{"id":2,"method":"no.such.method"}"#)
        harness.send(#"{"id":3,"method":"shutdown"}"#)
        #expect(harness.output.errorKind(1) == "not_initialized")
        #expect(harness.output.errorKind(2) == "not_initialized")
        #expect(harness.output.errorKind(3) == "not_initialized")
    }

    @Test func initializeReportsVersionsAndTheGenerationWithoutOpeningTheDatabase() throws {
        let harness = ServerHarness()
        harness.send(#"{"id":1,"method":"initialize","params":{"protocol_version":2,"client":"test"}}"#)
        #expect(harness.output.errorKind(1) == "protocol_mismatch")
        let data = (harness.output.response(1)?["error"] as? [String: Any])?["data"] as? [String: Any]
        #expect((data?["helper"] as? NSNumber)?.intValue == 1)
        harness.send(#"{"id":2,"method":"initialize","params":{"protocol_version":1,"client":"test"}}"#)
        let result = try #require(harness.output.result(2))
        #expect((result["protocol_version"] as? NSNumber)?.intValue == 1)
        #expect(result["helper_version"] as? String == "0.1.0-test")
        #expect(result["bundle_id"] as? String == "io.tezra.fermix.messages")
        let generation = try #require(ChatDB.generation(of: harness.watch.fixture.location.chatDB))
        let wire = try #require(result["db_generation"] as? [String: Any])
        #expect((wire["inode"] as? NSNumber)?.uint64Value == generation.inode)
        #expect(wire["birth_time"] as? String == generation.birthTime)
    }

    @Test func unknownMethodsAndMalformedParamsAreProtocolMismatchAndServingContinues() {
        let harness = ServerHarness()
        harness.initialize()
        #expect(harness.send(#"{"id":1,"method":"messages.delete"}"#) == .continueReading)
        harness.send(#"{"id":2,"method":"messages.after","params":{"since_rowid":"x","limit":1}}"#)
        harness.send(#"{"id":3,"method":"policy.get"}"#)
        #expect(harness.output.errorKind(1) == "protocol_mismatch")
        #expect(harness.output.errorKind(2) == "protocol_mismatch")
        #expect(harness.output.response(3)?.keys.contains("result") == true)
    }

    @Test func aMalformedLineEndsServingWithAProtocolError() {
        let harness = ServerHarness()
        guard case .protocolError = harness.send("{not json") else {
            Issue.record("expected a protocol error")
            return
        }
    }

    @Test func theControlPlaneAnswersFromZeroPermissions() throws {
        let harness = ServerHarness(policy: nil)
        harness.watch.fixture.closeWriter()
        _ = unlink(harness.watch.fixture.location.chatDB)
        harness.initialize()
        harness.send(#"{"id":1,"method":"probe"}"#)
        harness.send(#"{"id":2,"method":"policy.get"}"#)
        harness.send(#"{"id":3,"method":"messages.after","params":{"since_rowid":0,"limit":5}}"#)
        harness.send(#"{"id":4,"method":"watch.subscribe","params":{"since_rowid":null,"replay":null,"buffer_limit":8}}"#)
        harness.send(#"{"id":5,"method":"send.text","params":{"to":"+15551234567","text":"x","idempotency_key":"k"}}"#)
        harness.send(#"{"id":6,"method":"attachment.fetch","params":{"message_guid":"g","index":0,"convert":false}}"#)
        let probe = try #require(harness.output.result(1))
        #expect(probe["db"] as? String == "missing")
        #expect(probe["policy"] as? String == "absent")
        #expect(harness.output.response(2)?["result"] is NSNull)
        #expect(harness.output.errorKind(3) == "db_missing")
        #expect(harness.output.errorKind(4) == "db_missing")
        #expect(harness.output.errorKind(5) == "db_missing")
        #expect(harness.output.errorKind(6) == "attachment_not_admitted")
    }

    @Test func theDataPlaneNamesAnAbsentPolicy() {
        let harness = ServerHarness(policy: nil)
        harness.initialize()
        harness.send(#"{"id":1,"method":"messages.after","params":{"since_rowid":0,"limit":5}}"#)
        harness.send(#"{"id":2,"method":"send.text","params":{"to":"+15551234567","text":"x","idempotency_key":"k"}}"#)
        #expect(harness.output.errorKind(1) == "policy_absent")
        #expect(harness.output.errorKind(2) == "policy_absent")
    }

    @Test func moreThan32OutstandingRequestsAreBusy() {
        let inspector = BlockingInspector()
        let harness = ServerHarness(inspector: inspector)
        harness.initialize()
        for id in 1...33 {
            harness.send(#"{"id":\#(id),"method":"probe"}"#)
        }
        #expect(harness.output.errorKind(33) == "busy")
        for _ in 1...32 { inspector.gate.signal() }
        #expect(harness.output.result(32) != nil)
        harness.send(#"{"id":34,"method":"policy.get"}"#)
        #expect(harness.output.response(34)?.keys.contains("result") == true)
    }

    @Test func twoConcurrentIdenticalSendsSerializeOnTheLane() throws {
        let harness = ServerHarness()
        harness.initialize()
        let request = #"{"id":ID,"method":"send.text","params":{"to":"+15551234567","text":"hi","idempotency_key":"same"}}"#
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            harness.send(request.replacingOccurrences(of: "ID", with: String(index + 1)))
        }
        let first = try #require(harness.output.result(1))
        let second = try #require(harness.output.result(2))
        #expect(first["disposition"] as? String == "recorded")
        #expect(second["guid"] as? String == first["guid"] as? String)
        #expect(harness.watch.base.messages.commands.count == 1)
    }

    @Test func dispatchedSendsAreReconciledAndAnnouncedAfterInitialize() throws {
        let harness = ServerHarness()
        try harness.watch.base.ledger.insertDispatched(LedgerTests.dispatched("left-over", watermark: 0))
        harness.initialize()
        let deadline = Date().addingTimeInterval(5)
        var event: [String: Any]?
        repeat {
            event = harness.output.objects.first { $0["event"] as? String == "send.reconciled" }
            Thread.sleep(forTimeInterval: 0.01)
        } while event == nil && Date() < deadline
        let params = try #require(event?["params"] as? [String: Any])
        #expect(params["idempotency_key"] as? String == "left-over")
        #expect(params["disposition"] as? String == "uncertain")
    }

    @Test func shutdownAnswersClosesTheLedgerAndEndsServing() throws {
        let harness = ServerHarness()
        harness.initialize()
        harness.send(#"{"id":1,"method":"send.text","params":{"to":"+15551234567","text":"hi","idempotency_key":"k1"}}"#)
        #expect(harness.output.result(1)?["disposition"] as? String == "recorded")
        #expect(harness.send(#"{"id":2,"method":"shutdown"}"#) == .shutdown)
        #expect(harness.output.result(2) != nil)
        #expect(throws: SQLiteError.self) { try harness.watch.base.ledger.find("k1") }
    }

    @Test func shutdownDuringASendIsPromptAndLeavesTheRowDispatched() throws {
        let harness = ServerHarness()
        let gate = DispatchSemaphore(value: 0)
        harness.watch.base.messages.during = { _ in gate.wait() }
        harness.initialize()
        harness.send(#"{"id":1,"method":"send.text","params":{"to":"+15551234567","text":"hi","idempotency_key":"k1"}}"#)
        let deadline = Date().addingTimeInterval(5)
        while harness.watch.base.messages.commands.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let start = Date()
        #expect(harness.send(#"{"id":2,"method":"shutdown"}"#) == .shutdown)
        #expect(Date().timeIntervalSince(start) < 3, "the engine closes the port 2 s after shutdown")
        #expect(harness.output.result(2) != nil)
        gate.signal()
        let reopened = try Ledger.open(path: harness.watch.base.paths.ledger)
        defer { reopened.close() }
        #expect(try reopened.find("k1")?.state == .dispatched, "reconciled at the next start")
    }
}

@Suite struct LineReaderTests {
    @Test func linesAreSplitAndOverlongLinesAreRefused() throws {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        let text = "{\"a\":1}\n{\"b\":2}\r\n" + String(repeating: "x", count: 100) + "\n"
        _ = text.withCString { write(fds[1], $0, strlen($0)) }
        close(fds[1])
        let reader = LineReader(fd: fds[0], maxLine: 64)
        defer { close(fds[0]) }
        #expect(reader.next() == .line(Data("{\"a\":1}".utf8)))
        #expect(reader.next() == .line(Data("{\"b\":2}".utf8)))
        #expect(reader.next() == .tooLong)
    }

    @Test func endOfInputIsReported() {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        _ = "{}".withCString { write(fds[1], $0, 2) }
        close(fds[1])
        let reader = LineReader(fd: fds[0], maxLine: 64)
        defer { close(fds[0]) }
        #expect(reader.next() == .line(Data("{}".utf8)))
        #expect(reader.next() == .eof)
    }
}

@Suite struct StdoutWriterTests {
    @Test func linesAreWrittenWholeAndInOrder() throws {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        let writer = StdoutWriter(fd: fds[1]) { Issue.record("broken") }
        DispatchQueue.concurrentPerform(iterations: 50) { index in
            writer.send(Data("{\"n\":\(index)}".utf8), onWritten: nil)
        }
        writer.flush()
        close(fds[1])
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fds[0], &buffer, buffer.count)
            if count <= 0 { break }
            collected.append(contentsOf: buffer[0..<count])
        }
        close(fds[0])
        let lines = String(decoding: collected, as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 50)
        #expect(lines.allSatisfy { $0.hasPrefix("{\"n\":") && $0.hasSuffix("}") })
    }
}
