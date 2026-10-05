import Foundation
import Testing
@testable import FermixMessagesCore

/// A scripted Mac: Automation, Messages, sign-in and session states, and a record of the
/// grant actions taken.
final class FakeInspector: SystemInspector {
    var automationState: AutomationState = .notDetermined
    var automationAfterAsk: AutomationState = .granted
    var running = false
    var signed: Tri = .yes
    var session = true
    private(set) var actions: [String] = []

    func automation(ask: Bool) -> AutomationState {
        if ask {
            actions.append("ask_automation")
            automationState = automationAfterAsk
        }
        return running ? automationState : .unknown
    }

    func messagesRunning() -> Bool { running }

    func signedIn() -> Tri {
        actions.append("signed_in")
        return signed
    }

    func userSession() -> Bool { session }

    func launchMessages() -> Bool {
        actions.append("launch_messages")
        running = true
        return true
    }

    func registerBundle() {
        actions.append("lsregister")
    }

    func openFullDiskAccessPane() {
        actions.append("open_pane")
    }

    func revealBundle() {
        actions.append("reveal")
    }
}

@Suite struct ProbeTests {
    static func prober(_ location: MessagesLocation, inspector: FakeInspector,
                       store: InMemoryPolicyStore = InMemoryPolicyStore()) -> Prober {
        let log = LogCapture().logger
        let policy = PolicyService(store: store, prompter: ScriptedConsent(), now: { TestClock.noon },
                                   userSession: { true }, selfAliases: { .success([]) }, log: log)
        return Prober(location: location, inspector: inspector, policy: policy, log: log, helperVersion: "0.1.0-test")
    }

    @Test func aReadableDatabaseWithEveryGrantProbesGreen() {
        let fixture = ChatDBFixture()
        let friend = fixture.handle("+15550001111")
        let chat = fixture.chat("+15550001111", lastAddressed: "+15551234567")
        fixture.message(.init(handle: friend, chat: chat, destination: "owner@example.com"))
        let inspector = FakeInspector()
        inspector.running = true
        inspector.automationState = .granted
        let result = Self.prober(fixture.location, inspector: inspector,
                                 store: InMemoryPolicyStore(.dedicated())).probe()
        #expect(result.fullDiskAccess == .granted)
        #expect(result.db == .readable)
        #expect(result.automation == .granted)
        #expect(result.messagesRunning)
        #expect(result.signedIn == .yes)
        #expect(result.userSession)
        #expect(result.policy == .confirmed)
        #expect(result.selfAliases == ["+15551234567", "owner@example.com"])
    }

    @Test func signInIsUnknownWithoutAutomationAndIsNeverAsked() {
        let fixture = ChatDBFixture()
        let inspector = FakeInspector()
        inspector.running = true
        inspector.automationState = .denied
        let result = Self.prober(fixture.location, inspector: inspector).probe()
        #expect(result.automation == .denied)
        #expect(result.signedIn == .unknown)
        #expect(!inspector.actions.contains("signed_in"))
        #expect(!inspector.actions.contains("ask_automation"), "the probe never prompts")
    }

    @Test func messagesNotRunningIsUnknownAutomation() {
        let fixture = ChatDBFixture()
        let result = Self.prober(fixture.location, inspector: FakeInspector()).probe()
        #expect(result.automation == .unknown)
        #expect(!result.messagesRunning)
        #expect(result.policy == .absent)
    }

    @Test func aDeniedDatabaseIsAFullDiskAccessDenial() {
        guard getuid() != 0 else { return }
        let fixture = ChatDBFixture()
        #expect(chmod(fixture.location.chatDB, 0) == 0)
        let result = Self.prober(fixture.location, inspector: FakeInspector()).probe()
        #expect(result.fullDiskAccess == .denied)
        #expect(result.db == .unreadable)
        #expect(result.selfAliases == nil)
    }

