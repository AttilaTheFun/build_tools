import Foundation

public struct CIBazelError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// What this container has, said in the job's log: its CPUs, its memory, and what a build peaked at.
public struct Resources: Sendable {
    public var cpus: @Sendable () -> Int
    /// The container's memory, in bytes (nil where unknown).
    public var memory: @Sendable () -> Int64?
    /// The most memory the container held at once, in bytes (cgroup v2's memory.peak; nil where there is none).
    public var peakMemory: @Sendable () -> Int64?

    public init(cpus: @escaping @Sendable () -> Int, memory: @escaping @Sendable () -> Int64?,
                peakMemory: @escaping @Sendable () -> Int64?) {
        self.cpus = cpus
        self.memory = memory
        self.peakMemory = peakMemory
    }

    public static let system = Resources(
        cpus: { ProcessInfo.processInfo.activeProcessorCount },
        memory: {
            guard let meminfo = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8),
                  let line = meminfo.split(separator: "\n").first(where: { $0.hasPrefix("MemTotal:") }),
                  let kilobytes = line.split(separator: " ").dropFirst().first.flatMap({ Int64($0) }) else { return nil }
            return kilobytes * 1024
        },
        peakMemory: {
            (try? String(contentsOfFile: "/sys/fs/cgroup/memory.peak", encoding: .utf8))
                .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        })
}

/// Bazel in a CI container: `bazel build`, `test` and the like with Nimbus' settings for the runner, and `package`,
/// which copies what the targets built out of Bazel's tree into a folder of the checkout (what a job signs and
/// publishes). Replaces the `tools/ci/container_build.sh` the private repositories each copied.
///
/// The settings are Nimbus' (`nimbus job bazel-config`): the downloader config that sends the Xcode SDK and
/// rules_applecross' ported tools to the server's files (no repository pins their SHA-256), the runner's size, and
/// `--config=apple_on_linux`, written as a bazelrc that goes in as `--bazelrc=`.
public struct CIBazel: Sendable {
    public var runner: any CommandRunner
    /// Nimbus' command line (`/opt/nimbus/bin/nimbus`), asked for the bazelrc when none is given.
    public var nimbus: String
    /// A bazelrc to use instead of asking Nimbus for one.
    public var bazelrc: String?
    /// The folder the tool runs in: the checkout, where Bazel's workspace is.
    public var checkout: String
    public var isLinux: Bool
    public var resources: Resources
    /// The job's log (standard error: standard output is Bazel's).
    public var log: @Sendable (String) -> Void
    /// Seconds since a point, for the timing line (a test's is fixed).
    public var clock: @Sendable () -> Double

