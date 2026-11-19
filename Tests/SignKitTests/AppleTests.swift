import Crypto
import Foundation
import Testing
@testable import SignKit

// sign apple's plan (ApplePlan, AppleProfile, AppleBundle): profiles read and chosen, entitlements made a profile's,
// code ordered deepest first, rcodesign's output read. No key and no rcodesign: those are CI's signing jobs'.

private let team = "TEAMPREFIX"
private let certificate = Data("a certificate".utf8)
private let certificateSHA = AppleProfile.sha1(certificate)

/// A profile's bytes as Apple sends one: its plist inside a CMS envelope (here, bytes either side).
private func profileData(bundle: String, mac: Bool = false, kind: AppleProfile.Kind, entitlements extra: [String: Any] = [:],
                         expires: Date = Date(timeIntervalSinceNow: 86_400 * 30), certificates: [Data] = [certificate]) throws -> Data {
    var entitlements: [String: Any] = [mac ? "com.apple.application-identifier" : "application-identifier": "\(team).\(bundle)",
                                       "keychain-access-groups": ["\(team).*"]]
    if kind == .development { entitlements[mac ? "com.apple.security.get-task-allow" : "get-task-allow"] = true }
    entitlements.merge(extra) { $1 }
    var info: [String: Any] = ["Name": "\(bundle) \(kind.rawValue)", "ApplicationIdentifierPrefix": [team], "TeamIdentifier": [team],
                               "Platform": [mac ? "OSX" : "iOS"], "ExpirationDate": expires, "DeveloperCertificates": certificates,
                               "Entitlements": entitlements]
    switch kind {
    case .development, .adHoc: info["ProvisionedDevices"] = ["device"]
    case .enterprise, .developerID: info["ProvisionsAllDevices"] = true
    case .appStore: break
    }
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    return Data([0x30, 0x80, 0x06]) + plist + Data([0x00, 0x00])
}

private func profile(_ bundle: String, mac: Bool = false, kind: AppleProfile.Kind, entitlements: [String: Any] = [:],
                     expires: Date = Date(timeIntervalSinceNow: 86_400 * 30), certificates: [Data] = [certificate]) throws -> AppleProfile {
    let data = try profileData(bundle: bundle, mac: mac, kind: kind, entitlements: entitlements, expires: expires, certificates: certificates)
    return try AppleProfile(path: "/profiles/\(bundle).\(kind.rawValue)", info: try #require(AppleProfile.plist(data)))
}

@Test func aProfileIsReadOutOfItsEnvelopeWithItsKind() throws {
    for kind in AppleProfile.Kind.allCases where kind != .developerID {
        let read = try profile("com.example.App", kind: kind)
        #expect(read.kind == kind)
        #expect(read.bundleID == "com.example.App" && read.prefix == team && read.team == team && !read.mac)
        #expect(read.certificates == [certificateSHA])
    }
    #expect(try profile("com.example.Mac", mac: true, kind: .developerID).kind == .developerID)
    #expect(AppleProfile.plist(Data("no plist here".utf8)) == nil)
}

@Test func theProfilesInAFolderAreFoundAtAnyDepth() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("build-tools-profiles-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
    try profileData(bundle: "com.example.App", kind: .development).write(to: folder.appendingPathComponent("inner/a.mobileprovision"))
    try profileData(bundle: "com.example.Mac", mac: true, kind: .developerID).write(to: folder.appendingPathComponent("b.provisionprofile"))
    try Data("junk".utf8).write(to: folder.appendingPathComponent("c.mobileprovision"))
    try Data("ignored".utf8).write(to: folder.appendingPathComponent("readme.txt"))
    let found = AppleProfile.all(in: folder.path)
    #expect(Set(found.map(\.bundleID)) == ["com.example.App", "com.example.Mac"])
}

@Test func oneProfilePerBundleOfTheKindAskedNamingTheCertificate() throws {
    let now = Date()
    let profiles = [try profile("com.example.App", kind: .development), try profile("com.example.App", kind: .adHoc),
                    try profile("com.example.App.Share", kind: .development),
                    try profile("com.example.App.Share", kind: .adHoc, expires: now.addingTimeInterval(-60)),
                    try profile("com.example.Other", kind: .adHoc, certificates: [Data("another".utf8)])]
    let chosen = try ApplePlan.choose(profiles, for: ["com.example.App", "com.example.App.Share"], kinds: [.development],
                                      certificate: certificateSHA, now: now)
    #expect(chosen["com.example.App"]?.kind == .development && chosen["com.example.App.Share"]?.kind == .development)
    // The extension's ad hoc profile has expired: no ad hoc set.
    #expect(throws: SignError.self) {
        try ApplePlan.choose(profiles, for: ["com.example.App", "com.example.App.Share"], kinds: [.adHoc], certificate: certificateSHA, now: now)
    }
    // A profile naming another certificate isn't one.
    #expect(throws: SignError.self) {
        try ApplePlan.choose(profiles, for: ["com.example.Other"], kinds: [.adHoc], certificate: certificateSHA, now: now)
    }
}

