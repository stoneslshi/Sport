import Foundation

/// 本地统计分析引擎：趋势、目标达成、活动评分、规则建议、AI 摘要文本。
enum AnalysisEngine {

    // MARK: - 周期汇总

    /// 汇总一个周期的数据；可传入上一周期用于计算趋势。
    /// 目标维度仅活动能量；步数只统计展示值，不参与达标判定。
    static func summarize(current: [DailyActivity],
                          previous: [DailyActivity],
                          energyGoal: Double) -> PeriodSummary {
        var summary = PeriodSummary()
        guard !current.isEmpty else { return summary }

        summary.totalSteps = current.reduce(0) { $0 + $1.steps }
        summary.avgSteps = summary.totalSteps / Double(current.count)
        summary.totalEnergyKcal = current.reduce(0) { $0 + $1.activeEnergyKcal }
        summary.avgEnergyKcal = summary.totalEnergyKcal / Double(current.count)
        summary.totalExerciseMin = current.reduce(0) { $0 + $1.exerciseMinutes }
        summary.totalDistanceKM = current.reduce(0) { $0 + $1.distanceKM }
        summary.energyGoalHitDays = current.filter { $0.activeEnergyKcal >= energyGoal }.count
        summary.mostActiveDay = current.max(by: { $0.activeEnergyKcal < $1.activeEnergyKcal })?.date

        let previousEnergy = previous.reduce(0) { $0 + $1.activeEnergyKcal }
        if previousEnergy > 0 {
            summary.energyTrendPercent = (summary.totalEnergyKcal - previousEnergy) / previousEnergy * 100
        }

        summary.activityScore = activityScore(
            avgEnergy: summary.avgEnergyKcal,
            avgExerciseMin: summary.totalExerciseMin / Double(current.count),
            energyGoal: energyGoal
        )
        return summary
    }

    /// 综合活动评分：活动能量 60% + 锻炼时长 40%（对标每日 30 分钟）。步数不计入评分。
    static func activityScore(avgEnergy: Double,
                              avgExerciseMin: Double,
                              energyGoal: Double,
                              exerciseGoalMin: Double = 30) -> Int {
        let energyPart = min(avgEnergy / max(energyGoal, 1), 1.0) * 60
        let exercisePart = min(avgExerciseMin / exerciseGoalMin, 1.0) * 40
        return Int((energyPart + exercisePart).rounded())
    }

    /// 今日评分（用今日实际值而非平均值）
    static func todayScore(today: DailyActivity, energyGoal: Double) -> Int {
        activityScore(
            avgEnergy: today.activeEnergyKcal,
            avgExerciseMin: today.exerciseMinutes,
            energyGoal: energyGoal
        )
    }

    // MARK: - 本地规则建议

