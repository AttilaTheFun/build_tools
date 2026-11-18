import Crypto
import Foundation

/// Apple apps signed with no Mac (Logan, 2026-11-15: hermetic signing), by the repository's own pinned rcodesign (and
/// rules_applecross' `dmg` for a disk image). Ported from shireworks' tools/ci/apple_sign.sh and apple_profiles.py.
///
/// - A Mac app's .zip (one .app at its top): signed with Developer ID (hardened runtime, a timestamp), its Developer
///   ID profile embedded and its entitlements made the profile's when there's one for it, notarized and stapled,
///   zipped again; with a disk image beside it (the app and an Applications link, its volume named after the app),
///   signed, notarized and stapled too.
/// - An iPhone app's .ipa: its extensions, then the app, each with its own profile of the one kind asked for and its
///   entitlements made the profile's, and every other piece of code with the same identity, deepest first. Not
///   notarized (iOS isn't).
///
/// The keys go into a folder of their own on a tmpfs, are used, and are removed however it ends; none is ever printed
/// or put on a command line.
public struct AppleSigner: Sendable {
    /// Where the keys come from.
    public enum Keys: Sendable {
        /// A public repository's job on GitHub's runners: its GitHub environment's secrets (`environmentNames`), each
        /// read once and unset.
        case environment
        /// A folder already holding the secrets by their names (Shireworks' secret service's `secrets-fetch`, on a
        /// tmpfs), the caller's to remove. A password-less .p12 keeps no password file.
        case folder(String)
    }

    /// The kind of profile an iPhone app is signed with, and so its identity: development's certificate for a
    /// development profile, distribution's for the others.
    public enum IPAKind: String, Sendable, CaseIterable {
        case development, adHoc = "ad-hoc", appStore = "app-store", enterprise

        var profile: AppleProfile.Kind {
            switch self {
            case .development: .development
            case .adHoc: .adHoc
            case .appStore: .appStore
            case .enterprise: .enterprise
            }
        }

        var identity: String { self == .development ? "apple-development" : "apple-distribution" }
    }

    /// Each secret's name and the environment variable it comes from with `--key-from-env` (base64 for a .p12 and the
    /// profiles' .tar). APPLE_PROFILES_2 … _9 hold more profiles where one secret can't (GitHub's are 48 KB at most).
    public static let environmentNames: [(secret: String, variable: String, base64: Bool)] = [
        ("apple-developer-id-p12", "APPLE_DEVELOPER_ID_P12", true),
        ("apple-developer-id-password", "APPLE_DEVELOPER_ID_PASSWORD", false),
        ("apple-notary-key", "APPLE_NOTARY_KEY", false),
        ("apple-notary-key-id", "APPLE_NOTARY_KEY_ID", false),
        ("apple-notary-issuer", "APPLE_NOTARY_ISSUER", false),
        ("apple-development-p12", "APPLE_DEVELOPMENT_P12", true),
        ("apple-development-password", "APPLE_DEVELOPMENT_PASSWORD", false),
        ("apple-distribution-p12", "APPLE_DISTRIBUTION_P12", true),
        ("apple-distribution-password", "APPLE_DISTRIBUTION_PASSWORD", false),
        ("apple-profiles", "APPLE_PROFILES", true),
    ] + (2...9).map { ("apple-profiles-\($0)", "APPLE_PROFILES_\($0)", true) }

    public let rcodesign: Tool
    public let dmg: Tool?
    public let ipaKind: IPAKind
    /// Each app's BuildVariant (its Info.plist's) set before it's signed, and a Mac app's stapled ticket taken out:
    /// how a published release makes its tested Alphas Production.
    public let variant: String?
    /// The app's name across platforms: outputs named `<App>-<version>-<platform>.<ext>` (shireworks'
    /// RELEASE_ASSETS.md), else each package's own name.
    public let app: String?

