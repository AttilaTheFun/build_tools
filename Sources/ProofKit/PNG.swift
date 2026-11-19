import Foundation

/// A PNG decoded to RGBA rows: 8 bits a channel; grey, grey and alpha, RGB, RGBA or a palette; not interlaced.
struct PNG {
    struct Unreadable: Error, CustomStringConvertible {
        let description: String
    }

    let width: Int
    let height: Int
    /// Each row's RGBA bytes.
    let rows: [[UInt8]]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { throw Unreadable(description: "not a PNG") }
        func u32(_ at: Int) -> Int { Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) }
        var position = 8
        var width = 0, height = 0, depth = -1, color = -1, interlace = -1
        var palette: [UInt8] = [], alpha: [UInt8]?
        var compressed = Data()
        while position + 8 <= bytes.count {
            let length = u32(position)
            let kind = String(decoding: bytes[(position + 4)..<(position + 8)], as: UTF8.self)
            guard position + 12 + length <= bytes.count else { throw Unreadable(description: "a PNG cut short") }
            let body = Array(bytes[(position + 8)..<(position + 8 + length)])
            position += 12 + length
            switch kind {
            case "IHDR":
                guard body.count >= 13 else { throw Unreadable(description: "a PNG's header is short") }
                width = Int(body[0]) << 24 | Int(body[1]) << 16 | Int(body[2]) << 8 | Int(body[3])
                height = Int(body[4]) << 24 | Int(body[5]) << 16 | Int(body[6]) << 8 | Int(body[7])
                depth = Int(body[8]); color = Int(body[9]); interlace = Int(body[12])
            case "PLTE": palette = body
            case "tRNS": alpha = body
            case "IDAT": compressed.append(contentsOf: body)
            default: break
            }
            if kind == "IEND" { break }
        }
        let channelsByColor = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4]
        guard depth == 8, interlace == 0, let channels = channelsByColor[color] else {
            throw Unreadable(description: "a PNG of depth \(depth), color type \(color), interlace \(interlace)")
        }
        let stride = width * channels
        let raw = [UInt8](try Inflate.inflate(compressed, expected: height * (stride + 1)))
        guard raw.count >= height * (stride + 1) else { throw Unreadable(description: "a PNG's pixels are cut short") }
        var rows: [[UInt8]] = []
        rows.reserveCapacity(height)
        var previous = [UInt8](repeating: 0, count: stride)
        for y in 0..<height {
            let start = y * (stride + 1)
            let filter = raw[start]
            var line = Array(raw[(start + 1)..<(start + 1 + stride)])
            switch filter {
            case 0: break
            case 1:
                for i in channels..<max(channels, stride) { line[i] = line[i] &+ line[i - channels] }
            case 2:
                for i in 0..<stride { line[i] = line[i] &+ previous[i] }
            case 3:
                for i in 0..<stride {
                    let left = i >= channels ? Int(line[i - channels]) : 0
                    line[i] = line[i] &+ UInt8((left + Int(previous[i])) >> 1)
                }
            case 4:
                for i in 0..<stride {
                    let a = i >= channels ? Int(line[i - channels]) : 0
                    let b = Int(previous[i])
                    let c = i >= channels ? Int(previous[i - channels]) : 0
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    line[i] = line[i] &+ UInt8(pa <= pb && pa <= pc ? a : pb <= pc ? b : c)
                }
            default: throw Unreadable(description: "a PNG row filter \(filter)")
            }
            rows.append(line)
            previous = line
        }
        self.width = width
        self.height = height
        guard color != 6 else {
            self.rows = rows
            return
        }
        self.rows = try rows.map { line in
            var out = [UInt8](repeating: 0, count: width * 4)
            for x in 0..<width {
                let r, g, b, a: UInt8
                switch color {
                case 2: (r, g, b, a) = (line[3 * x], line[3 * x + 1], line[3 * x + 2], 255)
                case 0: (r, g, b, a) = (line[x], line[x], line[x], 255)
                case 4: (r, g, b, a) = (line[2 * x], line[2 * x], line[2 * x], line[2 * x + 1])
                default:
                    let index = Int(line[x])
                    guard 3 * index + 2 < palette.count else { throw Unreadable(description: "a PNG's palette is short") }
                    (r, g, b) = (palette[3 * index], palette[3 * index + 1], palette[3 * index + 2])
                    a = alpha.flatMap { index < $0.count ? $0[index] : nil } ?? 255
                }
                out[4 * x] = r; out[4 * x + 1] = g; out[4 * x + 2] = b; out[4 * x + 3] = a
            }
            return out
        }
    }
}

extension PNG {
    /// An RGBA PNG of `rows` (each `width` * 4 bytes), every row unfiltered: the tests' pictures.
    static func encode(width: Int, rows: [[UInt8]]) throws -> Data {
        func u32(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func chunk(_ kind: String, _ body: [UInt8]) -> [UInt8] { u32(body.count) + Array(kind.utf8) + body + [0, 0, 0, 0] }
        var raw: [UInt8] = []
        for row in rows { raw += [0] + row }
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += chunk("IHDR", u32(width) + u32(rows.count) + [8, 6, 0, 0, 0])
        png += chunk("IDAT", [UInt8](try Inflate.deflate(Data(raw))))
        png += chunk("IEND", [])
        return Data(png)
    }
}
