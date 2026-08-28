import Foundation

/// Garmin / ANT+ FIT 活动文件的精简解析器（活动、采样、游泳趟）。
enum FITParser {
    static let epoch = Date(timeIntervalSince1970: 631_065_600) // 1989-12-31 UTC

    enum ParseError: LocalizedError {
        case notFIT
        case truncated

        var errorDescription: String? {
            switch self {
            case .notFIT: return "不是有效的 FIT 文件。"
            case .truncated: return "FIT 文件不完整。"
            }
        }
    }

    struct Activity {
        var fileType: Int?
        var sport: Int?
        var subSport: Int?
        var start: Date?
        var durationSec: Double?
        var timerSec: Double?
        var distanceM: Double?
        var calories: Double?
        var avgHR: Double?
        var maxHR: Double?
        var ascentM: Double?
        var poolLengthM: Double?
        var records: [Record] = []
        var lengths: [Length] = []
        var laps: [Lap] = []
    }

    struct Record {
        var timestamp: Date?
        var lat: Double?
        var lon: Double?
        var altitude: Double?
        var hr: Double?
        var distanceM: Double?
    }

    struct Length {
        var start: Date?
        var timestamp: Date?
        var durationSec: Double?
        var strokes: Int?
        var stroke: Int?
        var isActive: Bool = true
    }

    struct Lap {
        var start: Date?
        var durationSec: Double?
        var distanceM: Double?
    }

    static func parse(_ data: Data) throws -> Activity {
        guard data.count >= 14 else { throw ParseError.truncated }
        var cursor = 0
        var merged = Activity()
        var parsedAny = false
        while cursor + 12 <= data.count {
            let headerSize = Int(data[cursor])
            guard headerSize == 12 || headerSize == 14, cursor + headerSize <= data.count else { break }
            let magic = data.subdata(in: (cursor + 8)..<(cursor + 12))
            guard magic == Data(".FIT".utf8) else {
                if parsedAny { break }
                throw ParseError.notFIT
            }
            let dataSize = Int(readUInt32(data, cursor + 4, littleEndian: true))
            let bodyStart = cursor + headerSize
            let bodyEnd = min(bodyStart + dataSize, data.count)
            guard bodyEnd > bodyStart else { break }
            let chunk = try parseBody(data, start: bodyStart, end: bodyEnd)
            merge(&merged, chunk)
            parsedAny = true
            cursor = min(bodyEnd + 2, data.count) // skip CRC
            if dataSize == 0 { break }
        }
        guard parsedAny else { throw ParseError.notFIT }
        return merged
    }

    static func looksLikeFIT(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let headerSize = Int(data[0])
        guard headerSize == 12 || headerSize == 14, data.count >= headerSize else { return false }
        return data.subdata(in: 8..<12) == Data(".FIT".utf8)
    }

    // MARK: - Body

    private static func parseBody(_ data: Data, start: Int, end: Int) throws -> Activity {
        var offset = start
        var defs: [Int: Definition] = [:]
        var lastTimestamp: UInt32 = 0
        var activity = Activity()

        while offset < end {
            let header = data[offset]
            offset += 1
            if header & 0x80 != 0 {
                // compressed timestamp header
                let local = Int((header >> 5) & 0x03)
                let timeOffset = UInt32(header & 0x1F)
                var ts = (lastTimestamp & ~0x1F) + timeOffset
                if timeOffset < (lastTimestamp & 0x1F) { ts += 0x20 }
                lastTimestamp = ts
                guard let def = defs[local] else { continue }
                let (consumed, fields) = readDataFields(data, offset: offset, def: def, end: end)
                offset += consumed
                ingest(fields, def: def, timestampHint: ts, into: &activity, lastTimestamp: &lastTimestamp)
                continue
            }

            let local = Int(header & 0x0F)
            let isDefinition = (header & 0x40) != 0
            let hasDev = (header & 0x20) != 0

            if isDefinition {
                guard offset + 5 <= end else { throw ParseError.truncated }
                let architecture = data[offset + 1] // 0 little, 1 big
                let little = architecture == 0
                let global = Int(readUInt16(data, offset + 2, littleEndian: little))
                let fieldCount = Int(data[offset + 4])
                offset += 5
                var fields: [FieldDef] = []
                fields.reserveCapacity(fieldCount)
                for _ in 0..<fieldCount {
                    guard offset + 3 <= end else { throw ParseError.truncated }
                    fields.append(FieldDef(
                        number: Int(data[offset]),
                        size: Int(data[offset + 1]),
                        baseType: data[offset + 2]
                    ))
                    offset += 3
                }
                var devSize = 0
                if hasDev {
                    guard offset < end else { throw ParseError.truncated }
                    let n = Int(data[offset])
                    offset += 1
                    for _ in 0..<n {
                        guard offset + 3 <= end else { throw ParseError.truncated }
                        devSize += Int(data[offset + 1])
                        offset += 3
                    }
                }
                defs[local] = Definition(global: global, littleEndian: little, fields: fields, developerBytes: devSize)
            } else {
                guard let def = defs[local] else {
                    // unknown local type — cannot skip safely
                    break
                }
                let (consumed, fields) = readDataFields(data, offset: offset, def: def, end: end)
                offset += consumed
                ingest(fields, def: def, timestampHint: nil, into: &activity, lastTimestamp: &lastTimestamp)
            }
        }
        return activity
    }