    public init(rcodesign: String, dmg: String?, ipaKind: IPAKind, variant: String?, app: String?) throws {
        guard FileManager.default.isExecutableFile(atPath: rcodesign) else { throw SignError("no rcodesign at \(rcodesign)") }
        if let dmg { guard FileManager.default.isExecutableFile(atPath: dmg) else { throw SignError("no dmg at \(dmg)") } }
        if let variant { guard Self.validVariant(variant) else { throw SignError("--variant is a word (Production, Alpha…)") } }
        if let app { guard !app.isEmpty, !app.contains("/") else { throw SignError("--app is the app's name") } }
        self.rcodesign = Tool(rcodesign)
        self.dmg = dmg.map(Tool.init)
        self.ipaKind = ipaKind
        self.variant = variant
        self.app = app
    }

    static func validVariant(_ variant: String) -> Bool {
        guard let first = variant.first, first.isASCII, first.isLetter, variant.count <= 32 else { return false }
        return variant.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// What was made: each output's path and its builds.json line's values.
    public struct Signed: Sendable {
        public var path: String
        public var line: [String: String]
        public var size: Int
    }

    /// Every variable `environmentNames` lists, read and unset at once (before anything runs, so no process this starts
    /// inherits one), written to `folder` by its secret's name. A password-less .p12's empty password is no file.
    public static func takeEnvironment(into folder: SecretsFolder) throws {
        var taken: [(String, String, Bool)] = []
        for name in environmentNames {
            if let value = SecretEnvironment.take(name.variable) { taken.append((name.secret, value, name.base64)) }
        }
        for (secret, value, base64) in taken {
            if base64 {
                guard let data = Data(base64Encoded: value, options: .ignoreUnknownCharacters) else {
                    throw SignError("\(environmentNames.first { $0.secret == secret }!.variable) isn't base64")
                }
                try folder.write(secret, data)
            } else {
                try folder.write(secret, Data(value.utf8))
            }
        }
    }

    /// Signs each package into `out`.
    public func sign(_ packages: [String], out: String, keys: Keys) async throws -> [Signed] {
        let packages = packages.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for package in packages {
            guard FileManager.default.fileExists(atPath: package) else { throw SignError("no such file: \(package)") }
            guard package.hasSuffix(".zip") || package.hasSuffix(".ipa") else {
                throw SignError("\((package as NSString).lastPathComponent) is neither a Mac app's .zip nor an .ipa")
            }
        }
        let mac = packages.contains { $0.hasSuffix(".zip") }
        let ios = packages.contains { $0.hasSuffix(".ipa") }
        if dmg != nil, !mac { throw SignError("--dmg is for a Mac app's .zip") }
        guard let unzip = Tool.find("unzip"), let zip = Tool.find("zip"), let tar = Tool.find("tar"), let openssl = Tool.find("openssl") else {
            throw SignError("unzip, zip, tar and openssl are needed on PATH")
        }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let out = URL(fileURLWithPath: out).standardizedFileURL.path

        // The keys, in a tmpfs folder of this run's own, whichever way they came.
        let secrets = try SecretsFolder(prefix: "apple-sign")
        defer { secrets.remove() }
        switch keys {
        case .environment: try Self.takeEnvironment(into: secrets)
        case .folder(let folder):
            for name in Self.environmentNames {
                if let data = FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent(name.secret)) {
                    try secrets.write(name.secret, data)
                }
            }
        }
        func file(_ name: String) -> String { (secrets.path as NSString).appendingPathComponent(name) }
        func has(_ name: String) -> Bool { (FileManager.default.contents(atPath: file(name))?.count ?? 0) > 0 }
        var needed = ["apple-profiles"]
        if mac { needed += ["apple-developer-id-p12", "apple-notary-key", "apple-notary-key-id", "apple-notary-issuer"] }
        if ios { needed.append("\(ipaKind.identity)-p12") }
        for name in needed where !has(name) { throw SignError("no \(name)") }

        let profilesFolder = file("profiles")
        try FileManager.default.createDirectory(atPath: profilesFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in ["apple-profiles"] + (2...9).map({ "apple-profiles-\($0)" }) where has(name) {
            let unpacked = try await tar.run(["-xf", file(name), "-C", profilesFolder, "--no-same-owner"])
            guard unpacked.ok else { throw SignError("\(name) isn't a .tar or .tar.gz") }
        }
        let profiles = AppleProfile.all(in: profilesFolder)

        var developerID = ""
        if mac {
            try secrets.write("notary.json", try Self.notaryKey(key: String(decoding: FileManager.default.contents(atPath: file("apple-notary-key"))!, as: UTF8.self),
                                                                keyID: String(decoding: FileManager.default.contents(atPath: file("apple-notary-key-id"))!, as: UTF8.self),
                                                                issuer: String(decoding: FileManager.default.contents(atPath: file("apple-notary-issuer"))!, as: UTF8.self)))
            developerID = try await certificate(openssl, p12: file("apple-developer-id-p12"), password: file("apple-developer-id-password"))
        }
        var iPhoneIdentity = ""
        if ios {
            iPhoneIdentity = try await certificate(openssl, p12: file("\(ipaKind.identity)-p12"), password: file("\(ipaKind.identity)-password"))
        }

        let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("apple-sign-work-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: work) }

        var signed: [Signed] = []
        for package in packages {
            let base = ((package as NSString).lastPathComponent as NSString).deletingPathExtension
            let folder = (work as NSString).appendingPathComponent("unpacked-\(base)")
            try await unpack(package, into: folder, unzip: unzip)
            if package.hasSuffix(".ipa") {
                let payload = (folder as NSString).appendingPathComponent("Payload")
                let apps = ((try? FileManager.default.contentsOfDirectory(atPath: payload)) ?? []).filter { $0.hasSuffix(".app") }
                guard apps.count == 1 else { throw SignError("\(base).ipa holds \(apps.count) apps in its Payload, not one") }
                let appPath = (payload as NSString).appendingPathComponent(apps[0])
                print("== \(base).ipa: signed (\(ipaKind.rawValue))")
                try stamp(appPath, info: (appPath as NSString).appendingPathComponent("Info.plist"))
                try await signBundle(appPath, platform: .ios, p12: file("\(ipaKind.identity)-p12"), password: file("\(ipaKind.identity)-password"),
                                     certificate: iPhoneIdentity, profiles: profiles, work: work)
                let info = AppleBundle.info(appPath) ?? [:]
                let target = (out as NSString).appendingPathComponent(outputName(base: base, info: info, platform: "ios", ext: "ipa"))
                try? FileManager.default.removeItem(atPath: target)
                let zipped = try await zip.run(["-qry", "-X", target, "."], in: folder)
                guard zipped.ok else { throw SignError("\(base).ipa couldn't be zipped again: \(zipped.error)") }
                signed.append(try described(target, info: info, platform: "ios"))
            } else {
                let apps = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }
                guard apps.count == 1 else { throw SignError("\(base).zip holds \(apps.count) apps at its top, not one") }
                let appPath = (folder as NSString).appendingPathComponent(apps[0])
                print("== \(apps[0]): signed, notarized, stapled")
                try stamp(appPath, info: (appPath as NSString).appendingPathComponent("Contents/Info.plist"))
                try await signBundle(appPath, platform: .mac, p12: file("apple-developer-id-p12"), password: file("apple-developer-id-password"),
                                     certificate: developerID, profiles: profiles, work: work)
                try await notarize(appPath, key: file("notary.json"))
                let info = AppleBundle.info(appPath) ?? [:]
                // Zipped again as ditto would: the app at the top, its links kept (-y).
                let target = (out as NSString).appendingPathComponent(outputName(base: base, info: info, platform: "macos", ext: "zip"))
                try? FileManager.default.removeItem(atPath: target)
                let zipped = try await zip.run(["-qry", "-X", target, apps[0]], in: folder)
                guard zipped.ok else { throw SignError("\(base).zip couldn't be zipped again: \(zipped.error)") }
                signed.append(try described(target, info: info, platform: "macos"))
                if let dmg {
                    let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? base
                    let image = (work as NSString).appendingPathComponent("image-\(base)")
                    try FileManager.default.createDirectory(atPath: image, withIntermediateDirectories: false)
                    try FileManager.default.moveItem(atPath: appPath, toPath: (image as NSString).appendingPathComponent(apps[0]))
                    try FileManager.default.createSymbolicLink(atPath: (image as NSString).appendingPathComponent("Applications"),
                                                               withDestinationPath: "/Applications")
                    let disk = (out as NSString).appendingPathComponent(outputName(base: base, info: info, platform: "macos", ext: "dmg"))
                    try? FileManager.default.removeItem(atPath: disk)
                    print("== \((disk as NSString).lastPathComponent): made by dmg, signed, notarized, stapled")
                    let made = try await dmg.run(["create", "--volname", name, "--srcfolder", image, "--format", "UDZO", disk])
                    guard made.ok else { throw SignError("dmg couldn't make the disk image: \(made.error)") }
                    let signing = try await rcodesign.run(["sign"] + p12Arguments(file("apple-developer-id-p12"), file("apple-developer-id-password"))
                                                          + ["--for-notarization", disk])
                    guard signing.ok else { throw SignError("rcodesign couldn't sign the disk image:\n\(signing.output)\(signing.error)") }
                    try await notarize(disk, key: file("notary.json"))
                    signed.append(try described(disk, info: info, platform: "macos"))
                }
            }
        }
        return signed
    }

    /// rcodesign's API key file (what `encode-app-store-connect-api-key` writes), made from the three secrets so the
    /// key's id and issuer are never on a command line. Its private_key is the key's DER, base64: the .p8's PEM body
    /// with its lines joined.
    static func notaryKey(key: String, keyID: String, issuer: String) throws -> Data {
        let pem = key.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let body = pem.filter { !$0.isEmpty && !$0.hasPrefix("-----") }.joined()
        guard pem.first == "-----BEGIN PRIVATE KEY-----", !body.isEmpty else { throw SignError("apple-notary-key is not a .p8 (BEGIN PRIVATE KEY)") }
        let values = ["issuer_id": issuer.trimmingCharacters(in: .whitespacesAndNewlines),
                      "key_id": keyID.trimmingCharacters(in: .whitespacesAndNewlines), "private_key": body]
        return try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    }

    /// The identity's certificate's SHA-1 (what a profile names), read by openssl. A .p12 is as Keychain Access
    /// exports one (3DES), which OpenSSL 3 reads with -legacy. An empty password (no file) is given as itself.
    func certificate(_ openssl: Tool, p12: String, password: String) async throws -> String {
        let help = try await openssl.run(["pkcs12", "-help"])
        let legacy = (help.output + help.error).contains("-legacy") ? ["-legacy"] : []
        let passwordGiven = (FileManager.default.contents(atPath: password)?.count ?? 0) > 0
        let read = try await openssl.run(["pkcs12"] + legacy + ["-in", p12, "-passin", passwordGiven ? "file:\(password)" : "pass:", "-nokeys", "-clcerts"])
        guard read.ok, let sha = Self.certificateSHA1(pem: read.output) else {
            throw SignError("\((p12 as NSString).lastPathComponent) doesn't open with its password")
        }
        return sha
    }

    /// The first certificate's SHA-1 in PEM text, uppercase hex.
    static func certificateSHA1(pem: String) -> String? {
        guard let begin = pem.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = pem.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<pem.endIndex),
              let der = Data(base64Encoded: String(pem[begin.upperBound..<end.lowerBound]), options: .ignoreUnknownCharacters) else { return nil }
        return AppleProfile.sha1(der)
    }

