import Foundation
import Testing
@testable import FermixMessagesCore

/// Goldens for the NDJSON wire (design §6). The fixtures under `Tests/Fixtures/protocol/`
/// are the contract the engine's `IMessage.Protocol` codec is tested against too: line 1
/// of a method fixture is the request, line 2 the response; a notification fixture is
/// one line. Responses are compared byte for byte (keys sorted, slashes unescaped).
@Suite struct ProtocolCodecTests {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/protocol")

    static func lines(_ name: String) throws -> [String] {
        let text = try String(contentsOf: directory.appendingPathComponent(name + ".ndjson"), encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    static func request(_ line: String) throws -> Request {
        switch Wire.decodeRequest(Data(line.utf8)) {
        case .success(let request): return request
        case .failure(let failure): throw failure
        }
    }

    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    static let chat = ChatRef(rowid: 7, guid: "any;-;+15551234567", identifier: "+15551234567",
                              service: "iMessage", group: false)
    static let sender = SenderRef(handle: "+15551234567", isMe: false)

    @Test func everyFixtureIsCoveredByAGolden() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
            .filter { $0.hasSuffix(".ndjson") }.map { String($0.dropLast(".ndjson".count)) }
        let covered: Set<String> = [
            "initialize", "initialize_no_database", "probe", "probe_zero_permissions", "grant",
            "policy.get", "policy.get_absent", "policy.set", "watch.subscribe", "watch.subscribe_now",
            "watch.unsubscribe", "messages.after", "send.text", "send.text_uncertain",
            "send.text_failed", "send.file", "attachment.fetch", "shutdown",
            "error.not_initialized", "error.protocol_mismatch", "error.permission_denied",
            "error.db_schema_unexpected", "error.policy_violation", "error.busy",
            "error.conversion_failed",
            "notification.message", "notification.message_reaction",
            "notification.message_decode_error", "notification.watch.overflow",
            "notification.db.state", "notification.db.state_available",
            "notification.send.reconciled", "notification.send.reconciled_uncertain",
        ]
        #expect(Set(names) == covered)
        #expect(Set(Method.allCases.map(\.rawValue)) == Set([
            "initialize", "probe", "grant", "policy.get", "policy.set", "watch.subscribe",
            "watch.unsubscribe", "messages.after", "send.text", "send.file", "attachment.fetch",
            "shutdown",
        ]))
    }

    @Test func initializeRoundTrips() throws {
        for (name, generation) in [("initialize", DBGeneration(inode: 279_744, birthTime: 1_770_428_605)),
                                   ("initialize_no_database", nil)] {
            let lines = try Self.lines(name)
            let request = try Self.request(lines[0])
            #expect(request.method == "initialize")
            let params = try request.params(InitializeParams.self).get()
            #expect(params.protocolVersion == 1)
            #expect(params.client == "fermix 0.13.0")
            let result = InitializeResult(protocolVersion: 1, helperVersion: "0.1.0", macosVersion: "27.0.0",
                                          bundleId: "io.tezra.fermix.messages", dbGeneration: generation)
            #expect(Self.text(Wire.encodeResult(id: request.id, result)) == lines[1])
        }
    }

    @Test func probeAndGrantRoundTrip() throws {
        let full = ProbeResult(fullDiskAccess: .granted, db: .readable, automation: .granted,
                               messagesRunning: true, signedIn: .yes, userSession: true,
                               policy: .confirmed, selfAliases: ["+15551234567", "owner@example.com"])
        let zero = ProbeResult(fullDiskAccess: .denied, db: .unreadable, automation: .unknown,
                               messagesRunning: false, signedIn: .unknown, userSession: true,
                               policy: .absent, selfAliases: nil)
        let granted = ProbeResult(fullDiskAccess: .granted, db: .readable, automation: .granted,
                                  messagesRunning: true, signedIn: .yes, userSession: true,
                                  policy: .absent, selfAliases: [])
        for (name, result) in [("probe", full), ("probe_zero_permissions", zero), ("grant", granted)] {
            let lines = try Self.lines(name)
            let request = try Self.request(lines[0])
            #expect(Self.text(Wire.encodeResult(id: request.id, result)) == lines[1])
        }
        let grant = try Self.request(try Self.lines("grant")[0]).params(GrantParams.self).get()
        #expect(grant.service == .automation)
    }

    @Test func policyMethodsRoundTrip() throws {
        let get = try Self.lines("policy.get")
        let view = PolicyView(posture: .dedicatedAccount, ownerHandle: "+15551234567",
                              handles: ["+15551234567", "guest@example.com"],
                              confirmedAt: "2026-10-03T12:00:00.000Z")
        #expect(Self.text(Wire.encodeResult(id: 4, view)) == get[1])
        let absent = try Self.lines("policy.get_absent")
        #expect(Self.text(Wire.encodeResult(id: 4, PolicyView?.none)) == absent[1])

        let set = try Self.lines("policy.set")
        let params = try Self.request(set[0]).params(PolicySetParams.self).get()
        #expect(params.posture == .dedicatedAccount)
        #expect(params.ownerHandle == "+15551234567")
        #expect(params.handles == ["+1 555 123 4567", "Guest@Example.com"])
        let confirmed = PolicySetResult(confirmedAt: "2026-10-03T12:00:00.000Z")
        #expect(Self.text(Wire.encodeResult(id: 5, confirmed)) == set[1])
    }

    @Test func watchMethodsRoundTrip() throws {
        let bounded = try Self.lines("watch.subscribe")
        let params = try Self.request(bounded[0]).params(SubscribeParams.self).get()
        #expect(params.sinceRowid == 41)
        #expect(params.replay == ReplayBounds(maxRows: 50, maxAgeS: 600))
        #expect(params.bufferLimit == 256)
        #expect(Self.text(Wire.encodeResult(id: 6, SubscribeResult(startedAtRowid: 120, replaySkipped: 3)))
            == bounded[1])

        let now = try Self.lines("watch.subscribe_now")
        let nowParams = try Self.request(now[0]).params(SubscribeParams.self).get()
        #expect(nowParams.sinceRowid == nil)
        #expect(nowParams.replay == nil)
        #expect(Self.text(Wire.encodeResult(id: 6, SubscribeResult(startedAtRowid: 120, replaySkipped: 0)))
            == now[1])

        let unsubscribe = try Self.lines("watch.unsubscribe")
        #expect(Self.text(Wire.encodeResult(id: 7, EmptyResult())) == unsubscribe[1])
        let shutdown = try Self.lines("shutdown")
        #expect(Self.text(Wire.encodeResult(id: 12, EmptyResult())) == shutdown[1])
    }

    @Test func messagesAfterRoundTrips() throws {
        let lines = try Self.lines("messages.after")
        let params = try Self.request(lines[0]).params(MessagesAfterParams.self).get()
        #expect(params.sinceRowid == 41)
        #expect(params.limit == 64)
        let event = MessageEvent(rowid: 42, guid: "5C1A4E1B-0000-4000-8000-000000000042", chat: Self.chat,
                                 sender: Self.sender, date: "2026-10-03T12:00:00.250Z",
                                 text: "what is on my calendar today?", decodeError: nil, replyToGuid: nil,
                                 attachments: [], reaction: nil)
        let result = MessagesAfterResult(messages: [event], hasMore: false)
        #expect(Self.text(Wire.encodeResult(id: 8, result)) == lines[1])
    }

    @Test func sendMethodsRoundTrip() throws {
        let text = try Self.lines("send.text")
        let params = try Self.request(text[0]).params(SendTextParams.self).get()
        #expect(params.to == "+15551234567")
        #expect(params.idempotencyKey == "del-1:0")
        let recorded = SendResult(disposition: .recorded, guid: "5C1A4E1B-0000-4000-8000-000000000043",
                                  rowid: 43, failureClass: nil)
        #expect(Self.text(Wire.encodeResult(id: 9, recorded)) == text[1])
        let uncertain = try Self.lines("send.text_uncertain")
        #expect(Self.text(Wire.encodeResult(id: 9, SendResult.uncertain)) == uncertain[1])
        let failed = try Self.lines("send.text_failed")
        #expect(Self.text(Wire.encodeResult(id: 9, SendResult.failed(.policyViolation))) == failed[1])

        let file = try Self.lines("send.file")
        let fileParams = try Self.request(file[0]).params(SendFileParams.self).get()
        #expect(fileParams.path == "/Users/owner/.fermix/imessage/outbox/6F1D/photo.jpg")
        #expect(fileParams.mime == "image/jpeg")
        let fileResult = SendResult(disposition: .recorded, guid: "5C1A4E1B-0000-4000-8000-000000000044",
                                    rowid: 44, failureClass: nil)
        #expect(Self.text(Wire.encodeResult(id: 10, fileResult)) == file[1])
    }

    @Test func attachmentFetchRoundTrips() throws {
        let lines = try Self.lines("attachment.fetch")
        let params = try Self.request(lines[0]).params(AttachmentFetchParams.self).get()
        #expect(params == AttachmentFetchParams(messageGuid: "5C1A4E1B-0000-4000-8000-000000000045",
                                                index: 0, convert: true))
        let result = AttachmentFetchResult(
            path: "/Users/owner/.fermix/imessage/inbox/5C1A4E1B-0000-4000-8000-000000000045/0-Audio_Message.m4a",
            mime: "audio/mp4", bytes: 48213)
        #expect(Self.text(Wire.encodeResult(id: 11, result)) == lines[1])
    }

    @Test func errorsRoundTrip() throws {
        let cases: [(String, HelperError)] = [
            ("error.not_initialized", HelperError(.notInitialized, "initialize must be the first request")),
            ("error.protocol_mismatch", HelperError(.protocolMismatch, "helper speaks protocol 1, client asked for 2",
                                                    data: ["helper": .int(1), "client": .int(2)])),
            ("error.permission_denied", .permissionDenied(.fullDiskAccess, "chat.db: authorization denied")),
            ("error.db_schema_unexpected", .schemaUnexpected(missing: ["message.destination_caller_id"])),
            ("error.policy_violation", .policyViolation(handle: "5551234567",
                                                        "handle is not in normalized form (E.164 or email)")),
            ("error.busy", HelperError(.busy, "32 requests outstanding")),
            ("error.conversion_failed", HelperError(.conversionFailed, "afconvert exited 1")),
        ]
        for (name, error) in cases {
            let lines = try Self.lines(name)
            let request = try Self.request(lines[0])
            #expect(Self.text(Wire.encodeError(id: request.id, error)) == lines[1], "\(name)")
        }
    }

    @Test func notificationsRoundTrip() throws {
        let attachment = AttachmentRef(index: 0, guid: "AT-1", name: "Audio Message.caf", mime: "audio/x-caf",
                                       bytes: 48213)
        let voice = MessageEvent(rowid: 45, guid: "5C1A4E1B-0000-4000-8000-000000000045", chat: Self.chat,
                                 sender: Self.sender, date: "2026-10-03T12:00:01.000Z", text: nil,
                                 decodeError: nil, replyToGuid: nil, attachments: [attachment], reaction: nil)
        let reaction = MessageEvent(rowid: 46, guid: "5C1A4E1B-0000-4000-8000-000000000046", chat: Self.chat,
                                    sender: Self.sender, date: "2026-10-03T12:00:02.000Z",
                                    text: "Liked “Your calendar is clear.”", decodeError: nil, replyToGuid: nil,
                                    attachments: [],
                                    reaction: Reaction(type: 2001,
                                                       targetGuid: "5C1A4E1B-0000-4000-8000-000000000043"))
        let broken = MessageEvent(rowid: 47, guid: "5C1A4E1B-0000-4000-8000-000000000047", chat: Self.chat,
                                  sender: Self.sender, date: "2026-10-03T12:00:03.000Z", text: nil,
                                  decodeError: "truncated", replyToGuid: "5C1A4E1B-0000-4000-8000-000000000043",
                                  attachments: [], reaction: nil)
        let cases: [(String, Data)] = [
            ("notification.message", Wire.encodeNotification(.message, voice)),
            ("notification.message_reaction", Wire.encodeNotification(.message, reaction)),
            ("notification.message_decode_error", Wire.encodeNotification(.message, broken)),
            ("notification.watch.overflow", Wire.encodeNotification(.watchOverflow,
                                                                    OverflowEvent(dropped: 44, resumeAfterRowid: 300))),
            ("notification.db.state", Wire.encodeNotification(.dbState,
                                                              DBStateEvent(state: .unavailable,
                                                                           eventClass: "generation_changed"))),
            ("notification.db.state_available", Wire.encodeNotification(.dbState,
                                                                        DBStateEvent(state: .available,
                                                                                     eventClass: nil))),
            ("notification.send.reconciled", Wire.encodeNotification(.sendReconciled,
                                                                     ReconciledEvent(idempotencyKey: "del-1:0",
                                                                                     disposition: .recorded,
                                                                                     guid: "5C1A4E1B-0000-4000-8000-000000000043"))),
            ("notification.send.reconciled_uncertain", Wire.encodeNotification(.sendReconciled,
                                                                               ReconciledEvent(idempotencyKey: "del-1:0",
                                                                                               disposition: .uncertain,
                                                                                               guid: nil))),
        ]
        for (name, data) in cases {
            let golden = try Self.lines(name)[0]
            #expect(Self.text(data) == golden, "\(name)")
        }
    }

    @Test func malformedLinesAreProtocolErrors() {
        for line in ["not json", "[1,2]", "{\"method\":\"probe\"}", "{\"id\":\"1\",\"method\":\"probe\"}",
                     "{\"id\":1.5,\"method\":\"probe\"}", "{\"id\":1}", "{\"id\":1,\"method\":7}", ""] {
            if case .success = Wire.decodeRequest(Data(line.utf8)) {
                Issue.record("accepted \(line)")
            }
        }
    }

    @Test func malformedParamsAreProtocolMismatch() throws {
        let lines = [
            "{\"id\":1,\"method\":\"messages.after\",\"params\":{\"since_rowid\":\"x\",\"limit\":5}}",
            "{\"id\":1,\"method\":\"messages.after\",\"params\":{\"since_rowid\":1,\"limit\":257}}",
            "{\"id\":1,\"method\":\"messages.after\",\"params\":{\"since_rowid\":1,\"limit\":0}}",
            "{\"id\":1,\"method\":\"messages.after\"}",
            "{\"id\":1,\"method\":\"watch.subscribe\",\"params\":{\"since_rowid\":null,\"replay\":null,\"buffer_limit\":0}}",
            "{\"id\":1,\"method\":\"grant\",\"params\":{\"service\":\"contacts\"}}",
            "{\"id\":1,\"method\":\"policy.set\",\"params\":{\"posture\":\"guest\",\"owner_handle\":\"+15551234567\",\"handles\":[]}}",
            "{\"id\":1,\"method\":\"attachment.fetch\",\"params\":{\"message_guid\":\"g\",\"index\":-1,\"convert\":false}}",
        ]
        let decoders: [String: (Request) -> HelperError?] = [
            "messages.after": { $0.params(MessagesAfterParams.self).failureValue },
            "watch.subscribe": { $0.params(SubscribeParams.self).failureValue },
            "grant": { $0.params(GrantParams.self).failureValue },
            "policy.set": { $0.params(PolicySetParams.self).failureValue },
            "attachment.fetch": { $0.params(AttachmentFetchParams.self).failureValue },
        ]
        for line in lines {
            let request = try Self.request(line)
            let error = decoders[request.method]?(request)
            #expect(error?.kind == .protocolMismatch, "\(line)")
        }
    }

    @Test func theErrorVocabularyIsClosed() {
        #expect(ErrorKind.allCases.map(\.rawValue).sorted() == [
            "attachment_not_admitted", "attachment_too_large", "automation_refused", "busy",
            "chat_not_found", "conversion_failed", "db_missing", "db_schema_unexpected", "db_unreadable",
            "no_user_session", "not_initialized", "not_signed_in", "owner_not_self", "path_refused",
            "permission_denied", "policy_absent", "policy_refused", "policy_unconfirmed",
            "policy_violation", "protocol_mismatch", "send_timeout", "service_not_imessage",
        ])
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
