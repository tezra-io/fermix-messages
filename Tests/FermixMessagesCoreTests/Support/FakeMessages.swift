import Foundation
@testable import FermixMessagesCore

/// Messages.app, simulated: each send runs `behaviour` against the synthetic chat.db,
/// the way the real app writes the outgoing row after AppleScript returns.
final class FakeMessages: MessagesScripting {
    enum Behaviour {
        case recordRow
        case ghostRow
        case nothing
        case error(Int, String)
        case timeout
        case recordRowAfterTimeout
    }

    let fixture: ChatDBFixture
    var behaviour: Behaviour = .recordRow
    /// Called with the ledger's view of the send while "AppleScript" runs.
    var during: ((ScriptCommand) -> Void)?
    private let lock = NSLock()
    private var sent: [ScriptCommand] = []

    init(_ fixture: ChatDBFixture) {
        self.fixture = fixture
    }

    var commands: [ScriptCommand] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func send(_ command: ScriptCommand) -> ScriptOutcome {
        lock.lock()
        sent.append(command)
        lock.unlock()
        during?(command)
        switch behaviour {
        case .recordRow:
            writeOutgoing(command, service: "iMessage", text: command.isFile ? nil : command.payload)
            return .returned
        case .ghostRow:
            writeOutgoing(command, service: "SMS", text: "")
            return .returned
        case .nothing:
            return .returned
        case .error(let code, let text):
            return .failed(code: code, text: text)
        case .timeout:
            return .timedOut
        case .recordRowAfterTimeout:
            writeOutgoing(command, service: "iMessage", text: command.isFile ? nil : command.payload)
            return .timedOut
        }
    }

    /// The outgoing row: in the resolved chat, or in a direct chat created for a
    /// participant send, as Messages does.
    func writeOutgoing(_ command: ScriptCommand, service: String, text: String?) {
        let chat: Int64
        let handle: String
        switch command.mode {
        case .chatText, .chatFile:
            let identifier = try? fixture.writer.query("SELECT chat_identifier FROM chat WHERE guid = ?",
                                                       [.text(command.target)]) { $0.text(0) ?? "" }.first
            handle = identifier ?? ""
            chat = fixture.ensureChat(handle, service: service, guid: command.target)
        case .participantText, .participantFile:
            handle = command.target
            chat = fixture.ensureChat(handle, service: service, guid: "\(service);-;\(handle)")
        }
        let handleRow = fixture.ensureHandle(handle, service: service)
        let row = fixture.message(.init(text: text, fromMe: true, handle: handleRow, chat: chat))
        if command.isFile {
            fixture.attachment(message: row.rowid, filename: command.payload, mime: "image/jpeg", bytes: 3)
        }
    }
}

extension ScriptCommand {
    var isFile: Bool { mode == .chatFile || mode == .participantFile }
}
