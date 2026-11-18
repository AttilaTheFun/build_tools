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
        // Signing a build with its release keys, in its CI job: an Android app now, Apple's next.
        .executable(name: "sign", targets: ["sign"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2"),
        // FilePath off Apple's platforms (Subprocess takes System's on a Mac, SystemPackage's elsewhere).
        .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
    ],
    targets: [
        .target(
            name: "SignKit",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux])),
            ]),
        .executableTarget(
            name: "sign",
            dependencies: ["SignKit", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "SignKitTests", dependencies: ["SignKit"]),
    ],
    swiftLanguageModes: [.v6]
)
