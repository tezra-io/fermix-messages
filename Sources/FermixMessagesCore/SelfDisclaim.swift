import Darwin
import Foundation

/// Makes this process its OWN TCC "responsible process" (design §5.1; the compux
/// contract, `compux/native/compux/src/main.rs` `disclaim`).
///
/// The engine spawns the helper through an Erlang Port. A child that does not disclaim
/// inherits its parent's TCC identity, so Full Disk Access and Automation would be asked
/// of (and granted to) the daemon's ancestor instead of Fermix Messages. The disclaim flag
/// must be set on the spawn attributes BEFORE the spawn, which a running process cannot
/// do to itself, so the helper re-execs itself once with POSIX_SPAWN_SETEXEC: the image
/// is replaced in place, the pid and the stdio fds stay, and the sentinel bounds it to
/// one re-exec. The API is private (resolved with dlsym); when it is absent or refuses,
/// the helper exits non-zero and never runs undisclaimed.
public enum SelfDisclaim {
    public static let sentinel = "FERMIX_MESSAGES_DISCLAIMED"

    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    /// Returns only in the re-exec'd, disclaimed image.
    public static func ensure() {
        if isDisclaimed(ProcessInfo.processInfo.environment) { return }
        guard let setDisclaim = resolveSetDisclaim() else {
            fatal(ExitCode.disclaimUnavailable, "responsibility_spawnattrs_setdisclaim unavailable")
        }
        guard let executable = executablePath() else { fatal(ExitCode.execFailed, "_NSGetExecutablePath failed") }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { fatal(ExitCode.execFailed, "posix_spawnattr_init failed") }
        guard setDisclaim(&attributes, 1) == 0 else {
            fatal(ExitCode.disclaimRefused, "responsibility_spawnattrs_setdisclaim returned nonzero")
        }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC)) == 0 else {
            fatal(ExitCode.execFailed, "posix_spawnattr_setflags failed")
        }
        let argv = CommandLine.arguments.map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.filter { $0.key != sentinel }
            .map { "\($0.key)=\($0.value)" } + ["\(sentinel)=1"]
        let envp = environment.map { strdup($0) } + [nil]
        // SETEXEC replaces this image; posix_spawn returns only on failure.
        let rc = posix_spawn(nil, executable, nil, &attributes, argv, envp)
        fatal(ExitCode.execFailed, "POSIX_SPAWN_SETEXEC re-exec failed: \(String(cString: strerror(rc)))")
    }

    static func isDisclaimed(_ environment: [String: String]) -> Bool {
        environment[sentinel] == "1"
    }

    static func resolveSetDisclaim() -> SetDisclaim? {
        // RTLD_DEFAULT is (void *)-2 on macOS.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetDisclaim.self)
    }

    private static func executablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func fatal(_ code: Int32, _ message: String) -> Never {
        FileHandle.standardError.write(Data("fermix-messages: FATAL disclaim: \(message)\n".utf8))
        exit(code)
    }
}
