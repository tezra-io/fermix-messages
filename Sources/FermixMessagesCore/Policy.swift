import CryptoKit
import Foundation
import Security

/// The recipient policy (design §5.2, D10): the only boundary a same-user process cannot
/// rewrite silently. It lives in a generic-password item of the user's login keychain
/// that this signed code creates (default ACL: the creator only), changes only through
/// the helper's own consent dialog, and every data-plane call is checked against it.
public struct StoredPolicy: Codable, Equatable {
    public let posture: Posture
    public let ownerHandle: String
    public let handles: [String]
    public let confirmedAt: String?
    public let selfAliasesVerifiedAt: String?

    enum CodingKeys: String, CodingKey {
        case posture
        case ownerHandle = "owner_handle"
        case handles
        case confirmedAt = "confirmed_at"
        case selfAliasesVerifiedAt = "self_aliases_verified_at"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(posture, forKey: .posture)
        try container.encode(ownerHandle, forKey: .ownerHandle)
        try container.encode(handles, forKey: .handles)
        try container.encode(confirmedAt, forKey: .confirmedAt)
        try container.encode(selfAliasesVerifiedAt, forKey: .selfAliasesVerifiedAt)
    }

    /// Who Fermix may exchange messages with: the confirmed handles and the owner (an
    /// empty guest list means "no guests", never "no owner").
    public var allowed: Set<String> { Set(handles).union([ownerHandle]) }

    var view: PolicyView {
        PolicyView(posture: posture, ownerHandle: ownerHandle, handles: handles, confirmedAt: confirmedAt)
    }

    func sameRecipients(as other: StoredPolicy) -> Bool {
        posture == other.posture && ownerHandle == other.ownerHandle && handles == other.handles
    }

    static func encode(_ policy: StoredPolicy) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(policy)
    }

    static func decode(_ data: Data) throws -> StoredPolicy {
        try JSONDecoder().decode(StoredPolicy.self, from: data)
    }
}

public struct PolicyStoreError: Error, Equatable {
    public let status: OSStatus
    public let detail: String
}

public protocol PolicyStore: AnyObject {
    func load() -> Result<StoredPolicy?, PolicyStoreError>
    func save(_ policy: StoredPolicy) -> Result<Void, PolicyStoreError>
}

/// The login-keychain item. Never the data-protection keychain and never an explicit
/// access object: the default ACL of an item created by signed code trusts that code
/// only, so any other process's read raises the keychain dialog (Spike S10).
public final class KeychainPolicyStore: PolicyStore {
    public static let service = "io.tezra.fermix.messages"
    let account: String

    public init(home: String) throws {
        account = try Self.account(forHome: home)
    }

