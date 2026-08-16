import Foundation
import HealthKit
import CoreLocation

/// 负责与 Apple 健康（HealthKit）交互：授权与数据读取（只读，不写入）。
final class HealthKitManager {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()
    private let calendar = Calendar.current

    private init() {}

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    // MARK: - 授权

    /// 申请读取授权。注意：出于隐私，系统不会告知用户具体同意了哪些类型，
    /// 所以这里仅表示"授权流程已发起且无错误"，具体数据需要在读取后判空。
    @discardableResult
    func requestAuthorization() async throws -> Bool {
        guard isHealthDataAvailable else { return false }

        func q(_ id: HKQuantityTypeIdentifier) -> HKQuantityType {
            HKQuantityType.quantityType(forIdentifier: id)!
        }
        func c(_ id: HKCharacteristicTypeIdentifier) -> HKCharacteristicType {
            HKObjectType.characteristicType(forIdentifier: id)!
        }

        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!

        let readTypes: Set<HKObjectType> = [
            q(.stepCount),
            q(.distanceWalkingRunning),
            q(.distanceCycling),
            q(.distanceSwimming),
            q(.swimmingStrokeCount),
            q(.activeEnergyBurned),
            q(.appleExerciseTime),
            q(.appleStandTime),
            q(.flightsClimbed),
            q(.heartRate),
            q(.restingHeartRate),
            q(.heartRateVariabilitySDNN),
            q(.bodyMass),
            q(.height),
            q(.bodyFatPercentage),
            q(.bodyMassIndex),
            q(.vo2Max),
            q(.respiratoryRate),
            q(.oxygenSaturation),
            q(.appleSleepingWristTemperature),
            q(.bodyTemperature),
            sleepType,
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            c(.dateOfBirth),
            c(.biologicalSex)
        ]

        try await store.requestAuthorization(toShare: [], read: readTypes)
        return true
    }

    // MARK: - 日常活动序列

    /// 拉取最近 days 天（含今天）的每日活动数据，按日期升序返回。
    func fetchDailyActivities(days: Int) async throws -> [DailyActivity] {
        let now = Date()
        let end = calendar.startOfDay(for: now).addingTimeInterval(24 * 3600)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) else {
            return []
        }

        async let steps = dailySums(.stepCount, unit: .count(), from: start, to: end)
        async let distance = dailySums(.distanceWalkingRunning, unit: .meterUnit(with: .kilo), from: start, to: end)
        async let energy = dailySums(.activeEnergyBurned, unit: .kilocalorie(), from: start, to: end)
        async let exercise = dailySums(.appleExerciseTime, unit: .minute(), from: start, to: end)
        async let stand = dailySums(.appleStandTime, unit: .minute(), from: start, to: end)
        async let flights = dailySums(.flightsClimbed, unit: .count(), from: start, to: end)

        let (stepsMap, distMap, energyMap, exMap, standMap, flightMap) =
            try await (steps, distance, energy, exercise, stand, flights)

