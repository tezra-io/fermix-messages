import Foundation
import Testing
@testable import FermixMessagesCore

/// A sender over the synthetic chat.db, a real ledger, an in-memory policy and a fake
/// Messages that writes the rows the real app would.
final class SendHarness {
    let fixture = ChatDBFixture()
    let paths: HelperPaths
    let ledger: Ledger
    let store: InMemoryPolicyStore
    let messages: FakeMessages
    let log = LogCapture()
    var automation: AutomationState = .granted
    var fileCap: Int64 = 100 * 1024 * 1024
    private(set) var reconciled: [ReconciledEvent] = []
    let owner: Int64
    let ownerChat: Int64

    init(policy: StoredPolicy? = .dedicated(guests: ["guest@example.com"])) {
        paths = try! HelperPaths.resolve(home: fixture.directory.sub("fermix"))
        try! paths.prepare()
        ledger = try! Ledger.open(path: paths.ledger)
        store = InMemoryPolicyStore(policy)
        messages = FakeMessages(fixture)
        owner = fixture.handle("+15551234567")
        ownerChat = fixture.chat("+15551234567")
    }

    deinit { ledger.close() }

    lazy var policy = PolicyService(store: store, prompter: ScriptedConsent(), now: Date.init,
                                    userSession: { true }, selfAliases: { .success([]) }, log: log.logger)

    func sender() -> Sender {
        Sender(ledger: ledger, database: { [fixture] in ChatDB.open(fixture.location) }, scripting: messages,
               staging: Staging(root: fixture.location.stagingRoot, fileCap: fileCap, rootCap: 1 << 30),
               outbox: paths.outbox, policy: policy, automation: { [unowned self] in self.automation },
               now: Date.init, timing: VerifyTiming(timeout: 0.5, interval: 0.02), log: log.logger,
               onReconciled: { [unowned self] in self.reconciled.append($0) })
    }

    func outboxFile(_ name: String, bytes: Int = 3) -> String {
        let dir = fixture.directory.sub("fermix/imessage/outbox/\(UUID().uuidString)")
        let path = dir + "/" + name
        try! Data(repeating: 0x42, count: bytes).write(to: URL(fileURLWithPath: path))
        return path
    }
}

@Suite struct SenderTests {
    static func text(_ to: String = "+15551234567", _ text: String = "Your calendar is clear.",
                     key: String = "del-1:0") -> SendTextParams {
        SendTextParams(to: to, text: text, idempotencyKey: key)
    }