    @Test func anUnlistableMessagesDirectoryIsADenial() {
        guard getuid() != 0 else { return }
        let directory = TestDirectory()
        let messages = directory.sub("Messages")
        #expect(chmod(messages, 0) == 0)
        let location = MessagesLocation(directory: messages, attachmentsRoot: messages, stagingRoot: messages,
                                        tildeHome: directory.path)
        let result = Self.prober(location, inspector: FakeInspector()).probe()
        #expect(result.fullDiskAccess == .denied)
        #expect(result.db == .unreadable)
    }

    @Test func aMissingDatabaseIsMissingAndNotADenial() {
        let directory = TestDirectory()
        let messages = directory.sub("Messages")
        let location = MessagesLocation(directory: messages, attachmentsRoot: messages, stagingRoot: messages,
                                        tildeHome: directory.path)
        let result = Self.prober(location, inspector: FakeInspector()).probe()
        #expect(result.fullDiskAccess == .granted)
        #expect(result.db == .missing)
        #expect(result.selfAliases == nil)
    }

    @Test func schemaDriftIsReported() {
        let fixture = ChatDBFixture(ddl: ChatDBFixture.ddl.replacingOccurrences(of: ", destination_caller_id TEXT",
                                                                                with: ""))
        let result = Self.prober(fixture.location, inspector: FakeInspector()).probe()
        #expect(result.db == .schemaUnexpected)
        #expect(result.fullDiskAccess == .granted)
    }
}

@Suite struct GrantTests {
    let fixture = ChatDBFixture()

    func granter(_ inspector: FakeInspector) -> Granter {
        Granter(inspector: inspector, prober: ProbeTests.prober(fixture.location, inspector: inspector))
    }

    @Test func automationBringsMessagesUpThenAsksOnce() throws {
        let inspector = FakeInspector()
        let result = try granter(inspector).grant(.automation).get()
        #expect(inspector.actions.prefix(2) == ["launch_messages", "ask_automation"])
        #expect(result.automation == .granted)
    }

    @Test func automationDoesNotRelaunchARunningMessages() throws {
        let inspector = FakeInspector()
        inspector.running = true
        _ = try granter(inspector).grant(.automation).get()
        #expect(!inspector.actions.contains("launch_messages"))
    }

    /// The pane opens last so System Settings, where the switch is, ends up in
    /// front of the Finder window the reveal brought up for a drag-in.
    @Test func fullDiskAccessRegistersRevealsThenOpensThePaneInFront() throws {
        let inspector = FakeInspector()
        _ = try granter(inspector).grant(.fullDiskAccess).get()
        #expect(inspector.actions == ["lsregister", "reveal", "open_pane"])
    }

    @Test func grantingNeedsAUserSession() {
        let inspector = FakeInspector()
        inspector.session = false
        #expect(granter(inspector).grant(.automation).failureValue?.kind == .noUserSession)
        #expect(inspector.actions.isEmpty)
    }

    @Test func automationStatusCodesMapToTheProbeVocabulary() {
        #expect(MacSystemInspector.automationState(noErr) == .granted)
        #expect(MacSystemInspector.automationState(-1743) == .denied)
        #expect(MacSystemInspector.automationState(-1744) == .notDetermined)
        #expect(MacSystemInspector.automationState(-600) == .unknown)
        #expect(MacSystemInspector.automationState(-50) == .unknown)
    }

    @Test func signInOutputMapsToTri() {
        #expect(MacSystemInspector.signedInState(ChildResult(termination: .exited(0), stdout: Data("true\n".utf8),
                                                              stderr: Data())) == .yes)
        #expect(MacSystemInspector.signedInState(ChildResult(termination: .exited(0), stdout: Data("false\n".utf8),
                                                              stderr: Data())) == .no)
        let noAccount = ChildResult(termination: .exited(1), stdout: Data(),
                                    stderr: Data("execution error: Can’t get account 1. (-1728)".utf8))
        #expect(MacSystemInspector.signedInState(noAccount) == .no)
        #expect(MacSystemInspector.signedInState(ChildResult(termination: .timedOut, stdout: Data(),
                                                              stderr: Data())) == .unknown)
    }
}
