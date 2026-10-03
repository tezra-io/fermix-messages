import Foundation
@testable import FermixMessagesCore

/// The wire as the engine sees it. While `held`, lines queue up unwritten (an engine that
/// stopped reading); `release()` writes them in order.
final class CapturingWire: NotificationSink {
    private let lock = NSLock()
    private var written: [Data] = []
    private var queued: [(Data, () -> Void)] = []
    var held = false

    func notify(_ line: Data, onWritten: @escaping () -> Void) {
        lock.lock()
        if held {
            queued.append((line, onWritten))
            lock.unlock()
            return
        }
        written.append(line)
        lock.unlock()
        onWritten()
    }

    func release() {
        lock.lock()
        held = false
        let pending = queued
        queued = []
        written += pending.map(\.0)
        lock.unlock()
        pending.forEach { $0.1() }
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return (written + queued.map(\.0)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Decoded notifications, in wire order.
    var events: [(event: String, params: [String: Any])] {
        lines.compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let event = object["event"] as? String, let params = object["params"] as? [String: Any] else {
                return nil
            }
            return (event, params)
        }
    }

    var messageRowids: [Int64] {
        events.filter { $0.event == "message" }.compactMap { ($0.params["rowid"] as? NSNumber)?.int64Value }
    }
}
