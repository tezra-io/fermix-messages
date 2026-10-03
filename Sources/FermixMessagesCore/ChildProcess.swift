import Darwin
import Foundation

public struct ChildResult: Equatable {
    public enum Termination: Equatable {
        case exited(Int32)
        case signaled(Int32)
        case timedOut
    }

    public let termination: Termination
    public let stdout: Data
    public let stderr: Data

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public struct ChildError: Error, Equatable {
    public let message: String
}

/// A bounded child process (`osascript`, `afconvert`, `sips`, `lsregister`): spawned
/// directly with an argv (never through a shell), in its own process group, with stdin
/// on /dev/null and only fds 0-2 inherited. On expiry the whole group is SIGKILLed.
/// Output is captured up to `outputCap` bytes per stream; the rest is read and dropped
/// so the child never blocks on a full pipe.
enum BoundedChild {
    static let killGrace: TimeInterval = 5
    static let drainGrace: TimeInterval = 2

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                    outputCap: Int = 256 * 1024) throws -> ChildResult {
        let out = try Pipe.make()
        let err: Pipe
        do {
            err = try Pipe.make()
        } catch {
            out.closeBoth()
            throw error
        }
        let pid: pid_t
        do {
            pid = try spawn(executable, arguments, stdout: out.write, stderr: err.write)
        } catch {
            out.closeBoth()
            err.closeBoth()
            throw error
        }
        out.closeWrite()
        err.closeWrite()
        let stdoutBox = Drain(fd: out.read, cap: outputCap)
        let stderrBox = Drain(fd: err.read, cap: outputCap)
        let termination = wait(for: pid, timeout: timeout)
        return ChildResult(termination: termination, stdout: stdoutBox.finish(grace: drainGrace),
                           stderr: stderrBox.finish(grace: drainGrace))
    }

    private static func wait(for pid: pid_t, timeout: TimeInterval) -> ChildResult.Termination {
        let reaped = DispatchSemaphore(value: 0)
        let status = StatusBox()
        Thread.detachNewThread {
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
            status.set(raw)
            reaped.signal()
        }
        if reaped.wait(timeout: .now() + timeout) == .success {
            return decode(status.get())
        }
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        _ = reaped.wait(timeout: .now() + killGrace)
        return .timedOut
    }

    private static func decode(_ status: Int32) -> ChildResult.Termination {
        let signal = status & 0x7f
        if signal == 0 { return .exited((status >> 8) & 0xff) }
        return .signaled(signal)
    }

    private static func spawn(_ executable: String, _ arguments: [String], stdout: Int32,
                              stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = CStrings([executable] + arguments)
        let envp = CStrings(ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" })
        defer {
            argv.free()
            envp.free()
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attributes, argv.pointers, envp.pointers)
        guard rc == 0 else {
            throw ChildError(message: "\(executable): \(String(cString: strerror(rc)))")
        }
        return pid
    }

    private struct Pipe {
        let read: Int32
        let write: Int32

        static func make() throws -> Pipe {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else {
                throw ChildError(message: "pipe: \(String(cString: strerror(errno)))")
            }
            return Pipe(read: fds[0], write: fds[1])
        }

        func closeWrite() { close(write) }

        func closeBoth() {
            close(read)
            close(write)
        }
    }

    /// Reads one pipe to EOF on its own thread (never the shared GCD pool, which a busy
    /// process can starve), keeping at most `cap` bytes, and closes it.
    private final class Drain {
        private let lock = NSLock()
        private var data = Data()
        private let done = DispatchSemaphore(value: 0)

        init(fd: Int32, cap: Int) {
            Thread.detachNewThread { [self] in
                var buffer = [UInt8](repeating: 0, count: 16384)
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    append(buffer[0..<count], cap: cap)
                }
                close(fd)
                done.signal()
            }
        }

        private func append(_ chunk: ArraySlice<UInt8>, cap: Int) {
            lock.lock()
            defer { lock.unlock() }
            let room = cap - data.count
            if room > 0 { data.append(contentsOf: chunk.prefix(room)) }
        }

        func finish(grace: TimeInterval) -> Data {
            _ = done.wait(timeout: .now() + grace)
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private final class StatusBox {
        private let lock = NSLock()
        private var value: Int32 = 0

        func set(_ newValue: Int32) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// A NULL-terminated C string array that owns its strings until `free()`.
    private struct CStrings {
        let pointers: [UnsafeMutablePointer<CChar>?]

        init(_ strings: [String]) {
            pointers = strings.map { strdup($0) } + [nil]
        }

        func free() {
            pointers.forEach { Darwin.free($0) }
        }
    }
}
