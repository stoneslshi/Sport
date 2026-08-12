import Foundation
import SwiftUI

/// 全局数据中枢：负责拉取 HealthKit 数据、计算统计结果、调用大模型。
@Observable
@MainActor
final class HealthViewModel {

    // MARK: 状态

    var isLoading = false
    var hasRequestedAuth = false
    var errorMessage: String?

    var today: DailyActivity?
    var last7Days: [DailyActivity] = []
    var last30Days: [DailyActivity] = []
    var previous7Days: [DailyActivity] = []
    var previous30Days: [DailyActivity] = []
    var workouts: [WorkoutRecord] = []
    var bodyProfile = BodyProfile()
    var heartMetrics = HeartMetrics()
    var bodyTrends = BodyTrends()
    var recoveryBaseline = RecoveryBaseline()
    var sleepNights: [SleepNight] = []

    var aiAdvice: String = ""
    var isAILoading = false
    var aiError: String?

    /// 上一自然周 AI 总结（当前展示）
    var weeklyAdvice: WeeklyAdviceRecord?
    /// 历史周报列表（新→旧）
    var weeklyAdviceHistory: [WeeklyAdviceRecord] = []
    var isWeeklyAdviceLoading = false
    var weeklyAdviceError: String?

    /// 底部 Tab 选中项（概览 CTA / 提示可跳转）
    var selectedTab: AppTab = .home

