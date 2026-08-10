import SwiftUI
import MapKit

// MARK: - Map 适配

private enum RouteMapFitting {
    /// 在 map 已有有效 bounds 时，将轨迹居中适配。
    /// - Important: `coordinates` 必须与 overlay 使用同一套坐标（大陆为 GCJ），否则会整体偏到一侧。
    static func fit(
        _ map: MKMapView,
        coordinates: [CLLocationCoordinate2D],
        edgePadding: UIEdgeInsets,
        animated: Bool = false
    ) {
        guard coordinates.count > 1 else { return }
        guard map.bounds.width > 10, map.bounds.height > 10 else { return }

        map.layoutMargins = .zero
        map.preservesSuperviewLayoutMargins = false
        map.directionalLayoutMargins = .zero
        map.isPitchEnabled = false

        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        var rect = polyline.boundingMapRect
        if rect.size.width < 50 || rect.size.height < 50 {
            let pad = max(80.0, max(rect.size.width, rect.size.height) * 0.3)
            rect = rect.insetBy(dx: -pad, dy: -pad)
        }

        // 先按「可用区域」宽高比对称扩展，避免 MapKit 扩 span 时往一侧偏
        let usableW = max(1, map.bounds.width - edgePadding.left - edgePadding.right)
        let usableH = max(1, map.bounds.height - edgePadding.top - edgePadding.bottom)
        let viewRatio = usableW / usableH
        let rectRatio = rect.size.width / max(rect.size.height, 1)
        if rectRatio > viewRatio {
            let newH = rect.size.width / viewRatio
            rect = MKMapRect(
                x: rect.origin.x,
                y: rect.midY - newH / 2,
                width: rect.size.width,
                height: newH
            )
        } else {
            let newW = rect.size.height * viewRatio
            rect = MKMapRect(
                x: rect.midX - newW / 2,
                y: rect.origin.y,
                width: newW,
                height: rect.size.height
            )
        }

        map.setVisibleMapRect(rect, edgePadding: edgePadding, animated: animated)
    }

    static func sizeChanged(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5
    }

    static func configureFlatMap(_ map: MKMapView) {
        map.isPitchEnabled = false
        map.showsScale = false
        map.showsCompass = false
        map.layoutMargins = .zero
        map.preservesSuperviewLayoutMargins = false
        map.directionalLayoutMargins = .zero
        if #available(iOS 17.0, *) {
            map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        }
    }

    /// 展示用坐标：大陆做 WGS→GCJ，与道路对齐。
    static func displayCoordinates(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        ChinaCoordinateTransform.wgs84ToGcj02(coordinates)
    }
}

// MARK: - 分段标注模型

struct RouteSplitMarker: Identifiable {
    let id: Int
    let index: Int
    let coordinate: CLLocationCoordinate2D
    let paceMin: Double?
    let distanceMeters: Double

    var distanceLabel: String {
        if distanceMeters >= 1000 {
            let km = distanceMeters / 1000
            return km == floor(km) ? "\(Int(km)) km" : String(format: "%.1f km", km)
        }
        return "\(Int(distanceMeters)) m"
    }

    var paceLabel: String? {
        guard let paceMin, paceMin > 0 else { return nil }
        let m = Int(paceMin)
        let s = Int((paceMin - Double(m)) * 60)
        return String(format: "%d'%02d\"", m, s)
    }
}

enum RouteGeometry {
    /// 沿轨迹按固定距离切出分段点，并挂上对应配速（若有）。
    static func splitMarkers(
        coordinates: [CLLocationCoordinate2D],
        splits: [KMSplit],
        segmentMeters: Double? = nil
    ) -> [RouteSplitMarker] {
        guard coordinates.count >= 2 else { return [] }
        let step = segmentMeters
            ?? splits.first?.segmentMeters
            ?? 1000
        guard step > 0 else { return [] }

        let paceByIndex = Dictionary(uniqueKeysWithValues: splits.map { ($0.index, $0.paceMin) })
        var markers: [RouteSplitMarker] = []
        var totalDist = 0.0
        var nextBoundary = step
        var splitIndex = 1

        for i in 1..<coordinates.count {
            let a = coordinates[i - 1]
            let b = coordinates[i]
            let prev = CLLocation(latitude: a.latitude, longitude: a.longitude)
            let curr = CLLocation(latitude: b.latitude, longitude: b.longitude)
            let edge = curr.distance(from: prev)
            guard edge > 0 else { continue }

            let startTotal = totalDist
            let endTotal = totalDist + edge
            while nextBoundary <= endTotal + 0.5 {
                let t = min(1, max(0, (nextBoundary - startTotal) / edge))
                let coord = interpolate(a, b, t: t)
                markers.append(RouteSplitMarker(
                    id: splitIndex,
                    index: splitIndex,
                    coordinate: coord,
                    paceMin: paceByIndex[splitIndex],
                    distanceMeters: nextBoundary
                ))
                splitIndex += 1
                nextBoundary += step
            }
            totalDist = endTotal
        }
        return markers
    }

