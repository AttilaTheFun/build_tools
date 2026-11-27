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

// --mac-kind development: a Mac app's development profile, always embedded, its restricted entitlements allowed.
@Test func aMacDevelopmentBuildAlwaysEmbedsItsDevelopmentProfile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("build-tools-mac-dev-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Mac.app")
    try makeBundle(app, id: "com.example.Mac", mac: true)
    let analysis: [String: Any] = ["com.apple.developer.sensitivecontentanalysis.client": ["analysis"]]
    // None: refused, even for an app asking for nothing (a development build names the Macs it runs on).
    await #expect(throws: SignError.self) {
        try await ApplePlan.steps(app: app.path, platform: .mac, profiles: [try profile("com.example.Mac", mac: true, kind: .developerID)],
                                  certificate: certificateSHA, kinds: [.development]) { _ in [:] }
    }
    let development = try profile("com.example.Mac", mac: true, kind: .development, entitlements: analysis)
    #expect(development.kind == .development && development.mac)
    let steps = try await ApplePlan.steps(app: app.path, platform: .mac, profiles: [development], certificate: certificateSHA,
                                          kinds: [.development]) { _ in analysis }
    let last = try #require(steps.last)
    #expect(last.profile == development.path && last.embed?.hasSuffix("Contents/embedded.provisionprofile") == true)
    let entitlementsData = try #require(last.entitlements)
    let entitlements = try #require(PropertyListSerialization.propertyList(from: entitlementsData, format: nil) as? [String: Any])
    #expect(entitlements["com.apple.developer.sensitivecontentanalysis.client"] as? [String] == ["analysis"])
    // A Developer ID profile can't carry it: a Developer ID build asking for it is refused.
    await #expect(throws: SignError.self) {
        try await ApplePlan.steps(app: app.path, platform: .mac, profiles: [try profile("com.example.Mac", mac: true, kind: .developerID)],
                                  certificate: certificateSHA, kinds: [.developerID]) { _ in analysis }
    }
}

@Test func aMacProfileNamingDevicesIsDevelopmentWithoutGetTaskAllow() throws {
    // As Apple makes a Mac development profile: its devices, and no get-task-allow.
    let info: [String: Any] = ["Name": "Mac Development", "ApplicationIdentifierPrefix": [team], "TeamIdentifier": [team],
                               "Platform": ["OSX"], "ExpirationDate": Date(timeIntervalSinceNow: 86_400),
                               "DeveloperCertificates": [certificate], "ProvisionedDevices": ["mac"],
                               "Entitlements": ["com.apple.application-identifier": "\(team).com.example.Mac"]]
    let read = try AppleProfile(path: "/profiles/mac.provisionprofile", info: info)
    #expect(read.mac && read.kind == .development)
}

@Test func aDevelopmentMacBuildHasNoDiskImage() {
    #expect(throws: SignError.self) {
        try AppleSigner(rcodesign: nil, dmg: "/bin/sh", ipaKinds: [.development], macKind: .development, variant: nil, app: nil)
    }
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

/// What Foundation reads from a plist, written back: integers stay integers (UIDeviceFamily's 1 and 2, a 0), Bools
/// stay Bools (NCH's review of #6: a number must never bridge into a Bool).
@Test func aPlistReadAndWrittenAgainKeepsItsIntegersAndBools() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>Zero</key><integer>0</integer>
    <key>One</key><integer>1</integer>
    <key>Flag</key><true/>
    <key>Off</key><false/>
    <key>Real</key><real>2.5</real>
    </dict></plist>
    """
    let read = try #require(try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any])
    let text = String(decoding: try PlistXML.data(read), as: UTF8.self)
    #expect(text.contains("<key>UIDeviceFamily</key>\n\t<array>\n\t\t<integer>1</integer>\n\t\t<integer>2</integer>"), "\(text)")
    #expect(text.contains("<key>Zero</key>\n\t<integer>0</integer>") && text.contains("<key>One</key>\n\t<integer>1</integer>"), "\(text)")
    #expect(text.contains("<key>Flag</key>\n\t<true/>") && text.contains("<key>Off</key>\n\t<false/>"), "\(text)")
    #expect(text.contains("<key>Real</key>\n\t<real>2.5</real>"), "\(text)")
}

@Test func copyingUnsignedNeedsNoRcodesignButSigningDoes() async throws {
    // --unsigned runs no rcodesign, so it needs none (Isomer passed /usr/bin/true); signing still refuses without one.
    let signer = try AppleSigner(rcodesign: nil, dmg: nil, ipaKinds: [.adHoc], variant: nil, app: nil)
    await #expect(throws: SignError.self) { try await signer.sign([], out: NSTemporaryDirectory(), keys: .folder(NSTemporaryDirectory())) }
    #expect(throws: SignError.self) { try AppleSigner(rcodesign: "/nonexistent/rcodesign", dmg: nil, ipaKinds: [.adHoc], variant: nil, app: nil) }
}

// sign team: the team of a bundle's profiles, from the keys' apple-profiles archive.

private func profileXML(team: String, bundle: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>Name</key><string>CI Development: \(bundle)</string>
    <key>TeamIdentifier</key><array><string>\(team)</string></array>
    <key>ExpirationDate</key><date>2030-01-01T00:00:00Z</date>
    <key>ProvisionedDevices</key><array/>
    <key>Entitlements</key><dict><key>application-identifier</key><string>\(team).\(bundle)</string></dict>
    </dict></plist>
    """
}

