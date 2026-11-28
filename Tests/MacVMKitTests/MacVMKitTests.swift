import Foundation
@testable import MacVMKit
import Testing

/// A runner that runs nothing: every call is recorded, and a handler answers it.
final class FakeRunner: ProgramRunner, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        var executable: String
        var arguments: [String]
        var input: String?
        var output: ProgramOutput
        /// ssh's command on the VM (its last argument), else "".
        var remote: String { executable == "ssh" ? arguments.last ?? "" : "" }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let handler: @Sendable (Call) throws -> ProgramResult

    init(_ handler: @escaping @Sendable (Call) throws -> ProgramResult) { self.handler = handler }

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: String, _ arguments: [String], input: String?, output: ProgramOutput) async throws -> ProgramResult {
        let call = Call(executable: executable, arguments: arguments, input: input, output: output)
        lock.withLock { recorded.append(call) }
        return try handler(call)
    }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func add(_ line: String) { lock.withLock { recorded.append(line) } }
    var all: [String] { lock.withLock { recorded } }
}

let leaseOutput = """
export NIMBUS_HOST='192.168.166.1'
export NIMBUS_ID='a1b2c3d4'
export NIMBUS_SSH_PORT='52022'
export NIMBUS_SSH_PROXY_COMMAND=''
export NIMBUS_SSH_USER='runner'
export SHIREWORKS_SERVERS='not printed'
"""