@Test func entitlementsAreMadeTheProfiles() throws {
    let app = try profile("com.example.App", kind: .adHoc, entitlements: ["aps-environment": "production"])
    // None of its own: the profile's, its wildcard keychain group made the app's.
    let concrete = try ApplePlan.entitlements(own: [:], bundle: "com.example.App", profile: app)
    #expect(concrete["application-identifier"] as? String == "\(team).com.example.App")
    #expect(concrete["keychain-access-groups"] as? [String] == ["\(team).com.example.App"])
    #expect(concrete["get-task-allow"] == nil)
    // Its own: the build's prefix made the team's, push the profile's, debugging dropped.
    let own: [String: Any] = ["application-identifier": "OLDPREFIX.com.example.App", "keychain-access-groups": ["OLDPREFIX.shared"],
                              "aps-environment": "development", "get-task-allow": true]
    let made = try ApplePlan.entitlements(own: own, bundle: "com.example.App", profile: app)
    #expect(made["keychain-access-groups"] as? [String] == ["\(team).shared"])
    #expect(made["aps-environment"] as? String == "production")
    #expect(made["get-task-allow"] == nil)
    // A key the profile doesn't allow: refused.
    #expect(throws: SignError.self) {
        try ApplePlan.entitlements(own: ["com.apple.developer.healthkit": true], bundle: "com.example.App", profile: app)
    }
    // On a Mac the hardened runtime's and the sandbox's are no profile's.
    let mac = try profile("com.example.Mac", mac: true, kind: .developerID)
    let sandboxed = try ApplePlan.entitlements(own: ["com.apple.security.app-sandbox": true], bundle: "com.example.Mac", profile: mac)
    #expect(isTrue(sandboxed["com.apple.security.app-sandbox"]))
    #expect(ApplePlan.restrictedOnMac("com.apple.security.application-groups", ["group.example"]))
    #expect(!ApplePlan.restrictedOnMac("com.apple.security.application-groups", ["\(team).example"]))
}

/// A bundle on disk: its Info.plist, and its executable as a Mach-O file's first bytes.
private func makeBundle(_ path: URL, id: String, mac: Bool = false) throws {
    let contents = mac ? path.appendingPathComponent("Contents") : path
    let executableFolder = mac ? contents.appendingPathComponent("MacOS") : contents
    try FileManager.default.createDirectory(at: executableFolder, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "main", "CFBundleShortVersionString": "1.2.3"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    try Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0]).write(to: executableFolder.appendingPathComponent("main"))
}

@Test func anIPhoneAppIsSignedDeepestFirstEachProvisionedBundleWithItsProfile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("build-tools-app-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("App.app")
    try makeBundle(app, id: "com.example.App")
    try makeBundle(app.appendingPathComponent("PlugIns/Share.appex"), id: "com.example.App.Share")
    try makeBundle(app.appendingPathComponent("Frameworks/Kit.framework"), id: "com.example.Kit")
    try Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2]).write(to: app.appendingPathComponent("Frameworks/libswift.dylib"))
    try Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52]).write(to: app.appendingPathComponent("Something.class"))
    let profiles = [try profile("com.example.App", kind: .development), try profile("com.example.App.Share", kind: .development)]
    let steps = try await ApplePlan.steps(app: app.path, platform: .ios, profiles: profiles, certificate: certificateSHA,
                                          kinds: [.development]) { _ in [:] }
    let names = steps.map { $0.path.dropFirst(app.path.count) }
    #expect(names == ["/Frameworks/Kit.framework", "/Frameworks/libswift.dylib", "/PlugIns/Share.appex", ""])
    #expect(steps[0].profile == nil && steps[0].bundle)
    #expect(steps[1].bundle == false && steps[1].profile == nil)
    #expect(steps[2].profile?.hasSuffix("com.example.App.Share.development") == true && steps[2].embed?.hasSuffix("Share.appex/embedded.mobileprovision") == true)
    #expect(steps[3].entitlements != nil && steps[3].profile != nil)
    // An extension that isn't the app's own: refused.
    try makeBundle(app.appendingPathComponent("PlugIns/Stray.appex"), id: "com.other.Stray")
    await #expect(throws: SignError.self) {
        try await ApplePlan.steps(app: app.path, platform: .ios, profiles: profiles, certificate: certificateSHA, kinds: [.development]) { _ in [:] }
    }
}

@Test func aMacAppAskingForWhatOnlyAProfileAllowsIsRefusedWithoutOne() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("build-tools-mac-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Mac.app")
    try makeBundle(app, id: "com.example.Mac", mac: true)
    let asks: [String: Any] = ["keychain-access-groups": ["\(team).com.example.Mac"]]
    await #expect(throws: SignError.self) {
        try await ApplePlan.steps(app: app.path, platform: .mac, profiles: [], certificate: certificateSHA, kinds: [.developerID]) { _ in asks }
    }
    let withProfile = try await ApplePlan.steps(app: app.path, platform: .mac, profiles: [try profile("com.example.Mac", mac: true, kind: .developerID)],
                                                certificate: certificateSHA, kinds: [.developerID]) { _ in asks }
    #expect(withProfile.last?.embed?.hasSuffix("Contents/embedded.provisionprofile") == true)
    let plain = try await ApplePlan.steps(app: app.path, platform: .mac, profiles: [], certificate: certificateSHA, kinds: [.developerID]) { _ in [:] }
    #expect(plain.count == 1 && plain[0].entitlements == nil && plain[0].profile == nil)
}

