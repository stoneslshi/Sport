import Foundation
import HealthKit
import CoreLocation

/// 某一天的日常活动数据
struct DailyActivity: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    var steps: Double = 0
    var distanceKM: Double = 0
    var activeEnergyKcal: Double = 0
    var exerciseMinutes: Double = 0
    var standMinutes: Double = 0
    var flightsClimbed: Double = 0

    var isToday: Bool { Calendar.current.isDateInToday(date) }
}

/// 心率相关指标
struct HeartMetrics {
    /// 静息心率（最近一次）
    var restingHR: Double?
    /// 近 7 天平均心率
    var averageHR7d: Double?
    /// 心率变异性 SDNN（最近一次，毫秒）
    var hrvSDNN: Double?
}

/// 身体档案（来自健康 App 的身体测量与个人资料）
struct BodyProfile {
    var ageYears: Int?
    var biologicalSex: String?
    var heightCM: Double?
    var weightKG: Double?
    /// 体脂率，0-100 数值
    var bodyFatPercent: Double?
    /// VO₂ Max（mL/kg·min），无则 nil
    var vo2Max: Double?

    var bmi: Double? {
        guard let w = weightKG, let h = heightCM, h > 0 else { return nil }
        let m = h / 100.0
        return w / (m * m)
    }

    /// 中国成人 BMI 标准
    var bmiCategory: (text: String, isHealthy: Bool)? {
        guard let bmi else { return nil }
        switch bmi {
        case ..<18.5: return ("偏瘦", false)
        case 18.5..<24: return ("正常", true)
        case 24..<28: return ("超重", false)
        default: return ("肥胖", false)
        }
    }

    /// 估算基础代谢率（Mifflin-St Jeor 公式）
    var estimatedBMR: Double? {
        guard let w = weightKG, let h = heightCM, let age = ageYears else { return nil }
        let base = 10 * w + 6.25 * h - 5 * Double(age)
        if biologicalSex == "女" { return base - 161 }
        return base + 5
    }
}

/// 体重/体脂时间序列上的一点
struct BodyMetricPoint: Identifiable, Equatable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// 身体趋势（体重 / 体脂历史）
struct BodyTrends {
    var weightPoints: [BodyMetricPoint] = []
    var bodyFatPoints: [BodyMetricPoint] = []

    func weightDelta(inDays days: Int) -> Double? {
        delta(in: weightPoints, days: days)
    }

    func bodyFatDelta(inDays days: Int) -> Double? {
        delta(in: bodyFatPoints, days: days)
    }

    private func delta(in points: [BodyMetricPoint], days: Int) -> Double? {
        guard let latest = points.last else { return nil }
        let cal = Calendar.current
        guard let start = cal.date(byAdding: .day, value: -days, to: latest.date) else { return nil }
        guard let baseline = points.last(where: { $0.date <= start }) ?? points.first else { return nil }
        if baseline.date == latest.date { return nil }
        return latest.value - baseline.value
    }

    func weightSeries(inDays days: Int) -> [BodyMetricPoint] {
        filter(points: weightPoints, days: days)
    }

    func bodyFatSeries(inDays days: Int) -> [BodyMetricPoint] {
        filter(points: bodyFatPoints, days: days)
    }

    private func filter(points: [BodyMetricPoint], days: Int) -> [BodyMetricPoint] {
        guard let last = points.last?.date,
              let start = Calendar.current.date(byAdding: .day, value: -days, to: last) else { return points }
        return points.filter { $0.date >= start }
    }
}

/// 恢复基线（近周体质，非昨夜）
struct RecoveryBaseline {
    var restingHR: Double?
    /// 较前一周静息心率变化（负=下降=更好）
    var restingHRDelta: Double?
    var hrvSDNN: Double?
    var averageHR7d: Double?
}