        var result: [DailyActivity] = []
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            result.append(DailyActivity(
                date: day,
                steps: stepsMap[day] ?? 0,
                distanceKM: distMap[day] ?? 0,
                activeEnergyKcal: energyMap[day] ?? 0,
                exerciseMinutes: exMap[day] ?? 0,
                standMinutes: standMap[day] ?? 0,
                flightsClimbed: flightMap[day] ?? 0
            ))
        }
        return result
    }

    // MARK: - 心率

    func fetchHeartMetrics() async throws -> HeartMetrics {
        async let resting = latestQuantity(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()))
        async let hrv = latestQuantity(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli))
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -7, to: end) ?? end
        async let avg = averageQuantity(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: start, to: end)

        return HeartMetrics(
            restingHR: try await resting,
            averageHR7d: try await avg,
            hrvSDNN: try await hrv
        )
    }

    // MARK: - 身体档案

    func fetchBodyProfile() async throws -> BodyProfile {
        var profile = BodyProfile()

        if let birth = try? store.dateOfBirthComponents(),
           let birthDate = birth.date {
            profile.ageYears = calendar.dateComponents([.year], from: birthDate, to: Date()).year
        }
        if let sexObject = try? store.biologicalSex() {
            switch sexObject.biologicalSex {
            case .female: profile.biologicalSex = "女"
            case .male: profile.biologicalSex = "男"
            case .other: profile.biologicalSex = "其他"
            default: profile.biologicalSex = nil
            }
        }

        async let height = latestQuantity(.height, unit: .meterUnit(with: .centi))
        async let weight = latestQuantity(.bodyMass, unit: .gramUnit(with: .kilo))
        async let fat = latestQuantity(.bodyFatPercentage, unit: .percent())
        async let vo2 = latestQuantity(.vo2Max,
                                       unit: HKUnit.literUnit(with: .milli)
                                        .unitDivided(by: .gramUnit(with: .kilo))
                                        .unitDivided(by: .minute()))

        profile.heightCM = try await height
        profile.weightKG = try await weight
        if let fatValue = try await fat {
            profile.bodyFatPercent = fatValue * 100
        }
        profile.vo2Max = try await vo2
        return profile
    }

    /// 拉取体重 / 体脂历史（升序），默认近 days 天。
    func fetchBodyTrends(days: Int = 90) async throws -> BodyTrends {
        let end = Date()
        guard let start = calendar.date(byAdding: .day, value: -days, to: end) else {
            return BodyTrends()
        }
        async let weights = quantitySeries(.bodyMass, unit: .gramUnit(with: .kilo), from: start, to: end)
        async let fats = quantitySeries(.bodyFatPercentage, unit: .percent(), from: start, to: end)
        let (w, f) = try await (weights, fats)
        return BodyTrends(
            weightPoints: w,
            bodyFatPoints: f.map { BodyMetricPoint(date: $0.date, value: $0.value * 100) }
        )
    }

    /// 恢复基线：当前静息/HRV/7日均，以及静息心率相对前一周的变化。
    func fetchRecoveryBaseline() async throws -> RecoveryBaseline {
        let heart = try await fetchHeartMetrics()
        var baseline = RecoveryBaseline(
            restingHR: heart.restingHR,
            restingHRDelta: nil,
            hrvSDNN: heart.hrvSDNN,
            averageHR7d: heart.averageHR7d
        )
        let end = Date()
        guard let mid = calendar.date(byAdding: .day, value: -7, to: end),
              let start = calendar.date(byAdding: .day, value: -14, to: end) else { return baseline }
        let unit = HKUnit.count().unitDivided(by: .minute())
        async let recent = averageQuantity(.restingHeartRate, unit: unit, from: mid, to: end)
        async let previous = averageQuantity(.restingHeartRate, unit: unit, from: start, to: mid)
        if let r = try await recent, let p = try await previous {
            baseline.restingHRDelta = r - p
        }
        return baseline
    }

    /// 指定时间窗内的数量样本序列（按开始时间升序）。
    private func quantitySeries(_ id: HKQuantityTypeIdentifier,
                                unit: HKUnit,
                                from start: Date,
                                to end: Date) async throws -> [BodyMetricPoint] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
        // 按天取末日最新一条，避免同一天多次称重导致折线抖动过密
        var byDay: [Date: BodyMetricPoint] = [:]
        for s in samples {
            let day = calendar.startOfDay(for: s.startDate)
            byDay[day] = BodyMetricPoint(date: s.startDate, value: s.quantity.doubleValue(for: unit))
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    // MARK: - 睡眠

    /// 拉取最近 nights 晚的睡眠数据，按「起床日」聚合，按日期升序返回。
    /// 含主睡眠分期时间轴、前一日傍晚午睡、以及昨夜生命体征（呼吸/血氧/腕温）。
    func fetchSleepNights(nights: Int) async throws -> [SleepNight] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let now = Date()
        let end = now
        // 多取两天余量，便于挂载前一日傍晚午睡
        guard let start = calendar.date(byAdding: .day, value: -(nights + 2),
                                        to: calendar.startOfDay(for: now)) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }

        var result = aggregateSleep(samples: samples, nights: nights)

        // 为每一晚补生命体征（主睡眠窗内均值）
        for i in result.indices {
            result[i].vitals = await fetchSleepVitals(from: result[i].inBed, to: result[i].wake)
        }
        return result
    }

    /// 主睡眠窗内的呼吸频率 / 血氧 / 腕温。
    func fetchSleepVitals(from start: Date, to end: Date) async -> SleepVitals {
        var vitals = SleepVitals()
        async let resp = averageQuantity(.respiratoryRate,
                                         unit: HKUnit.count().unitDivided(by: .minute()),
                                         from: start, to: end)
        async let spo2 = averageQuantity(.oxygenSaturation, unit: .percent(), from: start, to: end)
        async let wrist = averageQuantity(.appleSleepingWristTemperature,
                                          unit: .degreeCelsius(), from: start, to: end)
        async let body = averageQuantity(.bodyTemperature,
                                         unit: .degreeCelsius(), from: start, to: end)
        vitals.respiratoryRate = try? await resp
        vitals.oxygenSaturation = try? await spo2
        // appleSleepingWristTemperature 本身就是相对基线的偏差（°C）
        if let delta = try? await wrist {
            vitals.wristTempDelta = delta
        } else if let absTemp = try? await body {
            vitals.wristTempAbsolute = absTemp
        }
        return vitals
    }

    /// 把睡眠分段样本按「起床日」归组并累计各阶段时长。
    /// 口径对齐系统「健康」App 的过夜主睡眠：
    /// - 同一天多段只取主睡眠；前一日傍晚短睡挂到次日主睡眠的 nap
    /// - 睡着总时长用时间并集；阶段占比用单一优选数据源
    private func aggregateSleep(samples: [HKCategorySample], nights: Int) -> [SleepNight] {
        var grouped: [Date: [HKCategorySample]] = [:]
        for s in samples {
            guard isAsleepOrAwake(s) else { continue }
            let day = attributionDay(for: s.endDate)
            grouped[day, default: []].append(s)
        }

        // day → (main session, all sessions)
        var sessionMap: [Date: (main: [HKCategorySample], all: [[HKCategorySample]])] = [:]
        var nightsResult: [SleepNight] = []

        for (day, list) in grouped {
            let sorted = list.sorted { $0.startDate < $1.startDate }
            guard !sorted.isEmpty else { continue }

            let sessions = clusterSleepSessions(sorted, maxGap: 90 * 60)
            guard let main = pickMainSleepSession(sessions) else { continue }
            sessionMap[day] = (main, sessions)

            let asleepSamples = main.filter { stage(for: $0) != .awake }
            guard let inBed = asleepSamples.map(\.startDate).min(),
                  let wake = main.map(\.endDate).max() else { continue }

            var night = SleepNight(date: day, inBed: inBed, wake: wake)
            night.asleepMin = mergedMinutes(asleepSamples.map { ($0.startDate, $0.endDate) })

            let staged = preferredStagedSamples(in: main)
            for stg in SleepStage.allCases {
                let intervals = staged
                    .filter { stage(for: $0) == stg }
                    .map { ($0.startDate, $0.endDate) }
                night.setMinutes(mergedMinutes(intervals), of: stg)
            }

            let stageSum = night.deepMin + night.coreMin + night.remMin
            if stageSum > 0, night.asleepMin > 0, abs(stageSum - night.asleepMin) > 2 {
                let scale = night.asleepMin / stageSum
                night.deepMin *= scale
                night.coreMin *= scale
                night.remMin *= scale
            }

            night.segments = buildSegments(from: staged)
            nightsResult.append(night)
        }

        nightsResult.sort { $0.date < $1.date }

        // 把「前一日傍晚」的非主睡眠段挂到次日作为午睡
        for i in nightsResult.indices {
            let day = nightsResult[i].date
            guard let prevDay = calendar.date(byAdding: .day, value: -1, to: day),
                  let prev = sessionMap[prevDay] else { continue }
            let eveningNaps = prev.all.compactMap { session -> SleepNap? in
                // 跳过前一日的主睡眠（通常是前一晚过夜）
                if sessionsEqual(session, prev.main) { return nil }
                guard let start = session.map(\.startDate).min(),
                      let end = session.map(\.endDate).max() else { return nil }
                // 傍晚短睡：开始在中午之后
                guard calendar.component(.hour, from: start) >= 12 else { return nil }
                let asleep = asleepMinutes(in: session)
                guard asleep >= 10, asleep <= 180 else { return nil }
                return SleepNap(start: start, end: end, asleepMin: asleep)
            }
            nightsResult[i].nap = eveningNaps.max(by: { $0.asleepMin < $1.asleepMin })
        }

        return Array(nightsResult.suffix(nights))
    }

    /// 由优选分期样本生成时间轴片段（按开始时间排序，相邻同阶段合并）。
    private func buildSegments(from samples: [HKCategorySample]) -> [SleepStageSegment] {
        let sorted = samples.sorted { $0.startDate < $1.startDate }
        guard !sorted.isEmpty else { return [] }
        var result: [SleepStageSegment] = []
        var curStage = stage(for: sorted[0])
        var curStart = sorted[0].startDate
        var curEnd = sorted[0].endDate
        for s in sorted.dropFirst() {
            let stg = stage(for: s)
            if stg == curStage, s.startDate <= curEnd.addingTimeInterval(60) {
                curEnd = max(curEnd, s.endDate)
            } else {
                if curEnd > curStart {
                    result.append(SleepStageSegment(stage: curStage, start: curStart, end: curEnd))
                }
                curStage = stg
                curStart = s.startDate
                curEnd = s.endDate
            }
        }
        if curEnd > curStart {
            result.append(SleepStageSegment(stage: curStage, start: curStart, end: curEnd))
        }
        return result
    }

    /// 将样本按时间间隔拆成多段会话（间隔超过 maxGap 则新开一段）。
    private func clusterSleepSessions(_ samples: [HKCategorySample],
                                      maxGap: TimeInterval) -> [[HKCategorySample]] {
        guard let first = samples.first else { return [] }
        var sessions: [[HKCategorySample]] = []
        var current: [HKCategorySample] = [first]
        for s in samples.dropFirst() {
            let sessionEnd = current.map(\.endDate).max() ?? current.last!.endDate
            let gap = s.startDate.timeIntervalSince(sessionEnd)
            if gap > maxGap {
                sessions.append(current)
                current = [s]
            } else {
                current.append(s)
            }
        }
        sessions.append(current)
        return sessions
    }

    /// 选出主睡眠段：睡着时长最长；并列时优先早晨起床的（过夜睡）。
    private func pickMainSleepSession(_ sessions: [[HKCategorySample]]) -> [HKCategorySample]? {
        sessions.max { a, b in
            let da = asleepMinutes(in: a)
            let db = asleepMinutes(in: b)
            if abs(da - db) > 1 { return da < db }
            let wakeA = a.map(\.endDate).max() ?? a.last!.endDate
            let wakeB = b.map(\.endDate).max() ?? b.last!.endDate
            let hourA = calendar.component(.hour, from: wakeA)
            let hourB = calendar.component(.hour, from: wakeB)
            let morningA = hourA < 12
            let morningB = hourB < 12
            if morningA != morningB { return !morningA }
            return wakeA > wakeB
        }
    }

    /// 优先选用带深睡/REM/核心分期的数据源（通常是 Apple Watch）。
    private func preferredStagedSamples(in samples: [HKCategorySample]) -> [HKCategorySample] {
        let grouped = Dictionary(grouping: samples) {
            $0.sourceRevision.source.bundleIdentifier
        }
        let staged = grouped.filter { (_, list) in
            list.contains { sample in
                guard let v = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return false }
                switch v {
                case .asleepDeep, .asleepCore, .asleepREM: return true
                default: return false
                }
            }
        }
        guard !staged.isEmpty else { return samples }

        let ranked = staged.max { a, b in
            let watchA = isAppleWatchSource(a.value.first)
            let watchB = isAppleWatchSource(b.value.first)
            if watchA != watchB { return !watchA }
            return asleepMinutes(in: a.value) < asleepMinutes(in: b.value)
        }
        return ranked?.value ?? samples
    }

    private func isAppleWatchSource(_ sample: HKCategorySample?) -> Bool {
        guard let sample else { return false }
        let name = sample.sourceRevision.source.name.lowercased()
        let bundle = sample.sourceRevision.source.bundleIdentifier.lowercased()
        return name.contains("watch") || bundle.contains("watch")
    }

    private func asleepMinutes(in samples: [HKCategorySample]) -> Double {
        let intervals = samples
            .filter { stage(for: $0) != .awake }
            .map { ($0.startDate, $0.endDate) }
        return mergedMinutes(intervals)
    }

    /// 合并重叠时间区间后返回总分钟数（去重）。
    private func mergedMinutes(_ intervals: [(Date, Date)]) -> Double {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        guard var curStart = sorted.first?.0, var curEnd = sorted.first?.1 else { return 0 }
        var total: TimeInterval = 0
        for (s, e) in sorted.dropFirst() {
            if s <= curEnd {
                if e > curEnd { curEnd = e }
            } else {
                total += curEnd.timeIntervalSince(curStart)
                curStart = s
                curEnd = e
            }
        }
        total += curEnd.timeIntervalSince(curStart)
        return total / 60
    }

    private func attributionDay(for endDate: Date) -> Date {
        calendar.startOfDay(for: endDate)
    }

    private func isAsleepOrAwake(_ s: HKCategorySample) -> Bool {
        guard let v = HKCategoryValueSleepAnalysis(rawValue: s.value) else { return false }
        switch v {
        case .inBed: return false
        default: return true
        }
    }

    private func stage(for s: HKCategorySample) -> SleepStage {
        guard let v = HKCategoryValueSleepAnalysis(rawValue: s.value) else { return .core }
        switch v {
        case .asleepDeep: return .deep
        case .asleepREM:  return .rem
        case .awake:      return .awake
        case .asleepCore: return .core
        case .asleepUnspecified: return .core
        default: return .core
        }
    }

    /// 判断两段会话是否为同一段（用样本 UUID 集合比较）。
    private func sessionsEqual(_ a: [HKCategorySample], _ b: [HKCategorySample]) -> Bool {
        Set(a.map(\.uuid)) == Set(b.map(\.uuid))
    }

    // MARK: - 运动记录
    func fetchRecentWorkouts(limit: Int = 30) async throws -> [WorkoutRecord] {
        try await fetchWorkouts(from: nil, to: nil, limit: limit)
    }

    /// 按任意日期区间查询运动记录（供运动页时间范围切换使用）。
    /// start/end 为 nil 时表示不限制该端。
    func fetchWorkouts(from start: Date?, to end: Date?, limit: Int = 0) async throws -> [WorkoutRecord] {
        let workoutType = HKObjectType.workoutType()
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let predicate: NSPredicate?
        if start != nil || end != nil {
            predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        } else {
            predicate = nil
        }
        let queryLimit = limit > 0 ? limit : HKObjectQueryNoLimit

        let samples: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: predicate,
                limit: queryLimit,
                sortDescriptors: [sort]
            ) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }

        return samples.map { workout in
            let energy = workout.statistics(for: HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!)
                .flatMap { $0.sumQuantity() }?.doubleValue(for: .kilocalorie()) ?? 0

            var distanceMeters: Double?
            for id in [HKQuantityTypeIdentifier.distanceWalkingRunning, .distanceCycling, .distanceSwimming] {
                if let type = HKQuantityType.quantityType(forIdentifier: id),
                   let sum = workout.statistics(for: type)?.sumQuantity() {
                    distanceMeters = sum.doubleValue(for: .meter())
                    break
                }
            }

            // 心率（均值/峰值）
            var avgHR: Double?
            var maxHR: Double?
            if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
               let stats = workout.statistics(for: hrType) {
                let unit = HKUnit.count().unitDivided(by: .minute())
                avgHR = stats.averageQuantity()?.doubleValue(for: unit)
                maxHR = stats.maximumQuantity()?.doubleValue(for: unit)
            }

            // 爬升
            var elevation: Double?
            if let elevQ = workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity {
                elevation = elevQ.doubleValue(for: .meter())
            }

            // 泳池长度（仅泳池游泳有）
            var poolLength: Double?
            if workout.workoutActivityType == .swimming,
               let lapQ = workout.metadata?[HKMetadataKeyLapLength] as? HKQuantity {
                poolLength = lapQ.doubleValue(for: .meter())
            }

            let source = sourceInfo(for: workout)
            return WorkoutRecord(
                id: workout.uuid,
                activityType: workout.workoutActivityType,
                start: workout.startDate,
                end: workout.endDate,
                durationMinutes: workout.duration / 60,
                caloriesKcal: energy,
                distanceKM: distanceMeters.map { $0 / 1000 },
                source: source.source,
                sourceName: source.name,
                avgHR: avgHR,
                maxHR: maxHR,
                elevationGain: elevation,
                poolLength: poolLength
            )
        }
    }

    // MARK: - 运动详情（心率曲线 + GPS 轨迹）

    /// 根据 workout 的 UUID 找到原始 HKWorkout。
    private func fetchWorkout(id: UUID) async throws -> HKWorkout? {
        let predicate = HKQuery.predicateForObject(with: id)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                                      predicate: predicate, limit: 1,
                                      sortDescriptors: nil) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: results?.first as? HKWorkout)
            }
            store.execute(query)
        }
    }

    /// 读取某次运动的心率采样序列（相对开始时间的分钟, bpm），最多下采样到 ~60 个点。
    func fetchHeartRateSeries(for record: WorkoutRecord) async throws -> [HeartRatePoint] {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: record.start, end: record.end, options: [])
        let unit = HKUnit.count().unitDivided(by: .minute())
        let start = record.start

        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: hrType, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }

        let points = samples.map {
            HeartRatePoint(minute: $0.startDate.timeIntervalSince(start) / 60,
                           bpm: $0.quantity.doubleValue(for: unit))
        }
        // 下采样：超过 60 点时按步长抽稀，避免图表过密
        guard points.count > 60 else { return points }
        let step = points.count / 60
        return points.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
    }

    /// 一次运动的 GPS 轨迹打包：坐标 + 海拔曲线。
    struct WorkoutRoutePayload {
        var coordinates: [CLLocationCoordinate2D] = []
        var elevationSeries: [ElevationPoint] = []
    }

    /// 运动环境：天气（来自 workout metadata）。
    struct WorkoutContextPayload {
        var weatherTemperatureC: Double?
        var weatherHumidityPercent: Double?
    }

    /// 读取 workout metadata 中的室内外与天气。
    func fetchWorkoutContext(for record: WorkoutRecord) async throws -> WorkoutContextPayload {
        guard let workout = try await fetchWorkout(id: record.id) else { return WorkoutContextPayload() }
        return parseWorkoutMetadata(from: workout)
    }

    private func parseWorkoutMetadata(from workout: HKWorkout) -> WorkoutContextPayload {
        var payload = WorkoutContextPayload()
        guard let metadata = workout.metadata else { return payload }

        if let tempQ = metadata[HKMetadataKeyWeatherTemperature] as? HKQuantity {
            payload.weatherTemperatureC = tempQ.doubleValue(for: .degreeCelsius())
        }

        if let humidQ = metadata[HKMetadataKeyWeatherHumidity] as? HKQuantity {
            payload.weatherHumidityPercent = normalizedHumidityPercent(humidQ)
        }

        return payload
    }

    /// HealthKit 湿度偶发异常大值，归一化到 0–100。
    private func normalizedHumidityPercent(_ quantity: HKQuantity) -> Double? {
        var value = quantity.doubleValue(for: .percent())
        if value <= 0 { return nil }
        if value <= 1 { value *= 100 }
        if value > 100 {
            // 个别记录以 0–10000 刻度存储
            if value <= 10_000 { value /= 100 }
            else { return nil }
        }
        return min(100, max(0, value))
    }

    /// 读取某次运动的 GPS 轨迹坐标（若有）。
    func fetchRoute(for record: WorkoutRecord) async throws -> [CLLocationCoordinate2D] {
        try await fetchRouteDetail(for: record).coordinates
    }

    /// 读取轨迹坐标与海拔曲线（同一趟 GPS，避免重复查询）。
    func fetchRouteDetail(for record: WorkoutRecord) async throws -> WorkoutRoutePayload {
        let locations = try await fetchRouteLocations(for: record)
        guard !locations.isEmpty else { return WorkoutRoutePayload() }
        return WorkoutRoutePayload(
            coordinates: locations.map(\.coordinate),
            elevationSeries: elevationSeries(from: locations, workoutStart: record.start)
        )
    }

    /// 只取轨迹第一个点，供位置相簿聚合（避免拉完整路线）。
    func fetchRouteStartCoordinate(for record: WorkoutRecord) async throws -> CLLocationCoordinate2D? {
        guard let workout = try await fetchWorkout(id: record.id) else { return nil }

        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(),
                                      predicate: predicate, limit: 1,
                                      sortDescriptors: nil) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (results as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }
        guard let route = routes.first else { return nil }

        return try await withCheckedThrowingContinuation { continuation in
            var settled = false
            let query = HKWorkoutRouteQuery(route: route) { query, locs, done, error in
                guard !settled else { return }
                if let error {
                    settled = true
                    continuation.resume(throwing: error)
                    return
                }
                if let first = locs?.first {
                    settled = true
                    self.store.stop(query)
                    continuation.resume(returning: first.coordinate)
                    return
                }
                if done {
                    settled = true
                    continuation.resume(returning: nil)
                }
            }
            store.execute(query)
        }
    }

    /// 由 GPS 点生成海拔曲线；过滤无效海拔，并适度下采样。
    private func elevationSeries(from locations: [CLLocation], workoutStart: Date) -> [ElevationPoint] {
        let valid = locations.filter { $0.verticalAccuracy >= 0 && $0.altitude.isFinite }
        guard valid.count >= 2 else { return [] }

        let alts = valid.map(\.altitude)
        let span = (alts.max() ?? 0) - (alts.min() ?? 0)
        // 几乎无起伏（平面室内/信号差）则不展示曲线
        guard span >= 3 else { return [] }

        var points = valid.map {
            ElevationPoint(
                minute: max(0, $0.timestamp.timeIntervalSince(workoutStart) / 60),
                meters: $0.altitude
            )
        }
        // 下采样到约 80 点，曲线更顺、渲染更轻
        if points.count > 80 {
            let step = max(1, points.count / 80)
            var sampled = points.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
            if let last = points.last, sampled.last?.minute != last.minute {
                sampled.append(last)
            }
            points = sampled
        }
        return points
    }

    /// 读取 GPS 轨迹的完整 CLLocation（含时间戳，用于分段配速）。
    private func fetchRouteLocations(for record: WorkoutRecord) async throws -> [CLLocation] {
        guard let workout = try await fetchWorkout(id: record.id) else { return [] }

        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(),
                                      predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (results as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }
        guard let route = routes.first else { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            var acc: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, locs, done, error in
                if let error { continuation.resume(throwing: error); return }
                if let locs { acc.append(contentsOf: locs) }
                if done { continuation.resume(returning: acc) }
            }
            store.execute(query)
        }
    }

    // MARK: - 分段配速

    /// 计算真实分段配速。
    /// - 跑步/骑行等：优先 GPS 轨迹；室内或无 GPS 时优先 workout 单段事件，其次距离采样；每 1 km 一段。
    /// - 游泳：每 100 m 一段；优先趟数事件（池长累加），其次距离采样 / GPS。
    func fetchSplits(for record: WorkoutRecord) async throws -> [KMSplit] {
        let segmentMeters: Double = record.isSwimming ? 100 : 1000

        if record.isSwimming {
            if let fromLaps = try await splitsFromSwimLaps(record: record, segmentMeters: segmentMeters),
               !fromLaps.isEmpty {
                return fromLaps
            }
        }

        let locations = try await fetchRouteLocations(for: record)
        if locations.count >= 2 {
            let fromRoute = splitsFromLocations(locations, segmentMeters: segmentMeters)
            if !fromRoute.isEmpty { return fromRoute }
        }

        if let fromDistance = try await splitsFromDistanceSamples(record: record, segmentMeters: segmentMeters),
           !fromDistance.isEmpty {
            return fromDistance
        }
        return []
    }

    /// 由 GPS 点按累计距离切段，跨段边界时按比例插值时间。
    private func splitsFromLocations(_ locations: [CLLocation], segmentMeters: Double) -> [KMSplit] {
        guard locations.count >= 2, segmentMeters > 0 else { return [] }
        var splits: [KMSplit] = []
        var segIndex = 1
        var distInSeg = 0.0
        var segStart = locations[0].timestamp

        for i in 1..<locations.count {
            let prev = locations[i - 1]
            let curr = locations[i]
            let edgeDist = curr.distance(from: prev)
            let edgeDuration = curr.timestamp.timeIntervalSince(prev.timestamp)
            guard edgeDist > 0, edgeDuration > 0 else { continue }

            var remaining = edgeDist
            var consumedOnEdge = 0.0

            while distInSeg + remaining >= segmentMeters {
                let need = segmentMeters - distInSeg
                consumedOnEdge += need
                let cross = prev.timestamp.addingTimeInterval(edgeDuration * (consumedOnEdge / edgeDist))
                let paceMin = cross.timeIntervalSince(segStart) / 60.0
                if paceMin > 0, paceMin < 120 {
                    splits.append(KMSplit(index: segIndex, paceMin: paceMin, segmentMeters: segmentMeters))
                }
                segIndex += 1
                remaining -= need
                distInSeg = 0
                segStart = cross
            }
            distInSeg += remaining
        }
        return splits
    }

    /// 游泳：用 lap 事件 + 池长累加出每 100m 配速。
    private func splitsFromSwimLaps(record: WorkoutRecord, segmentMeters: Double) async throws -> [KMSplit]? {
        guard let workout = try await fetchWorkout(id: record.id) else { return nil }
        let poolLen = record.poolLength
            ?? (workout.metadata?[HKMetadataKeyLapLength] as? HKQuantity)?.doubleValue(for: .meter())
        guard let poolLen, poolLen > 0 else { return nil }

        let laps = (workout.workoutEvents ?? [])
            .filter { $0.type == .lap }
            .sorted { $0.dateInterval.start < $1.dateInterval.start }
        guard !laps.isEmpty else { return nil }

        var splits: [KMSplit] = []
        var cumMeters = 0.0
        var nextThreshold = segmentMeters
        var segStart = record.start
        var segIndex = 1

        for lap in laps {
            let lapStart = lap.dateInterval.start
            let lapDur = max(lap.dateInterval.duration, 0.01)
            let startCum = cumMeters
            cumMeters += poolLen

            while cumMeters + 0.01 >= nextThreshold {
                let metersIntoLap = nextThreshold - startCum
                let frac = min(max(metersIntoLap / poolLen, 0), 1)
                let cross = lapStart.addingTimeInterval(lapDur * frac)
                let paceMin = cross.timeIntervalSince(segStart) / 60.0
                if paceMin > 0, paceMin < 30 {
                    splits.append(KMSplit(index: segIndex, paceMin: paceMin, segmentMeters: segmentMeters))
                }
                segIndex += 1
                segStart = cross
                nextThreshold += segmentMeters
            }
        }
        return splits
    }

    private func expectedSplitCount(for record: WorkoutRecord, segmentMeters: Double) -> Int? {
        guard segmentMeters > 0, let km = record.distanceKM, km > 0 else { return nil }
        let count = Int((km * 1000 / segmentMeters).rounded(.down))
        return count > 0 ? count : nil
    }

    private struct DistanceSamplePoint {
        let start: Date
        let end: Date
        /// 该时刻累计距离（米）；序列样本在展开时已做 running sum。
        let meters: Double
    }

    /// 用距离采样序列切段（室内跑/无 GPS 时的兜底）。
    private func splitsFromDistanceSamples(record: WorkoutRecord,
                                           segmentMeters: Double) async throws -> [KMSplit]? {
        guard let workout = try await fetchWorkout(id: record.id) else { return nil }
        let points = try await fetchWorkoutDistancePoints(record: record, workout: workout)
        guard !points.isEmpty else { return nil }

        let totalMeters = (record.distanceKM ?? 0) * 1000
        let expected = expectedSplitCount(for: record, segmentMeters: segmentMeters)
        let maxPace = record.isSwimming ? 30.0 : 120.0

        // 1) 累计距离序列：在曲线上找每公里穿越时刻（Apple Watch 室内跑常见）
        if totalMeters > 0,
           let fromCumulative = splitsFromCumulativeSeries(
                points: points,
                segStart: record.start,
                segmentMeters: segmentMeters,
                totalMeters: totalMeters,
                maxPace: maxPace
           ),
           let expected,
           fromCumulative.count == expected {
            return fromCumulative
        }

        // 2) 增量序列：逐段累加距离
        let increments = incrementalDistancePoints(from: points, totalMeters: totalMeters > 0 ? totalMeters : nil)
        if let fromIncrements = splitsFromIncrementalSeries(
            points: increments,
            segStart: record.start,
            segmentMeters: segmentMeters,
            maxPace: maxPace
        ),
           let expected,
           fromIncrements.count == expected {
            return fromIncrements
        }

        // 3) 放宽：允许 ±1 段（末段不足 1km 时）
        if totalMeters > 0,
           let fromCumulative = splitsFromCumulativeSeries(
                points: points,
                segStart: record.start,
                segmentMeters: segmentMeters,
                totalMeters: totalMeters,
                maxPace: maxPace
           ), !fromCumulative.isEmpty {
            return fromCumulative
        }
        if let fromIncrements = splitsFromIncrementalSeries(
            points: increments,
            segStart: record.start,
            segmentMeters: segmentMeters,
            maxPace: maxPace
        ), !fromIncrements.isEmpty {
            return fromIncrements
        }
        return nil
    }

    /// 累计型距离：对每个整公里阈值在采样区间内插值得穿越时刻，相邻时刻之差即单段用时。
    private func splitsFromCumulativeSeries(points: [DistanceSamplePoint],
                                            segStart: Date,
                                            segmentMeters: Double,
                                            totalMeters: Double,
                                            maxPace: Double) -> [KMSplit]? {
        let values = points.map(\.meters)
        guard isCumulativeDistanceSeries(values: values, totalMeters: totalMeters) else { return nil }

        let expected = max(1, Int((totalMeters / segmentMeters).rounded(.down)))
        var crossingTimes: [Date] = []
        var nextThreshold = segmentMeters
        var prevValue = 0.0

        for point in points {
            let value = point.meters
            let span = max(point.end.timeIntervalSince(point.start), 0.001)

            while nextThreshold <= value + 0.5, nextThreshold <= totalMeters + 0.5 {
                let range = value - prevValue
                let frac = range > 0.01 ? (nextThreshold - prevValue) / range : 1
                let cross = point.start.addingTimeInterval(span * min(max(frac, 0), 1))
                crossingTimes.append(cross)
                nextThreshold += segmentMeters
            }
            prevValue = value
        }

        guard crossingTimes.count >= expected else { return nil }

        var splits: [KMSplit] = []
        var segmentStart = segStart
        let minPace = segmentMeters <= 100 ? 0.5 : 2.0
        for (i, cross) in crossingTimes.prefix(expected).enumerated() {
            let paceMin = cross.timeIntervalSince(segmentStart) / 60.0
            guard paceMin >= minPace, paceMin <= maxPace else { return nil }
            splits.append(KMSplit(index: i + 1, paceMin: paceMin, segmentMeters: segmentMeters))
            segmentStart = cross
        }
        return splits.isEmpty ? nil : splits
    }

    /// 增量型距离：按段长累加，跨阈值时插值时间。
    private func splitsFromIncrementalSeries(points: [DistanceSamplePoint],
                                             segStart: Date,
                                             segmentMeters: Double,
                                             maxPace: Double) -> [KMSplit]? {
        guard !points.isEmpty else { return nil }

        var splits: [KMSplit] = []
        var cumMeters = 0.0
        var nextThreshold = segmentMeters
        var segmentStart = segStart
        var segIndex = 1
        let minPace = segmentMeters <= 100 ? 0.5 : 2.0

        for point in points {
            guard point.meters > 0 else { continue }
            let startCum = cumMeters
            cumMeters += point.meters
            let span = max(point.end.timeIntervalSince(point.start), 0.001)

            while cumMeters + 0.01 >= nextThreshold {
                let metersIntoSample = nextThreshold - startCum
                let frac = min(max(metersIntoSample / point.meters, 0), 1)
                let cross = point.start.addingTimeInterval(span * frac)
                let paceMin = cross.timeIntervalSince(segmentStart) / 60.0
                guard paceMin >= minPace, paceMin <= maxPace else { return nil }
                splits.append(KMSplit(index: segIndex, paceMin: paceMin, segmentMeters: segmentMeters))
                segIndex += 1
                segmentStart = cross
                nextThreshold += segmentMeters
            }
        }
        return splits.isEmpty ? nil : splits
    }

    private func isCumulativeDistanceSeries(values: [Double], totalMeters: Double) -> Bool {
        guard values.count >= 2, totalMeters > 0 else { return false }
        let monotonic = zip(values.dropLast(), values.dropFirst()).allSatisfy { $0.1 >= $0.0 - 0.01 }
        guard monotonic else { return false }
        let last = values.last ?? 0
        guard last >= totalMeters * 0.85, last <= totalMeters * 1.15 else { return false }
        let sum = values.reduce(0, +)
        return sum > totalMeters * 1.15
    }

    /// 读取与 workout 关联的距离采样；序列样本会展开为逐段增量。
    private func fetchWorkoutDistancePoints(record: WorkoutRecord,
                                            workout: HKWorkout) async throws -> [DistanceSamplePoint] {
        let typeId: HKQuantityTypeIdentifier
        switch record.activityType {
        case .swimming: typeId = .distanceSwimming
        case .cycling, .handCycling: typeId = .distanceCycling
        default: typeId = .distanceWalkingRunning
        }
        guard let qtyType = HKQuantityType.quantityType(forIdentifier: typeId) else { return [] }

        let predicate = HKQuery.predicateForObjects(from: workout)
        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: qtyType, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }

        var points: [DistanceSamplePoint] = []
        let unit = HKUnit.meter()
        var runningCumulative = 0.0
        for sample in samples {
            if sample.count > 1 {
                let series = try await expandDistanceSeries(sample: sample, unit: unit, baseCumulative: runningCumulative)
                points.append(contentsOf: series)
                runningCumulative = series.last?.meters ?? runningCumulative
            } else {
                let meters = sample.quantity.doubleValue(for: unit)
                guard meters > 0 else { continue }
                // 单点样本：严格递增视为累计打卡，否则视为增量
                let cumulative = meters > runningCumulative ? meters : runningCumulative + meters
                runningCumulative = cumulative
                points.append(DistanceSamplePoint(start: sample.startDate, end: sample.endDate, meters: cumulative))
            }
        }
        return points.sorted { $0.start < $1.start }
    }

    private func expandDistanceSeries(sample: HKQuantitySample,
                                      unit: HKUnit,
                                      baseCumulative: Double) async throws -> [DistanceSamplePoint] {
        try await withCheckedThrowingContinuation { continuation in
            var points: [DistanceSamplePoint] = []
            var prevDate: Date?
            var cumMeters = baseCumulative
            let query = HKQuantitySeriesSampleQuery(sample: sample) { _, quantity, date, done, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let quantity, let date {
                    let delta = quantity.doubleValue(for: unit)
                    if delta > 0 {
                        cumMeters += delta
                        let start = prevDate ?? sample.startDate
                        points.append(DistanceSamplePoint(start: start, end: date, meters: cumMeters))
                        prevDate = date
                    }
                }
                if done {
                    continuation.resume(returning: points)
                }
            }
            store.execute(query)
        }
    }

    /// 将累计距离序列转为逐段增量。Apple Watch 室内跑常写入「到第 N 公里为止的总距离」，直接累加会得到双倍分段。
    private func incrementalDistancePoints(from points: [DistanceSamplePoint],
                                           totalMeters: Double?) -> [DistanceSamplePoint] {
        guard points.count >= 2 else { return points }
        let values = points.map(\.meters)
        let monotonic = zip(values.dropLast(), values.dropFirst()).allSatisfy { $0.1 >= $0.0 - 0.01 }
        guard monotonic else { return points }

        let sum = values.reduce(0, +)
        let last = values.last ?? 0
        let total = max(totalMeters ?? last, last)
        // 累计型：单调递增且总和明显大于总距离，末值接近总距离
        let looksCumulative = sum > total * 1.15 && last >= total * 0.75 && last <= total * 1.15
        guard looksCumulative else { return points }

        var result: [DistanceSamplePoint] = []
        var prev = 0.0
        for point in points {
            let delta = max(0, point.meters - prev)
            if delta > 0.01 {
                result.append(DistanceSamplePoint(start: point.start, end: point.end, meters: delta))
            }
            prev = point.meters
        }
        return result.isEmpty ? points : result
    }

    // MARK: - 游泳详情（趟明细 / 组 / 划次 / SWOLF / 泳姿）

    struct SwimDetailPayload {
        var lapsCount: Int?
        var strokes: [SwimStroke: Double] = [:]
        var lapDetails: [SwimLap] = []
        var sets: [SwimSet] = []
        var totalStrokeCount: Int?
        var avgSWOLF: Double?
        var bestPacePer100m: Double?
        var sessionBests: [SwimDistanceBest] = []
    }

    /// 读取泳池游泳的丰富明细：趟、组、划次、SWOLF、泳姿分布、本场距离最佳。
    func fetchSwimDetail(for record: WorkoutRecord) async throws -> SwimDetailPayload {
        guard record.isSwimming, let workout = try await fetchWorkout(id: record.id) else {
            return SwimDetailPayload()
        }

        let events = workout.workoutEvents ?? []
        let poolLen = record.poolLength
            ?? (workout.metadata?[HKMetadataKeyLapLength] as? HKQuantity)?.doubleValue(for: .meter())
        let lapEvents = events.filter { $0.type == .lap }
            .sorted { $0.dateInterval.start < $1.dateInterval.start }
        let segmentEvents = events.filter { $0.type == .segment }
        let totalMeters = (record.distanceKM ?? 0) * 1000

        var payload = SwimDetailPayload()

        if !lapEvents.isEmpty {
            payload.lapsCount = lapEvents.count
        } else if !segmentEvents.isEmpty {
            payload.lapsCount = segmentEvents.count
        } else if let poolLen, poolLen > 0, let km = record.distanceKM {
            payload.lapsCount = Int((km * 1000 / poolLen).rounded())
        }

        payload.strokes = resolveStrokeDistribution(
            workout: workout, lapEvents: lapEvents, segmentEvents: segmentEvents, totalMeters: totalMeters)

        // 划次：swimmingStrokeCount 为 cumulative 类型，每条样本是该时段增量，总划次应对样本求和
        // （旧逻辑用 max，会把「每趟约 N 次」当成总划次，再除以趟数得到 ≈1）
        let strokeSamples = (try? await fetchQuantitySamples(
            .swimmingStrokeCount, unit: .count(), from: record.start, to: record.end)) ?? []
        payload.totalStrokeCount = resolveTotalStrokeCount(workout: workout, samples: strokeSamples)

        if let poolLen, poolLen > 0, !lapEvents.isEmpty {
            payload.lapDetails = buildSwimLaps(
                lapEvents: lapEvents, poolLen: poolLen,
                workoutStart: record.start, strokeSamples: strokeSamples)
            // 有趟明细时，优先用各趟划次之和校正总划次
            let lapStrokeSum = payload.lapDetails.compactMap(\.strokeCount).reduce(0, +)
            if lapStrokeSum > 0 {
                payload.totalStrokeCount = lapStrokeSum
            }
            payload.sets = buildSwimSets(from: payload.lapDetails, restThreshold: 12)
            payload.sessionBests = buildSessionDistanceBests(laps: payload.lapDetails)
            let paces = payload.lapDetails.compactMap(\.paceMinPer100m)
            payload.bestPacePer100m = paces.min()
            let swolfs = payload.lapDetails.compactMap(\.swolf)
            if !swolfs.isEmpty {
                payload.avgSWOLF = swolfs.reduce(0, +) / Double(swolfs.count)
            } else if let strokes = payload.totalStrokeCount, let n = payload.lapsCount, n > 0 {
                let avgLapSec = record.durationMinutes * 60 / Double(n)
                payload.avgSWOLF = avgLapSec + Double(strokes) / Double(n)
            }
        } else if let strokes = payload.totalStrokeCount, let n = payload.lapsCount, n > 0 {
            let avgLapSec = record.durationMinutes * 60 / Double(n)
            payload.avgSWOLF = avgLapSec + Double(strokes) / Double(n)
        }

        return payload
    }

    /// 总划次：优先 workout 统计 sum，其次对样本求和；仅当样本呈「全程累计单调递增」时取末值。
    private func resolveTotalStrokeCount(workout: HKWorkout, samples: [HKQuantitySample]) -> Int? {
        if let type = HKQuantityType.quantityType(forIdentifier: .swimmingStrokeCount),
           let sum = workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: .count()),
           sum > 0 {
            return Int(sum.rounded())
        }
        if #available(iOS 16.0, *),
           let legacy = workout.totalSwimmingStrokeCount?.doubleValue(for: .count()),
           legacy > 0 {
            return Int(legacy.rounded())
        }
        return totalStrokeCount(from: samples)
    }

    private func totalStrokeCount(from samples: [HKQuantitySample]) -> Int? {
        guard !samples.isEmpty else { return nil }
        let values = samples
            .sorted { $0.endDate < $1.endDate }
            .map { $0.quantity.doubleValue(for: .count()) }
        let sum = values.reduce(0, +)
        // 少数来源写成单调累计总量：末值 ≈ max，且远小于「逐段相加」
        if looksLikeRunningTotal(values), let last = values.last, last > 0 {
            return Int(last.rounded())
        }
        guard sum > 0 else { return nil }
        return Int(sum.rounded())
    }

    /// 判断是否为「按时间单调不减的累计总量」（而非每段增量）。
    private func looksLikeRunningTotal(_ values: [Double]) -> Bool {
        guard values.count >= 2 else { return false }
        var nonDecreasing = 0
        for i in 1..<values.count where values[i] + 0.5 >= values[i - 1] {
            nonDecreasing += 1
        }
        let ratio = Double(nonDecreasing) / Double(values.count - 1)
        guard ratio >= 0.9, let last = values.last, let first = values.first else { return false }
        let sum = values.reduce(0, +)
        // 累计序列：末值应接近 max，且明显小于各点之和
        return last >= values.max()! - 0.5 && last + 1 < sum * 0.6 && last >= first
    }

    private func resolveStrokeDistribution(
        workout: HKWorkout,
        lapEvents: [HKWorkoutEvent],
        segmentEvents: [HKWorkoutEvent],
        totalMeters: Double
    ) -> [SwimStroke: Double] {
        var strokes: [SwimStroke: Double] = [:]
        let activities = workout.workoutActivities
        if !activities.isEmpty, totalMeters > 0 {
            let durations = activities.map { act -> TimeInterval in
                if let end = act.endDate { return end.timeIntervalSince(act.startDate) }
                return act.duration
            }
            let totalDur = durations.reduce(0, +)
            if totalDur > 0 {
                for (act, dur) in zip(activities, durations) {
                    strokes[swimStroke(from: act.metadata), default: 0] += dur / totalDur * totalMeters
                }
            }
        }
        if strokes.isEmpty || onlyUnknown(strokes), !lapEvents.isEmpty, totalMeters > 0 {
            var byLap: [SwimStroke: Double] = [:]
            let per = totalMeters / Double(lapEvents.count)
            for lap in lapEvents { byLap[swimStroke(from: lap.metadata), default: 0] += per }
            if !onlyUnknown(byLap) { strokes = byLap }
        }
        if strokes.isEmpty || onlyUnknown(strokes), !segmentEvents.isEmpty, totalMeters > 0 {
            let totalDur = segmentEvents.reduce(0.0) { $0 + $1.dateInterval.duration }
            if totalDur > 0 {
                var bySeg: [SwimStroke: Double] = [:]
                for seg in segmentEvents {
                    bySeg[swimStroke(from: seg.metadata), default: 0] +=
                        seg.dateInterval.duration / totalDur * totalMeters
                }
                if !onlyUnknown(bySeg) { strokes = bySeg }
            }
        }
        if strokes.isEmpty || onlyUnknown(strokes), totalMeters > 0 {
            let stroke = swimStroke(from: workout.metadata)
            if stroke != .unknown { strokes = [stroke: totalMeters] }
        }
        return strokes
    }

    private func buildSwimLaps(
        lapEvents: [HKWorkoutEvent],
        poolLen: Double,
        workoutStart: Date,
        strokeSamples: [HKQuantitySample]
    ) -> [SwimLap] {
        var result: [SwimLap] = []
        var cursor = workoutStart
        let runningTotal = looksLikeRunningTotal(
            strokeSamples.sorted { $0.endDate < $1.endDate }
                .map { $0.quantity.doubleValue(for: .count()) })

        for (i, ev) in lapEvents.enumerated() {
            let interval = ev.dateInterval
            let start: Date
            let end: Date
            if interval.duration > 0.05 {
                start = interval.start
                end = interval.end
            } else {
                // 旧版零时长 lap：标记在趟结束点
                end = interval.start
                start = cursor
            }
            cursor = end
            let stroke = swimStroke(from: ev.metadata)
            let sc = strokeCount(in: strokeSamples, from: start, to: end, runningTotal: runningTotal)
            result.append(SwimLap(
                index: i + 1, start: start, end: end,
                distanceM: poolLen, stroke: stroke,
                strokeCount: sc > 0 ? sc : nil
            ))
        }
        return result
    }

    /// 区间划次：增量样本求和；若为全程累计序列则取末值差。
    private func strokeCount(
        in samples: [HKQuantitySample],
        from: Date,
        to: Date,
        runningTotal: Bool
    ) -> Int {
        guard !samples.isEmpty, to > from else { return 0 }
        if runningTotal {
            let sorted = samples.sorted { $0.endDate < $1.endDate }
            func value(at t: Date) -> Double {
                var last = 0.0
                for s in sorted {
                    if s.endDate <= t {
                        last = s.quantity.doubleValue(for: .count())
                    } else { break }
                }
                return last
            }
            let delta = value(at: to) - value(at: from)
            return delta > 0 ? Int(delta.rounded()) : 0
        }
        // 与趟时间重叠的增量样本求和（Watch 常见：每趟一条）
        let sum = samples
            .filter { $0.endDate > from && $0.startDate < to }
            .map { $0.quantity.doubleValue(for: .count()) }
            .reduce(0, +)
        return sum > 0 ? Int(sum.rounded()) : 0
    }

    /// 休息超过阈值则拆组
    private func buildSwimSets(from laps: [SwimLap], restThreshold: TimeInterval) -> [SwimSet] {
        guard !laps.isEmpty else { return [] }
        var sets: [SwimSet] = []
        var bucket: [SwimLap] = [laps[0]]
        var restBeforeNext: [TimeInterval] = []

        for i in 1..<laps.count {
            let gap = laps[i].start.timeIntervalSince(laps[i - 1].end)
            if gap >= restThreshold {
                sets.append(makeSet(index: sets.count + 1, laps: bucket, trailingRest: max(gap, 0)))
                bucket = [laps[i]]
            } else {
                restBeforeNext.append(max(gap, 0))
                bucket.append(laps[i])
            }
        }
        sets.append(makeSet(index: sets.count + 1, laps: bucket, trailingRest: 0))
        return sets
    }

    private func makeSet(index: Int, laps: [SwimLap], trailingRest: TimeInterval) -> SwimSet {
        let dist = laps.reduce(0.0) { $0 + $1.distanceM }
        let active = laps.reduce(0.0) { $0 + $1.durationSec }
        // 组内休息：相邻趟间隙之和
        var innerRest = 0.0
        for i in 1..<laps.count {
            innerRest += max(laps[i].start.timeIntervalSince(laps[i - 1].end), 0)
        }
        return SwimSet(
            index: index,
            startLap: laps.first?.index ?? index,
            endLap: laps.last?.index ?? index,
            distanceM: dist,
            activeSec: active,
            restSec: trailingRest > 0 ? trailingRest : innerRest
        )
    }

    /// 本场连续趟累计距离的最佳用时（100/200/400/800/1000/1500）
    private func buildSessionDistanceBests(laps: [SwimLap]) -> [SwimDistanceBest] {
        let targets = [100, 200, 400, 800, 1000, 1500]
        guard !laps.isEmpty else { return [] }
        var bests: [SwimDistanceBest] = []
        let pool = laps[0].distanceM
        guard pool > 0 else { return [] }

        for target in targets {
            let need = Int((Double(target) / pool).rounded())
            guard need > 0, need <= laps.count else { continue }
            var best: Double?
            for i in 0...(laps.count - need) {
                let window = laps[i..<(i + need)]
                let sec = window.reduce(0.0) { $0 + $1.durationSec }
                if best == nil || sec < best! { best = sec }
            }
            if let best {
                bests.append(SwimDistanceBest(meters: target, timeSec: best))
            }
        }
        return bests
    }

    private func fetchQuantitySamples(_ id: HKQuantityTypeIdentifier,
                                      unit: HKUnit,
                                      from start: Date,
                                      to end: Date) async throws -> [HKQuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
    }

    /// 由心率序列估算五区（始终返回 5 段）。阈值按最大心率百分比：
    /// Z1 &lt;60% · Z2 60–70% · Z3 70–80% · Z4 80–90% · Z5 ≥90%。
    /// `estimatedMaxHR` 优先用年龄估算（220−年龄），否则用本次峰值/提示值。
    static func heartRateZones(from series: [HeartRatePoint],
                               maxHRHint: Double?,
                               ageYears: Int?) -> [HRZoneSlice] {
        guard series.count >= 2 else { return [] }

        let peak = max(maxHRHint ?? 0, series.map(\.bpm).max() ?? 0)
        let ageBased = ageYears.map { Double(220 - $0) }
        // 用年龄估最大心率更稳；若无年龄则取峰值与 190 的较大者，避免区间被压扁
        let maxHR = ageBased ?? max(peak > 120 ? peak / 0.92 : 190, 170)

        // (名称, 上界比例含, 色) — 最后一区上界用很大值
        let defs: [(String, Double, String)] = [
            ("热身", 0.60, "blue"),
            ("燃脂", 0.70, "teal"),
            ("有氧耐力", 0.80, "green"),
            ("无氧耐力", 0.90, "orange"),
            ("极限", 1.50, "pink")
        ]

        // BPM 边界：Z1: < r1, Z2: r1…r2-1, …
        let edges = defs.map { Int(($0.1 * maxHR).rounded()) } // 各区上界 BPM
        // edges[0]=60%max, edges[1]=70%max, ... edges[4] unused for upper of Z5

        var seconds = Array(repeating: 0.0, count: 5)
        for i in 1..<series.count {
            let dt = max((series[i].minute - series[i - 1].minute) * 60, 0)
            let bpm = series[i - 1].bpm
            let idx: Int
            if bpm < Double(edges[0]) { idx = 0 }
            else if bpm < Double(edges[1]) { idx = 1 }
            else if bpm < Double(edges[2]) { idx = 2 }
            else if bpm < Double(edges[3]) { idx = 3 }
            else { idx = 4 }
            seconds[idx] += dt
        }
        let total = max(seconds.reduce(0, +), 0.001)

        return (0..<5).map { i in
            let low: Int
            let high: Int?
            if i == 0 {
                low = 0
                high = edges[0] - 1
            } else if i == 4 {
                low = edges[3]
                high = nil
            } else {
                low = edges[i - 1]
                high = edges[i] - 1
            }
            return HRZoneSlice(
                index: i + 1,
                name: defs[i].0,
                seconds: seconds[i],
                tintName: defs[i].2,
                fraction: seconds[i] / total,
                bpmLow: max(low, 0),
                bpmHigh: high
            )
        }
    }

    /// 泳姿分布是否全部为「未知」（用于判断某来源是否有效）。
    private func onlyUnknown(_ dict: [SwimStroke: Double]) -> Bool {
        dict.keys.allSatisfy { $0 == .unknown }
    }

    /// 从 segment metadata 解析泳姿。
    private func swimStroke(from metadata: [String: Any]?) -> SwimStroke {
        guard let raw = metadata?[HKMetadataKeySwimmingStrokeStyle] as? Int,
              let style = HKSwimmingStrokeStyle(rawValue: raw) else {
            return .unknown
        }
        switch style {
        case .freestyle:    return .freestyle
        case .breaststroke: return .breaststroke
        case .backstroke:   return .backstroke
        case .butterfly:    return .butterfly
        case .mixed:        return .mixed
        case .kickboard:    return .unknown
        case .unknown:      return .unknown
        @unknown default:   return .unknown
        }
    }

    // MARK: - 私有工具

    private func dailySums(_ id: HKQuantityTypeIdentifier,
                           unit: HKUnit,
                           from start: Date,
                           to end: Date) async throws -> [Date: Double] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [:] }
        var interval = DateComponents()
        interval.day = 1
        let cal = calendar
        let anchor = cal.startOfDay(for: start)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchor,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var map: [Date: Double] = [:]
                results?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let day = cal.startOfDay(for: statistics.startDate)
                    map[day] = statistics.sumQuantity()?.doubleValue(for: unit) ?? 0
                }
                continuation.resume(returning: map)
            }
            store.execute(query)
        }
    }

    private func latestQuantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func averageQuantity(_ id: HKQuantityTypeIdentifier,
                                 unit: HKUnit,
                                 from start: Date,
                                 to end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: statistics?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func sourceInfo(for object: HKObject?) -> (source: HealthDataSource, name: String?) {
        guard let object else { return (.appleHealth, nil) }
        let name = object.sourceRevision.source.name
        let bundle = object.sourceRevision.source.bundleIdentifier
        return (HealthDataSource.from(name: name, bundle: bundle), name)
    }
}
