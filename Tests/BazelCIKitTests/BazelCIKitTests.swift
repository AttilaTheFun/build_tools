import BazelCIKit
import Foundation
import Testing

/// A runner that runs nothing: every call is recorded, and a handler answers it.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        var executable: String
        var arguments: [String]
        var output: String
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let handler: @Sendable (Call) throws -> CommandResult

    init(_ handler: @escaping @Sendable (Call) throws -> CommandResult) { self.handler = handler }

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: String, _ arguments: [String], output: CommandOutput) async throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments, output: output == .inherited ? "inherited" : "collected")
        lock.withLock { recorded.append(call) }
        return try handler(call)
    }
}

extension CommandOutput: Equatable {
    public static func == (lhs: CommandOutput, rhs: CommandOutput) -> Bool {
        switch (lhs, rhs) {
        case (.inherited, .inherited), (.collected, .collected): return true
        default: return false
        }
    }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func add(_ line: String) { lock.withLock { recorded.append(line) } }
    var all: [String] { lock.withLock { recorded } }
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ci-bazel-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.resolvingSymlinksInPath()
}

private let resources = Resources(cpus: { 4 }, memory: { 8 * 1_073_741_824 }, peakMemory: { 6 * 1_073_741_824 })

/// A clock that says 100 s, then 142 s, 184 s …: a build between two readings took 42 s.
final class Ticks: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 100.0
    func next() -> Double { lock.withLock { defer { seconds += 42 }; return seconds } }
}

private func tool(_ runner: FakeRunner, checkout: URL, bazelrc: String? = nil, isLinux: Bool = true, log: Lines = Lines()) -> CIBazel {
    let ticks = Ticks()
    return CIBazel(runner: runner, nimbus: "nimbus", bazelrc: bazelrc, checkout: checkout.path, isLinux: isLinux,
                   resources: resources, log: { log.add($0) }, clock: { ticks.next() })
}

// MARK: - Nimbus' bazelrc

@Test func nimbusBazelConfigGivesTheBazelrc() async throws {
    let folder = try temporaryFolder()
    let runner = FakeRunner { call in
        call.executable == "nimbus" ? CommandResult(status: 0, output: "writing the config\n/tmp/nimbus/bazelrc\n\n") : CommandResult(status: 0)
    }
    let status = try await tool(runner, checkout: folder).run(verb: "build", arguments: ["--noremote_upload_local_results", "//:App"])
    #expect(status == 0)
    #expect(runner.calls.count == 2)
    #expect(runner.calls[0] == .init(executable: "nimbus", arguments: ["job", "bazel-config"], output: "collected"))
    #expect(runner.calls[1] == .init(executable: "bazel", arguments: ["--bazelrc=/tmp/nimbus/bazelrc", "build", "--keep_going",
                                                                       "--noremote_upload_local_results", "//:App"], output: "inherited"))
}

@Test func aGivenBazelrcNeedsNoNimbus() async throws {
    let folder = try temporaryFolder()
    let runner = FakeRunner { _ in CommandResult(status: 0) }
    _ = try await tool(runner, checkout: folder, bazelrc: "/my/bazelrc").run(verb: "test", arguments: ["//t:all"])
    #expect(runner.calls.map(\.executable) == ["bazel"])
    #expect(runner.calls[0].arguments == ["--bazelrc=/my/bazelrc", "test", "--keep_going", "//t:all"])
}

@Test func aBazelrcNimbusDidNotGiveIsAnError() async throws {
    let folder = try temporaryFolder()
    for answer in [CommandResult(status: 1, output: "x"), CommandResult(status: 0, output: "\n  \n")] {
        let runner = FakeRunner { _ in answer }
        await #expect(throws: CIBazelError.self) { try await tool(runner, checkout: folder).run(verb: "build", arguments: ["//:App"]) }
        // Bazel never ran without its settings.
        #expect(runner.calls.map(\.executable) == ["nimbus"])
    }
    struct Missing: Error {}
    let runner = FakeRunner { _ in throw Missing() }
    await #expect(throws: CIBazelError.self) { try await tool(runner, checkout: folder).run(verb: "build", arguments: ["//:App"]) }
}