@Test func rcodesignsEntitlementsAreRead() throws {
    let output = """
    signature:
      entitlements_plist:
      - '<?xml version="1.0" encoding="UTF-8"?>'
      - '<plist version="1.0">'
      - <dict>
      - "  <key>com.apple.security.app-sandbox</key>"
      - '  <true/>'
      - </dict>
      - </plist>
      code_requirements_xml: []
    """
    let values = try ApplePlan.entitlements(fromSignatureInfo: output)
    #expect(isTrue(values["com.apple.security.app-sandbox"]))
    #expect(try ApplePlan.entitlements(fromSignatureInfo: "signature:\n  cms: none\n").isEmpty)
}

@Test func theNotaryKeyFileIsMadeOfTheThreeSecrets() throws {
    let pem = "-----BEGIN PRIVATE KEY-----\nAAAA\nBBBB\n-----END PRIVATE KEY-----\n"
    let made = try JSONSerialization.jsonObject(with: try AppleSigner.notaryKey(key: pem, keyID: "KEY\n", issuer: "issuer")) as? [String: String]
    #expect(made == ["issuer_id": "issuer", "key_id": "KEY", "private_key": "AAAABBBB"])
    #expect(throws: SignError.self) { try AppleSigner.notaryKey(key: "not a key", keyID: "k", issuer: "i") }
}

@Test func aCertificatesSHA1IsReadFromPEM() {
    let pem = "Bag Attributes\n-----BEGIN CERTIFICATE-----\n\(certificate.base64EncodedString())\n-----END CERTIFICATE-----\n"
    #expect(AppleSigner.certificateSHA1(pem: pem) == certificateSHA)
    #expect(AppleSigner.certificateSHA1(pem: "nothing") == nil)
}

@Test func theKeysFromTheEnvironmentAreTakenAndUnset() throws {
    setenv("APPLE_NOTARY_KEY_ID", "key-id", 1)
    setenv("APPLE_PROFILES_3", Data("tar".utf8).base64EncodedString(), 1)
    let folder = try SecretsFolder(prefix: "build-tools-apple-test")
    defer { folder.remove() }
    try AppleSigner.takeEnvironment(into: folder)
    #expect(ProcessInfo.processInfo.environment["APPLE_NOTARY_KEY_ID"] == nil && ProcessInfo.processInfo.environment["APPLE_PROFILES_3"] == nil)
    #expect(FileManager.default.contents(atPath: folder.path + "/apple-notary-key-id") == Data("key-id".utf8))
    #expect(FileManager.default.contents(atPath: folder.path + "/apple-profiles-3") == Data("tar".utf8))
}

@Test func aVariantIsAWord() {
    #expect(AppleSigner.validVariant("Production") && AppleSigner.validVariant("Alpha2"))
    for bad in ["", "2x", "a b", "Pro-duction", String(repeating: "a", count: 33)] { #expect(!AppleSigner.validVariant(bad), "\(bad)") }
}

@Test func aProfilesArchiveMemberOutsideItsFolderIsFound() {
    #expect(AppleSigner.strayMember("./\n./a.mobileprovision\ninner/b.provisionprofile\n") == nil)
    #expect(AppleSigner.strayMember("./a.mobileprovision\n../escape\n") == "../escape")
    #expect(AppleSigner.strayMember("/etc/passwd\n") == "/etc/passwd")
    #expect(AppleSigner.strayMember("inner/../../x\n") == "inner/../../x")
    #expect(AppleSigner.strayMember("a..b.mobileprovision\n") == nil)
}

/// Property lists written without Foundation's bridging (a statically linked sign couldn't write a Bool), read back
/// as Foundation reads them.
@Test func aPlistIsWrittenAsXMLItsBoolsBoolsAndItsNumbersNumbers() throws {
    let values: [String: Any] = ["get-task-allow": true, "aps-environment": "production", "count": 3, "groups": ["A.b", "C<d>"],
                                 "nested": ["flag": false], "data": Data([1, 2, 3])]
    let written = try PlistXML.data(values)
    let text = String(decoding: written, as: UTF8.self)
    #expect(text.contains("<key>get-task-allow</key>\n\t<true/>") && text.contains("<integer>3</integer>") && text.contains("C&lt;d&gt;"))
    let read = try #require(try PropertyListSerialization.propertyList(from: written, format: nil) as? [String: Any])
    #expect(isTrue(read["get-task-allow"]) && !isTrue((read["nested"] as? [String: Any])?["flag"]))
    #expect(read["count"] as? Int == 3 && read["groups"] as? [String] == ["A.b", "C<d>"] && read["data"] as? Data == Data([1, 2, 3]))
}
