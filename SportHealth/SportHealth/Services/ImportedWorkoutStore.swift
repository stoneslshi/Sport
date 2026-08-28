import Foundation
import CoreLocation
import HealthKit
import CryptoKit

struct PersistedImportedWorkout: Codable, Identifiable {
    var id: UUID
    var fingerprint: String
    var fileName: String
    var activityTypeRaw: UInt
    var start: Date
    var end: Date
    var durationMinutes: Double
    var caloriesKcal: Double
    var distanceKM: Double?
    var avgHR: Double?
    var maxHR: Double?
    var elevationGain: Double?
    var poolLength: Double?
    var sourceName: String
    var latitudes: [Double]
    var longitudes: [Double]
    var elevation: [PersistedXY]
    var heartRate: [PersistedXY]
    var splits: [PersistedSplit]
    var swimLaps: [PersistedSwimLap]
    var importedAt: Date

    var activityType: HKWorkoutActivityType {
        HKWorkoutActivityType(rawValue: activityTypeRaw) ?? .other
    }

    func asRecord() -> WorkoutRecord {
        WorkoutRecord(
            id: id,
            activityType: activityType,
            start: start,
            end: end,
            durationMinutes: durationMinutes,
            caloriesKcal: caloriesKcal,
            distanceKM: distanceKM,
            source: .garmin,
            sourceName: sourceName,
            avgHR: avgHR,
            maxHR: maxHR,
            elevationGain: elevationGain,
            poolLength: poolLength
        )
    }

    func detailedRecord() -> WorkoutRecord {
        var record = asRecord()
        record.routeCoordinates = zip(latitudes, longitudes).map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
        record.elevationSeries = elevation.map { ElevationPoint(minute: $0.x, meters: $0.y) }
        record.heartRateSeries = heartRate.map { HeartRatePoint(minute: $0.x, bpm: $0.y) }
        record.splits = splits.map {
            KMSplit(index: $0.index, paceMin: $0.paceMin, segmentMeters: $0.segmentMeters)
        }
        let laps = swimLaps.map { lap -> SwimLap in
            var item = SwimLap(
                index: lap.index,
                start: lap.start,
                end: lap.end,
                distanceM: lap.distanceM,
                stroke: SwimStroke(rawValue: lap.stroke) ?? .unknown
            )
            item.strokeCount = lap.strokeCount
            return item
        }
        record.swimLaps = laps
        record.laps = laps.isEmpty ? nil : laps.count
        record.totalStrokeCount = {
            let sum = laps.compactMap(\.strokeCount).reduce(0, +)
            return sum > 0 ? sum : nil
        }()
        if !laps.isEmpty {
            record.strokeDistribution = Dictionary(grouping: laps, by: \.stroke).mapValues { $0.reduce(0) { $0 + $1.distanceM } }
            record.swimSets = GarminFitMapper.swimSets(from: laps)
            record.avgSWOLF = {
                let values = laps.compactMap(\.swolf)
                guard !values.isEmpty else { return nil }
                return values.reduce(0, +) / Double(values.count)
            }()
            record.bestPacePer100m = laps.compactMap(\.paceMinPer100m).min()
            record.sessionDistanceBests = GarminFitMapper.sessionBests(from: laps)
        }
        if !record.heartRateSeries.isEmpty {
            record.hrZones = HealthKitManager.heartRateZones(
                from: record.heartRateSeries,
                maxHRHint: record.maxHR,
                ageYears: nil)
        }
        return record
    }
}

struct PersistedXY: Codable {
    var x: Double
    var y: Double
}

struct PersistedSplit: Codable {
    var index: Int
    var paceMin: Double
    var segmentMeters: Double
}

struct PersistedSwimLap: Codable {
    var index: Int
    var start: Date
    var end: Date
    var distanceM: Double
    var stroke: String
    var strokeCount: Int?
}

final class ImportedWorkoutStore {
    static let shared = ImportedWorkoutStore()

    private let fileName = "imported_garmin_workouts.json"
    private let queue = DispatchQueue(label: "com.workbuddy.SportHealth.importedWorkouts")
    private var cache: [PersistedImportedWorkout]?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("SportHealth", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(fileName)
    }

