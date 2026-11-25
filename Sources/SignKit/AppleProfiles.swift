import Crypto
import Foundation

/// A provisioning profile, as apple_profiles.py read one (shireworks' Libraries/Signing/AppleSigning: ProfileFolder):
/// its app id, team, platform, kind, the certificates it names (their SHA-1s) and the entitlements it allows.
public struct AppleProfile: @unchecked Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case development, adHoc = "ad-hoc", appStore = "app-store", enterprise, developerID = "developer-id"
    }

    public let path: String
    public let name: String
    /// The id it's for (`*` for a wildcard), without the team's prefix.
    public let bundleID: String
    public let prefix: String
    public let team: String
    public let mac: Bool
    public let kind: Kind
    /// Its certificates' SHA-1s, uppercase hex.
    public let certificates: Set<String>
    public let entitlements: [String: Any]
    public let expires: Date

    /// A profile's property list, out of its CMS envelope: the XML it carries as it is.
    static func plist(_ data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), options: .backwards),
              start.lowerBound < end.upperBound else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil)) as? [String: Any]
    }

    init(path: String, info: [String: Any]) throws {
        let entitlements = info["Entitlements"] as? [String: Any] ?? [:]
        guard let identifier = (entitlements["application-identifier"] ?? entitlements["com.apple.application-identifier"]) as? String,
              let expires = info["ExpirationDate"] as? Date else { throw SignError("not a profile") }
        let prefixes = info["ApplicationIdentifierPrefix"] as? [String] ?? []
        let prefix = prefixes.first ?? String(identifier.prefix { $0 != "." })
        guard identifier.hasPrefix(prefix + ".") else { throw SignError("its identifier isn't its prefix's") }
        self.path = path
        name = info["Name"] as? String ?? (path as NSString).lastPathComponent
        bundleID = String(identifier.dropFirst(prefix.count + 1))
        self.prefix = prefix
        team = (info["TeamIdentifier"] as? [String])?.first ?? prefix
        mac = (info["Platform"] as? [String] ?? ["iOS"]).contains("OSX")
        certificates = Set((info["DeveloperCertificates"] as? [Data] ?? []).map { Self.sha1($0) })
        self.entitlements = entitlements
        self.expires = expires
        let debuggable = isTrue(entitlements["get-task-allow"]) || isTrue(entitlements["com.apple.security.get-task-allow"])
        if isTrue(info["ProvisionsAllDevices"]) {
            kind = mac ? .developerID : .enterprise
        } else if info["ProvisionedDevices"] != nil {
            kind = debuggable ? .development : .adHoc
        } else {
            kind = .appStore
        }
    }

    static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    /// Every profile under `folder`, at any depth (a .tar of a folder of them as much as of them); those that can't
    /// be read said so on standard error and left out.
    public static func all(in folder: String) -> [AppleProfile] {
        guard let walk = FileManager.default.enumerator(atPath: folder) else { return [] }
        var found: [AppleProfile] = []
        for relative in (walk.allObjects as? [String] ?? []).sorted() where relative.hasSuffix(".mobileprovision") || relative.hasSuffix(".provisionprofile") {
            let path = (folder as NSString).appendingPathComponent(relative)
            guard let data = FileManager.default.contents(atPath: path), let info = plist(data) else {
                FileHandle.standardError.write(Data("sign apple: \(relative) isn't a profile it can read\n".utf8))
                continue
            }
            do {
                found.append(try AppleProfile(path: path, info: info))
            } catch {
                FileHandle.standardError.write(Data("sign apple: \(relative) left out: \(error)\n".utf8))
            }
        }
        return found
    }

    /// What there is for `bundle`, and why none of it fits: each profile's kind, end, and whether it names the
    /// certificate (its SHA-1 alone, never anything of the key).
    static func described(_ profiles: [AppleProfile], _ bundle: String, certificate: String, now: Date) -> String {
        let mine = profiles.filter { $0.bundleID == bundle }
        guard !mine.isEmpty else {
            let ids = Set(profiles.map(\.bundleID)).sorted().joined(separator: ", ")
            return "no profile here is for \(bundle) (there are \(profiles.count): \(ids.isEmpty ? "none" : ids))"
        }
        return mine.map { profile in
            let day = ISO8601DateFormatter()
            day.formatOptions = [.withFullDate]
            let end = profile.expires <= now ? "expired" : "until " + day.string(from: profile.expires)
            let names = profile.certificates.contains(certificate) ? "names" : "does not name"
            return "\(profile.name) (\(profile.kind.rawValue), \(end), \(names) the signing certificate \(certificate.prefix(8))…)"
        }.joined(separator: "; ")
    }
}

/// A property list's true: a Bool's, never a number's that bridges to one.
func isTrue(_ value: Any?) -> Bool {
    guard let value else { return false }
    #if canImport(Darwin)
    if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() && number.boolValue }
    #endif
    return (value as? Bool) == true
}

extension AppleProfile {
    /// The team whose profiles for `bundle` are in a keys folder's apple-profiles (and -2…-9) archives: for a build
    /// that stamps the team's prefix into its Info.plist (the shared sign-in's keychain group), with no team id in the
    /// repository. Unpacked into a private folder of its own, removed after; a member outside its folder refused.
    public static func team(keys: String, bundle: String) async throws -> String {
        guard let tar = Tool.find("tar") else { throw SignError("no tar on PATH") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("sign-team-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: work) }
        var unpacked = false
        for name in ["apple-profiles"] + (2...9).map({ "apple-profiles-\($0)" }) {
            let archive = (keys as NSString).appendingPathComponent(name)
            guard (FileManager.default.contents(atPath: archive)?.count ?? 0) > 0 else { continue }
            let listed = try await tar.run(["-tf", archive])
            guard listed.ok else { throw SignError("\(name) isn't a .tar or .tar.gz") }
            if let stray = AppleSigner.strayMember(listed.output) { throw SignError("\(name) has a member outside its folder: \(stray)") }
            guard try await tar.run(["-xf", archive, "-C", work, "--no-same-owner"]).ok else { throw SignError("\(name) isn't a .tar or .tar.gz") }
            unpacked = true
        }
        guard unpacked else { throw SignError("no apple-profiles in \(keys)") }
        let teams = Set(all(in: work).filter { $0.bundleID == bundle }.map(\.team))
        guard let team = teams.first else { throw SignError("no profile here is for \(bundle)") }
        guard teams.count == 1 else { throw SignError("\(bundle)'s profiles are of more than one team") }
        return team
    }
}
