import SwiftUI
import Charts
import MapKit

/// 跑步 / 步行 / 骑行 / 徒步详情：对齐确认的交互稿
/// 地图 Hero → 距离大数字 → 天气 → 心率 → 配速 → 分段 → 跑姿 → 海拔。
struct RunStyleDetailStack: View {
    let record: WorkoutRecord
    let detailed: WorkoutRecord
    let tint: Color
    var peerAvgPace: Double?
    var onMapTap: () -> Void

    @State private var showAllSplits = false
    @State private var presentedGuide: MetricGuideContent?

    var body: some View {
        VStack(spacing: 16) {
            if detailed.hasRoute {
                heroMap
            }
            runHero
            if detailed.hasWeatherInfo { weatherRow }

            if !detailed.heartRateSeries.isEmpty {
                heartRateSection
            }
            if !detailed.paceSeries.isEmpty || record.avgPaceMinPerKM != nil {
                paceSection
            }
            if !detailed.splits.isEmpty, detailed.splits.first?.isPer100m != true {
                splitsTable
            }
            if detailed.runningMetrics.hasStride { strideCard }
            if detailed.runningMetrics.hasCadence { cadenceCard }
            if detailed.runningMetrics.hasVerticalOsc { verticalOscCard }
            if detailed.runningMetrics.hasGroundContact { groundContactCard }
            if showElevationCard { elevationSection }
        }
        .sheet(item: $presentedGuide) { content in
            MetricGuideSheet(content: content)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var dyn: RunningMetrics { detailed.runningMetrics }

    // MARK: - 地图 Hero

    private var heroMap: some View {
        Button(action: onMapTap) {
            ZStack(alignment: .bottomTrailing) {
                RouteMapView(coordinates: detailed.routeCoordinates, tint: tint)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .allowsHitTesting(false)

                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                    Text("动态回放")
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(12)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 距离 Hero

    private var runHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.activityType.displayName)
                        .font(.title3.bold())
                    Text("\(record.start.mdTimeCN)  –  \(record.end.timeShort)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: record.activityType.symbolName)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.15), in: Circle())
            }

            if let km = record.distanceKM, km > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(km < 1 ? "\(Int(km * 1000))" : String(format: "%.2f", km))
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                    Text(km < 1 ? "米" : "公里")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint.opacity(0.8))
                }
            }

            HStack(spacing: 0) {
                heroStat("时长", record.durationMinutes.minutesAsHMS)
                Divider().frame(height: 36)
                heroStat("平均配速", record.avgPaceMinPerKM.map(paceText) ?? "—")
                Divider().frame(height: 36)
                heroStat("消耗", "\(Int(record.caloriesKcal)) 千卡")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [tint.opacity(0.16), Color(.secondarySystemBackground)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20)
        )
    }

