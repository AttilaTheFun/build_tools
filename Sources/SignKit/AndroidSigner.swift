import Foundation

/// An Android app's release APK signed with its private release key, in the CI job's own container (Logan,
/// 2026-11-15: signing is hermetic, one key per package, pinned): APK Signature Schemes v2 and v3, then checked as
/// Android checks it and against the certificate's pin, so a key swapped in the store signs nothing. Ported from
/// shireworks' tools/ci/android_sign.sh.
public struct AndroidSigner: Sendable {
    /// Where the key comes from.
    public enum Keys: Sendable {
        /// A public repository's job on GitHub's runners: ANDROID_SIGNING_KEYSTORE (the PKCS12, base64) and
        /// ANDROID_SIGNING_PASSWORD, its GitHub environment's secrets, read once and unset.
        case environment
        /// A folder already holding `android-<app>-keystore` and `android-<app>-password` (Shireworks' secret
        /// service's `secrets-fetch`, on a tmpfs), the caller's to remove.
        case folder(String)
    }

    /// The key's name (its alias, and its secrets' names): lowercase letters, digits and `-`.
    public let app: String
    /// The release certificate's SHA-256, lowercase hex without colons.
    public let pin: String
    public let java: Tool
    /// apksigner.jar, the repository's own pinned one.
    public let apksigner: String

    public init(app: String, pin: String, java: String, apksigner: String) throws {
        guard Self.validApp(app) else { throw SignError("the key's name is lowercase letters, digits and -: \(app)") }
        guard let pin = Self.normalizedPin(pin) else { throw SignError("the pin is a SHA-256: 64 hex digits, colons or not") }
        guard FileManager.default.isExecutableFile(atPath: java) else { throw SignError("no java at \(java)") }
        guard FileManager.default.fileExists(atPath: apksigner) else { throw SignError("no apksigner.jar at \(apksigner)") }
        self.app = app
        self.pin = pin
        self.java = Tool(java)
        self.apksigner = apksigner
    }

