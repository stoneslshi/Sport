import SwiftUI
import HealthKit
import UIKit
import MapKit
import LinkPresentation

// MARK: - 分享图片包装（供 .sheet(item:) 使用）

struct ShareImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
    /// 与图片一起分享的文案（含 AI 生成结果）
    var text: String = ""
}

// MARK: - 图片分享数据源（让系统分享面板顶部显示图片缩略图）

/// 直接把 UIImage 传给 UIActivityViewController 时，分享面板顶部常常只显示文字、不显示大图预览。
/// 通过 UIActivityItemSource 提供 LPLinkMetadata（含 imageProvider/iconProvider）与 thumbnailImage，
/// 系统面板即可展示图片缩略图。
final class ImageActivityItemSource: NSObject, UIActivityItemSource {
    let image: UIImage
    let title: String

    init(image: UIImage, title: String) {
        self.image = image
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        image
    }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        // 保存到相册必须拿到真正的 UIImage；不要返回其它包装类型
        image
    }

    func activityViewController(_ controller: UIActivityViewController,
                                thumbnailImageForActivityType activityType: UIActivity.ActivityType?,
                                suggestedSize size: CGSize) -> UIImage? {
        image
    }

    func activityViewController(_ controller: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        // 标题不宜过长；截取首行作主题
        String(title.prefix(40))
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        // 仅用于分享面板顶部预览；placeholder/item 仍返回 UIImage，保证「存储图像」可用
        let metadata = LPLinkMetadata()
        metadata.title = String(title.prefix(40))
        let provider = NSItemProvider(object: image)
        metadata.imageProvider = provider
        metadata.iconProvider = provider
        return metadata
    }
}

// MARK: - 系统分享面板

/// 包装 UIActivityViewController，调起系统分享（存图/微信/朋友圈等）。
/// 图片与文案分两个 ItemSource：保存到相册时只提供图片（返回 nil 文案），否则「存储图像」会因混合类型而消失。
struct ShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let imageSource = ImageActivityItemSource(image: image, title: text)
        let textSource = TextActivityItemSource(text: text)
        return UIActivityViewController(activityItems: [imageSource, textSource],
                                        applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// 分享文案；对「保存到相册」返回 nil，避免挡住存图入口。
final class TextActivityItemSource: NSObject, UIActivityItemSource {
    let text: String
    init(text: String) { self.text = text }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        text
    }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        if activityType == .saveToCameraRoll { return nil }
        return text
    }
}

// MARK: - 分享海报（海报化；按场景自动选模板）

private enum SharePosterLayout {
    static let width: CGFloat = 360
    static let height: CGFloat = 640
}

private extension View {
    /// 导出位图必须铺满矩形且不透明。圆角 `clipShape` 会让四角变透明，微信/相册压成 JPEG 后露出白块。
    func sharePosterCanvas() -> some View {
        frame(width: SharePosterLayout.width, height: SharePosterLayout.height)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .ignoresSafeArea()
    }
}

/// 轨迹海报：全幅地图底 + 一个主指标 + 短文案。
struct RouteSharePoster: View {
    let record: WorkoutRecord
    let caption: String
    let routeSnapshot: UIImage

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(uiImage: routeSnapshot)
                .resizable()
                .scaledToFill()
                .frame(width: SharePosterLayout.width, height: SharePosterLayout.height)
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.25), .black.opacity(0.82), .black],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: SharePosterLayout.width, height: SharePosterLayout.height)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("\(AppBrand.watermark)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.4), in: Capsule())
                    Spacer()
                    Text(record.start.mdTimeCN)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 18).padding(.top, 18)

                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Label(record.activityType.displayName,
                          systemImage: record.activityType.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))

                    heroMetric

                    HStack(spacing: 14) {
                        ForEach(secondaryItems, id: \.self) { Text($0) }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))

                    Text(caption)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Text("\(AppBrand.watermark)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(14)
        }
        .foregroundStyle(.white)
        .sharePosterCanvas()
    }

    @ViewBuilder
    private var heroMetric: some View {
        if let km = record.distanceKM, km > 0, !record.isSwimming {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(km.oneDecimal).font(.system(size: 56, weight: .bold, design: .rounded))
                Text("km").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            }
        } else if record.isSwimming, let km = record.distanceKM, km > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(km * 1000))").font(.system(size: 56, weight: .bold, design: .rounded))
                Text("m").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(record.caloriesKcal))")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                Text("kcal").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var secondaryItems: [String] {
        var items: [String] = []
        if let pace = ShareCardRenderer.paceLabel(for: record) { items.append(pace) }
        items.append("\(Int(record.durationMinutes)) 分钟")
        items.append("\(Int(record.caloriesKcal)) kcal")
        if let hr = record.avgHR, items.count < 3 {
            items.insert("均心 \(Int(hr))", at: min(1, items.count))
        }
        return Array(items.prefix(3))
    }
}