    private func heroStat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline.monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var weatherRow: some View {
        HStack(spacing: 20) {
            if let temp = detailed.weatherTemperatureC {
                Label("\(Int(temp.rounded()))°", systemImage: "thermometer.medium")
            }
            if let humidity = detailed.weatherHumidityPercent {
                Label("湿度 \(Int(humidity.rounded()))%", systemImage: "humidity.fill")
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 心率

    private var heartRateSection: some View {
        let avg = detailed.avgHR ?? record.avgHR
        let maxHR = detailed.maxHR ?? record.maxHR
        let domain = hrDomain
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("心率", icon: "heart.fill", color: .red, kind: .hr)
            HStack {
                pairStat("平均", avg.map { "\(Int($0))" } ?? "—", "次/分")
                Spacer()
                pairStat("最高", maxHR.map { "\(Int($0))" } ?? "—", "次/分")
            }

            Chart {
                ForEach(Array(hrSegments.enumerated()), id: \.offset) { idx, seg in
                    ForEach(seg.points) { p in
                        LineMark(
                            x: .value("分钟", p.minute),
                            y: .value("心率", p.bpm),
                            series: .value("段", idx)
                        )
                        .foregroundStyle(seg.color)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.2))
                    }
                }
            }
            .chartXScale(domain: chartMinuteDomain(detailed.heartRateSeries.map(\.minute)))
            .chartYScale(domain: domain)
            .chartPlotStyle { $0.clipped() }
            .chartXAxisLabel("分钟")
            .frame(height: 160)
            .clipped()

            if !detailed.hrZones.isEmpty {
                zoneBlockHeader("心率区间", kind: .hrZone)
                VStack(spacing: 14) {
                    ForEach(detailed.hrZones) { z in
                        MetricListedZoneRow(
                            title: "区间 \(z.index)",
                            subtitle: z.name,
                            trailing: z.durationText,
                            caption: z.rangeText,
                            fraction: z.fraction,
                            color: Color(themeName: z.tintName)
                        )
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var hrDomain: ClosedRange<Double> {
        let vals = detailed.heartRateSeries.map(\.bpm)
        let lo = (vals.min() ?? 60) - 10
        let hi = (vals.max() ?? 160) + 10
        return max(lo, 40)...hi
    }

    private var hrSegments: [(color: Color, points: [HeartRatePoint])] {
        let series = detailed.heartRateSeries
        guard series.count >= 2 else { return [] }
        var result: [(Color, [HeartRatePoint])] = []
        var current = hrZoneIndex(series[0].bpm)
        var bucket: [HeartRatePoint] = [series[0]]
        for i in 1..<series.count {
            let idx = hrZoneIndex(series[i].bpm)
            if idx == current {
                bucket.append(series[i])
            } else {
                bucket.append(series[i])
                result.append((hrZoneColor(current), bucket))
                current = idx
                bucket = [series[i]]
            }
        }
        if bucket.count >= 2 {
            result.append((hrZoneColor(current), bucket))
        }
        return result
    }

    private func hrZoneIndex(_ bpm: Double) -> Int {
        for z in detailed.hrZones {
            if let high = z.bpmHigh, bpm <= Double(high) { return z.index }
            if z.bpmHigh == nil, bpm >= Double(z.bpmLow) { return z.index }
        }
        return 3
    }

    private func hrZoneColor(_ index: Int) -> Color {
        if let z = detailed.hrZones.first(where: { $0.index == index }) {
            return Color(themeName: z.tintName)
        }
        return .red
    }

    // MARK: - 配速

    private var paceSection: some View {
        let avg = record.avgPaceMinPerKM
        let best = detailed.bestPaceMinPerKM
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("配速", icon: "speedometer", color: .blue, kind: .pace)
            HStack {
                pairStat("平均", avg.map(paceText) ?? "—", "/km")
                Spacer()
                pairStat("最佳", best.map(paceText) ?? "—", "/km")
            }

            if detailed.paceSeries.count >= 2 {
                let domain = paceDomain
                Chart {
                    ForEach(detailed.paceSeries) { p in
                        LineMark(
                            x: .value("分钟", p.minute),
                            y: .value("配速", p.value)
                        )
                        .foregroundStyle(Color.blue)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.2))
                    }
                    if let avg {
                        RuleMark(y: .value("均速", avg))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.secondary.opacity(0.7))
                    }
                }
                .chartXScale(domain: chartMinuteDomain(detailed.paceSeries.map(\.minute)))
                .chartYScale(domain: domain)
                .chartPlotStyle { $0.clipped() }
                .chartXAxisLabel("分钟")
                .chartYAxisLabel("分钟/km")
                .frame(height: 160)
                .clipped()
            }

            if !detailed.paceZones.isEmpty {
                zoneBlockHeader("配速区间", kind: .paceZone)
                VStack(spacing: 14) {
                    ForEach(detailed.paceZones) { z in
                        MetricListedZoneRow(
                            title: z.name,
                            subtitle: z.percentText,
                            trailing: z.durationText,
                            fraction: z.fraction,
                            color: Color(themeName: z.tintName)
                        )
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var paceDomain: ClosedRange<Double> {
        let vals = detailed.paceSeries.map(\.value)
        let lo = (vals.min() ?? 4) - 0.3
        let hi = (vals.max() ?? 8) + 0.3
        return max(lo, 2)...hi
    }

    // MARK: - 分段表

    private var splitsTable: some View {
        let rows = showAllSplits ? detailed.splits : Array(detailed.splits.prefix(12))
        let fastest = detailed.splits.filter { !$0.isPartial }.map(\.paceMin).min()
        let slowest = detailed.splits.filter { !$0.isPartial }.map(\.paceMin).max()
        let showCadence = detailed.splits.contains { $0.avgCadence != nil }
        let showElev = detailed.splits.contains { $0.elevationDelta != nil }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("分段", icon: "list.number", color: tint, kind: .split)
                Spacer()
                if detailed.splits.count > 12 {
                    Button(showAllSplits ? "收起" : "全部") {
                        withAnimation { showAllSplits.toggle() }
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            HStack(spacing: 0) {
                Text("公里").frame(width: 36, alignment: .leading)
                Text("用时").frame(maxWidth: .infinity)
                Text("配速").frame(maxWidth: .infinity)
                Text("心率").frame(width: 36, alignment: .trailing)
                if showCadence {
                    Text("步频").frame(width: 36, alignment: .trailing)
                }
                if showElev {
                    Text("海拔").frame(width: 40, alignment: .trailing)
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(rows) { split in
                let isFast = fastest != nil && !split.isPartial && split.paceMin == fastest
                let isSlow = slowest != nil && !split.isPartial && split.paceMin == slowest && fastest != slowest
                HStack(spacing: 0) {
                    Text(split.isPartial
                         ? String(format: "%.2f", split.segmentMeters / 1000)
                         : "\(split.index)")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 36, alignment: .leading)
                    Text(split.durationMinutes.minutesAsClock)
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity)
                    Text(paceText(split.paceMin))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isFast ? Color.green : .primary)
                        .frame(maxWidth: .infinity)
                    Text(split.avgHR.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                    if showCadence {
                        Text(split.avgCadence.map { "\(Int($0.rounded()))" } ?? "—")
                            .font(.caption.monospacedDigit())
                            .frame(width: 36, alignment: .trailing)
                    }
                    if showElev {
                        Text(elevDeltaText(split.elevationDelta))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(elevDeltaColor(split.elevationDelta))
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background {
                    if isFast {
                        RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12))
                    } else if isSlow {
                        RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func elevDeltaText(_ delta: Double?) -> String {
        guard let delta else { return "—" }
        let v = Int(delta.rounded())
        if v > 0 { return "+\(v)" }
        return "\(v)"
    }

    private func elevDeltaColor(_ delta: Double?) -> Color {
        guard let delta else { return .secondary }
        if delta > 2 { return .orange }
        if delta < -2 { return .blue }
        return .secondary
    }

    // MARK: - 跑步动态 / 海拔

    private var strideCard: some View {
        seriesCard(
            title: "步幅",
            icon: "ruler",
            color: .cyan,
            kind: .stride,
            left: ("平均", dyn.avgStrideM.map { String(format: "%.2f", $0) } ?? "—", "米"),
            right: ("最大", dyn.maxStrideM.map { String(format: "%.2f", $0) } ?? "—", "米"),
            series: dyn.strideSeries,
            yLabel: "m"
        )
    }

    private var cadenceCard: some View {
        seriesCard(
            title: "步频",
            icon: "metronome.fill",
            color: .orange,
            kind: .cadence,
            left: ("平均", dyn.avgCadence.map { "\(Int($0.rounded()))" } ?? "—", "步/分"),
            right: ("最大", dyn.maxCadence.map { "\(Int($0.rounded()))" } ?? "—", "步/分"),
            series: dyn.cadenceSeries,
            yLabel: "spm"
        )
    }

    private var verticalOscCard: some View {
        seriesCard(
            title: "垂直振幅",
            icon: "arrow.up.arrow.down",
            color: .orange,
            kind: .vo,
            left: ("平均", dyn.avgVerticalOscCM.map { String(format: "%.1f", $0) } ?? "—", "厘米"),
            right: ("最大", dyn.maxVerticalOscCM.map { String(format: "%.1f", $0) } ?? "—", "厘米"),
            series: dyn.verticalOscSeries,
            yLabel: "cm"
        )
    }

    private var groundContactCard: some View {
        seriesCard(
            title: "触地时间",
            icon: "figure.run",
            color: .blue,
            kind: .gct,
            left: ("平均", dyn.avgGroundContactMS.map { "\(Int($0.rounded()))" } ?? "—", "毫秒"),
            right: ("最大", dyn.maxGroundContactMS.map { "\(Int($0.rounded()))" } ?? "—", "毫秒"),
            series: dyn.groundContactSeries,
            yLabel: "ms"
        )
    }

    private var showElevationCard: Bool {
        guard detailed.elevationSeries.count >= 2 else { return false }
        if let gain = detailed.elevationGain ?? record.elevationGain, gain > 0 { return true }
        let alts = detailed.elevationSeries.map(\.meters)
        return (alts.max() ?? 0) - (alts.min() ?? 0) >= 3
    }

    private var elevationSection: some View {
        let series = detailed.elevationSeries
        let alts = series.map(\.meters)
        let minAlt = alts.min() ?? 0
        let maxAlt = alts.max() ?? 0
        let lo = minAlt - 5
        let hi = max(maxAlt + 5, lo + 10)
        let domain = lo...hi
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("海拔", icon: "mountain.2.fill", color: .yellow, kind: .elev)
            HStack {
                pairStat("最高", String(format: "%.0f", maxAlt), "米")
                Spacer()
                pairStat("最低", String(format: "%.0f", minAlt), "米")
            }

            Chart(series) { p in
                AreaMark(
                    x: .value("分钟", p.minute),
                    yStart: .value("底", domain.lowerBound),
                    yEnd: .value("海拔", min(max(p.meters, domain.lowerBound), domain.upperBound))
                )
                .foregroundStyle(LinearGradient(colors: [.yellow.opacity(0.35), .yellow.opacity(0.04)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.linear)

                LineMark(x: .value("分钟", p.minute), y: .value("海拔", p.meters))
                    .foregroundStyle(.yellow)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
            }
            .chartXScale(domain: chartMinuteDomain(series.map(\.minute)))
            .chartYScale(domain: domain)
            .chartPlotStyle { $0.clipped() }
            .chartXAxisLabel("分钟")
            .chartYAxisLabel("m")
            .frame(height: 160)
            .clipped()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func seriesCard(title: String,
                            icon: String,
                            color: Color,
                            kind: MetricGuideKind,
                            left: (String, String, String),
                            right: (String, String, String),
                            series: [WorkoutMetricPoint],
                            yLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title, icon: icon, color: color, kind: kind)
            HStack {
                pairStat(left.0, left.1, left.2)
                Spacer()
                pairStat(right.0, right.1, right.2)
            }
            if series.count >= 2 {
                let vals = series.map(\.value)
                let lo = (vals.min() ?? 0) * 0.92
                let hi = (vals.max() ?? 1) * 1.08
                let domain = min(lo, hi - 0.1)...max(hi, lo + 0.1)
                Chart {
                    ForEach(series) { p in
                        LineMark(
                            x: .value("分钟", p.minute),
                            y: .value(title, p.value)
                        )
                        .foregroundStyle(color)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.2))
                    }
                }
                .chartXScale(domain: chartMinuteDomain(series.map(\.minute)))
                .chartYScale(domain: domain)
                .chartPlotStyle { $0.clipped() }
                .chartXAxisLabel("分钟")
                .chartYAxisLabel(yLabel)
                .frame(height: 140)
                .clipped()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 共用

    private func sectionHeader(_ title: String, icon: String, color: Color, kind: MetricGuideKind) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            infoButton(kind, accessibility: "\(title)说明")
        }
    }

    private func zoneBlockHeader(_ title: String, kind: MetricGuideKind) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.bold))
            infoButton(kind, accessibility: "\(title)说明")
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func infoButton(_ kind: MetricGuideKind, accessibility: String) -> some View {
        Button {
            presentedGuide = MetricGuideAdvisor.content(
                kind: kind,
                record: record,
                detailed: detailed,
                peerAvgPace: peerAvgPace
            )
        } label: {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    private func pairStat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title2.bold().monospacedDigit())
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chartMinuteDomain(_ minutes: [Double]) -> ClosedRange<Double> {
        let end = max(minutes.max() ?? 1, 1)
        return 0...end
    }

    private func paceText(_ minPerUnit: Double) -> String {
        minPerUnit.asPaceText
    }
}