    /// `policy:` + the first 16 hex digits of sha256(realpath(home)): one item per home.
    static func account(forHome home: String) throws -> String {
        guard let real = realpath(home, nil) else {
            throw PolicyStoreError(status: errSecParam, detail: "home \(home): \(String(cString: strerror(errno)))")
        }
        defer { free(real) }
        let digest = SHA256.hash(data: Data(String(cString: real).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "policy:" + hex.prefix(16)
    }

    static func itemQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> Result<StoredPolicy?, PolicyStoreError> {
        var query = Self.itemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess, let data = item as? Data else {
            return .failure(PolicyStoreError(status: status, detail: "read"))
        }
        do {
            return .success(try StoredPolicy.decode(data))
        } catch {
            return .failure(PolicyStoreError(status: errSecDecode, detail: "item is not a policy: \(error)"))
        }
    }

    public func save(_ policy: StoredPolicy) -> Result<Void, PolicyStoreError> {
        let data: Data
        do {
            data = try StoredPolicy.encode(policy)
        } catch {
            return .failure(PolicyStoreError(status: errSecParam, detail: "encode: \(error)"))
        }
        var add = Self.itemQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Fermix Messages recipient policy"
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecSuccess { return .success(()) }
        guard added == errSecDuplicateItem else { return .failure(PolicyStoreError(status: added, detail: "add")) }
        let updated = SecItemUpdate(Self.itemQuery(account: account) as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        return updated == errSecSuccess ? .success(()) : .failure(PolicyStoreError(status: updated, detail: "update"))
    }
}

/// `policy.get`, `policy.set`, the probe's `policy` field and the data-plane gate.
final class PolicyService {
    static let notNormalized = "handle is not in normalized form (E.164 or email)"
    static let ownAccountGuests = "own_account admits only the owner's own conversation"

    private let store: PolicyStore
    private let prompter: ConsentPrompter
    private let now: () -> Date
    private let userSession: () -> Bool
    private let selfAliases: () -> Result<[String], DBOpenFailure>
    private let log: Logger

    init(store: PolicyStore, prompter: ConsentPrompter, now: @escaping () -> Date,
         userSession: @escaping () -> Bool, selfAliases: @escaping () -> Result<[String], DBOpenFailure>,
         log: Logger) {
        self.store = store
        self.prompter = prompter
        self.now = now
        self.userSession = userSession
        self.selfAliases = selfAliases
        self.log = log
    }

    func get() -> Result<PolicyView?, HelperError> {
        switch store.load() {
        case .success(let policy): return .success(policy?.view)
        case .failure(let error): return .failure(storeError(error))
        }
    }

    func state() -> PolicyState {
        switch store.load() {
        case .success(nil): return .absent
        case .success(let policy?): return policy.confirmedAt == nil ? .unconfirmed : .confirmed
        case .failure(let error):
            log.event("policy_read_failed", ["status": String(error.status), "detail": error.detail])
            return .unconfirmed
        }
    }

    /// The stored policy, when it exists and was confirmed; the specific class otherwise.
    func requireConfirmed() -> Result<StoredPolicy, HelperError> {
        switch store.load() {
        case .success(nil):
            return .failure(HelperError(.policyAbsent, "no recipient policy has been confirmed on this Mac"))
        case .success(let policy?) where policy.confirmedAt == nil:
            return .failure(HelperError(.policyUnconfirmed, "the recipient policy awaits confirmation"))
        case .success(let policy?):
            return .success(policy)
        case .failure(let error):
            return .failure(storeError(error))
        }
    }

    func set(_ params: PolicySetParams) -> Result<PolicySetResult, HelperError> {
        let candidate: StoredPolicy
        switch normalizedCandidate(params) {
        case .success(let value): candidate = value
        case .failure(let error): return .failure(error)
        }
        let stored: StoredPolicy?
        switch store.load() {
        case .success(let value): stored = value
        case .failure(let error): return .failure(storeError(error))
        }
        if let stored, let confirmedAt = stored.confirmedAt, stored.sameRecipients(as: candidate) {
            return .success(PolicySetResult(confirmedAt: confirmedAt))
        }
        return confirm(candidate)
    }

    private func normalizedCandidate(_ params: PolicySetParams) -> Result<StoredPolicy, HelperError> {
        guard case .success(let owner) = Handles.normalize(params.ownerHandle) else {
            return .failure(.policyViolation(handle: params.ownerHandle, Self.notNormalized))
        }
        let handles: [String]
        switch Handles.normalizeAll(params.handles + [owner]) {
        case .success(let value): handles = value
        case .failure(.notNormalizable(let raw)): return .failure(.policyViolation(handle: raw, Self.notNormalized))
        }
        guard params.posture == .ownAccount else {
            return .success(StoredPolicy(posture: params.posture, ownerHandle: owner, handles: handles,
                                         confirmedAt: nil, selfAliasesVerifiedAt: nil))
        }
        if let guest = handles.first(where: { $0 != owner }) {
            return .failure(.policyViolation(handle: guest, Self.ownAccountGuests))
        }
        return verifySelf(owner).map {
            StoredPolicy(posture: .ownAccount, ownerHandle: owner, handles: handles, confirmedAt: nil,
                         selfAliasesVerifiedAt: Timestamp.format(now()))
        }
    }

    /// §9.4: under own_account the owner must be one of the account's own aliases; an
    /// unreadable database or an empty alias set never confirms (fails closed).
    private func verifySelf(_ owner: String) -> Result<Void, HelperError> {
        switch selfAliases() {
        case .failure(let failure):
            return .failure(failure.helperError)
        case .success(let aliases) where aliases.contains(owner):
            return .success(())
        case .success(let aliases):
            log.event("owner_not_self", ["owner": Handles.redact(owner), "aliases": String(aliases.count)])
            return .failure(HelperError(.ownerNotSelf, "that handle is not one of this Mac's Messages account aliases",
                                        data: ["handle": .string(owner)]))
        }
    }

    private func confirm(_ candidate: StoredPolicy) -> Result<PolicySetResult, HelperError> {
        guard userSession() else {
            return .failure(HelperError(.noUserSession, "the confirmation dialog needs a logged-in console session"))
        }
        let request = ConsentRequest(posture: candidate.posture, owner: candidate.ownerHandle,
                                     handles: candidate.handles)
        let answer = prompter.ask(request)
        log.event("policy_consent", ["answer": answer.rawValue, "handles": String(candidate.handles.count)])
        guard answer == .approved else {
            return .failure(HelperError(.policyRefused, answer == .timedOut
                ? "the confirmation dialog was not answered in time" : "the owner declined the recipient policy"))
        }
        let confirmedAt = Timestamp.format(now())
        let confirmed = StoredPolicy(posture: candidate.posture, ownerHandle: candidate.ownerHandle,
                                     handles: candidate.handles, confirmedAt: confirmedAt,
                                     selfAliasesVerifiedAt: candidate.selfAliasesVerifiedAt)
        if case .failure(let error) = store.save(confirmed) { return .failure(storeError(error)) }
        return .success(PolicySetResult(confirmedAt: confirmedAt))
    }

    private func storeError(_ error: PolicyStoreError) -> HelperError {
        log.event("policy_store_failed", ["status": String(error.status), "detail": error.detail])
        if error.status == errSecInteractionNotAllowed {
            return HelperError(.noUserSession, "the keychain needs a logged-in session (OSStatus \(error.status))")
        }
        return HelperError(.policyUnconfirmed, "keychain \(error.detail) failed (OSStatus \(error.status))")
    }
}
