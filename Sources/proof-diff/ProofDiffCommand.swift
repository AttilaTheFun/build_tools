import ArgumentParser
import Foundation
import ProofKit

/// `proof-diff`: a proof's comparison with the release before's, made once (proof-diff.json), as Reviews reads it.
@main
struct ProofDiffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proof-diff",
        abstract: "Compare a proof with the release before's, as proof-diff.json.",
        discussion: """
        GITHUB_REPOSITORY (owner/name; CI sets it), GH_TOKEN (contents: read to make, write to backfill), GITHUB_API_URL, \
        and PROOF_TAG_PREFIX (a release's tag before its version: "v", or "shireworks-v" in a repository of several apps).
        """,
        subcommands: [Make.self, Backfill.self])
}

struct Settings {
    let environment = ProcessInfo.processInfo.environment
    var repository: String? { environment["GITHUB_REPOSITORY"].flatMap { $0.isEmpty ? nil : $0 } }
    var prefix: String { environment["PROOF_TAG_PREFIX"].flatMap { $0.isEmpty ? nil : $0 } ?? "v" }
}

func counted(_ document: [String: Any]) -> String {
    let counts = document["counts"] as? [String: Int] ?? [:]
    return "\(counts["added"] ?? 0) added, \(counts["removed"] ?? 0) removed, \(counts["changed"] ?? 0) changed, \(counts["unchanged"] ?? 0) unchanged"
}

/// `make`: never fails its job over the comparison (a base that can't be fetched, a picture that can't be read: the
/// manifest's `note` says so). Only a missing proof.json is an error.
struct Make: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "The comparison of a proof (verify's folder, or a release's zip) with the release before's.")

    @Argument(help: "The proof: verify's folder, or a proof.zip.")
    var proof: String

    @Option(help: "Where proof-diff.json goes (default: beside proof.json, or beside the zip).")
    var out: String?

    @Option(help: "The release to compare with, by its tag, rather than the release before.")
    var baseTag: String?

    func run() async throws {
        let settings = Settings()
        let proof: ProofDiff.Proof
        do {
            proof = try ProofDiff.Proof(path: self.proof)
        } catch {
            throw ValidationError("\(self.proof): \(error)")
        }
        guard let repository = settings.repository ?? proof.document["repository"] as? String else {
            throw ValidationError("which repository: GITHUB_REPOSITORY, or the proof's own")
        }
        let clock = ContinuousClock(), started = clock.now
        let (base, baseProof, note) = await ProofDiff.base(for: proof, in: repository, prefix: settings.prefix, tag: baseTag, github: GitHub())
        let fetched = clock.now
        let document = ProofDiff.manifest(proof, base: base, baseProof: baseProof, note: note)
        let compared = clock.now
        let folder = proof.isFolder ? self.proof : (URL(fileURLWithPath: self.proof).standardizedFileURL.deletingLastPathComponent().path)
        let path = out ?? (folder as NSString).appendingPathComponent("proof-diff.json")
        try ProofDiff.encoded(document).write(to: URL(fileURLWithPath: path))
        print("proof-diff: against \(base?["tag"] as? String ?? "nothing"): \(counted(document))\(note.map { " (\($0))" } ?? "")")
        let screens = (document["items"] as? [[String: Any]] ?? []).filter { $0["changedPixels"] != nil }.count
        func seconds(_ duration: Duration) -> String { String(format: "%.1f", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) }
        print("proof-diff: \(seconds(fetched - started)) s fetching the base's proof, \(seconds(compared - fetched)) s comparing (\(screens) screens' pixels)")
    }
}

/// `backfill`: every published release with a proof.zip and no proof-diff.json, oldest first: its comparison made
/// against the release before it and attached.
struct Backfill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Attach proof-diff.json to every published release with a proof.zip and none.")

    @Flag(help: "Say what would be attached, attaching nothing.")
    var dryRun = false

    func run() async throws {
        let settings = Settings()
        guard let repository = settings.repository else { throw ValidationError("GITHUB_REPOSITORY is owner/name") }
        let prefix = settings.prefix
        let github = GitHub()
        let listed = try await github.releases(repository)
        func version(_ release: [String: Any]) -> [Int]? { ProofDiff.version(release["tag_name"] as? String ?? "", prefix: prefix) }
        let published = listed.filter { $0["draft"] as? Bool != true && $0["prerelease"] as? Bool != true && version($0) != nil }
            .sorted { version($0)!.lexicographicallyPrecedes(version($1)!) }
        for release in published {
            let assets = release["assets"] as? [[String: Any]] ?? []
            let names = Set(assets.compactMap { $0["name"] as? String })
            guard names.contains("proof.zip"), !names.contains("proof-diff.json"),
                  let asset = assets.first(where: { $0["name"] as? String == "proof.zip" })?["id"] as? Int,
                  let tag = release["tag_name"] as? String, let id = release["id"] as? Int, let below = version(release) else { continue }
            let proof = try ProofDiff.Proof(data: try await github.assetData(repository, asset: asset))
            guard (proof.document["format"] as? Int) == 2 else {
                print("proof-diff: \(tag): its proof is not of format 2, passed over")
                continue
            }
            // Its base: the release before its tag, whatever its proof.json's version says (a verify proof says the line).
            let earlier = listed.filter { version($0).map { $0.lexicographicallyPrecedes(below) } ?? false }
            let base: [String: Any]?, baseProof: ProofDiff.Proof?, note: String?
            if let before = ProofDiff.baseRelease(earlier, below: nil, prefix: prefix), let beforeTag = before["tag_name"] as? String {
                (base, baseProof, note) = await ProofDiff.base(for: proof, in: repository, prefix: prefix, tag: beforeTag, listed: listed, github: github)
            } else {
                (base, baseProof, note) = (nil, nil, "no release before this one")
            }
            let document = ProofDiff.manifest(proof, base: base, baseProof: baseProof, note: note)
            print("proof-diff: \(tag) against \(base?["tag"] as? String ?? "nothing"): \(counted(document))")
            guard !dryRun else { continue }
            try await github.upload(try ProofDiff.encoded(document), name: "proof-diff.json", contentType: "application/json", release: id, in: repository)
            print("proof-diff: \(tag): proof-diff.json attached")
        }
    }
}