    static func interpolate(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        t: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    /// 轨迹总长度（米）
    static func lengthMeters(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        var sum = 0.0
        for i in 1..<coordinates.count {
            let a = CLLocation(latitude: coordinates[i - 1].latitude, longitude: coordinates[i - 1].longitude)
            let b = CLLocation(latitude: coordinates[i].latitude, longitude: coordinates[i].longitude)
            sum += b.distance(from: a)
        }
        return sum
    }

    /// 按累计距离比例取点（用于动画头）
    static func point(atFraction f: Double, along coordinates: [CLLocationCoordinate2D]) -> (coord: CLLocationCoordinate2D, index: Int)? {
        guard coordinates.count >= 2 else { return coordinates.first.map { ($0, 0) } }
        let target = max(0, min(1, f)) * lengthMeters(coordinates)
        if target <= 0 { return (coordinates[0], 0) }

        var acc = 0.0
        for i in 1..<coordinates.count {
            let a = coordinates[i - 1]
            let b = coordinates[i]
            let prev = CLLocation(latitude: a.latitude, longitude: a.longitude)
            let curr = CLLocation(latitude: b.latitude, longitude: b.longitude)
            let edge = curr.distance(from: prev)
            if acc + edge >= target {
                let t = edge > 0 ? (target - acc) / edge : 0
                return (interpolate(a, b, t: t), i)
            }
            acc += edge
        }
        return (coordinates[coordinates.count - 1], coordinates.count - 1)
    }

    /// 取到某个累计距离比例为止的坐标序列（用于逐步描线）
    static func prefix(atFraction f: Double, along coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard let tip = point(atFraction: f, along: coordinates) else { return [] }
        if tip.index <= 0 { return [coordinates[0]] }
        var result = Array(coordinates.prefix(tip.index))
        if let last = result.last,
           abs(last.latitude - tip.coord.latitude) > 1e-9
            || abs(last.longitude - tip.coord.longitude) > 1e-9 {
            result.append(tip.coord)
        } else if result.isEmpty {
            result = [tip.coord]
        }
        return result
    }
}

// MARK: - 独立全屏轨迹页

struct WorkoutRouteDetailView: View {
    let coordinates: [CLLocationCoordinate2D]
    let splits: [KMSplit]
    let tint: Color
    var activityName: String = "运动"
    var distanceKM: Double?
    var durationMinutes: Double?

    @State private var progress: Double = 0
    @State private var isPlaying = false
    /// 默认总览居中；播放时可点右上角打开跟随
    @State private var followCamera = false
    @State private var animTask: Task<Void, Never>?

    /// 地图展示坐标（大陆已转 GCJ-02）；距离/动画时长仍用原始 WGS 长度。
    private var mapCoordinates: [CLLocationCoordinate2D] {
        RouteMapFitting.displayCoordinates(coordinates)
    }

    private var markers: [RouteSplitMarker] {
        RouteGeometry.splitMarkers(coordinates: mapCoordinates, splits: splits)
    }

    private var animationDuration: TimeInterval {
        let meters = RouteGeometry.lengthMeters(coordinates)
        // 约 180 m/s 视觉速度，限制 5–14 秒
        return min(14, max(5, meters / 180))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AnimatedRouteMapView(
                coordinates: mapCoordinates,
                splitMarkers: markers,
                tint: tint,
                progress: progress,
                followCamera: followCamera
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                if let summary = summaryText {
                    Text(summary)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                controlBar
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .navigationTitle("运动轨迹")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    followCamera.toggle()
                } label: {
                    Image(systemName: followCamera ? "location.fill" : "location")
                }
                .accessibilityLabel(followCamera ? "跟随视角" : "总览视角")
            }
        }
        .onAppear {
            // 先总览居中，再开播（避免首帧错误 fit 造成左右偏移）
            followCamera = false
            play(fromStart: true)
        }
        .onDisappear { animTask?.cancel() }
    }

