import Foundation

/// 某一自然周的 AI 总结与建议（可持久化）
struct WeeklyAdviceRecord: Codable, Identifiable, Hashable {
    /// ISO 风格周标识，如 `2026-W31`
    let weekID: String
    let weekStart: Date
    let weekEnd: Date
    /// 兼容旧版：纯 Markdown；新版可存 JSON 原文
    let content: String
    let createdAt: Date
    /// 用于图文展示的指标快照
    var snapshot: WeeklyAdviceSnapshot
    /// 结构化短周报（新版）；旧数据为 nil 时从 content 解析或降级
    var brief: WeeklyAdviceBrief?

    var id: String { weekID }

    var dateRangeText: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日"
        let endDay = Calendar.current.date(byAdding: .day, value: -1, to: weekEnd) ?? weekEnd
        return "\(df.string(from: weekStart)) – \(df.string(from: endDay))"
    }

    var title: String { "上周回顾 · \(dateRangeText)" }

    /// 展示用结构化内容
    var displayBrief: WeeklyAdviceBrief {
        if let brief { return brief }
        if let parsed = WeeklyAdviceBrief.parse(from: content) { return parsed }
        return .legacyFallback(markdown: content, snapshot: snapshot)
    }
}

/// AI 输出的短图文周报（指标优先，少长文）
struct WeeklyAdviceBrief: Codable, Hashable {
    /// 一句话点评，≤20 字
    var headline: String
    /// 状态标签，2–4 字，如「稳健」「充能」「需恢复」
    var vibe: String
    /// 2–3 条亮点
    var highlights: [WeeklyAdviceHighlight]
    /// 对关键指标的短注释（key 见 WeeklyMetricKey）
    var metricNotes: [WeeklyMetricNote]
    /// 3 条本周行动，每条 ≤22 字
    var actions: [String]

    var shareCaption: String {
        let act = actions.prefix(2).joined(separator: "；")
        if act.isEmpty { return headline }
        return "\(headline)｜\(act)"
    }

    static func parse(from raw: String) -> WeeklyAdviceBrief? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = extractJSONData(from: trimmed) else { return nil }
        return try? JSONDecoder().decode(WeeklyAdviceBrief.self, from: data)
    }

    /// 从可能被 ```json 包裹的文本中取出 JSON
    private static func extractJSONData(from text: String) -> Data? {
        if let data = text.data(using: .utf8),
           (try? JSONDecoder().decode(WeeklyAdviceBrief.self, from: data)) != nil {
            return data
        }
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"),
           start < end {
            let slice = String(text[start...end])
            return slice.data(using: .utf8)
        }
        return nil
    }

    /// 旧 Markdown 周报降级为短结构，避免详情页刷屏
    static func legacyFallback(markdown: String, snapshot: WeeklyAdviceSnapshot) -> WeeklyAdviceBrief {
        let plain = markdown
            .replacingOccurrences(of: #"#+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\*+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = plain.split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? "上周训练已记录"
        let headline = String(firstLine.prefix(20))

        var highlights: [WeeklyAdviceHighlight] = []
        if snapshot.workoutCount > 0 {
            highlights.append(.init(symbol: "run", title: "训练 \(snapshot.workoutCount) 次",
                                    detail: "共 \(Int(snapshot.totalExerciseMin)) 分钟"))
        }
        if let sleep = snapshot.avgSleepHours {
            highlights.append(.init(symbol: "sleep", title: String(format: "均睡 %.1fh", sleep),
                                    detail: snapshot.goodSleepNights.map { "充足 \($0) 晚" } ?? "睡眠已记录"))
        }
        highlights.append(.init(symbol: "trophy", title: "评分 \(snapshot.activityScore)",
                                detail: "活动能量 \(Int(snapshot.totalEnergyKcal)) kcal"))

        return WeeklyAdviceBrief(
            headline: headline,
            vibe: snapshot.activityScore >= 75 ? "稳健" : (snapshot.activityScore >= 50 ? "推进中" : "需加油"),
            highlights: Array(highlights.prefix(3)),
            metricNotes: [],
            actions: ["保持有氧节奏", "补一次力量或核心", "固定起床时间"]
        )
    }
}

