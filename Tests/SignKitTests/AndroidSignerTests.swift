import Foundation
import Testing
@testable import SignKit

// sign android's checks (AndroidSigner): the key's name, the pin, and apksigner's verify output read as
// android_sign.sh read it.

private let pin = "15b0ff4ba3bdd9eee725c8a2e06d11513055b064de899a09243bfa5370500959"

@Test func aKeysNameIsLowercaseLettersDigitsAndDashes() {
    #expect(AndroidSigner.validApp("storybook") && AndroidSigner.validApp("visor-2"))
    for bad in ["", "Storybook", "-x", "a b", "a/b", String(repeating: "a", count: 42)] {
        #expect(!AndroidSigner.validApp(bad), "\(bad)")
    }
}

@Test func aPinIsASHA256ColonsOrNot() {
    #expect(AndroidSigner.normalizedPin("15:B0:FF:4B:A3:BD:D9:EE:E7:25:C8:A2:E0:6D:11:51:30:55:B0:64:DE:89:9A:09:24:3B:FA:53:70:50:09:59") == pin)
    #expect(AndroidSigner.normalizedPin(pin.uppercased()) == pin)
    #expect(AndroidSigner.normalizedPin("15b0") == nil)
    #expect(AndroidSigner.normalizedPin(String(repeating: "z", count: 64)) == nil)
}

private func verifyOutput(v3: Bool = true, signers: [String] = [pin]) -> String {
    var lines = ["Verifies", "Verified using v1 scheme (JAR signing): false", "Verified using v2 scheme (APK Signature Scheme v2): true",
                 "Verified using v3 scheme (APK Signature Scheme v3): \(v3)", "Number of signers: \(signers.count)"]
    for (index, digest) in signers.enumerated() {
        lines.append("Signer #\(index + 1) certificate DN: CN=Storybook, O=Logan Shire")
        lines.append("Signer #\(index + 1) certificate SHA-256 digest: \(digest)")
    }
    return lines.joined(separator: "\n") + "\n"
}

private let v2 = "Verifies\nVerified using v2 scheme (APK Signature Scheme v2): true\n"

@Test func aSignedAPKIsV3AndV2OneSignerThePinnedOne() throws {
    #expect(try AndroidSigner.checked(verify: verifyOutput(), verifyV2: v2, pin: pin, app: "storybook") == pin)
    #expect(throws: SignError.self) { try AndroidSigner.checked(verify: verifyOutput(v3: false), verifyV2: v2, pin: pin, app: "storybook") }
    #expect(throws: SignError.self) { try AndroidSigner.checked(verify: verifyOutput(), verifyV2: "Verifies\n", pin: pin, app: "storybook") }
    #expect(throws: SignError.self) { try AndroidSigner.checked(verify: verifyOutput(signers: [pin, pin]), verifyV2: v2, pin: pin, app: "storybook") }
    let other = String(repeating: "a", count: 64)
    #expect(throws: SignError.self) { try AndroidSigner.checked(verify: verifyOutput(signers: [other]), verifyV2: v2, pin: pin, app: "storybook") }
}

@Test func aKeyFromTheEnvironmentIsReadOnceAndUnset() {
    setenv("BUILD_TOOLS_TEST_SECRET", "s3cret", 1)
    #expect(SecretEnvironment.take("BUILD_TOOLS_TEST_SECRET") == "s3cret")
    #expect(ProcessInfo.processInfo.environment["BUILD_TOOLS_TEST_SECRET"] == nil)
    #expect(SecretEnvironment.take("BUILD_TOOLS_TEST_SECRET") == nil)
}

@Test func theKeysFolderIsThisUsersAloneAndGoes() throws {
    let folder = try SecretsFolder(prefix: "build-tools-test")
    let file = try folder.write("key", Data("k".utf8))
    let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    folder.remove()
    #expect(!FileManager.default.fileExists(atPath: folder.path))
}

@Test func whetherAKeyIsHereIsToldWithNothingRead() throws {
    // --skip-missing-keys: both of its secrets, in the environment or the folder; neither read nor unset.
    let folder = try SecretsFolder(prefix: "build-tools-test")
    defer { folder.remove() }
    let apksigner = try folder.write("apksigner.jar", Data())
    let signer = try AndroidSigner(app: "storybook", pin: pin, java: "/usr/bin/true", apksigner: apksigner)
    #expect(!signer.hasKeys(.folder(folder.path)))
    _ = try folder.write("android-storybook-keystore", Data("k".utf8))
    #expect(!signer.hasKeys(.folder(folder.path)))
    _ = try folder.write("android-storybook-password", Data("p".utf8))
    #expect(signer.hasKeys(.folder(folder.path)))
    #expect(!signer.hasKeys(.environment, environment: ["ANDROID_SIGNING_KEYSTORE": "a"]))
    #expect(!signer.hasKeys(.environment, environment: ["ANDROID_SIGNING_KEYSTORE": "a", "ANDROID_SIGNING_PASSWORD": ""]))
    #expect(signer.hasKeys(.environment, environment: ["ANDROID_SIGNING_KEYSTORE": "a", "ANDROID_SIGNING_PASSWORD": "b"]))
}

@Test func theSignedAPKIsMadeOnDiskNotTheKeysTmpfs() throws {
    // Isomer, 2026-11-20: a 157 MB APK filled a job container's 64 MB /dev/shm. The APK is made in the temporary
    // directory, the owner's alone; only the keys are on the tmpfs.
    let work = try AndroidSigner.workFolder()
    defer { try? FileManager.default.removeItem(atPath: work) }
    #expect(!work.hasPrefix("/dev/shm"))
    #expect(work.hasPrefix(NSTemporaryDirectory()) || work.hasPrefix((NSTemporaryDirectory() as NSString).standardizingPath))
    let mode = try FileManager.default.attributesOfItem(atPath: work)[.posixPermissions] as? Int
    #expect(mode == 0o700)
    let next = try AndroidSigner.workFolder()
    defer { try? FileManager.default.removeItem(atPath: next) }
    #expect(next != work, "a new folder each signing")
}
