import CryptoKit
import Darwin
import Foundation

public struct HelperPathsError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// The helper's places under FERMIX_HOME (design §5.4), all created 0700:
/// `imessage/helper/ledger.sqlite`, `imessage/inbox/`, `imessage/outbox/`.
public struct HelperPaths {
    public let home: String

    public var root: String { home + "/imessage" }
    public var helperDir: String { root + "/helper" }
    public var ledger: String { helperDir + "/ledger.sqlite" }
    public var inbox: String { root + "/inbox" }
    public var outbox: String { root + "/outbox" }

    /// The real path of an existing home directory.
    public static func resolve(home: String) throws -> HelperPaths {
        guard let real = realpath(home, nil) else {
            throw HelperPathsError(description: "home \(home): \(String(cString: strerror(errno)))")
        }
        defer { free(real) }
        let path = String(cString: real)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HelperPathsError(description: "home \(home) is not a directory")
        }
        return HelperPaths(home: path)
    }

    public func prepare() throws {
        for directory in [root, helperDir, inbox, outbox] {
            try Self.ensurePrivateDirectory(directory)
        }
    }

    /// Creates `path` 0700, or tightens an existing real directory to 0700. A symlink or a
    /// file in its place is refused.
    static func ensurePrivateDirectory(_ path: String) throws {
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw HelperPathsError(description: "\(path) exists and is not a real directory")
            }
            guard chmod(path, 0o700) == 0 else {
                throw HelperPathsError(description: "chmod \(path): \(String(cString: strerror(errno)))")
            }
            return
        }
        guard mkdir(path, 0o700) == 0 || errno == EEXIST else {
            throw HelperPathsError(description: "mkdir \(path): \(String(cString: strerror(errno)))")
        }
    }
}

public struct PathRefusal: Error, Equatable {
    public let reason: String
}

/// Resolution of a caller- or database-supplied path under a fixed root (R10): the path
/// must be absolute with no `.`/`..` components, name a regular file, and every component
/// between the root and the file must be a real directory, never a symlink. Symlinks
/// above the root are allowed (the root is matched by its real path); the root itself
/// must not be a symlink.
enum SafePath {
    static let maxDepth = 64

    static func resolve(_ path: String, under root: String) -> Result<String, PathRefusal> {
        guard path.hasPrefix("/") else { return .failure(PathRefusal(reason: "not absolute")) }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return .failure(PathRefusal(reason: "dot components"))
        }
        guard let rootReal = realRoot(root) else { return .failure(PathRefusal(reason: "root is not a real directory")) }
        guard kind(of: path) == S_IFREG else { return .failure(PathRefusal(reason: "not a regular file")) }
        var ancestor = (path as NSString).deletingLastPathComponent
        for _ in 0..<maxDepth {
            guard ancestor != "/", kind(of: ancestor) == S_IFDIR else {
                return .failure(PathRefusal(reason: "outside the root or through a symlink"))
            }
            if realPath(ancestor) == rootReal {
                guard let real = realPath(path) else { return .failure(PathRefusal(reason: "realpath failed")) }
                return .success(real)
            }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        return .failure(PathRefusal(reason: "too deep"))
    }

    private static func realRoot(_ root: String) -> String? {
        guard kind(of: root) == S_IFDIR else { return nil }
        return realPath(root)
    }

    /// The file type of `path` itself (lstat: a symlink is S_IFLNK), or 0 when absent.
    private static func kind(of path: String) -> mode_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return info.st_mode & S_IFMT
    }

    static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }
}

public enum CopyFailure: Error, Equatable {
    case tooLarge
    case notRegularFile
    case io(String)
}

struct CopyResult: Equatable {
    let bytes: Int64
    let sha256: String
}

/// A byte-capped copy that never follows a symlink at either end and never overwrites:
/// the destination is created exclusively (0600) and removed on any failure.
enum FileCopy {
    static let chunk = 64 * 1024

