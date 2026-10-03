import Foundation

/// A bounded STRUCTURAL extractor of the text inside a `message.attributedBody`
/// typedstream blob (design §7.2, D6). It walks the container's records and returns the
/// first string payload; it never instantiates an archived class (no `NSUnarchiver`, no
/// `NSKeyedUnarchiver`) and is written from the public description of the format.
///
/// The prefix it understands:
///
///     04 0b "streamtyped"         streamer version 4, the 11-byte signature
///     int                         system version (81 e8 03 = 1000)
///     84 01 40                    a new shared string "@": the root is an object
///     84 <class chain>            a new object of NSAttributedString or
///                                 NSMutableAttributedString (class, version, superclass…, 85)
///     <"@" or a reference>        the attributed string's first member, an object
///     84 <class chain>            a new NSString or NSMutableString
///     84 01 2b <len> <utf8>       a new shared string "+" (bytes with a length), then the text
///     86                          end of the string object
///
/// Integers are a signed byte, or 81 + int16 LE, or 82 + int32 LE; 84 is "new", 85 "nil",
/// 86 "end"; any other value in 80...91 is reserved. A reference is an integer whose
/// value + 110 indexes the records seen so far (so 92 is the first).
public enum Typedstream {
    public struct Limits {
        public let maxBytes: Int
        public let maxDepth: Int
        public let budgetNanoseconds: UInt64

        public static let standard = Limits(maxBytes: 1 << 20, maxDepth: 32, budgetNanoseconds: 50_000_000)
    }

    /// The `decode_error` classes on the wire.
    public enum DecodeError: String, Error, Equatable {
        case tooLarge = "too_large"
        case badHeader = "bad_header"
        case truncated
        case grammar
        case tooDeep = "too_deep"
        case timeout
        case invalidUTF8 = "invalid_utf8"
        case unexpectedClass = "unexpected_class"
    }

    static let signature = Array("streamtyped".utf8)
    static let rootClasses: Set<String> = ["NSAttributedString", "NSMutableAttributedString"]
    static let stringClasses: Set<String> = ["NSString", "NSMutableString"]

    public static func extractText(_ blob: Data, limits: Limits = .standard) -> Result<String, DecodeError> {
        guard blob.count <= limits.maxBytes else { return .failure(.tooLarge) }
        var cursor = Cursor(bytes: [UInt8](blob), limits: limits)
        do {
            try cursor.header()
            try cursor.rootObject()
            return .success(try cursor.stringObject())
        } catch let error as DecodeError {
            return .failure(error)
        } catch {
            preconditionFailure("typedstream cursor threw \(error)")
        }
    }

    private enum Token: Equatable {
        case new, null, end
        case int(Int64)
    }

    private struct Cursor {
        let bytes: [UInt8]
        let limits: Limits
        let deadline: UInt64
        var index = 0
        var depth = 0
        var sharedStrings: [[UInt8]] = []

        init(bytes: [UInt8], limits: Limits) {
            self.bytes = bytes
            self.limits = limits
            self.deadline = DispatchTime.now().uptimeNanoseconds &+ limits.budgetNanoseconds
        }

        mutating func header() throws {
            guard bytes.count >= 2 + Typedstream.signature.count else { throw DecodeError.badHeader }
            guard try byte() == 0x04, try byte() == 0x0b,
                  try take(Typedstream.signature.count) == Typedstream.signature else {
                throw DecodeError.badHeader
            }
            _ = try integer() // the system version; any value is accepted
        }

        /// The root: an "@" object of an attributed-string class.
        mutating func rootObject() throws {
            guard try sharedString() == [0x40] else { throw DecodeError.grammar }
            guard try token() == .new else { throw DecodeError.grammar }
            try enter()
            let className = try classChain()
            guard let name = className, Typedstream.rootClasses.contains(name) else {
                throw DecodeError.unexpectedClass
            }
        }

        /// The attributed string's first member: an NSString whose payload is the text.
        mutating func stringObject() throws -> String {
            guard try sharedString() == [0x40] else { throw DecodeError.grammar }
            guard try token() == .new else { throw DecodeError.grammar }
            try enter()
            let className = try classChain()
            guard let name = className, Typedstream.stringClasses.contains(name) else {
                throw DecodeError.unexpectedClass
            }
            guard try sharedString() == [0x2b] else { throw DecodeError.grammar }
            let payload = try take(try length())
            guard try token() == .end else { throw DecodeError.grammar }
            guard let text = String(bytes: payload, encoding: .utf8) else { throw DecodeError.invalidUTF8 }
            return text
        }

        /// Reads a class, its version and its superclasses down to `nil` or a reference
        /// to a class already seen. Returns the first class's name when it is new.
        mutating func classChain() throws -> String? {
            var first: String?
            var isFirst = true
            while true {
                switch try token() {
                case .new:
                    try enter()
                    let name = try sharedString()
                    _ = try integer() // class version
                    if isFirst { first = String(bytes: name, encoding: .utf8) }
                    isFirst = false
                case .null, .int:
                    return first
                case .end:
                    throw DecodeError.grammar
                }
            }
        }

        mutating func sharedString() throws -> [UInt8] {
            switch try token() {
            case .new:
                let value = try take(try length())
                sharedStrings.append(value)
                return value
            case .int(let reference):
                let slot = reference + 110
                guard slot >= 0, slot < Int64(sharedStrings.count) else { throw DecodeError.grammar }
                return sharedStrings[Int(slot)]
            case .null, .end:
                throw DecodeError.grammar
            }
        }

        mutating func length() throws -> Int {
            let value = try integer()
            guard value >= 0 else { throw DecodeError.grammar }
            return Int(value)
        }

        mutating func integer() throws -> Int64 {
            guard case .int(let value) = try token() else { throw DecodeError.grammar }
            return value
        }

        mutating func token() throws -> Token {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw DecodeError.timeout }
            let tag = try byte()
            switch tag {
            case 0x84: return .new
            case 0x85: return .null
            case 0x86: return .end
            case 0x81: return .int(Int64(Int16(truncatingIfNeeded: try littleEndian(2))))
            case 0x82: return .int(Int64(Int32(truncatingIfNeeded: try littleEndian(4))))
            case 0x80...0x91: throw DecodeError.grammar
            default: return .int(Int64(Int8(bitPattern: tag)))
            }
        }

        mutating func enter() throws {
            depth += 1
            guard depth <= limits.maxDepth else { throw DecodeError.tooDeep }
        }

        mutating func littleEndian(_ count: Int) throws -> UInt64 {
            try take(count).reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }

        mutating func byte() throws -> UInt8 {
            guard index < bytes.count else { throw DecodeError.truncated }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count <= bytes.count - index else { throw DecodeError.truncated }
            defer { index += count }
            return Array(bytes[index..<(index + count)])
        }
    }
}