@Test func theTeamIsTheBundlesProfiles() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("sign-team-test-\(UUID().uuidString)")
    let profiles = base.appendingPathComponent("profiles"), keys = base.appendingPathComponent("keys")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
    try profileXML(team: "TEAMA12345", bundle: "com.example.Images").write(to: profiles.appendingPathComponent("images.mobileprovision"), atomically: true, encoding: .utf8)
    try profileXML(team: "TEAMB12345", bundle: "com.example.Other").write(to: profiles.appendingPathComponent("other.provisionprofile"), atomically: true, encoding: .utf8)
    let tar = try #require(Tool.find("tar"))
    #expect(try await tar.run(["-czf", keys.appendingPathComponent("apple-profiles").path, "-C", profiles.path, "."]).ok)
    #expect(try await AppleProfile.team(keys: keys.path, bundle: "com.example.Images") == "TEAMA12345")
    await #expect(throws: SignError.self) { try await AppleProfile.team(keys: keys.path, bundle: "com.example.Missing") }
}

// --add-infoplist, --add-app-group and --add-keychain-group (AppleAdditions): what a build on runners with no secrets
// left out, stamped into the outer app before it's signed (Isomer, 2026-11-27). None of their values is ever said.

@Test func addedInfoPlistKeysAreStringsOrArraysOfStringsAndNeverOverwrite() throws {
    let read = try AppleAdditions.infoPlist(json: Data(#"{"SharedClientID": "abc", "Distributors": ["com.example.A", "com.example.B"]}"#.utf8))
    #expect(read == ["SharedClientID": .string("abc"), "Distributors": .strings(["com.example.A", "com.example.B"])])
    #expect(throws: SignError.self) { try AppleAdditions.infoPlist(json: Data(#"{"Count": 3}"#.utf8)) }
    #expect(throws: SignError.self) { try AppleAdditions.infoPlist(json: Data(#"["not", "an", "object"]"#.utf8)) }
    let additions = try AppleAdditions(infoPlist: read)
    let merged = try additions.merged(into: ["CFBundleIdentifier": "com.example.App", "SharedClientID": "abc"])
    #expect(merged["SharedClientID"] as? String == "abc")
    #expect(merged["Distributors"] as? [String] == ["com.example.A", "com.example.B"])
    #expect(merged["CFBundleIdentifier"] as? String == "com.example.App")
    // Already there with another value: refused, naming the key, never either value.
    do {
        _ = try additions.merged(into: ["SharedClientID": "something else"])
        Issue.record("a different value was overwritten")
    } catch let error as SignError {
        #expect("\(error)".contains("SharedClientID") && !"\(error)".contains("abc") && !"\(error)".contains("something else"))
    }
}

@Test func addedGroupsGoLastAfterTheAppsOwnEachOnce() throws {
    let additions = try AppleAdditions(appGroups: ["\(team).shared", "\(team).shared"], keychainGroups: ["\(team).com.example.shared"])
    // The app's own first: where it saves without naming a group.
    let own: [String: Any] = ["keychain-access-groups": ["\(team).com.example.App"], "com.apple.security.application-groups": ["\(team).own"]]
    let added = additions.applied(to: own, bundle: "com.example.App")
    #expect(added["keychain-access-groups"] as? [String] == ["\(team).com.example.App", "\(team).com.example.shared"])
    #expect(added["com.apple.security.application-groups"] as? [String] == ["\(team).own", "\(team).shared"])
    // None of its own: its own group first, made from the added group's team, then the added one.
    let none = additions.applied(to: [:], bundle: "com.example.App")
    #expect(none["keychain-access-groups"] as? [String] == ["\(team).com.example.App", "\(team).com.example.shared"])
    #expect(none["com.apple.security.application-groups"] as? [String] == ["\(team).shared"])
    // Nothing added: nothing changed.
    #expect(AppleAdditions.none.applied(to: own, bundle: "com.example.App")["keychain-access-groups"] as? [String] == ["\(team).com.example.App"])
}

@Test func aGroupThatIsntOneIsRefusedWithoutSayingIt() {
    for (apps, keychains) in [([""], [String]()), (["has space"], []), ([], ["shared"]), ([], ["teamprefix.shared"]), ([], ["SHORT.shared"])] {
        do {
            _ = try AppleAdditions(appGroups: apps, keychainGroups: keychains)
            Issue.record("\(apps) \(keychains) taken")
        } catch {
            #expect(!"\(error)".contains("shared") && !"\(error)".contains("has space"))
        }
    }
}

@Test func addedGroupsAreCheckedAgainstTheProfileAndOnlyTheAppGetsThem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("build-tools-additions-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("App.app")
    try makeBundle(app, id: "com.example.App")
    try makeBundle(app.appendingPathComponent("PlugIns/Share.appex"), id: "com.example.App.Share")
    let groups: [String: Any] = ["com.apple.security.application-groups": ["\(team).shared"]]
    let profiles = [try profile("com.example.App", kind: .development, entitlements: groups),
                    try profile("com.example.App.Share", kind: .development, entitlements: groups)]
    let additions = try AppleAdditions(appGroups: ["\(team).shared"], keychainGroups: ["\(team).com.example.shared"])
    let steps = try await ApplePlan.steps(app: app.path, platform: .ios, profiles: profiles, certificate: certificateSHA,
                                          kinds: [.development], additions: additions) { _ in [:] }
    func entitlements(_ step: ApplePlan.Step) throws -> [String: Any] {
        let data = try #require(step.entitlements)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
    let last = try #require(steps.last)
    let outer = try entitlements(last)
    #expect(outer["com.apple.security.application-groups"] as? [String] == ["\(team).shared"])
    // The profile's wildcard keychain group made the app's own, first; the added one after it.
    #expect(outer["keychain-access-groups"] as? [String] == ["\(team).com.example.App", "\(team).com.example.shared"])
    let shareStep = try #require(steps.first { $0.path.hasSuffix("Share.appex") })
    let share = try entitlements(shareStep)
    #expect(share["keychain-access-groups"] as? [String] == ["\(team).com.example.App.Share"])
    #expect(share["com.apple.security.application-groups"] as? [String] == ["\(team).shared"])
    // A group the profile doesn't allow: refused, saying how many, never which.
    let stray = try AppleAdditions(appGroups: ["\(team).elsewhere"])
    do {
        _ = try await ApplePlan.steps(app: app.path, platform: .ios, profiles: profiles, certificate: certificateSHA,
                                      kinds: [.development], additions: stray) { _ in [:] }
        Issue.record("a group the profile doesn't allow was taken")
    } catch let error as SignError {
        #expect("\(error)".contains("1 app group added") && !"\(error)".contains("elsewhere"))
    }
    // A Mac app with no profile: a keychain group added needs one, so it's refused as its own would be.
    let mac = root.appendingPathComponent("Mac.app")
    try makeBundle(mac, id: "com.example.Mac", mac: true)
    await #expect(throws: SignError.self) {
        try await ApplePlan.steps(app: mac.path, platform: .mac, profiles: [], certificate: certificateSHA, kinds: [.developerID],
                                  additions: try AppleAdditions(keychainGroups: ["\(team).com.example.shared"])) { _ in [:] }
    }
}

// Manager's review of #20: groups from a file, never argv; BuildVariant and repeated keys refused; the default keychain
// group the profile's; stamp saying no values; --unsigned refusing additions.

@Test func groupsComeFromAFileAndEachKeyOnce() throws {
    let groups = try AppleAdditions.groups(json: Data(#"{"app": ["\#(team).shared"], "keychain": ["\#(team).com.example.shared"]}"#.utf8))
    #expect(groups.app == ["\(team).shared"] && groups.keychain == ["\(team).com.example.shared"])
    #expect(try AppleAdditions.groups(json: Data(#"{"keychain": []}"#.utf8)).app.isEmpty)
    for bad in [#"{"apps": ["x"]}"#, #"{"app": "\#(team).shared"}"#, #"{"app": [3]}"#, #"["\#(team).shared"]"#,
                #"{"app": ["\#(team).one"], "app": ["\#(team).two"]}"#] {
        do {
            _ = try AppleAdditions.groups(json: Data(bad.utf8))
            Issue.record("\(bad) taken")
        } catch {
            #expect(!"\(error)".contains("shared") && !"\(error)".contains(".one") && !"\(error)".contains(".two"))
        }
    }
    // A key twice: JSONSerialization would keep the last, silently; refused, naming the key alone.
    #expect(throws: SignError.self) { try AppleAdditions.infoPlist(json: Data(#"{"A": "one", "B": {"A": "x"}, "A": "two"}"#.utf8)) }
    #expect(AppleAdditions.repeatedKey(Data(#"{"A": "one", "B": {"A": "x"}, "C": "A:"}"#.utf8)) == nil)
    #expect(AppleAdditions.repeatedKey(Data(#"{"A\"": 1, "A\"": 2}"#.utf8)) == "A\"")
}

@Test func buildVariantIsTheToolsAndCantBeAdded() throws {
    let values = try AppleAdditions.infoPlist(json: Data(#"{"BuildVariant": "Production"}"#.utf8))
    #expect(throws: SignError.self) { try AppleAdditions(infoPlist: values) }
}

@Test func theDefaultKeychainGroupIsTheProfilesAndOneItRefusesIsSaidByCount() throws {
    let mac = try profile("com.example.Mac", mac: true, kind: .developerID,
                          entitlements: ["keychain-access-groups": ["\(team).*", "OTHERTEAM1.*"]])
    // Its own entitlements, no keychain group: the profile's prefix first, not the added group's team.
    let added = try AppleAdditions(keychainGroups: ["OTHERTEAM1.shared"])
    let made = try ApplePlan.entitlements(own: ["com.apple.security.app-sandbox": true], bundle: "com.example.Mac", profile: mac, additions: added)
    #expect(made["keychain-access-groups"] as? [String] == ["\(team).com.example.Mac", "OTHERTEAM1.shared"])
    // A keychain group no profile pattern allows: refused, by count.
    let stray = try AppleAdditions(keychainGroups: ["ZZZZZZZZZZ.secret"])
    do {
        _ = try ApplePlan.entitlements(own: [:], bundle: "com.example.Mac", profile: mac, additions: stray)
        Issue.record("a keychain group the profile doesn't allow was taken")
    } catch let error as SignError {
        #expect("\(error)".contains("1 keychain group added") && !"\(error)".contains("secret") && !"\(error)".contains("ZZZZ"))
    }
}

@Test func stampAddsTheKeysAndSaysNoneOfTheirValues() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("build-tools-stamp-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Mac.app")
    try makeBundle(app, id: "com.example.Mac", mac: true)
    let infoPath = app.appendingPathComponent("Contents/Info.plist").path
    let additions = try AppleAdditions(infoPlist: ["SharedClientID": .string("client-secret-value"),
                                                    "Distributors": .strings(["com.example.hidden"])])
    let signer = try AppleSigner(rcodesign: nil, dmg: nil, ipaKinds: [.development], variant: "Production", app: nil, additions: additions)
    let said = try signer.stamp(app.path, info: infoPath)
    let info = try #require(AppleBundle.info(app.path))
    #expect(info["SharedClientID"] as? String == "client-secret-value")
    #expect(info["Distributors"] as? [String] == ["com.example.hidden"])
    #expect(info["BuildVariant"] as? String == "Production" && info["CFBundleIdentifier"] as? String == "com.example.Mac")
    #expect(said == ["   BuildVariant: Production", "   Info.plist: 2 keys added"])
    #expect(!said.joined().contains("client-secret-value") && !said.joined().contains("hidden"))
    // Its own value already there, another: refused, the plist left as it was.
    let other = try AppleSigner(rcodesign: nil, dmg: nil, ipaKinds: [.development], variant: nil, app: nil,
                                additions: try AppleAdditions(infoPlist: ["SharedClientID": .string("another")]))
    #expect(throws: SignError.self) { try other.stamp(app.path, info: infoPath) }
    #expect(AppleBundle.info(app.path)?["SharedClientID"] as? String == "client-secret-value")
}

@Test func unsignedCopiesRefuseAdditions() async throws {
    let signer = try AppleSigner(rcodesign: nil, dmg: nil, ipaKinds: [.development], variant: nil, app: nil,
                                 additions: try AppleAdditions(appGroups: ["\(team).shared"]))
    await #expect(throws: SignError.self) { try await signer.copyUnsigned(["/nonexistent.zip"], out: "/tmp/never") }
}
