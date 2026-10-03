import Foundation
import Testing
@testable import FermixMessagesCore

@Suite struct ChatDBTests {
    @Test func aWellFormedDatabaseOpensReadOnly() throws {
        let fixture = ChatDBFixture()
        let db = fixture.openReader()
        defer { db.close() }
        #expect(try db.maxRowid() == 0)
        #expect(throws: SQLiteError.self) { try db.connection.execute("CREATE TABLE x (y)") }
    }

    @Test func aMissingDatabaseIsMissing() {
        let directory = TestDirectory()
        let location = MessagesLocation(directory: directory.sub("Messages"), attachmentsRoot: directory.path,
                                        stagingRoot: directory.path, tildeHome: directory.path)
        #expect(ChatDB.open(location).failureValue == .missing)
        #expect(ChatDB.generation(of: location.chatDB) == nil)
    }

    @Test func anUnreadableFileIsAPermissionDenialNotAMissingFile() throws {
        guard getuid() != 0 else { return }
        let fixture = ChatDBFixture()
        #expect(chmod(fixture.location.chatDB, 0) == 0)
        guard case .permissionDenied = ChatDB.open(fixture.location).failureValue else {
            Issue.record("expected permission denied, got \(String(describing: ChatDB.open(fixture.location)))")
            return
        }
        #expect(ChatDB.generation(of: fixture.location.chatDB) != nil, "stat needs no read permission")
    }

