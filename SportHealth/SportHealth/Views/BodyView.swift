import SwiftUI
import Charts

struct BodyView: View {
    @Environment(HealthViewModel.self) private var vm
    @State private var trendRange: BodyTrendRange = .days30

    private var body_: BodyProfile { vm.bodyProfile }
    private var recovery: RecoveryBaseline { vm.recoveryBaseline }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    trendCard
                    recoveryCard
                    metabolismCard
                    if let vo2 = body_.vo2Max {
                        vo2Card(vo2)
                    }
                    profileCard
                    if !vm.bodyTips.isEmpty {
                        tipsCard
                    }
                    Text("身体数据来自 Apple 健康。绿段为成年人运动常用参考区间（随性别、年龄、身高调整），仅供参考，不构成医疗诊断。请在健康 App 或设备中维护身高、体重、体脂等信息。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle("身体")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(vm.bodyVerdict)
                .font(.subheadline)
                .foregroundStyle(Color.blue.opacity(0.95))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 8) {
                heroBox(body_.bmi.map { $0.oneDecimal } ?? "--",
                        "BMI" + (body_.bmiCategory.map { " · \($0.text)" } ?? ""),
                        body_.bmiCategory?.isHealthy == true ? .green : .orange,
                        range: BodyMetricRanges.bmi(value: body_.bmi),
                        metric: body_.bmi)
                heroBox(body_.weightKG.map { $0.oneDecimal } ?? "--", "体重 kg", .blue,
                        range: BodyMetricRanges.weight(heightCM: body_.heightCM, value: body_.weightKG),
                        metric: body_.weightKG)
                heroBox(body_.bodyFatPercent.map { "\($0.oneDecimal)%" } ?? "--", "体脂率", .purple,
                        range: BodyMetricRanges.bodyFat(sex: body_.biologicalSex, value: body_.bodyFatPercent),
                        metric: body_.bodyFatPercent)
            }
            rangeLegend
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var rangeLegend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Capsule().fill(Color.green.opacity(0.5)).frame(width: 16, height: 5)
                Text("参考区间")
            }
            HStack(spacing: 6) {
                Circle().fill(Color.primary).frame(width: 8, height: 8)
                Text("当前值")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func heroBox(_ value: String, _ label: String, _ color: Color,
                         range: BodyMetricRange?, metric: Double?) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.title3.bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let range {
                MetricRangeBar(value: metric, range: range)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: 体重趋势

    private var trendCard: some View {
        let weights = vm.bodyTrends.weightSeries(inDays: trendRange.rawValue)
        let wDelta = vm.bodyTrends.weightDelta(inDays: trendRange.rawValue)
        let fDelta = vm.bodyTrends.bodyFatDelta(inDays: trendRange.rawValue)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("体重 · 体脂趋势").font(.headline)
                Spacer()
                Text(trendRange.label).font(.caption).foregroundStyle(.secondary)
            }
            Picker("范围", selection: $trendRange) {
                ForEach(BodyTrendRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                deltaCell(title: "体重",
                          text: deltaText(wDelta, unit: "kg"),
                          tone: deltaTone(wDelta, lowerIsGood: true))
                deltaCell(title: "体脂",
                          text: deltaText(fDelta, unit: "%"),
                          tone: deltaTone(fDelta, lowerIsGood: true))
                deltaCell(title: "BMI",
                          text: body_.bmi.map { $0.oneDecimal } ?? "--",
                          tone: .primary)
            }

            if weights.count >= 2 {
                let domain = weightDomain(weights)
                Chart(weights) { p in
                    // 填充锚定 Y 域下界并裁剪，避免 AreaMark 画出卡片
                    AreaMark(
                        x: .value("日期", p.date),
                        yStart: .value("底", domain.lowerBound),
                        yEnd: .value("kg", min(max(p.value, domain.lowerBound), domain.upperBound))
                    )
                    .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.25), .blue.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.linear)

                    LineMark(
                        x: .value("日期", p.date),
                        y: .value("kg", p.value)
                    )
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: domain)
                .chartPlotStyle { $0.clipped() }
                .frame(height: 160)
                .clipped()
            } else {
                Text(weights.isEmpty ? "暂无体重历史记录。在「健康」App 记录体重后，这里会显示趋势。" : "体重记录不足，再积累几次即可看到趋势。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func weightDomain(_ points: [BodyMetricPoint]) -> ClosedRange<Double> {
        let vals = points.map(\.value)
        let lo = (vals.min() ?? 60) - 0.5
        let hi = (vals.max() ?? 70) + 0.5
        return lo...hi
    }

    private func deltaCell(title: String, text: String, tone: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(text).font(.subheadline.bold()).foregroundStyle(tone)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func deltaText(_ delta: Double?, unit: String) -> String {
        guard let delta else { return "—" }
        if abs(delta) < 0.05 { return "持平" }
        return String(format: "%+.1f %@", delta, unit)
    }

    private func deltaTone(_ delta: Double?, lowerIsGood: Bool) -> Color {
        guard let delta, abs(delta) >= 0.05 else { return .primary }
        let good = lowerIsGood ? delta < 0 : delta > 0
        return good ? .green : .orange
    }

    // MARK: 恢复基线

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("恢复基线").font(.headline)
                Spacer()
                Text("近7日体质").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                recoverBox(
                    value: recovery.restingHR.map { "\(Int($0))" } ?? "--",
                    label: "静息心率",
                    hint: restingHint,
                    range: BodyMetricRanges.restingHR(value: recovery.restingHR),
                    metric: recovery.restingHR
                )
                recoverBox(
                    value: recovery.hrvSDNN.map { "\(Int($0))" } ?? "--",
                    label: "HRV ms",
                    hint: hrvHint,
                    range: BodyMetricRanges.hrv(value: recovery.hrvSDNN),
                    metric: recovery.hrvSDNN
                )
                recoverBox(
                    value: recovery.averageHR7d.map { "\(Int($0))" } ?? "--",
                    label: "7日均心率",
                    hint: "次/分",
                    range: BodyMetricRanges.averageHR(value: recovery.averageHR7d),
                    metric: recovery.averageHR7d
                )
            }
            Text(vm.recoveryInsight)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var restingHint: String {
        let grade: String? = {
            guard let r = recovery.restingHR else { return nil }
            if r <= 60 { return "优秀" }
            if r <= 70 { return "良好" }
            return "偏高"
        }()
        if let d = recovery.restingHRDelta, abs(d) >= 1 {
            let delta = String(format: "%+.0f", d)
            return grade.map { "\(delta) · \($0)" } ?? delta
        }
        return grade ?? "—"
    }

    private var hrvHint: String {
        guard let hrv = recovery.hrvSDNN else { return "—" }
        return hrv >= 40 ? "较好 · 恢复好" : "关注恢复"
    }

    private func recoverBox(value: String, label: String, hint: String,
                            range: BodyMetricRange, metric: Double?) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(hint).font(.caption2).foregroundStyle(.tertiary)
            MetricRangeBar(value: metric, range: range)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 代谢

    private var metabolismCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("代谢估算").font(.headline)
                Spacer()
                Text("本地公式").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                metaBox(title: "基础代谢 BMR",
                        value: body_.estimatedBMR.map { Int($0).grouped } ?? "--",
                        unit: "kcal/天",
                        sub: "Mifflin-St Jeor",
                        range: BodyMetricRanges.bmr(body: body_, value: body_.estimatedBMR),
                        metric: body_.estimatedBMR)
                if let tdee = vm.estimatedTDEE {
                    metaBox(title: "估算消耗 TDEE",
                            value: Int(tdee.tdee).grouped,
                            unit: "kcal/天",
                            sub: "\(tdee.label) ×\(String(format: "%.2f", tdee.factor))",
                            range: BodyMetricRanges.tdee(bmr: body_.estimatedBMR, value: tdee.tdee),
                            metric: tdee.tdee)
                } else {
                    metaBox(title: "估算消耗 TDEE", value: "--", unit: "kcal/天",
                            sub: "需完善身高体重年龄",
                            range: nil, metric: nil)
                }
            }
            Text("设置里活动能量目标 \(Int(vm.energyGoal)) kcal，为日常活动消耗的一部分；达标有助于接近 TDEE 活动量。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func metaBox(title: String, value: String, unit: String, sub: String,
                         range: BodyMetricRange?, metric: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.bold())
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            Text(sub).font(.caption2).foregroundStyle(.tertiary)
            if let range {
                MetricRangeBar(value: metric, range: range, captionAlignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: VO₂ Max

    private func vo2Card(_ vo2: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("心肺适应").font(.headline)
                Spacer()
                Text("VO₂ Max").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(vo2.oneDecimal)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                Text("mL/kg·min")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            MetricRangeBar(value: vo2,
                           range: BodyMetricRanges.vo2(sex: body_.biologicalSex, age: body_.ageYears, value: vo2),
                           captionAlignment: .leading,
                           trackHeight: 6)
            Text("来自 Apple Watch 心肺适能估算。无数据时本卡不显示。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 精简档案

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("个人档案").font(.headline).padding(.bottom, 8)
            kvRow("年龄", body_.ageYears.map { "\($0) 岁" })
            kvRow("生理性别", body_.biologicalSex)
            kvRow("身高", body_.heightCM.map { "\($0.oneDecimal) cm" })
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 提示

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("身体提示").font(.headline)
            ForEach(vm.bodyTips) { tip in
                TipRow(tip: tip)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func kvRow(_ key: String, _ value: String?) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "--").fontWeight(.medium)
        }
        .font(.subheadline)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.3)
        }
    }
}