/// 身体页趋势时间范围
enum BodyTrendRange: Int, CaseIterable, Identifiable {
    case days30 = 30
    case days90 = 90
    var id: Int { rawValue }
    var label: String { self == .days30 ? "近30天" : "近90天" }
}

/// 一条运动训练记录
struct WorkoutRecord: Identifiable {
    let id: UUID
    let activityType: HKWorkoutActivityType
    let start: Date
    let end: Date
    let durationMinutes: Double
    let caloriesKcal: Double
    let distanceKM: Double?
    /// 平均心率（次/分）
    var avgHR: Double?
    /// 最高心率（次/分）
    var maxHR: Double?
    /// 累计爬升（米）
    var elevationGain: Double?

    /// 泳池长度（米），仅泳池游泳有；开放水域为 nil
    var poolLength: Double?

    /// 趟数（往返一个池长记 1 趟），延迟加载
    var laps: Int?

    /// 泳姿分布：泳姿 -> 该泳姿累计距离（米），延迟加载
    var strokeDistribution: [SwimStroke: Double] = [:]

    /// 每趟明细（泳池游泳，延迟加载）
    var swimLaps: [SwimLap] = []
    /// 自动分组（按休息间隔，延迟加载）
    var swimSets: [SwimSet] = []
    /// 总划次（延迟加载）
    var totalStrokeCount: Int?
    /// 平均 SWOLF（有划次时，延迟加载）
    var avgSWOLF: Double?
    /// 本场最快配速（分钟/100m，延迟加载）
    var bestPacePer100m: Double?
    /// 本场距离最佳分段（100/200/…，延迟加载）
    var sessionDistanceBests: [SwimDistanceBest] = []
    /// 心率区间占比（延迟加载）
    var hrZones: [HRZoneSlice] = []

    /// 是否为游泳
    var isSwimming: Bool { activityType == .swimming }

    /// 是否含 GPS 轨迹（至少 2 个点才画线）
    var hasRoute: Bool { routeCoordinates.count >= 2 }

    /// 运动时气温（摄氏度）
    var weatherTemperatureC: Double?

    /// 运动时相对湿度（0–100）
    var weatherHumidityPercent: Double?

    var hasWeatherInfo: Bool {
        weatherTemperatureC != nil || weatherHumidityPercent != nil
    }

    /// GPS 轨迹坐标（延迟加载，详情页进入时才填充）
    var routeCoordinates: [CLLocationCoordinate2D] = []

    /// 海拔曲线（相对开始分钟, 海拔米；延迟加载，来自 GPS 轨迹）
    var elevationSeries: [ElevationPoint] = []

    /// 详情页心率采样曲线（相对时间秒, bpm）
    var heartRateSeries: [HeartRatePoint] = []

    /// 分段配速（跑步等：分钟/公里；游泳：分钟/100m）
    var splits: [KMSplit] = []

    /// 平均配速（分钟/公里），仅对有距离的运动有意义
    var avgPaceMinPerKM: Double? {
        guard let km = distanceKM, km > 0 else { return nil }
        return durationMinutes / km
    }

    /// 游泳平均配速（分钟/100 米），游泳专用
    var avgPacePer100m: Double? {
        guard let km = distanceKM, km > 0 else { return nil }
        let meters = km * 1000
        return durationMinutes / (meters / 100)
    }
}

/// 户外运动在地图上的位置钉（用轨迹起点代表一次运动）。
struct WorkoutMapPin: Identifiable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let activityType: HKWorkoutActivityType
    let start: Date
}

/// 游泳泳姿
enum SwimStroke: String, CaseIterable, Identifiable {
    case freestyle   // 自由泳
    case breaststroke // 蛙泳
    case backstroke  // 仰泳
    case butterfly   // 蝶泳
    case mixed       // 混合泳
    case unknown     // 未知

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .freestyle:    return "自由泳"
        case .breaststroke: return "蛙泳"
        case .backstroke:   return "仰泳"
        case .butterfly:    return "蝶泳"
        case .mixed:        return "混合泳"
        case .unknown:      return "其他"
        }
    }

    /// 配色名（供 Color(themeName:) 使用）
    var tintName: String {
        switch self {
        case .freestyle:    return "cyan"
        case .breaststroke: return "green"
        case .backstroke:   return "blue"
        case .butterfly:    return "orange"
        case .mixed:        return "purple"
        case .unknown:      return "pink"
        }
    }
}

