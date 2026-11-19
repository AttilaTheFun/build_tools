import Crypto
import Foundation

/// A build's line in builds.json (shireworks' docs/RELEASE_ASSETS.md), as release_assets.sh wrote it: what
/// Applications lists. Read from the build itself: its Info.plist, its executable's LC_UUID and, for a Mac app, its
/// icon.
public struct BuildDescription: Sendable {
    public var file: String
    public var bundleID: String
    public var app: String
    public var platform: String
    public var version: String
    public var buildNumber: String
    public var variant: String
    public var commit: String
    public var executableUUID: String
    public var size: Int
    public var sha256: String
    /// A Mac app's icon's file, beside it (`<App>-<version>-icon.png`).
    public var icon: String?
    public var urlSchemes: [String]
    /// False for a build copied unsigned (`--unsigned`, an experiment's): its line says `"signed": false`, and
    /// Applications lists such a line only in an experiment's release, never as an app's Alpha (NCH, #8's review).
    public var signed: Bool = true

    /// Its line, as builds.json holds it: `urlSchemes` only where it has some (an Android app's always), `icon`
    /// only where there is one.
    public var object: [String: Any] {
        var line: [String: Any] = ["file": file, "bundleID": bundleID, "app": app, "platform": platform, "version": version,
                                   "buildNumber": buildNumber, "variant": variant, "commit": commit, "executableUUID": executableUUID,
                                   "size": size, "sha256": sha256]
        if let icon { line["icon"] = icon }
        if !signed { line["signed"] = false }
        if !urlSchemes.isEmpty || platform == "android" { line["urlSchemes"] = urlSchemes }
        return line
    }

