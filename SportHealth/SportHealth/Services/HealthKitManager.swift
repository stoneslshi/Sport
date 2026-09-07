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
            q(.runningSpeed),
            q(.runningStrideLength),
            q(.runningVerticalOscillation),
            q(.runningGroundContactTime),
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
    /// 含主睡眠分期时间轴、前一日白天短睡、以及昨夜生命体征（呼吸/血氧/腕温）。
    func fetchSleepNights(nights: Int) async throws -> [SleepNight] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let now = Date()
        let end = now
        // 多取两天余量，便于挂载前一日白天短睡
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

        let wristFrom = calendar.date(byAdding: .day, value: -WristTemp.lookbackDays,
                                      to: calendar.startOfDay(for: now)) ?? start
        async let wristSamples = fetchQuantitySamples(.appleSleepingWristTemperature,
                                                      unit: WristTemp.celsius,
                                                      from: wristFrom, to: now)

        // 为每一晚补生命体征（主睡眠窗内均值）
        for i in result.indices {
            result[i].vitals = await fetchSleepVitals(from: result[i].inBed, to: result[i].wake)
        }
        if let samples = try? await wristSamples {
            applyWristTemperature(samples: samples, to: &result)
        }
        return result
    }

    /// 主睡眠窗内的呼吸频率 / 血氧；体温仅作无腕温时的兜底。
    /// 腕温由 `applyWristTemperature` 单独处理：HealthKit 存的是整夜绝对值，需相对基线后才展示偏差。
    func fetchSleepVitals(from start: Date, to end: Date) async -> SleepVitals {
        var vitals = SleepVitals()
        async let resp = averageQuantity(.respiratoryRate,
                                         unit: HKUnit.count().unitDivided(by: .minute()),
                                         from: start, to: end)
        async let spo2 = averageQuantity(.oxygenSaturation, unit: .percent(), from: start, to: end)
        async let body = averageQuantity(.bodyTemperature,
                                         unit: .degreeCelsius(), from: start, to: end)
        vitals.respiratoryRate = try? await resp
        vitals.oxygenSaturation = try? await spo2
        if let absTemp = try? await body {
            vitals.wristTempAbsolute = absTemp
        }
        return vitals
    }

    /// Apple Watch 腕温：样本为整夜绝对值（约 32–36°C），系统健康 App 再减个人基线后展示。
    private enum WristTemp {
        static let celsius = HKUnit.degreeCelsius()
        /// 腕部皮肤温度生理区间；落在此区间视为绝对值，否则视为已是偏差
        static let absoluteRange = 20.0...45.0
        /// 对齐系统健康 App：约 5 晚建立基线
        static let baselineMinNights = 5
        static let lookbackDays = 60
        /// 偏差超过此阈值视为计算异常，回退到绝对值
        static let maxPlausibleDelta = 5.0
    }

    private func isAbsoluteWristTemperature(_ celsius: Double) -> Bool {
        WristTemp.absoluteRange.contains(celsius)
    }

    /// 按起床日把腕温样本聚成每晚一个值。
    private func nightlyWristTemperatures(from samples: [HKQuantitySample]) -> [Date: Double] {
        var grouped: [Date: [Double]] = [:]
        for s in samples {
            let value = s.quantity.doubleValue(for: WristTemp.celsius)
            guard isAbsoluteWristTemperature(value) else { continue }
            grouped[attributionDay(for: s.endDate), default: []].append(value)
        }
        return grouped.mapValues { $0.reduce(0, +) / Double($0.count) }
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// 睡眠窗与样本时间重叠时取均值，并返回用到的归属日（从基线池里剔除）。
    private func overlappingWristValue(night: SleepNight,
                                       samples: [HKQuantitySample]) -> (value: Double, days: Set<Date>)? {
        let pad: TimeInterval = 2 * 3600
        let lo = night.inBed.addingTimeInterval(-pad)
        let hi = night.wake.addingTimeInterval(pad)
        var values: [Double] = []
        var days: Set<Date> = []
        for s in samples {
            guard s.startDate < hi, s.endDate > lo else { continue }
            let value = s.quantity.doubleValue(for: WristTemp.celsius)
            guard isAbsoluteWristTemperature(value) else { continue }
            values.append(value)
            days.insert(attributionDay(for: s.endDate))
        }
        guard !values.isEmpty else { return nil }
        return (values.reduce(0, +) / Double(values.count), days)
    }

    private func applyWristTemperature(samples: [HKQuantitySample], to nights: inout [SleepNight]) {
        let nightly = nightlyWristTemperatures(from: samples)
        var alreadyDelta: [Date: Double] = [:]
        for s in samples {
            let value = s.quantity.doubleValue(for: WristTemp.celsius)
            if !isAbsoluteWristTemperature(value) {
                alreadyDelta[attributionDay(for: s.endDate)] = value
            }
        }

        for i in nights.indices {
            let day = nights[i].date
            if let delta = alreadyDelta[day], abs(delta) <= WristTemp.maxPlausibleDelta {
                nights[i].vitals.wristTempDelta = delta
                nights[i].vitals.wristTempAbsolute = nil
                nights[i].vitals.wristTempNeedsBaseline = false
                continue
            }

            let matched: (value: Double, exclude: Set<Date>)?
            if let value = nightly[day] {
                matched = (value, [day])
            } else if let overlap = overlappingWristValue(night: nights[i], samples: samples) {
                matched = (overlap.value, overlap.days)
            } else {
                matched = nil
            }
            guard let match = matched else { continue }

            let others = nightly.filter { !match.exclude.contains($0.key) }.map(\.value)
            if others.count >= WristTemp.baselineMinNights,
               let baseline = median(others) {
                let delta = match.value - baseline
                if abs(delta) <= WristTemp.maxPlausibleDelta {
                    nights[i].vitals.wristTempDelta = delta
                    nights[i].vitals.wristTempAbsolute = nil
                    nights[i].vitals.wristTempNeedsBaseline = false
                    continue
                }
            }
            nights[i].vitals.wristTempAbsolute = match.value
            nights[i].vitals.wristTempDelta = nil
            nights[i].vitals.wristTempNeedsBaseline = true
        }
    }

    /// 把睡眠分段样本按「起床日」归组并累计各阶段时长。
    /// 口径对齐系统「健康」App 的过夜主睡眠：
    /// - 有手表分期时，主睡眠窗只用手表，避免 iPhone 睡眠日程把起床拖到闹钟结束
    /// - 按「睡着间隙」拆段，不用清醒样本把两段粘在一起
    /// - 起床 = 最后一次睡着结束；白天短睡才挂午睡，傍晚假睡不展示
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

            let primary = primarySleepSamples(in: sorted)
            let sessions = clusterSleepSessions(primary, maxAsleepGap: 45 * 60)
            guard let main = pickMainSleepSession(sessions) else { continue }
            sessionMap[day] = (main, sessions)

            let staged = preferredStagedSamples(in: main)
            let window = staged.isEmpty ? main : staged
            let asleepSamples = window.filter { stage(for: $0) != .awake }
            guard let inBed = asleepSamples.map(\.startDate).min(),
                  let wake = asleepSamples.map(\.endDate).max() else { continue }

            var night = SleepNight(date: day, inBed: inBed, wake: wake)
            night.asleepMin = mergedMinutes(asleepSamples.map { ($0.startDate, $0.endDate) })

            for stg in SleepStage.allCases {
                let intervals = window
                    .filter { stage(for: $0) == stg }
                    .map { ($0.startDate, $0.endDate) }
                night.setMinutes(mergedMinutes(intervals), of: stg)
            }

            night.segments = buildSegments(from: window).compactMap { seg in
                let start = max(seg.start, inBed)
                let end = min(seg.end, wake)
                guard end > start else { return nil }
                return SleepStageSegment(stage: seg.stage, start: start, end: end)
            }
            nightsResult.append(night)
        }

        nightsResult.sort { $0.date < $1.date }

        // 前一日白天短睡挂到次日，不把傍晚沙发假睡标成午睡
        for i in nightsResult.indices {
            let day = nightsResult[i].date
            guard let prevDay = calendar.date(byAdding: .day, value: -1, to: day),
                  let prev = sessionMap[prevDay] else { continue }
            let daytimeNaps = prev.all.compactMap { session -> SleepNap? in
                if sessionsEqual(session, prev.main) { return nil }
                guard let start = session.map(\.startDate).min(),
                      let end = session.map(\.endDate).max() else { return nil }
                let hour = calendar.component(.hour, from: start)
                guard hour >= 10, hour < 17 else { return nil }
                let asleep = asleepMinutes(in: session)
                guard asleep >= 10, asleep <= 180 else { return nil }
                return SleepNap(start: start, end: end, asleepMin: asleep)
            }
            nightsResult[i].nap = daytimeNaps.max(by: { $0.asleepMin < $1.asleepMin })
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

    /// 有手表分期时只用手表，避免 iPhone 睡眠日程（常写到闹钟点）把过夜窗拉长。
    private func primarySleepSamples(in samples: [HKCategorySample]) -> [HKCategorySample] {
        let watch = samples.filter { isAppleWatchSource($0) }
        return hasStagedSleep(watch) ? watch : samples
    }

    private func hasStagedSleep(_ samples: [HKCategorySample]) -> Bool {
        samples.contains { sample in
            guard let v = HKCategoryValueSleepAnalysis(rawValue: sample.value) else { return false }
            switch v {
            case .asleepDeep, .asleepCore, .asleepREM: return true
            default: return false
            }
        }
    }

    /// 按睡着样本拆段：两段睡着之间超过 maxAsleepGap 则视为另一段。
    /// 清醒样本只挂到相邻睡着窗上，避免用「起床后仍清醒」把午睡粘进主睡眠。
    private func clusterSleepSessions(_ samples: [HKCategorySample],
                                      maxAsleepGap: TimeInterval) -> [[HKCategorySample]] {
        let asleep = samples.filter { stage(for: $0) != .awake }
            .sorted { $0.startDate < $1.startDate }
        guard !asleep.isEmpty else { return [] }

        var asleepGroups: [[HKCategorySample]] = []
        var current: [HKCategorySample] = [asleep[0]]
        for s in asleep.dropFirst() {
            let sessionEnd = current.map(\.endDate).max() ?? current.last!.endDate
            if s.startDate.timeIntervalSince(sessionEnd) > maxAsleepGap {
                asleepGroups.append(current)
                current = [s]
            } else {
                current.append(s)
            }
        }
        asleepGroups.append(current)

        let awakes = samples.filter { stage(for: $0) == .awake }
        let pad: TimeInterval = 10 * 60
        return asleepGroups.map { group in
            guard let lo = group.map(\.startDate).min(),
                  let hi = group.map(\.endDate).max() else { return group }
            let related = awakes.filter {
                $0.endDate > lo.addingTimeInterval(-pad) && $0.startDate < hi.addingTimeInterval(pad)
            }
            return (group + related).sorted { $0.startDate < $1.startDate }
        }
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

            return WorkoutRecord(
                id: workout.uuid,
                activityType: workout.workoutActivityType,
                start: workout.startDate,
                end: workout.endDate,
                durationMinutes: workout.duration / 60,
                caloriesKcal: energy,
                distanceKM: distanceMeters.map { $0 / 1000 },
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

    /// 一次运动的 GPS 轨迹打包：坐标 + 海拔 + 配速曲线。
    struct WorkoutRoutePayload {
        var coordinates: [CLLocationCoordinate2D] = []
        var elevationSeries: [ElevationPoint] = []
        var paceSeries: [WorkoutMetricPoint] = []
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
            elevationSeries: elevationSeries(from: locations, workoutStart: record.start),
            paceSeries: paceSeries(from: locations, workoutStart: record.start)
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

    /// 由 GPS 点生成滚动配速曲线（分钟/公里）。
    private func paceSeries(from locations: [CLLocation], workoutStart: Date) -> [WorkoutMetricPoint] {
        let valid = locations.filter {
            $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < 40 && $0.timestamp >= workoutStart
        }
        guard valid.count >= 3 else { return [] }

        var points: [WorkoutMetricPoint] = []
        var windowStart = 0
        for i in 1..<valid.count {
            let curr = valid[i]
            while windowStart < i - 1 {
                let dt = curr.timestamp.timeIntervalSince(valid[windowStart].timestamp)
                if dt <= 18 { break }
                windowStart += 1
            }
            var dist = 0.0
            for j in windowStart..<i {
                dist += valid[j + 1].distance(from: valid[j])
            }
            let dt = curr.timestamp.timeIntervalSince(valid[windowStart].timestamp)
            guard dist > 8, dt > 5 else { continue }
            let paceMin = (dt / 60.0) / (dist / 1000.0)
            guard paceMin >= 2.5, paceMin <= 18 else { continue }
            points.append(WorkoutMetricPoint(
                minute: max(0, curr.timestamp.timeIntervalSince(workoutStart) / 60),
                value: paceMin
            ))
        }
        return downsampleMetricPoints(points, limit: 80)
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
    /// 单段用时只计移动时间，暂停 / 自动暂停不计入配速。
    func fetchSplits(for record: WorkoutRecord) async throws -> [KMSplit] {
        let segmentMeters: Double = record.isSwimming ? 100 : 1000
        let workout = try await fetchWorkout(id: record.id)
        let pauses = workout.map { pauseIntervals(from: $0) } ?? []

        if record.isSwimming, let workout {
            if let fromLaps = splitsFromSwimLaps(record: record, workout: workout,
                                                 segmentMeters: segmentMeters, pauses: pauses),
               !fromLaps.isEmpty {
                return fromLaps
            }
        }

        let locations = try await fetchRouteLocations(for: record)
        if locations.count >= 2 {
            let fromRoute = splitsFromLocations(locations,
                                                segmentMeters: segmentMeters,
                                                pauses: pauses,
                                                workoutStart: record.start)
            if !fromRoute.isEmpty { return fromRoute }
        }

        if let fromDistance = try await splitsFromDistanceSamples(record: record,
                                                                  segmentMeters: segmentMeters,
                                                                  pauses: pauses),
           !fromDistance.isEmpty {
            return fromDistance
        }
        return []
    }

    /// 手动暂停、自动暂停，以及相邻 workout activity 之间的空隙。
    private func pauseIntervals(from workout: HKWorkout) -> [DateInterval] {
        var raw: [DateInterval] = []
        let events = (workout.workoutEvents ?? [])
            .sorted { $0.dateInterval.start < $1.dateInterval.start }
        var openPause: Date?

        for event in events {
            switch event.type {
            case .pause, .motionPaused:
                if event.dateInterval.duration > 1 {
                    raw.append(event.dateInterval)
                    openPause = nil
                } else {
                    openPause = event.dateInterval.start
                }
            case .resume, .motionResumed:
                if let start = openPause, event.dateInterval.start > start {
                    raw.append(DateInterval(start: start, end: event.dateInterval.start))
                }
                openPause = nil
            default:
                break
            }
        }
        if let start = openPause, workout.endDate > start {
            raw.append(DateInterval(start: start, end: workout.endDate))
        }

        let activities = workout.workoutActivities.sorted { $0.startDate < $1.startDate }
        if activities.count >= 2 {
            for i in 1..<activities.count {
                let prev = activities[i - 1]
                let prevEnd = prev.endDate ?? prev.startDate.addingTimeInterval(max(prev.duration, 0))
                let nextStart = activities[i].startDate
                if nextStart.timeIntervalSince(prevEnd) > 1 {
                    raw.append(DateInterval(start: prevEnd, end: nextStart))
                }
            }
        }

        return mergedIntervals(raw)
    }

    private func mergedIntervals(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for iv in sorted {
            if let last = merged.last, last.end >= iv.start {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, iv.end))
            } else {
                merged.append(iv)
            }
        }
        return merged
    }

    /// 墙钟区间扣除暂停后的移动时长。
    private func activeDuration(from start: Date, to end: Date, pauses: [DateInterval]) -> TimeInterval {
        let wall = end.timeIntervalSince(start)
        guard wall > 0 else { return 0 }
        guard !pauses.isEmpty else { return wall }
        let window = DateInterval(start: start, end: end)
        var paused: TimeInterval = 0
        for pause in pauses {
            if let overlap = window.intersection(with: pause) {
                paused += overlap.duration
            }
        }
        return max(wall - paused, 0)
    }

    /// 由 GPS 点按累计距离切段；跨段时按移动时长比例分摊，暂停不计入配速。
    private func splitsFromLocations(_ locations: [CLLocation],
                                     segmentMeters: Double,
                                     pauses: [DateInterval],
                                     workoutStart: Date) -> [KMSplit] {
        guard locations.count >= 2, segmentMeters > 0 else { return [] }
        var splits: [KMSplit] = []
        var segIndex = 1
        var distInSeg = 0.0
        var movingSec = 0.0
        var splitStartTime = locations[0].timestamp
        var splitStartAlt: Double? = locations[0].verticalAccuracy >= 0 ? locations[0].altitude : nil

        func appendSplit(endTime: Date, endAlt: Double?, meters: Double, moving: Double) {
            guard meters > 0, moving > 0 else { return }
            let unit = segmentMeters <= 100 ? 100.0 : 1000.0
            let paceMin = (moving / 60.0) / (meters / unit)
            let maxPace = segmentMeters <= 100 ? 30.0 : 120.0
            guard paceMin > 0, paceMin < maxPace else { return }
            let elev: Double?
            if let startAlt = splitStartAlt, let endAlt, endAlt.isFinite, startAlt.isFinite {
                elev = endAlt - startAlt
            } else {
                elev = nil
            }
            splits.append(KMSplit(
                index: segIndex,
                paceMin: paceMin,
                segmentMeters: meters,
                startMinute: max(0, splitStartTime.timeIntervalSince(workoutStart) / 60),
                elevationDelta: elev
            ))
            segIndex += 1
            splitStartTime = endTime
            splitStartAlt = endAlt
        }

        for i in 1..<locations.count {
            let prev = locations[i - 1]
            let curr = locations[i]
            let edgeDist = curr.distance(from: prev)
            let wall = curr.timestamp.timeIntervalSince(prev.timestamp)
            guard edgeDist > 0, wall > 0 else { continue }

            var remainingDist = edgeDist
            var remainingSec = activeDuration(from: prev.timestamp, to: curr.timestamp, pauses: pauses)
            // 无暂停事件时，长时间几乎不动的边视为停留
            if remainingSec > 8, edgeDist / remainingSec < 0.3 {
                remainingSec = 0
            }

            while distInSeg + remainingDist >= segmentMeters, remainingDist > 0 {
                let need = segmentMeters - distInSeg
                let frac = need / remainingDist
                movingSec += remainingSec * frac
                let cross = prev.timestamp.addingTimeInterval(wall * (1 - remainingDist / edgeDist + need / edgeDist))
                let endAlt = curr.verticalAccuracy >= 0 ? curr.altitude : splitStartAlt
                appendSplit(endTime: cross, endAlt: endAlt, meters: segmentMeters, moving: movingSec)
                remainingDist -= need
                remainingSec *= (1 - frac)
                distInSeg = 0
                movingSec = 0
            }
            distInSeg += remainingDist
            movingSec += remainingSec
        }
        // 末段不足 1km 也保留，便于对照 Keep 式分段表
        if distInSeg >= 50, movingSec > 0 {
            let last = locations.last
            appendSplit(
                endTime: last?.timestamp ?? splitStartTime.addingTimeInterval(movingSec),
                endAlt: (last?.verticalAccuracy ?? -1) >= 0 ? last?.altitude : splitStartAlt,
                meters: distInSeg,
                moving: movingSec
            )
        }
        return splits
    }

    /// 游泳：用 lap 事件 + 池长累加出每 100m 配速。
    private func splitsFromSwimLaps(record: WorkoutRecord,
                                    workout: HKWorkout,
                                    segmentMeters: Double,
                                    pauses: [DateInterval]) -> [KMSplit]? {
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
                let paceMin = activeDuration(from: segStart, to: cross, pauses: pauses) / 60.0
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
                                           segmentMeters: Double,
                                           pauses: [DateInterval]) async throws -> [KMSplit]? {
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
                maxPace: maxPace,
                pauses: pauses
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
            maxPace: maxPace,
            pauses: pauses
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
                maxPace: maxPace,
                pauses: pauses
           ), !fromCumulative.isEmpty {
            return fromCumulative
        }
        if let fromIncrements = splitsFromIncrementalSeries(
            points: increments,
            segStart: record.start,
            segmentMeters: segmentMeters,
            maxPace: maxPace,
            pauses: pauses
        ), !fromIncrements.isEmpty {
            return fromIncrements
        }
        return nil
    }

    /// 累计型距离：对每个整公里阈值在采样区间内插值得穿越时刻；配速用扣除暂停后的移动时长。
    private func splitsFromCumulativeSeries(points: [DistanceSamplePoint],
                                            segStart: Date,
                                            segmentMeters: Double,
                                            totalMeters: Double,
                                            maxPace: Double,
                                            pauses: [DateInterval]) -> [KMSplit]? {
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
            let paceMin = activeDuration(from: segmentStart, to: cross, pauses: pauses) / 60.0
            guard paceMin >= minPace, paceMin <= maxPace else { return nil }
            splits.append(KMSplit(
                index: i + 1,
                paceMin: paceMin,
                segmentMeters: segmentMeters,
                startMinute: max(0, segmentStart.timeIntervalSince(segStart) / 60)
            ))
            segmentStart = cross
        }
        return splits.isEmpty ? nil : splits
    }

    /// 增量型距离：按段长累加，跨阈值时插值时间；配速扣除暂停。
    private func splitsFromIncrementalSeries(points: [DistanceSamplePoint],
                                             segStart: Date,
                                             segmentMeters: Double,
                                             maxPace: Double,
                                             pauses: [DateInterval]) -> [KMSplit]? {
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
                let paceMin = activeDuration(from: segmentStart, to: cross, pauses: pauses) / 60.0
                guard paceMin >= minPace, paceMin <= maxPace else { return nil }
                splits.append(KMSplit(
                    index: segIndex,
                    paceMin: paceMin,
                    segmentMeters: segmentMeters,
                    startMinute: max(0, segmentStart.timeIntervalSince(segStart) / 60)
                ))
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

    /// 跑步动态：步幅 / 步频 / 垂直振幅 / 触地时间。
    func fetchRunningMetrics(for record: WorkoutRecord) async throws -> RunningMetrics {
        guard record.isRunning else { return RunningMetrics() }
        let workout = try await fetchWorkout(id: record.id)
        let start = record.start
        let end = record.end

        async let strideSamples = metricSeries(.runningStrideLength, unit: .meter(), from: start, to: end,
                                               minValue: 0.4, maxValue: 2.5)
        async let speedSamples = metricSeries(.runningSpeed, unit: .meter().unitDivided(by: .second()),
                                              from: start, to: end, minValue: 0.8, maxValue: 8)
        async let voSamples = metricSeries(.runningVerticalOscillation, unit: .meter(),
                                           from: start, to: end, transform: { $0 * 100 },
                                           minValue: 3, maxValue: 25)
        async let gctSamples = metricSeries(.runningGroundContactTime, unit: .secondUnit(with: .milli),
                                            from: start, to: end, minValue: 120, maxValue: 450)
        async let stepCadence = cadenceSeriesFromSteps(from: start, to: end)

        let (stride, speed, vo, gct, cadenceFromSteps) = try await (strideSamples, speedSamples, voSamples, gctSamples, stepCadence)
        var cadence = cadenceFromSteps
        if cadence.isEmpty, !speed.isEmpty, !stride.isEmpty {
            cadence = cadenceFromSpeed(speed, stride: stride)
        }

        var metrics = RunningMetrics(
            strideSeries: stride,
            cadenceSeries: cadence,
            verticalOscSeries: vo,
            groundContactSeries: gct
        )

        if let workout {
            let (avgS, maxS) = workoutQuantityStats(workout, id: .runningStrideLength, unit: .meter())
            metrics.avgStrideM = avgS ?? average(of: stride)
            metrics.maxStrideM = maxS ?? stride.map(\.value).max()

            let (avgVO, maxVO) = workoutQuantityStats(workout, id: .runningVerticalOscillation, unit: .meter())
            metrics.avgVerticalOscCM = avgVO.map { $0 * 100 } ?? average(of: vo)
            metrics.maxVerticalOscCM = maxVO.map { $0 * 100 } ?? vo.map(\.value).max()

            let (avgG, maxG) = workoutQuantityStats(workout, id: .runningGroundContactTime, unit: .secondUnit(with: .milli))
            metrics.avgGroundContactMS = avgG ?? average(of: gct)
            metrics.maxGroundContactMS = maxG ?? gct.map(\.value).max()

            if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount),
               let steps = workout.statistics(for: stepType)?.sumQuantity()?.doubleValue(for: .count()),
               record.durationMinutes > 0.5 {
                metrics.avgCadence = steps / record.durationMinutes
            }
        }

        if metrics.avgStrideM == nil { metrics.avgStrideM = average(of: stride) }
        if metrics.maxStrideM == nil { metrics.maxStrideM = stride.map(\.value).max() }
        if metrics.avgCadence == nil { metrics.avgCadence = average(of: cadence) }
        metrics.maxCadence = cadence.map(\.value).max()
        if metrics.avgVerticalOscCM == nil { metrics.avgVerticalOscCM = average(of: vo) }
        if metrics.maxVerticalOscCM == nil { metrics.maxVerticalOscCM = vo.map(\.value).max() }
        if metrics.avgGroundContactMS == nil { metrics.avgGroundContactMS = average(of: gct) }
        if metrics.maxGroundContactMS == nil { metrics.maxGroundContactMS = gct.map(\.value).max() }

        return metrics
    }

    /// 手表跑步速度转配速曲线；样本足够时优先于 GPS 滚动配速。
    func fetchWatchPaceSeries(for record: WorkoutRecord) async throws -> [WorkoutMetricPoint] {
        guard record.isRunning else { return [] }
        return try await metricSeries(
            .runningSpeed,
            unit: .meter().unitDivided(by: .second()),
            from: record.start,
            to: record.end,
            transform: { mps in
                guard mps > 0.5 else { return 0 }
                return (1000 / mps) / 60
            },
            minValue: 2.5,
            maxValue: 18
        )
    }

    /// 给分段补上区间内心率 / 步频均值。
    static func annotateSplits(_ splits: [KMSplit],
                               heartRate: [HeartRatePoint],
                               cadence: [WorkoutMetricPoint]) -> [KMSplit] {
        guard !splits.isEmpty else { return splits }
        var cursor = 0.0
        return splits.map { split in
            var next = split
            let start = split.startMinute ?? cursor
            let end = start + split.durationMinutes
            if next.startMinute == nil { next.startMinute = start }
            next.avgHR = averageHR(heartRate, from: start, to: end)
            next.avgCadence = averageMetric(cadence, from: start, to: end)
            cursor = end
            return next
        }
    }

    /// 配速五区：相对本次平均配速。
    static func paceZones(from series: [WorkoutMetricPoint], averagePace: Double?) -> [PaceZoneSlice] {
        guard series.count >= 2, let avg = averagePace, avg > 0 else { return [] }
        let defs: [(String, Double, String)] = [
            ("轻松", 1.12, "blue"),
            ("稳态", 1.02, "teal"),
            ("节奏", 0.94, "green"),
            ("间歇", 0.86, "orange"),
            ("冲刺", 0, "red")
        ]
        var seconds = Array(repeating: 0.0, count: 5)
        for i in 1..<series.count {
            let dt = max((series[i].minute - series[i - 1].minute) * 60, 0)
            let pace = series[i - 1].value
            let ratio = pace / avg
            let idx: Int
            if ratio >= defs[0].1 { idx = 0 }
            else if ratio >= defs[1].1 { idx = 1 }
            else if ratio >= defs[2].1 { idx = 2 }
            else if ratio >= defs[3].1 { idx = 3 }
            else { idx = 4 }
            seconds[idx] += dt
        }
        let total = max(seconds.reduce(0, +), 0.001)
        return (0..<5).map { i in
            PaceZoneSlice(
                index: i + 1,
                name: defs[i].0,
                seconds: seconds[i],
                tintName: defs[i].2,
                fraction: seconds[i] / total
            )
        }
    }

    private func metricSeries(_ id: HKQuantityTypeIdentifier,
                              unit: HKUnit,
                              from start: Date,
                              to end: Date,
                              transform: (Double) -> Double = { $0 },
                              minValue: Double? = nil,
                              maxValue: Double? = nil) async throws -> [WorkoutMetricPoint] {
        let samples = try await fetchQuantitySamples(id, unit: unit, from: start, to: end)
        var points: [WorkoutMetricPoint] = []
        points.reserveCapacity(samples.count)
        for sample in samples {
            let raw = sample.quantity.doubleValue(for: unit)
            let value = transform(raw)
            if let minValue, value < minValue { continue }
            if let maxValue, value > maxValue { continue }
            points.append(WorkoutMetricPoint(
                minute: max(0, sample.startDate.timeIntervalSince(start) / 60),
                value: value
            ))
        }
        return downsampleMetricPoints(points, limit: 80)
    }

    private func cadenceSeriesFromSteps(from start: Date, to end: Date) async throws -> [WorkoutMetricPoint] {
        let samples = try await fetchQuantitySamples(.stepCount, unit: .count(), from: start, to: end)
        guard samples.count >= 2 else { return [] }

        var points: [WorkoutMetricPoint] = []
        var windowStart = 0
        var cum = Array(repeating: 0.0, count: samples.count)
        var running = 0.0
        for (i, sample) in samples.enumerated() {
            running += sample.quantity.doubleValue(for: .count())
            cum[i] = running
        }

        for i in 1..<samples.count {
            let curr = samples[i]
            while windowStart < i - 1 {
                let dt = curr.endDate.timeIntervalSince(samples[windowStart].startDate)
                if dt <= 25 { break }
                windowStart += 1
            }
            let dt = curr.endDate.timeIntervalSince(samples[windowStart].startDate)
            let steps = cum[i] - (windowStart > 0 ? cum[windowStart - 1] : 0)
            guard dt > 8, steps > 4 else { continue }
            let spm = steps / dt * 60
            guard spm >= 90, spm <= 230 else { continue }
            points.append(WorkoutMetricPoint(
                minute: max(0, curr.endDate.timeIntervalSince(start) / 60),
                value: spm
            ))
        }
        return downsampleMetricPoints(points, limit: 80)
    }

    private func cadenceFromSpeed(_ speedMps: [WorkoutMetricPoint],
                                  stride: [WorkoutMetricPoint]) -> [WorkoutMetricPoint] {
        guard !speedMps.isEmpty, !stride.isEmpty else { return [] }
        var points: [WorkoutMetricPoint] = []
        var j = 0
        for s in speedMps {
            while j + 1 < stride.count,
                  abs(stride[j + 1].minute - s.minute) < abs(stride[j].minute - s.minute) {
                j += 1
            }
            let strideM = stride[j].value
            guard strideM > 0.4 else { continue }
            let spm = s.value / strideM * 60
            guard spm >= 90, spm <= 230 else { continue }
            points.append(WorkoutMetricPoint(minute: s.minute, value: spm))
        }
        return downsampleMetricPoints(points, limit: 80)
    }

    private func workoutQuantityStats(_ workout: HKWorkout,
                                      id: HKQuantityTypeIdentifier,
                                      unit: HKUnit) -> (Double?, Double?) {
        guard let type = HKQuantityType.quantityType(forIdentifier: id),
              let stats = workout.statistics(for: type) else { return (nil, nil) }
        return (
            stats.averageQuantity()?.doubleValue(for: unit),
            stats.maximumQuantity()?.doubleValue(for: unit)
        )
    }

    private func downsampleMetricPoints(_ points: [WorkoutMetricPoint], limit: Int) -> [WorkoutMetricPoint] {
        guard points.count > limit, limit > 1 else { return points }
        let step = max(1, points.count / limit)
        var sampled = points.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
        if let last = points.last, sampled.last?.minute != last.minute {
            sampled.append(last)
        }
        return sampled
    }

    private func average(of points: [WorkoutMetricPoint]) -> Double? {
        guard !points.isEmpty else { return nil }
        return points.map(\.value).reduce(0, +) / Double(points.count)
    }

    private static func averageHR(_ series: [HeartRatePoint], from start: Double, to end: Double) -> Double? {
        let slice = series.filter { $0.minute >= start && $0.minute < max(end, start + 0.05) }
        guard !slice.isEmpty else { return nil }
        return slice.map(\.bpm).reduce(0, +) / Double(slice.count)
    }

    private static func averageMetric(_ series: [WorkoutMetricPoint], from start: Double, to end: Double) -> Double? {
        let slice = series.filter { $0.minute >= start && $0.minute < max(end, start + 0.05) }
        guard !slice.isEmpty else { return nil }
        return slice.map(\.value).reduce(0, +) / Double(slice.count)
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
            ("热身", 0.60, "green"),
            ("燃脂", 0.70, "yellow"),
            ("有氧耐力", 0.80, "orange"),
            ("无氧耐力", 0.90, "red"),
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
}