    @Test func aTextToAnExistingChatIsRecorded() throws {
        let harness = SendHarness()
        let result = try harness.sender().sendText(Self.text()).get()
        #expect(result.disposition == .recorded)
        #expect(result.guid != nil)
        #expect(harness.messages.commands == [ScriptCommand(mode: .chatText, target: "any;-;+15551234567",
                                                            payload: "Your calendar is clear.")])
        let row = try #require(try harness.ledger.find("del-1:0"))
        #expect(row.state == .recorded)
        #expect(row.guid == result.guid)
        #expect(row.rowid == result.rowid)
    }

    @Test func aTextToAHandleWithNoChatGoesToTheIMessageParticipant() throws {
        let harness = SendHarness()
        let result = try harness.sender().sendText(Self.text("Guest@Example.com")).get()
        #expect(result.disposition == .recorded)
        #expect(harness.messages.commands.first == ScriptCommand(mode: .participantText, target: "guest@example.com",
                                                                 payload: "Your calendar is clear."))
    }

    @Test func theLedgerRowIsDispatchedWithItsWatermarkBeforeAppleScriptRuns() throws {
        let harness = SendHarness()
        harness.fixture.message(.init(handle: harness.owner, chat: harness.ownerChat))
        var seen: LedgerRow?
        harness.messages.during = { _ in seen = try? harness.ledger.find("del-1:0") }
        _ = try harness.sender().sendText(Self.text()).get()
        #expect(seen?.state == .dispatched)
        #expect(seen?.watermark == 1)
        #expect(seen?.textSHA256 == FileCopy.sha256("Your calendar is clear."))
    }

    @Test func aRecipientOutsideThePolicyFailsWithoutSendingOrRecording() throws {
        let harness = SendHarness()
        for to in ["+15559999999", "not a handle"] {
            let result = try harness.sender().sendText(Self.text(to, key: to)).get()
            #expect(result == .failed(.policyViolation))
            #expect(try harness.ledger.find(to) == nil)
        }
        #expect(harness.messages.commands.isEmpty)
    }

    @Test func theSameIdempotencyKeyReturnsTheLedgerOutcomeAndSendsNothing() throws {
        let harness = SendHarness()
        let first = try harness.sender().sendText(Self.text()).get()
        let second = try harness.sender().sendText(Self.text()).get()
        #expect(first == second)
        #expect(harness.messages.commands.count == 1)
    }

    @Test func aGhostRowIsUncertain() throws {
        let harness = SendHarness()
        harness.messages.behaviour = .ghostRow
        #expect(try harness.sender().sendText(Self.text()).get() == .uncertain)
        #expect(try harness.ledger.find("del-1:0")?.state == .uncertain)
        #expect(try harness.ledger.find("del-1:0")?.detail?.contains("ghost") == true)
    }

    @Test func noRowIsUncertainAndUncertainIsNeverRetried() throws {
        let harness = SendHarness()
        harness.messages.behaviour = .nothing
        #expect(try harness.sender().sendText(Self.text()).get() == .uncertain)
        harness.messages.behaviour = .recordRow
        #expect(try harness.sender().sendText(Self.text()).get() == .uncertain)
        #expect(harness.messages.commands.count == 1)
    }

    @Test func aTimeoutWithNoRowIsUncertainWithTheTimeoutClass() throws {
        let harness = SendHarness()
        harness.messages.behaviour = .timeout
        let result = try harness.sender().sendText(Self.text()).get()
        #expect(result.disposition == .uncertain)
        #expect(result.failureClass == .sendTimeout)
    }

    @Test func aTimeoutWhoseRowAppearsIsRecorded() throws {
        let harness = SendHarness()
        harness.messages.behaviour = .recordRowAfterTimeout
        #expect(try harness.sender().sendText(Self.text()).get().disposition == .recorded)
    }

    @Test func appleScriptRefusalsArePreDispatchFailures() throws {
        let cases: [(Int, ErrorKind)] = [(-1743, .automationRefused), (-1728, .chatNotFound)]
        for (code, kind) in cases {
            let harness = SendHarness()
            harness.messages.behaviour = .error(code, "execution error: refused (\(code))")
            #expect(try harness.sender().sendText(Self.text()).get() == .failed(kind))
            let row = try #require(try harness.ledger.find("del-1:0"))
            #expect(row.state == .failed)
            #expect(row.detail?.contains("(\(code))") == true, "the AppleScript text reaches the ledger")
        }
    }

    @Test func theDataPlaneGatesComeFirst() {
        let missing = SendHarness()
        missing.fixture.writer.close()
        _ = unlink(missing.fixture.location.chatDB)
        #expect(missing.sender().sendText(Self.text()).failureValue?.kind == .dbMissing)

        let noPolicy = SendHarness(policy: nil)
        #expect(noPolicy.sender().sendText(Self.text()).failureValue?.kind == .policyAbsent)

        let unconfirmed = SendHarness(policy: .dedicated(confirmedAt: nil))
        #expect(unconfirmed.sender().sendText(Self.text()).failureValue?.kind == .policyUnconfirmed)

        for state in [AutomationState.denied, .notDetermined] {
            let noAutomation = SendHarness()
            noAutomation.automation = state
            let error = noAutomation.sender().sendText(Self.text()).failureValue
            #expect(error == .permissionDenied(.automation, "Automation of Messages is not granted"))
            #expect(noAutomation.messages.commands.isEmpty)
        }
    }

    @Test func ownAccountSendsOnlyToTheOwner() throws {
        let harness = SendHarness(policy: .own())
        #expect(try harness.sender().sendText(Self.text("guest@example.com", key: "a")).get()
            == .failed(.policyViolation))
        #expect(try harness.sender().sendText(Self.text(key: "b")).get().disposition == .recorded)
    }
}

@Suite struct SendFileTests {
    static func file(_ path: String, key: String = "f-1") -> SendFileParams {
        SendFileParams(to: "+15551234567", path: path, mime: "image/jpeg", idempotencyKey: key)
    }

    @Test func anOutboxFileIsStagedSentAndRecorded() throws {
        let harness = SendHarness()
        let source = harness.outboxFile("photo.jpg")
        let result = try harness.sender().sendFile(Self.file(source)).get()
        #expect(result.disposition == .recorded)
        let command = try #require(harness.messages.commands.first)
        #expect(command.mode == .chatFile)
        #expect(command.payload.hasPrefix(harness.fixture.location.stagingRoot + "/"))
        #expect(command.payload.hasSuffix("/photo.jpg"))
        #expect(FileManager.default.contentsEqual(atPath: command.payload, andPath: source))
        #expect(try harness.ledger.find("f-1")?.fileSHA256 == FileCopy.sha256(Data(repeating: 0x42, count: 3)))
    }

    @Test func aPathOutsideTheOutboxIsRefused() throws {
        let harness = SendHarness()
        let outside = harness.fixture.directory.sub("elsewhere") + "/x.jpg"
        try Data("x".utf8).write(to: URL(fileURLWithPath: outside))
        #expect(try harness.sender().sendFile(Self.file(outside)).get() == .failed(.pathRefused))
        #expect(try harness.ledger.find("f-1")?.state == .failed)
        #expect(harness.messages.commands.isEmpty)
    }