/// 心率曲线上的一个点
struct HeartRatePoint: Identifiable {
    let id = UUID()
    /// 距开始的分钟数
    let minute: Double
    let bpm: Double
}

/// 海拔曲线上的一个点
struct ElevationPoint: Identifiable {
    let id = UUID()
    /// 距开始的分钟数
    let minute: Double
    /// 海拔（米）
    let meters: Double
}

/// 分段配速
struct KMSplit: Identifiable {
    let id = UUID()
    /// 第几段（1 起）
    let index: Int
    /// 该段用时（分钟）——跑步等为分钟/公里，游泳为分钟/100m
    let paceMin: Double
    /// 每段距离（米）：跑步 1000，游泳 100
    var segmentMeters: Double = 1000

    var isPer100m: Bool { segmentMeters <= 100 }
}

/// 游泳一趟明细
struct SwimLap: Identifiable {
    let id = UUID()
    let index: Int
    let start: Date
    let end: Date
    let distanceM: Double
    let stroke: SwimStroke
    var strokeCount: Int?

    var durationSec: Double { max(end.timeIntervalSince(start), 0) }

    /// 分钟/100m
    var paceMinPer100m: Double? {
        guard distanceM > 0, durationSec > 0 else { return nil }
        return (durationSec / 60.0) / (distanceM / 100.0)
    }

    /// SWOLF ≈ 该趟用时（秒）+ 划次
    var swolf: Double? {
        guard let sc = strokeCount, sc > 0, durationSec > 0 else { return nil }
        return durationSec + Double(sc)
    }
}

/// 游泳自动组（趟与趟之间休息拆分）
struct SwimSet: Identifiable {
    let id = UUID()
    let index: Int
    let startLap: Int
    let endLap: Int
    let distanceM: Double
    let activeSec: Double
    let restSec: Double

    var lapLabel: String {
        startLap == endLap ? "\(startLap)" : "\(startLap)–\(endLap)"
    }

    var avgPaceMinPer100m: Double? {
        guard distanceM > 0, activeSec > 0 else { return nil }
        return (activeSec / 60.0) / (distanceM / 100.0)
    }
}

/// 本场某标准距离的最佳用时
struct SwimDistanceBest: Identifiable {
    let id = UUID()
    let meters: Int
    let timeSec: Double
}

/// 心率五区中的一区（始终五段齐全，可为 0 时长）
struct HRZoneSlice: Identifiable {
    let id = UUID()
    /// 1…5
    let index: Int
    /// 热身 / 燃脂 / 有氧耐力 / 无氧耐力 / 极限
    let name: String
    /// 区间秒数
    let seconds: Double
    let tintName: String
    /// 0–1
    let fraction: Double
    /// BPM 下界（含）
    let bpmLow: Int
    /// BPM 上界（含）；nil 表示无上界（如 165+）
    let bpmHigh: Int?

    var minutes: Double { seconds / 60 }

    var rangeText: String {
        if let high = bpmHigh {
            if index == 1 { return "<\(high + 1) 次/分" }
            return "\(bpmLow)–\(high) 次/分"
        }
        return "\(bpmLow)+ 次/分"
    }

    var durationText: String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

/// 按运动类型聚合的统计
struct WorkoutTypeStat: Identifiable {
    let activityType: HKWorkoutActivityType
    var count: Int = 0
    var totalMinutes: Double = 0
    var totalKcal: Double = 0
    var totalKM: Double = 0

    var id: UInt { activityType.rawValue }
}