    static func localTips(today: DailyActivity?,
                          week: PeriodSummary,
                          body: BodyProfile,
                          heart: HeartMetrics,
                          workouts: [WorkoutRecord],
                          energyGoal: Double) -> [LocalTip] {
        var tips: [LocalTip] = []

        // 今日活动能量（唯一目标维度）
        if let today {
            if today.activeEnergyKcal >= energyGoal {
                tips.append(LocalTip(icon: "checkmark.seal.fill", tint: .good,
                                     title: "今日活动能量已达标",
                                     detail: "已消耗 \(Int(today.activeEnergyKcal)) kcal，达到 \(Int(energyGoal)) kcal 目标，保持这个节奏。"))
            } else {
                let remaining = Int(energyGoal - today.activeEnergyKcal)
                let walkMin = max(remaining / 5, 1) // 快走约每分钟消耗 5 kcal
                tips.append(LocalTip(icon: "flame", tint: .notice,
                                     title: "今日还差 \(remaining) kcal",
                                     detail: "大约再快走 \(walkMin) 分钟即可达成能量目标。"))
            }
        }

        // 周运动量（WHO 建议每周至少 150 分钟中等强度）
        if week.totalExerciseMin < 150 {
            tips.append(LocalTip(icon: "heart.text.square", tint: .warning,
                                 title: "本周锻炼时长不足",
                                 detail: "本周锻炼 \(Int(week.totalExerciseMin)) 分钟，WHO 建议每周至少 150 分钟中等强度运动。"))
        } else {
            tips.append(LocalTip(icon: "flame.fill", tint: .good,
                                 title: "本周运动量达标",
                                 detail: "本周累计锻炼 \(Int(week.totalExerciseMin)) 分钟，达到 WHO 推荐量。"))
        }

        // 趋势（按活动能量）
        if let trend = week.energyTrendPercent {
            if trend <= -20 {
                tips.append(LocalTip(icon: "chart.line.downtrend.xyaxis", tint: .warning,
                                     title: "活动量明显下降",
                                     detail: "本周活动能量较上周期下降 \(Int(abs(trend)))%，注意别中断运动习惯。"))
            } else if trend >= 20 {
                tips.append(LocalTip(icon: "chart.line.uptrend.xyaxis", tint: .good,
                                     title: "活动量显著提升",
                                     detail: "本周活动能量较上周期提升 \(Int(trend))%，进步明显，注意循序渐进避免受伤。"))
            }
        }

        // 运动记录
        let weekWorkouts = workouts.filter { $0.start > Date().addingTimeInterval(-7 * 24 * 3600) }
        if weekWorkouts.isEmpty {
            tips.append(LocalTip(icon: "dumbbell.fill", tint: .notice,
                                 title: "近 7 天没有运动训练记录",
                                 detail: "可以从每周 2-3 次、每次 20-30 分钟的快走或慢跑开始建立习惯。"))
        }

        // BMI
        if let category = body.bmiCategory, let bmi = body.bmi {
            if category.isHealthy {
                tips.append(LocalTip(icon: "person.fill.checkmark", tint: .good,
                                     title: "BMI 处于正常范围",
                                     detail: "当前 BMI \(bmi.oneDecimal)，继续保持均衡饮食与规律运动。"))
            } else {
                tips.append(LocalTip(icon: "scalemass.fill", tint: .notice,
                                     title: "BMI \(category.text)",
                                     detail: "当前 BMI \(bmi.oneDecimal)（中国标准正常区间 18.5-23.9），建议结合有氧运动与饮食管理逐步改善。"))
            }
        }

        // 静息心率
        if let resting = heart.restingHR {
            if resting >= 80 {
                tips.append(LocalTip(icon: "heart.fill", tint: .warning,
                                     title: "静息心率偏高",
                                     detail: "最近静息心率 \(Int(resting)) 次/分，规律有氧运动、充足睡眠有助于降低静息心率。如有不适请咨询医生。"))
            } else if resting <= 60 {
                tips.append(LocalTip(icon: "heart.fill", tint: .good,
                                     title: "静息心率优秀",
                                     detail: "静息心率 \(Int(resting)) 次/分，心肺功能状态不错。"))
            }
        }

        return tips
    }

    /// 概览决策页优先提示：最多 2 条，带跳转。
    static func priorityTips(today: DailyActivity?,
                             week: PeriodSummary,
                             lastNight: SleepNight?,
                             nights: [SleepNight],
                             energyGoal: Double,
                             sleepScore: Int) -> [LocalTip] {
        var tips: [LocalTip] = []

        if let today {
            if today.activeEnergyKcal >= energyGoal {
                tips.append(LocalTip(icon: "checkmark.seal.fill", tint: .good,
                                     title: "今日活动能量已达标",
                                     detail: "已消耗 \(Int(today.activeEnergyKcal)) kcal。可生成本日建议做恢复安排。",
                                     destination: .advice))
            } else {
                let remaining = Int((energyGoal - today.activeEnergyKcal).rounded())
                let walkMin = max(remaining / 5, 1)
                tips.append(LocalTip(icon: "flame.fill", tint: .notice,
                                     title: "再消耗 \(remaining) kcal 就达标",
                                     detail: "约等于快走 \(walkMin) 分钟。点此生成本日运动建议。",
                                     destination: .advice))
            }
        }

        if let night = lastNight {
            let impact = sleepImpactOnToday(night: night, nights: nights, score: sleepScore)
            tips.append(LocalTip(icon: "moon.stars.fill", tint: sleepScore >= 75 ? .good : .notice,
                                 title: sleepScore >= 75 ? "昨夜恢复良好" : "昨夜睡眠一般",
                                 detail: impact,
                                 destination: .sleep))
        }

        return Array(tips.prefix(2))
    }

    /// Hero 一句话结论。
    static func dashboardVerdict(today: DailyActivity?,
                                 energyGoal: Double,
                                 lastNight: SleepNight?,
                                 sleepScore: Int,
                                 nights: [SleepNight]) -> String {
        var parts: [String] = []
        if let today {
            if today.activeEnergyKcal >= energyGoal {
                parts.append("今日活动能量已达标（\(Int(today.activeEnergyKcal)) kcal）")
            } else {
                let gap = Int((energyGoal - today.activeEnergyKcal).rounded())
                parts.append("今日活动能量还差 \(gap) kcal 即可达标")
            }
        }
        if lastNight != nil {
            if sleepScore >= 80 {
                parts.append("昨夜睡眠评分 \(sleepScore)，恢复良好，适合轻松有氧")
            } else if sleepScore >= 65 {
                parts.append("昨夜睡眠评分 \(sleepScore)，今日建议中低强度")
            } else {
                parts.append("昨夜睡眠评分 \(sleepScore)，今日宜减量恢复")
            }
        }
        return parts.isEmpty ? "授权健康数据后，这里会给出今日行动建议。" : parts.joined(separator: "；") + "。"
    }

