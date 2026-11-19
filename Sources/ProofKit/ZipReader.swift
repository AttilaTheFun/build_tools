import Foundation

/// A zip's entries, read from its central directory: stored or deflated (what Python's zipfile and `zip` write), no
/// zip64, no encryption. Enough for a proof.zip.
struct ZipReader {
    struct Failed: Error, CustomStringConvertible {
        let description: String
    }

    private struct Entry {
        var method: UInt16
        var compressed: Int
        var size: Int
        var offset: Int
    }

    private let data: [UInt8]
    private var entries: [String: Entry] = [:]

    init(_ data: Data) throws {
        self.data = [UInt8](data)
        // The end of central directory record: its signature, within the last 64 KiB and 22 bytes.
        let bytes = self.data
        guard bytes.count >= 22 else { throw Failed(description: "not a zip") }
        var end = -1
        for at in stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65_535), by: -1)
        where u32(at) == 0x0605_4B50 {
            end = at
            break
        }
        guard end >= 0 else { throw Failed(description: "not a zip (no end of its directory)") }
        let count = Int(u16(end + 10))
        var at = Int(u32(end + 16))
        for _ in 0..<count {
            guard at + 46 <= bytes.count, u32(at) == 0x0201_4B50 else { throw Failed(description: "a damaged zip directory") }
            let method = u16(at + 10)
            let compressed = Int(u32(at + 20)), size = Int(u32(at + 24))
            let nameLength = Int(u16(at + 28)), extraLength = Int(u16(at + 30)), commentLength = Int(u16(at + 32))
            let offset = Int(u32(at + 42))
            guard at + 46 + nameLength <= bytes.count else { throw Failed(description: "a damaged zip directory") }
            let name = String(decoding: bytes[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(method: method, compressed: compressed, size: size, offset: offset)
            at += 46 + nameLength + extraLength + commentLength
        }
    }

    private func u16(_ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
    private func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }

    /// An entry's bytes; nil where the zip has none of that name.
    func read(_ name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        let header = entry.offset
        guard header + 30 <= data.count, u32(header) == 0x0403_4B50 else { throw Failed(description: "\(name)'s header is damaged") }
        let start = header + 30 + Int(u16(header + 26)) + Int(u16(header + 28))
        guard start + entry.compressed <= data.count else { throw Failed(description: "\(name) is cut short") }
        let stored = Data(data[start..<(start + entry.compressed)])
        switch entry.method {
        case 0: return stored
        case 8: return try Inflate.inflate(stored, raw: true, expected: entry.size)
        default: throw Failed(description: "\(name) is compressed by method \(entry.method)")
        }
    }
}
