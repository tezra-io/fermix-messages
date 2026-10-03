import AppKit
import Foundation
import Testing
@testable import FermixMessagesCore

/// Real typedstream input is GENERATED here with NSArchiver (archiving is allowed in
/// tests; nothing ever unarchives). The class is looked up at run time so the
/// deprecated API costs no compiler warning.
enum Archive {
    static func typedstream(_ object: Any) -> Data {
        guard let archiver: AnyObject = NSClassFromString("NSArchiver"),
              let result = archiver.perform(NSSelectorFromString("archivedDataWithRootObject:"), with: object),
              let data = result.takeUnretainedValue() as? Data else {
            preconditionFailure("NSArchiver unavailable")
        }
        return data
    }

    static func attributedBody(_ text: String) -> Data {
        typedstream(NSAttributedString(string: text))
    }
}

@Suite struct TypedstreamTests {
    @Test func plainAsciiDecodes() {
        #expect(Typedstream.extractText(Archive.attributedBody("hello world")) == .success("hello world"))
    }

    @Test func emojiAndAccentsDecode() {
        let text = "héllo 👋🏽 family 👨‍👩‍👧 日本語"
        #expect(Typedstream.extractText(Archive.attributedBody(text)) == .success(text))
    }

    @Test func aUrlDecodes() {
        let text = "see https://example.com/a/b?q=1&r=two#frag"
        #expect(Typedstream.extractText(Archive.attributedBody(text)) == .success(text))
    }

    @Test func longStringsUseTheWideLengthForms() {
        let tenK = String(repeating: "abcdefghij", count: 1000)
        #expect(Typedstream.extractText(Archive.attributedBody(tenK)) == .success(tenK))
        let seventyK = String(repeating: "z", count: 70_000)
        #expect(Typedstream.extractText(Archive.attributedBody(seventyK)) == .success(seventyK))
        for edge in [0, 1, 127, 128, 32767, 32768] {
            let text = String(repeating: "q", count: edge)
            #expect(Typedstream.extractText(Archive.attributedBody(text)) == .success(text), "length \(edge)")
        }
    }

    @Test func attributedRunsDecodeToTheWholeString() {
        let text = "bold, a link and a mention"
        let runs = NSMutableAttributedString(string: text)
        runs.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 12), range: NSRange(location: 0, length: 4))
        runs.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 8, length: 4))
        runs.addAttribute(NSAttributedString.Key("__kIMMentionConfirmedMention"), value: "+15551234567",
                          range: NSRange(location: 19, length: 7))
        #expect(Typedstream.extractText(Archive.typedstream(runs)) == .success(text))
        #expect(Typedstream.extractText(Archive.typedstream(NSMutableAttributedString(string: "m")))
            == .success("m"))
    }

    @Test func everyTruncationFailsOrYieldsTheWholeText() {
        let text = "truncate me 👋"
        let blob = [UInt8](Archive.attributedBody(text))
        for cut in 0..<blob.count {
            switch Typedstream.extractText(Data(blob[0..<cut])) {
            case .success(let decoded): #expect(decoded == text, "cut \(cut) gave a partial string")
            case .failure: continue
            }
        }
        // Cutting inside the string payload is always a failure.
        let marker = Self.find([0x84, 0x01, 0x2b], in: blob)!
        #expect(Typedstream.extractText(Data(blob[0..<(marker + 6)])) == .failure(.truncated))
    }

    @Test func oversizedInputIsRefusedBeforeParsing() {
        let big = Data(count: (1 << 20) + 1)
        #expect(Typedstream.extractText(big) == .failure(.tooLarge))
    }

    @Test func aWrongHeaderIsRefused() {
        var blob = [UInt8](Archive.attributedBody("x"))
        blob[2] = 0x53 // "Streamtyped"
        #expect(Typedstream.extractText(Data(blob)) == .failure(.badHeader))
        var version = [UInt8](Archive.attributedBody("x"))
        version[0] = 0x05
        #expect(Typedstream.extractText(Data(version)) == .failure(.badHeader))
        #expect(Typedstream.extractText(Data("typedstream".utf8)) == .failure(.badHeader))
    }

    @Test func nestedGarbageHitsTheDepthLimit() {
        var blob = Self.header + [0x84, 0x01, 0x40, 0x84]
        for _ in 0..<40 { blob += [0x84, 0x84, 0x01, 0x43, 0x00] }
        #expect(Typedstream.extractText(Data(blob)) == .failure(.tooDeep))
    }

    @Test func anUnexpectedRootClassIsRefused() {
        #expect(Typedstream.extractText(Archive.typedstream(["k": "v"] as NSDictionary))
            == .failure(.unexpectedClass))
        #expect(Typedstream.extractText(Archive.typedstream("bare string" as NSString))
            == .failure(.unexpectedClass))
    }

    @Test func invalidUtf8IsRefused() {
        var blob = [UInt8](Archive.attributedBody("abcd"))
        let marker = Self.find([0x84, 0x01, 0x2b, 0x04], in: blob)!
        blob[marker + 4] = 0xff
        #expect(Typedstream.extractText(Data(blob)) == .failure(.invalidUTF8))
    }

    @Test func aLengthPastTheEndIsTruncated() {
        var blob = [UInt8](Archive.attributedBody("abcd"))
        let marker = Self.find([0x84, 0x01, 0x2b, 0x04], in: blob)!
        blob.replaceSubrange((marker + 3)...(marker + 3), with: [0x82, 0xff, 0xff, 0x0f, 0x00])
        #expect(Typedstream.extractText(Data(blob)) == .failure(.truncated))
    }

    @Test func aReservedTagIsAGrammarError() {
        var blob = [UInt8](Archive.attributedBody("abcd"))
        let marker = Self.find([0x84, 0x01, 0x2b, 0x04], in: blob)!
        blob[marker + 3] = 0x8a
        #expect(Typedstream.extractText(Data(blob)) == .failure(.grammar))
    }

    @Test func theWallClockBudgetIsEnforced() {
        let limits = Typedstream.Limits(maxBytes: 1 << 20, maxDepth: 32, budgetNanoseconds: 0)
        #expect(Typedstream.extractText(Archive.attributedBody("x"), limits: limits) == .failure(.timeout))
    }

    @Test func randomBytesAfterAValidHeaderNeverCrashAndStayInBudget() {
        var generator = SplitMix(seed: 0x5eed)
        for _ in 0..<3000 {
            let count = Int(generator.next() % 600)
            let tail = (0..<count).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            let start = DispatchTime.now().uptimeNanoseconds
            _ = Typedstream.extractText(Data(Self.header + tail))
            #expect(DispatchTime.now().uptimeNanoseconds - start < 50_000_000)
        }
    }

    static let header: [UInt8] = [0x04, 0x0b] + Array("streamtyped".utf8) + [0x81, 0xe8, 0x03]

    static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        return (0...(haystack.count - needle.count)).first { Array(haystack[$0..<($0 + needle.count)]) == needle }
    }
}

/// A deterministic generator, so the fuzz case is reproducible.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
