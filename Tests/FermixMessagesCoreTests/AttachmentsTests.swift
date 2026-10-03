import Foundation
import Testing
@testable import FermixMessagesCore

final class FakeConverter: MediaConverting {
    var fails = false
    private(set) var calls: [Conversion] = []

    func convert(_ conversion: Conversion, input: String, output: String) -> Result<Void, HelperError> {
        calls.append(conversion)
        if fails { return .failure(HelperError(.conversionFailed, "\(conversion) exited 1")) }
        do {
            try FileManager.default.copyItem(atPath: input, toPath: output)
            return .success(())
        } catch {
            return .failure(HelperError(.conversionFailed, "\(error)"))
        }
    }
}

final class FetchHarness {
    let watch: WatchHarness
    let converter = FakeConverter()
    var cap: Int64 = 100 * 1024 * 1024
    var fixture: ChatDBFixture { watch.fixture }
    var inbox: String { watch.base.paths.inbox }

    init(policy: StoredPolicy? = .dedicated(guests: ["guest@example.com"])) {
        watch = WatchHarness(policy: policy)
    }

    func fetcher() -> AttachmentFetcher {
        AttachmentFetcher(feed: watch.feed, inbox: inbox, converter: converter, cap: cap, log: watch.base.log.logger,
                          now: Date.init)
    }

    /// An inbound message with one attachment whose file exists under the synthetic
    /// Attachments root, referenced with a `~` path as Messages writes it.
    @discardableResult
    func message(name: String = "IMG_0001.HEIC", mime: String = "image/heic", bytes: Int = 64,
                 from handle: String = "+15551234567") -> (rowid: Int64, guid: String) {
        let row = watch.inbound("", from: handle)
        let relative = "Library/Messages/Attachments/ab/\(row.rowid)/\(UUID().uuidString)"
        let dir = fixture.directory.sub(relative)
        try! Data(repeating: 0x5a, count: bytes).write(to: URL(fileURLWithPath: dir + "/" + name))
        fixture.attachment(message: row.rowid, filename: "~/\(relative)/\(name)", mime: mime, bytes: Int64(bytes))
        return row
    }

    func emitAll() {
        _ = try! watch.feed.after(MessagesAfterParams(sinceRowid: 0, limit: 256)).get()
    }
}

@Suite struct AttachmentsTests {
    @Test func anEmittedAttachmentIsCopiedIntoTheInbox() throws {
        let harness = FetchHarness()
        let row = harness.message(name: "Photo 1.jpg", mime: "image/jpeg")
        harness.emitAll()
        let result = try harness.fetcher().fetch(AttachmentFetchParams(messageGuid: row.guid, index: 0, convert: true)).get()
        #expect(result.path == harness.inbox + "/\(row.guid)/0-Photo_1.jpg")
        #expect(result.mime == "image/jpeg")
        #expect(result.bytes == 64)
        #expect(harness.converter.calls.isEmpty, "nothing to convert for a JPEG")
        let mode = try FileManager.default.attributesOfItem(atPath: harness.inbox + "/\(row.guid)")[.posixPermissions]
        #expect(mode as? Int == 0o700)
    }

    @Test func conversionsProduceTheEngineFormats() throws {
        let harness = FetchHarness()
        let photo = harness.message(name: "IMG.HEIC", mime: "image/heic")
        let voice = harness.message(name: "Audio Message.caf", mime: "audio/x-caf")
        harness.emitAll()
        let jpeg = try harness.fetcher().fetch(AttachmentFetchParams(messageGuid: photo.guid, index: 0, convert: true)).get()
        #expect(jpeg.path.hasSuffix("/0-IMG.jpg"))
        #expect(jpeg.mime == "image/jpeg")
        let m4a = try harness.fetcher().fetch(AttachmentFetchParams(messageGuid: voice.guid, index: 0, convert: true)).get()
        #expect(m4a.path.hasSuffix("/0-Audio_Message.m4a"))
        #expect(m4a.mime == "audio/mp4")
        #expect(harness.converter.calls == [.heicToJpeg, .audioToM4a])
        #expect(!FileManager.default.fileExists(atPath: harness.inbox + "/\(voice.guid)/0-Audio_Message.caf"))
        let raw = try harness.fetcher().fetch(AttachmentFetchParams(messageGuid: voice.guid, index: 0, convert: false)).get()
        #expect(raw.path.hasSuffix("/0-Audio_Message.caf"))
    }

    @Test func aFailedConversionIsNamedAndLeavesNothing() throws {
        let harness = FetchHarness()
        harness.converter.fails = true
        let voice = harness.message(name: "a.caf", mime: "audio/x-caf")
        harness.emitAll()
        let error = harness.fetcher().fetch(AttachmentFetchParams(messageGuid: voice.guid, index: 0, convert: true))
        #expect(error.failureValue?.kind == .conversionFailed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.inbox + "/\(voice.guid)").isEmpty)
    }

