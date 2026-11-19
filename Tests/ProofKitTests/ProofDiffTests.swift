import Foundation
import Testing
@testable import ProofKit

// proof-diff's comparison (ProofDiff, PNG, ZipReader), as shireworks' proof_diff.py made it: pictures compared by
// their pixels, items by their kinds, the release before chosen as Reviews chooses it. No GitHub: those calls are CI's.

private func picture(_ width: Int, _ height: Int, _ pixel: (Int, Int) -> [UInt8] = { _, _ in [10, 20, 30, 255] }) throws -> Data {
    try PNG.encode(width: width, rows: (0..<height).map { y in (0..<width).flatMap { x in pixel(x, y) } })
}

@Test func aPNGIsDecodedToItsPixels() throws {
    let png = try PNG(try picture(3, 2) { x, y in [UInt8(x), UInt8(y), 7, 255] })
    #expect(png.width == 3 && png.height == 2)
    #expect(png.rows[1] == [0, 1, 7, 255, 1, 1, 7, 255, 2, 1, 7, 255])
    #expect(throws: PNG.Unreadable.self) { try PNG(Data("not a png".utf8)) }
}

@Test func picturesDifferOnlyBeyondTheTolerance() throws {
    let base = try picture(4, 4)
    #expect(try ProofDiff.compare(base, base).pixels == 0)
    let slight = try picture(4, 4) { x, y in x == 1 && y == 1 ? [10 + 24, 20, 30, 255] : [10, 20, 30, 255] }
    #expect(try ProofDiff.compare(slight, base).pixels == 0, "24 is within the tolerance")
    let moved = try picture(4, 4) { x, y in (x, y) == (1, 2) || (x, y) == (3, 3) ? [200, 20, 30, 255] : [10, 20, 30, 255] }
    let compared = try ProofDiff.compare(moved, base)
    #expect(compared.pixels == 2)
    #expect(compared.bounds == ["x": 1, "y": 2, "width": 3, "height": 2])
    let bigger = try ProofDiff.compare(try picture(5, 4), base)
    #expect(bigger.pixels == 20 && bigger.bounds == ["x": 0, "y": 0, "width": 5, "height": 4])
}

/// A zip of `files`, each stored or deflated, as Python's zipfile writes one.
private func zip(_ files: [(String, Data)], deflated: Bool) throws -> Data {
    func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    func u32(_ v: Int) -> [UInt8] { u16(v & 0xFFFF) + u16(v >> 16 & 0xFFFF) }
    var out: [UInt8] = [], directory: [UInt8] = []
    for (name, data) in files {
        let body = deflated ? [UInt8](try Inflate.deflate(data, raw: true)) : [UInt8](data)
        let offset = out.count, method = deflated ? 8 : 0, nameBytes = Array(name.utf8)
        out += u32(0x0403_4B50) + u16(20) + u16(0) + u16(method) + u16(0) + u16(0) + u32(0) + u32(body.count) + u32(data.count)
            + u16(nameBytes.count) + u16(0) + nameBytes + body
        directory += u32(0x0201_4B50) + u16(20) + u16(20) + u16(0) + u16(method) + u16(0) + u16(0) + u32(0) + u32(body.count)
            + u32(data.count) + u16(nameBytes.count) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(offset) + nameBytes
    }
    let start = out.count
    out += directory
    out += u32(0x0605_4B50) + u16(0) + u16(0) + u16(files.count) + u16(files.count) + u32(directory.count) + u32(start) + u16(0)
    return Data(out)
}

private func proofJSON(_ items: [[String: Any]], version: String = "0.2.0") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["format": 2, "repository": "o/app", "version": version, "commit": "abc", "items": items])
}

@Test func aZipsEntriesAreReadStoredOrDeflated() throws {
    for deflated in [false, true] {
        let reader = try ZipReader(try zip([("proof.json", Data("{}".utf8)), ("a/b.png", Data(repeating: 7, count: 5000))], deflated: deflated))
        #expect(try reader.read("proof.json") == Data("{}".utf8))
        #expect(try reader.read("a/b.png") == Data(repeating: 7, count: 5000))
        #expect(try reader.read("missing") == nil)
    }
    #expect(throws: ZipReader.Failed.self) { try ZipReader(Data("no zip".utf8)) }
}

