import ArgumentParser
import BazelCIKit
import Foundation

/// `ci-bazel`: Bazel in a CI container, with Nimbus' settings for the runner.
@main
struct CIBazelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ci-bazel",
        abstract: "Bazel in a CI container: build, test or package, with Nimbus' settings for the runner.",
        usage: """
        ci-bazel [--bazelrc <file>] <build|test|…> <bazel arguments…>
        ci-bazel [--bazelrc <file>] package <folder> <bazel arguments…>
        """,
        discussion: """
        Runs `bazel <verb> --keep_going <arguments>` in the current folder (the checkout), with a bazelrc from \
        `nimbus job bazel-config` (the downloader config for the Xcode SDK and the ported tools, the runner's size, \
        --config=apple_on_linux) given as --bazelrc, or the file --bazelrc names instead. The log says the container's \
        CPUs and memory, and how long the build took and its peak memory. The exit status is Bazel's.

        `package` builds, then copies the files of the targets into <folder>, which must be in the checkout (its files \
        are replaced). Its options (words that start with `-`, each one word: `--compilation_mode=opt`) apply to the \
        build and to finding its files; the other words are the targets.

        Builds in a Linux container only: where there is no Nimbus runner, lease a container and run it there.
        """)

    @Option(help: "A bazelrc to use instead of asking Nimbus for one.")
    var bazelrc: String?

    @Argument(parsing: .captureForPassthrough, help: "The Bazel command and its arguments (package: its folder first).")
    var arguments: [String] = []

    func run() async throws {
        guard let verb = arguments.first else { throw ValidationError("a Bazel command is needed: build, test, package …") }
        let rest = Array(arguments.dropFirst())
        let tool = CIBazel(bazelrc: bazelrc)
        let status: Int32
        if verb == "package" {
            guard let folder = rest.first else { throw ValidationError("package needs a folder: ci-bazel package <folder> <bazel arguments…>") }
            status = try await tool.package(folder: folder, arguments: Array(rest.dropFirst()))
        } else {
            status = try await tool.run(verb: verb, arguments: rest)
        }
        if status != 0 { throw ExitCode(status) }
    }
}