    /// 近 7 日洞察文案。
    static func weekInsight(week: PeriodSummary) -> String {
        var parts: [String] = []
        if let trend = week.energyTrendPercent {
            let dir = trend >= 0 ? "上升" : "下降"
            parts.append("活动能量周环比\(dir) \(Int(abs(trend).rounded()))%")
        }
        parts.append("能量达标 \(week.energyGoalHitDays)/7 天")
        parts.append("锻炼 \(Int(week.totalExerciseMin)) 分钟")
        return parts.joined(separator: "，") + "。"
    }

    /// 昨夜睡眠对今日训练强度的影响说明。
    static func sleepImpactOnToday(night: SleepNight,
                                   nights: [SleepNight],
                                   score: Int) -> String {
        let cmp = sleepComparison(night: night, nights: nights)
        var lead = ""
        if abs(cmp.bedDeltaMin) >= 3 {
            lead = cmp.bedDeltaMin < 0
                ? "昨夜比平常早睡 \(abs(cmp.bedDeltaMin)) 分钟，"
                : "昨夜比平常晚睡 \(cmp.bedDeltaMin) 分钟，"
        }
        if score >= 80 {
            return lead + "恢复良好 → 今日宜保持轻松有氧，不必硬上高强度"
        } else if score >= 65 {
            return lead + "恢复尚可 → 今日建议中低强度，注意热身"
        } else {
            return lead + "恢复一般 → 今日宜减量或以散步拉伸为主"
        }
    }

    // MARK: - 睡眠分析

    /// 汇总近 N 晚睡眠：平均时长、深睡、效率、达标夜数、作息规律性、最近一晚评分。
    static func summarizeSleep(nights: [SleepNight]) -> SleepSummary {
        var s = SleepSummary()
        guard !nights.isEmpty else { return s }
        s.nightCount = nights.count
        s.avgAsleepHours = nights.reduce(0) { $0 + $1.asleepHours } / Double(nights.count)
        s.avgDeepMin = nights.reduce(0) { $0 + $1.deepMin } / Double(nights.count)
        s.avgEfficiency = nights.reduce(0) { $0 + $1.efficiency } / Double(nights.count)
        s.goodNights = nights.filter { $0.asleepHours >= 7 }.count

        // 作息规律性：入睡时间的标准差越小越规律（映射到 0-100）
        let bedHours = nights.map { h -> Double in
            // 把凌晨入睡（如 0.5）视为 24.5，避免与晚间 23 拉开巨大距离
            h.inBedHour < 12 ? h.inBedHour + 24 : h.inBedHour
        }
        if bedHours.count >= 2 {
            let mean = bedHours.reduce(0, +) / Double(bedHours.count)
            let variance = bedHours.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(bedHours.count)
            let std = variance.squareRoot() // 单位小时
            // std=0 → 100 分；std≥2 小时 → 0 分
            s.regularityScore = Int(max(0, min(100, (1 - std / 2) * 100)).rounded())
        } else {
            s.regularityScore = 100
        }

        if let last = nights.last {
            s.lastNightScore = sleepScore(night: last)
        }
        return s
    }

    /// 单晚睡眠评分：时长 50% + 深睡占比 25% + 睡眠效率 25%。
    static func sleepScore(night: SleepNight) -> Int {
        let durationPart = min(night.asleepHours / 8.0, 1.0) * 50
        let deepRatio = night.asleepMin > 0 ? night.deepMin / night.asleepMin : 0
        // 深睡理想占比约 20%
        let deepPart = min(deepRatio / 0.20, 1.0) * 25
        let effPart = min(night.efficiency / 0.90, 1.0) * 25
        return Int((durationPart + deepPart + effPart).rounded())
    }

