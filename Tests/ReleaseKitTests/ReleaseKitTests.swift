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

/// GitHub as the steps see it: releases (two pages) and tags, assets that uploads add, deletes remove and renames
/// rename, every request sent, and failures scripted by request: one answers its status having done nothing, or
/// (`landed`) having done what it was asked.
private final class FakeGitHub: GitHubTransport, @unchecked Sendable {
    struct Failure {
        let method: String
        let path: String
        let status: Int
        let landed: Bool
    }

    private let lock = NSLock()
    var releases: [[String: Any]]
    var tags: [String]
    var assets: [(id: Int, name: String)] = []
    var failures: [Failure] = []
    private var nextID = 100
    private(set) var sent: [(method: String, path: String, body: [String: Any]?)] = []

    init(releases: [[String: Any]], tags: [String] = []) {
        self.releases = releases
        self.tags = tags
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { answer(request) }
    }

    var assetNames: [String] { lock.withLock { assets.map(\.name).sorted() } }

    private func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        sent.append((method, url.path, body))
        func reply(_ status: Int, _ object: Any? = nil, link: String? = nil) -> (Data, HTTPURLResponse) {
            let data = object.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
            var headers: [String: String] = [:]
            if let link { headers["Link"] = link }
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        var failure: Failure?
        if let index = failures.firstIndex(where: { $0.method == method && url.path.hasSuffix($0.path) }) {
            failure = failures.remove(at: index)
            if failure?.landed == false { return reply(failure!.status, ["message": "Server Error"]) }
        }
        let done: (Data, HTTPURLResponse)
        switch (method, url.path) {
        case ("GET", "/repos/o/r/releases"):
            let half = releases.count / 2
            done = url.query?.contains("page=2") == true ? reply(200, Array(releases[half...]))
                : reply(200, Array(releases[..<half]), link: "<https://api.test/repos/o/r/releases?per_page=100&page=2>; rel=\"next\"")
        case ("GET", "/repos/o/r/tags"):
            done = reply(200, tags.map { ["name": $0] })
        case ("POST", "/repos/o/r/releases"):
            releases.append(["id": 9, "tag_name": body?["tag_name"] ?? "", "draft": true, "prerelease": body?["prerelease"] ?? false])
            done = reply(201, ["id": 9])
        case ("PATCH", let path) where path.hasPrefix("/repos/o/r/releases/assets/"):
            let id = Int(path.split(separator: "/").last!)!
            if let index = assets.firstIndex(where: { $0.id == id }) {
                assets[index].name = body?["name"] as? String ?? assets[index].name
                done = reply(200, ["id": id, "name": assets[index].name])
            } else {
                done = reply(404)
            }
        case ("PATCH", _):
            done = reply(200, ["id": 9])
        case ("GET", let path) where path.hasPrefix("/repos/o/r/releases/assets/"):
            let id = Int(path.split(separator: "/").last!)!
            done = assets.first { $0.id == id }.map { reply(200, ["id": $0.id, "name": $0.name]) } ?? reply(404)
        case ("GET", let path) where path.hasSuffix("/assets"):
            done = reply(200, assets.map { ["id": $0.id, "name": $0.name] })
        case ("DELETE", let path):
            let id = Int(path.split(separator: "/").last!)!
            let had = assets.contains { $0.id == id }
            assets.removeAll { $0.id == id }
            done = reply(had ? 204 : 404)
        case ("POST", let path) where url.host == "uploads.test" && path.hasSuffix("/assets"):
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "name" }!.value!
            nextID += 1
            assets.append((nextID, name))
            done = reply(201, ["id": nextID, "name": name])
        default:
            done = reply(404, ["message": "Not Found"])
        }
        if let failure { return reply(failure.status, ["message": "Server Error"]) }
        return done
    }
}

private func release(_ id: Int, _ tag: String, commit: String = "c", draft: Bool = false, prerelease: Bool = false) -> [String: Any] {
    ["id": id, "tag_name": tag, "target_commitish": commit, "draft": draft, "prerelease": prerelease]
}

