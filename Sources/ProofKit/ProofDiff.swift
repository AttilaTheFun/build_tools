import Crypto
import Foundation

/// A proof's comparison with the release before's, made once: proof-diff.json (docs/PROOF_FORMAT.md in shireworks,
/// "The comparison: proof-diff.json"). Ported from shireworks' tools/ci/proof_diff.py, the same manifest field for
/// field: its pictures PNGs decoded here, so no Mac is needed.
public enum ProofDiff {
    public static let format = 1
    /// A channel's difference that counts (RGBA, as Reviews and the snapshot tests count them).
    public static let tolerance = 24

    public struct Failed: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// proof.json and its files, from verify's folder or a proof.zip.
    public final class Proof: @unchecked Sendable {
        let zip: ZipReader?
        let root: String?
        public let document: [String: Any]

        public init(path: String) throws {
            if path.hasSuffix(".zip") {
                guard let data = FileManager.default.contents(atPath: path) else { throw Failed("no such file: \(path)") }
                zip = try ZipReader(data)
                root = nil
            } else {
                zip = nil
                root = path
            }
            document = try Self.json(Self.read("proof.json", zip: zip, root: root))
        }

        public init(data: Data) throws {
            zip = try ZipReader(data)
            root = nil
            document = try Self.json(Self.read("proof.json", zip: zip, root: nil))
        }

        static func json(_ data: Data?) throws -> [String: Any] {
            guard let data, let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failed("no proof.json, or it isn't a JSON object")
            }
            return document
        }

        static func read(_ name: String, zip: ZipReader?, root: String?) throws -> Data? {
            if let zip { return try zip.read(name) }
            guard let root else { return nil }
            return FileManager.default.contents(atPath: (root as NSString).appendingPathComponent(name))
        }

        public var isFolder: Bool { root != nil }

        /// An item's file's bytes; nil where it names none, or it can't be read.
        func file(_ item: [String: Any]) -> Data? {
            guard let name = item["file"] as? String, !name.isEmpty else { return nil }
            return try? Self.read(name, zip: zip, root: root)
        }

