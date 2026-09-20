import Foundation

/// 本场 AI 点评：按运动 ID 落盘，再打开不重复请求。
final class WorkoutCoachStore {
    static let shared = WorkoutCoachStore()

    private let fileName = "workout_coach_cache.json"
    private let maxRecords = 80
    private let queue = DispatchQueue(label: "com.workbuddy.SportHealth.workoutCoach")
    private var cache: [WorkoutCoachRecord]?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("SportHealth", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(fileName)
    }

    func record(for id: UUID) -> WorkoutCoachRecord? {
        queue.sync {
            loadIfNeeded().first { $0.workoutID == id }
        }
    }

    func save(_ record: WorkoutCoachRecord) {
        queue.sync {
            var list = loadIfNeeded().filter { $0.workoutID != record.workoutID }
            list.append(record)
            list.sort { $0.createdAt > $1.createdAt }
            if list.count > maxRecords {
                list = Array(list.prefix(maxRecords))
            }
            cache = list
            persist(list)
        }
    }

    func remove(id: UUID) {
        queue.sync {
            let list = loadIfNeeded().filter { $0.workoutID != id }
            cache = list
            persist(list)
        }
    }

    private func loadIfNeeded() -> [WorkoutCoachRecord] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([WorkoutCoachRecord].self, from: data) else {
            cache = []
            return []
        }
        cache = decoded
        return decoded
    }

    private func persist(_ list: [WorkoutCoachRecord]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