    func all() -> [PersistedImportedWorkout] {
        queue.sync {
            loadIfNeeded().sorted { $0.start > $1.start }
        }
    }

    func count() -> Int { all().count }

    func workout(id: UUID) -> PersistedImportedWorkout? {
        queue.sync { loadIfNeeded().first { $0.id == id } }
    }

    func startCoordinate(for id: UUID) -> CLLocationCoordinate2D? {
        guard let item = workout(id: id), let lat = item.latitudes.first, let lon = item.longitudes.first else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func hasRoute(id: UUID) -> Bool {
        guard let item = workout(id: id) else { return false }
        return item.latitudes.count >= 2
    }

    @discardableResult
    func upsert(_ items: [PersistedImportedWorkout]) -> (added: Int, updated: Int) {
        queue.sync {
            var list = loadIfNeeded()
            var added = 0
            var updated = 0
            for item in items {
                if let idx = list.firstIndex(where: { $0.fingerprint == item.fingerprint || $0.id == item.id }) {
                    list[idx] = item
                    updated += 1
                } else {
                    list.append(item)
                    added += 1
                }
            }
            cache = list
            persist(list)
            return (added, updated)
        }
    }

    func containsFingerprint(_ fingerprint: String) -> Bool {
        queue.sync { loadIfNeeded().contains { $0.fingerprint == fingerprint } }
    }

    func clear() {
        queue.sync {
            cache = []
            persist([])
        }
    }

    private func loadIfNeeded() -> [PersistedImportedWorkout] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PersistedImportedWorkout].self, from: data) else {
            cache = []
            return []
        }
        cache = decoded
        return decoded
    }

    private func persist(_ list: [PersistedImportedWorkout]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

enum GarminFitMapper {
    static func persist(activity: FITParser.Activity, fileName: String, fingerprint: String) -> PersistedImportedWorkout? {
        let records = activity.records.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
        let start = activity.start
            ?? records.first?.timestamp
            ?? activity.laps.first?.start
        guard let start else { return nil }

        let durationSec = activity.timerSec ?? activity.durationSec
            ?? records.last?.timestamp.map { $0.timeIntervalSince(start) }
            ?? 0
        guard durationSec >= 20 else { return nil }

        if let type = activity.fileType {
            // 只要已完成的活动；跳过设备/设置/训练计划/全天监测 FIT
            let skip: Set<Int> = [1, 2, 3, 5, 6, 9, 10, 11, 15, 28, 32]
            if skip.contains(type) { return nil }
        }

        let end = start.addingTimeInterval(durationSec)
        let coords = downsampleCoords(records)
        let hrSeries = downsampleHR(records, start: start)
        let elev = downsampleElevation(records, start: start)
        let laps = swimLaps(from: activity)
        let type = sportType(activity.sport, sub: activity.subSport)
        let distanceM = activity.distanceM
            ?? records.compactMap(\.distanceM).last
            ?? (type == .swimming && !laps.isEmpty ? laps.reduce(0) { $0 + $1.distanceM } : nil)

        let avgHR = activity.avgHR ?? average(hrSeries.map(\.y))
        let maxHR = activity.maxHR ?? hrSeries.map(\.y).max()
        let splits: [PersistedSplit]
        if type == .swimming {
            splits = swimSplits(laps)
        } else {
            splits = distanceSplits(records, start: start, segmentMeters: 1000)
        }

        let hash = fingerprint
        return PersistedImportedWorkout(
            id: uuid(from: hash),
            fingerprint: hash,
            fileName: fileName,
            activityTypeRaw: type.rawValue,
            start: start,
            end: end,
            durationMinutes: durationSec / 60,
            caloriesKcal: activity.calories ?? 0,
            distanceKM: (distanceM ?? 0) > 0 ? (distanceM! / 1000) : nil,
            avgHR: avgHR,
            maxHR: maxHR,
            elevationGain: activity.ascentM,
            poolLength: activity.poolLengthM,
            sourceName: "Garmin FIT",
            latitudes: coords.map(\.0),
            longitudes: coords.map(\.1),
            elevation: elev,
            heartRate: hrSeries,
            splits: splits,
            swimLaps: laps,
            importedAt: Date()
        )
    }

    static func fingerprint(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func swimSets(from laps: [SwimLap], restThreshold: TimeInterval = 12) -> [SwimSet] {
        guard !laps.isEmpty else { return [] }
        var sets: [SwimSet] = []
        var bucket: [SwimLap] = [laps[0]]
        for i in 1..<laps.count {
            let gap = laps[i].start.timeIntervalSince(laps[i - 1].end)
            if gap >= restThreshold {
                sets.append(makeSet(index: sets.count + 1, laps: bucket, trailingRest: max(gap, 0)))
                bucket = [laps[i]]
            } else {
                bucket.append(laps[i])
            }
        }
        sets.append(makeSet(index: sets.count + 1, laps: bucket, trailingRest: 0))
        return sets
    }

    static func sessionBests(from laps: [SwimLap]) -> [SwimDistanceBest] {
        let targets = [100, 200, 400, 800, 1000, 1500]
        guard let pool = laps.first?.distanceM, pool > 0 else { return [] }
        var bests: [SwimDistanceBest] = []
        for target in targets {
            let need = Int((Double(target) / pool).rounded())
            guard need > 0, need <= laps.count else { continue }
            var best: Double?
            for i in 0...(laps.count - need) {
                let sec = laps[i..<(i + need)].reduce(0.0) { $0 + $1.durationSec }
                if best == nil || sec < best! { best = sec }
            }
            if let best { bests.append(SwimDistanceBest(meters: target, timeSec: best)) }
        }
        return bests
    }

    private static func makeSet(index: Int, laps: [SwimLap], trailingRest: TimeInterval) -> SwimSet {
        let dist = laps.reduce(0.0) { $0 + $1.distanceM }
        let active = laps.reduce(0.0) { $0 + $1.durationSec }
        var innerRest = 0.0
        for i in 1..<laps.count {
            innerRest += max(laps[i].start.timeIntervalSince(laps[i - 1].end), 0)
        }
        return SwimSet(
            index: index,
            startLap: laps.first?.index ?? index,
            endLap: laps.last?.index ?? index,
            distanceM: dist,
            activeSec: active,
            restSec: trailingRest > 0 ? trailingRest : innerRest
        )
    }

    private static func swimLaps(from activity: FITParser.Activity) -> [PersistedSwimLap] {
        let pool = activity.poolLengthM ?? 25
        let active = activity.lengths.filter(\.isActive)
        guard !active.isEmpty else { return [] }
        var result: [PersistedSwimLap] = []
        for (i, length) in active.enumerated() {
            let start = length.start
                ?? length.timestamp.map { $0.addingTimeInterval(-(length.durationSec ?? 0)) }
                ?? activity.start?.addingTimeInterval(Double(i) * (length.durationSec ?? 0))
            guard let start else { continue }
            let dur = max(length.durationSec ?? 0, 1)
            result.append(PersistedSwimLap(
                index: i + 1,
                start: start,
                end: start.addingTimeInterval(dur),
                distanceM: pool,
                stroke: swimStroke(length.stroke).rawValue,
                strokeCount: length.strokes
            ))
        }
        return result
    }

    private static func swimStroke(_ raw: Int?) -> SwimStroke {
        switch raw {
        case 0: return .freestyle
        case 1: return .backstroke
        case 2: return .breaststroke
        case 3: return .butterfly
        case 5: return .mixed
        default: return .unknown
        }
    }

    private static func swimSplits(_ laps: [PersistedSwimLap]) -> [PersistedSplit] {
        var splits: [PersistedSplit] = []
        var accDist = 0.0
        var accSec = 0.0
        var index = 1
        for lap in laps {
            accDist += lap.distanceM
            accSec += lap.end.timeIntervalSince(lap.start)
            while accDist >= 100 {
                let pace = (accSec / 60.0) / (accDist / 100.0)
                splits.append(PersistedSplit(index: index, paceMin: pace, segmentMeters: 100))
                index += 1
                accDist -= 100
                accSec = 0
            }
        }
        return splits
    }

    private static func distanceSplits(_ records: [FITParser.Record], start: Date, segmentMeters: Double) -> [PersistedSplit] {
        let points: [(Date, Double)] = records.compactMap { rec in
            guard let t = rec.timestamp, let d = rec.distanceM else { return nil }
            return (t, d)
        }
        guard points.count >= 2 else { return [] }
        var splits: [PersistedSplit] = []
        var next = segmentMeters
        var prevT = points[0].0
        var prevD = points[0].1
        var segStart = start
        var index = 1
        for (t, d) in points.dropFirst() {
            while d >= next, d > prevD {
                let frac = (next - prevD) / (d - prevD)
                let cross = prevT.addingTimeInterval(t.timeIntervalSince(prevT) * frac)
                let durationMin = max(cross.timeIntervalSince(segStart) / 60.0, 0)
                splits.append(PersistedSplit(index: index, paceMin: durationMin, segmentMeters: segmentMeters))
                index += 1
                segStart = cross
                next += segmentMeters
            }
            prevT = t
            prevD = d
        }
        return splits
    }

    private static func downsampleCoords(_ records: [FITParser.Record], maxPoints: Int = 400) -> [(Double, Double)] {
        let pts = records.compactMap { rec -> (Double, Double)? in
            guard let lat = rec.lat, let lon = rec.lon else { return nil }
            return (lat, lon)
        }
        guard pts.count > maxPoints else { return pts }
        let step = Double(pts.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { i in pts[min(Int((Double(i) * step).rounded()), pts.count - 1)] }
    }

    private static func downsampleHR(_ records: [FITParser.Record], start: Date, maxPoints: Int = 80) -> [PersistedXY] {
        let pts: [PersistedXY] = records.compactMap { rec in
            guard let t = rec.timestamp, let hr = rec.hr, hr > 20 else { return nil }
            return PersistedXY(x: t.timeIntervalSince(start) / 60, y: hr)
        }
        guard pts.count > maxPoints else { return pts }
        let step = Double(pts.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { i in pts[min(Int((Double(i) * step).rounded()), pts.count - 1)] }
    }

    private static func downsampleElevation(_ records: [FITParser.Record], start: Date, maxPoints: Int = 80) -> [PersistedXY] {
        let pts: [PersistedXY] = records.compactMap { rec in
            guard let t = rec.timestamp, let alt = rec.altitude else { return nil }
            return PersistedXY(x: t.timeIntervalSince(start) / 60, y: alt)
        }
        guard pts.count > maxPoints else { return pts }
        let step = Double(pts.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { i in pts[min(Int((Double(i) * step).rounded()), pts.count - 1)] }
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func uuid(from hex: String) -> UUID {
        let bytes = stride(from: 0, to: min(hex.count, 32), by: 2).compactMap { i -> UInt8? in
            let s = hex.index(hex.startIndex, offsetBy: i)
            let e = hex.index(s, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            return UInt8(hex[s..<e], radix: 16)
        }
        var b = bytes + Array(repeating: 0, count: max(0, 16 - bytes.count))
        b[6] = (b[6] & 0x0F) | 0x50 // UUID v5-ish
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func sportType(_ sport: Int?, sub: Int?) -> HKWorkoutActivityType {
        if let sub {
            switch sub {
            case 20: return .traditionalStrengthTraining
            case 6: return .cycling
            case 17, 18: return .swimming
            default: break
            }
        }
        switch sport {
        case 1: return .running
        case 2, 21: return .cycling
        case 4:
            switch sub {
            case 20: return .traditionalStrengthTraining
            default: return .mixedCardio
            }
        case 5: return .swimming
        case 6: return .basketball
        case 7: return .soccer
        case 8: return .tennis
        case 10:
            return sub == 20 ? .traditionalStrengthTraining : .mixedCardio
        case 11: return .walking
        case 12, 13, 14: return .snowSports
        case 15: return .rowing
        case 17: return .hiking
        case 25: return .golf
        case 31: return .climbing
        case 33: return .skatingSports
        case 38: return .surfingSports
        case 47: return .boxing
        case 62: return .highIntensityIntervalTraining
        case 75: return .volleyball
        case 83: return .cardioDance
        case 84: return .jumpRope
        default: return .other
        }
    }
}