private func releasing(_ fake: FakeGitHub) -> Releasing {
    Releasing(github: GitHub(repository: "o/r", token: "token", api: URL(string: "https://api.test")!,
                             uploads: URL(string: "https://uploads.test")!, transport: fake, pause: { _ in }))
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

// An app's Info.plist that carries the version as its build number too (GitHub Drive's): both are stamped, the
// build number's write not undoing the version's.
@Test func anInfoPlistInBothListsGetsBoth() async throws {
    let fake = FakeGitHub(releases: [], tags: [])
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let app = folder.appendingPathComponent("App.plist")
    try plist.write(to: app, atomically: true, encoding: .utf8)
    let version = try await releasing(fake).stampVersion(plists: [app], buildNumberPlists: [app], commit: "z")
    let text = try String(contentsOf: app, encoding: .utf8)
    #expect(InfoPlistText.value(of: "CFBundleShortVersionString", in: text) == version)
    #expect(InfoPlistText.value(of: "CFBundleVersion", in: text) == version)
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
    let made = try #require(none.sent.last { $0.method == "POST" })
    #expect(made.path == "/repos/o/r/releases")
    #expect(made.body?["name"] as? String == "Images 1.2.3" && made.body?["draft"] as? Bool == true && made.body?["prerelease"] as? Bool == true)

    let drafted = FakeGitHub(releases: [release(1, "v1.2.1"), release(7, "v1.2.3", draft: true)])
    _ = try await releasing(drafted).draft(version: "1.2.3", prerelease: false, notes: "n", app: "Images", commit: "z")
    let updated = try #require(drafted.sent.last)
    #expect(updated.method == "PATCH" && updated.path == "/repos/o/r/releases/7" && updated.body?["prerelease"] as? Bool == false)
    #expect(updated.body?["tag_name"] as? String == "v1.2.3")
}

@Test func aDraftThatLandedBeforeIts502IsntMadeTwice() async throws {
    let fake = FakeGitHub(releases: [release(1, "v1.2.1"), release(2, "v1.2.2")])
    fake.failures = [.init(method: "POST", path: "/repos/o/r/releases", status: 502, landed: true)]
    _ = try await releasing(fake).draft(version: "1.2.3", prerelease: true, notes: "n", app: "Images", commit: "z")
    #expect(fake.sent.filter { $0.method == "POST" && $0.path == "/repos/o/r/releases" }.count == 1)
}

@Test func aListIsReadAgainAfterA5xx() async throws {
    let fake = FakeGitHub(releases: [release(1, "v1.2.1"), release(2, "v1.2.2")], tags: ["v1.2.5"])
    fake.failures = [.init(method: "GET", path: "/repos/o/r/tags", status: 503, landed: false)]
    #expect(try await releasing(fake).github.tags() == ["v1.2.5"])
}

@Test func assetsAreAttachedBuildsJSONLast() async throws {
    let fake = FakeGitHub(releases: [release(1, "v1.2.2"), release(5, "v1.2.3", draft: true)])
    fake.assets = [(40, "Images-1.2.3-macos.zip")]
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["builds.json", "Images-1.2.3-macos.zip", "Images-1.2.3-icon.png", "builds.lines"] {
        try Data(name.utf8).write(to: folder.appendingPathComponent(name))
    }
    var said: [String] = []
    try await releasing(fake).attach(tag: "v1.2.3", folder: folder, run: "77") { said.append($0) }
    #expect(said == ["Images-1.2.3-icon.png attached to v1.2.3", "Images-1.2.3-macos.zip attached to v1.2.3", "builds.json attached to v1.2.3"])
    #expect(fake.assetNames == ["Images-1.2.3-icon.png", "Images-1.2.3-macos.zip", "builds.json"])
    // Staged first, the old one deleted only after: the release is never without the zip.
    let order = fake.sent.map { "\($0.method) \($0.path)" }
    let upload = try #require(order.firstIndex { $0 == "POST /repos/o/r/releases/5/assets" })
    let delete = try #require(order.firstIndex { $0 == "DELETE /repos/o/r/releases/assets/40" })
    #expect(upload < delete)
}

@Test func aFailedUploadLeavesTheOldAssetInPlace() async throws {
    let fake = FakeGitHub(releases: [release(1, "v1.2.2"), release(5, "v1.2.3", draft: true)])
    fake.assets = [(40, "Images-1.2.3-macos.zip")]
    // Every attempt fails.
    fake.failures = (1...5).map { _ in .init(method: "POST", path: "/releases/5/assets", status: 502, landed: false) }
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["builds.json", "Images-1.2.3-macos.zip"] { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
    await #expect(throws: ReleaseError.self) { try await releasing(fake).attach(tag: "v1.2.3", folder: folder, run: "77") { _ in } }
    #expect(fake.assetNames == ["Images-1.2.3-macos.zip"])
}

@Test func a502AfterTheDeleteLandedIsDoneNotRepeated() async throws {
    let fake = FakeGitHub(releases: [release(1, "v1.2.2"), release(5, "v1.2.3", draft: true)])
    fake.assets = [(40, "Images-1.2.3-macos.zip")]
    fake.failures = [.init(method: "DELETE", path: "/releases/assets/40", status: 502, landed: true)]
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["builds.json", "Images-1.2.3-macos.zip"] { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
    try await releasing(fake).attach(tag: "v1.2.3", folder: folder, run: "77") { _ in }
    #expect(fake.assetNames == ["Images-1.2.3-macos.zip", "builds.json"])
    #expect(fake.sent.filter { $0.method == "DELETE" && $0.path == "/repos/o/r/releases/assets/40" }.count == 1)
}

@Test func a5xxOnARenameThatLandedIsDone() async throws {
    let fake = FakeGitHub(releases: [release(1, "v1.2.2"), release(5, "v1.2.3", draft: true)])
    fake.failures = [.init(method: "PATCH", path: "/releases/assets/101", status: 500, landed: true)]
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["builds.json", "Images-1.2.3-macos.zip"] { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
    try await releasing(fake).attach(tag: "v1.2.3", folder: folder, run: "77") { _ in }
    #expect(fake.assetNames == ["Images-1.2.3-macos.zip", "builds.json"])
    #expect(fake.sent.filter { $0.method == "PATCH" && $0.path == "/repos/o/r/releases/assets/101" }.count == 1)
}

@Test func aFolderWithoutBuildsJSONIsRefusedUnlessItsTheProof() async throws {
    let fake = FakeGitHub(releases: [release(1, "v1.2.2"), release(5, "v1.2.3", draft: true)])
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("x".utf8).write(to: folder.appendingPathComponent("Images-1.2.3-macos.zip"))
    await #expect(throws: ReleaseError.self) { try await releasing(fake).attach(tag: "v1.2.3", folder: folder, run: "77") { _ in } }
    try FileManager.default.removeItem(at: folder.appendingPathComponent("Images-1.2.3-macos.zip"))
    try Data("x".utf8).write(to: folder.appendingPathComponent("proof.zip"))
    try await releasing(fake).attach(tag: "v1.2.3", folder: folder, run: "77") { _ in }
    #expect(fake.assetNames == ["proof.zip"])
}