    /// 昨夜相对「平常」对比。平常 = 近7晚中除昨夜外的均值；不足则用全部可用晚。
    static func sleepComparison(night: SleepNight, nights: [SleepNight]) -> SleepComparison {
        var c = SleepComparison()
        let baseline = nights.filter { $0.date != night.date }
        let pool = baseline.isEmpty ? nights : baseline
        guard !pool.isEmpty else { return c }

        let avgBed = pool.map { $0.inBedHour < 12 ? $0.inBedHour + 24 : $0.inBedHour }
            .reduce(0, +) / Double(pool.count)
        let nightBed = night.inBedHour < 12 ? night.inBedHour + 24 : night.inBedHour
        c.bedDeltaMin = Int(((nightBed - avgBed) * 60).rounded())

        let avgDur = pool.map(\.asleepMin).reduce(0, +) / Double(pool.count)
        c.durDeltaMin = Int((night.asleepMin - avgDur).rounded())

        let avgDeep = pool.map(\.deepMin).reduce(0, +) / Double(pool.count)
        c.deepDeltaMin = Int((night.deepMin - avgDeep).rounded())

        c.avgBedLabel = formatHourMinute(avgBed >= 24 ? avgBed - 24 : avgBed)
        c.avgDurLabel = String(format: "%.1fh", avgDur / 60)
        c.avgDeepLabel = fmtMin(avgDeep)
        return c
    }

    /// 昨夜一句话结论（本地规则）。
    static func sleepVerdict(night: SleepNight, nights: [SleepNight], score: Int) -> String {
        let cmp = sleepComparison(night: night, nights: nights)
        var parts: [String] = []

        if abs(cmp.bedDeltaMin) < 3 {
            parts.append("入睡与平常接近")
        } else if cmp.bedDeltaMin < 0 {
            parts.append("比平常**早睡 \(abs(cmp.bedDeltaMin)) 分钟**")
        } else {
            parts.append("比平常晚睡 \(cmp.bedDeltaMin) 分钟")
        }

        if abs(cmp.durDeltaMin) >= 3 {
            let more = cmp.durDeltaMin > 0
            parts.append("时长\(more ? "多" : "少") \(abs(cmp.durDeltaMin)) 分钟")
        }

        let deepRatio = night.asleepMin > 0 ? night.deepMin / night.asleepMin : 0
        let deepPct = Int((deepRatio * 100).rounded())
        if deepRatio > 0 {
            if deepRatio < 0.18 {
                parts.append("深睡占比 \(deepPct)%，略低于理想 20%，今天训练可保持轻松强度")
            } else if deepRatio >= 0.22 {
                parts.append("深睡占比 \(deepPct)%，恢复良好")
            } else {
                parts.append("深睡占比 \(deepPct)%，处于正常范围")
            }
        }

        if score >= 85 {
            parts.append("整体睡眠质量不错")
        } else if score < 70 {
            parts.append("建议今晚尽量早些休息")
        }

        // 把 ** 标记留给 UI 做粗体；这里用纯文案
        return "昨夜" + parts.map { $0.replacingOccurrences(of: "**", with: "") }.joined(separator: "；") + "。"
    }

    private static func formatHourMinute(_ hourDecimal: Double) -> String {
        var h = Int(hourDecimal)
        var m = Int(((hourDecimal - Double(h)) * 60).rounded())
        if m == 60 { h += 1; m = 0 }
        h = ((h % 24) + 24) % 24
        return String(format: "%02d:%02d", h, m)
    }

    /// 睡眠与恢复的关联洞察（结合运动/心率做本地规则计算）。
    static func sleepInsights(nights: [SleepNight],
                              workouts: [WorkoutRecord],
                              heart: HeartMetrics) -> [SleepInsight] {
        var insights: [SleepInsight] = []
        guard nights.count >= 2 else {
            insights.append(SleepInsight(icon: "moon.zzz.fill", tint: .notice,
                                         title: "睡眠数据较少",
                                         detail: "佩戴 Apple Watch 睡觉可自动记录睡眠分期，积累几晚后这里会给出更有价值的分析。"))
            return insights
        }

        let cal = Calendar.current

        // ① 运动日 vs 无运动日的深睡对比
        let workoutDays = Set(workouts.map { cal.startOfDay(for: $0.start) })
        let withEx = nights.filter { workoutDays.contains(cal.startOfDay(for: $0.date)) }
        let noEx = nights.filter { !workoutDays.contains(cal.startOfDay(for: $0.date)) }
        if !withEx.isEmpty && !noEx.isEmpty {
            let d1 = withEx.reduce(0) { $0 + $1.deepMin } / Double(withEx.count)
            let d0 = noEx.reduce(0) { $0 + $1.deepMin } / Double(noEx.count)
            if d1 - d0 >= 5 {
                insights.append(SleepInsight(icon: "figure.run", tint: .good,
                                             title: "运动日睡得更深",
                                             detail: "有运动的夜晚深睡平均 \(fmtMin(d1))，比无运动日多约 \(Int(d1 - d0)) 分钟，运动有助于提升睡眠质量。"))
            }
        }

        // ② 睡眠充足与静息心率
        if let resting = heart.restingHR {
            let avgSleep = nights.reduce(0) { $0 + $1.asleepHours } / Double(nights.count)
            if avgSleep >= 7 {
                insights.append(SleepInsight(icon: "heart.fill", tint: .good,
                                             title: "睡眠充足，心肺状态良好",
                                             detail: "近 \(nights.count) 晚平均睡眠 \(String(format: "%.1f", avgSleep)) 小时，当前静息心率 \(Int(resting)) 次/分，充足睡眠有助于维持较低静息心率。"))
            } else {
                insights.append(SleepInsight(icon: "heart.text.square", tint: .notice,
                                             title: "睡眠偏少可能影响恢复",
                                             detail: "近 \(nights.count) 晚平均睡眠仅 \(String(format: "%.1f", avgSleep)) 小时，睡眠不足可能使静息心率升高、恢复变慢，建议尽量睡满 7 小时。"))
            }
        }

        // ③ HRV 与睡眠
        if let hrv = heart.hrvSDNN {
            insights.append(SleepInsight(icon: "waveform.path.ecg", tint: .good,
                                         title: "睡眠与恢复能力",
                                         detail: "当前 HRV(SDNN) 约 \(Int(hrv)) ms，规律且充足的睡眠通常伴随更高的 HRV，代表更好的身体恢复能力。"))
        }

        return insights
    }

