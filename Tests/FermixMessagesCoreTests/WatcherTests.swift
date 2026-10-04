import Foundation
import Testing
@testable import FermixMessagesCore

/// The inbound path over the synthetic chat.db: one SendHarness for the fixture, ledger
/// and policy, a capturing wire, and a watcher ticked by hand.
final class WatchHarness {
    let base: SendHarness
    let wire = CapturingWire()
    let emitted = EmittedRegistry(capacity: 1000)
    var clock = TestClock.noon.addingTimeInterval(30)
    var joinHold: TimeInterval = 10
    var fixture: ChatDBFixture { base.fixture }

    init(policy: StoredPolicy? = .dedicated(guests: ["guest@example.com"])) {
        base = SendHarness(policy: policy)
    }

    lazy var feed = Feed(location: fixture.location, policy: base.policy, ledger: base.ledger, emitted: emitted,
                         log: base.log.logger, now: { [unowned self] in self.clock },
                         onOwnerIsThisMac: { [wire] event in
                             wire.notify(Wire.encodeNotification(.policyState, event)) {}
                         })
    lazy var watcher = Watcher(location: fixture.location, feed: feed, sink: wire,
                               log: base.log.logger, now: { [unowned self] in self.clock },
                               pollInterval: 0.05, joinHold: joinHold)

    @discardableResult
    func inbound(_ text: String = "hello", from handle: String = "+15551234567", date: Int64 = ChatDBFixture.noon,
                 chatService: String = "iMessage", handleService: String = "iMessage", group: Bool = false,
                 associatedType: Int64 = 0, joined: Bool = true) -> (rowid: Int64, guid: String) {
        let handleRow = fixture.ensureHandle(handle, service: handleService)
        let guid = group ? "any;+;group-\(handle)" : "\(chatService == "SMS" ? "SMS" : "any");-;\(handle)"
        let chat = fixture.ensureChat(handle, service: chatService, guid: guid)
        return fixture.message(.init(text: text, date: date, handle: handleRow, chat: joined ? chat : nil,
                                     associatedType: associatedType,
                                     associatedGuid: associatedType == 0 ? nil : "p:0/TARGET"))
    }

    func subscribe(since: Int64? = nil, replay: ReplayBounds? = nil, buffer: Int = 256) throws -> SubscribeResult {
        try watcher.subscribe(SubscribeParams(sinceRowid: since, replay: replay, bufferLimit: buffer)).get()
    }
}

@Suite struct WatcherTests {
    @Test func aLiveSubscriptionStartsAtNowAndStreamsNewRows() throws {
        let harness = WatchHarness()
        harness.inbound("before")
        let started = try harness.subscribe()
        #expect(started == SubscribeResult(startedAtRowid: 1, replaySkipped: 0))
        let new = harness.inbound("after")
        harness.watcher.tick()
        #expect(harness.wire.messageRowids == [new.rowid])
        let params = try #require(harness.wire.events.first?.params)
        #expect(params["text"] as? String == "after")
        #expect((params["sender"] as? [String: Any])?["handle"] as? String == "+15551234567")
        #expect(harness.emitted.contains(new.guid))
        harness.watcher.tick()
        #expect(harness.wire.messageRowids == [new.rowid], "each row once")
    }

