import Foundation

/// The one handle normalizer (design §7.4): the engine and the helper key every policy
/// decision on its output, so it is the only place a handle's spelling is decided.
///
/// - phone numbers become E.164: a leading `+`, a non-zero country digit, 7 to 15 digits
///   in all, with spaces, dashes, dots and parentheses removed;
/// - emails are lower-cased: one `@`, a non-empty local part, a dotted domain, no spaces;
/// - anything else is refused with the raw handle, never guessed at (no default region).
public enum Handles {
    public enum Failure: Error, Equatable {
        case notNormalizable(String)
    }

    private static let phoneSeparators: Set<Character> = [" ", "-", ".", "(", ")"]

    public static func normalize(_ raw: String) -> Result<String, Failure> {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("+") {
            return normalizePhone(trimmed, raw: raw)
        }
        return normalizeEmail(trimmed, raw: raw)
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

    /// The log form (design §13): `+1555…4567`, `s…@example.com`; anything that is not
    /// a recognisable handle shows only its length.
    public static func redact(_ handle: String) -> String {
        if handle.hasPrefix("+"), handle.count >= 9 {
            return String(handle.prefix(5)) + "…" + String(handle.suffix(4))
        }
        if let at = handle.firstIndex(of: "@"), at > handle.startIndex {
            return String(handle[handle.startIndex]) + "…" + String(handle[at...])
        }
        return "…(\(handle.count))"
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
        let digits = trimmed.dropFirst().filter { !phoneSeparators.contains($0) }
        let allDigits = digits.allSatisfy { $0.isASCII && $0.isNumber }
        guard allDigits, (7...15).contains(digits.count), digits.first != "0" else {
            return .failure(.notNormalizable(raw))
        }
        return .success("+" + digits)
    }

    private static func normalizeEmail(_ trimmed: String, raw: String) -> Result<String, Failure> {
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !trimmed.contains(" ") else {
            return .failure(.notNormalizable(raw))
        }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else {
            return .failure(.notNormalizable(raw))
        }
        return .success(trimmed.lowercased())
    }
}