    private static func fmtMin(_ min: Double) -> String {
        let h = Int(min) / 60, m = Int(min) % 60
        return h > 0 ? "\(h) 时 \(m) 分" : "\(m) 分"
    }

    // MARK: - 身体页分析

    /// 活动系数：按近7日锻炼分钟分档。
    static func activityMultiplier(weekExerciseMin: Double) -> (factor: Double, label: String) {
        switch weekExerciseMin {
        case ..<60: return (1.2, "久坐")
        case 60..<150: return (1.375, "轻度活跃")
        case 150..<300: return (1.55, "中度活跃")
        default: return (1.725, "较高活跃")
        }
    }

    /// 估算 TDEE = BMR × 活动系数。
    static func estimatedTDEE(bmr: Double, weekExerciseMin: Double) -> (tdee: Double, factor: Double, label: String) {
        let m = activityMultiplier(weekExerciseMin: weekExerciseMin)
        return (bmr * m.factor, m.factor, m.label)
    }

    /// 身体页一句话结论。
    static func bodyVerdict(body: BodyProfile, recovery: RecoveryBaseline) -> String {
        var tags: [String] = []
        if let cat = body.bmiCategory {
            tags.append("BMI \(cat.text)")
        }
        if let fat = body.bodyFatPercent {
            let ok: Bool
            if body.biologicalSex == "女" {
                ok = (21...33).contains(fat)
            } else {
                ok = (10...20).contains(fat)
            }
            tags.append(ok ? "体脂适中" : "体脂需关注")
        }
        if let r = recovery.restingHR {
            if r <= 60 { tags.append("静息心率优秀") }
            else if r <= 70 { tags.append("静息心率良好") }
            else { tags.append("静息心率偏高") }
        }
        let head = tags.isEmpty ? "身体数据较少" : tags.joined(separator: " · ")
        let advice: String
        if body.bmiCategory?.isHealthy == true, (recovery.restingHR ?? 99) <= 70 {
            advice = "当前适合维持训练强度，继续规律有氧即可"
        } else if body.bmiCategory?.isHealthy == false {
            advice = "建议以有氧为主、循序渐进，并关注饮食节奏"
        } else {
            advice = "建议保持规律运动，注意恢复与睡眠"
        }
        return "\(head) → \(advice)"
    }

    /// 恢复基线解读。
    static func recoveryInsight(recovery: RecoveryBaseline) -> String {
        var parts: [String] = []
        if let d = recovery.restingHRDelta {
            if d <= -2 { parts.append("静息心率较上周下降 \(String(format: "%.0f", abs(d)))") }
            else if d >= 2 { parts.append("静息心率较上周上升 \(String(format: "%.0f", d))") }
        }
        if let hrv = recovery.hrvSDNN {
            if hrv >= 40 { parts.append("HRV 处于较好区间") }
            else { parts.append("HRV 偏低，注意恢复") }
        }
        if parts.isEmpty {
            return "与睡眠页「昨夜」不同，这里看的是近一周体质基线。"
        }
        return parts.joined(separator: "；") + "。与睡眠页「昨夜」不同，这里看近一周体质基线。"
    }

