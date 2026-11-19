import Foundation
import Testing
@testable import ProofKit

// tests-proof: a log's totals read (XCTest's, Swift Testing's), the proof written as Reviews reads a library's, and
// zipped as a release's proof.zip.

private let xctest = """
Test Suite 'All tests' started at 2026-11-19 07:00:00.000
Test Suite 'All tests' passed at 2026-11-19 07:00:01.000
\t Executed 12 tests, with 0 failures (0 unexpected) in 0.5 (0.5) seconds
"""

private let swiftTestingPassed = """
◇ Test run started.
✔ Test aPNGIsDecoded() passed after 0.005 seconds.
✔ Test run with 9 tests in 0 suites passed after 0.020 seconds.
"""

private let swiftTestingFailed = """
✔ Test one() passed after 0.005 seconds.
✘ Test two() recorded an issue at X.swift:3:5: Expectation failed
✘ Test two() failed after 0.006 seconds with 1 issue.
✘ Test run with 2 tests in 0 suites failed after 0.010 seconds with 1 issue.
"""

@Test func aLogsTotalsAreRead() {
    #expect(TestsProof.counts(xctest)! == (12, 0))
    #expect(TestsProof.counts(swiftTestingPassed)! == (9, 0))
    #expect(TestsProof.counts(swiftTestingFailed)! == (2, 1))
    #expect(TestsProof.counts(xctest + "\n" + swiftTestingPassed)! == (21, 0), "swift test runs both")
    #expect(TestsProof.counts("Compiling…\nerror: build failed") == nil)
}

@Test func theProofIsWrittenAndZipped() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tests-proof-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let linux = folder.appendingPathComponent("linux.log"), macos = folder.appendingPathComponent("macos.log")
    try Data((xctest + "\n" + swiftTestingPassed).utf8).write(to: linux)
    try Data(swiftTestingFailed.utf8).write(to: macos)
    let out = folder.appendingPathComponent("proof").path
    let (proof, passed) = try TestsProof.write([TestsProof.Run(id: "linux", title: "Linux (Swift 6.4.2)", log: linux.path),
                                                TestsProof.Run(id: "macos", title: "macOS", log: macos.path)],
                                               to: out, app: "build_tools", version: "0.3.0",
                                               environment: ["GITHUB_REPOSITORY": "o/build_tools", "GITHUB_SHA": "abc", "GITHUB_RUN_ID": "7"])
    #expect(!passed, "macOS failed")
    let items = try #require(proof["items"] as? [[String: Any]])
    #expect(items.map { $0["result"] as? String } == ["passed", "failed"])
    #expect(items[0]["tests"] as? Int == 21 && items[0]["log"] as? String == "logs/linux.txt")
    #expect(proof["format"] as? Int == 2 && proof["run"] as? Int == 7 && proof["commit"] as? String == "abc")
    let zipped = try ZipReader(try ZipWriter.zip(folder: out))
    let json = try #require(try zipped.read("proof.json"))
    #expect((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["app"] as? String == "build_tools")
    #expect(try zipped.read("logs/macos.txt") == Data(swiftTestingFailed.utf8))
    // The proof-diff of it with itself: unchanged.
    let read = try ProofDiff.Proof(data: try ZipWriter.zip(folder: out))
    let diff = ProofDiff.manifest(read, base: [:], baseProof: read, note: nil)
    #expect(diff["counts"] as? [String: Int] == ["added": 0, "removed": 0, "changed": 0, "unchanged": 2])
    #expect(TestsProof.Run(spec: "id=Title=path/to.log")?.title == "Title" && TestsProof.Run(spec: "nolog") == nil)
}