struct WeeklyAdviceHighlight: Codable, Hashable, Identifiable {
    /// 约定符号：run / sleep / heart / flame / trophy / bolt / body
    var symbol: String
    var title: String
    var detail: String

    var id: String { symbol + title + detail }

    var systemImage: String {
        switch symbol.lowercased() {
        case "run", "workout": return "figure.run"
        case "sleep": return "bed.double.fill"
        case "heart", "resting": return "heart.fill"
        case "flame", "energy": return "flame.fill"
        case "trophy", "score": return "trophy.fill"
        case "bolt": return "bolt.fill"
        case "body", "bmi": return "figure.stand"
        default: return "sparkles"
        }
    }

    var tint: String {
        switch symbol.lowercased() {
        case "run", "workout": return "orange"
        case "sleep": return "indigo"
        case "heart", "resting": return "red"
        case "flame", "energy": return "red"
        case "trophy", "score": return "yellow"
        case "bolt": return "cyan"
        case "body", "bmi": return "green"
        default: return "orange"
        }
    }
}

struct WeeklyMetricNote: Codable, Hashable, Identifiable {
    /// score / workouts / exercise / energy / sleep / resting / bmi
    var key: String
    /// ≤16 字点评
    var note: String
    var id: String { key }
}

extension Array where Element == WeeklyMetricNote {
    func note(for key: String) -> String? {
        first(where: { $0.key == key })?.note
    }
}

/// 周报卡片上的可视化指标快照
struct WeeklyAdviceSnapshot: Codable, Hashable {
    var workoutCount: Int = 0
    var totalExerciseMin: Double = 0
    var totalDistanceKM: Double = 0
    var totalEnergyKcal: Double = 0
    var activityScore: Int = 0
    var energyGoalHitDays: Int = 0
    var avgSleepHours: Double?
    var avgDeepMin: Double?
    var goodSleepNights: Int?
    var sleepNightCount: Int?
    var weightKG: Double?
    var bmi: Double?
    var restingHR: Double?
    /// 运动类型 → 次数（最多若干项）
    var topWorkoutTypes: [WorkoutTypeCount] = []
}

struct WorkoutTypeCount: Codable, Hashable, Identifiable {
    var name: String
    var count: Int
    var id: String { name }
}

/// 自然周（周一开周）辅助
enum CalendarWeekHelper {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.locale = Locale(identifier: "zh_CN")
        return c
    }

    /// 参考日所在周的起止（周一 00:00 .. 下周一 00:00）
    static func weekInterval(containing date: Date) -> DateInterval? {
        calendar.dateInterval(of: .weekOfYear, for: date)
    }

    /// 已结束的上一自然周
    static func lastCompletedWeek(reference: Date = Date()) -> (start: Date, end: Date, weekID: String)? {
        guard let thisWeek = weekInterval(containing: reference) else { return nil }
        let start = calendar.date(byAdding: .day, value: -7, to: thisWeek.start) ?? thisWeek.start
        let end = thisWeek.start
        return (start, end, weekID(for: start))
    }

    /// 上上周（用于环比）
    static func weekBeforeLast(reference: Date = Date()) -> (start: Date, end: Date)? {
        guard let last = lastCompletedWeek(reference: reference) else { return nil }
        let start = calendar.date(byAdding: .day, value: -7, to: last.start) ?? last.start
        return (start, last.start)
    }

    static func weekID(for weekStart: Date) -> String {
        let cal = calendar
        let year = cal.component(.yearForWeekOfYear, from: weekStart)
        let week = cal.component(.weekOfYear, from: weekStart)
        return String(format: "%d-W%02d", year, week)
    }

    /// 今天是否为周一
    static func isMonday(_ date: Date = Date()) -> Bool {
        calendar.component(.weekday, from: date) == 2
    }

    static func activities(_ days: [DailyActivity], in start: Date, end: Date) -> [DailyActivity] {
        days.filter { $0.date >= start && $0.date < end }
    }

    static func workouts(_ list: [WorkoutRecord], in start: Date, end: Date) -> [WorkoutRecord] {
        list.filter { $0.start >= start && $0.start < end }
            .sorted { $0.start > $1.start }
    }

    static func sleepNights(_ nights: [SleepNight], in start: Date, end: Date) -> [SleepNight] {
        nights.filter { $0.date >= start && $0.date < end }
            .sorted { $0.date < $1.date }
    }
}