    private var summaryText: String? {
        var parts: [String] = [activityName]
        if let km = distanceKM, km > 0 {
            parts.append(km >= 1 ? String(format: "%.2f km", km) : "\(Int(km * 1000)) m")
        }
        if let mins = durationMinutes, mins > 0 {
            parts.append(mins.minutesAsClock)
        }
        return parts.count > 1 ? parts.joined(separator: " · ") : nil
    }

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button {
                if progress >= 0.999 {
                    play(fromStart: true)
                } else if isPlaying {
                    pause()
                } else {
                    play(fromStart: false)
                }
            } label: {
                Image(systemName: playButtonSymbol)
                    .font(.title2.weight(.semibold))
                    .frame(width: 44, height: 44)
            }

            ProgressView(value: progress)
                .tint(tint)

            Text("\(Int(progress * 100))%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            Button {
                play(fromStart: true)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 44)
            }
            .disabled(isPlaying && progress < 0.05)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var playButtonSymbol: String {
        if progress >= 0.999 { return "arrow.counterclockwise" }
        return isPlaying ? "pause.fill" : "play.fill"
    }

    private func pause() {
        isPlaying = false
        animTask?.cancel()
        animTask = nil
    }

    private func play(fromStart: Bool) {
        animTask?.cancel()
        if fromStart { progress = 0 }
        isPlaying = true
        let startProgress = progress
        let remaining = max(0.05, 1 - startProgress)
        let duration = animationDuration * remaining
        let started = Date()

        animTask = Task { @MainActor in
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(started)
                let t = startProgress + remaining * min(1, elapsed / duration)
                progress = min(1, t)
                if progress >= 1 {
                    isPlaying = false
                    break
                }
                try? await Task.sleep(nanoseconds: 16_666_000)
            }
        }
    }
}

// MARK: - 动态描线 MapKit 视图

