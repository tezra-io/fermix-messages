import Foundation

/// Exit codes: the compux/disclaim contract (design §6). A one-shot command exits 0
/// whether it printed a result or a helper error; the others are process classes whose
/// stdout the engine does not read.
public enum ExitCode {
    public static let ok: Int32 = 0
    public static let usage: Int32 = 64
    public static let disclaimUnavailable: Int32 = 70
    public static let disclaimRefused: Int32 = 71
    public static let execFailed: Int32 = 72
    public static let io: Int32 = 74
    public static let temporary: Int32 = 75
    public static let protocolError: Int32 = 76
}

public enum Command: Equatable {
    case serve(home: String)
    case probe(home: String)
    case grant(home: String, service: Service)
    case policyGet(home: String)
    case policySet(home: String, owner: String, handles: [String])
    case rows(home: String, since: Int64, limit: Int)
    case version
}

public struct UsageError: Error, Equatable {
    public let message: String
}

public enum CLI {
    static let usage = """
        usage: fermix-messages serve      --home DIR
               fermix-messages probe      --home DIR
               fermix-messages grant      --home DIR --service automation|full_disk_access
               fermix-messages policy-get --home DIR
               fermix-messages policy-set --home DIR --owner HANDLE [--handle HANDLE]...
       fermix-messages rows       --home DIR --since ROWID [--limit N]
               fermix-messages --version
        """

    /// Runs a command line (argv[0] first). `serve` never returns.
    public static func main(_ arguments: [String]) -> Int32 {
        switch parse(Array(arguments.dropFirst())) {
        case .failure(let error):
            FileHandle.standardError.write(Data("fermix-messages: \(error.message)\n\(usage)\n".utf8))
            return ExitCode.usage
        case .success(let command):
            return run(command)
        }
    }

    static func parse(_ arguments: [String]) -> Result<Command, UsageError> {
        guard let first = arguments.first else { return .failure(UsageError(message: "no command")) }
        let rest = arguments.dropFirst()
        switch first {
        case "--version":
            return rest.isEmpty ? .success(.version) : .failure(UsageError(message: "--version takes no arguments"))
        case "serve":
            return flags(rest, ["--home"]).map { .serve(home: $0.single["--home"]!) }
        case "probe":
            return flags(rest, ["--home"]).map { .probe(home: $0.single["--home"]!) }
        case "grant":
            return flags(rest, ["--home", "--service"]).flatMap { values in
                guard let service = Service(rawValue: values.single["--service"]!) else {
                    return .failure(UsageError(message: "--service is automation or full_disk_access"))
                }
                return .success(.grant(home: values.single["--home"]!, service: service))
            }
        case "policy-get":
            return flags(rest, ["--home"]).map { .policyGet(home: $0.single["--home"]!) }
        case "policy-set":
            return flags(rest, ["--home", "--owner"], repeatable: "--handle").map { values in
                .policySet(home: values.single["--home"]!, owner: values.single["--owner"]!, handles: values.repeated)
            }
        case "rows":
            return flags(rest, ["--home", "--since"], optional: ["--limit"]).flatMap { values in
                guard let since = Int64(values.single["--since"]!) else {
                    return .failure(UsageError(message: "--since is a row id"))
                }
                let limit = values.single["--limit"].flatMap(Int.init) ?? 50
                return .success(.rows(home: values.single["--home"]!, since: since, limit: limit))
            }
        default:
            return .failure(UsageError(message: "unknown command \(first)"))
        }
    }

    struct Flags {
        var single: [String: String] = [:]
        var repeated: [String] = []
    }

    /// Exactly the `required` flags, each once with a value, plus any number of the
    /// `repeatable` flag.
    private static func flags(_ tokens: ArraySlice<String>, _ required: Set<String>,
                              repeatable: String? = nil, optional: Set<String> = []) -> Result<Flags, UsageError> {
        var values = Flags()
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let flag = tokens[index]
            guard index + 1 < tokens.endIndex else { return .failure(UsageError(message: "\(flag) needs a value")) }
            let value = tokens[index + 1]
            index += 2
            if flag == repeatable {
                values.repeated.append(value)
                continue
            }
            guard required.contains(flag) || optional.contains(flag), values.single[flag] == nil else {
                return .failure(UsageError(message: "unexpected or repeated \(flag)"))
            }
            values.single[flag] = value
        }
        let missing = required.subtracting(values.single.keys)
        guard missing.isEmpty else {
            return .failure(UsageError(message: "missing \(missing.sorted().joined(separator: ", "))"))
        }
        return .success(values)
    }

    private static func run(_ command: Command) -> Int32 {
        switch command {
        case .version:
            print("fermix-messages \(HelperInfo.current().version)")
            return ExitCode.ok
        case .serve(let home):
            Serve.run(home: home)
        case .probe(let home):
            return oneShot(home) { runtime in Result<ProbeResult, HelperError>.success(runtime.prober.probe()) }
        case .grant(let home, let service):
            return oneShot(home) { $0.granter.grant(service) }
        case .policyGet(let home):
            return oneShot(home) { $0.policy.get() }
        case .policySet(let home, let owner, let handles):
            let params = PolicySetParams(ownerHandle: owner, handles: handles)
            return oneShot(home) { $0.policy.set(params) }
        case .rows(let home, let since, let limit):
            return oneShot(home) { Diagnostics.rows(since: since, limit: limit, runtime: $0) }
        }
    }

    /// A control-plane command: exactly one JSON value on stdout — the result (`null` for
    /// an absent policy) or `{"error": {kind, message, data}}` — and exit 0 either way.
    private static func oneShot<T: Encodable>(_ home: String, _ body: (Runtime) -> Result<T, HelperError>) -> Int32 {
        let log = Logger.standardError()
        let runtime: Runtime
        do {
            runtime = try Runtime(home: home, log: log)
        } catch {
            FileHandle.standardError.write(Data("fermix-messages: \(error)\n".utf8))
            return ExitCode.usage
        }
        switch body(runtime) {
        case .success(let value):
            print(String(decoding: Wire.encode(value), as: UTF8.self))
            return ExitCode.ok
        case .failure(let error):
            print(String(decoding: Wire.encode(["error": error]), as: UTF8.self))
            return ExitCode.ok
        }
    }
}
