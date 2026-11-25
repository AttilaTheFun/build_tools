// swift-tools-version: 6.2
// build_tools: the build tools Logan's repositories share (isomer, playground, visor, shireworks), as executables a
// repository takes through rules_swift_package_manager at a tagged version, built from source and cached (Logan,
// 2026-11-18: tools in Swift, not shell or Python; ~/Developer/AGENTS.md). A signer is built by Bazel with no secret in
// the environment, then run directly with its keys: never `bazel run` with them (README.md).
import PackageDescription

let package = Package(
    name: "build_tools",
    platforms: [.macOS(.v15)],
    products: [
        // Signing a build with its release keys, in its CI job: an Android app, a Mac app or an iPhone app.
        .executable(name: "sign", targets: ["sign"]),
        // A proof's comparison with the release before's (proof-diff.json), as Reviews reads it.
        .executable(name: "proof-diff", targets: ["proof-diff"]),
        // A repository's proof of its tests' results, when it has no apps.
        .executable(name: "tests-proof", targets: ["tests-proof"]),
        // A release's steps in its CI job: the build's version, the line's check, the draft and its assets.
        .executable(name: "release", targets: ["release"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.2"),
        // SHA-1 (a profile's certificates) and SHA-256 (builds.json): CryptoKit's API on every platform.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.10.0"..<"6.0.0"),
        // FilePath off Apple's platforms (Subprocess takes System's on a Mac, SystemPackage's elsewhere).
        .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "SignKit",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux])),
            ]),
        .executableTarget(
            name: "sign",
            dependencies: ["SignKit", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "SignKitTests", dependencies: ["SignKit"]),
        // zlib, the system's (a PNG's pixels, a zip's entries): Linux has no Compression.
        .systemLibrary(name: "CZlib", providers: [.apt(["zlib1g-dev"]), .brew(["zlib"])]),
        .target(
            name: "ProofKit",
            dependencies: [
                "CZlib",
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .executableTarget(
            name: "proof-diff",
            dependencies: ["ProofKit", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .executableTarget(
            name: "tests-proof",
            dependencies: ["ProofKit", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "ProofKitTests", dependencies: ["ProofKit"]),
        // GitHub's REST API by URLSession (FoundationNetworking on Linux), with the job's token.
        .target(name: "ReleaseKit"),
        .executableTarget(
            name: "release",
            dependencies: ["ReleaseKit", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "ReleaseKitTests", dependencies: ["ReleaseKit"]),
    ],
    swiftLanguageModes: [.v6]
)