/// 极简大字：无轨迹时用。有距离则距离做主指标，配速进辅栏。
struct MinimalSharePoster: View {
    let record: WorkoutRecord
    let caption: String

    private var tint: Color { Color(themeName: record.activityType.tintName) }

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [tint.opacity(0.45), Color(red: 0.04, green: 0.06, blue: 0.08)],
                center: .topLeading, startRadius: 20, endRadius: 420
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("\(AppBrand.watermark)").font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Text(record.start.mdTimeCN).font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }

                Spacer(minLength: 28)

                Text(record.activityType.displayName)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(tint)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(heroValue)
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.55)
                        .lineLimit(1)
                    if let unit = heroUnitInline {
                        Text(unit)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.bottom, 6)
                    }
                }
                .padding(.top, 8)

                Text(heroSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 6)

                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                    .padding(.top, 22)

                HStack(spacing: 18) {
                    ForEach(secondaryStats, id: \.label) { item in
                        miniStat(item.value, item.label)
                    }
                }
                .padding(.top, 16)

                Text(caption)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .padding(.top, 28)

                Spacer(minLength: 12)
            }
            .padding(22)
        }
        .sharePosterCanvas()
    }

    /// 主指标：优先距离（游泳用米），否则配速，再否则消耗。
    private var heroValue: String {
        if record.isSwimming, let km = record.distanceKM, km > 0 {
            return "\(Int((km * 1000).rounded()))"
        }
        if let km = record.distanceKM, km > 0 {
            return km.oneDecimal
        }
        if let pace = ShareCardRenderer.paceRaw(for: record) { return pace }
        return "\(Int(record.caloriesKcal))"
    }

    private var heroUnitInline: String? {
        if record.isSwimming, let km = record.distanceKM, km > 0 { return "m" }
        if let km = record.distanceKM, km > 0 { return "km" }
        if ShareCardRenderer.paceRaw(for: record) != nil { return nil }
        return "kcal"
    }

    private var heroSubtitle: String {
        if record.distanceKM != nil, record.distanceKM! > 0 {
            if let pace = ShareCardRenderer.paceLabel(for: record) {
                return "距离 · \(pace)"
            }
            return "距离"
        }
        if ShareCardRenderer.paceRaw(for: record) != nil {
            return record.isSwimming ? "平均配速 /100m" : "平均配速 /km"
        }
        return "活动消耗"
    }

    private var secondaryStats: [(value: String, label: String)] {
        var items: [(String, String)] = [
            ("\(Int(record.durationMinutes))", "分钟")
        ]
        // 距离已做主指标时，配速进辅栏
        if record.distanceKM != nil, record.distanceKM! > 0,
           let pace = ShareCardRenderer.paceRaw(for: record) {
            items.append((pace, record.isSwimming ? "/100m" : "/km"))
        } else if let hr = record.avgHR {
            items.append(("\(Int(hr))", "均心"))
        }
        items.append(("\(Int(record.caloriesKcal))", "kcal"))
        if items.count < 3, let hr = record.avgHR,
           !items.contains(where: { $0.1 == "均心" }) {
            items.insert(("\(Int(hr))", "均心"), at: 1)
        }
        return Array(items.prefix(3))
    }

    private func miniStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.bold()).foregroundStyle(.white)
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 区间汇总海报：主打「次数」+ 按类型列出次数/距离或消耗。
struct WeekSharePoster: View {
    let records: [WorkoutRecord]
    let typeStats: [WorkoutTypeStat]
    let rangeLabel: String
    let periodText: String
    let caption: String

