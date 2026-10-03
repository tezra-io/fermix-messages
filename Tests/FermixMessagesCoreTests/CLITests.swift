import Foundation
import Testing
@testable import FermixMessagesCore

@Suite struct CLITests {
    @Test func everySubcommandParses() {
        #expect(CLI.parse(["--version"]) == .success(.version))
        #expect(CLI.parse(["serve", "--home", "/h"]) == .success(.serve(home: "/h")))
        #expect(CLI.parse(["probe", "--home", "/h"]) == .success(.probe(home: "/h")))
        #expect(CLI.parse(["grant", "--service", "automation", "--home", "/h"])
            == .success(.grant(home: "/h", service: .automation)))
        #expect(CLI.parse(["grant", "--home", "/h", "--service", "full_disk_access"])
            == .success(.grant(home: "/h", service: .fullDiskAccess)))
        #expect(CLI.parse(["policy-get", "--home", "/h"]) == .success(.policyGet(home: "/h")))
        #expect(CLI.parse(["policy-set", "--home", "/h", "--posture", "dedicated_account", "--owner", "+15551234567",
                           "--handle", "+15551234567", "--handle", "guest@example.com"])
            == .success(.policySet(home: "/h", posture: .dedicatedAccount, owner: "+15551234567",
                                   handles: ["+15551234567", "guest@example.com"])))
        #expect(CLI.parse(["policy-set", "--home", "/h", "--posture", "own_account", "--owner", "a@b.co"])
            == .success(.policySet(home: "/h", posture: .ownAccount, owner: "a@b.co", handles: [])))
    }

    @Test func usageErrorsAreRefused() {
        let bad: [[String]] = [
            [], ["help"], ["serve"], ["serve", "--home"], ["serve", "--home", "/h", "--home", "/i"],
            ["serve", "--home", "/h", "--extra", "x"], ["probe", "/h"], ["grant", "--home", "/h"],
            ["grant", "--home", "/h", "--service", "contacts"], ["policy-get"], ["policy", "get", "--home", "/h"],
            ["policy-set", "--home", "/h", "--posture", "dedicated_account"],
            ["policy-set", "--home", "/h", "--posture", "guest", "--owner", "x"],
            ["policy-set", "--home", "/h", "--posture", "own_account", "--owner", "x", "--handle"],
            ["policy-get", "--home", "/h", "--handle", "x"],
            ["--version", "extra"],
        ]
        for arguments in bad {
            #expect(CLI.parse(arguments).failureValue != nil, "\(arguments)")
        }
        #expect(CLI.main(["fermix-messages", "bogus"]) == ExitCode.usage)
    }

    @Test func exitCodesFollowTheDisclaimContract() {
        #expect(ExitCode.usage == 64)
        #expect(ExitCode.disclaimUnavailable == 70)
        #expect(ExitCode.disclaimRefused == 71)
        #expect(ExitCode.execFailed == 72)
        #expect(ExitCode.io == 74)
        #expect(ExitCode.temporary == 75)
        #expect(ExitCode.protocolError == 76)
    }

    @Test func theDisclaimSentinelIsExactlyOne() {
        #expect(SelfDisclaim.isDisclaimed(["FERMIX_MESSAGES_DISCLAIMED": "1"]))
        #expect(!SelfDisclaim.isDisclaimed(["FERMIX_MESSAGES_DISCLAIMED": "0"]))
        #expect(!SelfDisclaim.isDisclaimed(["FERMIX_MESSAGES_DISCLAIMED": "yes"]))
        #expect(!SelfDisclaim.isDisclaimed([:]))
    }

    @Test func theDisclaimSymbolResolvesOnThisMacOS() {
        #expect(SelfDisclaim.resolveSetDisclaim() != nil)
    }
}
