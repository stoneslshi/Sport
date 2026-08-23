import CoreLocation

/// HealthKit / GPS 为 WGS-84；大陆 MapKit（高德底图）按 GCJ-02 渲染。
/// 不转换时轨迹形状正确，但相对道路常整体偏西（看起来「往左偏」）。
/// 境外（含港澳台、新加坡、日韩等）底图为 WGS-84，不得套用 GCJ 偏移。
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

    // MARK: - 区域判断（含港澳台及周边国家排除）

    /// 是否应按大陆 GCJ-02 偏移。
    ///
    /// 旧实现沿用 eviltransform 粗框（北纬 ≥ 0.8293、东经 72–138），
    /// 新加坡（约 1.35°N, 103.8°E）会落在框内被错误加密，轨迹相对道路整体偏移。
    /// 海南岛南端约 18.16°N，以此为南界即可排除新马泰等，同时保留三亚等海南轨迹。
    private static func isInMainlandChina(_ c: CLLocationCoordinate2D) -> Bool {
        let lat = c.latitude, lon = c.longitude
        // 大陆实际范围：乌恰以西约 73.5°E，抚远约 134.8°E，漠河约 53.5°N，海南约 18.1°N
        guard lat >= 18.10, lat <= 53.56, lon >= 73.50, lon <= 135.05 else { return false }

        // 台湾
        if lat >= 21.1, lat <= 25.6, lon >= 119.3, lon <= 122.5 { return false }
        // 香港
        if lat >= 22.13, lat <= 22.58, lon >= 113.82, lon <= 114.5 { return false }
        // 澳门
        if lat >= 22.0, lat <= 22.25, lon >= 113.5, lon <= 113.65 { return false }

        // 日本本州/九州/四国。珲春约 42.9°N、绥芬河约 44.4°N，纬度更高不会被裁。
        if lat >= 24.0, lat <= 41.7, lon >= 128.8 { return false }
        // 琉球 / 冲绳（台湾以东）
        if lat >= 24.0, lat <= 28.5, lon >= 122.7, lon <= 131.5 { return false }

        // 韩国（含济州）。丹东约 40.1°N, 124.4°E，不在此框。
        if lat >= 33.0, lat <= 38.65, lon >= 124.5, lon <= 129.8 { return false }

        // 越南北部（河内一带）。东兴约 21.55°N，海南经度 > 108.6，均避开。
        if lat < 21.50, lon >= 102.2, lon <= 108.0 { return false }

        // 菲律宾北部吕宋（南界抬到海南后仍可能落入粗框）
        if lat <= 21.2, lon >= 116.0, lon <= 127.0 { return false }

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
