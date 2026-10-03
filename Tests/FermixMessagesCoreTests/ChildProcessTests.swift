import Foundation
import Testing
@testable import FermixMessagesCore

@Suite struct ChildProcessTests {
    @Test func outputAndStatusAreCaptured() throws {
        let result = try BoundedChild.run("/bin/sh", ["-c", "printf out; printf err >&2; exit 3"], timeout: 10)
        #expect(result.termination == .exited(3))
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err")
    }

    @Test func argumentsArePassedVerbatimNeverThroughAShell() throws {
        let hostile = "-e $(touch /nonexistent); \"quoted\" `x` \n second line"
        let result = try BoundedChild.run("/usr/bin/printf", ["%s", hostile], timeout: 10)
        #expect(result.termination == .exited(0))
        #expect(String(decoding: result.stdout, as: UTF8.self) == hostile)
    }

    @Test func anExpiredChildAndItsProcessGroupAreKilled() throws {
        let directory = TestDirectory()
        let marker = directory.path + "/survivor"
        let start = Date()
        let result = try BoundedChild.run("/bin/sh", ["-c", "(sleep 2; touch '\(marker)') & sleep 30"],
                                          timeout: 0.3)
        #expect(result.termination == .timedOut)
        #expect(Date().timeIntervalSince(start) < 5)
        Thread.sleep(forTimeInterval: 2.5)
        #expect(!FileManager.default.fileExists(atPath: marker), "the grandchild outlived the group kill")
    }

    @Test func outputBeyondTheCapIsDiscardedWithoutBlockingTheChild() throws {
        let result = try BoundedChild.run("/bin/sh", ["-c", "head -c 300000 /dev/zero"], timeout: 10, outputCap: 1000)
        #expect(result.termination == .exited(0))
        #expect(result.stdout.count == 1000)
    }

    @Test func aMissingExecutableIsAnError() {
        #expect(throws: ChildError.self) { try BoundedChild.run("/nonexistent/tool", [], timeout: 1) }
    }
}
