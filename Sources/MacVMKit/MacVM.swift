import Foundation

public struct MacVMError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// What a step asks of a macOS VM: the folder copied in, a command run in it, some paths copied back.
public struct MacVMRequest: Sendable, Equatable {
    /// The command, run with `zsh -lc` in the copied folder (Homebrew's tools, Xcode).
    public var command: String
    /// The folder copied in (the job's checkout and what it downloaded).
    public var folder: String
    /// `NAME=VALUE` pairs set for the command. Never a secret: Nimbus' VMs aren't network-locked.
    public var environment: [String]
    /// Paths in the folder copied back after the command, whatever it returned; those it didn't make are skipped.
    public var out: [String]
    /// Copied in with the folder too (it's left out unless asked: a quick proof reads the branch's history).
    public var withGit: Bool
    /// Run in the VM's desktop session (`launchctl asuser`), where an app can show a window and a simulator can boot.
    public var desktop: Bool
    /// The VM's base.
    public var config: String
    /// Shown beside the lease to everyone watching the server.
    public var label: String

    public init(command: String, folder: String = ".", environment: [String] = [], out: [String] = [],
                withGit: Bool = false, desktop: Bool = true, config: String = "xcode_27_2", label: String = "mac-vm") {
        self.command = command
        self.folder = folder
        self.environment = environment
        self.out = out
        self.withGit = withGit
        self.desktop = desktop
        self.config = config
        self.label = label
    }
}

/// A lease's way in, as `nimbus job lease` prints it (`export NAME='value'` lines).
public struct VMLease: Sendable, Equatable {
    public var id: String
    public var host: String
    public var port: String
    public var user: String
    /// ssh's ProxyCommand in a job with no network but Nimbus' proxy; nil without one.
    public var proxyCommand: String?

    public init(id: String, host: String, port: String, user: String, proxyCommand: String? = nil) {
        self.id = id
        self.host = host
        self.port = port
        self.user = user
        self.proxyCommand = proxyCommand
    }

    /// The lease from `nimbus job lease`'s output: its `export` lines, each value quoted as a shell's single quotes.
    public static func parse(_ output: String) throws -> VMLease {
        var values: [String: String] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<equals])
            guard name.hasPrefix("NIMBUS_") else { continue }
            values[name] = try unquote(String(line[line.index(after: equals)...]))
        }
        func required(_ name: String) throws -> String {
            guard let value = values[name], !value.isEmpty else {
                throw MacVMError("nimbus job lease printed no \(name): is this a VM lease, on a Nimbus runner?")
            }
            return value
        }
        let proxy = values["NIMBUS_SSH_PROXY_COMMAND"].flatMap { $0.isEmpty ? nil : $0 }
        return VMLease(id: try required("NIMBUS_ID"), host: try required("NIMBUS_HOST"), port: try required("NIMBUS_SSH_PORT"),
                       user: try required("NIMBUS_SSH_USER"), proxyCommand: proxy)
    }

    /// A shell word back to its text: single quotes (with `'\''` for a quote), double quotes, or bare.
    static func unquote(_ word: String) throws -> String {
        var text = ""
        var index = word.startIndex
        while index < word.endIndex {
            let character = word[index]
            if character == "'" {
                guard let close = word[word.index(after: index)...].firstIndex(of: "'") else {
                    throw MacVMError("an unclosed quote in nimbus job lease's output")
                }
                text += word[word.index(after: index)..<close]
                index = word.index(after: close)
            } else if character == "\\", word.index(after: index) < word.endIndex {
                text.append(word[word.index(after: index)])
                index = word.index(index, offsetBy: 2)
            } else if character == "\"" {
                guard let close = word[word.index(after: index)...].firstIndex(of: "\"") else {
                    throw MacVMError("an unclosed quote in nimbus job lease's output")
                }
                text += word[word.index(after: index)..<close]
                index = word.index(after: close)
            } else {
                text.append(character)
                index = word.index(after: index)
            }
        }
        return text
    }
}

/// A word for a POSIX shell, as itself: single-quoted, with `'\''` for each quote in it.
public func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// A step that needs macOS itself, from a CI job on a Nimbus runner (a Linux container): a macOS VM leased in the job's
/// name, renewed while it runs and released however the step ends; the folder copied in; the command run in the VM's
/// desktop session; the paths asked for copied back. The exit status is the command's (ssh's 255 when the VM couldn't
/// be reached). What isomer's and playground's `.github/actions/mac_vm` did in a page of bash.
public final class MacVM: Sendable {
    public let runner: any ProgramRunner
    /// Nimbus' command line (`/opt/nimbus/bin/nimbus`).
    public let nimbus: String
    /// A folder of this run's own (its SSH key, known hosts and archives), removed at the end.
    public let scratch: String
    /// The job's log (standard error: standard output is the command's).
    public let log: @Sendable (String) -> Void
    /// A pause between tries (a test's returns at once).
    public let pause: @Sendable (Duration) async -> Void
    /// How long a lease is asked for, and renewed to, in minutes; how often it is renewed.
    public let minutes: Int
    public let renewEvery: Duration
    /// Tries at reaching the VM's SSH, `pause`d `reachEvery` apart, before giving up.
    public let reachTries: Int
    public let reachEvery: Duration