    /// 身体页本地提示（最多 2 条）。
    static func bodyTips(body: BodyProfile,
                         trends: BodyTrends,
                         recovery: RecoveryBaseline,
                         week: PeriodSummary,
                         energyGoal: Double) -> [LocalTip] {
        var tips: [LocalTip] = []
        if let cat = body.bmiCategory, let bmi = body.bmi {
            if cat.isHealthy {
                tips.append(LocalTip(icon: "checkmark.seal.fill", tint: .good,
                                     title: "体成分处于健康区间",
                                     detail: "BMI \(bmi.oneDecimal)（\(cat.text)）。继续保持有氧与力量结合。"))
            } else {
                tips.append(LocalTip(icon: "scalemass.fill", tint: .notice,
                                     title: "BMI \(cat.text)",
                                     detail: "当前 BMI \(bmi.oneDecimal)。建议结合有氧与饮食管理逐步改善。"))
            }
        }
        if let delta = trends.weightDelta(inDays: 30), abs(delta) >= 0.3 {
            if delta < 0 {
                tips.append(LocalTip(icon: "chart.line.downtrend.xyaxis", tint: .good,
                                     title: "近30天体重稳步变化",
                                     detail: "累计 \(String(format: "%+.1f", delta)) kg，节奏健康；避免过快减重影响恢复。"))
            } else {
                tips.append(LocalTip(icon: "chart.line.uptrend.xyaxis", tint: .notice,
                                     title: "近30天体重有所上升",
                                     detail: "累计 \(String(format: "%+.1f", delta)) kg。可结合活动能量目标（\(Int(energyGoal)) kcal）调整节奏。"))
            }
        }
        if let r = recovery.restingHR, r > 75 {
            tips.append(LocalTip(icon: "heart.fill", tint: .warning,
                                 title: "静息心率偏高",
                                 detail: "当前约 \(Int(r)) 次/分，规律有氧与充足睡眠有助于改善。"))
        }
        return Array(tips.prefix(2))
    }

    // MARK: - AI 摘要文本（仅聚合统计，不含可识别个人信息）

