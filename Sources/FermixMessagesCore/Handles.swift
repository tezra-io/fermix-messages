import Foundation

/// The one handle normalizer (design §7.4), rule for rule the engine's
/// `IMessage.Protocol.normalize_handle/1`: both sides key every policy decision on it.
///
/// - anything with an `@` is an email: one `@`, non-empty sides, no whitespace,
///   lower-cased;
/// - anything else is a phone number: whitespace, `-`, `.`, `(` and `)` removed, then
///   E.164 (`+`, a non-zero country digit, 7 to 15 digits in all);
/// - anything else is refused with the raw handle, never guessed at (no default region).
public enum Handles {
    public enum Failure: Error, Equatable {
        case notNormalizable(String)
    }

    /// PCRE's `\s` without Unicode mode, as the engine's regexes use it.
    private static let asciiWhitespace: Set<Character> = [" ", "\t", "\n", "\u{0B}", "\u{0C}", "\r", "\r\n"]
    private static let phoneSeparators: Set<Character> = asciiWhitespace.union(["-", ".", "(", ")"])

    public static func normalize(_ raw: String) -> Result<String, Failure> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") {
            return normalizeEmail(trimmed, raw: raw)
        }
        return normalizePhone(trimmed, raw: raw)
    }

    /// Normalizes every handle, de-duplicates and sorts them, and reports the first
    /// handle that is not in a normalizable form.
    public static func normalizeAll(_ raws: [String]) -> Result<[String], Failure> {
        var out = Set<String>()
        for raw in raws {
            switch normalize(raw) {
            case .success(let handle): out.insert(handle)
            case .failure(let failure): return .failure(failure)
            }
        }
        return .success(out.sorted())
    }

    /// The log form (design §13), the engine's `redact_handle/1`: `s…@example.com` for an
    /// email, `+1555…4567` for anything of ten characters or more, `…` otherwise.
    public static func redact(_ handle: String) -> String {
        if let at = handle.firstIndex(of: "@"), at > handle.startIndex {
            return String(handle[handle.startIndex]) + "…" + String(handle[at...])
        }
        guard handle.count >= 10 else { return "…" }
        return String(handle.prefix(5)) + "…" + String(handle.suffix(4))
    }

    /// The consent dialog's form: a North American number reads `+1 555 123 4567`;
    /// every other handle is shown exactly as it is stored.
    public static func display(_ handle: String) -> String {
        let digits = Array(handle.dropFirst())
        guard handle.hasPrefix("+1"), digits.count == 11 else { return handle }
        let area = String(digits[1...3]), exchange = String(digits[4...6]), line = String(digits[7...10])
        return "+1 \(area) \(exchange) \(line)"
    }

    private static func normalizePhone(_ trimmed: String, raw: String) -> Result<String, Failure> {
        let compact = trimmed.filter { !phoneSeparators.contains($0) }
        let digits = compact.dropFirst()
        guard compact.hasPrefix("+"), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              (7...15).contains(digits.count), digits.first != "0" else {
            return .failure(.notNormalizable(raw))
        }
        return .success(compact)
    }

    private static func normalizeEmail(_ trimmed: String, raw: String) -> Result<String, Failure> {
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }), !trimmed.contains(where: asciiWhitespace.contains) else {
            return .failure(.notNormalizable(raw))
        }
        return .success(trimmed.lowercased())
    }
}
