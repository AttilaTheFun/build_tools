import CZlib
import Foundation

/// A repository's proof when it has no apps: its tests' results (Logan, 2026-11-19: every release has a proof, "even
/// if it's just tests"). Format 2's proof.json with a `tests` item for each run of the tests (a platform, a target),
/// each with its counts and its log, as agent_protocol's tools/ci/tests_proof.py made it, and as Reviews shows it.
public enum TestsProof {
    /// One run's tests: its id and title, and its log.
    public struct Run: Sendable {
        public var id: String
        public var title: String
        public var log: String

        public init(id: String, title: String, log: String) {
            self.id = id
            self.title = title
            self.log = log
        }

        /// `<id>=<title>=<log>`.
        public init?(spec: String) {
            let parts = spec.split(separator: "=", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[0].isEmpty, !parts[2].isEmpty else { return nil }
            self.init(id: parts[0], title: parts[1], log: parts[2])
        }
    }

    /// The tests a log ran and how many failed, XCTest's and Swift Testing's summed; nil where it says neither's
    /// totals (a run that ended early proves nothing).
    public static func counts(_ log: String) -> (tests: Int, failures: Int)? {
        var tests = 0, failures = 0, seen = false
        // XCTest: each bundle's "All tests" (or "Selected tests", filtered) suite, then its totals.
        var closing = false
        let executed = try! NSRegularExpression(pattern: #"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?"#)
        let suite = try! NSRegularExpression(pattern: #"Test Suite '(All|Selected) tests' (passed|failed) at "#)
        // Swift Testing: its run's line, and each test that failed.
        let run = try! NSRegularExpression(pattern: #"Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed)"#)
        let failed = try! NSRegularExpression(pattern: #"✘ Test (.+?) failed after "#)
        var failedTests = Set<String>()
        var swiftTestingFailed = false
        func groups(_ regex: NSRegularExpression, _ line: String) -> [String]? {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range) else { return nil }
            return (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
            }
        }
        for line in log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if groups(suite, line) != nil {
                closing = true
                continue
            }
            if closing, let found = groups(executed, line) {
                tests += Int(found[1]) ?? 0
                failures += Int(found[3]) ?? 0
                seen = true
                closing = false
                continue
            }
            if let found = groups(run, line) {
                tests += Int(found[1]) ?? 0
                swiftTestingFailed = swiftTestingFailed || found[2] == "failed"
                seen = true
                continue
            }
            if let found = groups(failed, line), !found[1].hasPrefix("run with") { failedTests.insert(found[1]) }
        }
        guard seen else { return nil }
        failures += max(failedTests.count, swiftTestingFailed ? 1 : 0)
        return (tests, failures)
    }

    /// The proof of `runs` in `folder`: proof.json, and each log at logs/<id>.txt. Whether they all passed (one
    /// with no tests, or whose totals its log never said, didn't).
    @discardableResult
    public static func write(_ runs: [Run], to folder: String, app: String, version: String,
                             environment: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date()) throws -> (proof: [String: Any], passed: Bool) {
        let logs = (folder as NSString).appendingPathComponent("logs")
        try FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        var items: [[String: Any]] = []
        for run in runs {
            guard let data = FileManager.default.contents(atPath: run.log) else { throw ProofDiff.Failed("no log at \(run.log)") }
            let name = "logs/\(run.id.replacingOccurrences(of: "/", with: "-")).txt"
            try data.write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent(name)))
            let found = counts(String(decoding: data, as: UTF8.self))
            let (tests, failures) = found ?? (0, 1)
            // None run is no pass: a filter that matched nothing proves nothing.
            items.append(["id": run.id, "kind": "tests", "title": run.title, "result": found != nil && failures == 0 && tests > 0 ? "passed" : "failed",
                          "tests": tests, "failures": failures, "log": name])
        }
        let made = ISO8601DateFormatter()
        made.formatOptions = [.withInternetDateTime]
        let proof: [String: Any] = [
            "format": 2, "app": app, "version": version,
            "repository": environment["GITHUB_REPOSITORY"] ?? "", "commit": environment["GITHUB_SHA"] ?? "",
            "run": Int(environment["GITHUB_RUN_ID"] ?? "") ?? 0, "made": made.string(from: now), "items": items,
        ]
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent("proof.json")))
        return (proof, items.allSatisfy { $0["result"] as? String == "passed" })
    }
}

/// A zip of a folder's files (deflated), as a release's proof.zip: proof.json and what it names.
public enum ZipWriter {
    public static func zip(folder: String) throws -> Data {
        guard let walk = FileManager.default.enumerator(atPath: folder) else { throw ProofDiff.Failed("no folder at \(folder)") }
        var files: [String] = []
        for case let relative as String in walk {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(relative), isDirectory: &isFolder), !isFolder.boolValue {
                files.append(relative)
            }
        }
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) -> [UInt8] { u16(v & 0xFFFF) + u16(v >> 16 & 0xFFFF) }
        var out: [UInt8] = [], directory: [UInt8] = []
        for name in files.sorted() {
            guard let data = FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent(name)) else { continue }
            let body = [UInt8](try Inflate.deflate(data, raw: true))
            let crc = data.withUnsafeBytes { Int(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            let offset = out.count, nameBytes = Array(name.utf8)
            out += u32(0x0403_4B50) + u16(20) + u16(0x0800) + u16(8) + u16(0) + u16(0x21) + u32(crc) + u32(body.count) + u32(data.count)
                + u16(nameBytes.count) + u16(0) + nameBytes + body
            directory += u32(0x0201_4B50) + u16(20) + u16(20) + u16(0x0800) + u16(8) + u16(0) + u16(0x21) + u32(crc) + u32(body.count)
                + u32(data.count) + u16(nameBytes.count) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0o100644 << 16) + u32(offset) + nameBytes
        }
        let start = out.count
        out += directory
        out += u32(0x0605_4B50) + u16(0) + u16(0) + u16(files.count) + u16(files.count) + u32(directory.count) + u32(start) + u16(0)
        return Data(out)
    }
}
