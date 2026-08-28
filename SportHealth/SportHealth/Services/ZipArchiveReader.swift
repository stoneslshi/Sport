import Foundation
import zlib

/// 读取标准 ZIP（含 Garmin 数据导出里的嵌套 UploadedFiles_*.zip）。
enum ZipArchiveReader {
    struct Entry {
        var name: String
        var data: Data
    }

    enum ZipError: LocalizedError {
        case truncated
        case inflateFailed

        var errorDescription: String? {
            switch self {
            case .truncated: return "ZIP 文件不完整。"
            case .inflateFailed: return "ZIP 解压失败。"
            }
        }
    }

    static func looksLikeZIP(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == 0x50 && data[1] == 0x4B && (data[2] == 0x03 || data[2] == 0x05 || data[2] == 0x07)
    }

    /// 展开一层 ZIP；调用方再对其中的 zip/fit 递归。
    static func entries(from data: Data) throws -> [Entry] {
        var offset = 0
        var result: [Entry] = []
        while offset + 30 <= data.count {
            let sig = readUInt32LE(data, offset)
            if sig == 0x0201_4B50 || sig == 0x0605_4B50 || sig == 0x0606_4B50 {
                break // central directory / EOCD
            }
            guard sig == 0x0403_4B50 else { break }
            let flags = Int(readUInt16LE(data, offset + 6))
            let method = Int(readUInt16LE(data, offset + 8))
            var compSize = Int(readUInt32LE(data, offset + 18))
            var uncompSize = Int(readUInt32LE(data, offset + 22))
            let nameLen = Int(readUInt16LE(data, offset + 26))
            let extraLen = Int(readUInt16LE(data, offset + 28))
            let nameStart = offset + 30
            guard nameStart + nameLen + extraLen <= data.count else { throw ZipError.truncated }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? "unknown"
            let extra = data.subdata(in: (nameStart + nameLen)..<(nameStart + nameLen + extraLen))
            parseZip64Sizes(extra, compressed: &compSize, uncompressed: &uncompSize)
            let dataStart = nameStart + nameLen + extraLen

            let dataDescriptor = (flags & 0x08) != 0
            var payload: Data
            var next: Int
            if dataDescriptor && (compSize == 0 || uncompSize == 0) {
                // 少见：扫描到 data descriptor。为稳妥跳过该条目。
                break
            } else {
                guard dataStart + compSize <= data.count else { throw ZipError.truncated }
                payload = data.subdata(in: dataStart..<(dataStart + compSize))
                next = dataStart + compSize
            }

            if shouldSkip(name) {
                offset = next
                continue
            }

            let fileData: Data
            switch method {
            case 0:
                fileData = payload
            case 8:
                fileData = try inflateRaw(payload, uncompressedSize: uncompSize)
            default:
                offset = next
                continue
            }
            result.append(Entry(name: name, data: fileData))
            offset = next
        }
        return result
    }

    private static func shouldSkip(_ name: String) -> Bool {
        let lower = name.lowercased()
        if name.hasSuffix("/") { return true }
        if lower.contains("__macosx") || lower.hasSuffix(".ds_store") { return true }
        return false
    }

    private static func parseZip64Sizes(_ extra: Data, compressed: inout Int, uncompressed: inout Int) {
        var i = 0
        while i + 4 <= extra.count {
            let id = Int(readUInt16LE(extra, i))
            let size = Int(readUInt16LE(extra, i + 2))
            let start = i + 4
            guard start + size <= extra.count else { break }
            if id == 0x0001 {
                var cursor = start
                if uncompressed == 0xFFFF_FFFF, cursor + 8 <= start + size {
                    uncompressed = Int(readUInt64LE(extra, cursor))
                    cursor += 8
                }
                if compressed == 0xFFFF_FFFF, cursor + 8 <= start + size {
                    compressed = Int(readUInt64LE(extra, cursor))
                }
            }
            i = start + size
        }
    }

    private static func inflateRaw(_ input: Data, uncompressedSize: Int) throws -> Data {
        if input.isEmpty { return Data() }
        let destCount = max(uncompressedSize, max(input.count * 16, 1024))
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { throw ZipError.inflateFailed }
        defer { inflateEnd(&stream) }

        var output = Data(count: destCount)
        let status: Int32 = input.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = dst.baseAddress?.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(destCount)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || status == Z_OK else { throw ZipError.inflateFailed }
        let written = destCount - Int(stream.avail_out)
        return output.prefix(written)
    }

    private static func readUInt16LE(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[offset + i]) << (8 * i) }
        return v
    }
}