    /// rcodesign's arguments for an identity; a password-less one's empty password said as such (rcodesign refuses
    /// an empty password file), never a password on a command line.
    func p12Arguments(_ p12: String, _ password: String) -> [String] {
        (FileManager.default.contents(atPath: password)?.count ?? 0) > 0
            ? ["--p12-file", p12, "--p12-password-file", password] : ["--p12-file", p12, "--p12-password", ""]
    }

    /// Unzipped, a ditto zip's AppleDouble files dropped (on a Mac they go back into attributes; here they'd be files
    /// the signature seals, and a Mac unzipping the result would break it).
    func unpack(_ package: String, into folder: String, unzip: Tool) async throws {
        try? FileManager.default.removeItem(atPath: folder)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let unzipped = try await unzip.run(["-q", package, "-d", folder])
        guard unzipped.ok else { throw SignError("\((package as NSString).lastPathComponent) couldn't be unzipped: \(unzipped.error)") }
        try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent("__MACOSX"))
        for relative in (FileManager.default.enumerator(atPath: folder)?.allObjects as? [String] ?? [])
        where (relative as NSString).lastPathComponent.hasPrefix("._") {
            try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(relative))
        }
    }

    /// BuildVariant set, the plist's format kept; a Mac app's stapled ticket (Contents/CodeResources) taken out, its
    /// signature being made again.
    func stamp(_ app: String, info path: String) throws {
        guard let variant else { return }
        guard let data = FileManager.default.contents(atPath: path) else { throw SignError("no Info.plist in \((app as NSString).lastPathComponent)") }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var info = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any] else {
            throw SignError("\((app as NSString).lastPathComponent)'s Info.plist isn't a dictionary")
        }
        info["BuildVariant"] = variant
        try PropertyListSerialization.data(fromPropertyList: info, format: format == .binary ? .binary : .xml, options: 0)
            .write(to: URL(fileURLWithPath: path))
        try? FileManager.default.removeItem(atPath: (app as NSString).appendingPathComponent("Contents/CodeResources"))
        print("   BuildVariant: \(variant)")
    }

    /// Each step the plan has, the deepest code first.
    func signBundle(_ app: String, platform: ApplePlan.Platform, p12: String, password: String, certificate: String, profiles: [AppleProfile],
                    work: String) async throws {
        let rcodesign = rcodesign
        let steps = try await ApplePlan.steps(app: app, platform: platform, profiles: profiles, certificate: certificate,
                                              kinds: platform == .mac ? [.developerID] : [ipaKind.profile]) { code in
            let target = AppleBundle.isFolder(code) ? AppleBundle.executable(code) : code
            guard let target else { return [:] }
            let info = try await rcodesign.run(["print-signature-info", target])
            return info.ok ? try ApplePlan.entitlements(fromSignatureInfo: info.output) : [:]
        }
        for (index, step) in steps.enumerated() {
            if let profile = step.profile, let embed = step.embed {
                try? FileManager.default.removeItem(atPath: embed)
                try FileManager.default.copyItem(atPath: profile, toPath: embed)
            }
            var arguments = ["sign"] + p12Arguments(p12, password) + (platform == .mac ? ["--for-notarization"] : [])
            if step.bundle { arguments.append("--shallow") }
            if let entitlements = step.entitlements {
                let file = (work as NSString).appendingPathComponent("entitlements-\(index).plist")
                try entitlements.write(to: URL(fileURLWithPath: file))
                arguments += ["--entitlements-xml-file", file]
            }
            let signing = try await self.rcodesign.run(arguments + [step.path])
            guard signing.ok else {
                throw SignError("rcodesign couldn't sign \(step.path.dropFirst(work.count + 1)):\n\(signing.output)\(signing.error)")
            }
        }
    }

    func notarize(_ path: String, key: String) async throws {
        let submitted = try await rcodesign.run(["notary-submit", "--api-key-file", key, "--wait", "--staple", path])
        guard submitted.ok else {
            throw SignError("\((path as NSString).lastPathComponent) wasn't notarized and stapled:\n\(submitted.output)\(submitted.error)")
        }
    }

    func outputName(base: String, info: [String: Any], platform: String, ext: String) -> String {
        guard let app else { return "\(base).\(ext)" }
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        return "\(app.replacingOccurrences(of: " ", with: "-"))-\(version)-\(platform).\(ext)"
    }

    /// An output's builds.json line (RELEASE_ASSETS.md's fields this tool knows: the rest, a commit and an executable's
    /// UUID, are the caller's).
    func described(_ path: String, info: [String: Any], platform: String) throws -> Signed {
        guard let data = FileManager.default.contents(atPath: path) else { throw SignError("\(path) wasn't written") }
        var line = ["file": (path as NSString).lastPathComponent, "platform": platform,
                    "bundleID": info["CFBundleIdentifier"] as? String ?? "",
                    "version": info["CFBundleShortVersionString"] as? String ?? "",
                    "buildNumber": info["CFBundleVersion"] as? String ?? "",
                    "variant": info["BuildVariant"] as? String ?? "",
                    "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        if let app { line["app"] = app }
        return Signed(path: path, line: line, size: data.count)
    }
}
