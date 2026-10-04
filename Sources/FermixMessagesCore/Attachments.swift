import Foundation

enum Attachments {
    /// `attachment.filename` as a path: Messages writes `~/Library/Messages/Attachments/…`.
    static func sourcePath(_ filename: String?, location: MessagesLocation) -> String? {
        guard let filename, !filename.isEmpty else { return nil }
        if filename.hasPrefix("~/") { return location.tildeHome + filename.dropFirst(1) }
        return filename
    }
}

/// The conversions the engine's media paths need: voice memos (CAF, AMR) to m4a for
/// transcription, HEIC photos to JPEG.
enum Conversion: Equatable {
    case audioToM4a
    case heicToJpeg

    var fileExtension: String { self == .audioToM4a ? "m4a" : "jpg" }
    var mime: String { self == .audioToM4a ? "audio/mp4" : "image/jpeg" }

    static func needed(mime: String?, name: String) -> Conversion? {
        let ext = (name as NSString).pathExtension.lowercased()
        switch (mime?.lowercased(), ext) {
        case ("audio/x-caf", _), ("audio/amr", _), (_, "caf"), (_, "amr"): return .audioToM4a
        case ("image/heic", _), ("image/heif", _), (_, "heic"), (_, "heif"): return .heicToJpeg
        default: return nil
        }
    }
}

protocol MediaConverting: AnyObject {
    func convert(_ conversion: Conversion, input: String, output: String) -> Result<Void, HelperError>
}

/// `afconvert` and `sips` as bounded children (30 s, the process group killed on expiry).
/// The closed vocabulary has no conversion kind, so a failure is `path_refused` (the
/// requested file could not be produced) with the tool's own words in the message.
final class ToolConverter: MediaConverting {
    static let timeout: TimeInterval = 30

    static func arguments(_ conversion: Conversion, input: String, output: String) -> [String] {
        switch conversion {
        case .audioToM4a: return ["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", input, output]
        case .heicToJpeg: return ["/usr/bin/sips", "-s", "format", "jpeg", input, "--out", output]
        }
    }

    func convert(_ conversion: Conversion, input: String, output: String) -> Result<Void, HelperError> {
        let argv = Self.arguments(conversion, input: input, output: output)
        let tool = (argv[0] as NSString).lastPathComponent
        do {
            let result = try BoundedChild.run(argv[0], Array(argv.dropFirst()), timeout: Self.timeout)
            guard result.termination == .exited(0) else {
                let text = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
                return .failure(HelperError(.pathRefused, "conversion failed: \(tool) \(result.termination): \(text)"))
            }
            return .success(())
        } catch {
            return .failure(HelperError(.pathRefused, "conversion failed: \(tool) did not start: \(error)"))
        }
    }
}

/// `attachment.fetch` (design §8.3, R10): only for a message this process emitted, and
/// only while that message still passes the stored policy. The source must resolve under
/// the Messages Attachments root without symlinks; the destination is generated under
/// FERMIX_HOME/imessage/inbox/<guid>/<index>-<name>; the copy is byte-capped.
final class AttachmentFetcher {
    static let inboxAge: TimeInterval = 24 * 3600

    private let feed: Feed
    private let inbox: String
    private let converter: MediaConverting
    private let cap: Int64
    private let log: Logger
    private let now: () -> Date

    init(feed: Feed, inbox: String, converter: MediaConverting, cap: Int64, log: Logger, now: @escaping () -> Date) {
        self.feed = feed
        self.inbox = inbox
        self.converter = converter
        self.cap = cap
        self.log = log
        self.now = now
    }

    func fetch(_ params: AttachmentFetchParams) -> Result<AttachmentFetchResult, HelperError> {
        guard feed.emitted.contains(params.messageGuid) else {
            return .failure(HelperError(.attachmentNotAdmitted, "this helper did not emit that message"))
        }
        let db: ChatDB
        let stored: StoredPolicy
        switch feed.open() {
        case .success(let opened): (db, stored) = opened
        case .failure(let error): return .failure(error)
        }
        defer { db.close() }
        let attachment: RawAttachment
        do {
            guard let raw = try db.row(guid: params.messageGuid),
                  let admitted = try feed.admit(raw, policy: stored, db: db) else {
                return .failure(HelperError(.attachmentNotAdmitted, "that message is outside the stored policy"))
            }
            guard params.index < admitted.attachments.count else {
                return .failure(HelperError(.attachmentNotAdmitted, "no attachment at index \(params.index)"))
            }
            attachment = admitted.attachments[params.index]
        } catch {
            return .failure(.reading(error))
        }
        removeStaleInboxEntries()
        return copy(attachment, params: params)
    }

    private func copy(_ attachment: RawAttachment, params: AttachmentFetchParams) -> Result<AttachmentFetchResult, HelperError> {
        guard let source = Attachments.sourcePath(attachment.filename, location: feed.location) else {
            return .failure(HelperError(.pathRefused, "the attachment has no file on this Mac"))
        }
        let real: String
        switch SafePath.resolve(source, under: feed.location.attachmentsRoot) {
        case .success(let resolved): real = resolved
        case .failure(let refusal):
            return .failure(HelperError(.pathRefused, "the attachment file is not under Messages' Attachments: \(refusal.reason)"))
        }
        let directory = inbox + "/" + FileNames.sanitize(params.messageGuid)
        let name = "\(params.index)-" + FileNames.sanitize((source as NSString).lastPathComponent)
        let destination = directory + "/" + name
        do {
            try HelperPaths.ensurePrivateDirectory(directory)
            if FileManager.default.fileExists(atPath: destination) { try FileManager.default.removeItem(atPath: destination) }
        } catch {
            return .failure(HelperError(.pathRefused, "inbox: \(error)"))
        }
        switch FileCopy.copy(from: real, to: destination, cap: cap) {
        case .failure(.tooLarge(let bytes)):
            return .failure(.tooLarge(bytes: bytes, cap: cap))
        case .failure(let other):
            return .failure(HelperError(.pathRefused, "copy: \(other)"))
        case .success(let copied):
            guard params.convert, let conversion = Conversion.needed(mime: attachment.mime, name: name) else {
                return .success(AttachmentFetchResult(path: destination, mime: attachment.mime, bytes: copied.bytes))
            }
            return convert(destination, conversion)
        }
    }

    private func convert(_ input: String, _ conversion: Conversion) -> Result<AttachmentFetchResult, HelperError> {
        let output = (input as NSString).deletingPathExtension + "." + conversion.fileExtension
        let outcome = converter.convert(conversion, input: input, output: output)
        let removeInput = Result { try FileManager.default.removeItem(atPath: input) }
        if case .failure(let error) = outcome {
            _ = Result { try FileManager.default.removeItem(atPath: output) }
            log.event("conversion_failed", ["conversion": "\(conversion)", "error": error.message])
            return .failure(error)
        }
        if case .failure(let error) = removeInput {
            log.event("inbox_cleanup_failed", ["error": String(describing: error)])
        }
        var info = stat()
        guard stat(output, &info) == 0 else {
            return .failure(HelperError(.pathRefused, "conversion failed: \(conversion) produced no file"))
        }
        return .success(AttachmentFetchResult(path: output, mime: conversion.mime, bytes: Int64(info.st_size)))
    }

    private func removeStaleInboxEntries() {
        do {
            let removed = try FileTree.removeOlder(in: inbox, than: Self.inboxAge, now: now())
            if !removed.isEmpty { log.event("inbox_pruned", ["entries": String(removed.count)]) }
        } catch {
            log.event("inbox_prune_failed", ["error": String(describing: error)])
        }
    }
}
