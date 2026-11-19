import ArgumentParser
import Foundation
import ProofKit

/// `tests-proof`: a repository's proof of its tests' results (format 2, `tests` items), its release's proof.zip when
/// it has no apps (Logan, 2026-11-19).
@main
struct TestsProofCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tests-proof",
        abstract: "Make a proof of a repository's test results: proof.json, each run's log, and proof.zip.",
        discussion: """
        Each run is <id>=<title>=<log>: a `swift test` log (XCTest's totals, Swift Testing's run line and failures are \
        read). GITHUB_REPOSITORY, GITHUB_SHA and GITHUB_RUN_ID name what it's a proof of. Exits 1 when a run failed, ran \
        no tests, or never said its totals, after writing the proof.
        """)

    @Option(help: "The folder the proof is made in.")
    var out: String

    @Option(help: "The repository's name as the proof calls it (its \"app\").")
    var app: String

    @Option(help: "The version it's a proof of.")
    var version: String

    @Option(help: "Also zip the proof here (the release's proof.zip).")
    var zip: String?

    @Argument(help: "The runs: <id>=<title>=<log>.")
    var runs: [String]

    func run() throws {
        let parsed = try runs.map { spec -> TestsProof.Run in
            guard let run = TestsProof.Run(spec: spec) else { throw ValidationError("a run is <id>=<title>=<log>: \(spec)") }
            return run
        }
        let (proof, passed) = try TestsProof.write(parsed, to: out, app: app, version: version)
        for item in proof["items"] as? [[String: Any]] ?? [] {
            print("\(item["id"] ?? ""): \(item["result"] ?? ""), \(item["tests"] ?? 0) tests, \(item["failures"] ?? 0) failures")
        }
        if let zip { try ZipWriter.zip(folder: out).write(to: URL(fileURLWithPath: zip)) }
        if !passed { throw ExitCode.failure }
    }
}
