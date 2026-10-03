import Testing
@testable import FermixMessagesCore

@Suite struct HandlesTests {
    @Test func phoneNumbersBecomeE164WithoutSeparators() {
        #expect(Handles.normalize("+1 (555) 123-4567") == .success("+15551234567"))
        #expect(Handles.normalize("+44 20 7946 0958") == .success("+442079460958"))
        #expect(Handles.normalize("+1.555.123.4567") == .success("+15551234567"))
        #expect(Handles.normalize("  +15551234567 ") == .success("+15551234567"))
        #expect(Handles.normalize("+1\t555 123 4567") == .success("+15551234567"))
        #expect(Handles.normalize("+1 555\u{00a0}123 4567") == .failure(.notNormalizable("+1 555\u{00a0}123 4567")),
                "the engine's \\s is ASCII-only")
    }

    @Test func emailsAreLowerCased() {
        #expect(Handles.normalize("Someone@Example.COM") == .success("someone@example.com"))
        #expect(Handles.normalize(" a.b+c@icloud.com ") == .success("a.b+c@icloud.com"))
        #expect(Handles.normalize("+Plus@Example.com") == .success("+plus@example.com"))
        #expect(Handles.normalize("a@b") == .success("a@b"), "the engine's rule: no dot required")
    }

    @Test func anythingElseIsRefusedWithTheHandle() {
        for raw in ["5551234567", "+0123456", "+1", "tel:+15551234567", "user@", "@example.com",
                    "two@at@example.com", "has space@example.com", "", "+1555abc4567",
                    "+1234567890123456", "1+5551234567"] {
            #expect(Handles.normalize(raw) == .failure(.notNormalizable(raw)), "accepted \(raw)")
        }
    }

    @Test func normalizeAllReportsTheFirstBadHandle() {
        #expect(Handles.normalizeAll(["+15551234567", "x", "y"]) == .failure(.notNormalizable("x")))
        #expect(Handles.normalizeAll(["B@example.com", "+15551234567", "b@example.com"])
            == .success(["+15551234567", "b@example.com"]))
    }

    @Test func redactionKeepsOnlyTheEdges() {
        #expect(Handles.redact("+15551234567") == "+1555…4567")
        #expect(Handles.redact("someone@example.com") == "s…@example.com")
        #expect(Handles.redact("weird") == "…")
        #expect(Handles.redact("+123") == "…")
        #expect(Handles.redact("5551234567") == "55512…4567")
    }

    @Test func displayFormGroupsNorthAmericanNumbers() {
        #expect(Handles.display("+15551234567") == "+1 555 123 4567")
        #expect(Handles.display("+442079460958") == "+442079460958")
        #expect(Handles.display("someone@example.com") == "someone@example.com")
    }
}
