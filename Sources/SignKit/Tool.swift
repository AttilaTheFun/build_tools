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

    /// The program of that name on PATH; nil when there's none.
    public static func find(_ name: String) -> Tool? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for folder in path.split(separator: ":") {
            let candidate = (String(folder) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return Tool(candidate) }
        }
        return nil
    }

    /// Runs it to its end (in `directory`, else here), its output and error kept (at most 16 MiB each).
    public func run(_ arguments: [String], in directory: String? = nil) async throws -> Result {
        let result = try await Subprocess.run(.path(FilePath(path)), arguments: Arguments(arguments),
                                              workingDirectory: directory.map { FilePath($0) },
                                              output: .string(limit: 16 << 20), error: .string(limit: 16 << 20))
        var ok = false
        if case .exited(0) = result.terminationStatus { ok = true }
        return Result(ok: ok, output: result.standardOutput ?? "", error: result.standardError ?? "")
    }
}
