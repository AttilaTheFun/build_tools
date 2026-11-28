import ArgumentParser
import Dispatch
import Foundation
import MacVMKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// `mac-vm`: a step that needs macOS itself, from a CI job on a Nimbus runner.
@main
struct MacVMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mac-vm",
        abstract: "Runs a command in a Nimbus macOS VM: the folder copied in, the command run, its results copied back.",
        usage: "mac-vm [--env NAME=VALUE …] [--out <path> …] [--git] [--folder <folder>] -- <command>",
        discussion: """
        Leases a macOS VM from Nimbus in the job's name (`nimbus job lease macos`), renews it while the step runs, and \
        releases it however the step ends: done, failed, or stopped by a signal (SIGINT, SIGTERM, SIGHUP). The folder \
        (the job's checkout and what it downloaded; .git and .bazelrc.user left out) is copied in, the command run there \
        with `zsh -lc` in the VM's desktop session, and each --out path copied back whatever the command returned. The \
        exit status is the command's (ssh's 255 if the VM couldn't be reached).

        In a job with no network but Nimbus' proxy, the lease's NIMBUS_SSH_PROXY_COMMAND takes ssh to the VM.

        No secret goes in: Nimbus' VMs aren't network-locked. --env values are the command's, not the log's.
        """)

    @Option(name: .customLong("env"), help: "NAME=VALUE for the command (again for each).")
    var environment: [String] = []

    @Option(help: "A path in the folder copied back after the command (again for each); skipped if it isn't there.")
    var out: [String] = []

    @Flag(help: "Copy the checkout's .git in too.")
    var git = false

    @Flag(name: .customLong("no-desktop"), help: "Run over SSH alone, not in the VM's desktop session.")
    var noDesktop = false

    @Option(help: "The folder copied in, and where --out paths come back to.")
    var folder = "."

    @Option(help: "The VM's base.")
    var config = "xcode_27_2"

    @Option(help: "Shown beside the lease (the repository and job when unset).")
    var label: String?

    @Option(help: "Nimbus' command line.")
    var nimbus = "/opt/nimbus/bin/nimbus"

    @Argument(parsing: .postTerminator, help: "The command, run with zsh -lc in the VM's copy of the folder.")
    var command: [String] = []

    func run() async throws {
        guard !command.isEmpty else { throw ValidationError("a command is needed: mac-vm … -- <command>") }
        let environment = ProcessInfo.processInfo.environment
        let jobLabel = [environment["GITHUB_REPOSITORY"], environment["GITHUB_JOB"]].compactMap { $0 }.joined(separator: " ")
        let request = MacVMRequest(command: command.joined(separator: " "), folder: folder, environment: self.environment,
                                   out: out, withGit: git, desktop: !noDesktop, config: config,
                                   label: label ?? (jobLabel.isEmpty ? "mac-vm" : jobLabel))
        let vm = MacVM(nimbus: nimbus)
        let signals = SignalRelease(vm)
        defer { signals.stop() }
        let status: Int32
        do {
            status = try await vm.run(request)
        } catch let error as MacVMError {
            FileHandle.standardError.write(Data("mac-vm: \(error.description)\n".utf8))
            throw ExitCode(1)
        }
        if status != 0 { throw ExitCode(status) }
    }
}

/// A signal that would end the step (the job cancelled, its time up) releases the lease first, then ends with
/// 128 plus the signal, as a shell does.
final class SignalRelease: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []

    init(_ vm: MacVM) {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                FileHandle.standardError.write(Data("mac-vm: stopped by signal \(number); releasing the lease\n".utf8))
                let done = DispatchSemaphore(value: 0)
                Task {
                    await vm.release()
                    vm.removeScratch()
                    done.signal()
                }
                _ = done.wait(timeout: .now() + 60)
                exit(128 + number)
            }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        for source in sources { source.cancel() }
    }
}
