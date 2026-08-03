import SwiftUI
import Charts

struct SleepView: View {
    @Environment(HealthViewModel.self) private var vm
    @State private var trendMetric: SleepTrendMetric = .hours

    private var nights: [SleepNight] { vm.displaySleepNights }
    private var lastNight: SleepNight? { vm.lastNight }
    private var summary: SleepSummary { vm.sleepSummary }

    var body: some View {
        NavigationStack {
            Group {
                if !vm.hasRequestedAuth {
                    ContentUnavailableView("暂无睡眠数据", systemImage: "moon.zzz.fill",
                                           description: Text("请先在「概览」页授权 Apple 健康。佩戴 Apple Watch 睡觉可自动记录睡眠分期。"))
                } else if nights.isEmpty {
                    ContentUnavailableView("暂无睡眠数据", systemImage: "moon.zzz.fill",
                                           description: Text("最近没有可用的睡眠记录。佩戴 Apple Watch 睡觉，或在 iPhone「健康」App 手动记录睡眠后再来查看。"))
                } else {
                    content
                }
            }
            .navigationTitle("睡眠")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroCard
                stagesCard
                if let n = lastNight, n.vitals.hasAny {
                    vitalsCard(n.vitals)
                }
                trendCard
                scheduleCard
                if !vm.sleepInsights.isEmpty {
                    insightsCard
                }
            }
            .padding()
        }
    }

    // MARK: 昨夜评分 + 结论 + vs 平常 + 午睡

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                ZStack {
                    ProgressRing(progress: Double(summary.lastNightScore) / 100, color: sleepAccent, lineWidth: 11)
                        .frame(width: 104, height: 104)
                    VStack(spacing: 2) {
                        Text("\(summary.lastNightScore)")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("睡眠评分").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let n = lastNight {
                        Text(hm(n.asleepMin)).font(.system(size: 28, weight: .heavy))
                        Text("深睡 \(hm(n.deepMin)) · 效率 \(Int(n.efficiency * 100))%")
                            .font(.footnote).foregroundStyle(.secondary)
                        Label("\(n.inBed.timeShort) 入睡 · \(n.wake.timeShort) 起床",
                              systemImage: "bed.double.fill")
                            .font(.footnote).foregroundStyle(sleepAccent)
                    }
                }
                Spacer(minLength: 0)
            }

            if let verdict = vm.sleepVerdict {
                Text(verdict)
                    .font(.subheadline)
                    .foregroundStyle(Color(sleepColorName: "sleepREM"))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sleepAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }

            if let cmp = vm.sleepComparison {
                HStack(spacing: 8) {
                    vsCell(title: "入睡 vs 平常",
                           value: bedDeltaText(cmp.bedDeltaMin),
                           tone: bedTone(cmp.bedDeltaMin),
                           base: "均值 \(cmp.avgBedLabel)")
                    vsCell(title: "时长 vs 平常",
                           value: amountDeltaText(cmp.durDeltaMin, more: "多", less: "少"),
                           tone: amountTone(cmp.durDeltaMin),
                           base: "均值 \(cmp.avgDurLabel)")
                    vsCell(title: "深睡 vs 平常",
                           value: amountDeltaText(cmp.deepDeltaMin, more: "多", less: "少"),
                           tone: amountTone(cmp.deepDeltaMin),
                           base: "均值 \(cmp.avgDeepLabel)")
                }
            }

            if let nap = lastNight?.nap {
                HStack(spacing: 10) {
                    Image(systemName: "zzz")
                        .font(.title3)
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("另有午睡 \(hm(nap.asleepMin))").font(.subheadline.bold())
                        Text("\(nap.start.timeShort) – \(nap.end.timeShort) · 不计入上方「昨夜」主睡眠")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.cyan.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func vsCell(title: String, value: String, tone: Color, base: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).foregroundStyle(tone)
            Text(base).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 分期时间轴 + 占比

    private var stagesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("睡眠阶段").font(.headline)
                Spacer()
                Text("昨夜时间轴").font(.caption).foregroundStyle(.secondary)
            }

            if let n = lastNight, !n.segments.isEmpty {
                HypnogramView(night: n)
            }

            stageBar
            stageLegend
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var stageTotal: Double {
        guard let n = lastNight else { return 0 }
        return SleepStage.allCases.reduce(0) { $0 + n.minutes(of: $1) }
    }

    @ViewBuilder
    private var stageBar: some View {
        let total = stageTotal
        if total > 0 {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(SleepStage.allCases) { stage in
                        let mins = lastNight?.minutes(of: stage) ?? 0
                        if mins > 0 {
                            Color(sleepColorName: stage.colorName)
                                .frame(width: max(geo.size.width * mins / total - 2, 1))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
        }
    }

    private var stageLegend: some View {
        VStack(spacing: 8) {
            ForEach(SleepStage.allCases) { stage in
                let mins = lastNight?.minutes(of: stage) ?? 0
                HStack(spacing: 8) {
                    Circle().fill(Color(sleepColorName: stage.colorName)).frame(width: 10, height: 10)
                    Text(stage.rawValue).font(.subheadline)
                    Spacer()
                    Text(hm(mins)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 夜间生命体征

    private func vitalsCard(_ v: SleepVitals) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("夜间生命体征").font(.headline)
                Spacer()
                Text("昨夜睡眠期间").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                vitalCell(icon: "wind",
                          value: v.respiratoryRate.map { String(format: "%.1f" , $0) },
                          unit: "次/分",
                          label: "呼吸频率",
                          hint: v.respiratoryRate != nil ? "均值" : nil)
                vitalCell(icon: "drop.fill",
                          value: v.oxygenSaturation.map { "\(Int(($0 * 100).rounded()))" },
                          unit: "%",
                          label: "血氧饱和度",
                          hint: v.oxygenSaturation != nil ? "均值" : nil)
                if let delta = v.wristTempDelta {
                    vitalCell(icon: "thermometer.medium",
                              value: String(format: "%+.2f", delta),
                              unit: "°C",
                              label: "腕温变化",
                              hint: "相对基线")
                } else if let abs = v.wristTempAbsolute {
                    vitalCell(icon: "thermometer.medium",
                              value: String(format: "%.1f", abs),
                              unit: "°C",
                              label: "体温",
                              hint: "绝对值")
                } else {
                    vitalCell(icon: "thermometer.medium",
                              value: nil, unit: "", label: "腕温变化", hint: nil)
                }
            }
            Text("需 Apple Watch 睡眠时佩戴并授权。腕温优先显示相对基线偏差。不构成医疗诊断。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func vitalCell(icon: String, value: String?, unit: String, label: String, hint: String?) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(sleepAccent)
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(.title3.bold())
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("暂无").font(.subheadline.bold()).foregroundStyle(.secondary)
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .opacity(value == nil ? 0.55 : 1)
    }

    // MARK: 近7晚趋势（多指标）

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("近 7 晚趋势").font(.headline)
                Spacer()
                Text(trendSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Picker("指标", selection: $trendMetric) {
                ForEach(SleepTrendMetric.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)

            Chart(nights) { night in
                BarMark(
                    x: .value("日期", night.date, unit: .day),
                    y: .value("值", trendValue(night))
                )
                .foregroundStyle(trendColor(night))
                .cornerRadius(5)
            }
            .chartYScale(domain: trendDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 1)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(trendAxisLabel(v))
                        }
                    }
                }
            }
            .chartPlotStyle { $0.clipped() }
            .frame(height: 170)
            .animation(.easeInOut(duration: 0.25), value: trendMetric)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var trendSubtitle: String {
        switch trendMetric {
        case .hours: return String(format: "日均 %.1f 小时", summary.avgAsleepHours)
        case .deep: return "日均深睡 \(Int(summary.avgDeepMin.rounded())) 分"
        case .efficiency: return "日均效率 \(Int((summary.avgEfficiency * 100).rounded()))%"
        case .score:
            let avg = nights.isEmpty ? 0 :
                nights.map { AnalysisEngine.sleepScore(night: $0) }.reduce(0, +) / nights.count
            return "日均评分 \(avg)"
        }
    }

    private func trendValue(_ night: SleepNight) -> Double {
        switch trendMetric {
        case .hours: return night.asleepHours
        case .deep: return night.deepMin
        case .efficiency: return night.efficiency * 100
        case .score: return Double(AnalysisEngine.sleepScore(night: night))
        }
    }

    private func trendColor(_ night: SleepNight) -> Color {
        switch trendMetric {
        case .hours: return night.asleepHours >= 7 ? sleepAccent : sleepAccent.opacity(0.4)
        case .deep: return night.deepMin >= 90 ? Color(sleepColorName: "sleepDeep") : Color(sleepColorName: "sleepDeep").opacity(0.45)
        case .efficiency: return night.efficiency >= 0.9 ? Color(sleepColorName: "sleepREM") : Color(sleepColorName: "sleepREM").opacity(0.4)
        case .score:
            let s = AnalysisEngine.sleepScore(night: night)
            return s >= 80 ? .green : .green.opacity(0.4)
        }
    }

    private var trendDomain: ClosedRange<Double> {
        let vals = nights.map(trendValue)
        let maxV = vals.max() ?? 1
        switch trendMetric {
        case .hours:
            let upper = max(ceil(maxV / 2) * 2, 8)
            return 0...upper
        case .deep:
            return 0...max(ceil(maxV / 20) * 20, 140)
        case .efficiency, .score:
            return 0...100
        }
    }

    private func trendAxisLabel(_ v: Double) -> String {
        switch trendMetric {
        case .hours: return "\(Int(v))h"
        case .deep: return "\(Int(v))m"
        case .efficiency: return "\(Int(v))%"
        case .score: return "\(Int(v))"
        }
    }

    // MARK: 作息规律

    private var scheduleCard: some View {
        let ax0 = 21.0, ax1 = 33.0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("作息规律").font(.headline)
                Spacer()
                Text("规律性 \(summary.regularityScore)/100")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("每条横条表示当晚主睡眠的时段。条越整齐对齐，说明近几天入睡/起床越稳定。规律性评分按入睡时间波动计算：每天差不多同一时间睡，分数越高。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(nights) { night in
                let startH = night.inBedHour < 12 ? night.inBedHour + 24 : night.inBedHour
                let rawEnd = night.wakeHour < 12 ? night.wakeHour + 24 : night.wakeHour
                let endH = max(rawEnd, startH)
                HStack(spacing: 10) {
                    Text(night.date.weekdayCN.replacingOccurrences(of: "周", with: ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 18)
                    GeometryReader { geo in
                        let leftFrac = min(max((startH - ax0) / (ax1 - ax0), 0), 1)
                        let rightFrac = min(max((endH - ax0) / (ax1 - ax0), 0), 1)
                        let widthFrac = max(rightFrac - leftFrac, 0)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemBackground))
                            Capsule().fill(sleepAccent)
                                .frame(width: max(geo.size.width * widthFrac, widthFrac > 0 ? 4 : 0))
                                .offset(x: geo.size.width * leftFrac)
                        }
                    }
                    .frame(height: 12)
                    .clipShape(Capsule())
                    Text(String(format: "%.1fh", night.asleepHours))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            HStack {
                Text("21:00").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("03:00").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("09:00").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.leading, 28)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 睡眠 & 恢复关联

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("睡眠 & 恢复关联").font(.headline)
            ForEach(vm.sleepInsights) { insight in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: insight.icon)
                        .font(.title3)
                        .foregroundStyle(tint(insight.tint))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(insight.title).font(.subheadline.bold())
                        Text(insight.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 工具

    private var sleepAccent: Color { Color(sleepColorName: "sleepCore") }

    private func tint(_ level: LocalTip.TipLevel) -> Color {
        switch level {
        case .good: return .green
        case .notice: return .orange
        case .warning: return .red
        }
    }

    private func hm(_ mins: Double) -> String {
        let total = max(Int(mins.rounded()), 0)
        let h = total / 60, m = total % 60
        if h > 0 { return m > 0 ? "\(h)时\(m)分" : "\(h)时" }
        return "\(m)分"
    }

    private func bedDeltaText(_ min: Int) -> String {
        if abs(min) < 3 { return "持平" }
        return min < 0 ? "早 \(abs(min)) 分" : "晚 \(min) 分"
    }

    private func bedTone(_ min: Int) -> Color {
        if abs(min) < 3 { return .primary }
        return min < 0 ? .green : .orange
    }

    private func amountDeltaText(_ min: Int, more: String, less: String) -> String {
        if abs(min) < 3 { return "持平" }
        return min > 0 ? "\(more) \(min) 分" : "\(less) \(abs(min)) 分"
    }

    private func amountTone(_ min: Int) -> Color {
        if abs(min) < 3 { return .primary }
        return min > 0 ? .green : .orange
    }
}

// MARK: - 简化 hypnogram

private struct HypnogramView: View {
    let night: SleepNight

    private let rows: [SleepStage] = [.awake, .rem, .core, .deep]

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let span = max(night.wake.timeIntervalSince(night.inBed), 1)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.tertiarySystemBackground))
                    // 行参考线
                    ForEach(0..<rows.count, id: \.self) { i in
                        let y = geo.size.height * (CGFloat(i) + 0.5) / CGFloat(rows.count)
                        Path { p in
                            p.move(to: CGPoint(x: 36, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width - 8, y: y))
                        }
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    }
                    // Y 轴标签
                    VStack(spacing: 0) {
                        ForEach(rows, id: \.self) { stage in
                            Text(shortName(stage))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .frame(width: 30, height: geo.size.height / CGFloat(rows.count))
                        }
                    }
                    .frame(width: 30, alignment: .leading)
                    .padding(.leading, 4)

                    // 段
                    ForEach(night.segments) { seg in
                        let row = rows.firstIndex(of: seg.stage) ?? 2
                        let x0 = 36 + (seg.start.timeIntervalSince(night.inBed) / span) * (geo.size.width - 44)
                        let w = max((seg.end.timeIntervalSince(seg.start) / span) * (geo.size.width - 44), 2)
                        let rowH = geo.size.height / CGFloat(rows.count)
                        let y = CGFloat(row) * rowH + 4
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(sleepColorName: seg.stage.colorName))
                            .frame(width: w, height: max(rowH - 8, 6))
                            .offset(x: x0, y: y)
                    }
                }
            }
            .frame(height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack {
                Text(night.inBed.timeShort)
                Spacer()
                Text(midLabel)
                Spacer()
                Text(night.wake.timeShort)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    private var midLabel: String {
        let mid = night.inBed.addingTimeInterval(night.wake.timeIntervalSince(night.inBed) / 2)
        return mid.timeShort
    }

    private func shortName(_ stage: SleepStage) -> String {
        switch stage {
        case .awake: return "清醒"
        case .rem: return "REM"
        case .core: return "核心"
        case .deep: return "深睡"
        }
    }
}