        /// Its items: a proof of format 2's, else none.
        var items: [[String: Any]] {
            guard (document["format"] as? Int) == 2 else { return [] }
            return document["items"] as? [[String: Any]] ?? []
        }
    }

    /// How many pixels differ by more than `tolerance` in a channel, and the smallest rectangle around them; pictures
    /// of different sizes differ everywhere.
    static func compare(_ now: Data, _ then: Data) throws -> (pixels: Int, bounds: [String: Int]?) {
        let a = try PNG(now), b = try PNG(then)
        guard a.width == b.width, a.height == b.height else {
            return (max(a.width * a.height, b.width * b.height), ["x": 0, "y": 0, "width": max(a.width, b.width), "height": max(a.height, b.height)])
        }
        var changed = 0, left = a.width, top = a.height, right = -1, bottom = -1
        for y in 0..<a.height {
            let row = a.rows[y], thenRow = b.rows[y]
            if row == thenRow { continue }
            for x in 0..<a.width {
                let i = 4 * x
                if row[i] == thenRow[i] && row[i + 1] == thenRow[i + 1] && row[i + 2] == thenRow[i + 2] && row[i + 3] == thenRow[i + 3] { continue }
                if (0..<4).contains(where: { abs(Int(row[i + $0]) - Int(thenRow[i + $0])) > tolerance }) {
                    changed += 1
                    left = min(left, x); top = min(top, y); right = max(right, x); bottom = max(bottom, y)
                }
            }
        }
        guard changed > 0 else { return (0, nil) }
        return (changed, ["x": left, "y": top, "width": right - left + 1, "height": bottom - top + 1])
    }

    static func picked(_ item: [String: Any], _ keys: [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in keys { if let value = item[key] { out[key] = value } }
        return out
    }

    /// What an item's row shows, as the manifest repeats it.
    static func shown(_ item: [String: Any]) -> [String: Any] {
        picked(item, ["id", "kind", "title", "sha256", "width", "height", "result", "tests", "failures"])
    }

    static func side(_ item: [String: Any]) -> [String: Any] {
        picked(item, ["sha256", "width", "height", "result", "tests", "failures"])
    }

    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b as AnyObject)
        default: return false
        }
    }

    /// Every item with its status, this proof's in its order, then the removed ones in the base's.
    static func compared(_ proof: Proof, _ base: Proof?) -> [[String: Any]] {
        var before: [String: [String: Any]] = [:]
        for item in base?.items ?? [] {
            if let id = item["id"] as? String, before[id] == nil { before[id] = item }
        }
        let ids = Set(proof.items.compactMap { $0["id"] as? String })
        var out: [[String: Any]] = []
        for item in proof.items {
            var entry = shown(item)
            if let base, let id = item["id"] as? String, let then = before[id] {
                entry["base"] = side(then)
                let (status, extra) = status(proof, item, base, then)
                entry["status"] = status
                entry.merge(extra) { $1 }
            } else {
                entry["status"] = "added"
            }
            out.append(entry)
        }
        for item in base?.items ?? [] where !ids.contains(item["id"] as? String ?? "") {
            var entry = shown(item)
            entry["status"] = "removed"
            out.append(entry)
        }
        return out
    }

    static func status(_ proof: Proof, _ item: [String: Any], _ base: Proof, _ before: [String: Any]) -> (String, [String: Any]) {
        guard same(item["kind"], before["kind"]) else { return ("changed", [:]) }
        switch item["kind"] as? String {
        case "screen":
            if let sha = item["sha256"] as? String, !sha.isEmpty, sha == before["sha256"] as? String { return ("unchanged", [:]) }
            guard let now = proof.file(item), let then = base.file(before) else {
                return ("changed", ["note": "a picture is missing from a proof"])
            }
            do {
                let (pixels, bounds) = try compare(now, then)
                var extra: [String: Any] = ["changedPixels": pixels]
                if let bounds { extra["bounds"] = bounds }
                return (pixels == 0 ? "unchanged" : "changed", extra)
            } catch {
                return ("changed", ["note": "not compared: \(error)"])
            }
        case "tests":
            let unchanged = ["result", "tests", "failures"].allSatisfy { same(item[$0], before[$0]) }
            return (unchanged ? "unchanged" : "changed", [:])
        default:
            return (same(item, before) ? "unchanged" : "changed", [:])
        }
    }

    /// The manifest, proof-diff.json's object.
    public static func manifest(_ proof: Proof, base: [String: Any]?, baseProof: Proof?, note: String?, now: Date = Date()) -> [String: Any] {
        let items = compared(proof, baseProof)
        var counts = ["added": 0, "removed": 0, "changed": 0, "unchanged": 0]
        for entry in items { if let status = entry["status"] as? String { counts[status, default: 0] += 1 } }
        let made = ISO8601DateFormatter()
        made.formatOptions = [.withInternetDateTime]
        var out: [String: Any] = [
            "format": format, "made": made.string(from: now), "tolerance": tolerance,
            "proof": picked(proof.document, ["repository", "app", "version", "commit", "run"]),
            "base": base ?? NSNull(), "counts": counts, "items": items,
        ]
        if let note { out["note"] = note }
        return out
    }

    /// A tag's version's numbers after `prefix` (three at least), nil where it isn't one of `prefix`'s.
    public static func version(_ tag: String, prefix: String) -> [Int]? {
        guard tag.hasPrefix(prefix) else { return nil }
        let rest = tag.dropFirst(prefix.count)
        guard rest.first?.isNumber == true else { return nil }
        let numbers = rest.split { !$0.isNumber }.compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        return numbers + Array(repeating: 0, count: max(0, 3 - numbers.count))
    }

    /// The release before (as Reviews takes it): of the published, not pre-release releases whose tag's version is
    /// below `below`, the one published last; or the one named `tag`.
    static func baseRelease(_ listed: [[String: Any]], below: [Int]?, prefix: String, tag: String? = nil) -> [String: Any]? {
        var candidates: [(String, [String: Any])] = []
        for release in listed {
            if release["draft"] as? Bool == true || release["prerelease"] as? Bool == true { continue }
            if let tag {
                if release["tag_name"] as? String == tag { return release }
                continue
            }
            guard let numbers = version(release["tag_name"] as? String ?? "", prefix: prefix) else { continue }
            if below == nil || numbers.lexicographicallyPrecedes(below!) {
                candidates.append((release["published_at"] as? String ?? "", release))
            }
        }
        return candidates.max { $0.0 < $1.0 }?.1
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The base's description and its proof, or a note why there's none.
    static func base(for proof: Proof, in repository: String, prefix: String, tag: String? = nil, listed known: [[String: Any]]? = nil,
                     github: GitHub) async -> (base: [String: Any]?, proof: Proof?, note: String?) {
        var listed: [[String: Any]] = known ?? []
        if known == nil {
            do {
                listed = try await github.releases(repository)
            } catch {
                return (nil, nil, "the releases weren't listed: \(error)")
            }
        }
        var below: [Int]?
        if let documented = proof.document["version"], !"\(documented)".isEmpty { below = version(prefix + "\(documented)", prefix: prefix) }
        guard let release = baseRelease(listed, below: below, prefix: prefix, tag: tag), let releaseTag = release["tag_name"] as? String else {
            return (nil, nil, "no release before this one")
        }
        guard let asset = (release["assets"] as? [[String: Any]] ?? []).first(where: { $0["name"] as? String == "proof.zip" }),
              let assetID = asset["id"] as? Int else {
            return (nil, nil, "\(releaseTag) has no proof.zip")
        }
        let data: Data, baseProof: Proof
        do {
            data = try await github.assetData(repository, asset: assetID)
            baseProof = try Proof(data: data)
        } catch {
            return (nil, nil, "\(releaseTag)'s proof.zip wasn't read: \(error)")
        }
        guard (baseProof.document["format"] as? Int) == 2 else { return (nil, nil, "\(releaseTag)'s proof is not of format 2") }
        var commit: Any = baseProof.document["commit"] ?? NSNull()
        if (commit as? String ?? "").isEmpty { commit = await github.commit(repository, tag: releaseTag) ?? NSNull() }
        let base: [String: Any] = ["tag": releaseTag, "release": release["id"] ?? NSNull(), "commit": commit, "asset": assetID,
                                   "sha256": sha256(data)]
        return (base, baseProof, nil)
    }

    /// JSON as proof-diff.json is written: indented, its keys sorted.
    public static func encoded(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }
}