@Test func bazelsStatusIsTheStatus() async throws {
    let folder = try temporaryFolder()
    let runner = FakeRunner { _ in CommandResult(status: 37) }
    let status = try await tool(runner, checkout: folder, bazelrc: "/rc").run(verb: "build", arguments: ["//:App"])
    #expect(status == 37)
}

@Test func theLogSaysWhereItRunsAndHowLong() async throws {
    let folder = try temporaryFolder()
    let log = Lines()
    let runner = FakeRunner { _ in CommandResult(status: 0) }
    _ = try await tool(runner, checkout: folder, bazelrc: "/rc", log: log).run(verb: "build", arguments: ["//:App"])
    #expect(log.all == ["This container: 4 CPUs, 8.0 GB memory", "ci-bazel: 42 s, peak memory 6.0 GB"])
}

@Test func buildsAreRefusedOffLinux() async throws {
    let folder = try temporaryFolder()
    let runner = FakeRunner { _ in CommandResult(status: 0) }
    await #expect(throws: CIBazelError.self) { try await tool(runner, checkout: folder, isLinux: false).run(verb: "build", arguments: ["//:App"]) }
    await #expect(throws: CIBazelError.self) { try await tool(runner, checkout: folder, isLinux: false).package(folder: "out", arguments: ["//:App"]) }
    #expect(runner.calls.isEmpty)
}

// MARK: - package

/// A runner for a package: a build that works, an execution root with the targets' files, and cquery listing them.
private func packaging(executionRoot: URL, files: [String], buildStatus: Int32 = 0) -> FakeRunner {
    FakeRunner { call in
        let arguments = call.arguments
        if call.executable == "bazel", arguments.contains("build") { return CommandResult(status: buildStatus) }
        if call.executable == "bazel", arguments.contains("info") { return CommandResult(status: 0, output: executionRoot.path + "\n") }
        if call.executable == "bazel", arguments.contains("cquery") { return CommandResult(status: 0, output: files.joined(separator: "\n") + "\n") }
        return CommandResult(status: 0)
    }
}

private func executionRoot(with files: [String: String]) throws -> URL {
    let root = try temporaryFolder()
    for (path, contents) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return root
}

@Test func packageCopiesTheTargetsFilesIntoTheFolder() async throws {
    let checkout = try temporaryFolder()
    let root = try executionRoot(with: ["bazel-out/bin/App.zip": "zip", "bazel-out/bin/sub/App.ipa": "ipa"])
    let runner = packaging(executionRoot: root, files: ["bazel-out/bin/App.zip", "bazel-out/bin/sub/App.ipa"])
    let status = try await tool(runner, checkout: checkout, bazelrc: "/rc")
        .package(folder: ".ci/packages", arguments: ["--compilation_mode=opt", "--config=ci", "//:App", "//:Phone"])
    #expect(status == 0)

    let startup = "--bazelrc=/rc"
    #expect(runner.calls[0].arguments == [startup, "build", "--keep_going", "--compilation_mode=opt", "--config=ci", "//:App", "//:Phone"])
    // The options go to info and cquery too; the targets are one union.
    #expect(runner.calls[1].arguments == [startup, "info", "--compilation_mode=opt", "--config=ci", "execution_root"])
    #expect(runner.calls[2].arguments == [startup, "cquery", "--compilation_mode=opt", "--config=ci", "//:App + //:Phone", "--output=files"])
    let folder = checkout.appendingPathComponent(".ci/packages")
    #expect(try String(contentsOf: folder.appendingPathComponent("App.zip"), encoding: .utf8) == "zip")
    #expect(try String(contentsOf: folder.appendingPathComponent("App.ipa"), encoding: .utf8) == "ipa")
    #expect(runner.calls.last == .init(executable: "ls", arguments: ["-l", folder.path], output: "inherited"))
}