    private var totalMin: Int { Int(records.reduce(0) { $0 + $1.durationMinutes }) }
    private var totalKcal: Int { Int(records.reduce(0) { $0 + $1.caloriesKcal }) }
    private var rankedTypes: [WorkoutTypeStat] {
        typeStats.sorted { $0.count > $1.count }.prefix(5).map { $0 }
    }

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Color(red: 0.42, green: 0.22, blue: 0.08).opacity(0.95),
                    Color(red: 0.07, green: 0.09, blue: 0.12),
                    Color(red: 0.03, green: 0.04, blue: 0.06)
                ],
                center: UnitPoint(x: 0.15, y: 0.0),
                startRadius: 10,
                endRadius: 480
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("\(AppBrand.watermark)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text(rangeLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.45))
                }

                Text(periodText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 18)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(records.count)")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text("次")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.bottom, 10)
                }
                .padding(.top, 2)

                Text("\(totalMin) 分钟  ·  \(totalKcal.grouped) kcal")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 4)

                Text("运动分类")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 26)
                    .padding(.bottom, 10)

                VStack(spacing: 0) {
                    ForEach(rankedTypes) { stat in
                        typeRow(stat)
                    }
                }

                Spacer(minLength: 12)

                Text(caption)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(AppBrand.watermark)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 10)
            }
            .padding(22)
        }
        .sharePosterCanvas()
    }

    private func typeRow(_ stat: WorkoutTypeStat) -> some View {
        let tint = Color(themeName: stat.activityType.tintName)
        return HStack(spacing: 8) {
            Image(systemName: stat.activityType.symbolName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.18), in: Circle())

            Text(stat.activityType.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 72, alignment: .leading)

            Spacer(minLength: 4)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(stat.count)")
                    .font(.body.bold())
                    .foregroundStyle(.white)
                Text("次")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Text(metricText(for: stat))
                .font(.footnote.weight(.bold))
                .foregroundStyle(.orange.opacity(0.95))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 88, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        }
    }

    /// 有距离的类型展示距离；大数用紧凑格式，避免右侧被裁切。
    private func metricText(for stat: WorkoutTypeStat) -> String {
        if stat.totalKM > 0 {
            if stat.activityType == .swimming {
                let meters = Int((stat.totalKM * 1000).rounded())
                // 年汇总米数过大时改用公里，保证可读且不截断
                if meters >= 10_000 {
                    return compactKM(stat.totalKM)
                }
                return "\(meters.grouped) m"
            }
            return compactKM(stat.totalKM)
        }
        return "\(Int(stat.totalKcal).grouped) kcal"
    }

    private func compactKM(_ km: Double) -> String {
        if km >= 100 {
            return "\(Int(km.rounded()).grouped) km"
        }
        return "\(km.oneDecimal) km"
    }
}

/// 上周 AI 周报分享海报：大评分 + 关键指标 + 短行动
struct WeeklyAdviceSharePoster: View {
    let record: WeeklyAdviceRecord
    let caption: String

    private var snap: WeeklyAdviceSnapshot { record.snapshot }
    private var brief: WeeklyAdviceBrief { record.displayBrief }

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    Color(red: 0.42, green: 0.22, blue: 0.08).opacity(0.95),
                    Color(red: 0.07, green: 0.09, blue: 0.12),
                    Color(red: 0.03, green: 0.04, blue: 0.06)
                ],
                center: UnitPoint(x: 0.2, y: 0.0),
                startRadius: 10,
                endRadius: 480
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(AppBrand.watermark)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text("上周周报")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.45))
                }

                Text(record.dateRangeText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 16)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(snap.activityScore)")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("活动评分")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                        Text(brief.vibe)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                    }
                    .padding(.bottom, 10)
                }
                .padding(.top, 4)

                Text(brief.headline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.top, 6)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    shareMetric("\(snap.workoutCount)", "训练")
                    shareMetric("\(Int(snap.totalExerciseMin))", "分钟")
                    shareMetric("\(Int(snap.totalEnergyKcal))", "kcal")
                    shareMetric(snap.avgSleepHours.map { String(format: "%.1fh", $0) } ?? "--", "均睡")
                }
                .padding(.top, 20)

                Text("本周行动")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 22)
                    .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(brief.actions.prefix(3).enumerated()), id: \.offset) { i, act in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                                .frame(width: 18)
                            Text(act)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.92))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Spacer(minLength: 12)

                Text(caption)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)

                Text(AppBrand.watermark)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 10)
            }
            .padding(22)
        }
        .sharePosterCanvas()
    }

    private func shareMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 渲染器 & 文案

