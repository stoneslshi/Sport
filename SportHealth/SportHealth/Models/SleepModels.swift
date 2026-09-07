import Foundation

/// 睡眠阶段（对应 HKCategoryValueSleepAnalysis 的聚合分类）
enum SleepStage: String, CaseIterable, Identifiable {
    case deep = "深睡"
    case core = "核心睡眠"
    case rem = "REM"
    case awake = "清醒"

    var id: String { rawValue }

    /// 展示配色（与原型一致）
    var colorName: String {
        switch self {
        case .deep:  return "sleepDeep"
        case .core:  return "sleepCore"
        case .rem:   return "sleepREM"
        case .awake: return "sleepAwake"
        }
    }
}

/// 分期时间轴上的一段（简化 hypnogram）
struct SleepStageSegment: Identifiable, Equatable {
    let stage: SleepStage
    let start: Date
    let end: Date

    var id: Date { start }

    var durationMin: Double { end.timeIntervalSince(start) / 60 }
}

/// 午睡（不计入主睡眠）
struct SleepNap: Equatable {
    var start: Date
    var end: Date
    var asleepMin: Double
}

/// 夜间生命体征（主睡眠窗内）
struct SleepVitals: Equatable {
    /// 呼吸频率（次/分）
    var respiratoryRate: Double?
    /// 血氧饱和度 0–1（展示时 ×100）
    var oxygenSaturation: Double?
    /// 腕温相对个人基线的偏差（°C）；优先展示
    var wristTempDelta: Double?
    /// 绝对温度（°C）：腕温历史不足 5 晚，或无腕温时的体温兜底
    var wristTempAbsolute: Double?
    /// 绝对值为 Apple Watch 腕温且基线尚未建立
    var wristTempNeedsBaseline: Bool = false

    var hasAny: Bool {
        respiratoryRate != nil || oxygenSaturation != nil
            || wristTempDelta != nil || wristTempAbsolute != nil
    }
}

/// 某一晚的睡眠数据（以「起床日」归属，即凌晨醒来算当天）
struct SleepNight: Identifiable, Equatable {
    /// 归属日期（起床日 0 点）
    let date: Date
    /// 入睡时间（主睡眠段首个睡着样本开始；不含午睡）
    var inBed: Date
    /// 起床时间（主睡眠段最后一次睡着结束；不含午睡、不含起床后清醒）
    var wake: Date
    /// 睡着总时长（分钟）：所有睡着阶段的时间并集
    var asleepMin: Double = 0
    /// 各阶段累计分钟（来自同一优选数据源的分期）
    var deepMin: Double = 0
    var coreMin: Double = 0
    var remMin: Double = 0
    var awakeMin: Double = 0
    /// 分期时间轴片段（优选数据源）
    var segments: [SleepStageSegment] = []
    /// 入睡日前一天的白天短睡（约 10:00–17:00；若有）
    var nap: SleepNap?
    /// 主睡眠窗内生命体征
    var vitals: SleepVitals = SleepVitals()

    var id: Date { date }

    /// 卧床总时长（分钟）：入睡→起床的墙钟时间
    var inBedMin: Double {
        max(wake.timeIntervalSince(inBed) / 60, 0)
    }

    /// 睡眠时长（小时）
    var asleepHours: Double { asleepMin / 60 }

    /// 睡眠效率（睡着时间 / 卧床时间）
    var efficiency: Double {
        inBedMin > 0 ? min(asleepMin / inBedMin, 1) : 0
    }

    /// 各阶段分钟映射（供 UI 遍历）
    func minutes(of stage: SleepStage) -> Double {
        switch stage {
        case .deep:  return deepMin
        case .core:  return coreMin
        case .rem:   return remMin
        case .awake: return awakeMin
        }
    }

    /// 设置某阶段累计分钟（供聚合时区间合并后写入）
    mutating func setMinutes(_ mins: Double, of stage: SleepStage) {
        switch stage {
        case .deep:  deepMin = mins
        case .core:  coreMin = mins
        case .rem:   remMin = mins
        case .awake: awakeMin = mins
        }
    }

    /// 入睡小时（用于作息规律条，24 制小数）
    var inBedHour: Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: inBed)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    var wakeHour: Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: wake)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }
}

/// 昨夜相对「平常」的对比
struct SleepComparison {
    /// 入睡差值（分钟）；负=更早
    var bedDeltaMin: Int = 0
    /// 时长差值（分钟）；正=更长
    var durDeltaMin: Int = 0
    /// 深睡差值（分钟）；正=更多
    var deepDeltaMin: Int = 0
    var avgBedLabel: String = "—"
    var avgDurLabel: String = "—"
    var avgDeepLabel: String = "—"
}

/// 近一段时间睡眠汇总
struct SleepSummary {
    /// 平均睡眠时长（小时）
    var avgAsleepHours: Double = 0
    /// 平均深睡分钟
    var avgDeepMin: Double = 0
    /// 平均睡眠效率 0-1
    var avgEfficiency: Double = 0
    /// 达标夜数（睡眠 ≥ 7 小时）
    var goodNights: Int = 0
    /// 统计夜数
    var nightCount: Int = 0
    /// 作息规律性 0-100（入睡时间标准差越小越高）
    var regularityScore: Int = 0
    /// 睡眠评分 0-100（最近一晚）
    var lastNightScore: Int = 0
}

/// 睡眠与恢复的关联洞察（本地规则计算）
struct SleepInsight: Identifiable {
    let id = UUID()
    let icon: String
    let tint: LocalTip.TipLevel
    let title: String
    let detail: String
}

/// 睡眠趋势图指标
enum SleepTrendMetric: String, CaseIterable, Identifiable {
    case hours = "时长"
    case deep = "深睡"
    case efficiency = "效率"
    case score = "评分"

    var id: String { rawValue }
}
