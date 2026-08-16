import SwiftUI

/// 健康数据来源。FIT 导入标为 Garmin，HealthKit 样本也可按 bundle 识别。
enum HealthDataSource: String, Codable, Equatable, CaseIterable, Identifiable {
    case appleHealth
    case garmin
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleHealth: return "Apple 健康"
        case .garmin: return "Garmin"
        case .other: return "其他"
        }
    }

    var shortLabel: String {
        switch self {
        case .appleHealth: return "Apple"
        case .garmin: return "Garmin"
        case .other: return "其他"
        }
    }

    var tint: Color {
        switch self {
        case .appleHealth: return .blue
        case .garmin: return .cyan
        case .other: return .secondary
        }
    }

    static func from(name: String?, bundle: String?) -> HealthDataSource {
        let haystack = "\(name ?? "") \(bundle ?? "")".lowercased()
        if haystack.contains("garmin") { return .garmin }
        if haystack.contains("watch") || haystack.contains("com.apple.health") || haystack.contains("apple") {
            return .appleHealth
        }
        if haystack.trimmingCharacters(in: .whitespaces).isEmpty { return .appleHealth }
        return .other
    }
}

struct DataSourceBadge: View {
    let source: HealthDataSource
    var name: String? = nil

    var body: some View {
        Text((name?.isEmpty == false) ? name! : source.shortLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(source.tint)
            .background(source.tint.opacity(0.16), in: Capsule())
    }
}