    static func copy(from source: String, to destination: String, cap: Int64) -> Result<CopyResult, CopyFailure> {
        let input = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { return .failure(.io("open \(source): \(String(cString: strerror(errno)))")) }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return .failure(.notRegularFile) }
        guard info.st_size <= cap else { return .failure(.tooLarge) }
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { return .failure(.io("create \(destination): \(String(cString: strerror(errno)))")) }
        let result = pump(input, output, cap: cap)
        close(output)
        if case .failure = result { unlink(destination) }
        return result
    }

    private static func pump(_ input: Int32, _ output: Int32, cap: Int64) -> Result<CopyResult, CopyFailure> {
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: chunk)
        while total <= cap {
            let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return .failure(.io("read: \(String(cString: strerror(errno)))")) }
            if count == 0 { return .success(CopyResult(bytes: total, sha256: hex(hasher.finalize()))) }
            total += Int64(count)
            guard total <= cap else { return .failure(.tooLarge) }
            hasher.update(data: buffer[0..<count])
            guard writeAll(output, buffer, count) else {
                return .failure(.io("write: \(String(cString: strerror(errno)))"))
            }
        }
        return .failure(.tooLarge)
    }

    private static func writeAll(_ fd: Int32, _ buffer: [UInt8], _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { write(fd, $0.baseAddress! + offset, count - offset) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// The hash of a file, read with the same cap; nil when it cannot be read.
    static func sha256(file path: String, cap: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while total <= cap, let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            total += Int64(data.count)
            hasher.update(data: data)
        }
        return total <= cap ? hex(hasher.finalize()) : nil
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum FileNames {
    static let maxLength = 100
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// A file name safe to create: the last path component only, characters outside
    /// [A-Za-z0-9._-] replaced by `_`, at most 100 characters with the extension kept.
    static func sanitize(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = String(base.map { allowed.contains($0) ? $0 : "_" })
        guard !cleaned.isEmpty, !cleaned.allSatisfy({ $0 == "." }) else { return "attachment" }
        guard cleaned.count > maxLength else { return cleaned }
        let ext = (cleaned as NSString).pathExtension
        let suffix = ext.isEmpty || ext.count > 10 ? "" : "." + ext
        return String(cleaned.prefix(maxLength - suffix.count)) + suffix
    }
}

/// Bounded housekeeping of the helper's own roots (staging, inbox).
enum FileTree {
    static let maxEntries = 10_000

    struct Entry {
        let name: String
        let modified: Date
        let bytes: Int64
    }

    static func entries(in root: String) throws -> [Entry] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root).prefix(maxEntries)
        return try names.map { name in
            let path = root + "/" + name
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return Entry(name: name, modified: attributes[.modificationDate] as? Date ?? .distantPast,
                         bytes: size(of: path))
        }
    }

    static func size(of path: String) -> Int64 {
        guard let walker = FileManager.default.enumerator(atPath: path) else {
            return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        var visited = 0
        while visited < maxEntries, walker.nextObject() != nil {
            visited += 1
            total += (walker.fileAttributes?[.size] as? Int64) ?? 0
        }
        return total
    }

    /// Removes the oldest entries until `incoming` more bytes fit under `cap`.
    static func evictOldest(in root: String, toFit incoming: Int64, cap: Int64) throws -> [String] {
        let all = try entries(in: root).sorted { $0.modified < $1.modified }
        var total = all.reduce(Int64(0)) { $0 + $1.bytes }
        var removed: [String] = []
        for entry in all where total + incoming > cap {
            try remove(entry.name, in: root)
            total -= entry.bytes
            removed.append(entry.name)
        }
        return removed
    }

    static func removeOlder(in root: String, than age: TimeInterval, now: Date) throws -> [String] {
        let stale = try entries(in: root).filter { now.timeIntervalSince($0.modified) > age }
        for entry in stale {
            try remove(entry.name, in: root)
        }
        return stale.map(\.name).sorted()
    }

    static func remove(_ name: String, in root: String) throws {
        precondition(!name.contains("/") && name != "." && name != "..", "refusing to remove \(name)")
        try FileManager.default.removeItem(atPath: root + "/" + name)
    }
}