    @Test func onlyDirectIMessageRowsFromConfirmedHandlesLeaveTheHelper() throws {
        let harness = WatchHarness()
        _ = try harness.subscribe()
        harness.inbound("group", group: true)
        harness.inbound("sms handle", handleService: "SMS")
        harness.inbound("sms chat", chatService: "SMS")
        harness.inbound("stranger", from: "+15550009999")
        let mine = harness.fixture.message(.init(text: "typed on the Mac", fromMe: true, handle: harness.base.owner,
                                                 chat: harness.base.ownerChat))
        let guest = harness.inbound("guest", from: "guest@example.com")
        let owner = harness.inbound("owner")
        harness.watcher.tick()
        #expect(harness.wire.messageRowids == [guest.rowid, owner.rowid])
        #expect(!harness.emitted.contains(mine.guid))
        let log = harness.base.log.lines.joined(separator: "\n")
        #expect(!log.contains("group") && !log.contains("stranger") && !log.contains("+15550009999"),
                "no body and no unredacted handle reaches the log")
    }

    @Test func tapbacksAreEmittedWithTheirReactionOnlyWhereARowWouldBe() throws {
        let harness = WatchHarness()
        _ = try harness.subscribe()
        let like = harness.inbound("Liked “x”", associatedType: 2001)
        harness.inbound("Liked “y”", group: true, associatedType: 2001)
        harness.inbound("Liked “z”", from: "+15550009999", associatedType: 2001)
        harness.watcher.tick()
        #expect(harness.wire.messageRowids == [like.rowid])
        let reaction = harness.wire.events.first?.params["reaction"] as? [String: Any]
        #expect((reaction?["type"] as? NSNumber)?.intValue == 2001)
        #expect(reaction?["target_guid"] as? String == "TARGET")
    }

    @Test func aRowWaitingForItsChatJoinHoldsTheCursorUntilJoined() throws {
        let harness = WatchHarness()
        _ = try harness.subscribe()
        let early = harness.inbound("early", joined: false)
        let late = harness.inbound("late")
        harness.watcher.tick()
        #expect(harness.wire.messageRowids.isEmpty, "nothing passes a row whose join is pending")
        harness.fixture.join(chat: harness.base.ownerChat, message: early.rowid)
        harness.watcher.tick()
        #expect(harness.wire.messageRowids == [early.rowid, late.rowid])
    }

    @Test func aRowThatNeverGetsAJoinIsSkippedAfterTheHold() throws {
        let harness = WatchHarness()
        harness.joinHold = 0
        _ = try harness.subscribe()
        harness.inbound("orphan", joined: false)
        let next = harness.inbound("next")
        harness.watcher.tick()
        harness.watcher.tick()
        #expect(harness.wire.messageRowids == [next.rowid])
    }

    @Test func bootReplayIsBoundedByRowsAndAgeAndCountsWhatItSkipped() throws {
        let harness = WatchHarness()
        harness.inbound("acknowledged")
        let old = ChatDBFixture.noon - 1200 * 1_000_000_000
        for _ in 0..<3 { harness.inbound("stale", date: old) }
        harness.inbound("stranger", from: "+15550009999")
        let recent = (0..<60).map { _ in harness.inbound("recent").rowid }
        let result = try harness.subscribe(since: 1, replay: ReplayBounds(maxRows: 50, maxAgeS: 600))
        #expect(result.startedAtRowid == recent.last)
        #expect(result.replaySkipped == 13)
        #expect(harness.wire.messageRowids == Array(recent.suffix(50)))
        let live = harness.inbound("live")
        harness.watcher.tick()
        #expect(harness.wire.messageRowids.last == live.rowid)
        #expect(harness.wire.messageRowids.count == 51)
    }

    @Test func aResumeWithoutReplayBoundsStreamsEverythingAfterTheCursor() throws {
        let harness = WatchHarness()
        let rows = (0..<5).map { _ in harness.inbound(date: ChatDBFixture.noon - 86_400 * 1_000_000_000).rowid }
        let result = try harness.subscribe(since: rows[1])
        #expect(result == SubscribeResult(startedAtRowid: rows[1], replaySkipped: 0))
        harness.watcher.tick()
        #expect(harness.wire.messageRowids == Array(rows[2...]))
    }

    @Test func overflowStopsPushingAndPagingRecoversEveryRowExactlyOnceInOrder() throws {
        let harness = WatchHarness()
        _ = try harness.subscribe(buffer: 5)
        harness.wire.held = true
        let rows = (0..<12).map { _ in harness.inbound().rowid }
        harness.watcher.tick()
        harness.watcher.tick()
        #expect(harness.wire.messageRowids == Array(rows[0..<5]))
        let overflow = try #require(harness.wire.events.first { $0.event == "watch.overflow" })
        #expect((overflow.params["dropped"] as? NSNumber)?.intValue == 7)
        #expect((overflow.params["resume_after_rowid"] as? NSNumber)?.int64Value == rows[4])
        harness.wire.release()
        harness.watcher.tick()
        #expect(harness.wire.messageRowids.count == 5, "nothing is pushed after an overflow")

        var paged: [Int64] = []
        var cursor: Int64 = 0
        for _ in 0..<10 {
            let page = try harness.feed.after(MessagesAfterParams(sinceRowid: cursor, limit: 4)).get()
            paged += page.messages.map(\.rowid)
            cursor = page.messages.last?.rowid ?? cursor
            if !page.hasMore { break }
        }
        #expect(paged == rows)

        _ = try harness.subscribe(since: cursor, buffer: 5)
        let after = harness.inbound()
        harness.watcher.tick()
        #expect(harness.wire.messageRowids.suffix(1) == [after.rowid])
    }

    @Test func aNewGenerationResetsTheCursorToNow() throws {
        let harness = WatchHarness()
        _ = try harness.subscribe()
        harness.inbound("first")
        harness.watcher.tick()
        harness.fixture.replaceDatabase(seedRowid: 500)
        let owner = harness.fixture.handle("+15551234567")
        let chat = harness.fixture.chat("+15551234567")
        harness.fixture.message(.init(text: "already there", handle: owner, chat: chat))
        harness.watcher.tick()
        let states = harness.wire.events.filter { $0.event == "db.state" }.map {
            "\($0.params["state"] as? String ?? "")/\($0.params["class"] as? String ?? "null")"
        }
        #expect(states == ["unavailable/generation_changed", "available/null"])
        let fresh = harness.fixture.message(.init(text: "new", handle: owner, chat: chat))
        harness.watcher.tick()
        #expect(harness.wire.messageRowids == [1, fresh.rowid])
    }

    @Test func losingTheDatabaseIsReportedOnceAndItsReturnToo() throws {
        guard getuid() != 0 else { return }
        let harness = WatchHarness()
        _ = try harness.subscribe()
        harness.fixture.closeWriter()
        #expect(chmod(harness.fixture.location.chatDB, 0) == 0)
        harness.watcher.tick()
        harness.watcher.tick()
        #expect(chmod(harness.fixture.location.chatDB, 0o644) == 0)
        harness.fixture.reopenWriter()
        harness.watcher.tick()
        let states = harness.wire.events.filter { $0.event == "db.state" }.map {
            "\($0.params["state"] as? String ?? "")/\($0.params["class"] as? String ?? "null")"
        }
        #expect(states == ["unavailable/permission_denied", "available/null"])
    }

    @Test func aFutureDateIsClampedAndLogged() throws {
        let harness = WatchHarness()
        _ = try harness.subscribe()
        harness.inbound(date: ChatDBFixture.appleNanoseconds(harness.clock.addingTimeInterval(7200)))
        harness.watcher.tick()
        #expect(harness.wire.events.first?.params["date"] as? String == Timestamp.format(harness.clock))
        #expect(harness.base.log.lines.contains { $0.contains("date_clamped") })
    }

    @Test func ownAccountAdmitsTheSelfChatAndSuppressesFermixsOwnReplies() throws {
        let harness = WatchHarness(policy: .own())
        _ = try harness.subscribe()
        try harness.base.ledger.insertDispatched(LedgerRow(
            key: "reply-1", chat: "any;-;+15551234567", to: "+15551234567",
            textSHA256: FileCopy.sha256("Fermix's reply"), fileSHA256: nil, watermark: 0, state: .dispatched,
            startedAt: harness.clock, guid: nil, rowid: nil, finishedAt: nil, failureClass: nil, detail: nil))
        let prompt = harness.fixture.message(.init(text: "remind me at 5", fromMe: true, handle: harness.base.owner,
                                                   chat: harness.base.ownerChat))
        harness.fixture.message(.init(text: "Fermix's reply", fromMe: true, handle: harness.base.owner,
                                      chat: harness.base.ownerChat))
        harness.inbound("from someone else in the self chat?")
        harness.watcher.tick()
        #expect(harness.wire.messageRowids == [prompt.rowid])
    }

    @Test func anIsMeRowWithoutAHandleTakesTheChatsService() throws {
        let harness = WatchHarness(policy: .own())
        _ = try harness.subscribe()
        let prompt = harness.fixture.message(.init(text: "note to self", fromMe: true, handle: 0,
                                                   chat: harness.base.ownerChat, destination: "+15551234567"))
        harness.watcher.tick()
        #expect(harness.wire.messageRowids == [prompt.rowid])
        let sender = harness.wire.events.first?.params["sender"] as? [String: Any]
        #expect(sender?["service"] as? String == "iMessage")
        #expect(sender?["is_me"] as? Bool == true)
        #expect(sender?["handle"] as? String == "+15551234567")
    }

    /// A fresh account had no aliases at confirmation, so the owner's own Apple ID was
    /// derived dedicated; the owner's self chat on this Mac gives it away.
    @Test func theOwnersSelfChatUnderADedicatedPolicyIsReportedOnceAndRefusesSendsToTheOwner() throws {
        let harness = WatchHarness()
        _ = try harness.subscribe()
        let typed = harness.fixture.message(.init(text: "note to self", fromMe: true, handle: harness.base.owner,
                                                  chat: harness.base.ownerChat))
        harness.fixture.message(.init(text: "another", fromMe: true, handle: harness.base.owner,
                                      chat: harness.base.ownerChat))
        let guest = harness.inbound("guest", from: "guest@example.com")
        harness.watcher.tick()
        #expect(harness.wire.messageRowids == [guest.rowid])
        #expect(!harness.emitted.contains(typed.guid))
        let states = harness.wire.events.filter { $0.event == "policy.state" }
        #expect(states.count == 1, "once, not per row")
        #expect(states.first?.params["state"] as? String == "owner_is_this_mac")
        #expect(states.first?.params["owner"] as? String == "+1555…4567")
        #expect(!harness.base.log.lines.joined(separator: "\n").contains("+15551234567"))

        let sender = harness.base.sender()
        #expect(sender.sendText(SenderTests.text(key: "to-owner")).failureValue == .ownerIsThisMac)
        #expect(try sender.sendText(SenderTests.text("guest@example.com", key: "to-guest")).get().disposition
            == .recorded)
        #expect(harness.base.messages.commands.map(\.target) == ["any;-;guest@example.com"])

        _ = harness.base.store.save(.dedicated(guests: ["guest@example.com"], confirmedAt: "2026-10-03T13:00:00Z"))
        #expect(try sender.sendText(SenderTests.text(key: "after")).get().disposition == .recorded,
                "a new confirmation lifts the refusal")
        harness.watcher.tick()
        #expect(harness.wire.events.filter { $0.event == "policy.state" }.count == 1)
    }

    @Test func fermixsOwnSendsToTheOwnerAreNotTheOwnersSelfChat() throws {
        let harness = WatchHarness()
        _ = try harness.subscribe()
        #expect(try harness.base.sender().sendText(SenderTests.text()).get().disposition == .recorded)
        try harness.base.ledger.insertDispatched(LedgerRow(
            key: "in-flight", chat: "any;-;+15551234567", to: "+15551234567",
            textSHA256: FileCopy.sha256("on its way"), fileSHA256: nil, watermark: 0, state: .dispatched,
            startedAt: harness.clock, guid: nil, rowid: nil, finishedAt: nil, failureClass: nil, detail: nil))
        harness.fixture.message(.init(text: "on its way", fromMe: true, handle: harness.base.owner,
                                      chat: harness.base.ownerChat))
        harness.watcher.tick()
        #expect(harness.wire.events.isEmpty)
        #expect(try harness.base.sender().sendText(SenderTests.text(key: "again")).get().disposition == .recorded)
    }

    @Test func theDataPlaneGatesApplyToSubscribe() {
        let noPolicy = WatchHarness(policy: nil)
        #expect(noPolicy.watcher.subscribe(SubscribeParams(sinceRowid: nil, replay: nil, bufferLimit: 8))
            .failureValue?.kind == .policyAbsent)
        let missing = WatchHarness()
        missing.fixture.writer.close()
        _ = unlink(missing.fixture.location.chatDB)
        #expect(missing.watcher.subscribe(SubscribeParams(sinceRowid: nil, replay: nil, bufferLimit: 8))
            .failureValue?.kind == .dbMissing)
    }

    @Test func theTimerDeliversWithoutAManualTick() throws {
        let harness = WatchHarness()
        _ = try harness.subscribe()
        harness.watcher.start()
        defer { harness.watcher.stop() }
        let row = harness.inbound("timed")
        let deadline = Date().addingTimeInterval(3)
        while harness.wire.messageRowids.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(harness.wire.messageRowids == [row.rowid])
    }
}

@Suite struct MessagesAfterTests {
    @Test func pagesHonourTheLimitAndHasMore() throws {
        let harness = WatchHarness()
        let rows = (0..<5).map { _ in harness.inbound().rowid }
        harness.inbound("stranger", from: "+15550009999")
        let first = try harness.feed.after(MessagesAfterParams(sinceRowid: 0, limit: 3)).get()
        #expect(first.messages.map(\.rowid) == Array(rows[0..<3]))
        #expect(first.hasMore)
        let second = try harness.feed.after(MessagesAfterParams(sinceRowid: rows[2], limit: 3)).get()
        #expect(second.messages.map(\.rowid) == Array(rows[3...]))
        #expect(!second.hasMore)
    }

    @Test func messagesAfterIsGatedLikeEveryDataPlaneCall() {
        let unconfirmed = WatchHarness(policy: .dedicated(confirmedAt: nil))
        #expect(unconfirmed.feed.after(MessagesAfterParams(sinceRowid: 0, limit: 3)).failureValue?.kind
            == .policyUnconfirmed)
    }
}
