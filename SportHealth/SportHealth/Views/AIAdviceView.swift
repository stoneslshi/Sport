import SwiftUI

struct AIAdviceView: View {
    @Environment(HealthViewModel.self) private var vm
    @State private var showSettings = false
    @State private var instantExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    // 1. 唯一主卡：上周周报（摘要，详情进内页）
                    weeklyReviewCard

                    if let error = vm.weeklyAdviceError {
                        adviceErrorBanner(error)
                    }

                    // 2. 本地轻提示（贴近周报，次要但仍可见）
                    localTipsCard

                    // 3. 近况建议：普通白卡，不与周报抢 Hero
                    instantAdviceCard

                    if let error = vm.aiError {
                        adviceErrorBanner(error)
                    }

                    if vm.isAILoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在生成近况建议…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else if !vm.aiAdvice.isEmpty, instantExpanded {
                        adviceCard
                    }

                    if !vm.hasAPIKey {
                        Text("尚未配置 API Key：点右上角设置填写后，即可自动/手动生成周报与近况建议。")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("建议")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task {
                await vm.prepareWeeklyAdviceOnAppear()
                // 已有近况建议时默认展开结果
                if !vm.aiAdvice.isEmpty { instantExpanded = true }
            }
        }
    }

    private func adviceErrorBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 上周周报（紧凑主卡）

    private var weeklyReviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("上周周报", systemImage: "calendar.badge.clock")
                    .font(.headline)
                Spacer()
                NavigationLink {
                    WeeklyAdviceHistoryView()
                } label: {
                    Text("历史")
                        .font(.caption.weight(.semibold))
                }
                .disabled(vm.weeklyAdviceHistory.isEmpty)
            }

            Text(weekSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            if vm.isWeeklyAdviceLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在生成上周周报…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            } else if let record = vm.weeklyAdvice {
                weeklyCompactSummary(record)
            } else {
                weeklyEmptyState
            }

            // 次要操作：生成用主按钮；已有周报时降为边框按钮
            Group {
                if vm.weeklyAdvice == nil {
                    Button {
                        Task { await vm.requestWeeklyReview(force: true) }
                    } label: {
                        Label("生成上周周报", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        Task { await vm.requestWeeklyReview(force: true) }
                    } label: {
                        Label("重新生成上周周报", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .tint(.orange)
            .disabled(vm.isWeeklyAdviceLoading || !vm.hasAPIKey)

            if vm.hasAPIKey, CalendarWeekHelper.isMonday(), vm.weeklyAdvice == nil, !vm.isWeeklyAdviceLoading {
                Text("周一首次打开会自动生成。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [.orange.opacity(0.18), Color(.secondarySystemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20)
        )
    }

    private var weekSubtitle: String {
        if let last = CalendarWeekHelper.lastCompletedWeek() {
            let df = DateFormatter()
            df.locale = Locale(identifier: "zh_CN")
            df.dateFormat = "M月d日"
            let endDay = Calendar.current.date(byAdding: .day, value: -1, to: last.end) ?? last.end
            return "\(df.string(from: last.start)) – \(df.string(from: endDay))"
        }
        return "上一自然周回顾"
    }

    private func weeklyCompactSummary(_ record: WeeklyAdviceRecord) -> some View {
        let brief = record.displayBrief
        let snap = record.snapshot
        return NavigationLink {
            WeeklyAdviceDetailView(record: record)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(brief.vibe)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                    Text(brief.headline)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("训练 \(snap.workoutCount) 次 · \(Int(snap.totalExerciseMin)) 分钟")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                VStack(spacing: 2) {
                    Text("\(snap.activityScore)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                    Text("评分")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.tertiarySystemBackground).opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var weeklyEmptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.image")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            Text("结合上周运动、睡眠与身体数据，生成一份可扫读的图文周报。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 本地提示

    private var localTipsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今日提示").font(.headline)
            if vm.localTips.isEmpty {
                Text("加载健康数据后，这里会给出几条规则提示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.localTips.prefix(3)) { TipRow(tip: $0) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 近况建议（次级）

    private var instantAdviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("近况建议", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if !vm.aiAdvice.isEmpty {
                    Button(instantExpanded ? "收起" : "展开") {
                        withAnimation(.easeInOut(duration: 0.2)) { instantExpanded.toggle() }
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            Text("基于近 7 / 30 天活动，随时问一版可执行建议。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                instantExpanded = true
                Task { await vm.requestAIAdvice() }
            } label: {
                Label(vm.aiAdvice.isEmpty ? "生成近况建议" : "重新生成近况建议",
                      systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(vm.isAILoading || !vm.hasAPIKey)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var adviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("近况分析", systemImage: "text.bubble.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            MarkdownText(markdown: vm.aiAdvice)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - 图文周报卡片（摘要）

struct WeeklyAdviceRichCard: View {
    let record: WeeklyAdviceRecord
    var showNotes: Bool = false

    private var snap: WeeklyAdviceSnapshot { record.snapshot }
    private var brief: WeeklyAdviceBrief { record.displayBrief }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(brief.vibe)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                    Text(brief.headline)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(spacing: 2) {
                    Text("\(snap.activityScore)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                    Text("评分").font(.caption2).foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                metricTile(key: "workouts", icon: "figure.run", tint: .orange,
                           value: "\(snap.workoutCount)", label: "训练次数")
                metricTile(key: "exercise", icon: "timer", tint: .yellow,
                           value: "\(Int(snap.totalExerciseMin))", label: "锻炼分钟")
                metricTile(key: "energy", icon: "flame.fill", tint: .red,
                           value: "\(Int(snap.totalEnergyKcal))", label: "活动能量")
                metricTile(key: "sleep", icon: "bed.double.fill", tint: .indigo,
                           value: snap.avgSleepHours.map { String(format: "%.1fh", $0) } ?? "--",
                           label: "均睡眠")
            }

            if !snap.topWorkoutTypes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("运动构成").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(snap.topWorkoutTypes.prefix(3)) { item in
                        let maxC = max(snap.topWorkoutTypes.first?.count ?? 1, 1)
                        HStack(spacing: 8) {
                            Text(item.name)
                                .font(.caption)
                                .frame(width: 56, alignment: .leading)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color(.tertiarySystemFill))
                                    Capsule()
                                        .fill(Color.orange.opacity(0.85))
                                        .frame(width: max(8, geo.size.width * CGFloat(item.count) / CGFloat(maxC)))
                                }
                            }
                            .frame(height: 8)
                            Text("\(item.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                        }
                    }
                }
                .padding(12)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 8) {
                miniChip(title: "评分", value: "\(snap.activityScore)", note: brief.metricNotes.note(for: "score"))
                if let bmi = snap.bmi {
                    miniChip(title: "BMI", value: String(format: "%.1f", bmi),
                             note: brief.metricNotes.note(for: "bmi"))
                }
                if let hr = snap.restingHR {
                    miniChip(title: "静息", value: "\(Int(hr))",
                             note: brief.metricNotes.note(for: "resting"))
                }
                if let good = snap.goodSleepNights, let n = snap.sleepNightCount, n > 0 {
                    miniChip(title: "睡够", value: "\(good)/\(n)", note: nil)
                }
            }
        }
    }

    private func metricTile(key: String, icon: String, tint: Color, value: String, label: String) -> some View {
        let note = showNotes ? brief.metricNotes.note(for: key) : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).font(.headline.monospacedDigit())
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func miniChip(title: String, value: String, note: String?) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.caption.bold().monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
            if showNotes, let note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 完整周报详情（图文为主）

struct WeeklyAdviceDetailView: View {
    @Environment(HealthViewModel.self) private var vm
    let record: WeeklyAdviceRecord

    @State private var shareItem: ShareImageItem?
    @State private var isPreparingShare = false

    private var brief: WeeklyAdviceBrief { record.displayBrief }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WeeklyAdviceRichCard(record: record, showNotes: true)

                if !brief.highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("关键亮点", systemImage: "sparkles")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        ForEach(brief.highlights) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.systemImage)
                                    .font(.title3)
                                    .foregroundStyle(Color(themeName: item.tint))
                                    .frame(width: 40, height: 40)
                                    .background(Color(themeName: item.tint).opacity(0.14),
                                                in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.subheadline.weight(.semibold))
                                    Text(item.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                }

                if !brief.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("本周行动", systemImage: "checklist")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        ForEach(Array(brief.actions.prefix(3).enumerated()), id: \.offset) { i, act in
                            HStack(alignment: .top, spacing: 12) {
                                Text("\(i + 1)")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(Color.orange, in: Circle())
                                Text(act)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                }

                Text("建议仅供参考，不能替代医生意见。生成于 \(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(AppBrand.name)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
        .navigationTitle(record.dateRangeText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await prepareShare() }
                } label: {
                    if isPreparingShare { ProgressView() }
                    else { Image(systemName: "square.and.arrow.up") }
                }
                .disabled(isPreparingShare)
                .accessibilityLabel("分享周报")
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(image: item.image, text: item.text)
        }
    }

    @MainActor
    private func prepareShare() async {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        let caption = await vm.weeklyAdviceShareCaption(for: record)
        let image = ShareCardRenderer.renderWeeklyAdvice(record: record, caption: caption)
        shareItem = ShareImageItem(image: image, text: caption)
    }
}

// MARK: - 历史列表

struct WeeklyAdviceHistoryView: View {
    @Environment(HealthViewModel.self) private var vm

    var body: some View {
        List {
            if vm.weeklyAdviceHistory.isEmpty {
                ContentUnavailableView(
                    "暂无历史周报",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("生成上周建议后，会按周保存在这里。")
                )
            } else {
                ForEach(vm.weeklyAdviceHistory) { record in
                    NavigationLink {
                        WeeklyAdviceDetailView(record: record)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.orange.opacity(0.14))
                                    .frame(width: 48, height: 48)
                                Image(systemName: "doc.text.image")
                                    .foregroundStyle(.orange)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.dateRangeText)
                                    .font(.subheadline.weight(.semibold))
                                Text("训练 \(record.snapshot.workoutCount) 次 · 评分 \(record.snapshot.activityScore)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("历史周报")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.refreshWeeklyAdviceFromStore() }
    }
}
