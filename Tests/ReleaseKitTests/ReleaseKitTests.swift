import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ReleaseKit

// release's rules (Versions, InfoPlistText) as the shell scripts had them, and its steps against a fake GitHub.

@Test func aLineIsMajorDotMinor() {
    #expect(Versions.line(of: "1.2") == "1.2")
    #expect(Versions.line(of: "1.2.0") == "1.2")
    #expect(Versions.line(of: "01.20.7") == "1.20")
    for bad in ["1", "1.x", "1.2.3.4", "", "v1.2", "1..2"] {
        #expect(Versions.line(of: bad) == nil, "\(bad)")
    }
}

@Test func theNextVersionIsOnePastTheLinesHighest() {
    let releases = [(tag: "v1.2.3", commit: "a"), (tag: "v1.1.9", commit: "b"), (tag: "v1.2.x", commit: "c")]
    #expect(Versions.next(line: "1.2", commit: "z", releases: releases, tags: ["v1.2.5", "v1.3.1", "other"]) == "1.2.6")
    #expect(Versions.next(line: "1.4", commit: "z", releases: releases, tags: []) == "1.4.1")
}

@Test func theSameCommitGetsItsVersionAgain() {
    let releases = [(tag: "v1.2.3", commit: "a"), (tag: "v1.2.4", commit: "b")]
    #expect(Versions.next(line: "1.2", commit: "a", releases: releases, tags: ["v1.2.9"]) == "1.2.3")
}

@Test func aLineWithAProductionReleaseIsClosed() {
    let releases = [(tag: "v1.2.3", draft: false, prerelease: true), (tag: "v1.2.4", draft: true, prerelease: false)]
    #expect(Versions.published(on: "1.2", releases: releases).isEmpty)
    #expect(Versions.published(on: "1.2", releases: releases + [(tag: "v1.2.5", draft: false, prerelease: false)]) == ["v1.2.5"])
    #expect(Versions.published(on: "1.3", releases: [(tag: "v1.2.5", draft: false, prerelease: false)]).isEmpty)
    #expect(Versions.lineAfter("1.9") == "1.10")
}

