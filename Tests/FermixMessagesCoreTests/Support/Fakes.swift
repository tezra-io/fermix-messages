import Foundation
@testable import FermixMessagesCore

/// Collects log lines so tests can assert what reached "stderr".
final class LogCapture {
    private let lock = NSLock()
    private var collected: [String] = []

    lazy var logger = Logger { [weak self] line in self?.append(line) }

    private func append(_ line: String) {
        lock.lock()
        collected.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

/// The policy item, in memory: tests never touch the real keychain.
final class InMemoryPolicyStore: PolicyStore {
    private let lock = NSLock()
    private var stored: StoredPolicy?
    var failure: PolicyStoreError?
    private(set) var saves = 0

    init(_ policy: StoredPolicy? = nil) {
        stored = policy
    }

    func load() -> Result<StoredPolicy?, PolicyStoreError> {
        lock.lock()
        defer { lock.unlock() }
        if let failure { return .failure(failure) }
        return .success(stored)
    }

    func save(_ policy: StoredPolicy) -> Result<Void, PolicyStoreError> {
        lock.lock()
        defer { lock.unlock() }
        if let failure { return .failure(failure) }
        stored = policy
        saves += 1
        return .success(())
    }

    var current: StoredPolicy? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class ScriptedConsent: ConsentPrompter {
    var answer: ConsentAnswer
    private(set) var requests: [ConsentRequest] = []

    init(_ answer: ConsentAnswer = .approved) {
        self.answer = answer
    }

    func ask(_ request: ConsentRequest) -> ConsentAnswer {
        requests.append(request)
        return answer
    }
}

extension StoredPolicy {
    static func dedicated(owner: String = "+15551234567", guests: [String] = [],
                          confirmedAt: String? = "2026-10-03T11:00:00.000Z") -> StoredPolicy {
        StoredPolicy(posture: .dedicatedAccount, ownerHandle: owner, handles: ([owner] + guests).sorted(),
                     confirmedAt: confirmedAt, selfAliasesVerifiedAt: nil)
    }

    static func own(owner: String = "+15551234567") -> StoredPolicy {
        StoredPolicy(posture: .ownAccount, ownerHandle: owner, handles: [owner],
                     confirmedAt: "2026-10-03T11:00:00.000Z", selfAliasesVerifiedAt: "2026-10-03T11:00:00.000Z")
    }
}

enum TestClock {
    static let noon = Date(timeIntervalSince1970: 1_791_028_800)
}
