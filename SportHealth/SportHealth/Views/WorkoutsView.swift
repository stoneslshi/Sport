import SwiftUI
import HealthKit

struct WorkoutsView: View {
    @Environment(HealthViewModel.self) private var vm
    @State private var range: HealthViewModel.WorkoutRange = .week
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var customEnd = Date()
    /// 当前选中的运动类型过滤（nil = 全部）
    @State private var selectedType: HKWorkoutActivityType?
    /// 分享面板
    @State private var shareItem: ShareImageItem?
    @State private var isPreparingShare = false

    // 当前生效的起止日期
    private var effectiveStart: Date {
        if range == .custom { return min(customStart, customEnd) }
        return vm.startDate(for: range) ?? Date()
    }
    private var effectiveEnd: Date {
        range == .custom ? max(customStart, customEnd) : Date()
    }

    /// 时间范围内的全部记录（用于统计卡，不受类型过滤影响）
    private var rangeRecords: [WorkoutRecord] {
        vm.workouts(from: effectiveStart, to: effectiveEnd)
            .sorted { $0.start > $1.start }
    }

    /// 列表展示的记录（叠加类型过滤）
    private var filtered: [WorkoutRecord] {
        guard let t = selectedType else { return rangeRecords }
        return rangeRecords.filter { $0.activityType == t }
    }

    private var totalMinutes: Int { Int(rangeRecords.reduce(0) { $0 + $1.durationMinutes }) }
    private var totalKcal: Int { Int(rangeRecords.reduce(0) { $0 + $1.caloriesKcal }) }
    private var typeStats: [WorkoutTypeStat] { vm.typeStats(for: rangeRecords) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    rangePicker
                    if range == .custom { customDateCard }
                    summaryCard
                    if !typeStats.isEmpty { typeStatsSection }
                    if selectedType != nil { filterHintBar }
                    if filtered.isEmpty {
                        ContentUnavailableView(
                            selectedType == nil ? "该时间段暂无运动记录" : "该时间段没有这类运动",
                            systemImage: selectedType?.symbolName ?? "figure.run",
                            description: Text(selectedType == nil
                                              ? "换个时间范围，或去健康 App 记录一次锻炼。"
                                              : "点上方「全部」查看所有运动。"))
                            .padding(.top, 30)
                    } else {
                        ForEach(filtered) { record in
                            NavigationLink {
                                WorkoutDetailView(record: record)
                            } label: {
                                WorkoutRow(record: record)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("运动记录")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: range) { _, _ in selectedType = nil }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await prepareShare() }
                    } label: {
                        if isPreparingShare {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(rangeRecords.isEmpty || isPreparingShare)
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(image: item.image, text: item.text)
            }
        }
    }

    /// 准备汇总分享：优先 AI 趣味文案，再渲染海报。
    @MainActor
    private func prepareShare() async {
        guard !isPreparingShare, !rangeRecords.isEmpty else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        let records = rangeRecords
        let stats = typeStats
        let label = range.rawValue
        let period = "\(effectiveStart.mediumLabelCN) – \(effectiveEnd.mediumLabelCN)"
        let caption = await vm.shareSummaryCaption(
            records: records, typeStats: stats, rangeLabel: label, periodText: period)
        let image = ShareCardRenderer.renderWorkoutSummary(
            records: records, typeStats: stats, rangeLabel: label,
            periodText: period, caption: caption)
        shareItem = ShareImageItem(image: image, text: caption + " " + AppBrand.shareHashtag)
    }

    // 时间范围切换
    private var rangePicker: some View {
        Picker("时间范围", selection: $range) {
            ForEach(HealthViewModel.WorkoutRange.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // 自定义日期区间
    private var customDateCard: some View {
        VStack(spacing: 12) {
            DatePicker("开始", selection: $customStart, in: ...Date(), displayedComponents: .date)
            DatePicker("结束", selection: $customEnd, in: ...Date(), displayedComponents: .date)
        }
        .font(.subheadline)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // 汇总卡
    private var summaryCard: some View {
        VStack(spacing: 10) {
            HStack {
                summaryItem("\(rangeRecords.count)", "次数")
                summaryItem("\(totalMinutes)", "锻炼分钟")
                summaryItem("\(totalKcal.grouped)", "消耗 kcal")
            }
            Text("\(effectiveStart.mediumLabelCN) – \(effectiveEnd.mediumLabelCN)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // 类型过滤提示条
    private var filterHintBar: some View {
        HStack(spacing: 8) {
            if let t = selectedType {
                Image(systemName: t.symbolName)
                    .foregroundStyle(Color(themeName: t.tintName))
                Text("已筛选：\(t.displayName) · \(filtered.count) 次")
                    .font(.subheadline)
                Spacer()
                Button {
                    withAnimation { selectedType = nil }
                } label: {
                    Label("清除", systemImage: "xmark.circle.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    private func summaryItem(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // 按运动类型分组统计（横向滚动卡片，可点击过滤）
    private var typeStatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按运动类型统计").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(typeStats) { stat in
                        TypeStatCard(stat: stat, selected: selectedType == stat.activityType) {
                            withAnimation {
                                selectedType = (selectedType == stat.activityType) ? nil : stat.activityType
                            }
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
            if selectedType == nil {
                Text("点击卡片可只看该类运动，再点一次或点上方清除即可恢复")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 运动类型统计卡片

struct TypeStatCard: View {
    let stat: WorkoutTypeStat
    var selected: Bool = false
    var onTap: () -> Void = {}

    private var tint: Color { Color(themeName: stat.activityType.tintName) }

    private var secondaryText: String {
        if stat.totalKM > 0 {
            // 游泳用米更贴切
            if stat.activityType == .swimming {
                return "\(Int(stat.totalKM * 1000).grouped) m"
            }
            return "\(stat.totalKM.oneDecimal) km"
        }
        return "\(Int(stat.totalMinutes)) 分钟"
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: stat.activityType.symbolName)
                        .foregroundStyle(tint)
                        .frame(width: 34, height: 34)
                        .background(tint.opacity(0.15), in: Circle())
                    Text(stat.activityType.displayName).font(.subheadline.bold())
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(stat.count)").font(.title3.bold())
                    Text("次").font(.caption2).foregroundStyle(.secondary)
                }
                Text("\(Int(stat.totalKcal).grouped) kcal")
                    .font(.caption).foregroundStyle(.orange)
                Text(secondaryText)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
            .frame(width: 130, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? tint : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 单条运动记录

struct WorkoutRow: View {
    let record: WorkoutRecord

    private var subtitle: String {
        var parts = ["\(record.start.mdTimeCN)", "\(Int(record.durationMinutes)) 分钟"]
        if record.isSwimming {
            // 游泳：距离用米，配速用 /100m，与详情页保持一致
            if let km = record.distanceKM, km > 0 {
                parts.append("\(Int(km * 1000)) m")
            }
            if let pace = record.avgPacePer100m {
                parts.append("\(WorkoutRow.paceText(pace)) /100m")
            }
        } else {
            if let km = record.distanceKM, km > 0 { parts.append("\(km.oneDecimal) km") }
            if let pace = record.avgPaceMinPerKM {
                parts.append("\(WorkoutRow.paceText(pace)) /km")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// 分钟数格式化为 X'XX"
    static func paceText(_ minutes: Double) -> String {
        let m = Int(minutes)
        let s = Int((minutes - Double(m)) * 60)
        return String(format: "%d'%02d\"", m, s)
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: record.activityType.symbolName)
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .background(Color.orange.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(record.activityType.displayName).font(.subheadline.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(record.caloriesKcal))").font(.headline)
                Text("kcal").font(.caption2).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
