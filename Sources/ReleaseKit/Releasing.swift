import Foundation

/// A release's steps in its CI job (ported from shireworks' version_from_tags.sh, check_version_line.sh,
/// draft_release.sh and attach_release.sh): the build's version, the line's check, the draft, and its assets.
public struct Releasing: Sendable {
    let github: GitHub

    public init(github: GitHub) {
        self.github = github
    }

    /// The version of a build of `commit`, from the first Info.plist's committed line, stamped into each Info.plist's
    /// CFBundleShortVersionString (and into `buildNumberPlists`' CFBundleVersion: helpers that carry the version as
    /// their build number). The files are rewritten as text, the rest of them as they were.
    public func stampVersion(plists: [URL], buildNumberPlists: [URL] = [], commit: String) async throws -> String {
        guard let first = plists.first else { throw ReleaseError("no Info.plist given") }
        var texts: [URL: String] = [:]
        for plist in plists + buildNumberPlists {
            texts[plist] = try String(contentsOf: plist, encoding: .utf8)
        }
        guard let committed = InfoPlistText.value(of: "CFBundleShortVersionString", in: texts[first]!) else {
            throw ReleaseError("\(first.path) is no XML Info.plist with a CFBundleShortVersionString")
        }
        guard let line = Versions.line(of: committed) else {
            throw ReleaseError("\(first.path)'s CFBundleShortVersionString, \"\(committed)\", is not MAJOR.MINOR.0")
        }
        let releases = try await github.releases()
        let tags = try await github.tags()
        let version = Versions.next(line: line, commit: commit, releases: releases.map { ($0.tag, $0.commit) }, tags: tags)
        for plist in plists {
            guard let stamped = InfoPlistText.setting("CFBundleShortVersionString", to: version, in: texts[plist]!) else {
                throw ReleaseError("\(plist.path) has no CFBundleShortVersionString to stamp")
            }
            try stamped.write(to: plist, atomically: true, encoding: .utf8)
        }
        for plist in buildNumberPlists {
            guard let stamped = InfoPlistText.setting("CFBundleVersion", to: version, in: texts[plist]!) else {
                throw ReleaseError("\(plist.path) has no CFBundleVersion to stamp")
            }
            try stamped.write(to: plist, atomically: true, encoding: .utf8)
        }
        return version
    }

    /// Refuses a version whose line already has a production release: the committed line must move on first.
    public func checkLine(_ version: String) async throws -> String {
        guard let line = Versions.line(of: version) else { throw ReleaseError("\"\(version)\" is not MAJOR.MINOR[.BUILD]") }
        let published = Versions.published(on: line, releases: try await github.releases().map { ($0.tag, $0.draft, $0.prerelease) })
        guard published.isEmpty else {
            throw ReleaseError("\(version) is on the \(line) line, which is already published as a production release "
                + "(\(published.joined(separator: " "))). Move the committed line to \(Versions.lineAfter(line)).0 "
                + "(CFBundleShortVersionString), and propose again.")
        }
        return "the \(line) line has no production release yet, so \(version) may be proposed"
    }

    /// The draft release `v<version>` ("<App> <version>") at `commit`: made, or the existing draft of that tag
    /// brought up to date. A pre-release for `prerelease`, a release proposed for Logan's Release otherwise.
    public func draft(version: String, prerelease: Bool, notes: String, app: String, commit: String) async throws -> String {
        let tag = "v\(version)"
        if let existing = try await github.releases().first(where: { $0.draft && $0.tag == tag }) {
            try await github.updateRelease(id: existing.id, tag: tag, commit: commit, prerelease: prerelease, body: notes)
            return "\(tag)'s draft updated (\(prerelease ? "prerelease" : "release"), \(commit))"
        }
        try await github.createRelease(tag: tag, commit: commit, name: "\(app) \(version)", prerelease: prerelease, body: notes)
        return "\(tag) drafted (\(prerelease ? "prerelease" : "release"), \(commit))"
    }

    /// Every file in `folder` attached to `tag`'s release, one of the same name replaced, builds.json last (what
    /// Applications reads, once the builds it names are there). A folder without builds.json may hold the proof alone.
    ///
    /// The release never goes without a file it had: each is uploaded under a staged name (`new-<run>-<name>`) first,
    /// and only then is the old one deleted and the staged one renamed (p2prc#12: a delete that landed, then an upload
    /// that got a 502, lost a release's APK). `run` is the job's GITHUB_RUN_ID, else a fresh one.
    public func attach(tag: String, folder: URL, run: String? = ProcessInfo.processInfo.environment["GITHUB_RUN_ID"],
                       waitForRelease: Duration = .seconds(60), log: (String) -> Void = { print($0) }) async throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }.sorted()
        let skipped: Set = ["builds.json", "builds.lines", "builds.lines.new"]
        let files = names.filter { !skipped.contains($0) }
        if !names.contains("builds.json") {
            guard names.contains("proof.zip"), files.allSatisfy({ $0 == "proof.zip" || $0 == "proof-diff.json" }) else {
                throw ReleaseError("\(folder.path) has no builds.json")
            }
        }
        // A draft just made can take a moment to be listed.
        let clock = ContinuousClock()
        let deadline = clock.now + waitForRelease
        var release = try await github.releases().first { $0.tag == tag }
        while release == nil, clock.now < deadline {
            try await Task.sleep(for: .seconds(5))
            release = try await github.releases().first { $0.tag == tag }
        }
        guard let release else { throw ReleaseError("no release \(tag) in \(github.repository)") }
        let stage = "new-\(run.flatMap { $0.isEmpty ? nil : $0 } ?? String(UUID().uuidString.prefix(8)).lowercased())-"
        for name in files + (names.contains("builds.json") ? ["builds.json"] : []) {
            // A staged copy an earlier run of this job left goes first.
            for leftover in try await github.assets(release: release.id) where leftover.name == stage + name {
                try await github.deleteAsset(id: leftover.id)
            }
            let staged = try await github.upload(release: release.id, name: stage + name, type: Self.contentType(name),
                                                 file: folder.appendingPathComponent(name))
            for old in try await github.assets(release: release.id) where old.name == name {
                try await github.deleteAsset(id: old.id)
            }
            try await github.renameAsset(id: staged.id, to: name)
            log("\(name) attached to \(tag)")
        }
    }

    static func contentType(_ name: String) -> String {
        if name.hasSuffix(".json") { return "application/json" }
        if name.hasSuffix(".apk") { return "application/vnd.android.package-archive" }
        if name.hasSuffix(".png") { return "image/png" }
        return "application/octet-stream"
    }
}
