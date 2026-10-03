import Foundation
import Security
import Testing
@testable import FermixMessagesCore

@Suite struct PolicyTests {
    final class Harness {
        let store: InMemoryPolicyStore
        let consent: ScriptedConsent
        var aliases: Result<[String], DBOpenFailure> = .success(["+15551234567"])
        var session = true
        let log = LogCapture()
        lazy var service = PolicyService(
            store: store, prompter: consent, now: { TestClock.noon },
            userSession: { [unowned self] in self.session },
            selfAliases: { [unowned self] in self.aliases }, log: log.logger)

        init(stored: StoredPolicy? = nil, answer: ConsentAnswer = .approved) {
            store = InMemoryPolicyStore(stored)
            consent = ScriptedConsent(answer)
        }
    }

    static func params(_ posture: Posture = .dedicatedAccount, owner: String = "+15551234567",
                       handles: [String] = ["+15551234567"]) -> PolicySetParams {
        PolicySetParams(posture: posture, ownerHandle: owner, handles: handles)
    }

    @Test func anUnchangedPolicyReturnsAtOnceWithoutADialog() throws {
        let harness = Harness(stored: .dedicated(guests: ["guest@example.com"]))
        let result = try harness.service.set(Self.params(handles: ["Guest@Example.com", "+1 555 123 4567"])).get()
        #expect(result.confirmedAt == "2026-10-03T11:00:00.000Z")
        #expect(harness.consent.requests.isEmpty)
        #expect(harness.store.saves == 0)
    }

    @Test func aChangedPolicyShowsOneDialogNamingEveryHandleAndIsStoredOnApprove() throws {
        let harness = Harness(stored: .dedicated())
        let result = try harness.service.set(Self.params(handles: ["+15551234567", "guest@example.com"])).get()
        #expect(result.confirmedAt == "2026-10-03T12:00:00Z")
        #expect(harness.consent.requests.count == 1)
        let request = try #require(harness.consent.requests.first)
        #expect(request.title == "Allow Fermix to exchange iMessages with +1 555 123 4567 and guest@example.com?")
        #expect(request.detail.contains("dedicated account"))
        #expect(harness.store.current == StoredPolicy(
            posture: .dedicatedAccount, ownerHandle: "+15551234567", handles: ["+15551234567", "guest@example.com"],
            confirmedAt: "2026-10-03T12:00:00Z", selfAliasesVerifiedAt: nil))
    }

    @Test func theOwnerIsAlwaysInTheConfirmedSet() throws {
        let harness = Harness()
        _ = try harness.service.set(Self.params(handles: [])).get()
        #expect(harness.store.current?.handles == ["+15551234567"])
        #expect(harness.consent.requests.first?.title == "Allow Fermix to exchange iMessages with +1 555 123 4567?")
    }

    @Test func cancelIsPolicyRefusedAndNothingIsWritten() {
        for answer in [ConsentAnswer.cancelled, .timedOut] {
            let harness = Harness(stored: .dedicated(), answer: answer)
            let error = harness.service.set(Self.params(handles: ["guest@example.com"])).failureValue
            #expect(error?.kind == .policyRefused)
            #expect(harness.store.current == .dedicated())
        }
    }

    @Test func aHandleOutsideNormalizedFormIsAViolationBeforeAnyDialog() {
        let harness = Harness()
        let error = harness.service.set(Self.params(handles: ["+15551234567", "555-1234"])).failureValue
        #expect(error == .policyViolation(handle: "555-1234", "handle is not in normalized form (E.164 or email)"))
        let owner = harness.service.set(Self.params(owner: "me", handles: [])).failureValue
        #expect(owner?.kind == .policyViolation)
        #expect(owner?.data["handle"] == .string("me"))
        #expect(harness.consent.requests.isEmpty)
    }

    @Test func ownAccountRequiresTheOwnerToBeASelfAlias() throws {
        let friend = Harness()
        friend.aliases = .success(["+15551234567"])
        let error = friend.service.set(Self.params(.ownAccount, owner: "+15550001111", handles: [])).failureValue
        #expect(error?.kind == .ownerNotSelf)
        #expect(friend.consent.requests.isEmpty)

        let empty = Harness()
        empty.aliases = .success([])
        #expect(empty.service.set(Self.params(.ownAccount, handles: [])).failureValue?.kind == .ownerNotSelf)

        let me = Harness()
        let result = try me.service.set(Self.params(.ownAccount, handles: [])).get()
        #expect(result.confirmedAt == "2026-10-03T12:00:00Z")
        #expect(me.store.current?.selfAliasesVerifiedAt == "2026-10-03T12:00:00Z")
        #expect(me.consent.requests.first?.detail.contains("own account") == true)
    }

    @Test func ownAccountNeverConfirmsBlind() {
        let cases: [(DBOpenFailure, ErrorKind)] = [
            (.permissionDenied("authorization denied"), .permissionDenied),
            (.missing, .dbMissing),
            (.unreadable("disk I/O error"), .dbUnreadable),
        ]
        for (failure, kind) in cases {
            let harness = Harness()
            harness.aliases = .failure(failure)
            #expect(harness.service.set(Self.params(.ownAccount, handles: [])).failureValue?.kind == kind)
            #expect(harness.consent.requests.isEmpty)
        }
    }

    @Test func ownAccountAdmitsNoGuests() {
        let harness = Harness()
        let error = harness.service.set(Self.params(.ownAccount, handles: ["+15551234567", "friend@example.com"]))
        #expect(error.failureValue == .policyViolation(
            handle: "friend@example.com", "own_account admits only the owner's own conversation"))
    }

    @Test func theDialogNeedsAUserSession() {
        let harness = Harness()
        harness.session = false
        #expect(harness.service.set(Self.params()).failureValue?.kind == .noUserSession)
        #expect(harness.consent.requests.isEmpty)
    }

    @Test func getReturnsTheStoredItemOrNull() throws {
        #expect(try Harness().service.get().get() == nil)
        let view = try #require(try Harness(stored: .dedicated(guests: ["g@example.com"])).service.get().get())
        #expect(view.handles == ["+15551234567", "g@example.com"])
        #expect(view.confirmedAt == "2026-10-03T11:00:00.000Z")
    }

    @Test func theDataPlaneGateNamesTheState() {
        #expect(Harness().service.requireConfirmed().failureValue?.kind == .policyAbsent)
        #expect(Harness(stored: .dedicated(confirmedAt: nil)).service.requireConfirmed().failureValue?.kind
            == .policyUnconfirmed)
        let broken = Harness(stored: .dedicated())
        broken.store.failure = PolicyStoreError(status: errSecAuthFailed, detail: "read")
        #expect(broken.service.requireConfirmed().failureValue?.kind == .policyUnconfirmed)
        #expect(broken.service.state() == .unconfirmed)
        #expect(Harness(stored: .dedicated()).service.state() == .confirmed)
        #expect(Harness().service.state() == .absent)
    }

    @Test func theEffectiveSetIsTheHandlesPlusTheOwner() {
        let policy = StoredPolicy(posture: .dedicatedAccount, ownerHandle: "+15551234567",
                                  handles: ["g@example.com"], confirmedAt: nil, selfAliasesVerifiedAt: nil)
        #expect(policy.allowed == ["+15551234567", "g@example.com"])
    }
}