struct AnimatedRouteMapView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]
    let splitMarkers: [RouteSplitMarker]
    let tint: Color
    let progress: Double
    let followCamera: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        RouteMapFitting.configureFlatMap(map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.tint = UIColor(tint)
        context.coordinator.apply(
            on: map,
            coordinates: coordinates,
            splitMarkers: splitMarkers,
            progress: progress,
            followCamera: followCamera
        )
        // 布局完成后再 fit，避免首帧 bounds 不准造成左右偏移
        let size = map.bounds.size
        DispatchQueue.main.async {
            context.coordinator.ensureFitted(on: map, coordinates: coordinates, size: size, followCamera: followCamera)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var tint: UIColor = .systemOrange
        private var lastVisibleSplitCount = -1
        private var lastFollowCamera: Bool?
        private var lastFitSize: CGSize = .zero
        private var cachedLength: Double = 0
        private var ghostOverlay: MKPolyline?
        private var activeOverlay: MKPolyline?
        private var tipAnnotation: MKPointAnnotation?
        private var startAnnotation: MKPointAnnotation?
        private var endAnnotation: MKPointAnnotation?
        private var splitAnnotations: [SplitAnnotation] = []

        private var overviewPadding: UIEdgeInsets {
            UIEdgeInsets(top: 88, left: 40, bottom: 150, right: 40)
        }

        func fitEntireRoute(on map: MKMapView, coordinates: [CLLocationCoordinate2D], animated: Bool = false) {
            RouteMapFitting.fit(map, coordinates: coordinates, edgePadding: overviewPadding, animated: animated)
            lastFitSize = map.bounds.size
        }

        func ensureFitted(on map: MKMapView, coordinates: [CLLocationCoordinate2D], size: CGSize, followCamera: Bool) {
            guard !followCamera else { return }
            guard size.width > 10, size.height > 10 else { return }
            if RouteMapFitting.sizeChanged(size, lastFitSize) {
                fitEntireRoute(on: map, coordinates: coordinates, animated: false)
            }
        }

        func apply(
            on map: MKMapView,
            coordinates: [CLLocationCoordinate2D],
            splitMarkers: [RouteSplitMarker],
            progress: Double,
            followCamera: Bool
        ) {
            guard coordinates.count > 1 else { return }

            // 灰色全程底线（只加一次）
            if ghostOverlay == nil {
                let ghost = MKPolyline(coordinates: coordinates, count: coordinates.count)
                ghost.title = "ghost"
                ghostOverlay = ghost
                map.addOverlay(ghost, level: .aboveRoads)
                cachedLength = RouteGeometry.lengthMeters(coordinates)
            }

            // 起点
            if startAnnotation == nil, let first = coordinates.first {
                let a = MKPointAnnotation()
                a.coordinate = first
                a.title = "起点"
                startAnnotation = a
                map.addAnnotation(a)
            }

            let drawn = RouteGeometry.prefix(atFraction: progress, along: coordinates)
            if drawn.count >= 2 {
                if let activeOverlay { map.removeOverlay(activeOverlay) }
                let poly = MKPolyline(coordinates: drawn, count: drawn.count)
                poly.title = "active"
                activeOverlay = poly
                map.addOverlay(poly, level: .aboveRoads)
            }

            let tipCoord = drawn.last ?? coordinates[0]
            updateTip(on: map, coordinate: tipCoord, progress: progress)

            // 分段标注：随进度逐步显现
            let total = cachedLength > 0 ? cachedLength : RouteGeometry.lengthMeters(coordinates)
            let visibleCount = splitMarkers.filter { marker in
                guard total > 0 else { return progress >= 1 }
                return marker.distanceMeters / total <= progress + 0.001
            }.count

            if visibleCount != lastVisibleSplitCount {
                syncSplitAnnotations(on: map, markers: Array(splitMarkers.prefix(visibleCount)))
                lastVisibleSplitCount = visibleCount
            }

            // 终点：播完再标
            if progress >= 0.999 {
                if endAnnotation == nil, let last = coordinates.last {
                    let a = MKPointAnnotation()
                    a.coordinate = last
                    a.title = "终点"
                    endAnnotation = a
                    map.addAnnotation(a)
                }
            } else if let endAnnotation {
                map.removeAnnotation(endAnnotation)
                self.endAnnotation = nil
            }

            if followCamera {
                let span = followSpanMeters(progress: progress, coordinates: coordinates)
                // 纵向多留一点，避免被底部控制条挡住（不改变经度中心，避免左右漂移）
                let region = MKCoordinateRegion(
                    center: tipCoord,
                    latitudinalMeters: span * 1.15,
                    longitudinalMeters: span
                )
                map.setRegion(region, animated: false)
            } else if lastFollowCamera != false || RouteMapFitting.sizeChanged(map.bounds.size, lastFitSize) {
                // 关闭跟随或尺寸变化时，重新总览居中
                fitEntireRoute(on: map, coordinates: coordinates, animated: lastFollowCamera != false)
            }
            lastFollowCamera = followCamera
        }

        private func followSpanMeters(progress: Double, coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
            let total = max(cachedLength > 0 ? cachedLength : RouteGeometry.lengthMeters(coordinates), 500)
            // 近景跟随，结束时略拉开
            let base = min(max(total * 0.18, 220), 900)
            return progress > 0.95 ? base * 1.4 : base
        }

        private func updateTip(on map: MKMapView, coordinate: CLLocationCoordinate2D, progress: Double) {
            if tipAnnotation == nil {
                let a = MKPointAnnotation()
                a.title = "当前位置"
                tipAnnotation = a
                map.addAnnotation(a)
            }
            tipAnnotation?.coordinate = coordinate
            if progress >= 0.999, let tip = tipAnnotation {
                map.removeAnnotation(tip)
                tipAnnotation = nil
            }
        }

        private func syncSplitAnnotations(on map: MKMapView, markers: [RouteSplitMarker]) {
            if !splitAnnotations.isEmpty {
                map.removeAnnotations(splitAnnotations)
                splitAnnotations.removeAll()
            }
            for m in markers {
                let a = SplitAnnotation(marker: m)
                splitAnnotations.append(a)
            }
            map.addAnnotations(splitAnnotations)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let poly = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r = MKPolylineRenderer(polyline: poly)
            if poly.title == "ghost" {
                r.strokeColor = UIColor.secondaryLabel.withAlphaComponent(0.35)
                r.lineWidth = 3
            } else {
                r.strokeColor = tint
                r.lineWidth = 5
            }
            r.lineJoin = .round
            r.lineCap = .round
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let split = annotation as? SplitAnnotation {
                let id = "split"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.markerTintColor = .systemIndigo
                view.glyphText = "\(split.marker.index)"
                view.titleVisibility = .adaptive
                view.subtitleVisibility = .adaptive
                view.displayPriority = .defaultHigh
                return view
            }

            let id = "endpoint"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            switch annotation.title ?? "" {
            case "起点":
                view.markerTintColor = .systemGreen
                view.glyphImage = UIImage(systemName: "flag.fill")
            case "终点":
                view.markerTintColor = .systemRed
                view.glyphImage = UIImage(systemName: "flag.checkered")
            case "当前位置":
                view.markerTintColor = tint
                view.glyphImage = UIImage(systemName: "circle.fill")
                view.displayPriority = .required
            default:
                view.markerTintColor = .systemOrange
            }
            view.titleVisibility = .adaptive
            return view
        }
    }
}