    static func validApp(_ app: String) -> Bool {
        guard let first = app.first, first.isASCII, first.isLowercase || first.isNumber, app.count <= 41 else { return false }
        return app.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    /// A SHA-256 as hex, colons and spaces dropped, lowercased; nil if it isn't one.
    static func normalizedPin(_ text: String) -> String? {
        let hex = text.filter { $0 != ":" && $0 != " " }.lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    /// Whether its key is here (both of its secrets, set or in the folder), nothing read: `--skip-missing-keys`.
    public func hasKeys(_ keys: Keys, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch keys {
        case .environment:
            return ["ANDROID_SIGNING_KEYSTORE", "ANDROID_SIGNING_PASSWORD"].allSatisfy { !(environment[$0] ?? "").isEmpty }
        case .folder(let path):
            return ["keystore", "password"].allSatisfy {
                FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("android-\(app)-\($0)"))
            }
        }
    }

    /// Where the signed APK is made: a new folder of the temporary directory's, the owner's alone (0700), never the
    /// keys' tmpfs (SecretsFolder). An APK is no secret, and a job container's /dev/shm is 64 MB unless its job asks for
    /// more (Isomer, 2026-11-20: the Playground's 157 MB APK filled it, "No space left on device").
    static func workFolder() throws -> String {
        let work = (NSTemporaryDirectory() as NSString).appendingPathComponent("android-sign-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return work
    }

    /// Signs `input` into `output`, its certificate checked against the pin: what the signed APK's certificate is.
    @discardableResult
    public func sign(_ input: String, to output: String, keys: Keys) async throws -> String {
        guard FileManager.default.fileExists(atPath: input) else { throw SignError("no such APK: \(input)") }
        let work = try Self.workFolder()
        defer { try? FileManager.default.removeItem(atPath: work) }
        let signed = (work as NSString).appendingPathComponent("signed.apk")
        do {
            // The key and its password on a tmpfs for as long as apksigner needs them; never a command line.
            var secrets: SecretsFolder?
            defer { secrets?.remove() }
            let keystore: String, password: String
            switch keys {
            case .environment:
                guard let encoded = SecretEnvironment.take("ANDROID_SIGNING_KEYSTORE"),
                      let passwordText = SecretEnvironment.take("ANDROID_SIGNING_PASSWORD") else {
                    throw SignError("ANDROID_SIGNING_KEYSTORE and ANDROID_SIGNING_PASSWORD aren't both set")
                }
                guard let store = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
                    throw SignError("ANDROID_SIGNING_KEYSTORE isn't base64")
                }
                let folder = try SecretsFolder(prefix: "android-sign")
                secrets = folder
                keystore = try folder.write("android-\(app)-keystore", store)
                password = try folder.write("android-\(app)-password", Data(passwordText.utf8))
            case .folder(let path):
                keystore = (path as NSString).appendingPathComponent("android-\(app)-keystore")
                password = (path as NSString).appendingPathComponent("android-\(app)-password")
            }
            guard FileManager.default.fileExists(atPath: keystore), FileManager.default.fileExists(atPath: password) else {
                throw SignError("no key for \(app)")
            }
            // apksigner reads the password from its file (`file:`, its whole first line).
            let signing = try await java.run(["-jar", apksigner, "sign", "--ks", keystore, "--ks-type", "PKCS12", "--ks-key-alias", app,
                                              "--ks-pass", "file:\(password)", "--v2-signing-enabled", "true",
                                              "--v3-signing-enabled", "true", "--out", signed, input])
            guard signing.ok else { throw SignError("apksigner couldn't sign: \(signing.error)") }
        }
        // Checked as Android checks it, and against the pin.
        let verify = try await java.run(["-jar", apksigner, "verify", "--verbose", "--print-certs", signed])
        guard verify.ok else { throw SignError("apksigner doesn't verify the signed APK:\n\(verify.output)\(verify.error)") }
        // Android 9 and later verify v3 alone, so the v2 block is read as Android 7 and 8 would.
        let verifyV2 = try await java.run(["-jar", apksigner, "verify", "--verbose", "--min-sdk-version", "24", "--max-sdk-version", "27", signed])
        guard verifyV2.ok else { throw SignError("apksigner doesn't verify the signed APK's v2 signature:\n\(verifyV2.output)\(verifyV2.error)") }
        let certificate = try Self.checked(verify: verify.output, verifyV2: verifyV2.output, pin: pin, app: app)
        try? FileManager.default.createDirectory(atPath: (output as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: output)
        try FileManager.default.moveItem(atPath: signed, toPath: output)
        return certificate
    }

    /// apksigner's verify outputs read: v3 and v2 signatures, one signer, its certificate the pinned one. Its digest.
    static func checked(verify: String, verifyV2: String, pin: String, app: String) throws -> String {
        let lines = verify.split(separator: "\n").map(String.init)
        guard lines.contains("Verified using v3 scheme (APK Signature Scheme v3): true") else { throw SignError("the signed APK has no v3 signature") }
        guard verifyV2.split(separator: "\n").contains("Verified using v2 scheme (APK Signature Scheme v2): true") else {
            throw SignError("the signed APK has no v2 signature")
        }
        let digests = lines.compactMap { line -> String? in
            guard line.hasPrefix("Signer #"), let range = line.range(of: " certificate SHA-256 digest:") else { return nil }
            return normalizedPin(String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        guard digests.count == 1, let digest = digests.first else { throw SignError("the signed APK has \(digests.count) signers, not one") }
        guard digest == pin else { throw SignError("the signing key isn't \(app)'s: its certificate is \(digest), not the pinned \(pin)") }
        return digest
    }
}

extension AndroidSigner {
    /// A signed APK's builds.json line, read by the repository's aapt2 (`dump badging`): its package as its bundle id,
    /// its versionName and versionCode, its label as its name (else `name`); no executable UUID, no icon, and
    /// `"urlSchemes": []`, as RELEASE_ASSETS.md's Android lines have.
    public static func describe(_ apk: String, aapt2: String, name: String?, variant: String, commit: String?) async throws -> BuildDescription {
        guard let data = FileManager.default.contents(atPath: apk) else { throw SignError("no APK at \(apk)") }
        let dumped = try await Tool(aapt2).run(["dump", "badging", apk])
        guard dumped.ok else { throw SignError("aapt2 couldn't read \(apk): \(dumped.error)") }
        let badging = try badging(dumped.output)
        return BuildDescription(file: (apk as NSString).lastPathComponent, bundleID: badging.package, app: name ?? badging.label ?? badging.package,
                                platform: "android", version: badging.versionName, buildNumber: badging.versionCode, variant: variant,
                                commit: BuildDescription.commit(commit), executableUUID: "", size: data.count,
                                sha256: BuildDescription.sha256(data), icon: nil, urlSchemes: [])
    }

    /// `aapt2 dump badging`'s package line (`package: name='…' versionCode='…' versionName='…'`) and label.
    static func badging(_ output: String) throws -> (package: String, versionCode: String, versionName: String, label: String?) {
        func value(_ key: String, in line: Substring) -> String? {
            guard let start = line.range(of: "\(key)='") else { return nil }
            let rest = line[start.upperBound...]
            return rest.firstIndex(of: "'").map { String(rest[..<$0]) }
        }
        let lines = output.split(separator: "\n")
        guard let package = lines.first(where: { $0.hasPrefix("package:") }), let name = value("name", in: package) else {
            throw SignError("aapt2 named no package")
        }
        let label = lines.first { $0.hasPrefix("application-label:") }.map { String($0.dropFirst("application-label:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            ?? lines.first { $0.hasPrefix("application:") }.flatMap { value("label", in: $0) }
        return (name, value("versionCode", in: package) ?? "", value("versionName", in: package) ?? "", label.flatMap { $0.isEmpty ? nil : $0 })
    }
}