private let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<!-- A comment stays. -->
\t<key>CFBundleShortVersionString</key>
\t<string>1.2</string>
\t<key>CFBundleVersion</key>
\t<string>5</string>
</dict>
</plist>
"""

@Test func anInfoPlistsValueIsSetAsText() {
    #expect(InfoPlistText.value(of: "CFBundleShortVersionString", in: plist) == "1.2")
    let stamped = InfoPlistText.setting("CFBundleShortVersionString", to: "1.2.7", in: plist)!
    #expect(stamped == plist.replacingOccurrences(of: "<string>1.2</string>", with: "<string>1.2.7</string>"))
    #expect(stamped.contains("<!-- A comment stays. -->"))
    #expect(InfoPlistText.value(of: "Missing", in: plist) == nil)
    // A key with no string of its own isn't given the next key's.
    #expect(InfoPlistText.value(of: "Flag", in: "<key>Flag</key><true/><key>Name</key><string>x</string>") == nil)
}

@Test func aLinkHeadersNextPage() {
    let link = #"<https://api.github.com/repositories/1/releases?per_page=100&page=2>; rel="next", <https://api.github.com/repositories/1/releases?page=4>; rel="last""#
    #expect(GitHub.nextPage(link)?.absoluteString == "https://api.github.com/repositories/1/releases?per_page=100&page=2")
    #expect(GitHub.nextPage(#"<https://x/?page=1>; rel="prev""#) == nil)
    #expect(GitHub.nextPage(nil) == nil)
}

/// GitHub as the steps see it: releases and tags (two pages of releases), and every request sent.
private final class FakeGitHub: GitHubTransport, @unchecked Sendable {
    private let lock = NSLock()
    var releases: [[String: Any]]
    var tags: [String]
    var assets: [[String: Any]] = []
    private(set) var sent: [(method: String, path: String, body: [String: Any]?)] = []

    init(releases: [[String: Any]], tags: [String] = []) {
        self.releases = releases
        self.tags = tags
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { answer(request) }
    }

    private func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        sent.append((method, url.path, body))
        func answer(_ status: Int, _ object: Any? = nil, link: String? = nil) -> (Data, HTTPURLResponse) {
            let data = object.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
            var headers: [String: String] = [:]
            if let link { headers["Link"] = link }
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        switch (method, url.path) {
        case ("GET", "/repos/o/r/releases"):
            // Two pages: the first half, then the rest.
            let half = releases.count / 2
            if url.query?.contains("page=2") == true { return answer(200, Array(releases[half...])) }
            return answer(200, Array(releases[..<half]), link: "<https://api.test/repos/o/r/releases?per_page=100&page=2>; rel=\"next\"")
        case ("GET", "/repos/o/r/tags"):
            return answer(200, tags.map { ["name": $0] })
        case ("POST", "/repos/o/r/releases"), ("PATCH", _):
            return answer(201, ["id": 9])
        case ("GET", let path) where path.hasSuffix("/assets"):
            return answer(200, assets)
        case ("DELETE", _):
            return answer(204)
        case ("POST", let path) where url.host == "uploads.test" && path.hasSuffix("/assets"):
            return answer(201, ["id": 1])
        default:
            return answer(404, ["message": "Not Found"])
        }
    }
}

private func release(_ id: Int, _ tag: String, commit: String = "c", draft: Bool = false, prerelease: Bool = false) -> [String: Any] {
    ["id": id, "tag_name": tag, "target_commitish": commit, "draft": draft, "prerelease": prerelease]
}

private func releasing(_ fake: FakeGitHub) -> Releasing {
    Releasing(github: GitHub(repository: "o/r", token: "token", api: URL(string: "https://api.test")!,
                             uploads: URL(string: "https://uploads.test")!, transport: fake))
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("release-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test func theVersionIsStampedIntoEveryInfoPlist() async throws {
    let fake = FakeGitHub(releases: [release(1, "v1.2.1"), release(2, "v1.2.2"), release(3, "v1.1.8")], tags: ["v1.2.3"])
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let mac = folder.appendingPathComponent("Mac.plist"), phone = folder.appendingPathComponent("Phone.plist")
    let helper = folder.appendingPathComponent("Helper.plist")
    for file in [mac, phone, helper] { try plist.write(to: file, atomically: true, encoding: .utf8) }
    let version = try await releasing(fake).stampVersion(plists: [mac, phone], buildNumberPlists: [helper], commit: "z")
    #expect(version == "1.2.4")
    for file in [mac, phone] {
        #expect(InfoPlistText.value(of: "CFBundleShortVersionString", in: try String(contentsOf: file, encoding: .utf8)) == "1.2.4")
    }
    #expect(InfoPlistText.value(of: "CFBundleVersion", in: try String(contentsOf: helper, encoding: .utf8)) == "1.2.4")
}

@Test func aPublishedLineRefusesAProposal() async throws {
    let open = FakeGitHub(releases: [release(1, "v1.2.1", prerelease: true), release(2, "v1.2.2", draft: true)])
    #expect(try await releasing(open).checkLine("1.2.3").contains("may be proposed"))
    let closed = FakeGitHub(releases: [release(1, "v1.2.1"), release(2, "v1.1.1")])
    await #expect(throws: ReleaseError.self) { try await releasing(closed).checkLine("1.2.3") }
}

@Test func aDraftIsMadeOrBroughtUpToDate() async throws {
    let none = FakeGitHub(releases: [release(1, "v1.2.1"), release(2, "v1.2.2")])
    _ = try await releasing(none).draft(version: "1.2.3", prerelease: true, notes: "n", app: "Images", commit: "z")
    let made = try #require(none.sent.last)
    #expect(made.method == "POST" && made.path == "/repos/o/r/releases")
    #expect(made.body?["name"] as? String == "Images 1.2.3" && made.body?["draft"] as? Bool == true && made.body?["prerelease"] as? Bool == true)

    let drafted = FakeGitHub(releases: [release(1, "v1.2.1"), release(7, "v1.2.3", draft: true)])
    _ = try await releasing(drafted).draft(version: "1.2.3", prerelease: false, notes: "n", app: "Images", commit: "z")
    let updated = try #require(drafted.sent.last)
    #expect(updated.method == "PATCH" && updated.path == "/repos/o/r/releases/7" && updated.body?["prerelease"] as? Bool == false)
}

@Test func assetsAreAttachedBuildsJSONLast() async throws {
    let fake = FakeGitHub(releases: [release(1, "v1.2.2"), release(5, "v1.2.3", draft: true)])
    fake.assets = [["id": 40, "name": "Images-1.2.3-macos.zip"]]
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["builds.json", "Images-1.2.3-macos.zip", "Images-1.2.3-icon.png", "builds.lines"] {
        try Data(name.utf8).write(to: folder.appendingPathComponent(name))
    }
    var said: [String] = []
    try await releasing(fake).attach(tag: "v1.2.3", folder: folder) { said.append($0) }
    #expect(said == ["Images-1.2.3-icon.png attached to v1.2.3", "Images-1.2.3-macos.zip attached to v1.2.3", "builds.json attached to v1.2.3"])
    #expect(fake.sent.contains { $0.method == "DELETE" && $0.path == "/repos/o/r/releases/assets/40" })
}

@Test func aFolderWithoutBuildsJSONIsRefusedUnlessItsTheProof() async throws {
    let fake = FakeGitHub(releases: [release(1, "v1.2.2"), release(5, "v1.2.3", draft: true)])
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("x".utf8).write(to: folder.appendingPathComponent("Images-1.2.3-macos.zip"))
    await #expect(throws: ReleaseError.self) { try await releasing(fake).attach(tag: "v1.2.3", folder: folder) { _ in } }
    try FileManager.default.removeItem(at: folder.appendingPathComponent("Images-1.2.3-macos.zip"))
    try Data("x".utf8).write(to: folder.appendingPathComponent("proof.zip"))
    try await releasing(fake).attach(tag: "v1.2.3", folder: folder) { _ in }
}
