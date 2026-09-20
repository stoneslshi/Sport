import Foundation

/// 单次运动的短结构点评（图文卡片，不成长文）
struct WorkoutCoachBrief: Codable, Equatable {
    var vibe: String
    var verdict: String
    var facts: [WorkoutCoachFact]
    var actions: [String]

    static func parse(from raw: String) -> WorkoutCoachBrief? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = extractJSONData(from: trimmed) else { return nil }
        return try? JSONDecoder().decode(WorkoutCoachBrief.self, from: data)
    }

    private static func extractJSONData(from text: String) -> Data? {
        if let data = text.data(using: .utf8),
           (try? JSONDecoder().decode(WorkoutCoachBrief.self, from: data)) != nil {
            return data
        }
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"),
           start < end {
            let slice = String(text[start...end])
            return slice.data(using: .utf8)
        }
        return nil
    }
}

struct WorkoutCoachFact: Codable, Equatable, Identifiable {
    var label: String
    var value: String
    var id: String { label + value }
}

/// 本场点评缓存记录
struct WorkoutCoachRecord: Codable, Equatable {
    let workoutID: UUID
    let createdAt: Date
    let brief: WorkoutCoachBrief
}
