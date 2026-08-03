import Foundation

/// 大模型建议服务：兼容 OpenAI Chat Completions 格式的 API
/// （OpenAI、DeepSeek、通义千问、Kimi、智谱等均可用，仅需替换 BaseURL 与模型名）。
struct AIService {

    struct Config {
        var baseURL: String   // 例如 https://api.openai.com/v1
        var apiKey: String
        var model: String     // 例如 gpt-4o-mini / deepseek-chat
    }

    enum AIError: LocalizedError {
        case missingAPIKey
        case invalidBaseURL
        case httpError(status: Int, message: String)
        case emptyResponse
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "尚未配置 API Key，请前往「设置」填写。"
            case .invalidBaseURL:
                return "API 地址无效，请检查「设置」中的 Base URL。"
            case .httpError(let status, let message):
                return "请求失败（HTTP \(status)）：\(message)"
            case .emptyResponse:
                return "模型返回了空内容，请稍后重试。"
            case .decodingFailed:
                return "无法解析模型返回的数据。"
            }
        }
    }

    // MARK: - 请求结构

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct ErrorResponse: Decodable {
        struct APIError: Decodable {
            let message: String?
        }
        let error: APIError?
    }

    // MARK: - 生成建议

    static func generateAdvice(healthSummary: String, config: Config) async throws -> String {
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingAPIKey
        }

        let trimmedBase = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmedBase + "/chat/completions") else {
            throw AIError.invalidBaseURL
        }

        let systemPrompt = """
        你是一位专业的运动健康教练，擅长根据用户的 Apple 健康数据给出科学、可执行的运动与生活方式建议。
        要求：
        1. 使用简体中文回答；
        2. 先总结数据亮点，再指出需要改进的问题，最后给出未来一周具体可执行的建议（包含有氧、力量、日常活动量、休息恢复）；
        3. 引用数据中的具体数字作为依据，不要编造输入里没有的数据；
        4. 建议要考虑用户的 BMI、年龄和当前运动水平，循序渐进；
        5. 全文 400 字以内，分点呈现；
        6. 结尾加一句免责声明：建议仅供参考，不能替代医生意见。
        """

        let requestBody = ChatRequest(
            model: config.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: "以下是我的健康与运动数据汇总，请给出分析与建议：\n\n" + healthSummary)
            ],
            temperature: 0.7
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.decodingFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            let apiMessage = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error?.message
            let fallback = String(data: data.prefix(300), encoding: .utf8) ?? "未知错误"
            throw AIError.httpError(status: http.statusCode, message: apiMessage ?? fallback)
        }

        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw AIError.decodingFailed
        }
        guard let content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.emptyResponse
        }
        return content
    }

    // MARK: - 上周总结与下周建议（结构化短图文）

    /// 基于上一自然周数据，生成「关键指标 + 短评」结构，便于 App 内图文展示。
    static func generateWeeklyReview(weekSummary: String, config: Config) async throws -> WeeklyAdviceBrief {
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingAPIKey
        }

        let trimmedBase = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmedBase + "/chat/completions") else {
            throw AIError.invalidBaseURL
        }

        let systemPrompt = """
        你是「燃知」App 的运动健康教练。请根据上一自然周数据，输出**严格 JSON**（不要 Markdown、不要代码围栏、不要额外解释），用于图文周报卡片。

        JSON 结构：
        {
          "headline": "一句话点评，不超过20字",
          "vibe": "2到4字状态标签，如稳健/充能/需恢复/推进中",
          "highlights": [
            {"symbol":"run|sleep|heart|flame|trophy|bolt|body","title":"不超过10字","detail":"不超过22字，含具体数字"}
          ],
          "metricNotes": [
            {"key":"score|workouts|exercise|energy|sleep|resting|bmi","note":"不超过14字短评"}
          ],
          "actions": ["本周行动1，不超过22字","行动2","行动3"]
        }

        规则：
        1. highlights 恰好 2～3 条；actions 恰好 3 条；metricNotes 2～4 条，只点评输入里存在的指标；
        2. 只使用输入数据，禁止编造；缺数据就跳过对应 key；
        3. 文字极简、可扫读，不要长段落；
        4. 行动建议循序渐进，覆盖训练与恢复中至少两类。
        """

        let requestBody = ChatRequest(
            model: config.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: "上一自然周数据如下，请只输出 JSON：\n\n" + weekSummary)
            ],
            temperature: 0.5
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.decodingFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            let apiMessage = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error?.message
            let fallback = String(data: data.prefix(300), encoding: .utf8) ?? "未知错误"
            throw AIError.httpError(status: http.statusCode, message: apiMessage ?? fallback)
        }

        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw AIError.decodingFailed
        }
        guard let content = decoded.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.emptyResponse
        }
        guard let brief = WeeklyAdviceBrief.parse(from: content) else {
            throw AIError.decodingFailed
        }
        return brief
    }

    // MARK: - 生成分享文案（一句有意思的短文案）

    /// 根据一段运动数据摘要，生成一句适合分享到社交平台的有趣文案。
    /// 失败时抛错，由调用方回退到本地文案。
    static func generateShareCaption(dataSummary: String, config: Config) async throws -> String {
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.missingAPIKey
        }
        let trimmedBase = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmedBase + "/chat/completions") else {
            throw AIError.invalidBaseURL
        }

        let systemPrompt = """
        你是一个热爱运动的社交达人。用户会给你单次运动，或一段时间的运动汇总数据。
        请生成一句用于晒到朋友圈的中文分享文案。要求：
        1. 只输出一句话，32 字以内，不要换行、不要引号、不要解释；
        2. 抓住一个亮点：次数、主项运动、累计距离、消耗或坚持感；语气自然有趣，像朋友随口说的；
        3. 最多 1 个 emoji，也可以不要；
        4. 不要像广告，不要罗列多个数字，突出一个印象点即可。
        """

        let requestBody = ChatRequest(
            model: config.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: dataSummary)
            ],
            temperature: 0.95
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AIError.emptyResponse
        }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = decoded.choices.first?.message.content?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw AIError.emptyResponse
        }
        // 去掉可能出现的首尾引号
        return content.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
    }
}
