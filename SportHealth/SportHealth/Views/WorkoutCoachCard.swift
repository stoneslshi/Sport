import SwiftUI

/// 运动详情「本场点评」：首次打开自动请求，按场次缓存。
struct WorkoutCoachCard: View {
    @Environment(HealthViewModel.self) private var vm
    let record: WorkoutRecord
    let detailed: WorkoutRecord
    var isDetailReady: Bool
    var peerAvgPace: Double?

    @State private var brief: WorkoutCoachBrief?
    @State private var fromCache = false
    @State private var isRequesting = false
    @State private var errorText: String?
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("本场点评", systemImage: "sparkles")
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let brief {
                resultBody(brief)
            } else if !vm.hasAPIKey {
                Text("设置 API Key 后，打开详情会自动生成本场点评。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("去设置") { showSettings = true }
                    .font(.subheadline.weight(.semibold))
            } else if let errorText {
                Text(errorText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("重试") { Task { await refresh() } }
                    .font(.subheadline.weight(.semibold))
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在分析本场…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.orange.opacity(0.16), Color(.secondarySystemBackground)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .task {
            if let cached = WorkoutCoachStore.shared.record(for: record.id) {
                brief = cached.brief
                fromCache = true
            }
        }
        .task(id: isDetailReady) {
            await loadIfNeeded()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private var subtitle: String {
        if brief != nil {
            return "结合本场数据的分析与下次建议。ⓘ 仍是指标说明。"
        }
        return "结合本场数据生成分析和建议，结果会记住"
    }

    @ViewBuilder
    private func resultBody(_ brief: WorkoutCoachBrief) -> some View {
        Text(brief.vibe)
            .font(.caption.weight(.bold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.16), in: Capsule())

        Text(brief.verdict)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)

        if !brief.facts.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                ForEach(brief.facts) { fact in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(fact.value)
                            .font(.subheadline.weight(.semibold))
                            .minimumScaleFactor(0.8)
                            .lineLimit(2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }

        if !brief.actions.isEmpty {
            Text("下次可以")
                .font(.caption.weight(.bold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(brief.actions.enumerated()), id: \.offset) { i, action in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(action)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        HStack {
            Text(fromCache ? "已缓存 · 下次打开不再请求" : "刚刚生成 · 已记住本场")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("重新分析") {
                Task { await refresh() }
            }
            .font(.caption.weight(.semibold))
            .disabled(isRequesting || !vm.hasAPIKey || !isDetailReady)
        }

        Text("建议仅供参考，不构成医疗诊断。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private func loadIfNeeded() async {
        if brief != nil { return }
        if let cached = WorkoutCoachStore.shared.record(for: record.id) {
            brief = cached.brief
            fromCache = true
            return
        }
        guard vm.hasAPIKey else { return }
        guard isDetailReady else { return }
        await request()
    }

    private func refresh() async {
        WorkoutCoachStore.shared.remove(id: record.id)
        brief = nil
        fromCache = false
        errorText = nil
        await request()
    }

    private func request() async {
        guard !isRequesting else { return }
        guard vm.hasAPIKey else { return }
        isRequesting = true
        errorText = nil
        defer { isRequesting = false }

        let summary = AnalysisEngine.workoutSessionSummary(
            record: record,
            detailed: detailed,
            peerAvgPace: peerAvgPace
        )
        let config = AIService.Config(
            baseURL: vm.effectiveBaseURL,
            apiKey: KeychainHelper.read(key: "llm_api_key") ?? "",
            model: vm.effectiveModel
        )
        do {
            let result = try await AIService.generateWorkoutCoach(sessionSummary: summary, config: config)
            try Task.checkCancellation()
            let saved = WorkoutCoachRecord(workoutID: record.id, createdAt: Date(), brief: result)
            WorkoutCoachStore.shared.save(saved)
            brief = result
            fromCache = false
        } catch is CancellationError {
            return
        } catch {
            errorText = error.localizedDescription
        }
    }
}