    @Test func aFileThatIsNotADatabaseIsUnreadable() throws {
        let directory = TestDirectory()
        let messages = directory.sub("Messages")
        try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: messages + "/chat.db"))
        let location = MessagesLocation(directory: messages, attachmentsRoot: directory.path,
                                        stagingRoot: directory.path, tildeHome: directory.path)
        guard case .unreadable = ChatDB.open(location).failureValue else {
            Issue.record("expected unreadable")
            return
        }
    }

    @Test func schemaDriftNamesEveryMissingColumn() {
        let drifted = ChatDBFixture.ddl
            .replacingOccurrences(of: ", destination_caller_id TEXT", with: "")
            .replacingOccurrences(of: "last_addressed_handle TEXT,", with: "")
        let fixture = ChatDBFixture(ddl: drifted)
        #expect(ChatDB.open(fixture.location).failureValue
            == .schemaUnexpected(["chat.last_addressed_handle", "message.destination_caller_id"]))
    }

    @Test func aMissingTableNamesItsColumns() {
        let fixture = ChatDBFixture(ddl: ChatDBFixture.ddl.replacingOccurrences(
            of: "CREATE TABLE message_attachment_join", with: "CREATE TABLE renamed_join"))
        #expect(ChatDB.open(fixture.location).failureValue
            == .schemaUnexpected(["message_attachment_join.attachment_id", "message_attachment_join.message_id"]))
    }

    @Test func theRowQueryJoinsHandleAndChat() throws {
        let fixture = ChatDBFixture()
        let owner = fixture.handle("+15551234567")
        let chat = fixture.chat("+15551234567")
        let sent = fixture.message(.init(text: "hi there", handle: owner, chat: chat, thread: "T-1"))
        let db = fixture.openReader()
        defer { db.close() }
        let rows = try db.rows(after: 0, limit: 256)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.rowid == sent.rowid)
        #expect(row.guid == sent.guid)
        #expect(row.text == "hi there")
        #expect(row.handle == "+15551234567")
        #expect(row.handleService == "iMessage")
        #expect(row.chatRowid == chat)
        #expect(row.chatGuid == "any;-;+15551234567")
        #expect(row.chatIdentifier == "+15551234567")
        #expect(row.chatService == "iMessage")
        #expect(row.threadOriginatorGuid == "T-1")
        #expect(!row.isFromMe)
    }

    @Test func aRowWhoseChatJoinArrivesLaterAppearsOnceJoined() throws {
        let fixture = ChatDBFixture()
        let owner = fixture.handle("+15551234567")
        let chat = fixture.chat("+15551234567")
        let early = fixture.message(.init(handle: owner, chat: nil))
        let db = fixture.openReader()
        defer { db.close() }
        #expect(try db.rows(after: 0, limit: 256).isEmpty)
        #expect(try db.firstRowWithoutChat(after: 0, through: early.rowid) == early.rowid)
        fixture.join(chat: chat, message: early.rowid)
        #expect(try db.rows(after: 0, limit: 256).map(\.rowid) == [early.rowid])
        #expect(try db.firstRowWithoutChat(after: 0, through: early.rowid) == nil)
    }

    @Test func rowsArePagedInRowidOrder() throws {
        let fixture = ChatDBFixture()
        let owner = fixture.handle("+15551234567")
        let chat = fixture.chat("+15551234567")
        let ids = (0..<10).map { _ in fixture.message(.init(handle: owner, chat: chat)).rowid }
        let db = fixture.openReader()
        defer { db.close() }
        #expect(try db.rows(after: ids[2], limit: 3).map(\.rowid) == Array(ids[3...5]))
        #expect(try db.maxRowid() == ids.last)
    }

    @Test func attachmentsAreListedInOrder() throws {
        let fixture = ChatDBFixture()
        let chat = fixture.chat("+15551234567")
        let row = fixture.message(.init(text: nil, chat: chat))
        fixture.attachment(message: row.rowid, filename: "~/Library/Messages/Attachments/a/b/IMG_1.HEIC",
                           mime: "image/heic", bytes: 2048)
        fixture.attachment(message: row.rowid, filename: nil, mime: nil, bytes: 0)
        let db = fixture.openReader()
        defer { db.close() }
        let attachments = try db.attachments(messageRowid: row.rowid)
        #expect(attachments.map(\.index) == [0, 1])
        #expect(attachments[0].filename == "~/Library/Messages/Attachments/a/b/IMG_1.HEIC")
        #expect(attachments[0].mime == "image/heic")
        #expect(attachments[0].bytes == 2048)
        #expect(attachments[1].filename == nil)
    }

    @Test func selfAliasesComeFromBothColumnsNormalized() throws {
        let fixture = ChatDBFixture()
        let friend = fixture.handle("+15550001111")
        let chat = fixture.chat("+15550001111", lastAddressed: "+1 (555) 123-4567")
        fixture.chat("+15550002222", lastAddressed: "")
        fixture.message(.init(handle: friend, chat: chat, destination: "Owner@Example.com"))
        fixture.message(.init(handle: friend, chat: chat, destination: "+15551234567"))
        fixture.message(.init(handle: friend, chat: chat, destination: "not a handle"))
        let db = fixture.openReader()
        defer { db.close() }
        #expect(try db.selfAliases() == ["+15551234567", "owner@example.com"])
    }

    @Test func theDirectIMessageChatIsFoundByHandleAndSmsOrGroupChatsAreSkipped() throws {
        let fixture = ChatDBFixture()
        fixture.chat("+15551234567", service: "SMS", guid: "SMS;-;+15551234567")
        fixture.chat("+15551234567", group: true, guid: "any;+;chat123")
        let imessage = fixture.chat("+15551234567", guid: "any;-;+15551234567")
        let db = fixture.openReader()
        defer { db.close() }
        let target = try db.directChat(handle: "+15551234567")
        #expect(target == DirectChat(rowid: imessage, guid: "any;-;+15551234567"))
        #expect(try db.directChat(handle: "+15559999999") == nil)
    }

    @Test func theGenerationChangesWhenTheFileIsReplaced() throws {
        let fixture = ChatDBFixture()
        let before = try #require(ChatDB.generation(of: fixture.location.chatDB))
        fixture.replaceDatabase(seedRowid: 0)
        let after = try #require(ChatDB.generation(of: fixture.location.chatDB))
        #expect(before != after)
    }
}

@Suite struct RowDecodingTests {
    static let now = Date(timeIntervalSince1970: 1_791_028_800)

    static func raw(text: String? = "hi", body: Data? = nil, date: Int64 = ChatDBFixture.noon,
                    fromMe: Bool = false, associatedType: Int64 = 0, associatedGuid: String? = nil,
                    chatGuid: String = "any;-;+15551234567") -> RawRow {
        RawRow(rowid: 9, guid: "G-9", text: text, attributedBody: body, date: date, isFromMe: fromMe,
               handleId: 1, associatedType: associatedType, associatedGuid: associatedGuid,
               threadOriginatorGuid: nil, destinationCallerId: "+15551234567", handle: "+15551234567",
               handleService: "iMessage", chatRowid: 3, chatGuid: chatGuid, chatIdentifier: "+15551234567",
               chatService: "iMessage")
    }

    @Test func nanosecondDatesDecodeToUtc() {
        let decoded = DecodedRow(Self.raw(date: ChatDBFixture.noon + 250_000_000), attachments: [], now: Self.now)
        #expect(Timestamp.format(decoded.date) == "2026-10-03T12:00:00.250Z")
        #expect(!decoded.dateClamped)
    }

