import Foundation

enum HealthDataMerger {
    static func mergeWorkouts(healthKit: [WorkoutRecord], imported: [WorkoutRecord]) -> [WorkoutRecord] {
        guard !imported.isEmpty else { return healthKit }
        var kept = healthKit
        for item in imported {
            if let index = kept.firstIndex(where: { overlaps($0, item) }) {
                var winner = prefer(kept[index], item)
                winner.source = .garmin
                winner.sourceName = winner.sourceName ?? item.sourceName ?? "Garmin"
                kept[index] = winner
            } else {
                kept.append(item)
            }
        }
        return kept.sorted { $0.start > $1.start }
    }

    private static func overlaps(_ a: WorkoutRecord, _ b: WorkoutRecord) -> Bool {
        guard a.activityType == b.activityType else { return false }
        return abs(a.start.timeIntervalSince(b.start)) < 180
            && abs(a.durationMinutes - b.durationMinutes) < 8
    }

    private static func prefer(_ a: WorkoutRecord, _ b: WorkoutRecord) -> WorkoutRecord {
        richness(a) >= richness(b) ? a : b
    }

    private static func richness(_ r: WorkoutRecord) -> Int {
        var score = 0
        if r.distanceKM != nil { score += 2 }
        if r.avgHR != nil { score += 2 }
        if r.maxHR != nil { score += 1 }
        if r.elevationGain != nil { score += 1 }
        if r.hasRoute { score += 4 }
        if !r.heartRateSeries.isEmpty { score += 3 }
        if r.source == .garmin, ImportedWorkoutStore.shared.hasRoute(id: r.id) { score += 4 }
        return score
    }
}