final class SplitAnnotation: NSObject, MKAnnotation {
    let marker: RouteSplitMarker
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?

    init(marker: RouteSplitMarker) {
        self.marker = marker
        self.coordinate = marker.coordinate
        self.title = marker.distanceLabel
        if let pace = marker.paceLabel {
            self.subtitle = "配速 \(pace)"
        } else {
            self.subtitle = "第 \(marker.index) 段"
        }
        super.init()
    }
}

// MARK: - 详情页缩略轨迹（静态）

struct RouteMapView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]
    let tint: Color

    private var edgePadding: UIEdgeInsets {
        UIEdgeInsets(top: 36, left: 36, bottom: 36, right: 36)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        RouteMapFitting.configureFlatMap(map)
        map.isRotateEnabled = false
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.tint = UIColor(tint)
        // 展示与 fit 必须用同一套坐标（GCJ），异步补 fit 时也不能传原始 WGS
        let display = RouteMapFitting.displayCoordinates(coordinates)
        context.coordinator.sync(
            on: map,
            displayCoordinates: display,
            edgePadding: edgePadding
        )
        DispatchQueue.main.async {
            context.coordinator.fitIfNeeded(
                on: map,
                coordinates: display,
                edgePadding: edgePadding,
                force: true
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var tint: UIColor = .systemOrange
        private var lastCoordCount = -1
        private var lastFitSize: CGSize = .zero

        func sync(on map: MKMapView, displayCoordinates display: [CLLocationCoordinate2D], edgePadding: UIEdgeInsets) {
            guard display.count > 1 else {
                map.removeOverlays(map.overlays)
                map.removeAnnotations(map.annotations)
                lastCoordCount = 0
                return
            }
            // 坐标未变时不要反复清图层（会抖）
            if display.count != lastCoordCount || map.overlays.isEmpty {
                map.removeOverlays(map.overlays)
                map.removeAnnotations(map.annotations)

                let polyline = MKPolyline(coordinates: display, count: display.count)
                map.addOverlay(polyline)

                if let first = display.first {
                    let a = MKPointAnnotation(); a.coordinate = first; a.title = "起点"
                    map.addAnnotation(a)
                }
                if let last = display.last {
                    let a = MKPointAnnotation(); a.coordinate = last; a.title = "终点"
                    map.addAnnotation(a)
                }
                lastCoordCount = display.count
                lastFitSize = .zero // 强制重新 fit
            }
            fitIfNeeded(on: map, coordinates: display, edgePadding: edgePadding, force: false)
        }

        func fitIfNeeded(
            on map: MKMapView,
            coordinates: [CLLocationCoordinate2D],
            edgePadding: UIEdgeInsets,
            force: Bool
        ) {
            let size = map.bounds.size
            guard size.width > 10, size.height > 10 else { return }
            if !force, !RouteMapFitting.sizeChanged(size, lastFitSize) { return }
            RouteMapFitting.fit(map, coordinates: coordinates, edgePadding: edgePadding, animated: false)
            lastFitSize = size
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                r.strokeColor = tint
                r.lineWidth = 4
                r.lineJoin = .round
                r.lineCap = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            let id = "pin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.markerTintColor = annotation.title == "起点" ? .systemGreen : .systemRed
            view.titleVisibility = .adaptive
            return view
        }
    }
}