/// Answers as a working Nimbus and VM would; `command` is the command's status, `fail` makes one step fail.
func vmHandler(command: Int32 = 0, lease: String = leaseOutput, fail: String? = nil, reachAfter: Int = 0) -> @Sendable (FakeRunner.Call) throws -> ProgramResult {
    let probes = Counter()
    return { call in
        if let fail, call.executable == fail || call.remote.contains(fail) { return ProgramResult(status: 2) }
        switch call.executable {
        case "/opt/nimbus/bin/nimbus" where call.arguments.prefix(2) == ["job", "lease"]:
            return ProgramResult(status: 0, output: lease)
        case "ssh" where call.remote == "true":
            return ProgramResult(status: probes.next() >= reachAfter ? 0 : 255)
        case "ssh" where call.remote.contains("zsh -lc"):
            return ProgramResult(status: command)
        case "ssh" where call.remote.contains("[ -e 'missing' ]"):
            return ProgramResult(status: 1)
        default:
            return ProgramResult(status: 0)
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
}

func makeVM(_ runner: FakeRunner, log: Lines = Lines(), reachTries: Int = 3) -> MacVM {
    MacVM(runner: runner, scratch: MacVM.newScratchFolder(), log: { log.add($0) }, pause: { _ in },
          renewEvery: .seconds(3600), reachTries: reachTries, reachEvery: .seconds(1))
}

@Suite struct MacVMTests {
    @Test func leaseIsParsedFromItsExportLines() throws {
        let lease = try VMLease.parse(leaseOutput)
        #expect(lease == VMLease(id: "a1b2c3d4", host: "192.168.166.1", port: "52022", user: "runner", proxyCommand: nil))
        let proxied = try VMLease.parse(leaseOutput.replacingOccurrences(
            of: "NIMBUS_SSH_PROXY_COMMAND=''", with: "NIMBUS_SSH_PROXY_COMMAND='/opt/nimbus/bin/nimbus job connect %h:%p'"))
        #expect(proxied.proxyCommand == "/opt/nimbus/bin/nimbus job connect %h:%p")
        #expect(try VMLease.unquote("'it'\\''s'") == "it's")
        #expect(throws: MacVMError.self) { try VMLease.parse("export NIMBUS_ID='x'\n") }
    }

    @Test func aStepLeasesCopiesRunsCopiesBackAndReleases() async throws {
        let runner = FakeRunner(vmHandler(command: 0))
        let vm = makeVM(runner)
        let request = MacVMRequest(command: "make test", folder: "/work", environment: ["A=1"], out: ["out/review"], label: "isomer apple-mac")
        let status = try await vm.run(request)
        #expect(status == 0)

        let calls = runner.calls
        #expect(calls.map(\.executable) == ["ssh-keygen", "/opt/nimbus/bin/nimbus", "ssh", "tar", "ssh", "ssh", "ssh", "tar", "/opt/nimbus/bin/nimbus"])
        #expect(calls[1].arguments == ["job", "lease", "macos", "--config=xcode_27_2", "--minutes=60",
                                       "--key=\(vm.scratch)/key.pub", "--label=isomer apple-mac"])
        #expect(calls[3].arguments == ["-cf", "\(vm.scratch)/in.tar", "--exclude=./.bazelrc.user", "--exclude=./.git", "-C", "/work", "."])
        #expect(calls[4].input == "\(vm.scratch)/in.tar")
        #expect(calls[4].remote == "rm -rf ~/mac-vm && mkdir ~/mac-vm && tar -xf - -C ~/mac-vm")
        #expect(calls[5].output == .inherited)
        #expect(calls[6].output == .file("\(vm.scratch)/out.tar"))
        #expect(calls[7].arguments == ["-xf", "\(vm.scratch)/out.tar", "-C", "/work"])
        #expect(calls[8].arguments == ["job", "release", "a1b2c3d4"])
        // ssh goes straight to the VM, with no ProxyCommand when the lease has none.
        #expect(calls[2].arguments.contains("runner@192.168.166.1"))
        #expect(calls[2].arguments.firstIndex(of: "-p").map { calls[2].arguments[$0 + 1] } == "52022")
        #expect(!calls[2].arguments.contains { $0.hasPrefix("ProxyCommand=") })
        #expect(!FileManager.default.fileExists(atPath: vm.scratch))
    }

    @Test func theCommandsStatusIsTheSteps() async throws {
        let runner = FakeRunner(vmHandler(command: 3))
        let status = try await makeVM(runner).run(MacVMRequest(command: "false", out: ["out"]))
        #expect(status == 3)
        // Copied back and released all the same.
        #expect(runner.calls.contains { $0.remote.contains("tar -chf - 'out'") })
        #expect(runner.calls.last?.arguments == ["job", "release", "a1b2c3d4"])
    }

    @Test func theLeaseIsReleasedWhenTheCopyFails() async throws {
        let runner = FakeRunner(vmHandler(fail: "tar -xf - -C"))
        await #expect(throws: MacVMError.self) { try await makeVM(runner).run(MacVMRequest(command: "true")) }
        #expect(runner.calls.last?.arguments == ["job", "release", "a1b2c3d4"])
        #expect(!runner.calls.contains { $0.remote.contains("zsh -lc") })
    }

    @Test func theLeaseIsReleasedWhenSSHNeverAnswers() async throws {
        let runner = FakeRunner(vmHandler(reachAfter: 99))
        await #expect(throws: MacVMError.self) { try await makeVM(runner, reachTries: 3).run(MacVMRequest(command: "true")) }
        #expect(runner.calls.filter { $0.remote == "true" }.count == 3)
        #expect(runner.calls.last?.arguments == ["job", "release", "a1b2c3d4"])
    }

    @Test func sshIsTriedUntilItAnswers() async throws {
        let runner = FakeRunner(vmHandler(reachAfter: 2))
        #expect(try await makeVM(runner, reachTries: 5).run(MacVMRequest(command: "true")) == 0)
        #expect(runner.calls.filter { $0.remote == "true" }.count == 3)
    }

    @Test func aRefusedLeaseHasNothingToRelease() async throws {
        let runner = FakeRunner(vmHandler(fail: "/opt/nimbus/bin/nimbus"))
        await #expect(throws: MacVMError.self) { try await makeVM(runner).run(MacVMRequest(command: "true")) }
        #expect(runner.calls.map(\.executable) == ["ssh-keygen", "/opt/nimbus/bin/nimbus"])
    }

    @Test func releaseHappensOnce() async throws {
        let runner = FakeRunner(vmHandler())
        let vm = makeVM(runner)
        _ = try await vm.run(MacVMRequest(command: "true"))
        await vm.release()  // A signal's, after the normal way out's: nothing more.
        #expect(runner.calls.filter { $0.arguments.prefix(2) == ["job", "release"] }.count == 1)
    }

    @Test func aMissingOutIsSkippedWithAWarning() async throws {
        let runner = FakeRunner(vmHandler())
        let log = Lines()
        #expect(try await makeVM(runner, log: log).run(MacVMRequest(command: "true", out: ["missing"])) == 0)
        #expect(log.all.contains("::warning::mac-vm: nothing at missing"))
        #expect(!runner.calls.contains { $0.executable == "tar" && $0.arguments.first == "-xf" })
    }

    @Test func aProxiedLeaseGoesThroughItsProxy() async throws {
        let proxied = leaseOutput.replacingOccurrences(of: "NIMBUS_SSH_PROXY_COMMAND=''",
                                                       with: "NIMBUS_SSH_PROXY_COMMAND='/opt/nimbus/bin/nimbus job connect %h:%p'")
        let runner = FakeRunner(vmHandler(lease: proxied))
        _ = try await makeVM(runner).run(MacVMRequest(command: "true"))
        let sshCalls = runner.calls.filter { $0.executable == "ssh" }
        #expect(!sshCalls.isEmpty)
        #expect(sshCalls.allSatisfy { $0.arguments.contains("ProxyCommand=/opt/nimbus/bin/nimbus job connect %h:%p") })
    }

    @Test func theRemoteCommandQuotesTheCommandAndItsEnvironment() {
        let vm = makeVM(FakeRunner(vmHandler()))
        let request = MacVMRequest(command: "echo \"$HOME\" it's", environment: ["NAME=a b", "EMPTY=", "Q=it's"])
        #expect(vm.remoteCommand(request) == """
            cd ~/mac-vm && sudo launchctl asuser "$(id -u)" sudo -u "$(id -un)" env NAME='a b' EMPTY='' Q='it'\\''s' zsh -lc 'echo "$HOME" it'\\''s'
            """)
        var plain = request
        plain.desktop = false
        #expect(vm.remoteCommand(plain).hasPrefix("cd ~/mac-vm && env NAME="))
    }

    @Test func gitIsCopiedOnlyWhenAsked() async throws {
        let runner = FakeRunner(vmHandler())
        _ = try await makeVM(runner).run(MacVMRequest(command: "true", withGit: true))
        let tar = try #require(runner.calls.first { $0.executable == "tar" })
        #expect(!tar.arguments.contains("--exclude=./.git"))
        #expect(tar.arguments.contains("--exclude=./.bazelrc.user"))
    }

    @Test func environmentNamesAreChecked() async throws {
        let runner = FakeRunner(vmHandler())
        for bad in ["NOEQUALS", "1A=x", "A-B=x", "=x"] {
            await #expect(throws: MacVMError.self) { try await makeVM(runner).run(MacVMRequest(command: "true", environment: [bad])) }
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func noValueOfTheLeasesIsLogged() async throws {
        let log = Lines()
        _ = try await makeVM(FakeRunner(vmHandler()), log: log).run(MacVMRequest(command: "true", environment: ["TOKENISH=value-of-env"]))
        #expect(!log.all.contains { $0.contains("not printed") || $0.contains("value-of-env") || $0.contains("52022") })
    }

    @Test func aRealProgramsStatusComesBack() async throws {
        let runner = SystemProgramRunner()
        #expect(try await runner.run("sh", ["-c", "exit 7"], input: nil, output: .quiet).status == 7)
        let folder = MacVM.newScratchFolder()
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try "hello\n".write(toFile: folder + "/in", atomically: true, encoding: .utf8)
        #expect(try await runner.run("cat", [], input: folder + "/in", output: .collected).output == "hello\n")
        _ = try await runner.run("cat", [], input: folder + "/in", output: .file(folder + "/copy"))
        #expect(try String(contentsOfFile: folder + "/copy", encoding: .utf8) == "hello\n")
    }
}
