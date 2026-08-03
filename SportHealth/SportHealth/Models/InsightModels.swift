import Foundation

/// 一个周期（周/月）的统计汇总
struct PeriodSummary {
    var totalSteps: Double = 0
    var avgSteps: Double = 0
    var totalEnergyKcal: Double = 0
    var avgEnergyKcal: Double = 0
    var totalExerciseMin: Double = 0
    var totalDistanceKM: Double = 0
    /// 活动能量达标天数（唯一的目标维度；步数仅作展示，不设目标）
    var energyGoalHitDays: Int = 0
    /// 与上一周期相比的活动能量变化百分比（正数为增长）
    var energyTrendPercent: Double?
    /// 最活跃的一天（按活动能量）
    var mostActiveDay: Date?
    /// 综合活动评分 0-100
    var activityScore: Int = 0
}

/// 本地规则引擎生成的一条建议
struct LocalTip: Identifiable {
    let id = UUID()
    let icon: String
    let tint: TipLevel
    let title: String
    let detail: String
    /// 点击后跳转的 Tab（概览决策页用）
    var destination: AppTab? = nil

    enum TipLevel {
        case good, notice, warning
    }
}

/// App 底部 Tab（用于跨页跳转）
enum AppTab: Hashable {
    case home, workouts, sleep, body, advice
}