    @Test func aMessageThisProcessNeverEmittedIsNotAdmitted() {
        let harness = FetchHarness()
        let row = harness.message()
        let error = harness.fetcher().fetch(AttachmentFetchParams(messageGuid: row.guid, index: 0, convert: false))
        #expect(error.failureValue?.kind == .attachmentNotAdmitted)
    }

    @Test func anAttachmentOfAnExcludedChatIsNotAdmitted() {
        let harness = FetchHarness()
        let stranger = harness.message(from: "+15550009999")
        harness.emitAll()
        let error = harness.fetcher().fetch(AttachmentFetchParams(messageGuid: stranger.guid, index: 0, convert: false))
        #expect(error.failureValue?.kind == .attachmentNotAdmitted)
    }

    @Test func aPolicyNarrowedAfterEmissionIsRecheckedAtFetch() {
        let harness = FetchHarness()
        let guest = harness.message(from: "guest@example.com")
        harness.emitAll()
        _ = harness.watch.base.store.save(.dedicated())
        let error = harness.fetcher().fetch(AttachmentFetchParams(messageGuid: guest.guid, index: 0, convert: false))
        #expect(error.failureValue?.kind == .attachmentNotAdmitted)
    }

    @Test func anIndexPastTheAttachmentsIsNotAdmitted() {
        let harness = FetchHarness()
        let row = harness.message()
        harness.emitAll()
        let error = harness.fetcher().fetch(AttachmentFetchParams(messageGuid: row.guid, index: 1, convert: false))
        #expect(error.failureValue?.kind == .attachmentNotAdmitted)
    }

    @Test func aSourceOutsideTheAttachmentsRootOrThroughASymlinkIsRefused() throws {
        let harness = FetchHarness()
        let outside = harness.watch.inbound("")
        let elsewhere = harness.fixture.directory.sub("elsewhere")
        try Data("secret".utf8).write(to: URL(fileURLWithPath: elsewhere + "/secret.txt"))
        harness.fixture.attachment(message: outside.rowid, filename: elsewhere + "/secret.txt", mime: nil, bytes: 6)
        let linked = harness.watch.inbound("")
        #expect(symlink(elsewhere, harness.fixture.location.attachmentsRoot + "/link") == 0)
        harness.fixture.attachment(message: linked.rowid, filename: "~/Library/Messages/Attachments/link/secret.txt",
                                   mime: nil, bytes: 6)
        harness.emitAll()
        for guid in [outside.guid, linked.guid] {
            let error = harness.fetcher().fetch(AttachmentFetchParams(messageGuid: guid, index: 0, convert: false))
            #expect(error.failureValue?.kind == .pathRefused)
        }
    }

    @Test func theByteCapHoldsDuringTheCopy() {
        let harness = FetchHarness()
        harness.cap = 10
        let row = harness.message(bytes: 11)
        harness.emitAll()
        let error = harness.fetcher().fetch(AttachmentFetchParams(messageGuid: row.guid, index: 0, convert: false))
        #expect(error.failureValue?.kind == .attachmentTooLarge)
    }

    @Test func inboxEntriesOlderThanADayAreRemovedOnEveryFetch() throws {
        let harness = FetchHarness()
        let stale = harness.fixture.directory.sub("fermix/imessage/inbox/stale-guid")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90_000)],
                                              ofItemAtPath: stale)
        let row = harness.message()
        harness.emitAll()
        _ = try harness.fetcher().fetch(AttachmentFetchParams(messageGuid: row.guid, index: 0, convert: false)).get()
        #expect(!FileManager.default.fileExists(atPath: stale))
    }

    @Test func conversionsAreChosenByMimeOrExtension() {
        #expect(Conversion.needed(mime: "audio/x-caf", name: "x") == .audioToM4a)
        #expect(Conversion.needed(mime: nil, name: "Audio Message.CAF") == .audioToM4a)
        #expect(Conversion.needed(mime: "audio/amr", name: "x.amr") == .audioToM4a)
        #expect(Conversion.needed(mime: "image/heic", name: "x") == .heicToJpeg)
        #expect(Conversion.needed(mime: nil, name: "x.heif") == .heicToJpeg)
        #expect(Conversion.needed(mime: "image/jpeg", name: "x.jpg") == nil)
        #expect(ToolConverter.arguments(.audioToM4a, input: "/a.caf", output: "/a.m4a")
            == ["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", "/a.caf", "/a.m4a"])
        #expect(ToolConverter.arguments(.heicToJpeg, input: "/a.heic", output: "/a.jpg")
            == ["/usr/bin/sips", "-s", "format", "jpeg", "/a.heic", "--out", "/a.jpg"])
    }
}