    private let held = Held()

    public init(runner: any ProgramRunner = SystemProgramRunner(), nimbus: String = "/opt/nimbus/bin/nimbus",
                scratch: String = MacVM.newScratchFolder(),
                log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                minutes: Int = 60, renewEvery: Duration = .seconds(600), reachTries: Int = 60, reachEvery: Duration = .seconds(5)) {
        self.runner = runner
        self.nimbus = nimbus
        self.scratch = scratch
        self.log = log
        self.pause = pause
        self.minutes = minutes
        self.renewEvery = renewEvery
        self.reachTries = reachTries
        self.reachEvery = reachEvery
    }

    public static func newScratchFolder() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("mac-vm-\(UUID().uuidString)").path
    }

    var key: String { scratch + "/key" }
    var knownHosts: String { scratch + "/known_hosts" }
    var archiveIn: String { scratch + "/in.tar" }
    var archiveOut: String { scratch + "/out.tar" }
    /// The folder's copy in the VM, under the login's home.
    static let remoteFolder = "~/mac-vm"

    // MARK: - The step

    /// Leases, copies in, runs, copies back and releases; the command's exit status. The lease is released on every
    /// way out of here, a thrown error's included (a signal's: `releaseNow()`).
    public func run(_ request: MacVMRequest) async throws -> Int32 {
        try Self.check(environment: request.environment)
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let lease: VMLease
        do {
            lease = try await self.lease(request)
        } catch {
            removeScratch()
            throw error
        }
        let renewing = Task { [self] in await renew(lease) }
        do {
            let status = try await use(lease, for: request)
            renewing.cancel()
            await release()
            removeScratch()
            return status
        } catch {
            renewing.cancel()
            await release()
            removeScratch()
            throw error
        }
    }

    func use(_ lease: VMLease, for request: MacVMRequest) async throws -> Int32 {
        try await waitForSSH(lease)
        try await copyIn(request, to: lease)
        log("mac-vm: running the command in \(lease.id)\(request.desktop ? "'s desktop session" : "")")
        let ran = try await runner.run("ssh", ssh(lease) + [remoteCommand(request)], input: nil, output: .inherited)
        log("mac-vm: the command answered \(ran.status)")
        for path in request.out { try await copyBack(path, from: lease, into: request.folder) }
        return ran.status
    }

    // MARK: - The lease

    func lease(_ request: MacVMRequest) async throws -> VMLease {
        let made = try await runner.run("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "mac-vm", "-f", key],
                                        input: nil, output: .quiet)
        guard made.status == 0 else { throw MacVMError("ssh-keygen answered \(made.status)") }
        log("mac-vm: leasing a macOS VM (\(request.config)) from Nimbus")
        let leased = try await runner.run(nimbus, ["job", "lease", "macos", "--config=\(request.config)", "--minutes=\(minutes)",
                                                   "--key=\(key).pub", "--label=\(request.label)"], input: nil, output: .collected)
        guard leased.status == 0 else { throw MacVMError("nimbus job lease answered \(leased.status)") }
        let lease = try VMLease.parse(leased.output)
        held.set(lease.id)
        log("mac-vm: leased \(lease.id)")
        return lease
    }

    /// Renewed every `renewEvery` until cancelled; a failed renewal is said and tried again next time.
    func renew(_ lease: VMLease) async {
        while !Task.isCancelled {
            // A real sleep, not `pause`: cancelling it is how the step ends the renewals.
            do { try await Task.sleep(for: renewEvery) } catch { return }
            let renewed = try? await runner.run(nimbus, ["job", "renew", lease.id, "--minutes=\(minutes)"], input: nil, output: .quiet)
            if renewed?.status != 0 { log("mac-vm: renewing \(lease.id) failed; trying again in \(renewEvery)") }
        }
    }

    /// Releases the lease held, once (a second call does nothing): the normal way out's, and a signal's.
    public func release() async {
        guard let id = held.take() else { return }
        let released = try? await runner.run(nimbus, ["job", "release", id], input: nil, output: .inherited)
        if released?.status == 0 {
            log("mac-vm: released \(id)")
        } else {
            log("::warning::mac-vm: releasing \(id) failed (\(released.map { "\($0.status)" } ?? "didn't run")); it ends when its time does")
        }
    }

    public func removeScratch() {
        try? FileManager.default.removeItem(atPath: scratch)
    }

    // MARK: - SSH

    /// ssh's arguments to the VM, before its command.
    func ssh(_ lease: VMLease) -> [String] {
        var arguments = ["-p", lease.port, "-i", key, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                         "-o", "ServerAliveInterval=30", "-o", "StrictHostKeyChecking=accept-new",
                         "-o", "UserKnownHostsFile=\(knownHosts)"]
        if let proxy = lease.proxyCommand { arguments += ["-o", "ProxyCommand=\(proxy)"] }
        return arguments + ["\(lease.user)@\(lease.host)"]
    }

    func waitForSSH(_ lease: VMLease) async throws {
        for attempt in 1...max(reachTries, 1) {
            let probe = try await runner.run("ssh", ssh(lease) + ["true"], input: nil, output: .quiet)
            if probe.status == 0 { return }
            if attempt < reachTries { await pause(reachEvery) }
        }
        throw MacVMError("\(lease.id)'s SSH didn't answer after \(reachTries) tries")
    }

    // MARK: - Files

    /// The folder as a tar, sent to a fresh copy in the VM.
    func copyIn(_ request: MacVMRequest, to lease: VMLease) async throws {
        var excluded = ["--exclude=./.bazelrc.user"]
        if !request.withGit { excluded.append("--exclude=./.git") }
        let packed = try await runner.run("tar", ["-cf", archiveIn] + excluded + ["-C", request.folder, "."], input: nil, output: .inherited)
        guard packed.status == 0 else { throw MacVMError("tar of \(request.folder) answered \(packed.status)") }
        let folder = Self.remoteFolder
        let sent = try await runner.run("ssh", ssh(lease) + ["rm -rf \(folder) && mkdir \(folder) && tar -xf - -C \(folder)"],
                                        input: archiveIn, output: .inherited)
        guard sent.status == 0 else { throw MacVMError("copying \(request.folder) into \(lease.id) answered \(sent.status)") }
        try? FileManager.default.removeItem(atPath: archiveIn)
    }

    /// A path of the VM's copy back into the folder (followed links as their files); skipped, and said, if it's not there.
    func copyBack(_ path: String, from lease: VMLease, into folder: String) async throws {
        let quoted = shellQuote(path)
        let fetched = try await runner.run("ssh", ssh(lease) + ["cd \(Self.remoteFolder) && [ -e \(quoted) ] && tar -chf - \(quoted)"],
                                           input: nil, output: .file(archiveOut))
        guard fetched.status == 0 else {
            log("::warning::mac-vm: nothing at \(path)")
            return
        }
        let unpacked = try await runner.run("tar", ["-xf", archiveOut, "-C", folder], input: nil, output: .inherited)
        if unpacked.status != 0 { log("::warning::mac-vm: \(path) came back but didn't unpack (tar answered \(unpacked.status))") }
        try? FileManager.default.removeItem(atPath: archiveOut)
    }

    // MARK: - The command

    /// What ssh runs: the command in the copied folder, by zsh as a login shell, with its environment, in the desktop
    /// session when asked.
    func remoteCommand(_ request: MacVMRequest) -> String {
        let environment = request.environment.map { pair -> String in
            let equals = pair.firstIndex(of: "=")!
            return String(pair[..<equals]) + "=" + shellQuote(String(pair[pair.index(after: equals)...]))
        }
        let shell = (["env"] + environment + ["zsh", "-lc", shellQuote(request.command)]).joined(separator: " ")
        let session = request.desktop ? "sudo launchctl asuser \"$(id -u)\" sudo -u \"$(id -un)\" " : ""
        return "cd \(Self.remoteFolder) && \(session)\(shell)"
    }

    /// Each pair `NAME=VALUE`, its name a shell variable's.
    static func check(environment: [String]) throws {
        for pair in environment {
            guard let equals = pair.firstIndex(of: "=") else { throw MacVMError("--env \(pair): NAME=VALUE") }
            let name = pair[..<equals]
            guard let first = name.first, first == "_" || first.isLetter, first.isASCII,
                  name.allSatisfy({ $0.isASCII && ($0 == "_" || $0.isLetter || $0.isNumber) }) else {
                throw MacVMError("--env \(name)=…: not a variable's name")
            }
        }
    }
}

/// The lease held, taken once by whichever way out releases it.
final class Held: @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?
    func set(_ id: String) { lock.withLock { self.id = id } }
    func take() -> String? { lock.withLock { defer { id = nil }; return id } }
}
