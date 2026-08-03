import SwiftUI
import Charts

struct DashboardView: View {
    @Environment(HealthViewModel.self) private var vm
    @State private var showSettings = false
    @State private var showTrends = false
    @State private var range: TrendRange = .week

    enum TrendRange: String, CaseIterable, Identifiable {
        case week = "近7天"
        case month = "近30天"
        var id: String { rawValue }
    }

    private var trendDays: [DailyActivity] {
        range == .week ? vm.last7Days : vm.last30Days
    }

    var body: some View {
        NavigationStack {
            Group {
                if !vm.hasRequestedAuth {
                    connectPrompt
                } else {
                    dashboardContent
                }
            }
            .navigationTitle(AppBrand.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .task {
                if !vm.hasRequestedAuth {
                    await vm.loadAll()
                }
            }
            .refreshable {
                await vm.refresh()
            }
        }
    }

    private var connectPrompt: some View {
        ContentUnavailableView {
            Label("连接 Apple 健康", systemImage: "heart.text.square.fill")
        } description: {
            Text("授权后，应用将读取您的运动与健康数据，在本地完成统计分析，并可结合大模型生成个性化建议。\n数据不会上传到任何服务器（AI 建议仅发送聚合统计摘要）。")
        } actions: {
            Button("授权并加载数据") {
                Task { await vm.loadAll() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: 主内容 · 今日决策页

    private var dashboardContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let error = vm.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }

                heroCard
                priorityTipsCard
                if !vm.todayWorkouts.isEmpty {
                    todayWorkoutsCard
                }
                lastNightCard
                weekInsightCard
            }
            .padding()
        }
        .overlay {
            if vm.isLoading && vm.today == nil {
                ProgressView("正在读取健康数据…")
            }
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                ZStack {
                    ProgressRing(progress: Double(vm.todayScore) / 100.0, color: scoreColor, lineWidth: 12)
                        .frame(width: 104, height: 104)
                    VStack(spacing: 2) {
                        Text("\(vm.todayScore)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("活动评分").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(Date().fullLabelCN)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(scoreComment)
                        .font(.headline)
                    Text(statusChip)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 0)
            }

            Text(vm.dashboardVerdict)
                .font(.subheadline)
                .foregroundStyle(Color.green.opacity(0.95))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                heroMetric(title: "活动能量",
                           value: "\(Int(vm.today?.activeEnergyKcal ?? 0))",
                           unit: "/ \(Int(vm.energyGoal)) kcal",
                           progress: vm.energyProgress,
                           color: .orange)
                heroMetric(title: "锻炼时长",
                           value: "\(Int(vm.today?.exerciseMinutes ?? 0))",
                           unit: "/ 30 分钟",
                           progress: vm.exerciseProgress,
                           color: .blue)
                heroMetric(title: "步数",
                           value: Int(vm.today?.steps ?? 0).grouped,
                           unit: "步",
                           progress: nil,
                           color: .green)
                heroMetric(title: "距离",
                           value: (vm.today?.distanceKM ?? 0).oneDecimal,
                           unit: "km",
                           progress: nil,
                           color: .purple)
            }

            Button {
                vm.selectedTab = .advice
            } label: {
                Text(ctaTitle)
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.energyGapKcal > 0 ? .orange : .green)

            Text("评分构成：能量 60% · 锻炼时长 40% · 步数仅展示不计入目标")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusChip: String {
        let energyPct = Int((min(vm.energyProgress, 1) * 100).rounded())
        let exerciseDone = (vm.today?.exerciseMinutes ?? 0) >= 30
        return "能量 \(energyPct)% · 锻炼\(exerciseDone ? "已达标" : "未达标")"
    }

    private var ctaTitle: String {
        if vm.energyGapKcal > 0 {
            return "还差 \(vm.energyGapKcal) kcal · 生成本日建议"
        }
        return "今日目标已完成 · 查看建议"
    }

    private func heroMetric(title: String, value: String, unit: String,
                            progress: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline.bold())
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var scoreColor: Color {
        switch vm.todayScore {
        case 80...: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }

    private var scoreComment: String {
        switch vm.todayScore {
        case 90...: return "非常棒，今天活力满分！"
        case 70..<90: return "状态不错，再推一把"
        case 40..<70: return "还可以，再动一动更好"
        default: return "今天活动偏少，起来走走吧"
        }
    }

    // MARK: 今日提示 Top 2

    private var priorityTipsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日提示").font(.headline)
                Spacer()
                Text("优先行动").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(vm.priorityTips) { tip in
                Button {
                    if let dest = tip.destination {
                        vm.selectedTab = dest
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        TipRow(tip: tip)
                        Spacer(minLength: 0)
                        if tip.destination != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 6)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 今日运动（无则不渲染）

    private var todayWorkoutsCard: some View {
        let items = vm.todayWorkouts
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日运动").font(.headline)
                Spacer()
                let min = Int(items.reduce(0) { $0 + $1.durationMinutes })
                let kcal = Int(items.reduce(0) { $0 + $1.caloriesKcal })
                Text("\(items.count) 次 · \(min) 分钟 · \(kcal) kcal")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items) { record in
                NavigationLink {
                    WorkoutDetailView(record: record)
                } label: {
                    TodayWorkoutRow(record: record)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 昨夜睡眠 + 影响今日

    @ViewBuilder
    private var lastNightCard: some View {
        if let n = vm.lastNight {
            Button {
                vm.selectedTab = .sleep
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("昨夜睡眠").font(.headline)
                        Spacer()
                        Text("影响今日强度")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 14) {
                        Image(systemName: "moon.stars.fill")
                            .font(.title2)
                            .foregroundStyle(Color(sleepColorName: "sleepCore"))
                            .frame(width: 46, height: 46)
                            .background(Color(sleepColorName: "sleepCore").opacity(0.18),
                                        in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sleepHM(n.asleepMin)).font(.title2.bold())
                            Text("深睡 \(sleepHM(n.deepMin)) · \(n.inBed.timeShort) 入睡")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(spacing: 2) {
                            Text("\(vm.sleepSummary.lastNightScore)")
                                .font(.title3.bold())
                                .foregroundStyle(Color(sleepColorName: "sleepCore"))
                            Text("睡眠分").font(.caption2).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if let impact = vm.sleepImpactText {
                        Text(impact)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 近7日洞察（可展开趋势）

    private var weekInsightCard: some View {
        let week = vm.weekSummary
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("近 7 日洞察").font(.headline)
                Spacer()
                if let trend = week.energyTrendPercent {
                    Label("\(trend >= 0 ? "+" : "")\(Int(trend))%",
                          systemImage: trend >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.subheadline.bold())
                        .foregroundStyle(trend >= 0 ? .green : .red)
                }
            }

            Text(vm.weekInsight)
                .font(.subheadline.weight(.semibold))

            Text("日均 \(Int(week.avgSteps).grouped) 步 · 锻炼 \(Int(week.totalExerciseMin)) 分钟 · 总 \(week.totalDistanceKM.oneDecimal) km")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showTrends.toggle()
                }
            } label: {
                HStack {
                    Text(showTrends ? "收起趋势图表" : "查看趋势图表")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: showTrends ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.orange)
                .padding(.top, 4)
            }
            .buttonStyle(.plain)

            if showTrends {
                Picker("范围", selection: $range) {
                    ForEach(TrendRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if trendDays.isEmpty {
                    Text("暂无趋势数据")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    stepsChartCard
                    energyChartCard
                    heartZoneCard
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var stepsChartCard: some View {
        ChartCard(title: "步数", subtitle: "日均 \(Int(vm.currentAvgSteps(trendDays)).grouped) 步", color: .green) {
            Chart(trendDays) { day in
                BarMark(x: .value("日期", day.date, unit: .day),
                        y: .value("步数", day.steps))
                    .foregroundStyle(day.isToday ? Color.green : Color.green.opacity(0.5))
                    .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : 5)) { _ in
                    AxisValueLabel(format: .dateTime.month().day())
                }
            }
            .frame(height: 160)
        }
    }

    private var energyChartCard: some View {
        ChartCard(title: "活动能量", subtitle: "目标 \(Int(vm.energyGoal)) kcal/天", color: .orange) {
            Chart {
                ForEach(trendDays) { day in
                    LineMark(x: .value("日期", day.date, unit: .day),
                             y: .value("能量", day.activeEnergyKcal))
                        .foregroundStyle(Color.orange)
                        .interpolationMethod(.catmullRom)
                    AreaMark(x: .value("日期", day.date, unit: .day),
                             y: .value("能量", day.activeEnergyKcal))
                        .foregroundStyle(LinearGradient(colors: [.orange.opacity(0.3), .clear],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                }
                RuleMark(y: .value("目标", vm.energyGoal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : 5)) { _ in
                    AxisValueLabel(format: .dateTime.month().day())
                }
            }
            .frame(height: 160)
        }
    }

    private var heartZoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("心率概览").font(.headline)
            HStack(spacing: 0) {
                heartItem(vm.heartMetrics.restingHR, "静息", "次/分")
                heartItem(vm.heartMetrics.averageHR7d, "7天均值", "次/分")
                heartItem(vm.heartMetrics.hrvSDNN, "HRV", "ms")
            }
        }
        .padding(.top, 4)
    }

    private func heartItem(_ value: Double?, _ label: String, _ unit: String) -> some View {
        VStack(spacing: 4) {
            Text(value.map { "\(Int($0))" } ?? "--")
                .font(.title3.bold())
                .foregroundStyle(.pink)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(unit).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func sleepHM(_ mins: Double) -> String {
        let total = max(Int(mins.rounded()), 0)
        let h = total / 60, m = total % 60
        if h > 0 { return m > 0 ? "\(h)时\(m)分" : "\(h)时" }
        return "\(m)分"
    }
}

// MARK: - 组件

struct ProgressRing: View {
    var progress: Double
    var color: Color
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: progress)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let color: Color
    var progress: Double?
    var goalText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.title2.bold())
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            if let progress {
                ProgressView(value: min(progress, 1.0)).tint(color)
            }
            Text(goalText).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct WeekStatItem: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.headline)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TodayWorkoutRow: View {
    let record: WorkoutRecord

    private var tint: Color { Color(themeName: record.activityType.tintName) }

    private var subtitle: String {
        var parts = [record.start.timeShort, "\(Int(record.durationMinutes)) 分钟"]
        if let km = record.distanceKM, km > 0 { parts.append("\(km.oneDecimal) km") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.activityType.symbolName)
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(record.activityType.displayName).font(.subheadline.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(record.caloriesKcal)) kcal")
                .font(.caption).foregroundStyle(.orange)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct TipRow: View {
    let tip: LocalTip

    private var tintColor: Color {
        switch tip.tint {
        case .good: return .green
        case .notice: return .orange
        case .warning: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tip.icon)
                .font(.title3)
                .foregroundStyle(tintColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(tip.title).font(.subheadline.bold())
                Text(tip.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    let subtitle: String
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(.vertical, 4)
    }
}

extension HealthViewModel {
    func currentAvgSteps(_ days: [DailyActivity]) -> Double {
        guard !days.isEmpty else { return 0 }
        return days.reduce(0) { $0 + $1.steps } / Double(days.count)
    }
}
