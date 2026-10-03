import Foundation
import Testing
@testable import FermixMessagesCore

@Suite struct LedgerTests {
    static let now = Date(timeIntervalSince1970: 1_791_028_800)

    static func open(_ directory: TestDirectory) throws -> Ledger {
        try Ledger.open(path: directory.path + "/ledger.sqlite")
    }

    static func dispatched(_ key: String, text: String = "reply", watermark: Int64 = 10,
                           startedAt: Date = now) -> LedgerRow {
        LedgerRow(key: key, chat: "any;-;+15551234567", to: "+15551234567", textSHA256: FileCopy.sha256(text),
                  fileSHA256: nil, watermark: watermark, state: .dispatched, startedAt: startedAt, guid: nil,
                  rowid: nil, finishedAt: nil, failureClass: nil, detail: nil)
    }

    @Test func aDispatchedRowSurvivesReopening() throws {
        let directory = TestDirectory()
        let ledger = try Self.open(directory)
        try ledger.insertDispatched(Self.dispatched("k1"))
        ledger.close()
        let reopened = try Self.open(directory)
        defer { reopened.close() }
        #expect(try reopened.find("k1") == Self.dispatched("k1"))
        #expect(try reopened.dispatched().map(\.key) == ["k1"])
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path + "/ledger.sqlite")[.posixPermissions]
        #expect(mode as? Int == 0o600)
    }

    @Test func finishingRecordsTheOutcome() throws {
        let directory = TestDirectory()
        let ledger = try Self.open(directory)
        defer { ledger.close() }
        try ledger.insertDispatched(Self.dispatched("k1"))
        try ledger.finish("k1", state: .recorded, guid: "G", rowid: 11, failureClass: nil, detail: nil, at: Self.now)
        let row = try #require(try ledger.find("k1"))
        #expect(row.state == .recorded)
        #expect(row.guid == "G")
        #expect(row.rowid == 11)
        #expect(row.outcome == .recorded(guid: "G", rowid: 11))
        #expect(try ledger.dispatched().isEmpty)
        try ledger.insertFailed(key: "k2", chat: "", to: "+15551234567", failure: .pathRefused, detail: "x", at: Self.now)
        #expect(try ledger.find("k2")?.outcome == .failed(.pathRefused))
    }

    @Test func aRecordedGuidIsFermixsOwn() throws {
        let directory = TestDirectory()
        let ledger = try Self.open(directory)
        defer { ledger.close() }
        try ledger.insertDispatched(Self.dispatched("k1"))
        try ledger.finish("k1", state: .recorded, guid: "G-OWN", rowid: 11, failureClass: nil, detail: nil, at: Self.now)
        let probe = EchoProbe(guid: "G-OWN", chatGuid: "x", chatIdentifier: "+15550000000", rowid: 99,
                              textSHA256: nil, attachmentHashes: { [] })
        #expect(try ledger.isFermixOwn(probe, now: Self.now.addingTimeInterval(3600)))
    }

    @Test func anInFlightSendMatchesByChatTextWatermarkAndTime() throws {
        let directory = TestDirectory()
        let ledger = try Self.open(directory)
        defer { ledger.close() }
        try ledger.insertDispatched(Self.dispatched("k1", text: "reply", watermark: 10))
        func probe(rowid: Int64 = 11, text: String = "reply", chat: String = "any;-;+15551234567") -> EchoProbe {
            EchoProbe(guid: "NEW", chatGuid: chat, chatIdentifier: "+15551234567", rowid: rowid,
                      textSHA256: FileCopy.sha256(text), attachmentHashes: { [] })
        }
        #expect(try ledger.isFermixOwn(probe(), now: Self.now.addingTimeInterval(5)))
        #expect(try !ledger.isFermixOwn(probe(rowid: 10), now: Self.now), "at or below the watermark")
        #expect(try !ledger.isFermixOwn(probe(text: "a genuine prompt"), now: Self.now), "different text")
        #expect(try !ledger.isFermixOwn(probe(), now: Self.now.addingTimeInterval(61)), "older than 60 s")
        let otherChat = EchoProbe(guid: "NEW", chatGuid: "any;-;+15559999999", chatIdentifier: "+15559999999",
                                  rowid: 11, textSHA256: FileCopy.sha256("reply"), attachmentHashes: { [] })
        #expect(try !ledger.isFermixOwn(otherChat, now: Self.now))
        try ledger.finish("k1", state: .uncertain, guid: nil, rowid: nil, failureClass: nil, detail: nil, at: Self.now)
        #expect(try ledger.isFermixOwn(probe(), now: Self.now.addingTimeInterval(5)), "uncertain still suppresses")
    }

    @Test func anInFlightFileSendMatchesByAttachmentHash() throws {
        let directory = TestDirectory()
        let ledger = try Self.open(directory)
        defer { ledger.close() }
        var row = Self.dispatched("f1")
        row = LedgerRow(key: row.key, chat: row.chat, to: row.to, textSHA256: nil, fileSHA256: "abc",
                        watermark: 10, state: .dispatched, startedAt: Self.now, guid: nil, rowid: nil,
                        finishedAt: nil, failureClass: nil, detail: nil)
        try ledger.insertDispatched(row)
        var hashed = 0
        let probe = EchoProbe(guid: "N", chatGuid: row.chat, chatIdentifier: "+15551234567", rowid: 11,
                              textSHA256: nil, attachmentHashes: { hashed += 1; return ["abc"] })
        #expect(try ledger.isFermixOwn(probe, now: Self.now))
        #expect(hashed == 1)
        let noCandidate = EchoProbe(guid: "N", chatGuid: "other", chatIdentifier: "+15550000000", rowid: 11,
                                    textSHA256: nil, attachmentHashes: { hashed += 1; return ["abc"] })
        #expect(try !ledger.isFermixOwn(noCandidate, now: Self.now))
        #expect(hashed == 1, "attachments are hashed only when a file send is in flight for that chat")
    }

    @Test func pruningDropsOldRowsAndBoundsTheCount() throws {
        let directory = TestDirectory()
        let ledger = try Self.open(directory)
        defer { ledger.close() }
        try ledger.insertFailed(key: "old", chat: "", to: "+1", failure: .pathRefused, detail: nil,
                                at: Self.now.addingTimeInterval(-31 * 86_400))
        for index in 0..<5 {
            try ledger.insertFailed(key: "k\(index)", chat: "", to: "+1", failure: .pathRefused, detail: nil,
                                    at: Self.now.addingTimeInterval(Double(index)))
        }
        try ledger.insertDispatched(Self.dispatched("inflight", startedAt: Self.now.addingTimeInterval(-40 * 86_400)))
        try ledger.prune(now: Self.now, maxRows: 3)
        #expect(try ledger.find("old") == nil)
        #expect(try ledger.find("k0") == nil)
        #expect(try ledger.find("k1") == nil)
        #expect(try ledger.find("k4") != nil)
        #expect(try ledger.find("inflight") != nil, "a dispatched row is reconciled, never pruned")
    }
}
