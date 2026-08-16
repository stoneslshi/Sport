#if DEBUG
import Foundation
import HealthKit
import CoreLocation

/// 仅 Debug 使用的本地示例数据，方便模拟器 / 无健康数据时调试五 Tab 与详情页。
enum DebugSampleData {

    static let runningID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let cyclingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let swimID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let strengthID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    static let walkID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    struct Snapshot {
        var today: DailyActivity?
        var last7Days: [DailyActivity]
        var last30Days: [DailyActivity]
        var previous7Days: [DailyActivity]
        var previous30Days: [DailyActivity]
        var workouts: [WorkoutRecord]
        var bodyProfile: BodyProfile
        var heartMetrics: HeartMetrics
        var bodyTrends: BodyTrends
        var recoveryBaseline: RecoveryBaseline
        var sleepNights: [SleepNight]
        var pinCoords: [UUID: CLLocationCoordinate2D]
        var weeklyAdvice: WeeklyAdviceRecord?
        var aiAdvice: String
        var details: [UUID: WorkoutRecord]
    }

    static func make(now: Date = Date(), calendar: Calendar = .current) -> Snapshot {
        let days60 = makeDailyActivities(now: now, calendar: calendar, days: 60)
        let last30 = Array(days60.suffix(30))
        let last14 = Array(days60.suffix(14))
        let workouts = makeWorkouts(now: now, calendar: calendar)
        var details: [UUID: WorkoutRecord] = [:]
        var pins: [UUID: CLLocationCoordinate2D] = [:]
        for var record in workouts {
            enrichDetail(&record)
            details[record.id] = record
            if let first = record.routeCoordinates.first {
                pins[record.id] = first
            }
        }
        let body = makeBodyProfile()
        let sleep = makeSleepNights(now: now, calendar: calendar)
        return Snapshot(
            today: last30.last,
            last7Days: Array(last30.suffix(7)),
            last30Days: last30,
            previous7Days: Array(last14.prefix(7)),
            previous30Days: Array(days60.prefix(30)),
            workouts: workouts,
            bodyProfile: body,
            heartMetrics: HeartMetrics(restingHR: 54, averageHR7d: 68, hrvSDNN: 48),
            bodyTrends: makeBodyTrends(now: now, calendar: calendar),
            recoveryBaseline: RecoveryBaseline(
                restingHR: 54, restingHRDelta: -1.5, hrvSDNN: 48, averageHR7d: 68),
            sleepNights: sleep,
            pinCoords: pins,
            weeklyAdvice: makeWeeklyAdvice(now: now, calendar: calendar),
            aiAdvice: "近几日有氧节奏稳定，睡眠深睡占比不错。今日活动能量还差一点，傍晚补一次 30 分钟轻松跑或快走即可；力量日保持两次/周即可。",
            details: details
        )
    }

    // MARK: - 日常活动