/// 绿段 = 参考区间，圆点 = 当前值（超出刻度时贴边）。
private struct MetricRangeBar: View {
    let value: Double?
    let range: BodyMetricRange
    var captionAlignment: TextAlignment = .center
    var trackHeight: CGFloat = 5

    var body: some View {
        VStack(alignment: captionAlignment == .leading ? .leading : .center, spacing: 6) {
            GeometryReader { geo in
                let inset: CGFloat = 5
                let w = max(geo.size.width - inset * 2, 1)
                let midY = geo.size.height / 2
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: w, height: trackHeight)
                        .position(x: inset + w / 2, y: midY)
                    Capsule()
                        .fill(Color.green.opacity(0.5))
                        .frame(width: max(x(range.band.upperBound, in: w) - x(range.band.lowerBound, in: w), 4),
                               height: trackHeight)
                        .position(x: inset + (x(range.band.lowerBound, in: w) + x(range.band.upperBound, in: w)) / 2,
                                  y: midY)
                    if let value {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: 9, height: 9)
                            .position(x: inset + x(value, in: w), y: midY)
                    }
                }
            }
            .frame(height: 11)
            Text(range.caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(captionAlignment)
                .minimumScaleFactor(0.8)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(range.caption)
    }

    private func x(_ v: Double, in width: CGFloat) -> CGFloat {
        let span = range.scale.upperBound - range.scale.lowerBound
        guard span > 0 else { return width / 2 }
        let t = (v - range.scale.lowerBound) / span
        return CGFloat(min(max(t, 0), 1)) * width
    }
}