    /// 已自动触发过周报生成的 weekID（防止同周一重复请求）
    private var autoWeeklyKey: String {
        get { UserDefaults.standard.string(forKey: "autoWeeklyAdviceWeekID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "autoWeeklyAdviceWeekID") }
    }

    // MARK: 设置（UserDefaults 持久化）
    // 步数仅作展示指标，不设目标；目标管理只保留活动能量。

    var energyGoal: Double {
        get { UserDefaults.standard.double(forKey: "energyGoal") == 0 ? 400 : UserDefaults.standard.double(forKey: "energyGoal") }
        set { UserDefaults.standard.set(newValue, forKey: "energyGoal") }
    }

    // MARK: 大模型配置（选择服务商 + 模型，仅需填 Key；自定义时才手填 URL/模型）

    /// 当前所选服务商 ID（默认 openai）
    var apiProviderID: String {
        get { UserDefaults.standard.string(forKey: "apiProviderID") ?? "openai" }
        set { UserDefaults.standard.set(newValue, forKey: "apiProviderID") }
    }

    /// 当前所选模型名
    var apiModel: String {
        get { UserDefaults.standard.string(forKey: "apiModel") ?? LLMProvider.provider(id: apiProviderID).models.first ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "apiModel") }
    }

    /// 自定义服务商时用户手填的 Base URL（预置服务商忽略此值）
    var customBaseURL: String {
        get { UserDefaults.standard.string(forKey: "customBaseURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "customBaseURL") }
    }

    /// 自定义服务商时用户手填的模型名
    var customModel: String {
        get { UserDefaults.standard.string(forKey: "customModel") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "customModel") }
    }

    /// 实际生效的 Base URL（预置取内置值，自定义取用户输入）
    var effectiveBaseURL: String {
        let provider = LLMProvider.provider(id: apiProviderID)
        return provider.isCustom ? customBaseURL : provider.baseURL
    }

    /// 实际生效的模型名
    var effectiveModel: String {
        let provider = LLMProvider.provider(id: apiProviderID)
        return provider.isCustom ? customModel : apiModel
    }

    var hasAPIKey: Bool {
        guard let key = KeychainHelper.read(key: "llm_api_key") else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: 计算属性

    var weekSummary: PeriodSummary {
        AnalysisEngine.summarize(current: last7Days, previous: previous7Days, energyGoal: energyGoal)
    }

    var monthSummary: PeriodSummary {
        AnalysisEngine.summarize(current: last30Days, previous: previous30Days, energyGoal: energyGoal)
    }

    var todayScore: Int {
        guard let today else { return 0 }
        return AnalysisEngine.todayScore(today: today, energyGoal: energyGoal)
    }

    var localTips: [LocalTip] {
        AnalysisEngine.localTips(
            today: today,
            week: weekSummary,
            body: bodyProfile,
            heart: heartMetrics,
            workouts: workouts,
            energyGoal: energyGoal
        )
    }

    /// 概览决策页优先提示（最多 2 条）
    var priorityTips: [LocalTip] {
        AnalysisEngine.priorityTips(
            today: today,
            week: weekSummary,
            lastNight: lastNight,
            nights: sleepNights,
            energyGoal: energyGoal,
            sleepScore: sleepSummary.lastNightScore
        )
    }

    /// 今日能量缺口（kcal）；已达标为 0
    var energyGapKcal: Int {
        guard let today else { return Int(energyGoal) }
        return max(Int((energyGoal - today.activeEnergyKcal).rounded()), 0)
    }

    var energyProgress: Double {
        guard let today else { return 0 }
        return today.activeEnergyKcal / max(energyGoal, 1)
    }

    var exerciseProgress: Double {
        guard let today else { return 0 }
        return today.exerciseMinutes / 30
    }

    /// Hero 一句话结论
    var dashboardVerdict: String {
        AnalysisEngine.dashboardVerdict(
            today: today,
            energyGoal: energyGoal,
            lastNight: lastNight,
            sleepScore: sleepSummary.lastNightScore,
            nights: sleepNights
        )
    }

    /// 近 7 日洞察一句话
    var weekInsight: String {
        AnalysisEngine.weekInsight(week: weekSummary)
    }

    /// 昨夜睡眠对今日强度的影响文案
    var sleepImpactText: String? {
        guard let lastNight else { return nil }
        return AnalysisEngine.sleepImpactOnToday(
            night: lastNight,
            nights: sleepNights,
            score: sleepSummary.lastNightScore
        )
    }

    // MARK: 身体页计算属性

    var bodyVerdict: String {
        AnalysisEngine.bodyVerdict(body: bodyProfile, recovery: recoveryBaseline)
    }

    var recoveryInsight: String {
        AnalysisEngine.recoveryInsight(recovery: recoveryBaseline)
    }

    var bodyTips: [LocalTip] {
        AnalysisEngine.bodyTips(
            body: bodyProfile,
            trends: bodyTrends,
            recovery: recoveryBaseline,
            week: weekSummary,
            energyGoal: energyGoal
        )
    }

    /// 估算 TDEE（依赖 BMR + 近7日锻炼）
    var estimatedTDEE: (tdee: Double, factor: Double, label: String)? {
        guard let bmr = bodyProfile.estimatedBMR else { return nil }
        return AnalysisEngine.estimatedTDEE(bmr: bmr, weekExerciseMin: weekSummary.totalExerciseMin)
    }

    // MARK: 睡眠计算属性

    /// 最近一晚睡眠
    var lastNight: SleepNight? { sleepNights.last }

    /// 睡眠页展示用近 7 晚（底层仍保留最多 14 晚供上周周报切片）
    var displaySleepNights: [SleepNight] { Array(sleepNights.suffix(7)) }
    private var recentSleepNights: [SleepNight] { displaySleepNights }

    /// 睡眠汇总（近 7 晚）
    var sleepSummary: SleepSummary {
        AnalysisEngine.summarizeSleep(nights: recentSleepNights)
    }

    /// 睡眠与恢复关联洞察
    var sleepInsights: [SleepInsight] {
        AnalysisEngine.sleepInsights(nights: recentSleepNights, workouts: workouts, heart: heartMetrics)
    }

    /// 昨夜 vs 平常
    var sleepComparison: SleepComparison? {
        guard let n = lastNight else { return nil }
        return AnalysisEngine.sleepComparison(night: n, nights: recentSleepNights)
    }

    /// 昨夜一句话结论
    var sleepVerdict: String? {
        guard let n = lastNight else { return nil }
        return AnalysisEngine.sleepVerdict(night: n, nights: sleepNights, score: sleepSummary.lastNightScore)
    }

    // MARK: 运动记录按时间范围筛选（步数展示 / 能量目标不涉及此处）

    enum WorkoutRange: String, CaseIterable, Identifiable {
        case week = "近7天"
        case month = "近1个月"
        case year = "近1年"
        case custom = "自定义"
        var id: String { rawValue }
    }

    /// 按预置范围返回起始日期（自定义返回 nil，由调用方提供区间）。
    func startDate(for range: WorkoutRange, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: Date())
        switch range {
        case .week:  return calendar.date(byAdding: .day, value: -6, to: today)
        case .month: return calendar.date(byAdding: .month, value: -1, to: today)
        case .year:  return calendar.date(byAdding: .year, value: -1, to: today)
        case .custom: return nil
        }
    }

    /// 从已缓存的 workouts 中筛选某区间的记录（含起止当天）。
    func workouts(from start: Date, to end: Date) -> [WorkoutRecord] {
        let s = min(start, end)
        let e = Calendar.current.date(byAdding: .day, value: 1,
                                      to: Calendar.current.startOfDay(for: max(start, end))) ?? max(start, end)
        return workouts.filter { $0.start >= s && $0.start < e }
    }

    /// 今日运动记录（供首页展示）。
    var todayWorkouts: [WorkoutRecord] {
        let cal = Calendar.current
        return workouts.filter { cal.isDateInToday($0.start) }
            .sorted { $0.start > $1.start }
    }

    /// 按运动类型对给定记录聚合统计（供运动页分类统计），按次数降序。
    func typeStats(for records: [WorkoutRecord]) -> [WorkoutTypeStat] {
        var map: [UInt: WorkoutTypeStat] = [:]
        for r in records {
            var stat = map[r.activityType.rawValue] ?? WorkoutTypeStat(activityType: r.activityType)
            stat.count += 1
            stat.totalMinutes += r.durationMinutes
            stat.totalKcal += r.caloriesKcal
            stat.totalKM += r.distanceKM ?? 0
            map[r.activityType.rawValue] = stat
        }
        return map.values.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.totalKcal > $1.totalKcal
        }
    }

    /// 加载某次运动的详情（心率曲线 + GPS 轨迹 + 真实分段配速）。返回补全后的记录副本。
    func loadWorkoutDetail(_ record: WorkoutRecord) async -> WorkoutRecord {
        var detailed = record
        let manager = HealthKitManager.shared
        async let hr = try? manager.fetchHeartRateSeries(for: record)
        async let route = try? manager.fetchRouteDetail(for: record)
        async let swim = try? manager.fetchSwimDetail(for: record)
        async let splits = try? manager.fetchSplits(for: record)
        let (hrSeries, routeDetail, swimDetail, realSplits) = await (hr, route, swim, splits)
        detailed.heartRateSeries = hrSeries ?? []
        detailed.routeCoordinates = routeDetail?.coordinates ?? []
        detailed.elevationSeries = routeDetail?.elevationSeries ?? []

        if let context = try? await manager.fetchWorkoutContext(for: record) {
            detailed.weatherTemperatureC = context.weatherTemperatureC
            detailed.weatherHumidityPercent = context.weatherHumidityPercent
        }
        if let swimDetail {
            detailed.laps = swimDetail.lapsCount
            detailed.strokeDistribution = swimDetail.strokes
            detailed.swimLaps = swimDetail.lapDetails
            detailed.swimSets = swimDetail.sets
            detailed.totalStrokeCount = swimDetail.totalStrokeCount
            detailed.avgSWOLF = swimDetail.avgSWOLF
            detailed.bestPacePer100m = swimDetail.bestPacePer100m
            detailed.sessionDistanceBests = swimDetail.sessionBests
        }
        detailed.splits = realSplits ?? []
        if !detailed.heartRateSeries.isEmpty {
            detailed.hrZones = HealthKitManager.heartRateZones(
                from: detailed.heartRateSeries,
                maxHRHint: detailed.maxHR ?? record.maxHR,
                ageYears: bodyProfile.ageYears)
        }
        return detailed
    }

    /// 历史游泳均配速（分钟/100m），排除当前这条，用于对比。
    func averageSwimPacePer100m(excluding id: UUID) -> Double? {
        let swims = workouts.filter { $0.isSwimming && $0.id != id && ($0.distanceKM ?? 0) > 0 }
        let paces = swims.compactMap(\.avgPacePer100m)
        guard !paces.isEmpty else { return nil }
        return paces.reduce(0, +) / Double(paces.count)
    }

    // MARK: 数据加载

    func loadAll() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let manager = HealthKitManager.shared
        guard manager.isHealthDataAvailable else {
            errorMessage = "此设备不支持 Apple 健康。"
            return
        }

        do {
            try await manager.requestAuthorization()
            hasRequestedAuth = true

            async let activities30 = manager.fetchDailyActivities(days: 30)
            async let activities14 = manager.fetchDailyActivities(days: 14)
            async let activities60 = manager.fetchDailyActivities(days: 60)
            async let heart = manager.fetchHeartMetrics()
            async let body = manager.fetchBodyProfile()
            async let trends = manager.fetchBodyTrends(days: 90)
            async let recovery = manager.fetchRecoveryBaseline()
            // 14 晚以覆盖「上一自然周」睡眠切片；睡眠页仍用近 7 晚展示
            async let sleep = manager.fetchSleepNights(nights: 14)
            // 加载近一年运动记录，供运动页「近7天/近1个月/近1年/自定义」范围筛选
            let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date())
            async let workoutList = manager.fetchWorkouts(from: yearAgo, to: Date())

            let (d30, d14, d60, h, b, tr, rec, s, w) = try await (
                activities30, activities14, activities60, heart, body, trends, recovery, sleep, workoutList
            )

            last30Days = d30
            last7Days = Array(d30.suffix(7))
            previous7Days = Array(d14.prefix(7))
            previous30Days = Array(d60.prefix(30))
            today = d30.last
            heartMetrics = h
            bodyProfile = b
            bodyTrends = tr
            recoveryBaseline = rec
            sleepNights = s
            workouts = w
            refreshWeeklyAdviceFromStore()
        } catch {
            errorMessage = "读取健康数据失败：\(error.localizedDescription)"
        }
    }

    func refresh() async {
        await loadAll()
    }

    // MARK: 分享文案

    /// 运动汇总本地兜底文案。
    func workoutSummaryCaption(records: [WorkoutRecord], rangeLabel: String) -> String {
        ShareCardRenderer.localSummaryCaption(records: records, rangeLabel: rangeLabel)
    }

    /// 区间汇总分享文案：优先 AI，失败/未配置则回退本地。
    func shareSummaryCaption(records: [WorkoutRecord],
                             typeStats: [WorkoutTypeStat],
                             rangeLabel: String,
                             periodText: String) async -> String {
        let local = ShareCardRenderer.localSummaryCaption(records: records, rangeLabel: rangeLabel)
        let key = KeychainHelper.read(key: "llm_api_key") ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return local }

        let totalMin = Int(records.reduce(0) { $0 + $1.durationMinutes })
        let totalKcal = Int(records.reduce(0) { $0 + $1.caloriesKcal })
        var parts: [String] = [
            "这是一段「\(rangeLabel)」运动汇总（\(periodText)）",
            "总次数：\(records.count) 次",
            "总时长：\(totalMin) 分钟",
            "总消耗：\(totalKcal) 千卡"
        ]
        let top = typeStats.sorted { $0.count > $1.count }.prefix(3)
        for s in top {
            var line = "\(s.activityType.displayName)：\(s.count) 次"
            if s.totalKM > 0 {
                if s.activityType == .swimming {
                    line += "，\(Int((s.totalKM * 1000).rounded())) 米"
                } else {
                    line += "，\(s.totalKM.oneDecimal) 公里"
                }
            } else {
                line += "，\(Int(s.totalKcal)) 千卡"
            }
            parts.append(line)
        }

        let config = AIService.Config(
            baseURL: effectiveBaseURL,
            apiKey: key,
            model: effectiveModel
        )
        do {
            return try await AIService.generateShareCaption(
                dataSummary: parts.joined(separator: "；"), config: config)
        } catch {
            return local
        }
    }

    /// 为单次运动生成一句有趣的分享文案：优先用 AI，失败/未配置则回退本地文案。
    func shareCaption(for record: WorkoutRecord) async -> String {
        let key = KeychainHelper.read(key: "llm_api_key") ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ShareCardRenderer.localCaption(for: record)
        }
        var parts: [String] = ["运动类型：\(record.activityType.displayName)",
                               "时长：\(Int(record.durationMinutes)) 分钟",
                               "消耗：\(Int(record.caloriesKcal)) 千卡"]
        if let km = record.distanceKM, km > 0 {
            parts.append(record.isSwimming ? "距离：\(Int(km * 1000)) 米" : "距离：\(km.oneDecimal) 公里")
        }
        if record.isSwimming, let p = record.avgPacePer100m {
            parts.append("配速：\(ShareCardRenderer.pace(p)) /100米")
        } else if let p = record.avgPaceMinPerKM {
            parts.append("配速：\(ShareCardRenderer.pace(p)) /公里")
        }
        if let hr = record.avgHR { parts.append("平均心率：\(Int(hr)) bpm") }

        let config = AIService.Config(
            baseURL: effectiveBaseURL,
            apiKey: key,
            model: effectiveModel
        )
        do {
            return try await AIService.generateShareCaption(
                dataSummary: parts.joined(separator: "；"), config: config)
        } catch {
            return ShareCardRenderer.localCaption(for: record)
        }
    }

    // MARK: AI 建议

    func requestAIAdvice() async {
        guard !isAILoading else { return }
        isAILoading = true
        aiError = nil
        defer { isAILoading = false }

        let summary = AnalysisEngine.healthSummaryText(
            today: today,
            week: weekSummary,
            month: monthSummary,
            body: bodyProfile,
            heart: heartMetrics,
            workouts: workouts,
            sleep: sleepSummary,
            energyGoal: energyGoal
        )

        let config = AIService.Config(
            baseURL: effectiveBaseURL,
            apiKey: KeychainHelper.read(key: "llm_api_key") ?? "",
            model: effectiveModel
        )

        do {
            aiAdvice = try await AIService.generateAdvice(healthSummary: summary, config: config)
        } catch {
            aiError = error.localizedDescription
        }
    }

    // MARK: 上周 AI 周报

    func refreshWeeklyAdviceFromStore() {
        weeklyAdviceHistory = AdviceHistoryStore.shared.allRecords()
        if let last = CalendarWeekHelper.lastCompletedWeek(),
           let match = AdviceHistoryStore.shared.record(weekID: last.weekID) {
            weeklyAdvice = match
        } else {
            weeklyAdvice = weeklyAdviceHistory.first
        }
    }

    /// 建议页出现时：加载历史；周一且尚未成功生成过则自动请求。
    func prepareWeeklyAdviceOnAppear() async {
        refreshWeeklyAdviceFromStore()
        guard let last = CalendarWeekHelper.lastCompletedWeek() else { return }
        if AdviceHistoryStore.shared.has(weekID: last.weekID) {
            weeklyAdvice = AdviceHistoryStore.shared.record(weekID: last.weekID)
            return
        }
        guard CalendarWeekHelper.isMonday() else { return }
        // 同一周一若已尝试过（成功会写入 store；失败用 key 避免刷屏），不再自动重试
        guard autoWeeklyKey != last.weekID else { return }
        guard hasAPIKey else { return }
        autoWeeklyKey = last.weekID
        await requestWeeklyReview(force: false)
    }

    /// 生成上一自然周总结；`force` 为 true 时覆盖已有记录。
    func requestWeeklyReview(force: Bool = true) async {
        guard !isWeeklyAdviceLoading else { return }
        guard let week = CalendarWeekHelper.lastCompletedWeek() else {
            weeklyAdviceError = "无法确定上一自然周。"
            return
        }
        if !force, AdviceHistoryStore.shared.has(weekID: week.weekID) {
            weeklyAdvice = AdviceHistoryStore.shared.record(weekID: week.weekID)
            refreshWeeklyAdviceFromStore()
            return
        }

        isWeeklyAdviceLoading = true
        weeklyAdviceError = nil
        defer { isWeeklyAdviceLoading = false }

        // 确保有足够数据覆盖上周
        if last30Days.isEmpty || sleepNights.isEmpty {
            await loadAll()
        }

        let payload = AnalysisEngine.weeklyReviewPayload(
            weekStart: week.start,
            weekEnd: week.end,
            weekID: week.weekID,
            days: last30Days.isEmpty ? last7Days : last30Days,
            workouts: workouts,
            sleepNights: sleepNights,
            body: bodyProfile,
            heart: heartMetrics,
            recovery: recoveryBaseline,
            energyGoal: energyGoal
        )

        let config = AIService.Config(
            baseURL: effectiveBaseURL,
            apiKey: KeychainHelper.read(key: "llm_api_key") ?? "",
            model: effectiveModel
        )

        do {
            let brief = try await AIService.generateWeeklyReview(
                weekSummary: payload.text, config: config)
            let contentJSON = (try? JSONEncoder().encode(brief))
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? brief.headline
            let record = WeeklyAdviceRecord(
                weekID: week.weekID,
                weekStart: week.start,
                weekEnd: week.end,
                content: contentJSON,
                createdAt: Date(),
                snapshot: payload.snapshot,
                brief: brief
            )
            AdviceHistoryStore.shared.save(record)
            autoWeeklyKey = week.weekID
            weeklyAdvice = record
            refreshWeeklyAdviceFromStore()
        } catch {
            weeklyAdviceError = error.localizedDescription
        }
    }

    /// 周报分享文案：优先短标题+行动，失败用本地拼接。
    func weeklyAdviceShareCaption(for record: WeeklyAdviceRecord) async -> String {
        let local = record.displayBrief.shareCaption + " " + AppBrand.shareHashtag
        let key = KeychainHelper.read(key: "llm_api_key") ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return local }

        let snap = record.snapshot
        var parts = [
            "上周\(record.dateRangeText)",
            "训练\(snap.workoutCount)次",
            "评分\(snap.activityScore)",
            record.displayBrief.headline
        ]
        if let sleep = snap.avgSleepHours {
            parts.append(String(format: "均睡%.1fh", sleep))
        }
        let config = AIService.Config(
            baseURL: effectiveBaseURL, apiKey: key, model: effectiveModel)
        do {
            let line = try await AIService.generateShareCaption(
                dataSummary: parts.joined(separator: "；"), config: config)
            return line + " " + AppBrand.shareHashtag
        } catch {
            return local
        }
    }
}