enum ShareCardRenderer {

    /// 分钟数 -> X'XX"
    static func pace(_ minutes: Double) -> String {
        let m = Int(minutes)
        let s = Int((minutes - Double(m)) * 60)
        return String(format: "%d'%02d\"", m, s)
    }

    /// 配速原始字符串（不含单位），供极简海报大字用。
    static func paceRaw(for record: WorkoutRecord) -> String? {
        if record.isSwimming, let p = record.avgPacePer100m { return pace(p) }
        if let p = record.avgPaceMinPerKM { return pace(p) }
        return nil
    }

    /// 带单位的配速文案。
    static func paceLabel(for record: WorkoutRecord) -> String? {
        guard let raw = paceRaw(for: record) else { return nil }
        return record.isSwimming ? "\(raw) /100m" : "\(raw) /km"
    }

    /// 用 ImageRenderer 把 SwiftUI 视图渲染成高清 UIImage。
    @MainActor
    private static func render<V: View>(_ view: V) -> UIImage {
        let content = view
            .frame(width: SharePosterLayout.width, height: SharePosterLayout.height)
            .background(Color.black)
            .ignoresSafeArea()
        let renderer = ImageRenderer(content: content)
        renderer.scale = UIScreen.main.scale
        renderer.proposedSize = ProposedViewSize(
            width: SharePosterLayout.width,
            height: SharePosterLayout.height
        )
        guard let image = renderer.uiImage else { return UIImage() }
        return flattenedOpaque(image)
    }

    /// 透明像素压到黑底，避免分享目标把透明边角变成白块。
    private static func flattenedOpaque(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = image.scale
        let size = image.size
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 渲染单次运动分享图：有轨迹快照 → 轨迹海报；否则 → 极简大字。
    @MainActor
    static func renderWorkout(record: WorkoutRecord, caption: String,
                              routeSnapshot: UIImage? = nil) -> UIImage {
        if let snap = routeSnapshot {
            return render(RouteSharePoster(record: record, caption: caption, routeSnapshot: snap))
        }
        return render(MinimalSharePoster(record: record, caption: caption))
    }

    /// 用 MKMapSnapshotter 把 GPS 轨迹渲染成全幅海报底图。
    /// ImageRenderer 无法渲染 MKMapView，所以这里预生成为静态图。
    static func routeSnapshot(coordinates: [CLLocationCoordinate2D],
                              tint: Color,
                              scale: CGFloat,
                              size: CGSize = CGSize(width: SharePosterLayout.width,
                                                    height: SharePosterLayout.height)) async -> UIImage? {
        guard coordinates.count > 1 else { return nil }
        // 与详情地图一致：去掉异常点后再转 GCJ-02
        let coordinates = ChinaCoordinateTransform.wgs84ToGcj02(RouteGeometry.sanitized(coordinates))
        guard coordinates.count > 1 else { return nil }

        var minLat = coordinates[0].latitude,  maxLat = coordinates[0].latitude
        var minLon = coordinates[0].longitude, maxLon = coordinates[0].longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        // 中心略偏北，给底部文案留白（不改经度，避免轨迹左右偏移）
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2 - (maxLat - minLat) * 0.08,
            longitude: (minLon + maxLon) / 2
        )
        // span 宽高比与海报一致，避免 snapshot 裁切后 point(for:) 与底图错位
        var latDelta = max((maxLat - minLat) * 1.45, 0.0025)
        var lonDelta = max((maxLon - minLon) * 1.45, 0.0025)
        let mapAspect = Double(size.width / max(size.height, 1))
        let cosLat = max(cos(center.latitude * .pi / 180), 0.2)
        var regionAspect = (lonDelta * cosLat) / max(latDelta, 1e-9)
        if regionAspect > mapAspect {
            latDelta = (lonDelta * cosLat) / mapAspect
        } else {
            lonDelta = (latDelta * mapAspect) / cosLat
        }
        let span = MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = size
        options.scale = scale
        options.pointOfInterestFilter = .excludingAll
        if #available(iOS 17.0, *) {
            options.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
        }

        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else { return nil }