@Test func theManifestComparesEachItemByItsKind() throws {
    let same = try picture(2, 2), changed = try picture(2, 2) { x, _ in x == 0 ? [255, 0, 0, 255] : [10, 20, 30, 255] }
    let base = try ProofDiff.Proof(data: try zip([
        ("proof.json", try proofJSON([
            ["id": "home", "kind": "screen", "file": "home.png", "sha256": "h1"],
            ["id": "settings", "kind": "screen", "file": "settings.png", "sha256": "s1"],
            ["id": "tests", "kind": "tests", "result": "passed", "tests": 10, "failures": 0],
            ["id": "gone", "kind": "screen", "file": "gone.png"],
        ], version: "0.1.0")),
        ("home.png", same), ("settings.png", same), ("gone.png", same),
    ], deflated: true))
    let now = try ProofDiff.Proof(data: try zip([
        ("proof.json", try proofJSON([
            ["id": "home", "kind": "screen", "file": "home.png", "sha256": "h2"],
            ["id": "settings", "kind": "screen", "file": "settings.png", "sha256": "s2"],
            ["id": "tests", "kind": "tests", "result": "passed", "tests": 10, "failures": 0],
            ["id": "new", "kind": "screen", "file": "new.png"],
        ])),
        ("home.png", same), ("settings.png", changed), ("new.png", same),
    ], deflated: false))
    let document = ProofDiff.manifest(now, base: ["tag": "v0.1.0"], baseProof: base, note: nil)
    #expect(document["counts"] as? [String: Int] == ["added": 1, "removed": 1, "changed": 1, "unchanged": 2])
    let items = try #require(document["items"] as? [[String: Any]])
    #expect(items.map { $0["id"] as? String } == ["home", "settings", "tests", "new", "gone"])
    #expect(items[0]["status"] as? String == "unchanged" && items[0]["changedPixels"] as? Int == 0, "the same pixels, another hash")
    #expect(items[1]["status"] as? String == "changed" && items[1]["changedPixels"] as? Int == 2)
    #expect((items[1]["base"] as? [String: Any])?["sha256"] as? String == "s1")
    #expect(items[2]["status"] as? String == "unchanged" && items[3]["status"] as? String == "added" && items[4]["status"] as? String == "removed")
    #expect((document["proof"] as? [String: Any])?["version"] as? String == "0.2.0")
    let written = try JSONSerialization.jsonObject(with: try ProofDiff.encoded(document)) as? [String: Any]
    #expect(written?["format"] as? Int == 1 && written?["tolerance"] as? Int == 24)
    // No base: everything added, the note said.
    let alone = ProofDiff.manifest(now, base: nil, baseProof: nil, note: "no release before this one")
    #expect(alone["counts"] as? [String: Int] == ["added": 4, "removed": 0, "changed": 0, "unchanged": 0])
    #expect(alone["note"] as? String == "no release before this one" && alone["base"] is NSNull)
}

@Test func theReleaseBeforeIsThePublishedOneBelowPublishedLast() {
    #expect(ProofDiff.version("v0.13.1", prefix: "v") == [0, 13, 1])
    #expect(ProofDiff.version("v1", prefix: "v") == [1, 0, 0])
    #expect(ProofDiff.version("shireworks-v0.2", prefix: "v") == nil)
    #expect(ProofDiff.version("vnext", prefix: "v") == nil)
    let listed: [[String: Any]] = [
        ["tag_name": "v0.12.2", "published_at": "2026-11-18T17:00:00Z", "id": 1],
        ["tag_name": "v0.13.1", "published_at": "2026-11-18T22:00:00Z", "id": 2],
        ["tag_name": "v0.14.0", "draft": true, "id": 3],
        ["tag_name": "v0.13.5", "prerelease": true, "published_at": "2026-11-19T00:00:00Z", "id": 4],
        ["tag_name": "v0.11.1", "published_at": "2026-11-19T01:00:00Z", "id": 5],
    ]
    #expect(ProofDiff.baseRelease(listed, below: [0, 14, 0], prefix: "v")?["id"] as? Int == 5, "published last, below")
    #expect(ProofDiff.baseRelease(listed, below: [0, 12, 0], prefix: "v")?["id"] as? Int == 5)
    #expect(ProofDiff.baseRelease(listed, below: [0, 11, 0], prefix: "v") == nil)
    #expect(ProofDiff.baseRelease(listed, below: nil, prefix: "v", tag: "v0.12.2")?["id"] as? Int == 1)
    #expect(ProofDiff.baseRelease(listed, below: nil, prefix: "v", tag: "v0.14.0") == nil, "a draft isn't a base")
}

@Test func inflatingStopsPastWhatWasSaid() throws {
    let big = try Inflate.deflate(Data(repeating: 0, count: 100_000), raw: true)
    #expect(try Inflate.inflate(big, raw: true, expected: 100_000).count == 100_000)
    #expect(throws: Inflate.Failed.self) { try Inflate.inflate(big, raw: true, expected: 1_000) }
}
