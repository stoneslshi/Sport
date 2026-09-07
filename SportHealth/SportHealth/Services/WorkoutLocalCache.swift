import Foundation
import CoreLocation

/// 运动本机缓存：按月存 GPS 起点 / 城市国家，详情按条限量落盘。
/// HealthKit 记录若时长、热量、距离或结束时间变了，指纹对不上会自动重拉。
final class WorkoutLocalCache {
    static let shared = WorkoutLocalCache()

    private let queue = DispatchQueue(label: "com.workbuddy.SportHealth.workoutCache")
    private let maxDetailFiles = 80
    private let keepMonths = 14

    private var months: [String: [UUID: CachedWorkoutPin]] = [:]
    private var loadedMonths: Set<String> = []

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private var folderURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = support.appendingPathComponent("SportHealth/workout-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private var detailsFolderURL: URL {
        let folder = folderURL.appendingPathComponent("details", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: Fingerprint

    static func fingerprint(for record: WorkoutRecord) -> String {
        let dist = record.distanceKM.map { String(format: "%.4f", $0) } ?? "-"
        let seconds = Int(record.durationMinutes * 60)
        let kcal = Int(record.caloriesKcal.rounded())
        let end = Int(record.end.timeIntervalSince1970)
        return "\(seconds)|\(kcal)|\(dist)|\(end)"
    }

    static func monthKey(for date: Date) -> String {
        monthFormatter.string(from: date)
    }

    // MARK: Pins (monthly)

    func hydratePins(for records: [WorkoutRecord]) -> HydratedPins {
        queue.sync {
            pruneOldMonthFiles()
            var coords: [UUID: CLLocationCoordinate2D] = [:]
            var checked: Set<UUID> = []
            var places: [UUID: WorkoutPlaceInfo] = [:]
            for record in records {
                loadMonthIfNeeded(Self.monthKey(for: record.start))
            }
            for record in records {
                let month = Self.monthKey(for: record.start)
                guard let item = months[month]?[record.id],
                      item.checked,
                      item.fingerprint == Self.fingerprint(for: record) else { continue }
                checked.insert(record.id)
                if let lat = item.latitude, let lon = item.longitude,
                   CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                    coords[record.id] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
                if let place = item.place, place.isResolved {
                    places[record.id] = place
                }
            }
            return HydratedPins(coords: coords, checked: checked, places: places)
        }
    }

    func place(id: UUID, start: Date) -> WorkoutPlaceInfo? {
        queue.sync {
            let month = Self.monthKey(for: start)
            loadMonthIfNeeded(month)
            guard let place = months[month]?[id]?.place, place.isResolved else { return nil }
            return place
        }
    }

    func savePins(_ batch: [(record: WorkoutRecord, coordinate: CLLocationCoordinate2D?)]) {
        guard !batch.isEmpty else { return }
        queue.sync {
            var dirty: Set<String> = []
            for item in batch {
                let month = Self.monthKey(for: item.record.start)
                loadMonthIfNeeded(month)
                var map = months[month] ?? [:]
                var pin = map[item.record.id] ?? CachedWorkoutPin(
                    id: item.record.id,
                    start: item.record.start,
                    fingerprint: Self.fingerprint(for: item.record)
                )
                pin.start = item.record.start
                pin.fingerprint = Self.fingerprint(for: item.record)
                pin.checked = true
                pin.latitude = item.coordinate?.latitude
                pin.longitude = item.coordinate?.longitude
                map[item.record.id] = pin
                months[month] = map
                dirty.insert(month)
            }
            for month in dirty { persistMonth(month) }
        }
    }

    func savePlace(id: UUID, start: Date, coordinate: CLLocationCoordinate2D, fingerprint: String, place: WorkoutPlaceInfo) {
        guard place.isResolved else { return }
        queue.sync {
            let month = Self.monthKey(for: start)
            loadMonthIfNeeded(month)
            var map = months[month] ?? [:]
            var pin = map[id] ?? CachedWorkoutPin(id: id, start: start, fingerprint: fingerprint)
            pin.start = start
            if pin.fingerprint.isEmpty { pin.fingerprint = fingerprint }
            pin.latitude = coordinate.latitude
            pin.longitude = coordinate.longitude
            pin.place = place
            map[id] = pin
            months[month] = map
            persistMonth(month)
        }
    }

    // MARK: Detail (LRU)

    func detail(matching record: WorkoutRecord) -> CachedWorkoutDetail? {
        queue.sync {
            let url = detailsFolderURL.appendingPathComponent("\(record.id.uuidString).json")
            guard let data = try? Data(contentsOf: url),
                  let cached = try? decoder.decode(CachedWorkoutDetail.self, from: data),
                  cached.schemaVersion >= CachedWorkoutDetail.currentSchema,
                  cached.fingerprint == Self.fingerprint(for: record) else { return nil }
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: url.path
            )
            return cached
        }
    }

    func saveDetail(_ record: WorkoutRecord) {
        let payload = CachedWorkoutDetail(record: record)
        guard payload.hasContent else { return }
        queue.sync {
            let url = detailsFolderURL.appendingPathComponent("\(record.id.uuidString).json")
            guard let data = try? encoder.encode(payload) else { return }
            try? data.write(to: url, options: .atomic)
            pruneDetailsIfNeeded()
        }
    }

    // MARK: Disk

    private func loadMonthIfNeeded(_ month: String) {
        guard !loadedMonths.contains(month) else { return }
        loadedMonths.insert(month)
        let url = pinFileURL(month)
        guard let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(CachedPinMonthFile.self, from: data) else {
            months[month] = months[month] ?? [:]
            return
        }
        var map: [UUID: CachedWorkoutPin] = months[month] ?? [:]
        for item in file.items { map[item.id] = item }
        months[month] = map
    }

    private func persistMonth(_ month: String) {
        let items = (months[month] ?? [:]).values.sorted { $0.start > $1.start }
        let file = CachedPinMonthFile(month: month, items: items)
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: pinFileURL(month), options: .atomic)
    }