    private static func makeDailyActivities(now: Date, calendar: Calendar, days: Int) -> [DailyActivity] {
        let start = calendar.date(
            byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)
        ) ?? now
        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let weekday = calendar.component(.weekday, from: day)
            let isWeekend = weekday == 1 || weekday == 7
            let isToday = calendar.isDateInToday(day)
            let wave = sin(Double(offset) / 4.2)
            let energy = isToday ? 320.0 : (isWeekend ? 520 : 410) + wave * 60
            let steps = isToday ? 6400.0 : (isWeekend ? 11000 : 8200) + wave * 1200
            let exercise = isToday ? 18.0 : (isWeekend ? 55 : 38) + wave * 8
            return DailyActivity(
                date: day,
                steps: max(steps, 1200),
                distanceKM: max(steps, 1200) * 0.00072,
                activeEnergyKcal: max(energy, 80),
                exerciseMinutes: max(exercise, 0),
                standMinutes: isToday ? 8 : 11,
                flightsClimbed: isWeekend ? 12 : 6
            )
        }
    }

    // MARK: - 运动

    private static func makeWorkouts(now: Date, calendar: Calendar) -> [WorkoutRecord] {
        func start(_ daysAgo: Int, hour: Int, minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        let runStart = start(0, hour: 7, minute: 10)
        var run = WorkoutRecord(
            id: runningID,
            activityType: .running,
            start: runStart,
            end: runStart.addingTimeInterval(32 * 60),
            durationMinutes: 32,
            caloriesKcal: 310,
            distanceKM: 5.12,
            avgHR: 158,
            maxHR: 176,
            elevationGain: 28
        )
        run.weatherTemperatureC = 24
        run.weatherHumidityPercent = 62

        let swimStart = start(1, hour: 19, minute: 5)
        var swim = WorkoutRecord(
            id: swimID,
            activityType: .swimming,
            start: swimStart,
            end: swimStart.addingTimeInterval(38 * 60),
            durationMinutes: 38,
            caloriesKcal: 360,
            distanceKM: 1.0,
            avgHR: 142,
            maxHR: 161,
            poolLength: 50
        )

        let rideStart = start(3, hour: 8, minute: 0)
        var ride = WorkoutRecord(
            id: cyclingID,
            activityType: .cycling,
            start: rideStart,
            end: rideStart.addingTimeInterval(58 * 60),
            durationMinutes: 58,
            caloriesKcal: 480,
            distanceKM: 18.6,
            avgHR: 136,
            maxHR: 164,
            elevationGain: 86
        )
        ride.weatherTemperatureC = 21

        let liftStart = start(5, hour: 20, minute: 15)
        let lift = WorkoutRecord(
            id: strengthID,
            activityType: .functionalStrengthTraining,
            start: liftStart,
            end: liftStart.addingTimeInterval(46 * 60),
            durationMinutes: 46,
            caloriesKcal: 220,
            distanceKM: nil,
            avgHR: 118,
            maxHR: 148
        )

        let walkStart = start(12, hour: 18, minute: 30)
        var walk = WorkoutRecord(
            id: walkID,
            activityType: .walking,
            start: walkStart,
            end: walkStart.addingTimeInterval(41 * 60),
            durationMinutes: 41,
            caloriesKcal: 180,
            distanceKM: 3.8,
            avgHR: 108,
            maxHR: 124,
            elevationGain: 12
        )

        var extras: [WorkoutRecord] = []
        let extraDays = [18, 26, 40, 70, 110, 200]
        for (i, ago) in extraDays.enumerated() {
            let s = start(ago, hour: 7, minute: 30)
            extras.append(WorkoutRecord(
                id: UUID(uuidString: "66666666-6666-6666-6666-\(String(format: "%012d", i + 1))")!,
                activityType: i % 2 == 0 ? .running : .yoga,
                start: s,
                end: s.addingTimeInterval(30 * 60),
                durationMinutes: 30,
                caloriesKcal: i % 2 == 0 ? 280 : 90,
                distanceKM: i % 2 == 0 ? 4.6 : nil,
                avgHR: 140,
                maxHR: 160
            ))
        }

        return ([run, swim, ride, lift, walk] + extras).sorted { $0.start > $1.start }
    }

    private static func enrichDetail(_ record: inout WorkoutRecord) {
        switch record.id {
        case runningID:
            record.routeCoordinates = loopRoute(center: shanghaiCenter, minutes: record.durationMinutes, radiusM: 700)
            record.elevationSeries = elevation(along: record.routeCoordinates, durationMin: record.durationMinutes, base: 8)
            record.heartRateSeries = heartRate(durationMin: record.durationMinutes, base: 148, peak: 176)
            record.splits = (1...5).map { KMSplit(index: $0, paceMin: 6.1 + Double($0 % 3) * 0.12, segmentMeters: 1000) }
            record.hrZones = HealthKitManager.heartRateZones(
                from: record.heartRateSeries, maxHRHint: record.maxHR, ageYears: 32)
        case cyclingID:
            record.routeCoordinates = loopRoute(center: shanghaiCenter, minutes: record.durationMinutes, radiusM: 1800)
            record.elevationSeries = elevation(along: record.routeCoordinates, durationMin: record.durationMinutes, base: 6)
            record.heartRateSeries = heartRate(durationMin: record.durationMinutes, base: 128, peak: 164)
            record.splits = (1...18).map { KMSplit(index: $0, paceMin: 3.05 + Double($0 % 4) * 0.08, segmentMeters: 1000) }
            record.hrZones = HealthKitManager.heartRateZones(
                from: record.heartRateSeries, maxHRHint: record.maxHR, ageYears: 32)
        case walkID:
            record.routeCoordinates = loopRoute(center: shanghaiCenter, minutes: record.durationMinutes, radiusM: 450)
            record.heartRateSeries = heartRate(durationMin: record.durationMinutes, base: 102, peak: 124)
            record.hrZones = HealthKitManager.heartRateZones(
                from: record.heartRateSeries, maxHRHint: record.maxHR, ageYears: 32)
        case swimID:
            enrichSwim(&record)
            record.heartRateSeries = heartRate(durationMin: record.durationMinutes, base: 132, peak: 161)
            record.hrZones = HealthKitManager.heartRateZones(
                from: record.heartRateSeries, maxHRHint: record.maxHR, ageYears: 32)
        default:
            record.heartRateSeries = heartRate(durationMin: record.durationMinutes, base: 110, peak: record.maxHR ?? 140)
            record.hrZones = HealthKitManager.heartRateZones(
                from: record.heartRateSeries, maxHRHint: record.maxHR, ageYears: 32)
        }
    }

    private static func enrichSwim(_ record: inout WorkoutRecord) {
        let pool = record.poolLength ?? 50
        let lapCount = 20
        var laps: [SwimLap] = []
        var cursor = record.start
        for i in 1...lapCount {
            let stroke: SwimStroke = i > 16 ? .breaststroke : .freestyle
            let duration = stroke == .freestyle ? 52.0 + Double(i % 4) : 68.0
            let end = cursor.addingTimeInterval(duration)
            laps.append(SwimLap(
                index: i,
                start: cursor,
                end: end,
                distanceM: pool,
                stroke: stroke,
                strokeCount: stroke == .freestyle ? 38 + i % 3 : 28
            ))
            cursor = end.addingTimeInterval(i == 10 ? 45 : 8)
        }
        record.swimLaps = laps
        record.laps = lapCount
        record.totalStrokeCount = laps.compactMap(\.strokeCount).reduce(0, +)
        record.strokeDistribution = [
            .freestyle: Double(16) * pool,
            .breaststroke: Double(4) * pool
        ]
        record.splits = (1...10).map { KMSplit(index: $0, paceMin: 1.75 + Double($0 % 3) * 0.06, segmentMeters: 100) }
        record.bestPacePer100m = laps.compactMap(\.paceMinPer100m).min()
        record.avgSWOLF = {
            let values = laps.compactMap(\.swolf)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }()
        record.swimSets = [
            SwimSet(index: 1, startLap: 1, endLap: 10, distanceM: 500, activeSec: 540, restSec: 72),
            SwimSet(index: 2, startLap: 11, endLap: 20, distanceM: 500, activeSec: 580, restSec: 80)
        ]
        record.sessionDistanceBests = [
            SwimDistanceBest(meters: 100, timeSec: 102),
            SwimDistanceBest(meters: 200, timeSec: 214),
            SwimDistanceBest(meters: 400, timeSec: 448)
        ]
    }

    // MARK: - 睡眠 / 身体 / 周报

    private static func makeSleepNights(now: Date, calendar: Calendar) -> [SleepNight] {
        (0..<14).compactMap { offset in
            let daysAgo = 13 - offset
            guard let wakeDay = calendar.date(
                byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)
            ) else { return nil }
            let inBed = calendar.date(byAdding: .hour, value: -7, to: wakeDay)?
                .addingTimeInterval(23 * 60) ?? wakeDay
            let wake = wakeDay.addingTimeInterval((7 * 3600) + 12 * 60)
            let quality = 0.92 - Double(daysAgo % 5) * 0.04
            let asleep = 7.1 * 60 * quality
            var night = SleepNight(date: wakeDay, inBed: inBed, wake: wake, asleepMin: asleep)
            night.deepMin = asleep * 0.22
            night.coreMin = asleep * 0.48
            night.remMin = asleep * 0.22
            night.awakeMin = asleep * 0.08
            night.segments = [
                SleepStageSegment(stage: .core, start: inBed, end: inBed.addingTimeInterval(40 * 60)),
                SleepStageSegment(stage: .deep, start: inBed.addingTimeInterval(40 * 60), end: inBed.addingTimeInterval(110 * 60)),
                SleepStageSegment(stage: .core, start: inBed.addingTimeInterval(110 * 60), end: inBed.addingTimeInterval(180 * 60)),
                SleepStageSegment(stage: .rem, start: inBed.addingTimeInterval(180 * 60), end: inBed.addingTimeInterval(230 * 60)),
                SleepStageSegment(stage: .awake, start: inBed.addingTimeInterval(230 * 60), end: inBed.addingTimeInterval(240 * 60)),
                SleepStageSegment(stage: .core, start: inBed.addingTimeInterval(240 * 60), end: inBed.addingTimeInterval(320 * 60)),
                SleepStageSegment(stage: .deep, start: inBed.addingTimeInterval(320 * 60), end: inBed.addingTimeInterval(360 * 60)),
                SleepStageSegment(stage: .rem, start: inBed.addingTimeInterval(360 * 60), end: wake)
            ]
            night.vitals = SleepVitals(
                respiratoryRate: 14.2,
                oxygenSaturation: 0.97,
                wristTempDelta: daysAgo == 0 ? 0.12 : -0.05,
                wristTempAbsolute: nil
            )
            if daysAgo == 2 {
                night.nap = SleepNap(
                    start: wakeDay.addingTimeInterval(15 * 3600),
                    end: wakeDay.addingTimeInterval(15.4 * 3600),
                    asleepMin: 22
                )
            }
            return night
        }
    }

    private static func makeBodyProfile() -> BodyProfile {
        var profile = BodyProfile()
        profile.ageYears = 32
        profile.biologicalSex = "男"
        profile.heightCM = 175
        profile.weightKG = 70.4
        profile.bodyFatPercent = 16.8
        profile.vo2Max = 46.2
        return profile
    }

    private static func makeBodyTrends(now: Date, calendar: Calendar) -> BodyTrends {
        var weight: [BodyMetricPoint] = []
        var fat: [BodyMetricPoint] = []
        for offset in 0..<90 {
            guard let day = calendar.date(byAdding: .day, value: offset - 89, to: calendar.startOfDay(for: now)) else {
                continue
            }
            if offset % 3 != 0 { continue }
            weight.append(BodyMetricPoint(date: day, value: 71.2 - Double(offset) * 0.009))
            fat.append(BodyMetricPoint(date: day, value: 17.6 - Double(offset) * 0.008))
        }
        return BodyTrends(weightPoints: weight, bodyFatPoints: fat)
    }

    private static func makeWeeklyAdvice(now: Date, calendar _: Calendar) -> WeeklyAdviceRecord? {
        guard let last = CalendarWeekHelper.lastCompletedWeek(reference: now) else { return nil }
        let brief = WeeklyAdviceBrief(
            headline: "有氧节奏稳，补点力量",
            vibe: "稳健",
            highlights: [
                .init(symbol: "run", title: "训练 5 次", detail: "跑步 + 游泳 + 骑行"),
                .init(symbol: "sleep", title: "均睡 7.1h", detail: "深睡占比正常"),
                .init(symbol: "trophy", title: "评分 78", detail: "活动能量多数达标")
            ],
            metricNotes: [
                .init(key: "score", note: "整体处于可维持区间"),
                .init(key: "sleep", note: "作息较规律")
            ],
            actions: ["本周再加一次力量", "保持 7 小时睡眠", "轻松跑控制配速"]
        )
        return WeeklyAdviceRecord(
            weekID: last.weekID,
            weekStart: last.start,
            weekEnd: last.end,
            content: brief.headline,
            createdAt: now,
            snapshot: WeeklyAdviceSnapshot(
                workoutCount: 5,
                totalExerciseMin: 215,
                totalDistanceKM: 28.5,
                totalEnergyKcal: 1550,
                activityScore: 78,
                energyGoalHitDays: 5,
                avgSleepHours: 7.1,
                avgDeepMin: 86,
                goodSleepNights: 5,
                sleepNightCount: 7,
                weightKG: 70.4,
                bmi: 23.0,
                restingHR: 54,
                topWorkoutTypes: [
                    WorkoutTypeCount(name: "跑步", count: 2),
                    WorkoutTypeCount(name: "游泳", count: 1),
                    WorkoutTypeCount(name: "骑行", count: 1)
                ]
            ),
            brief: brief
        )
    }

    // MARK: - 曲线 / 轨迹

    /// 上海人民广场附近 WGS-84 点，详情页会再转 GCJ-02。
    private static let shanghaiCenter = CLLocationCoordinate2D(latitude: 31.230416, longitude: 121.473701)

    private static func loopRoute(
        center: CLLocationCoordinate2D,
        minutes: Double,
        radiusM: Double
    ) -> [CLLocationCoordinate2D] {
        let count = max(Int(minutes * 2.2), 40)
        let latM = 111_320.0
        let lonM = 111_320.0 * cos(center.latitude * .pi / 180)
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1) * 2 * .pi
            return CLLocationCoordinate2D(
                latitude: center.latitude + (radiusM * sin(t)) / latM,
                longitude: center.longitude + (radiusM * cos(t) * 1.15) / lonM
            )
        }
    }

    private static func elevation(
        along coordinates: [CLLocationCoordinate2D],
        durationMin: Double,
        base: Double
    ) -> [ElevationPoint] {
        guard coordinates.count > 1 else { return [] }
        return coordinates.enumerated().map { index, _ in
            let t = Double(index) / Double(coordinates.count - 1)
            return ElevationPoint(
                minute: t * durationMin,
                meters: base + 12 * sin(t * 4.2) + 4 * sin(t * 11)
            )
        }
    }

    private static func heartRate(durationMin: Double, base: Double, peak: Double) -> [HeartRatePoint] {
        let count = max(Int(durationMin), 12)
        return (0..<count).map { i in
            let t = Double(i) / Double(max(count - 1, 1))
            let ramp = t < 0.12 ? t / 0.12 : (t > 0.88 ? (1 - t) / 0.12 : 1)
            let wobble = 4 * sin(t * 18)
            return HeartRatePoint(minute: t * durationMin, bpm: base + (peak - base) * ramp + wobble)
        }
    }
}
#endif
