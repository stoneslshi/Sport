import Foundation

/// 上周 AI 建议历史：JSON 落盘到 Application Support
final class AdviceHistoryStore {
    static let shared = AdviceHistoryStore()

    private let fileName = "weekly_advice_history.json"
    private let maxRecords = 52
    private let queue = DispatchQueue(label: "com.workbuddy.SportHealth.adviceHistory")

    private var cache: [WeeklyAdviceRecord]?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("SportHealth", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(fileName)
    }

    func allRecords() -> [WeeklyAdviceRecord] {
        queue.sync {
            loadIfNeeded()
                .sorted { $0.weekStart > $1.weekStart }
        }
    }

    func record(weekID: String) -> WeeklyAdviceRecord? {
        queue.sync {
            loadIfNeeded().first { $0.weekID == weekID }
        }
    }

    func has(weekID: String) -> Bool {
        record(weekID: weekID) != nil
    }

    func latest() -> WeeklyAdviceRecord? {
        allRecords().first
    }

    @discardableResult
    func save(_ record: WeeklyAdviceRecord) -> [WeeklyAdviceRecord] {
        queue.sync {
            var list = loadIfNeeded().filter { $0.weekID != record.weekID }
            list.append(record)
            list.sort { $0.weekStart > $1.weekStart }
            if list.count > maxRecords {
                list = Array(list.prefix(maxRecords))
            }
            cache = list
            persist(list)
            return list
        }
    }

    private func loadIfNeeded() -> [WeeklyAdviceRecord] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([WeeklyAdviceRecord].self, from: data) else {
            cache = []
            return []
        }
        cache = decoded
        return decoded
    }

    private func persist(_ list: [WeeklyAdviceRecord]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