    public init(runner: any CommandRunner = SystemRunner(), nimbus: String = "/opt/nimbus/bin/nimbus", bazelrc: String? = nil,
                checkout: String = FileManager.default.currentDirectoryPath, isLinux: Bool = CIBazel.runsOnLinux,
                resources: Resources = .system,
                log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                clock: @escaping @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }) {
        self.runner = runner
        self.nimbus = nimbus
        self.bazelrc = bazelrc
        self.checkout = checkout
        self.isLinux = isLinux
        self.resources = resources
        self.log = log
        self.clock = clock
    }

    public static var runsOnLinux: Bool {
        #if os(Linux)
        true
        #else
        false
        #endif
    }

    // MARK: - Running

    /// `bazel <verb> --keep_going <arguments>` with Nimbus' settings; the exit status is Bazel's.
    public func run(verb: String, arguments: [String]) async throws -> Int32 {
        try requireLinux()
        let startup = try await startupOptions()
        sayWhereItRuns()
        let started = clock()
        let result = try await runner.run("bazel", startup + [verb, "--keep_going"] + arguments, output: .inherited)
        sayHowLong(since: started)
        return result.status
    }

    /// `bazel build`, then the targets' files copied into `folder` (inside the checkout; its files replaced). The
    /// arguments are Bazel's: the options (each `--name=value`: one word) apply to the build and to finding its files,
    /// the rest are the targets. The exit status is the build's, or 0.
    public func package(folder: String, arguments: [String]) async throws -> Int32 {
        try requireLinux()
        let options = arguments.filter { $0.hasPrefix("-") }
        let targets = arguments.filter { !$0.hasPrefix("-") }
        guard !targets.isEmpty else { throw CIBazelError("package needs targets to build: ci-bazel package <folder> <bazel arguments…>") }

        // What CI publishes is copied out of Bazel's tree into this checkout.
        let root = URL(fileURLWithPath: checkout).standardizedFileURL.path
        let destination = URL(fileURLWithPath: folder, relativeTo: URL(fileURLWithPath: root, isDirectory: true)).standardizedFileURL.path
        guard destination.hasPrefix(root + "/") else { throw CIBazelError("package's folder must be in this checkout (\(root))") }
        try prepare(folder: destination)

        let startup = try await startupOptions()
        sayWhereItRuns()
        let started = clock()
        let built = try await runner.run("bazel", startup + ["build", "--keep_going"] + arguments, output: .inherited)
        sayHowLong(since: started)
        guard built.status == 0 else { return built.status }

        // Each target's files, by the build's own options, from the execution root (there is no bazel-out link here).
        let info = try await runner.run("bazel", startup + ["info"] + options + ["execution_root"], output: .collected)
        guard info.status == 0, let executionRoot = lastLine(of: info.output) else {
            throw CIBazelError("bazel info execution_root answered \(info.status)")
        }
        // cquery takes one expression: the targets as a union of them.
        let query = try await runner.run("bazel", startup + ["cquery"] + options + [targets.joined(separator: " + "), "--output=files"],
                                         output: .collected)
        guard query.status == 0 else { throw CIBazelError("bazel cquery answered \(query.status)") }
        for file in query.output.split(whereSeparator: \.isNewline).map(String.init) where !file.isEmpty {
            let source = URL(fileURLWithPath: executionRoot).appendingPathComponent(file)
            let target = URL(fileURLWithPath: destination).appendingPathComponent(source.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: source, to: target)
            } catch {
                throw CIBazelError("\(file) wasn't copied to \(destination): \(error.localizedDescription)")
            }
        }
        _ = try await runner.run("ls", ["-l", destination], output: .inherited)
        return 0
    }

    // MARK: - Pieces

    func requireLinux() throws {
        guard isLinux else {
            throw CIBazelError("ci-bazel builds in a Linux container: lease one and copy the tree in (~/Developer/AGENTS.md), then run it there")
        }
    }

    /// `--bazelrc=<path>`, the given one or Nimbus': the path `nimbus job bazel-config` prints, on its last line.
    func startupOptions() async throws -> [String] {
        if let bazelrc { return ["--bazelrc=\(bazelrc)"] }
        let result: CommandResult
        do {
            result = try await runner.run(nimbus, ["job", "bazel-config"], output: .collected)
        } catch {
            throw CIBazelError("\(nimbus) job bazel-config didn't run: \(error) (a CI runner gets nimbus from its server; --bazelrc names a file instead)")
        }
        guard result.status == 0 else { throw CIBazelError("nimbus job bazel-config answered \(result.status)") }
        guard let path = lastLine(of: result.output) else { throw CIBazelError("nimbus job bazel-config printed no bazelrc path") }
        return ["--bazelrc=\(path)"]
    }

    /// The folder empty and writable: its files removed (its folders stay).
    func prepare(folder: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for name in try manager.contentsOfDirectory(atPath: folder) {
            var isFolder: ObjCBool = false
            let path = (folder as NSString).appendingPathComponent(name)
            if manager.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue { try manager.removeItem(atPath: path) }
        }
        try manager.setAttributes([.posixPermissions: 0o775], ofItemAtPath: folder)
    }

    func sayWhereItRuns() {
        let memory = resources.memory().map { String(format: ", %.1f GB memory", Double($0) / 1_073_741_824) } ?? ""
        log("This container: \(resources.cpus()) CPUs\(memory)")
    }

    /// How long the build took, and the container's peak memory: what sizes CI's runners.
    func sayHowLong(since started: Double) {
        let seconds = Int((clock() - started).rounded())
        let peak = resources.peakMemory().map { String(format: ", peak memory %.1f GB", Double($0) / 1_073_741_824) } ?? ""
        log("ci-bazel: \(seconds) s\(peak)")
    }

    func lastLine(of output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }
}
