import CoreLocation

/// HealthKit / GPS 为 WGS-84；大陆 MapKit（高德底图）按 GCJ-02 渲染。
/// 不转换时轨迹形状正确，但相对道路常整体偏西（看起来「往左偏」）。
enum ChinaCoordinateTransform {
    /// 将 WGS-84 点转为 MapKit 在大陆应使用的 GCJ-02；境外原样返回。
    static func wgs84ToGcj02(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInMainlandChina(coordinate) else { return coordinate }
        let (dLat, dLon) = delta(lat: coordinate.latitude, lon: coordinate.longitude)
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + dLat,
            longitude: coordinate.longitude + dLon
        )
    }

    static func wgs84ToGcj02(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard let first = coordinates.first, isInMainlandChina(first) else { return coordinates }
        return coordinates.map(wgs84ToGcj02)
    }

    // MARK: - 区域判断（含港澳台近似排除）

    private static func isInMainlandChina(_ c: CLLocationCoordinate2D) -> Bool {
        let lat = c.latitude, lon = c.longitude
        // 粗框
        guard lat >= 0.8293, lat <= 55.8271, lon >= 72.004, lon <= 137.8347 else { return false }
        // 台湾
        if lat >= 21.1, lat <= 25.6, lon >= 119.3, lon <= 122.5 { return false }
        // 香港
        if lat >= 22.13, lat <= 22.58, lon >= 113.82, lon <= 114.5 { return false }
        // 澳门
        if lat >= 22.0, lat <= 22.25, lon >= 113.5, lon <= 113.65 { return false }
        return true
    }

    // MARK: - 标准加密偏移（与常见 eviltransform / coordtransform 一致）

    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323

    private static func delta(lat: Double, lon: Double) -> (Double, Double) {
        var dLat = transformLat(lon - 105.0, lat - 35.0)
        var dLon = transformLon(lon - 105.0, lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return (dLat, dLon)
    }

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}