        let img = snapshot.image
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = img.scale
        let renderer = UIGraphicsImageRenderer(size: img.size, format: format)
        let strokeColor = UIColor(tint)
        return renderer.image { ctx in
            img.draw(at: .zero)

            let path = UIBezierPath()
            for (i, c) in coordinates.enumerated() {
                let pt = snapshot.point(for: c)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            strokeColor.setStroke()
            path.lineWidth = 5
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()

            func dot(_ coord: CLLocationCoordinate2D, color: UIColor) {
                let p = snapshot.point(for: coord)
                let r: CGFloat = 7
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                color.setFill()
                UIColor.white.setStroke()
                let circle = UIBezierPath(ovalIn: rect)
                circle.lineWidth = 2
                circle.fill()
                circle.stroke()
            }
            if let first = coordinates.first { dot(first, color: .systemGreen) }
            if let last = coordinates.last  { dot(last,  color: .systemRed) }

            // Cover MapKit baked-in Apple Maps / Legal chip so it doesn't show as a white corner block.
            let mapSize = img.size
            let fadeH = max(40, mapSize.height * 0.07)
            let fadeRect = CGRect(x: 0, y: mapSize.height - fadeH, width: mapSize.width, height: fadeH)
            let colors = [UIColor.clear.cgColor, UIColor.black.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors,
                                         locations: [0, 1]) {
                ctx.cgContext.saveGState()
                ctx.cgContext.addRect(fadeRect)
                ctx.cgContext.clip()
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: fadeRect.minY),
                    end: CGPoint(x: 0, y: fadeRect.maxY),
                    options: []
                )
                ctx.cgContext.restoreGState()
            }
        }
    }

    /// 渲染汇总分享图（周报条形模板）。
    @MainActor
    static func renderWorkoutSummary(records: [WorkoutRecord], typeStats: [WorkoutTypeStat],
                                     rangeLabel: String,
                                     periodText: String, caption: String) -> UIImage {
        render(WeekSharePoster(records: records, typeStats: typeStats, rangeLabel: rangeLabel,
                               periodText: periodText, caption: caption))
    }

    /// 渲染上周 AI 周报分享图。
    @MainActor
    static func renderWeeklyAdvice(record: WeeklyAdviceRecord, caption: String) -> UIImage {
        render(WeeklyAdviceSharePoster(record: record, caption: caption))
    }

    // MARK: 本地兜底文案（短社交文案）

    static func localCaption(for record: WorkoutRecord) -> String {
        let min = Int(record.durationMinutes)
        let kcal = Int(record.caloriesKcal)
        if let km = record.distanceKM, km >= 8, !record.isSwimming {
            return "一口气跑完 \(km.oneDecimal) km，配速稳住了。"
        }
        if let km = record.distanceKM, km > 0, !record.isSwimming {
            return "出门动一动，\(km.oneDecimal) km 刚刚好。"
        }
        if record.isSwimming, let km = record.distanceKM, km > 0 {
            return "水里游了 \(Int(km * 1000)) 米，\(min) 分钟不停歇。"
        }
        if kcal >= 400 {
            return "高强度一堂，\(kcal) kcal 燃完。"
        }
        return "今天也没闲着，\(min) 分钟到位。"
    }

    static func localSummaryCaption(records: [WorkoutRecord], rangeLabel: String) -> String {
        let count = records.count
        if count == 0 { return "新的一周，先动起来。" }
        var map: [String: Int] = [:]
        for r in records {
            map[r.activityType.displayName, default: 0] += 1
        }
        let top = map.max(by: { $0.value < $1.value })?.key
        if let top {
            return "\(rangeLabel)练了 \(count) 次，主项「\(top)」。"
        }
        return "\(rangeLabel)完成 \(count) 次，继续保持。"
    }

    static func workoutText(record: WorkoutRecord) -> String {
        localCaption(for: record) + " " + AppBrand.shareHashtag
    }
    static func workoutSummaryText(records: [WorkoutRecord], rangeLabel: String) -> String {
        localSummaryCaption(records: records, rangeLabel: rangeLabel) + " " + AppBrand.shareHashtag
    }
}