    static func healthSummaryText(today: DailyActivity?,
                                  week: PeriodSummary,
                                  month: PeriodSummary,
                                  body: BodyProfile,
                                  heart: HeartMetrics,
                                  workouts: [WorkoutRecord],
                                  sleep: SleepSummary,
                                  energyGoal: Double) -> String {
        var lines: [String] = []
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日"

        lines.append("【身体数据】")
        if let age = body.ageYears { lines.append("- 年龄：\(age) 岁") }
        if let sex = body.biologicalSex { lines.append("- 生理性别：\(sex)") }
        if let h = body.heightCM { lines.append("- 身高：\(h.oneDecimal) cm") }
        if let w = body.weightKG { lines.append("- 体重：\(w.oneDecimal) kg") }
        if let bmi = body.bmi, let cat = body.bmiCategory {
            lines.append("- BMI：\(bmi.oneDecimal)（\(cat.text)，中国标准）")
        }
        if let fat = body.bodyFatPercent { lines.append("- 体脂率：\(fat.oneDecimal)%") }
        if let bmr = body.estimatedBMR { lines.append("- 估算基础代谢：\(Int(bmr)) kcal/天") }

        lines.append("")
        lines.append("【心率指标】")
        if let r = heart.restingHR { lines.append("- 静息心率：\(Int(r)) 次/分") }
        if let a = heart.averageHR7d { lines.append("- 近7天平均心率：\(Int(a)) 次/分") }
        if let h = heart.hrvSDNN { lines.append("- 心率变异性 HRV(SDNN)：\(Int(h)) ms") }

        lines.append("")
        lines.append("【睡眠（近\(sleep.nightCount)晚）】")
        if sleep.nightCount > 0 {
            lines.append("- 平均睡眠时长：\(String(format: "%.1f", sleep.avgAsleepHours)) 小时")
            lines.append("- 平均深睡：\(Int(sleep.avgDeepMin)) 分钟")
            lines.append("- 平均睡眠效率：\(Int(sleep.avgEfficiency * 100))%")
            lines.append("- 睡眠充足夜数（≥7小时）：\(sleep.goodNights)/\(sleep.nightCount)")
            lines.append("- 作息规律性评分：\(sleep.regularityScore)/100")
            lines.append("- 最近一晚睡眠评分：\(sleep.lastNightScore)/100")
        } else {
            lines.append("- 暂无睡眠数据")
        }

        lines.append("")
        lines.append("【今日活动】（能量目标：\(Int(energyGoal)) kcal；步数仅供展示，不设目标）")
        if let today {
            lines.append("- 活动能量：\(Int(today.activeEnergyKcal)) kcal（达成率 \(Int(today.activeEnergyKcal / max(energyGoal, 1) * 100))%）")
            lines.append("- 步数：\(Int(today.steps)) 步")
            lines.append("- 锻炼时长：\(Int(today.exerciseMinutes)) 分钟")
            lines.append("- 步行+跑步距离：\(today.distanceKM.oneDecimal) km")
            lines.append("- 爬楼层数：\(Int(today.flightsClimbed)) 层")
        } else {
            lines.append("- 今日暂无数据")
        }

        lines.append("")
        lines.append("【近7天统计】")
        lines.append("- 总活动能量：\(Int(week.totalEnergyKcal)) kcal，日均 \(Int(week.avgEnergyKcal)) kcal")
        lines.append("- 活动能量达标天数：\(week.energyGoalHitDays)/7 天")
        lines.append("- 总步数：\(Int(week.totalSteps)) 步，日均 \(Int(week.avgSteps)) 步")
        lines.append("- 总锻炼时长：\(Int(week.totalExerciseMin)) 分钟")
        lines.append("- 总距离：\(week.totalDistanceKM.oneDecimal) km")
        if let trend = week.energyTrendPercent {
            lines.append("- 活动能量周环比：\(trend >= 0 ? "+" : "")\(Int(trend))%")
        }
        lines.append("- 综合活动评分：\(week.activityScore)/100")

        lines.append("")
        lines.append("【近30天统计】")
        lines.append("- 日均活动能量：\(Int(month.avgEnergyKcal)) kcal，能量达标 \(month.energyGoalHitDays)/30 天")
        lines.append("- 日均步数：\(Int(month.avgSteps)) 步")
        lines.append("- 总锻炼时长：\(Int(month.totalExerciseMin)) 分钟")

        let recentWorkouts = workouts.filter { $0.start > Date().addingTimeInterval(-7 * 24 * 3600) }
        lines.append("")
        lines.append("【近7天运动记录】（共 \(recentWorkouts.count) 次）")
        if recentWorkouts.isEmpty {
            lines.append("- 无")
        } else {
            for w in recentWorkouts.prefix(10) {
                var line = "- \(df.string(from: w.start)) \(w.activityType.displayName)，\(Int(w.durationMinutes)) 分钟，\(Int(w.caloriesKcal)) kcal"
                if let d = w.distanceKM { line += "，\(d.oneDecimal) km" }
                lines.append(line)
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 自然周（上周）摘要 + 快照

    /// 组装「上一自然周」的 LLM 输入文本，并生成图文快照。
    /// `days` 需覆盖上周与上上周（例如近 30 天日活动）。
    static func weeklyReviewPayload(
        weekStart: Date,
        weekEnd: Date,
        weekID: String,
        days: [DailyActivity],
        workouts: [WorkoutRecord],
        sleepNights: [SleepNight],
        body: BodyProfile,
        heart: HeartMetrics,
        recovery: RecoveryBaseline,
        energyGoal: Double
    ) -> (text: String, snapshot: WeeklyAdviceSnapshot) {
        let weekActs = CalendarWeekHelper.activities(days, in: weekStart, end: weekEnd)
        let prevStart = CalendarWeekHelper.calendar.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
        let prevActs = CalendarWeekHelper.activities(days, in: prevStart, end: weekStart)
        let weekSum = summarize(current: weekActs, previous: prevActs, energyGoal: energyGoal)
        let weekWorkouts = CalendarWeekHelper.workouts(workouts, in: weekStart, end: weekEnd)
        let weekSleep = CalendarWeekHelper.sleepNights(sleepNights, in: weekStart, end: weekEnd)
        let sleepSum = summarizeSleep(nights: weekSleep)

        var typeMap: [String: Int] = [:]
        for w in weekWorkouts {
            typeMap[w.activityType.displayName, default: 0] += 1
        }
        let topTypes = typeMap
            .map { WorkoutTypeCount(name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(5)
            .map { $0 }

        let snapshot = WeeklyAdviceSnapshot(
            workoutCount: weekWorkouts.count,
            totalExerciseMin: weekSum.totalExerciseMin,
            totalDistanceKM: weekSum.totalDistanceKM,
            totalEnergyKcal: weekSum.totalEnergyKcal,
            activityScore: weekSum.activityScore,
            energyGoalHitDays: weekSum.energyGoalHitDays,
            avgSleepHours: sleepSum.nightCount > 0 ? sleepSum.avgAsleepHours : nil,
            avgDeepMin: sleepSum.nightCount > 0 ? sleepSum.avgDeepMin : nil,
            goodSleepNights: sleepSum.nightCount > 0 ? sleepSum.goodNights : nil,
            sleepNightCount: sleepSum.nightCount > 0 ? sleepSum.nightCount : nil,
            weightKG: body.weightKG,
            bmi: body.bmi,
            restingHR: recovery.restingHR ?? heart.restingHR,
            topWorkoutTypes: Array(topTypes)
        )

        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日"
        let endDay = Calendar.current.date(byAdding: .day, value: -1, to: weekEnd) ?? weekEnd

        var lines: [String] = []
        lines.append("【周次】\(weekID)（\(df.string(from: weekStart)) – \(df.string(from: endDay))）")
        lines.append("【说明】以下为上一自然周（周一至周日）聚合数据，请据此做上周总结与本周建议。")

        lines.append("")
        lines.append("【身体数据】")
        if let age = body.ageYears { lines.append("- 年龄：\(age) 岁") }
        if let sex = body.biologicalSex { lines.append("- 生理性别：\(sex)") }
        if let h = body.heightCM { lines.append("- 身高：\(h.oneDecimal) cm") }
        if let w = body.weightKG { lines.append("- 体重：\(w.oneDecimal) kg") }
        if let bmi = body.bmi, let cat = body.bmiCategory {
            lines.append("- BMI：\(bmi.oneDecimal)（\(cat.text)）")
        }
        if let fat = body.bodyFatPercent { lines.append("- 体脂率：\(fat.oneDecimal)%") }
        if let vo2 = body.vo2Max { lines.append("- VO₂ Max：\(vo2.oneDecimal) mL/kg·min") }

        lines.append("")
        lines.append("【恢复基线】")
        if let r = recovery.restingHR ?? heart.restingHR {
            lines.append("- 静息心率：\(Int(r)) 次/分")
        }
        if let d = recovery.restingHRDelta {
            lines.append("- 静息心率近7日较前7日：\(d >= 0 ? "+" : "")\(String(format: "%.0f", d))")
        }
        if let hrv = recovery.hrvSDNN ?? heart.hrvSDNN {
            lines.append("- HRV(SDNN)：\(Int(hrv)) ms")
        }

        lines.append("")
        lines.append("【上周活动】（能量目标：\(Int(energyGoal)) kcal/天）")
        lines.append("- 有数据天数：\(weekActs.count)/7")
        lines.append("- 总活动能量：\(Int(weekSum.totalEnergyKcal)) kcal，日均 \(Int(weekSum.avgEnergyKcal)) kcal")
        lines.append("- 能量达标：\(weekSum.energyGoalHitDays)/7 天")
        lines.append("- 总步数：\(Int(weekSum.totalSteps))，日均 \(Int(weekSum.avgSteps))")
        lines.append("- 锻炼时长：\(Int(weekSum.totalExerciseMin)) 分钟")
        lines.append("- 总距离：\(weekSum.totalDistanceKM.oneDecimal) km")
        if let trend = weekSum.energyTrendPercent {
            lines.append("- 活动能量周环比：\(trend >= 0 ? "+" : "")\(Int(trend))%")
        }
        lines.append("- 综合活动评分：\(weekSum.activityScore)/100")

        lines.append("")
        lines.append("【上周运动记录】（共 \(weekWorkouts.count) 次）")
        if weekWorkouts.isEmpty {
            lines.append("- 无正式训练记录")
        } else {
            if !topTypes.isEmpty {
                let typeLine = topTypes.map { "\($0.name)×\($0.count)" }.joined(separator: "、")
                lines.append("- 类型分布：\(typeLine)")
            }
            for w in weekWorkouts.prefix(12) {
                var line = "- \(df.string(from: w.start)) \(w.activityType.displayName)，\(Int(w.durationMinutes)) 分钟，\(Int(w.caloriesKcal)) kcal"
                if let d = w.distanceKM { line += "，\(d.oneDecimal) km" }
                if let elev = w.elevationGain, elev > 0 { line += "，爬升 \(Int(elev)) m" }
                lines.append(line)
            }
        }

        lines.append("")
        lines.append("【上周睡眠】（归属该周的 \(sleepSum.nightCount) 晚）")
        if sleepSum.nightCount > 0 {
            lines.append("- 平均睡眠：\(String(format: "%.1f", sleepSum.avgAsleepHours)) 小时")
            lines.append("- 平均深睡：\(Int(sleepSum.avgDeepMin)) 分钟")
            lines.append("- 平均效率：\(Int(sleepSum.avgEfficiency * 100))%")
            lines.append("- 充足夜数（≥7小时）：\(sleepSum.goodNights)/\(sleepSum.nightCount)")
            lines.append("- 规律性：\(sleepSum.regularityScore)/100")
        } else {
            lines.append("- 暂无该周睡眠数据")
        }

        return (lines.joined(separator: "\n"), snapshot)
    }
}
