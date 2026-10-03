import Foundation
import Testing
@testable import FermixMessagesCore

@Suite struct FilesTests {
    @Test func homeDirectoriesAreCreatedOwnerOnly() throws {
        let directory = TestDirectory()
        let paths = try HelperPaths.resolve(home: directory.sub("home"))
        try paths.prepare()
        for dir in [paths.root, paths.helperDir, paths.inbox, paths.outbox] {
            let mode = try #require(FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? Int)
            #expect(mode == 0o700, "\(dir)")
        }
        #expect(paths.ledger == paths.home + "/imessage/helper/ledger.sqlite")
        #expect(throws: HelperPathsError.self) { try HelperPaths.resolve(home: directory.path + "/absent") }
    }

    @Test func aFileUnderTheRootResolves() throws {
        let directory = TestDirectory()
        let root = directory.sub("outbox")
        let file = directory.sub("outbox/u1") + "/photo.jpg"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        #expect(SafePath.resolve(file, under: root) == .success(file))
    }

    @Test func pathsOutsideTheRootOrThroughASymlinkAreRefused() throws {
        let directory = TestDirectory()
        let root = directory.sub("outbox")
        let elsewhere = directory.sub("elsewhere")
        let secret = elsewhere + "/secret.txt"
        try Data("s".utf8).write(to: URL(fileURLWithPath: secret))
        #expect(SafePath.resolve(secret, under: root).failureValue != nil)

        #expect(symlink(secret, root + "/link.txt") == 0)
        #expect(SafePath.resolve(root + "/link.txt", under: root).failureValue != nil, "symlinked file")

        #expect(symlink(elsewhere, root + "/dir") == 0)
        #expect(SafePath.resolve(root + "/dir/secret.txt", under: root).failureValue != nil, "symlinked directory")

        let inside = directory.sub("outbox/u2") + "/a.txt"
        try Data("a".utf8).write(to: URL(fileURLWithPath: inside))
        #expect(SafePath.resolve(root + "/u2/../../elsewhere/secret.txt", under: root).failureValue != nil)
        #expect(SafePath.resolve("relative/a.txt", under: root).failureValue != nil)
        #expect(SafePath.resolve(root + "/u2/missing.txt", under: root).failureValue != nil)
        #expect(SafePath.resolve(root + "/u2", under: root).failureValue != nil, "a directory is not a file")
    }

    @Test func aRootThatIsItselfASymlinkIsRefused() throws {
        let directory = TestDirectory()
        let real = directory.sub("real")
        try Data("a".utf8).write(to: URL(fileURLWithPath: real + "/a.txt"))
        #expect(symlink(real, directory.path + "/outbox") == 0)
        #expect(SafePath.resolve(directory.path + "/outbox/a.txt", under: directory.path + "/outbox").failureValue
            != nil)
    }

    @Test func aSymlinkAboveTheRootIsFine() throws {
        let directory = TestDirectory()
        let real = directory.sub("real")
        let root = directory.sub("real/outbox")
        try Data("a".utf8).write(to: URL(fileURLWithPath: root + "/a.txt"))
        #expect(symlink(real, directory.path + "/alias") == 0)
        #expect(SafePath.resolve(directory.path + "/alias/outbox/a.txt", under: root) == .success(root + "/a.txt"))
    }

    @Test func copiesAreCappedHashedAndExclusive() throws {
        let directory = TestDirectory()
        let source = directory.path + "/source.bin"
        try Data(repeating: 7, count: 5000).write(to: URL(fileURLWithPath: source))
        let copied = try FileCopy.copy(from: source, to: directory.path + "/dest.bin", cap: 5000).get()
        #expect(copied.bytes == 5000)
        #expect(copied.sha256 == FileCopy.sha256(Data(repeating: 7, count: 5000)))
        #expect(FileCopy.copy(from: source, to: directory.path + "/dest.bin", cap: 5000).failureValue != nil,
                "never overwrites")
        #expect(FileCopy.copy(from: source, to: directory.path + "/small.bin", cap: 4999).failureValue == .tooLarge)
        #expect(!FileManager.default.fileExists(atPath: directory.path + "/small.bin"), "a capped copy leaves nothing")
    }

    @Test func namesAreSanitized() {
        #expect(FileNames.sanitize("Audio Message.caf") == "Audio_Message.caf")
        #expect(FileNames.sanitize("../../etc/passwd") == "passwd")
        #expect(FileNames.sanitize("") == "attachment")
        #expect(FileNames.sanitize("..") == "attachment")
        #expect(FileNames.sanitize("ünï cødé.jpg") == "_n__c_d_.jpg")
        #expect(FileNames.sanitize(String(repeating: "a", count: 300) + ".png").count == 100)
        #expect(FileNames.sanitize(String(repeating: "a", count: 300) + ".png").hasSuffix(".png"))
    }

    @Test func evictionKeepsTheRootUnderItsCapOldestFirst() throws {
        let directory = TestDirectory()
        let root = directory.sub("staging")
        for (index, name) in ["old", "mid", "new"].enumerated() {
            let entry = directory.sub("staging/\(name)")
            try Data(repeating: 1, count: 400).write(to: URL(fileURLWithPath: entry + "/f"))
            let date = Date(timeIntervalSince1970: 1_000_000 + Double(index) * 100)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: entry)
        }
        let removed = try FileTree.evictOldest(in: root, toFit: 300, cap: 1000)
        #expect(removed == ["old", "mid"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root) == ["new"])
    }

    @Test func entriesOlderThanTheAgeAreRemoved() throws {
        let directory = TestDirectory()
        let root = directory.sub("inbox")
        let stale = directory.sub("inbox/stale")
        directory.sub("inbox/fresh")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90_000)],
                                              ofItemAtPath: stale)
        let removed = try FileTree.removeOlder(in: root, than: 86_400, now: Date())
        #expect(removed == ["stale"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root) == ["fresh"])
    }
}
