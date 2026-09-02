import Foundation
import CoreLocation

/// 把 GPS 起点收成约 1 km 的格子，逆地理成城市/国家。结果落盘，地图可边识别边出卡片。
actor PlaceGeocoder {
    static let shared = PlaceGeocoder()

    private let geocoder = CLGeocoder()
    /// 同一时刻只跑一次 CLGeocoder；actor 在 await 时会重入，必须自己排队。
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func place(for coordinate: CLLocationCoordinate2D) async -> WorkoutPlaceInfo? {
        let key = PlaceGeocodeCache.cellKey(coordinate)
        if let cached = PlaceGeocodeCache.shared.get(key), cached.isResolved { return cached }
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        await acquire()
        defer { release() }

        if let cached = PlaceGeocodeCache.shared.get(key), cached.isResolved { return cached }

        if let info = await geocode(coordinate) {
            PlaceGeocodeCache.shared.set(key, info)
            return info
        }
        if let hint = GeoPlaceHint.infer(from: coordinate) {
            PlaceGeocodeCache.shared.set(key, hint)
            return hint
        }
        return nil
    }

    private func geocode(_ coordinate: CLLocationCoordinate2D) async -> WorkoutPlaceInfo? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let locales = [Locale(identifier: "zh_CN"), Locale(identifier: "en_SG"), Locale(identifier: "en")]
        for locale in locales {
            do {
                let marks = try await reverse(location, locale: locale)
                if let mark = marks.first {
                    let info = WorkoutPlaceInfo.from(placemark: mark)
                    if info.isResolved { return info }
                    if let hinted = GeoPlaceHint.infer(from: coordinate) { return hinted }
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func reverse(_ location: CLLocation, locale: Locale) async throws -> [CLPlacemark] {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceResume(continuation)
            geocoder.reverseGeocodeLocation(location, preferredLocale: locale) { marks, error in
                if let error {
                    once.resume(throwing: error)
                } else {
                    once.resume(returning: marks ?? [])
                }
            }
        }
    }
}

/// CLGeocoder 回调和取消可能各走一次，保证 continuation 只 resume 一次。
private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[CLPlacemark], Error>?

    init(_ continuation: CheckedContinuation<[CLPlacemark], Error>) {
        self.continuation = continuation
    }

    func resume(returning value: [CLPlacemark]) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<[CLPlacemark], Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}

/// 系统逆地理在海域 / 城市国家上经常没有 country。用范围兜底，至少能列出国家。
private enum GeoPlaceHint {
    static func infer(from coordinate: CLLocationCoordinate2D) -> WorkoutPlaceInfo? {
        let lat = coordinate.latitude, lon = coordinate.longitude
        // 新加坡本岛及近岸（北界避开柔佛巴鲁约 1.49°N）
        if lat >= 1.15, lat <= 1.478, lon >= 103.60, lon <= 104.12 {
            return WorkoutPlaceInfo(
                locality: "新加坡",
                subLocality: nil,
                administrativeArea: nil,
                country: "新加坡",
                isoCountryCode: "SG"
            )
        }
        return nil
    }
}
final class PlaceGeocodeCache: @unchecked Sendable {
    static let shared = PlaceGeocodeCache()

    private let fileName = "place_geocode_cache.json"
    private let lock = NSLock()
    private var memory: [String: WorkoutPlaceInfo] = [:]
    private var loaded = false

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("SportHealth", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(fileName)
    }

    static func cellKey(_ coordinate: CLLocationCoordinate2D) -> String {
        let lat = (coordinate.latitude * 100).rounded() / 100
        let lon = (coordinate.longitude * 100).rounded() / 100
        return String(format: "%.2f,%.2f", lat, lon)
    }

    func get(_ key: String) -> WorkoutPlaceInfo? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return memory[key]
    }

    func set(_ key: String, _ info: WorkoutPlaceInfo) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        memory[key] = info
        persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: WorkoutPlaceInfo].self, from: data) else {
            memory = [:]
            return
        }
        memory = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
