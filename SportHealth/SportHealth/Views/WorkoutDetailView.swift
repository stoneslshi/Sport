import SwiftUI
import Charts
import MapKit
import HealthKit

/// 运动详情页：完整指标 + 心率曲线；游泳对齐 Keep 式信息架构（距离 Hero / 趟 / 组 / 配速 / 区间）。
struct WorkoutDetailView: View {
    @Environment(HealthViewModel.self) private var vm
    let record: WorkoutRecord

    @State private var detailed: WorkoutRecord
    @State private var isLoading = true
    @State private var shareItem: ShareImageItem?
    @State private var isPreparingShare = false
    @State private var showAllLaps = false
    @State private var showRouteReplay = false

    init(record: WorkoutRecord) {
        self.record = record
        _detailed = State(initialValue: record)
    }

    private var tint: Color { Color(themeName: record.activityType.tintName) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if detailed.isSwimming {
                    swimHero
                    swimMetricsGrid
                    if !detailed.swimLaps.isEmpty { swimLapsCard }
                    if detailed.swimSets.count > 1 { swimSetsCard }
                    if !detailed.splits.isEmpty || !detailed.swimLaps.isEmpty { swimPaceCard }
                    if !detailed.strokeDistribution.isEmpty { strokeCard }
                    if !detailed.sessionDistanceBests.isEmpty { sessionBestsCard }
                    if swimComparisonRows != nil { swimCompareCard }
                    if !detailed.heartRateSeries.isEmpty {
                        heartRateCard
                        if !detailed.hrZones.isEmpty { hrZonesCard }
                    }
                } else {
                    header
                    metricsGrid
                    if detailed.hasRoute { routeMapCard }
                    if showElevationCard { elevationCard }
                    if !detailed.heartRateSeries.isEmpty {
                        heartRateCard
                        if !detailed.hrZones.isEmpty { hrZonesCard }
                    }
                    if !detailed.splits.isEmpty { splitsCard }
                }

                if !isLoading && detailIsEmpty {
                    ContentUnavailableView("暂无更详细的数据",
                                           systemImage: "waveform.path.ecg",
                                           description: Text(detailed.isSwimming
                                                              ? "这次游泳没有趟次、心率或泳姿明细。佩戴 Apple Watch 泳池游泳可记录更完整数据。"
                                                              : "这次运动没有记录心率或 GPS 轨迹。"))
                        .padding(.top, 20)
                }
            }
            .padding()
        }
        .navigationTitle(record.activityType.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            detailed = await vm.loadWorkoutDetail(record)
            isLoading = false
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await prepareShare() }
                } label: {
                    if isPreparingShare { ProgressView() }
                    else { Image(systemName: "square.and.arrow.up") }
                }
                .disabled(isPreparingShare)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(image: item.image, text: item.text)
        }
        .navigationDestination(isPresented: $showRouteReplay) {
            WorkoutRouteDetailView(
                coordinates: detailed.routeCoordinates,
                splits: detailed.splits,
                tint: tint,
                activityName: detailed.activityType.displayName,
                distanceKM: detailed.distanceKM,
                durationMinutes: detailed.durationMinutes
            )
        }
    }

    private var detailIsEmpty: Bool {
        if detailed.isSwimming {
            return detailed.swimLaps.isEmpty && detailed.heartRateSeries.isEmpty
                && detailed.strokeDistribution.isEmpty && detailed.splits.isEmpty
        }
        return !detailed.hasRoute && detailed.heartRateSeries.isEmpty && detailed.splits.isEmpty
    }

    @MainActor
    private func prepareShare() async {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        let caption = await vm.shareCaption(for: detailed)
        var snapshot: UIImage?
        if detailed.hasRoute {
            snapshot = await ShareCardRenderer.routeSnapshot(
                coordinates: detailed.routeCoordinates, tint: tint,
                scale: UIScreen.main.scale)
        }
        let image = ShareCardRenderer.renderWorkout(record: detailed, caption: caption,
                                                    routeSnapshot: snapshot)
        shareItem = ShareImageItem(image: image, text: caption + " " + AppBrand.shareHashtag)
    }

    private func paceText(_ minPerUnit: Double) -> String {
        let m = Int(minPerUnit)
        let s = Int((minPerUnit - Double(m)) * 60)
        return String(format: "%d'%02d\"", m, s)
    }

    // MARK: - 通用头部 / 指标（非游泳）

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: record.activityType.symbolName)
                .font(.system(size: 40))
                .foregroundStyle(tint)
                .frame(width: 84, height: 84)
                .background(tint.opacity(0.15), in: Circle())
            Text(record.activityType.displayName).font(.title2.bold())
            Text(record.start.mdTimeCN).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            LinearGradient(colors: [tint.opacity(0.16), Color(.secondarySystemBackground)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 20)
        )
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metric("消耗", "\(Int(record.caloriesKcal))", "kcal", "flame.fill", .orange)
            metric("时长", "\(Int(record.durationMinutes))", "分钟", "timer", .blue)
            if let km = record.distanceKM, km > 0 {
                metric("距离", km < 1 ? "\(Int(km * 1000))" : km.oneDecimal,
                       km < 1 ? "m" : "km", "map", .purple)
            }
            if let pace = record.avgPaceMinPerKM {
                metric("平均配速", paceText(pace), "/km", "speedometer", .green)
            }
            if let hr = detailed.avgHR ?? record.avgHR {
                metric("平均心率", "\(Int(hr))", "bpm", "heart.fill", .red)
            }
            if let mx = detailed.maxHR ?? record.maxHR {
                metric("最高心率", "\(Int(mx))", "bpm", "bolt.heart.fill", .pink)
            }
            if let elev = record.elevationGain, elev > 0 {
                metric("累计爬升", "\(Int(elev))", "m", "mountain.2.fill", .brown)
            }
        }
    }

    private func metric(_ title: String, _ value: String, _ unit: String,
                        _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 游泳 Hero

    private var swimHero: some View {
        let meters = Int(((detailed.distanceKM ?? record.distanceKM ?? 0) * 1000).rounded())
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(record.start.mediumLabelCN)  \(record.start.timeShort) – \(record.end.timeShort)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(meters)")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan)
                        Text("m").font(.title2.weight(.semibold)).foregroundStyle(.cyan.opacity(0.75))
                    }
                    HStack(spacing: 10) {
                        if let pool = detailed.poolLength ?? record.poolLength, pool > 0 {
                            Label("\(Int(pool))m 泳池", systemImage: "figure.pool.swim")
                        }
                        if let laps = detailed.laps, laps > 0 {
                            Label("\(laps) 趟", systemImage: "arrow.left.arrow.right")
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                // 泳姿色点
                HStack(spacing: 6) {
                    ForEach(topStrokes.prefix(4), id: \.self) { s in
                        Circle()
                            .fill(Color(themeName: s.tintName))
                            .frame(width: 10, height: 10)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.cyan.opacity(0.18), Color(.secondarySystemBackground)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20)
        )
    }

    private var topStrokes: [SwimStroke] {
        detailed.strokeDistribution
            .filter { $0.value > 0 && $0.key != .unknown }
            .sorted { $0.value > $1.value }
            .map(\.key)
    }

    /// 均划次/趟：优先各趟有划次的平均，否则总划次 ÷ 趟数
    private var avgStrokesPerLap: Double? {
        let perLap = detailed.swimLaps.compactMap(\.strokeCount).filter { $0 > 0 }
        if !perLap.isEmpty {
            return Double(perLap.reduce(0, +)) / Double(perLap.count)
        }
        guard let strokes = detailed.totalStrokeCount, strokes > 0,
              let laps = detailed.laps, laps > 0 else { return nil }
        return Double(strokes) / Double(laps)
    }

    // MARK: - 游泳指标网格

    private var swimMetricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metric("总时长", record.durationMinutes.minutesAsClock, "", "timer", .yellow)
            if let pace = detailed.avgPacePer100m ?? record.avgPacePer100m {
                metric("平均配速", paceText(pace), "/100m", "speedometer", .orange)
            }
            if let hr = detailed.avgHR ?? record.avgHR {
                metric("平均心率", "\(Int(hr))", "bpm", "heart.fill", .orange)
            }
            metric("消耗", "\(Int(record.caloriesKcal))", "kcal", "flame.fill", .green)
            if let swolf = detailed.avgSWOLF {
                metric("平均 SWOLF", String(format: "%.0f", swolf), "", "waveform.path.ecg", .green)
            }
            if let avg = avgStrokesPerLap {
                metric("均划次/趟", String(format: "%.0f", avg), "次", "hands.clap.fill", .green)
            } else if let strokes = detailed.totalStrokeCount {
                metric("总划次", "\(strokes)", "次", "hands.clap.fill", .green)
            }
            if let best = detailed.bestPacePer100m {
                metric("最快配速", paceText(best), "/100m", "hare.fill", .red)
            }
            if let mx = detailed.maxHR ?? record.maxHR {
                metric("最高心率", "\(Int(mx))", "bpm", "bolt.heart.fill", .red)
            }
            if let laps = detailed.laps, laps > 0 {
                metric("趟数", "\(laps)", "趟", "arrow.left.arrow.right", .cyan)
            }
        }
    }

    // MARK: - 趟次列表

    private var swimLapsCard: some View {
        let laps = showAllLaps ? detailed.swimLaps : Array(detailed.swimLaps.prefix(8))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("分段", systemImage: "list.number").font(.headline)
                Spacer()
                if detailed.swimLaps.count > 8 {
                    Button(showAllLaps ? "收起" : "查看更多") {
                        withAnimation { showAllLaps.toggle() }
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            HStack {
                Text("#").frame(width: 28, alignment: .leading)
                Text("距离")
                Spacer()
                Text("用时")
                Text("配速").frame(width: 54, alignment: .trailing)
                Text("泳姿").frame(width: 48, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(laps) { lap in
                HStack(spacing: 8) {
                    Text("\(lap.index)")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 28, alignment: .leading)
                    Text("\(Int(lap.distanceM))m")
                        .font(.subheadline)
                    Spacer()
                    Text(lap.durationSec.clockString)
                        .font(.subheadline.monospacedDigit())
                    Text(lap.paceMinPer100m.map(paceText) ?? "—")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 54, alignment: .trailing)
                    Text(lap.stroke.displayName)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(themeName: lap.stroke.tintName))
                        .frame(width: 48, alignment: .trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.vertical, 4)

                // 泳姿色条
                GeometryReader { geo in
                    Capsule()
                        .fill(Color(themeName: lap.stroke.tintName).opacity(0.85))
                        .frame(width: geo.size.width * lapBarWidth(lap), height: 4)
                }
                .frame(height: 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func lapBarWidth(_ lap: SwimLap) -> CGFloat {
        let paces = detailed.swimLaps.compactMap(\.paceMinPer100m)
        guard let p = lap.paceMinPer100m, let slow = paces.max(), let fast = paces.min(), slow > fast else {
            return 0.55
        }
        // 更快 → 更长条
        let ratio = 1 - (p - fast) / (slow - fast)
        return CGFloat(0.25 + ratio * 0.75)
    }

    // MARK: - 自动组

    private var swimSetsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("自动组合", systemImage: "square.stack.3d.up.fill").font(.headline)
            HStack {
                Text("组").frame(width: 36, alignment: .leading)
                Text("趟")
                Spacer()
                Text("距离")
                Text("用时").frame(width: 52, alignment: .trailing)
                Text("配速").frame(width: 54, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(detailed.swimSets) { set in
                HStack {
                    Text("\(set.index)")
                        .font(.subheadline.bold())
                        .frame(width: 36, alignment: .leading)
                    Text(set.lapLabel).font(.subheadline)
                    Spacer()
                    Text("\(Int(set.distanceM))m").font(.subheadline)
                    Text(set.activeSec.clockString)
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                    Text(set.avgPaceMinPer100m.map(paceText) ?? "—")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 54, alignment: .trailing)
                }
                if set.restSec >= 12 {
                    Text("休息 \(Int(set.restSec.rounded())) 秒")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 配速柱图

    private var swimPaceCard: some View {
        let points: [(Int, Double)] = {
            if !detailed.swimLaps.isEmpty {
                return detailed.swimLaps.compactMap { lap in
                    guard let p = lap.paceMinPer100m else { return nil }
                    return (lap.index, p)
                }
            }
            return detailed.splits.map { ($0.index, $0.paceMin) }
        }()
        let avg = points.map(\.1).reduce(0, +) / Double(max(points.count, 1))
        let best = points.map(\.1).min()
        let worst = points.map(\.1).max()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("配速", systemImage: "chart.bar.fill").font(.headline)
                Spacer()
                if let best, let worst {
                    Text("最快 \(paceText(best)) · 最慢 \(paceText(worst))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(points, id: \.0) { idx, pace in
                    BarMark(
                        x: .value("趟", idx),
                        y: .value("配速", pace)
                    )
                    .foregroundStyle(Color.orange.gradient)
                    .cornerRadius(3)
                }
                if avg > 0 {
                    RuleMark(y: .value("均速", avg))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel("分钟/100m")
            .frame(height: 160)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 本场距离最佳

    private var sessionBestsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("本场最佳分段", systemImage: "trophy.fill").font(.headline)
            ForEach(detailed.sessionDistanceBests) { b in
                HStack {
                    Text("\(b.meters) m")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(b.timeSec.clockString)
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .foregroundStyle(.cyan)
                }
                .padding(.vertical, 2)
            }
            Text("由本场连续趟次累计计算，非历史个人纪录。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 与历史对比

    private var swimComparisonRows: [(String, String, String, Bool?)]? {
        guard let cur = detailed.avgPacePer100m ?? record.avgPacePer100m else { return nil }
        var rows: [(String, String, String, Bool?)] = []
        if let avg = vm.averageSwimPacePer100m(excluding: record.id) {
            let better = cur < avg // 配速越小越好
            rows.append(("平均配速", paceText(cur) + "/100m", paceText(avg) + "/100m", better))
        }
        if let swolf = detailed.avgSWOLF {
            rows.append(("平均 SWOLF", String(format: "%.0f", swolf), "—", nil))
        }
        if let kcal = Optional(record.caloriesKcal) {
            rows.append(("消耗", "\(Int(kcal)) kcal", "—", nil))
        }
        return rows.isEmpty ? nil : rows
    }

    private var swimCompareCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("比较", systemImage: "arrow.left.arrow.right").font(.headline)
            HStack {
                Text("指标").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("本次").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text("历史均").frame(width: 72, alignment: .trailing)
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let rows = swimComparisonRows {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.0).font(.subheadline)
                        Spacer()
                        Text(row.1).font(.subheadline.weight(.semibold))
                        HStack(spacing: 4) {
                            Text(row.2)
                            if let better = row.3 {
                                Image(systemName: better ? "arrow.down" : "arrow.up")
                                    .foregroundStyle(better ? .green : .orange)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 轨迹 / 心率 / 分段（通用）

    private var routeMapCard: some View {
        // 不用 NavigationLink 包整卡：系统会为右侧 disclosure 预留宽度，轨迹看起来整体偏左。
        Button {
            showRouteReplay = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("运动轨迹", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("动态回放")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)

                RouteMapView(coordinates: detailed.routeCoordinates, tint: tint)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .allowsHitTesting(false)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    /// 有爬升元数据，或 GPS 海拔曲线有效时展示
    private var showElevationCard: Bool {
        guard detailed.elevationSeries.count >= 2 else { return false }
        if let gain = detailed.elevationGain ?? record.elevationGain, gain > 0 { return true }
        let alts = detailed.elevationSeries.map(\.meters)
        return (alts.max() ?? 0) - (alts.min() ?? 0) >= 3
    }

    private var elevationCard: some View {
        let series = detailed.elevationSeries
        let domain = elevationDomain
        let minAlt = series.map(\.meters).min() ?? domain.lowerBound
        let maxAlt = series.map(\.meters).max() ?? domain.upperBound
        let gain = detailed.elevationGain ?? record.elevationGain
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("爬升曲线", systemImage: "mountain.2.fill").font(.headline)
                Spacer()
                if let gain, gain > 0 {
                    Text("累计 +\(Int(gain)) m")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.brown)
                }
            }

            Chart(series) { p in
                AreaMark(
                    x: .value("分钟", p.minute),
                    yStart: .value("底", domain.lowerBound),
                    yEnd: .value("海拔", min(max(p.meters, domain.lowerBound), domain.upperBound))
                )
                .foregroundStyle(LinearGradient(colors: [.brown.opacity(0.35), .brown.opacity(0.04)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.linear)

                LineMark(x: .value("分钟", p.minute), y: .value("海拔", p.meters))
                    .foregroundStyle(.brown)
                    .interpolationMethod(.catmullRom)
            }
            .chartXScale(domain: chartMinuteDomain(series.map(\.minute)))
            .chartYScale(domain: domain)
            .chartPlotStyle { $0.clipped() }
            .chartXAxisLabel("分钟")
            .chartYAxisLabel("m")
            .frame(height: 180)
            .clipped()

            HStack {
                Text(String(format: "最低 %.0f m", minAlt))
                Spacer()
                Text(String(format: "最高 %.0f m", maxAlt))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var elevationDomain: ClosedRange<Double> {
        let vals = detailed.elevationSeries.map(\.meters)
        let lo = (vals.min() ?? 0) - 5
        let hi = (vals.max() ?? 100) + 5
        return lo...max(hi, lo + 10)
    }

    private var heartRateCard: some View {
        let domain = hrDomain
        return VStack(alignment: .leading, spacing: 10) {
            Label("心率曲线", systemImage: "waveform.path.ecg").font(.headline)
            Chart(detailed.heartRateSeries) { p in
                // 填充锚定在 Y 域下界，避免 AreaMark 画出绘图区
                AreaMark(
                    x: .value("分钟", p.minute),
                    yStart: .value("底", domain.lowerBound),
                    yEnd: .value("心率", min(max(p.bpm, domain.lowerBound), domain.upperBound))
                )
                .foregroundStyle(LinearGradient(colors: [.red.opacity(0.28), .red.opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.linear)

                LineMark(x: .value("分钟", p.minute), y: .value("心率", p.bpm))
                    .foregroundStyle(.red)
                    .interpolationMethod(.catmullRom)
            }
            .chartXScale(domain: chartMinuteDomain(detailed.heartRateSeries.map(\.minute)))
            .chartYScale(domain: domain)
            .chartPlotStyle { $0.clipped() }
            .chartXAxisLabel("分钟")
            .frame(height: 180)
            .clipped()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// 横轴贴合数据末点，避免 Charts 自动「好看刻度」把右侧拉出大片空白。
    private func chartMinuteDomain(_ minutes: [Double]) -> ClosedRange<Double> {
        let end = max(minutes.max() ?? 1, 1)
        return 0...end
    }

    private var hrDomain: ClosedRange<Double> {
        let vals = detailed.heartRateSeries.map { $0.bpm }
        let lo = (vals.min() ?? 60) - 10
        let hi = (vals.max() ?? 160) + 10
        return max(lo, 40)...hi
    }

    private var hrZonesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("心率区间", systemImage: "chart.bar.doc.horizontal").font(.headline)

            VStack(spacing: 14) {
                ForEach(detailed.hrZones) { z in
                    hrZoneRow(z)
                }
            }

            Text("每个心率区间的估计时间")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func hrZoneRow(_ z: HRZoneSlice) -> some View {
        let color = Color(themeName: z.tintName)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("区间 \(z.index)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(color)
                Text(z.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(z.durationText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                Text(z.rangeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 88, alignment: .trailing)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    if z.seconds > 0.5 {
                        Capsule()
                            .fill(color)
                            .frame(width: max(8, geo.size.width * CGFloat(z.fraction)))
                    } else {
                        // 无时长时显示色点，与系统健身五段式一致
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .frame(height: 8)
        }
    }

    private var splitsCard: some View {
        let per100 = detailed.isSwimming || detailed.splits.first?.isPer100m == true
        return VStack(alignment: .leading, spacing: 10) {
            Label("分段配速", systemImage: "chart.bar.fill").font(.headline)
            Chart(detailed.splits) { s in
                BarMark(
                    x: .value("配速", s.paceMin),
                    y: .value("段", per100 ? "第 \(s.index) ×100m" : "第 \(s.index) 公里")
                )
                .foregroundStyle(tint)
                .cornerRadius(4)
                .annotation(position: .trailing, alignment: .leading) {
                    Text(paceText(s.paceMin))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxisLabel(per100 ? "分钟/100m" : "分钟/km")
            .frame(height: max(120, CGFloat(detailed.splits.count) * 34 + 30))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var strokeCard: some View {
        let items = detailed.strokeDistribution
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
        let total = items.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 14) {
            Label("泳姿分布", systemImage: "figure.pool.swim").font(.headline)
            ForEach(items, id: \.key) { stroke, meters in
                let pct = total > 0 ? meters / total : 0
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(stroke.displayName).font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(Int(meters))m · \(Int(pct * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule()
                                .fill(Color(themeName: stroke.tintName))
                                .frame(width: max(6, geo.size.width * pct))
                        }
                    }
                    .frame(height: 10)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
