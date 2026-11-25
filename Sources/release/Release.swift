import ArgumentParser
import Foundation
import ReleaseKit

/// `release`: a release's steps in its CI job, with the job's token (GH_TOKEN) and GITHUB_REPOSITORY and GITHUB_SHA
/// from its environment.
@main
struct ReleaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "A release's steps in its CI job: the build's version, the line's check, the draft and its assets.",
        subcommands: [Version.self, CheckLine.self, Draft.self, Attach.self])
}

private func resolvedCommit(_ given: String?) throws -> String {
    if let given { return given }
    guard let sha = ProcessInfo.processInfo.environment["GITHUB_SHA"], !sha.isEmpty else {
        throw ValidationError("no commit: give --commit, or run in a job (GITHUB_SHA)")
    }
    return sha
}

/// Errors as a job's annotation and a failing exit, not a stack.
private func reportingErrors(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let error as ReleaseError {
        FileHandle.standardError.write(Data("::error::\(error.description)\n".utf8))
        throw ExitCode.failure
    }
}

struct Version: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stamp the build's version (MAJOR.MINOR.N: the committed line's next, or this commit's) into the Info.plists, and print it.")

    @Option(help: "The commit being built (default: GITHUB_SHA).")
    var commit: String?

    @Option(help: "An Info.plist whose CFBundleVersion is the version too (a helper's); repeatable.")
    var buildNumber: [String] = []

    @Option(help: "A file the version is appended to as version=<version> (GITHUB_OUTPUT, for the step's output).")
    var output: String?

    @Argument(help: "The Info.plists; the first one's CFBundleShortVersionString is the committed line.")
    var plists: [String]

    func run() async throws {
        try await reportingErrors {
            let sha = try resolvedCommit(commit)
            let releasing = Releasing(github: try GitHub.fromEnvironment())
            let version = try await releasing.stampVersion(plists: plists.map(URL.init(fileURLWithPath:)),
                                                           buildNumberPlists: buildNumber.map(URL.init(fileURLWithPath:)), commit: sha)
            if let output {
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("version=\(version)\n".utf8))
                try handle.close()
            }
            FileHandle.standardError.write(Data("release: \(version) (for \(sha)), stamped into \(plists.joined(separator: " "))\n".utf8))
            print(version)
        }
    }
}

struct CheckLine: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-line",
        abstract: "Refuse a version whose line already has a production release.")

    @Argument(help: "The version proposed.")
    var version: String

    func run() async throws {
        try await reportingErrors {
            print("release: " + (try await Releasing(github: try GitHub.fromEnvironment()).checkLine(version)))
        }
    }
}

struct Draft: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Make (or bring up to date) the draft release v<version>, \"<App> <version>\", at the commit.")

    @Argument(help: "The version.")
    var version: String

    @Option(help: "prerelease (a pre-release) or release (proposed for the owner's Release).")
    var kind: String

    @Option(help: "A Markdown file: the release's notes.")
    var notes: String

    @Option(help: "The app's name, the release's title's first word.")
    var app: String

    @Option(help: "The commit (default: GITHUB_SHA).")
    var commit: String?

    func validate() throws {
        guard kind == "prerelease" || kind == "release" else { throw ValidationError("--kind is prerelease or release") }
    }

    func run() async throws {
        try await reportingErrors {
            let body = try String(contentsOfFile: notes, encoding: .utf8)
            let said = try await Releasing(github: try GitHub.fromEnvironment())
                .draft(version: version, prerelease: kind == "prerelease", notes: body, app: app, commit: try resolvedCommit(commit))
            print("release: \(said)")
        }
    }
}

struct Attach: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Attach a folder's files to a release (one of the same name replaced), builds.json last.")

    @Argument(help: "The release's tag (v<version>).")
    var tag: String

    @Argument(help: "The folder: the signed builds, builds.json, and anything else to attach.")
    var folder: String

    func run() async throws {
        try await reportingErrors {
            try await Releasing(github: try GitHub.fromEnvironment())
                .attach(tag: tag, folder: URL(fileURLWithPath: folder)) { print("release: \($0)") }
        }
    }
}
