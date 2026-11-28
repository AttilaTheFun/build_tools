import Foundation
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// Where a program's standard output goes (its standard error is always this process's own, so its complaints are in
/// the job's log, except for `quiet`'s).
public enum ProgramOutput: Sendable, Equatable {
    /// Straight to this process's standard output, as it comes.
    case inherited
    /// Collected and returned (at most 16 MiB).
    case collected
    /// Into this file, created or emptied first.
    case file(String)
    /// Dropped, standard error too (a probe whose failures are expected).
    case quiet
}

public struct ProgramResult: Sendable, Equatable {
    /// The exit status; a program a signal ended answers 128 plus the signal, as a shell does.
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }
}

/// How the tool runs the programs it wraps (`nimbus`, `ssh`, `tar`, `ssh-keygen`): a test's records them.
public protocol ProgramRunner: Sendable {
    /// `input`, when given, is a file read as the program's standard input.
    func run(_ executable: String, _ arguments: [String], input: String?, output: ProgramOutput) async throws -> ProgramResult
}

/// swift-subprocess: the program of that name on the PATH, or at its path.
public struct SystemProgramRunner: ProgramRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], input: String?, output: ProgramOutput) async throws -> ProgramResult {
        let program: Executable = executable.contains("/") ? .path(FilePath(executable)) : .name(executable)
        // Standard input is a file always (/dev/null when none is given): one input type for every case.
        let stdin = try FileDescriptor.open(FilePath(input ?? "/dev/null"), .readOnly)
        let errors: FileDescriptor = .standardError
        func inputValue() -> FileDescriptorInput { .fileDescriptor(stdin, closeAfterSpawningProcess: true) }
        switch output {
        case .inherited:
            let result = try await Subprocess.run(program, arguments: Arguments(arguments), input: inputValue(),
                                                  output: .fileDescriptor(.standardOutput, closeAfterSpawningProcess: false),
                                                  error: .fileDescriptor(errors, closeAfterSpawningProcess: false))
            return ProgramResult(status: Self.status(of: result.terminationStatus))
        case .collected:
            let result = try await Subprocess.run(program, arguments: Arguments(arguments), input: inputValue(),
                                                  output: .string(limit: 16 << 20),
                                                  error: .fileDescriptor(errors, closeAfterSpawningProcess: false))
            return ProgramResult(status: Self.status(of: result.terminationStatus), output: result.standardOutput ?? "")
        case .file(let path):
            let file = try FileDescriptor.open(FilePath(path), .writeOnly, options: [.create, .truncate],
                                               permissions: [.ownerReadWrite])
            let result = try await Subprocess.run(program, arguments: Arguments(arguments), input: inputValue(),
                                                  output: .fileDescriptor(file, closeAfterSpawningProcess: true),
                                                  error: .fileDescriptor(errors, closeAfterSpawningProcess: false))
            return ProgramResult(status: Self.status(of: result.terminationStatus))
        case .quiet:
            let result = try await Subprocess.run(program, arguments: Arguments(arguments), input: inputValue(),
                                                  output: .discarded, error: .discarded)
            return ProgramResult(status: Self.status(of: result.terminationStatus))
        }
    }

    static func status(of termination: TerminationStatus) -> Int32 {
        switch termination {
        case .exited(let code): return Int32(code)
        case .signaled(let signal): return 128 + Int32(signal)
        }
    }
}