    private static func readDataFields(_ data: Data, offset: Int, def: Definition, end: Int) -> (Int, [Int: Int64]) {
        var cursor = offset
        var map: [Int: Int64] = [:]
        for field in def.fields {
            guard cursor + field.size <= end else { break }
            if let value = decodeInteger(data, at: cursor, size: field.size, baseType: field.baseType, little: def.littleEndian) {
                map[field.number] = value
            }
            cursor += field.size
        }
        cursor += def.developerBytes
        if cursor > end { cursor = end }
        return (cursor - offset, map)
    }

    private static func ingest(_ fields: [Int: Int64], def: Definition, timestampHint: UInt32?,
                               into activity: inout Activity, lastTimestamp: inout UInt32) {
        if let raw = fields[253], raw > 0, raw < 0xFFFF_FFFF {
            lastTimestamp = UInt32(truncatingIfNeeded: raw)
        } else if let hint = timestampHint {
            lastTimestamp = hint
        }

        switch def.global {
        case 0: // file_id
            if let t = fields[0] { activity.fileType = Int(t) }
        case 12: // sport
            if let s = fields[0] { activity.sport = Int(s) }
            if let s = fields[1] { activity.subSport = Int(s) }
        case 18: // session
            applySession(fields, into: &activity)
        case 19: // lap
            activity.laps.append(Lap(
                start: date(fields[2] ?? fields[253]),
                durationSec: scaled(fields[7], 1000) ?? scaled(fields[8], 1000),
                distanceM: scaled(fields[9], 100)
            ))
        case 20: // record
            activity.records.append(Record(
                timestamp: date(fields[253]) ?? date(Int64(lastTimestamp)),
                lat: semicircle(fields[0]),
                lon: semicircle(fields[1]),
                altitude: altitude(fields[78] ?? fields[2]),
                hr: validUInt8(fields[3]),
                distanceM: scaled(fields[5], 100)
            ))
        case 34: // activity
            if activity.timerSec == nil { activity.timerSec = scaled(fields[0], 1000) }
            if activity.start == nil { activity.start = date(fields[5] ?? fields[253]) }
        case 101: // length (swim)
            let lengthType = fields[11].map { Int($0) }
            activity.lengths.append(Length(
                start: date(fields[2]),
                timestamp: date(fields[253]),
                durationSec: scaled(fields[3], 1000) ?? scaled(fields[4], 1000),
                strokes: fields[5].map { Int($0) },
                stroke: fields[7].map { Int($0) },
                isActive: lengthType != 0
            ))
        default:
            break
        }
    }

    private static func applySession(_ fields: [Int: Int64], into activity: inout Activity) {
        if let s = fields[5] { activity.sport = Int(s) }
        if let s = fields[6] { activity.subSport = Int(s) }
        if let start = date(fields[2]) { activity.start = start }
        if let dur = scaled(fields[7], 1000) { activity.durationSec = dur }
        if let timer = scaled(fields[8], 1000) { activity.timerSec = timer }
        if let dist = scaled(fields[9], 100) { activity.distanceM = dist }
        if let cal = fields[11], cal != 0xFFFF { activity.calories = Double(cal) }
        if let hr = validUInt8(fields[16]) { activity.avgHR = hr }
        if let hr = validUInt8(fields[17]) { activity.maxHR = hr }
        if let asc = fields[22], asc != 0xFFFF { activity.ascentM = Double(asc) }
        if let pool = scaled(fields[44], 100), pool > 0 { activity.poolLengthM = pool }
    }

