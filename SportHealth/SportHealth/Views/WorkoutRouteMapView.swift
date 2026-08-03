import SwiftUI
import MapKit

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
    @State private var followCamera = true
    @State private var animTask: Task<Void, Never>?

    private var markers: [RouteSplitMarker] {
        RouteGeometry.splitMarkers(coordinates: coordinates, splits: splits)
    }

    private var animationDuration: TimeInterval {
        let meters = RouteGeometry.lengthMeters(coordinates)
        // 约 180 m/s 视觉速度，限制 5–14 秒
        return min(14, max(5, meters / 180))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            AnimatedRouteMapView(
                coordinates: coordinates,
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
        .onAppear { play(fromStart: true) }
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
        map.showsCompass = true
        map.showsScale = true
        if #available(iOS 17.0, *) {
            map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        }
        context.coordinator.fitEntireRoute(on: map, coordinates: coordinates)
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
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var tint: UIColor = .systemOrange
        private var lastVisibleSplitCount = -1
        private var lastFollowCamera: Bool?
        private var cachedLength: Double = 0
        private var ghostOverlay: MKPolyline?
        private var activeOverlay: MKPolyline?
        private var tipAnnotation: MKPointAnnotation?
        private var startAnnotation: MKPointAnnotation?
        private var endAnnotation: MKPointAnnotation?
        private var splitAnnotations: [SplitAnnotation] = []

        func fitEntireRoute(on map: MKMapView, coordinates: [CLLocationCoordinate2D], animated: Bool = false) {
            guard coordinates.count > 1 else { return }
            let poly = MKPolyline(coordinates: coordinates, count: coordinates.count)
            map.setVisibleMapRect(
                poly.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 80, left: 48, bottom: 140, right: 48),
                animated: animated
            )
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
                let region = MKCoordinateRegion(
                    center: tipCoord,
                    latitudinalMeters: followSpanMeters(progress: progress, coordinates: coordinates),
                    longitudinalMeters: followSpanMeters(progress: progress, coordinates: coordinates)
                )
                map.setRegion(region, animated: false)
            } else if lastFollowCamera != false {
                // 刚关闭跟随时，拉回全程总览
                fitEntireRoute(on: map, coordinates: coordinates, animated: true)
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

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isRotateEnabled = false
        map.showsCompass = false
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        map.isPitchEnabled = false
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        guard coordinates.count > 1 else { return }

        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        map.addOverlay(polyline)

        if let first = coordinates.first {
            let a = MKPointAnnotation(); a.coordinate = first; a.title = "起点"
            map.addAnnotation(a)
        }
        if let last = coordinates.last {
            let a = MKPointAnnotation(); a.coordinate = last; a.title = "终点"
            map.addAnnotation(a)
        }

        let rect = polyline.boundingMapRect
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: false)
        context.coordinator.tint = UIColor(tint)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var tint: UIColor = .systemOrange

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
