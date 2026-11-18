import Foundation
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif

/// A program this tool runs (apksigner's java, rcodesign, dmg): its path and arguments, never a secret among them
/// (keys and passwords go by file), its output collected.
public struct Tool: Sendable {
    public let path: String

    public init(_ path: String) {
        self.path = path
    }

    public struct Result: Sendable {
        public var ok: Bool
        public var output: String
        public var error: String
    }

    /// Runs it to its end, its output and error kept (at most 16 MiB each).
    public func run(_ arguments: [String]) async throws -> Result {
        let result = try await Subprocess.run(.path(FilePath(path)), arguments: Arguments(arguments),
                                              output: .string(limit: 16 << 20), error: .string(limit: 16 << 20))
        var ok = false
        if case .exited(0) = result.terminationStatus { ok = true }
        return Result(ok: ok, output: result.standardOutput ?? "", error: result.standardError ?? "")
    }
}