@Test func packageReplacesTheFoldersFilesAndKeepsItsFolders() async throws {
    let checkout = try temporaryFolder()
    let old = checkout.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: old.appendingPathComponent("keep"), withIntermediateDirectories: true)
    try "old".write(to: old.appendingPathComponent("App.zip"), atomically: true, encoding: .utf8)
    try "stale".write(to: old.appendingPathComponent("Stale.zip"), atomically: true, encoding: .utf8)
    let root = try executionRoot(with: ["b/App.zip": "new"])
    // A read-only file, as Bazel leaves them, replaced the next time.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.appendingPathComponent("b/App.zip").path)
    let runner = packaging(executionRoot: root, files: ["b/App.zip"])
    let package = tool(runner, checkout: checkout, bazelrc: "/rc")
    _ = try await package.package(folder: "out", arguments: ["//:App"])
    _ = try await package.package(folder: "out", arguments: ["//:App"])
    #expect(try String(contentsOf: old.appendingPathComponent("App.zip"), encoding: .utf8) == "new")
    #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("Stale.zip").path))
    #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("keep").path))
}

@Test func packageRefusesAFolderOutsideTheCheckout() async throws {
    let checkout = try temporaryFolder()
    let runner = FakeRunner { _ in CommandResult(status: 0) }
    for folder in ["/tmp/elsewhere", "../up", ".", ""] {
        await #expect(throws: CIBazelError.self) { try await tool(runner, checkout: checkout, bazelrc: "/rc").package(folder: folder, arguments: ["//:App"]) }
    }
    #expect(runner.calls.isEmpty)
}

@Test func packageNeedsTargets() async throws {
    let checkout = try temporaryFolder()
    let runner = FakeRunner { _ in CommandResult(status: 0) }
    await #expect(throws: CIBazelError.self) { try await tool(runner, checkout: checkout, bazelrc: "/rc").package(folder: "out", arguments: ["--compilation_mode=opt"]) }
    #expect(runner.calls.isEmpty)
}

@Test func aFailedBuildStopsBeforeAnyFilesAreLookedFor() async throws {
    let checkout = try temporaryFolder()
    let root = try executionRoot(with: [:])
    let runner = packaging(executionRoot: root, files: [], buildStatus: 1)
    let status = try await tool(runner, checkout: checkout, bazelrc: "/rc").package(folder: "out", arguments: ["//:App"])
    #expect(status == 1)
    #expect(runner.calls.count == 1)
}

@Test func aFileThatCantBeCopiedIsAnError() async throws {
    let checkout = try temporaryFolder()
    let root = try executionRoot(with: [:])
    let runner = packaging(executionRoot: root, files: ["bazel-out/missing.zip"])
    await #expect(throws: CIBazelError.self) { try await tool(runner, checkout: checkout, bazelrc: "/rc").package(folder: "out", arguments: ["//:App"]) }
}

// MARK: - A real program

@Test func theSystemRunnerRunsARealProgram() async throws {
    let collected = try await SystemRunner().run("sh", ["-c", "echo one; echo two; echo hidden >&2; exit 0"], output: .collected)
    #expect(collected == CommandResult(status: 0, output: "one\ntwo\n"))
    #expect(try await SystemRunner().run("sh", ["-c", "exit 7"], output: .collected).status == 7)
    #expect(try await SystemRunner().run("sh", ["-c", "exit 5"], output: .inherited).status == 5)
    #expect(try await SystemRunner().run("sh", ["-c", "kill -TERM $$"], output: .collected).status == 128 + 15)
}

@Test func aProgramGivenByItsPathRunsWhereItIs() async throws {
    // Nimbus' command line is run by its absolute path, not found on the PATH.
    let result = try await SystemRunner().run("/bin/sh", ["-c", "echo by-path"], output: .collected)
    #expect(result == CommandResult(status: 0, output: "by-path\n"))
}
