import Foundation
@testable import FermixMessagesCore

/// A scratch directory owned by one test. Removal is refused for any path that is not
/// a directory this type created under the temporary directory, so a computed path can
/// never delete anything else.
final class TestDirectory {
    static let prefix = "fermix-messages-tests-"
    let url: URL

    init() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath()
        url = base.appendingPathComponent(Self.prefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            preconditionFailure("cannot create test directory: \(error)")
        }
    }

    var path: String { url.path }

    func sub(_ relative: String) -> String {
        let child = url.appendingPathComponent(relative)
        do {
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("cannot create \(relative): \(error)")
        }
        return child.path
    }

    deinit {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath().path
        precondition(url.path.hasPrefix(base + "/" + Self.prefix), "refusing to remove \(url.path)")
        // Restore permissions a test may have removed, then delete the tree.
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let walker = FileManager.default.enumerator(atPath: url.path)
        while let item = walker?.nextObject() as? String {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path + "/" + item)
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            preconditionFailure("cannot remove test directory \(url.path): \(error)")
        }
    }
}
