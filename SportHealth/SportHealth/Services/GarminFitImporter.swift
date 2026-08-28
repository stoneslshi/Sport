import Foundation
import UniformTypeIdentifiers

struct FitImportResult {
    var imported = 0
    var updated = 0
    var skippedDuplicate = 0
    var skippedInvalid = 0
    var failed = 0
    var scanned = 0

    var summary: String {
        var parts: [String] = []
        if imported > 0 { parts.append("新导入 \(imported) 场") }
        if updated > 0 { parts.append("更新 \(updated) 场") }
        if skippedDuplicate > 0 { parts.append("已存在 \(skippedDuplicate) 场") }
        if skippedInvalid > 0 { parts.append("跳过 \(skippedInvalid) 个非活动文件") }
        if failed > 0 { parts.append("失败 \(failed) 个") }
        if parts.isEmpty { return "没有解析到可导入的 FIT 活动。" }
        return parts.joined(separator: "，") + "。"
    }
}

/// 从用户选择的 FIT / ZIP（含 Garmin 数据管理导出的嵌套 ZIP）导入活动。
enum GarminFitImporter {
    private static let maxDepth = 5
    private static let maxFiles = 4000

    static var allowedTypes: [UTType] {
        var types: [UTType] = [.zip]
        if let garmin = UTType("com.garmin.fit") {
            types.insert(garmin, at: 0)
        } else if let fit = UTType(filenameExtension: "fit") {
            types.insert(fit, at: 0)
        }
        return types
    }

    static func importItems(at urls: [URL],
                            progress: @MainActor @escaping (String) -> Void) async -> FitImportResult {
        var result = FitImportResult()
        var payloads: [(name: String, data: Data)] = []

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                try collect(from: url, name: url.lastPathComponent, depth: 0, into: &payloads)
            } catch {
                result.failed += 1
            }
        }

        result.scanned = payloads.count
        await progress("正在解析 \(payloads.count) 个 FIT…")

        var toSave: [PersistedImportedWorkout] = []
        let existing = Set(ImportedWorkoutStore.shared.all().map(\.fingerprint))

        for (index, item) in payloads.enumerated() {
            if index % 20 == 0 {
                await progress("正在解析 \(index + 1)/\(payloads.count)…")
            }
            let fingerprint = GarminFitMapper.fingerprint(of: item.data)
            if existing.contains(fingerprint) || toSave.contains(where: { $0.fingerprint == fingerprint }) {
                result.skippedDuplicate += 1
                continue
            }
            do {
                let parsed = try FITParser.parse(item.data)
                if let persisted = GarminFitMapper.persist(activity: parsed, fileName: item.name, fingerprint: fingerprint) {
                    toSave.append(persisted)
                } else {
                    result.skippedInvalid += 1
                }
            } catch {
                result.skippedInvalid += 1
            }
        }

        let outcome = ImportedWorkoutStore.shared.upsert(toSave)
        result.imported = outcome.added
        result.updated = outcome.updated
        return result
    }

    private static func collect(from url: URL, name: String, depth: Int,
                                into payloads: inout [(name: String, data: Data)]) throws {
        let data = try Data(contentsOf: url)
        try collect(data: data, name: name, depth: depth, into: &payloads)
    }

    private static func collect(data: Data, name: String, depth: Int,
                                into payloads: inout [(name: String, data: Data)]) throws {
        guard depth <= maxDepth, payloads.count < maxFiles else { return }
        let lower = name.lowercased()

        if FITParser.looksLikeFIT(data) {
            if data.count >= 512 {
                payloads.append((name, data))
            }
            return
        }

        if ZipArchiveReader.looksLikeZIP(data) || lower.hasSuffix(".zip") {
            let entries = try ZipArchiveReader.entries(from: data)
            for entry in entries {
                try collect(data: entry.data, name: entry.name, depth: depth + 1, into: &payloads)
            }
            return
        }

        if lower.hasSuffix(".fit") || lower.hasSuffix(".fit.gz") {
            if data.count >= 512, FITParser.looksLikeFIT(data) {
                payloads.append((name, data))
            }
        }
    }
}
