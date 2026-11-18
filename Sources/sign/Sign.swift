import ArgumentParser
import Foundation
import SignKit

/// `sign`: a build signed with its release keys, in its CI job (`bazel run @build_tools//:sign -- android …`).
@main
struct Sign: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign builds with their release keys, in their CI job.",
        subcommands: [Android.self, Apple.self])
}

/// `sign apple`: a Mac app (Developer ID, notarized and stapled, a disk image too) or an iPhone app (its profiles)
/// signed with no Mac, by the repository's own rcodesign.
struct Apple: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign a Mac app's .zip (Developer ID, notarized, stapled) or an iPhone app's .ipa (its profiles), with no Mac.")

    @Flag(help: "The keys from the job's environment (APPLE_DEVELOPER_ID_P12 and the rest: README.md), read once and unset.")
    var keyFromEnv = false

    @Option(help: "A folder holding the keys by their secrets' names (Shireworks' secrets-fetch).")
    var keys: String?

    @Option(help: "The repository's own pinned rcodesign.")
    var rcodesign: String

    @Option(help: "A disk image beside each Mac app, made by this dmg (rules_applecross', pinned by the repository).")
    var dmg: String?

    @Option(help: "The iPhone app's profile kind: development (development's identity), ad-hoc, app-store or enterprise (distribution's).")
    var ipaKind: String = "development"

    @Option(help: "Each app's BuildVariant set before it's signed (Production, for a published release's promotion).")
    var variant: String?

    @Option(help: "The app's name across platforms: outputs named <App>-<version>-<platform>.<ext>.")
    var app: String?

    @Option(help: "A file each output's builds.json line is appended to, as one line of JSON.")
    var describe: String?

    @Option(help: "Where the signed packages go.")
    var out: String

    @Argument(help: "Mac apps' .zip files (one .app at the top) and iPhone apps' .ipa files.")
    var packages: [String]

    func run() async throws {
        // The keys first, before anything runs: none inherited by a process this starts.
        if keyFromEnv, ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] != nil {
            throw ValidationError("--key-from-env isn't for `bazel run`, whose server and build events see the environment: "
                                  + "build sign with no secrets set, then run the binary itself (README.md)")
        }
        let source: AppleSigner.Keys
        switch (keyFromEnv, keys) {
        case (true, nil): source = .environment
        case (false, let folder?): source = .folder(folder)
        default: throw ValidationError("the keys come from one place: --key-from-env, or --keys <folder>")
        }
        guard let kind = AppleSigner.IPAKind(rawValue: ipaKind) else {
            throw ValidationError("--ipa-kind is \(AppleSigner.IPAKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        do {
            let signer = try AppleSigner(rcodesign: rcodesign, dmg: dmg, ipaKind: kind, variant: variant, app: app)
            let signed = try await signer.sign(packages, out: out, keys: source)
            if let describe {
                var lines = Data()
                for output in signed {
                    var line: [String: Any] = output.line
                    line["size"] = output.size
                    lines += try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) + Data("\n".utf8)
                }
                if !FileManager.default.fileExists(atPath: describe) { FileManager.default.createFile(atPath: describe, contents: nil) }
                guard let handle = FileHandle(forWritingAtPath: describe) else { throw SignError("\(describe) can't be written") }
                try handle.seekToEnd()
                try handle.write(contentsOf: lines)
                try handle.close()
            }
            for output in signed { print("Signed: \((output.path as NSString).lastPathComponent)") }
        } catch let error as SignError {
            FileHandle.standardError.write(Data("sign apple: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }
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
        // Never through Bazel with the keys in the environment: its server and build event stream would have them.
        if keyFromEnv, ProcessInfo.processInfo.environment["BUILD_WORKSPACE_DIRECTORY"] != nil {
            throw ValidationError("--key-from-env isn't for `bazel run`, whose server and build events see the environment: "
                                  + "build sign with no secrets set, then run the binary itself (README.md)")
        }
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