    private static func merge(_ into: inout Activity, _ other: Activity) {
        if into.fileType == nil { into.fileType = other.fileType }
        if into.sport == nil { into.sport = other.sport }
        if into.subSport == nil { into.subSport = other.subSport }
        if into.start == nil { into.start = other.start }
        if into.durationSec == nil { into.durationSec = other.durationSec }
        if into.timerSec == nil { into.timerSec = other.timerSec }
        if into.distanceM == nil { into.distanceM = other.distanceM }
        if into.calories == nil { into.calories = other.calories }
        if into.avgHR == nil { into.avgHR = other.avgHR }
        if into.maxHR == nil { into.maxHR = other.maxHR }
        if into.ascentM == nil { into.ascentM = other.ascentM }
        if into.poolLengthM == nil { into.poolLengthM = other.poolLengthM }
        into.records.append(contentsOf: other.records)
        into.lengths.append(contentsOf: other.lengths)
        into.laps.append(contentsOf: other.laps)
    }

    // MARK: - Decode helpers

    private struct FieldDef {
        let number: Int
        let size: Int
        let baseType: UInt8
    }

    private struct Definition {
        let global: Int
        let littleEndian: Bool
        let fields: [FieldDef]
        let developerBytes: Int
    }

    private static func decodeInteger(_ data: Data, at offset: Int, size: Int, baseType: UInt8, little: Bool) -> Int64? {
        let type = baseType & 0x1F
        switch type {
        case 0, 1, 2, 10, 13: // enum / sint8 / uint8 / uint8z / byte
            guard size >= 1 else { return nil }
            let v = data[offset]
            if type == 1 { return Int64(Int8(bitPattern: v)) }
            if v == 0xFF && type != 13 { return nil }
            return Int64(v)
        case 0x03, 0x04, 0x0B: // sint16 / uint16 / uint16z in low 5 bits: 3, 4, 11
            guard size >= 2 else { return nil }
            let raw = readUInt16(data, offset, littleEndian: little)
            if type == 3 { return Int64(Int16(bitPattern: raw)) }
            if raw == 0xFFFF { return nil }
            return Int64(raw)
        case 0x05, 0x06, 0x0C: // sint32 / uint32 / uint32z
            guard size >= 4 else { return nil }
            let raw = readUInt32(data, offset, littleEndian: little)
            if type == 5 { return Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: raw))) }
            if raw == 0xFFFF_FFFF { return nil }
            return Int64(raw)
        case 0x08: // float32
            guard size >= 4 else { return nil }
            let raw = readUInt32(data, offset, littleEndian: little)
            let f = Float(bitPattern: UInt32(truncatingIfNeeded: raw))
            guard f.isFinite else { return nil }
            return Int64(f.rounded())
        default:
            // multi-byte leftover: read as little/big unsigned up to 8 bytes
            if size == 2 {
                let raw = readUInt16(data, offset, littleEndian: little)
                return raw == 0xFFFF ? nil : Int64(raw)
            }
            if size == 4 {
                let raw = readUInt32(data, offset, littleEndian: little)
                return raw == 0xFFFF_FFFF ? nil : Int64(raw)
            }
            return nil
        }
    }

    private static func readUInt16(_ data: Data, _ offset: Int, littleEndian: Bool) -> UInt16 {
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        return littleEndian ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
    }

    private static func readUInt32(_ data: Data, _ offset: Int, littleEndian: Bool) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        if littleEndian { return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24) }
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func date(_ raw: Int64?) -> Date? {
        guard let raw, raw > 0x1000_0000, raw < 0xFFFF_FFFF else { return nil }
        return epoch.addingTimeInterval(TimeInterval(raw))
    }

    private static func scaled(_ raw: Int64?, _ scale: Double) -> Double? {
        guard let raw else { return nil }
        let v = Double(raw) / scale
        return v >= 0 ? v : nil
    }

    private static func validUInt8(_ raw: Int64?) -> Double? {
        guard let raw, raw >= 0, raw < 255 else { return nil }
        return Double(raw)
    }

    private static func semicircle(_ raw: Int64?) -> Double? {
        guard let raw, raw != 0x7FFF_FFFF, raw != -0x8000_0000 else { return nil }
        let deg = Double(raw) * (180.0 / Double(Int64(1) << 31))
        guard deg.isFinite, abs(deg) <= 180 else { return nil }
        return deg
    }

    private static func altitude(_ raw: Int64?) -> Double? {
        guard let raw else { return nil }
        let meters = Double(raw) / 5.0 - 500.0
        guard meters.isFinite, meters > -200, meters < 9000 else { return nil }
        return meters
    }
}