@Suite struct KeychainPolicyStoreTests {
    @Test func theAccountIsKeyedByTheRealPathOfTheHome() throws {
        let directory = TestDirectory()
        let home = directory.sub("home")
        let link = directory.path + "/link"
        #expect(symlink(home, link) == 0)
        let direct = try KeychainPolicyStore.account(forHome: home)
        #expect(direct.hasPrefix("policy:"))
        #expect(direct.count == "policy:".count + 16)
        #expect(direct.dropFirst("policy:".count).allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(try KeychainPolicyStore.account(forHome: link) == direct)
        #expect(try KeychainPolicyStore.account(forHome: directory.sub("other")) != direct)
        #expect(throws: PolicyStoreError.self) { try KeychainPolicyStore.account(forHome: directory.path + "/none") }
    }

    @Test func theItemIsALoginKeychainGenericPasswordWithTheDefaultAcl() {
        let query = KeychainPolicyStore.itemQuery(account: "policy:0123456789abcdef")
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "io.tezra.fermix.messages")
        #expect(query[kSecAttrAccount as String] as? String == "policy:0123456789abcdef")
        #expect(query[kSecUseDataProtectionKeychain as String] == nil)
        #expect(query[kSecAttrAccess as String] == nil)
        #expect(query[kSecAttrAccessGroup as String] == nil)
    }

    @Test func theStoredFormRoundTrips() throws {
        let policy = StoredPolicy.own()
        let data = try StoredPolicy.encode(policy)
        #expect(try StoredPolicy.decode(data) == policy)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"self_aliases_verified_at\""))
        #expect(text.contains("\"owner_handle\""))
    }
}

@Suite struct LoggerTests {
    @Test func oneLinePerEventWithQuotedValues() {
        let capture = LogCapture()
        capture.logger.event("send_recorded", ["to": Handles.redact("+15551234567"), "detail": "a \"b\"\nc"])
        #expect(capture.lines.count == 1)
        let line = capture.lines.first ?? ""
        #expect(line.contains("fermix-messages send_recorded"))
        #expect(line.contains("to=+1555…4567"))
        #expect(line.contains("detail=\"a \\\"b\\\"\\nc\""))
        #expect(!line.contains("\n"))
    }
}
