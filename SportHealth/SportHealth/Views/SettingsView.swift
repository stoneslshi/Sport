import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(HealthViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var energyGoalText = ""
    @State private var providerID = "openai"
    @State private var model = ""
    @State private var customBaseURL = ""
    @State private var customModel = ""
    @State private var apiKey = ""
    @State private var savedHint = false
    @State private var showFITImporter = false

    private var provider: LLMProvider { LLMProvider.provider(id: providerID) }

    var body: some View {
        NavigationStack {
            Form {
                Section("每日目标") {
                    HStack {
                        Label("活动能量目标", systemImage: "flame.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        TextField("400", text: $energyGoalText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("kcal").foregroundStyle(.secondary)
                    }
                    Text("步数、锻炼时长、距离等仅作展示，不设目标；目标管理只保留活动能量。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                garminImportSection

                Section("AI 服务商") {
                    Picker("服务商", selection: $providerID) {
                        ForEach(LLMProvider.presets) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    .onChange(of: providerID) { _, newID in
                        // 切换服务商时，把模型重置为该服务商的默认模型
                        let p = LLMProvider.provider(id: newID)
                        if !p.isCustom {
                            model = p.models.first ?? ""
                        }
                    }

                    if provider.isCustom {
                        LabeledContent("Base URL") {
                            TextField("https://your-api.com/v1", text: $customBaseURL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("模型名") {
                            TextField("model-name", text: $customModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                        }
                    } else {
                        Picker("模型", selection: $model) {
                            ForEach(provider.models, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }
                    }
                }

                Section {
                    SecureField("在此粘贴 API Key（保存在钥匙串）", text: $apiKey)
                } header: {
                    Text("API Key")
                } footer: {
                    if !provider.isCustom, !provider.keyURL.isEmpty {
                        Text("在 \(provider.keyURL) 申请 \(provider.name) 的 API Key，选好模型后只需在此粘贴 Key 即可使用。")
                    } else {
                        Text("填写你所用 OpenAI 兼容服务的 Base URL、模型名与 API Key。")
                    }
                }

                Section {
                    Text("所有健康数据仅在本地处理；生成 AI 建议时只发送聚合统计摘要（不含姓名等可识别信息）。API Key 存储于系统钥匙串。导入的 Garmin FIT 也只保存在本机。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("隐私说明")
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear(perform: load)
            .fileImporter(
                isPresented: $showFITImporter,
                allowedContentTypes: GarminFitImporter.allowedTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await vm.importFIT(from: urls) }
                case .failure(let error):
                    vm.fitImportMessage = error.localizedDescription
                }
            }
            .alert("已保存", isPresented: $savedHint) {
                Button("好", role: .cancel) { dismiss() }
            }
        }
    }

    private var garminImportSection: some View {
        Section {
            LabeledContent("已导入") {
                Text("\(vm.importedWorkoutCount) 场").foregroundStyle(.secondary)
            }
            Button {
                showFITImporter = true
            } label: {
                if vm.isImportingFIT {
                    ProgressView()
                } else {
                    Label("选择 FIT / ZIP 文件", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(vm.isImportingFIT)

            if let msg = vm.fitImportMessage, !msg.isEmpty {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if vm.importedWorkoutCount > 0 {
                Button("清除导入的 Garmin 记录", role: .destructive) {
                    vm.clearImportedFIT()
                }
            }
        } header: {
            Text("Garmin FIT")
        } footer: {
            Text("在 Garmin 账号「数据管理」导出数据包，或从单场活动导出原始 FIT。可直接选外层 ZIP（含嵌套 UploadedFiles_*.zip）或多个 .fit 文件。解析只在本机完成。")
        }
    }

    private func load() {
        energyGoalText = "\(Int(vm.energyGoal))"
        providerID = vm.apiProviderID
        let p = LLMProvider.provider(id: providerID)
        model = vm.apiModel.isEmpty ? (p.models.first ?? "") : vm.apiModel
        // 若已存模型不在当前服务商列表里，回退到默认模型
        if !p.isCustom, !p.models.contains(model) {
            model = p.models.first ?? ""
        }
        customBaseURL = vm.customBaseURL
        customModel = vm.customModel
        apiKey = KeychainHelper.read(key: "llm_api_key") ?? ""
    }

    private func save() {
        if let v = Double(energyGoalText), v > 0 { vm.energyGoal = v }
        vm.apiProviderID = providerID
        let p = LLMProvider.provider(id: providerID)
        if p.isCustom {
            vm.customBaseURL = customBaseURL.trimmingCharacters(in: .whitespaces)
            vm.customModel = customModel.trimmingCharacters(in: .whitespaces)
        } else {
            vm.apiModel = model
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            KeychainHelper.delete(key: "llm_api_key")
        } else {
            KeychainHelper.save(key: "llm_api_key", value: key)
        }
        savedHint = true
    }
}
