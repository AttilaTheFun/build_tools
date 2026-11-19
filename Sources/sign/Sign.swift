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

    @Option(help: "The iPhone app's profile kinds, in order (ad-hoc,development): development (development's identity), ad-hoc, app-store or enterprise (distribution's); the first with its identity here and a profile for every bundle.")
    var ipaKind: String = "development"

    @Flag(help: "Skip, saying so, a package whose platform's keys aren't here, rather than refusing.")
    var skipMissingKeys = false

    @Option(help: "Each app's BuildVariant set before it's signed (Production, for a published release's promotion).")
    var variant: String?

    @Option(help: "The app's name across platforms: outputs named <App>-<version>-<platform>.<ext>.")
    var app: String?

    @Option(help: "A file each output's builds.json line is appended to, as one line of JSON.")
    var describe: String?

    @Option(help: "builds.json: each output's line merged into its array (one for the same file replaced).")
    var builds: String?

    @Option(help: "The commit the builds are of, in their lines (default: GITHUB_SHA).")
    var commit: String?

    @Flag(help: "Copy the packages as built, unsigned (an experiment's, with no keys): named, described, not signed.")
    var unsigned = false

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
        var source: AppleSigner.Keys?
        switch (keyFromEnv, keys, unsigned) {
        case (false, nil, true): source = nil
        case (true, nil, false): source = .environment
        case (false, let folder?, false): source = .folder(folder)
        case (_, _, true): throw ValidationError("--unsigned takes no keys")
        default: throw ValidationError("the keys come from one place: --key-from-env, or --keys <folder>")
        }
        let kinds = ipaKind.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.compactMap(AppleSigner.IPAKind.init(rawValue:))
        guard !kinds.isEmpty, kinds.count == ipaKind.split(separator: ",").count else {
            throw ValidationError("--ipa-kind is one or more of \(AppleSigner.IPAKind.allCases.map(\.rawValue).joined(separator: ", ")), comma-separated")
        }
        do {
            let signer = try AppleSigner(rcodesign: rcodesign, dmg: dmg, ipaKinds: kinds, variant: variant, app: app,
                                         skipMissingKeys: skipMissingKeys, commit: commit)
            let signed: [AppleSigner.Signed]
            if let source {
                signed = try await signer.sign(packages, out: out, keys: source)
            } else {
                signed = try await signer.copyUnsigned(packages, out: out)
            }
            try record(signed.map(\.description.object), describe: describe, builds: builds)
            for output in signed { print("\(unsigned ? "Copied" : "Signed"): \((output.path as NSString).lastPathComponent)") }
        } catch let error as SignError {
            FileHandle.standardError.write(Data("sign apple: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }
}

/// Lines written as asked: each appended to `describe` as a line of JSON, and merged into the `builds` array.
func record(_ lines: [[String: Any]], describe: String?, builds: String?) throws {
    if let describe {
        var data = Data()
        for line in lines { data += try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) + Data("\n".utf8) }
        if !FileManager.default.fileExists(atPath: describe) { _ = FileManager.default.createFile(atPath: describe, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: describe) else { throw SignError("\(describe) can't be written") }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }
    if let builds { try BuildsFile.merge(lines, into: builds) }
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

    @Option(help: "The repository's own pinned aapt2, to describe the signed APK (its package, version and label).")
    var aapt2: String?

    @Option(help: "The app's name across platforms in its line (default: its label).")
    var name: String?

    @Option(help: "Its line's variant: the channel its signing was decided as (Production for a release's, Alpha for main's).")
    var variant: String = "Alpha"

    @Option(help: "A file the signed APK's builds.json line is appended to, as one line of JSON (needs --aapt2).")
    var describe: String?

    @Option(help: "builds.json: the signed APK's line merged into its array (needs --aapt2).")
    var builds: String?

    @Option(help: "The commit it's of, in its line (default: GITHUB_SHA).")
    var commit: String?

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
            if describe != nil || builds != nil {
                guard let aapt2 else { throw SignError("--describe and --builds read the APK with --aapt2 <the repository's aapt2>") }
                let line = try await AndroidSigner.describe(output, aapt2: aapt2, name: name, variant: variant, commit: commit)
                try record([line.object], describe: describe, builds: builds)
            }
        } catch let error as SignError {
            FileHandle.standardError.write(Data("sign android: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }
}