    @Test func smallDatesAreSeconds() {
        let seconds = ChatDBFixture.noon / 1_000_000_000
        let decoded = DecodedRow(Self.raw(date: seconds), attachments: [], now: Self.now)
        #expect(Timestamp.format(decoded.date) == "2026-10-03T12:00:00.000Z")
    }

    @Test func aFutureDateIsClampedToNow() {
        let future = ChatDBFixture.appleNanoseconds(Self.now.addingTimeInterval(3600))
        let decoded = DecodedRow(Self.raw(date: future), attachments: [], now: Self.now)
        #expect(decoded.date == Self.now)
        #expect(decoded.dateClamped)
        let nearFuture = ChatDBFixture.appleNanoseconds(Self.now.addingTimeInterval(30))
        #expect(!DecodedRow(Self.raw(date: nearFuture), attachments: [], now: Self.now).dateClamped)
    }

    @Test func textFallsToTheTypedstreamBodyOnlyWhenTextIsEmpty() {
        let body = Archive.attributedBody("from the blob")
        #expect(DecodedRow(Self.raw(text: nil, body: body), attachments: [], now: Self.now).text == "from the blob")
        #expect(DecodedRow(Self.raw(text: "", body: body), attachments: [], now: Self.now).text == "from the blob")
        #expect(DecodedRow(Self.raw(text: "column", body: body), attachments: [], now: Self.now).text == "column")
        let none = DecodedRow(Self.raw(text: nil, body: nil), attachments: [], now: Self.now)
        #expect(none.text == nil)
        #expect(none.decodeError == nil)
    }

    @Test func anUndecodableBodyIsADecodeErrorNotADrop() {
        let decoded = DecodedRow(Self.raw(text: nil, body: Data([0x04, 0x0b, 0x01])), attachments: [], now: Self.now)
        #expect(decoded.text == nil)
        #expect(decoded.decodeError == "bad_header")
        #expect(decoded.event.decodeError == "bad_header")
    }

    @Test func tapbacksAreReactionsWithTheirTarget() {
        for type in [2000, 2001, 2005, 2006, 3000, 3006] {
            let decoded = DecodedRow(Self.raw(associatedType: Int64(type), associatedGuid: "p:0/TARGET-1"),
                                     attachments: [], now: Self.now)
            #expect(decoded.reaction == Reaction(type: type, targetGuid: "TARGET-1"))
        }
        let bp = DecodedRow(Self.raw(associatedType: 2000, associatedGuid: "bp:TARGET-2"), attachments: [], now: Self.now)
        #expect(bp.reaction?.targetGuid == "TARGET-2")
        for type in [0, 1000, 2007, 3007] {
            #expect(DecodedRow(Self.raw(associatedType: Int64(type)), attachments: [], now: Self.now).reaction == nil)
        }
    }

    @Test func directAndGroupComeFromTheGuidShape() {
        #expect(!DecodedRow(Self.raw(chatGuid: "any;-;+15551234567"), attachments: [], now: Self.now).isGroup)
        #expect(!DecodedRow(Self.raw(chatGuid: "iMessage;-;a@b.com"), attachments: [], now: Self.now).isGroup)
        #expect(DecodedRow(Self.raw(chatGuid: "any;+;chat1"), attachments: [], now: Self.now).isGroup)
        #expect(DecodedRow(Self.raw(chatGuid: "weird"), attachments: [], now: Self.now).isGroup)
    }

    @Test func theEventCarriesTheNormalizedCounterpartAndAttachments() {
        let attachment = RawAttachment(index: 0, guid: "AT-1", filename: "~/Library/Messages/Attachments/x/Audio Message.caf",
                                       mime: "audio/x-caf", bytes: 10)
        let event = DecodedRow(Self.raw(), attachments: [attachment], now: Self.now).event
        #expect(event.sender == SenderRef(handle: "+15551234567", isMe: false))
        #expect(event.chat == ChatRef(rowid: 3, guid: "any;-;+15551234567", identifier: "+15551234567",
                                      service: "iMessage", group: false))
        #expect(event.attachments == [AttachmentRef(index: 0, guid: "AT-1", name: "Audio Message.caf",
                                                    mime: "audio/x-caf", bytes: 10)])
        let mine = DecodedRow(Self.raw(fromMe: true), attachments: [], now: Self.now).event
        #expect(mine.sender == SenderRef(handle: "+15551234567", isMe: true))
    }
}
