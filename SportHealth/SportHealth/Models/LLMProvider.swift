import Foundation

/// 预置的大模型服务商（均兼容 OpenAI Chat Completions 格式）。
/// 用户在设置里选择服务商与模型后，只需填写对应的 API Key 即可。
struct LLMProvider: Identifiable, Hashable {
    let id: String          // 稳定标识（存 UserDefaults）
    let name: String        // 展示名
    let baseURL: String     // OpenAI 兼容的 Base URL
    let models: [String]    // 该服务商可选模型列表
    let keyURL: String      // 获取 API Key 的官网地址（提示用）
    let isCustom: Bool       // 自定义服务商（Base URL / 模型由用户手填）

    init(id: String, name: String, baseURL: String, models: [String],
         keyURL: String = "", isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.keyURL = keyURL
        self.isCustom = isCustom
    }

    /// 预置服务商列表
    static let presets: [LLMProvider] = [
        LLMProvider(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            models: ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1"],
            keyURL: "platform.openai.com"
        ),
        LLMProvider(
            id: "deepseek",
            name: "DeepSeek 深度求索",
            baseURL: "https://api.deepseek.com/v1",
            models: ["deepseek-v4-flash", "deepseek-v4-pro"],
            keyURL: "platform.deepseek.com"
        ),
        LLMProvider(
            id: "qwen",
            name: "通义千问 Qwen",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            models: ["qwen-plus", "qwen-max", "qwen-turbo"],
            keyURL: "bailian.console.aliyun.com"
        ),
        LLMProvider(
            id: "kimi",
            name: "Kimi 月之暗面",
            baseURL: "https://api.moonshot.cn/v1",
            models: ["moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"],
            keyURL: "platform.moonshot.cn"
        ),
        LLMProvider(
            id: "zhipu",
            name: "智谱 GLM",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            models: ["glm-4-flash", "glm-4-air", "glm-4-plus"],
            keyURL: "bigmodel.cn"
        ),
        LLMProvider(
            id: "custom",
            name: "自定义（OpenAI 兼容）",
            baseURL: "",
            models: [],
            keyURL: "",
            isCustom: true
        )
    ]

    static func provider(id: String) -> LLMProvider {
        presets.first { $0.id == id } ?? presets[0]
    }
}
