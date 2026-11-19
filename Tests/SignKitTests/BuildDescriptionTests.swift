import Foundation
import Testing
@testable import SignKit

// builds.json lines (BuildDescription, BuildsFile, AndroidSigner.badging): what release_assets.sh wrote, read from the
// build itself.

/// A thin 64-bit Mach-O with one load command, LC_UUID.
private func machO(uuid: [UInt8]) -> [UInt8] {
    func u32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
    return u32(0xFEEDFACF) + u32(0x0100000C) + u32(0) + u32(2) + u32(1) + u32(24) + u32(0) + u32(0) + u32(0x1B) + u32(24) + uuid
}

private let uuidBytes: [UInt8] = Array(0x10...0x1F).map(UInt8.init)
private let uuidText = "10111213-1415-1617-1819-1A1B1C1D1E1F"

@Test func anExecutablesUUIDIsRead() {
    #expect(BuildDescription.executableUUID(data: machO(uuid: uuidBytes)) == uuidText)
    // A fat one: its arm64 slice.
    func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    let slice = machO(uuid: uuidBytes)
    let fat = be32(0xCAFEBABE) + be32(1) + be32(0x0100000C) + be32(0) + be32(28) + be32(slice.count) + be32(0) + slice
    #expect(BuildDescription.executableUUID(data: fat) == uuidText)
    #expect(BuildDescription.executableUUID(data: [0, 1, 2, 3]) == nil)
}

@Test func anICNSsLargestPNGIsItsIcon() {
    func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    func png(width: Int) -> [UInt8] { [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + be32(13) + Array("IHDR".utf8) + be32(width) + be32(width) + [8, 6, 0, 0, 0] }
    let small = png(width: 32), large = png(width: 512)
    let entries = Array("ic05".utf8) + be32(8 + small.count) + small + Array("ic09".utf8) + be32(8 + large.count) + large
    let icns = Array("icns".utf8) + be32(8 + entries.count) + entries
    #expect(BuildDescription.largestPNG(inICNS: icns) == Data(large))
}

@Test func aMacAppIsDescribedFromItself() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("describe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Lab.app/Contents")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "com.example.Lab", "CFBundleExecutable": "Lab", "CFBundleShortVersionString": "1.2.3",
                               "CFBundleVersion": "45", "CFBundleName": "Lab", "CFBundleIconFile": "AppIcon",
                               "CFBundleURLTypes": [["CFBundleURLSchemes": ["lab"]]]]
    try PlistXML.data(info).write(to: app.appendingPathComponent("Info.plist"))
    try Data(machO(uuid: uuidBytes)).write(to: app.appendingPathComponent("MacOS/Lab"))
    func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + be32(13) + Array("IHDR".utf8) + be32(64) + be32(64) + [8, 6, 0, 0, 0]
    try Data(Array("icns".utf8) + be32(16 + png.count) + Array("ic07".utf8) + be32(8 + png.count) + png).write(to: app.appendingPathComponent("Resources/AppIcon.icns"))
    let package = root.appendingPathComponent("Storybook-Lab-1.2.3-macos.zip")
    try Data("zip".utf8).write(to: package)
    let line = try BuildDescription.apple(package: package.path, app: root.appendingPathComponent("Lab.app").path, platform: "macos",
                                          name: "Storybook Lab", commit: "abc").object
    #expect(line["bundleID"] as? String == "com.example.Lab" && line["app"] as? String == "Storybook Lab")
    #expect(line["version"] as? String == "1.2.3" && line["buildNumber"] as? String == "45" && line["variant"] as? String == "Alpha")
    #expect(line["executableUUID"] as? String == uuidText && line["commit"] as? String == "abc" && line["size"] as? Int == 3)
    #expect(line["urlSchemes"] as? [String] == ["lab"] && line["icon"] as? String == "Storybook-Lab-1.2.3-icon.png")
    #expect(FileManager.default.contents(atPath: root.appendingPathComponent("Storybook-Lab-1.2.3-icon.png").path) == Data(png))
    #expect(BuildDescription.assetName(app: "Storybook Lab", version: "1.2.3", platform: "ios", ext: "ipa") == "Storybook-Lab-1.2.3-ios.ipa")
}

@Test func buildsJSONIsMergedAFilesLineReplaced() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("builds-\(UUID().uuidString).json").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    try BuildsFile.merge([["file": "A-1-ios.ipa", "sha256": "old"], ["file": "A-1-macos.zip", "sha256": "m"]], into: path)
    try BuildsFile.merge([["file": "A-1-ios.ipa", "sha256": "new"]], into: path)
    let all = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: Any]])
    #expect(all.count == 2)
    #expect(all.first { $0["file"] as? String == "A-1-ios.ipa" }?["sha256"] as? String == "new")
}

@Test func aapt2sBadgingIsRead() throws {
    let output = """
    package: name='com.example.storybook' versionCode='58' versionName='0.58.0' platformBuildVersionName='15'
    sdkVersion:'23'
    application-label:'Storybook'
    application: label='Storybook' icon='res/mipmap/ic_launcher.png'
    """
    let read = try AndroidSigner.badging(output)
    #expect(read.package == "com.example.storybook" && read.versionCode == "58" && read.versionName == "0.58.0" && read.label == "Storybook")
    #expect(throws: SignError.self) { try AndroidSigner.badging("nothing") }
    let android = BuildDescription(file: "Storybook-0.58.0-android.apk", bundleID: read.package, app: "Storybook", platform: "android",
                                   version: read.versionName, buildNumber: read.versionCode, variant: "Alpha", commit: "", executableUUID: "",
                                   size: 1, sha256: "x", icon: nil, urlSchemes: []).object
    #expect(android["urlSchemes"] as? [String] == [] && android["icon"] == nil)
}
