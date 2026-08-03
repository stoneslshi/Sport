import Foundation
import HealthKit

// MARK: - 数字格式化

extension Int {
    /// 千分位分组，例如 12,345
    var grouped: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

extension Double {
    var oneDecimal: String {
        String(format: "%.1f", self)
    }
}

// MARK: - 日期

extension Date {
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    /// "7/31"
    var monthDayShort: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: self)
    }

    /// "周五"（中文）
    var weekdayCN: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter.string(from: self)
    }

    /// "7月31日 周五"
    var fullLabelCN: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEE"
        return formatter.string(from: self)
    }

    /// "14:30"
    var timeShort: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: self)
    }

    /// "2026年7月31日"
    var mediumLabelCN: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: self)
    }

    /// "7月31日 07:12"
    var mdTimeCN: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: self)
    }
}

extension TimeInterval {
    /// 0:33:30 / 8:57
    var clockString: String {
        let total = Int(self.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

extension Double {
    /// 分钟数 → 0:33:30
    var minutesAsClock: String {
        (self * 60).clockString
    }
}

// MARK: - 运动类型展示

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: return "跑步"
        case .walking: return "步行"
        case .cycling: return "骑行"
        case .swimming: return "游泳"
        case .hiking: return "徒步"
        case .yoga: return "瑜伽"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "力量训练"
        case .highIntensityIntervalTraining: return "HIIT"
        case .basketball: return "篮球"
        case .soccer: return "足球"
        case .badminton: return "羽毛球"
        case .tennis: return "网球"
        case .tableTennis: return "乒乓球"
        case .volleyball: return "排球"
        case .dance: return "舞蹈"
        case .elliptical: return "椭圆机"
        case .rowing: return "划船"
        case .jumpRope: return "跳绳"
        case .pilates: return "普拉提"
        case .coreTraining: return "核心训练"
        case .cooldown: return "整理放松"
        case .boxing: return "拳击"
        case .climbing: return "攀岩"
        case .golf: return "高尔夫"
        case .skatingSports: return "滑冰"
        case .snowSports: return "冰雪运动"
        case .surfingSports: return "冲浪"
        case .martialArts: return "武术"
        case .taiChi: return "太极"
        case .cardioDance: return "有氧舞蹈"
        case .stairClimbing: return "爬楼梯"
        default: return "其他运动"
        }
    }

    var symbolName: String {
        switch self {
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .cycling: return "figure.outdoor.cycle"
        case .swimming: return "figure.pool.swim"
        case .hiking: return "figure.hiking"
        case .yoga: return "figure.yoga"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "dumbbell.fill"
        case .highIntensityIntervalTraining: return "flame.fill"
        case .basketball, .soccer, .volleyball: return "sportscourt.fill"
        case .badminton, .tennis, .tableTennis: return "tennis.racket"
        case .dance, .cardioDance: return "figure.dance"
        case .rowing: return "figure.rower"
        case .jumpRope: return "figure.jumprope"
        case .pilates, .coreTraining: return "figure.core.training"
        case .boxing, .martialArts: return "figure.boxing"
        case .climbing: return "figure.climbing"
        case .golf: return "figure.golf"
        case .taiChi: return "figure.taichi"
        case .stairClimbing: return "figure.stair.stepper"
        default: return "figure.mixed.cardio"
        }
    }

    /// 图标主题色（用于分类卡片与详情页头部）
    var tintName: String {
        switch self {
        case .running, .highIntensityIntervalTraining: return "orange"
        case .cycling, .hiking, .walking: return "green"
        case .swimming: return "cyan"
        case .functionalStrengthTraining, .traditionalStrengthTraining, .coreTraining: return "purple"
        case .yoga, .pilates, .taiChi: return "pink"
        default: return "blue"
        }
    }

    /// 是否为通常含 GPS 轨迹的户外运动
    var isOutdoorRouteType: Bool {
        switch self {
        case .running, .walking, .cycling, .hiking:
            return true
        default:
            return false
        }
    }
}

import SwiftUI

extension Color {
    /// 由类型主题色名解析为 Color
    init(themeName name: String) {
        switch name {
        case "orange": self = .orange
        case "green": self = .green
        case "cyan": self = .cyan
        case "teal": self = .teal
        case "yellow": self = .yellow
        case "red": self = .red
        case "purple": self = .purple
        case "pink": self = .pink
        case "indigo": self = .indigo
        case "brown": self = .brown
        default: self = .blue
        }
    }

    /// 睡眠阶段配色（与原型一致）
    init(sleepColorName name: String) {
        switch name {
        case "sleepDeep":  self = Color(red: 0.21, green: 0.20, blue: 0.64)   // #3634a3 深靛蓝
        case "sleepCore":  self = Color(red: 0.37, green: 0.36, blue: 0.90)   // #5e5ce6 靛紫
        case "sleepREM":   self = Color(red: 0.04, green: 0.52, blue: 1.0)    // #0a84ff 蓝
        case "sleepAwake": self = Color(red: 0.54, green: 0.59, blue: 0.65)   // #8a97a6 灰
        default:           self = Color(red: 0.37, green: 0.36, blue: 0.90)
        }
    }
}
