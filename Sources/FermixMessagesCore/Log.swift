import Foundation

/// The helper's log: one line per event on stderr (design §6, §13). Callers pass handles
/// through `Handles.redact` and never pass a message body; values are quoted when they
/// carry spaces, quotes or newlines, so a line is always one line.
public final class Logger {
    private let sink: (String) -> Void
    private let lock = NSLock()

    public init(sink: @escaping (String) -> Void) {
        self.sink = sink
    }

    public static func standardError() -> Logger {
        Logger { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    public func event(_ name: String, _ fields: KeyValuePairs<String, String> = [:]) {
        var line = "\(Timestamp.format(Date())) fermix-messages \(name)"
        for (key, value) in fields {
            line += " \(key)=\(Self.quote(value))"
        }
        lock.lock()
        defer { lock.unlock() }
        sink(line)
    }

    static func quote(_ value: String) -> String {
        let needsQuotes = value.isEmpty || value.contains { $0 == " " || $0 == "\"" || $0.isNewline || $0 == "=" }
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