    private func pinFileURL(_ month: String) -> URL {
        folderURL.appendingPathComponent("pins-\(month).json")
    }

    private func pruneOldMonthFiles() {
        let cutoff = Calendar.current.date(byAdding: .month, value: -keepMonths, to: Date()) ?? Date()
        let cutoffKey = Self.monthKey(for: cutoff)
        let prefix = "pins-"
        let suffix = ".json"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folderURL.path) else { return }
        for name in names {
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let month = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            guard month.count == 7, month < cutoffKey else { continue }
            try? FileManager.default.removeItem(at: folderURL.appendingPathComponent(name))
            months.removeValue(forKey: month)
            loadedMonths.remove(month)
        }
    }

    private func pruneDetailsIfNeeded() {
        let folder = detailsFolderURL
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let json = urls.filter { $0.pathExtension == "json" }
        guard json.count > maxDetailFiles else { return }
        let ranked = json.compactMap { url -> (URL, Date)? in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, date)
        }
        .sorted { $0.1 < $1.1 }
        let extra = ranked.count - maxDetailFiles
        guard extra > 0 else { return }
        for i in 0..<extra {
            try? FileManager.default.removeItem(at: ranked[i].0)
        }
    }
}

struct HydratedPins {
    var coords: [UUID: CLLocationCoordinate2D]
    var checked: Set<UUID>
    var places: [UUID: WorkoutPlaceInfo]
}

struct CachedWorkoutPin: Codable {
    var id: UUID
    var start: Date
    var fingerprint: String
    var latitude: Double?
    var longitude: Double?
    var checked: Bool = false
    var place: WorkoutPlaceInfo?
}

struct CachedPinMonthFile: Codable {
    var month: String
    var items: [CachedWorkoutPin]
}

