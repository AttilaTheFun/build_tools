import ArgumentParser
import Foundation
import SignKit

/// `sign`: a build signed with its release keys, in its CI job (`bazel run @build_tools//:sign -- android …`).
@main
struct Sign: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign builds with their release keys, in their CI job.",
        subcommands: [Android.self])
}

/// `sign android`: an APK signed with its app's private release key, its certificate checked against the pin.
struct Android: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign an Android app's release APK (v2 and v3) with its key, checked against its certificate's pin.")

    @Option(help: "The key's name: its alias, and its secrets' (android-<app>-keystore, android-<app>-password).")
    var app: String

    @Option(help: "The release certificate's SHA-256 (hex, colons or not), from the workflow.")
    var pin: String

    @Option(help: "The repository's own pinned java.")
    var java: String

    @Option(help: "The repository's own pinned apksigner.jar.")
    var apksigner: String

    @Flag(help: "The key from ANDROID_SIGNING_KEYSTORE (base64 PKCS12) and ANDROID_SIGNING_PASSWORD, read once and unset.")
    var keyFromEnv = false

    @Option(help: "A folder holding android-<app>-keystore and android-<app>-password (Shireworks' secrets-fetch).")
    var keys: String?

    @Argument(help: "The release build, zipaligned.")
    var input: String

    @Argument(help: "Where the signed APK goes.")
    var output: String

    func run() async throws {
        let source: AndroidSigner.Keys
        switch (keyFromEnv, keys) {
        case (true, nil): source = .environment
        case (false, let folder?): source = .folder(folder)
        default: throw ValidationError("the key comes from one place: --key-from-env, or --keys <folder>")
        }
        do {
            let signer = try AndroidSigner(app: app, pin: pin, java: java, apksigner: apksigner)
            let certificate = try await signer.sign(input, to: output, keys: source)
            print("Signed: \((output as NSString).lastPathComponent) (\(app)'s release key, certificate \(certificate))")
        } catch let error as SignError {
            FileHandle.standardError.write(Data("sign android: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }
}
