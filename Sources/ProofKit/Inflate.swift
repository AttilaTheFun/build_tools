import CZlib
import Foundation

/// zlib's inflate: a zlib stream (a PNG's IDAT) or a raw deflate one (a zip's entry).
enum Inflate {
    struct Failed: Error, CustomStringConvertible {
        let description: String
    }

    /// `data` inflated; `raw`: a deflate stream with no zlib header (a zip entry's).
    static func inflate(_ data: Data, raw: Bool = false, expected: Int? = nil) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, raw ? -MAX_WBITS : MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failed(description: "zlib couldn't start")
        }
        defer { inflateEnd(&stream) }
        var out = Data()
        out.reserveCapacity(expected ?? data.count * 4)
        let chunk = 1 << 16
        var buffer = [UInt8](repeating: 0, count: chunk)
        var input = [UInt8](data)
        let status: Int32 = input.withUnsafeMutableBufferPointer { inputBuffer in
            stream.next_in = inputBuffer.baseAddress
            stream.avail_in = uInt(inputBuffer.count)
            var result: Int32 = Z_OK
            repeat {
                result = buffer.withUnsafeMutableBufferPointer { outputBuffer in
                    stream.next_out = outputBuffer.baseAddress
                    stream.avail_out = uInt(chunk)
                    let result = CZlib.inflate(&stream, Z_NO_FLUSH)
                    out.append(outputBuffer.baseAddress!, count: chunk - Int(stream.avail_out))
                    return result
                }
            } while result == Z_OK
            return result
        }
        guard status == Z_STREAM_END else { throw Failed(description: "the data isn't whole deflate (zlib \(status))") }
        return out
    }
}

extension Inflate {
    /// `data` deflated (zlib's, or raw for a zip's entry): what the tests make their PNGs and zips with.
    static func deflate(_ data: Data, raw: Bool = false) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, raw ? -MAX_WBITS : MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failed(description: "zlib couldn't start") }
        defer { deflateEnd(&stream) }
        var input = [UInt8](data)
        var out = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))) + 64)
        let written: Int = input.withUnsafeMutableBufferPointer { inputBuffer in
            out.withUnsafeMutableBufferPointer { outputBuffer in
                stream.next_in = inputBuffer.baseAddress
                stream.avail_in = uInt(inputBuffer.count)
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = uInt(outputBuffer.count)
                guard CZlib.deflate(&stream, Z_FINISH) == Z_STREAM_END else { return -1 }
                return outputBuffer.count - Int(stream.avail_out)
            }
        }
        guard written >= 0 else { throw Failed(description: "zlib couldn't deflate") }
        return Data(out[0..<written])
    }
}