    /// An asset's name: `<App>-<version>-<platform>.<ext>`, the app's spaces and slashes made `-`.
    public static func assetName(app: String, version: String, platform: String, ext: String) -> String {
        "\(app.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-"))-\(version)-\(platform).\(ext)"
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The commit a build is of: `--commit`, else the job's (GITHUB_SHA).
    static func commit(_ given: String?) -> String {
        given ?? ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? ""
    }

    /// An Apple app's line, its package at `path` and its bundle unpacked at `app`; a Mac app's icon written beside
    /// the package. `name`: the app's name across platforms (else its display name, its name, its id).
    static func apple(package path: String, app bundle: String, platform: String, name: String?, commit: String?) throws -> BuildDescription {
        guard let data = FileManager.default.contents(atPath: path) else { throw SignError("\(path) wasn't written") }
        let info = AppleBundle.info(bundle) ?? [:]
        guard let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw SignError("\((bundle as NSString).lastPathComponent) names no CFBundleIdentifier")
        }
        let app = name ?? (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        var description = BuildDescription(file: (path as NSString).lastPathComponent, bundleID: bundleID, app: app, platform: platform,
                                           version: version, buildNumber: info["CFBundleVersion"] as? String ?? "",
                                           variant: (info["BuildVariant"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Alpha",
                                           commit: Self.commit(commit), executableUUID: AppleBundle.executable(bundle).flatMap(executableUUID) ?? "",
                                           size: data.count, sha256: sha256(data), icon: nil, urlSchemes: schemes)
        if platform == "macos", let png = icon(of: bundle, info: info) {
            let iconName = assetName(app: app, version: version, platform: "icon", ext: "png")
            let iconPath = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(iconName)
            if (try? png.write(to: URL(fileURLWithPath: iconPath))) != nil { description.icon = iconName }
        }
        return description
    }

    /// The UUID of an executable (its LC_UUID: the arm64 slice of a fat one, else the first), upper case; nil where
    /// it has none.
    static func executableUUID(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return executableUUID(data: [UInt8](data))
    }

    static func executableUUID(data: [UInt8]) -> String? {
        func big32(_ at: Int) -> Int { at + 4 <= data.count ? Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3]) : -1 }
        func little32(_ at: Int) -> Int { at + 4 <= data.count ? Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 : -1 }
        func big64(_ at: Int) -> Int { big32(at) << 32 | big32(at + 4) }
        func thin(_ start: Int) -> String? {
            let header: Int
            switch little32(start) {
            case 0xFEEDFACF: header = 32
            case 0xFEEDFACE: header = 28
            default: return nil
            }
            var cursor = start + header
            for _ in 0..<max(0, little32(start + 16)) {
                guard cursor + 8 <= data.count else { return nil }
                let command = little32(cursor), size = little32(cursor + 4)
                if command == 0x1B {
                    guard cursor + 24 <= data.count else { return nil }
                    let bytes = data[(cursor + 8)..<(cursor + 24)].map { String(format: "%02X", $0) }
                    return [bytes[0..<4], bytes[4..<6], bytes[6..<8], bytes[8..<10], bytes[10..<16]].map { $0.joined() }.joined(separator: "-")
                }
                guard size > 0 else { return nil }
                cursor += size
            }
            return nil
        }
        let magic = big32(0)
        guard magic == 0xCAFEBABE || magic == 0xCAFEBABF else { return thin(0) }
        let wide = magic == 0xCAFEBABF, entry = wide ? 32 : 20
        var first: Int?
        for index in 0..<max(0, big32(4)) {
            let base = 8 + index * entry
            guard base + entry <= data.count else { break }
            let offset = wide ? big64(base + 8) : big32(base + 8)
            if big32(base) == 0x0100_000C { return thin(offset) }
            if first == nil { first = offset }
        }
        return first.flatMap(thin)
    }

    /// A Mac app's icon: the largest PNG rendition in the .icns its Info.plist names (CFBundleIconFile), else the
    /// first .icns in its Resources; nil where there's none to read.
    static func icon(of bundle: String, info: [String: Any]) -> Data? {
        let resources = (bundle as NSString).appendingPathComponent("Contents/Resources")
        var path: String?
        if let named = info["CFBundleIconFile"] as? String, !named.isEmpty {
            let candidate = (resources as NSString).appendingPathComponent(named.hasSuffix(".icns") ? named : named + ".icns")
            if FileManager.default.fileExists(atPath: candidate) { path = candidate }
        }
        if path == nil, let first = ((try? FileManager.default.contentsOfDirectory(atPath: resources)) ?? []).sorted().first(where: { $0.hasSuffix(".icns") }) {
            path = (resources as NSString).appendingPathComponent(first)
        }
        guard let path, let data = FileManager.default.contents(atPath: path) else { return nil }
        return largestPNG(inICNS: [UInt8](data))
    }

    static func largestPNG(inICNS data: [UInt8]) -> Data? {
        func big32(_ at: Int) -> Int { Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3]) }
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var best: ArraySlice<UInt8>?, width = 0, at = 8
        while at + 8 <= data.count {
            let size = big32(at + 4)
            guard size >= 8, at + size <= data.count else { break }
            let body = data[(at + 8)..<(at + size)]
            if body.count >= 24, Array(body.prefix(8)) == png, Array(body.dropFirst(12).prefix(4)) == Array("IHDR".utf8) {
                let found = big32(body.startIndex + 16)
                if found > width { (best, width) = (body, found) }
            }
            at += size
        }
        return best.map { Data($0) }
    }
}

/// builds.json: its lines gathered as one array, an earlier line for the same file replaced (a step run again).
public enum BuildsFile {
    public static func merge(_ lines: [[String: Any]], into path: String) throws {
        var all: [[String: Any]] = []
        if let data = FileManager.default.contents(atPath: path), !data.isEmpty {
            guard let read = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw SignError("\(path) isn't a JSON array") }
            all = read
        }
        let files = Set(lines.compactMap { $0["file"] as? String })
        all.removeAll { files.contains($0["file"] as? String ?? "") }
        all += lines
        try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }
}
