import Foundation
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// Where a program's output goes.
public enum CommandOutput: Sendable {
    /// Straight to this process's own standard output and error, as it comes (a build's log, which may be huge).
    case inherited
    /// Standard output collected and returned (at most 64 MiB); standard error dropped.
    case collected
}

public struct CommandResult: Sendable, Equatable {
    /// The exit status; a program a signal ended answers 128 plus the signal, as a shell does.
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }
}

/// How the tool runs the programs it wraps (`bazel`, `nimbus`, `ls`): a test's records them.
public protocol CommandRunner: Sendable {
    func run(_ executable: String, _ arguments: [String], output: CommandOutput) async throws -> CommandResult
}

/// swift-subprocess: the program of that name on the PATH.
public struct SystemRunner: CommandRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], output: CommandOutput) async throws -> CommandResult {
        // A path (Nimbus' /opt/nimbus/bin/nimbus) runs where it is; a bare name is looked up on the PATH.
        let program: Executable = executable.contains("/") ? .path(FilePath(executable)) : .name(executable)
        switch output {
        case .inherited:
            let result = try await Subprocess.run(program, arguments: Arguments(arguments),
                                                  output: .fileDescriptor(.standardOutput, closeAfterSpawningProcess: false),
                                                  error: .fileDescriptor(.standardError, closeAfterSpawningProcess: false))
            return CommandResult(status: Self.status(of: result.terminationStatus))
        case .collected:
            let result = try await Subprocess.run(program, arguments: Arguments(arguments),
                                                  output: .string(limit: 64 << 20), error: .discarded)
            return CommandResult(status: Self.status(of: result.terminationStatus), output: result.standardOutput)
        }
    }

    static func status(of termination: TerminationStatus) -> Int32 {
        switch termination {
        case .exited(let code): return Int32(code)
        case .signaled(let signal): return 128 + Int32(signal)
        }
    }
}