struct CachedLatLon: Codable {
    var lat: Double
    var lon: Double
}

struct CachedWorkoutDetail: Codable {
    static let currentSchema = 2

    var schemaVersion: Int
    var id: UUID
    var fingerprint: String
    var savedAt: Date
    var route: [CachedLatLon]
    var elevation: [ElevationPoint]
    var heartRate: [HeartRatePoint]
    var splits: [KMSplit]
    var paceSeries: [WorkoutMetricPoint]
    var runningMetrics: RunningMetrics
    var weatherTemp: Double?
    var weatherHumidity: Double?
    var swimLapsCount: Int?
    var strokeDistribution: [String: Double]
    var swimLaps: [SwimLap]
    var swimSets: [SwimSet]
    var totalStrokeCount: Int?
    var avgSWOLF: Double?
    var bestPacePer100m: Double?
    var sessionBests: [SwimDistanceBest]

    var hasContent: Bool {
        !route.isEmpty
            || !elevation.isEmpty
            || !heartRate.isEmpty
            || !splits.isEmpty
            || !paceSeries.isEmpty
            || !runningMetrics.isEmpty
            || !swimLaps.isEmpty
            || weatherTemp != nil
            || weatherHumidity != nil
            || swimLapsCount != nil
    }

    init(record: WorkoutRecord) {
        schemaVersion = Self.currentSchema
        id = record.id
        fingerprint = WorkoutLocalCache.fingerprint(for: record)
        savedAt = Date()
        route = Self.compactRoute(record.routeCoordinates)
        elevation = record.elevationSeries
        heartRate = record.heartRateSeries
        splits = record.splits
        paceSeries = record.paceSeries
        runningMetrics = record.runningMetrics
        weatherTemp = record.weatherTemperatureC
        weatherHumidity = record.weatherHumidityPercent
        swimLapsCount = record.laps
        strokeDistribution = Dictionary(
            uniqueKeysWithValues: record.strokeDistribution.map { ($0.key.rawValue, $0.value) }
        )
        swimLaps = record.swimLaps
        swimSets = record.swimSets
        totalStrokeCount = record.totalStrokeCount
        avgSWOLF = record.avgSWOLF
        bestPacePer100m = record.bestPacePer100m
        sessionBests = record.sessionDistanceBests
    }

    func apply(to record: inout WorkoutRecord) {
        record.routeCoordinates = route.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }
        record.elevationSeries = elevation
        record.heartRateSeries = heartRate
        record.splits = splits
        record.paceSeries = paceSeries
        record.runningMetrics = runningMetrics
        record.weatherTemperatureC = weatherTemp
        record.weatherHumidityPercent = weatherHumidity
        record.laps = swimLapsCount
        record.strokeDistribution = Dictionary(
            uniqueKeysWithValues: strokeDistribution.compactMap { key, value in
                guard let stroke = SwimStroke(rawValue: key) else { return nil }
                return (stroke, value)
            }
        )
        record.swimLaps = swimLaps
        record.swimSets = swimSets
        record.totalStrokeCount = totalStrokeCount
        record.avgSWOLF = avgSWOLF
        record.bestPacePer100m = bestPacePer100m
        record.sessionDistanceBests = sessionBests
    }

    private static let maxRoutePoints = 4000

    private static func compactRoute(_ coords: [CLLocationCoordinate2D]) -> [CachedLatLon] {
        let valid = coords.filter { CLLocationCoordinate2DIsValid($0) }
        guard valid.count > maxRoutePoints else {
            return valid.map { CachedLatLon(lat: $0.latitude, lon: $0.longitude) }
        }
        let step = Double(valid.count - 1) / Double(maxRoutePoints - 1)
        return (0..<maxRoutePoints).map { index in
            let source = valid[min(Int((Double(index) * step).rounded()), valid.count - 1)]
            return CachedLatLon(lat: source.latitude, lon: source.longitude)
        }
    }
}