    @Test func aPathThroughASymlinkIsRefused() throws {
        let harness = SendHarness()
        let outside = harness.fixture.directory.sub("elsewhere")
        try Data("x".utf8).write(to: URL(fileURLWithPath: outside + "/x.jpg"))
        let link = harness.paths.outbox + "/sneaky"
        #expect(symlink(outside, link) == 0)
        #expect(try harness.sender().sendFile(Self.file(link + "/x.jpg")).get() == .failed(.pathRefused))
        #expect(harness.messages.commands.isEmpty)
    }

    @Test func aFileOverTheCapIsTooLarge() throws {
        let harness = SendHarness()
        harness.fileCap = 10
        let big = harness.outboxFile("big.bin", bytes: 11)
        #expect(try harness.sender().sendFile(Self.file(big)).get() == .failed(.attachmentTooLarge))
        #expect(harness.messages.commands.isEmpty)
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: harness.fixture.location.stagingRoot)) ?? []
        #expect(staged.isEmpty, "nothing is left staged")
    }
}

@Suite struct ReconcileTests {
    /// A crash at each point of a send, then a restart: the next lane job reconciles.
    @Test func aCrashBeforeTheLedgerWriteLeavesNothingAndARetrySends() throws {
        let harness = SendHarness()
        let result = try harness.sender().sendText(SenderTests.text()).get()
        #expect(result.disposition == .recorded)
        #expect(harness.reconciled.isEmpty)
    }

    @Test func aCrashAfterDispatchBeforeAppleScriptReconcilesUncertain() throws {
        let harness = SendHarness()
        try harness.ledger.insertDispatched(LedgerTests.dispatched("crashed", text: "lost", watermark: 0))
        _ = try harness.sender().sendText(SenderTests.text(key: "next")).get()
        #expect(harness.reconciled == [ReconciledEvent(idempotencyKey: "crashed", disposition: .uncertain, guid: nil)])
        #expect(try harness.ledger.find("crashed")?.state == .uncertain)
        #expect(try harness.sender().sendText(SenderTests.text("+15551234567", "lost", key: "crashed")).get()
            == .uncertain, "the replay returns the reconciled word and sends nothing")
    }

    @Test func aCrashAfterTheSendReconcilesRecorded() throws {
        let harness = SendHarness()
        try harness.ledger.insertDispatched(LedgerTests.dispatched("crashed", text: "made it", watermark: 0))
        let row = harness.fixture.message(.init(text: "made it", fromMe: true, handle: harness.owner,
                                                chat: harness.ownerChat))
        let events = harness.sender().reconcile()
        #expect(events == [ReconciledEvent(idempotencyKey: "crashed", disposition: .recorded, guid: row.guid)])
        #expect(try harness.ledger.find("crashed")?.rowid == row.rowid)
    }

    @Test func aCrashAfterTheOutcomeNeedsNoReconciliation() throws {
        let harness = SendHarness()
        _ = try harness.sender().sendText(SenderTests.text()).get()
        #expect(harness.sender().reconcile().isEmpty)
    }

    @Test func reconciliationWaitsForAReadableDatabase() throws {
        let harness = SendHarness()
        try harness.ledger.insertDispatched(LedgerTests.dispatched("crashed", watermark: 0))
        harness.fixture.writer.close()
        _ = unlink(harness.fixture.location.chatDB)
        #expect(harness.sender().reconcile().isEmpty)
        #expect(try harness.ledger.find("crashed")?.state == .dispatched)
    }
}

@Suite struct AppleScriptTests {
    @Test func valuesTravelInArgvAndNeverInTheScript() {
        let hostile = "\" & (do shell script \"touch /tmp/pwned\") & \""
        let arguments = OsascriptMessages.arguments(for: ScriptCommand(mode: .chatText, target: "any;-;x",
                                                                       payload: hostile))
        let scriptLines = arguments.enumerated().filter { $0.offset > 0 && arguments[$0.offset - 1] == "-e" }
            .map(\.element)
        #expect(!scriptLines.joined().contains(hostile))
        #expect(scriptLines.first == "on run argv")
        #expect(Array(arguments.suffix(3)) == ["chat_text", "any;-;x", hostile])
    }

    @Test func theErrorNumberIsParsedFromOsascriptsMessage() {
        #expect(OsascriptMessages.errorNumber("execution error: Not authorized to send Apple events to Messages. (-1743)")
            == -1743)
        #expect(OsascriptMessages.errorNumber("82:93: execution error: Can’t get participant \"x\". (-1728)") == -1728)
        #expect(OsascriptMessages.errorNumber("something else") == nil)
    }
}
