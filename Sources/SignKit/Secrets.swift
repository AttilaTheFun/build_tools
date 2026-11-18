import Foundation

/// Why a tool stops: said once, on standard error, by the command.
public struct SignError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A folder of its own for keys, readable by this user alone: on a tmpfs (`/dev/shm`) where there is one (Linux, CI's
/// containers), never a disk's. Removed by `remove()`, which the commands call however they end (`defer`).
public final class SecretsFolder: @unchecked Sendable {
    public let path: String

    public init(prefix: String) throws {
        let base: String
        #if os(Linux)
        guard FileManager.default.fileExists(atPath: "/dev/shm") else {
            throw SignError("no /dev/shm here: keys are written to a tmpfs alone")
        }
        base = "/dev/shm"
        #else
        base = NSTemporaryDirectory()
        #endif
        path = (base as NSString).appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// A file of the folder, written readable by this user alone.
    @discardableResult
    public func write(_ name: String, _ data: Data) throws -> String {
        let file = (path as NSString).appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: file, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SignError("\(name) couldn't be written in the keys' folder")
        }
        return file
    }

    public func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// The job's environment, where a public repository's workflow puts its GitHub environment's secrets: each read once,
/// then unset, so no command this tool runs inherits it.
public enum SecretEnvironment {
    /// The variable's value (nil when unset or empty), and the variable unset.
    public static func take(_ name: String) -> String? {
        defer { unsetenv(name) }
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return value
    }
}
