import SwiftUI
import MapKit
import HealthKit

/// 户外运动位置相簿：200 米内视为同一地点；缩小后还会继续按屏幕距离聚合。
struct WorkoutLocationsMapView: View {
    @Environment(HealthViewModel.self) private var vm
    let records: [WorkoutRecord]
    let rangeLabel: String

    @State private var clusterSheet: ClusterSheet?
    @State private var detailRecord: WorkoutRecord?
    @State private var fitAllToken = 0

    private var pins: [WorkoutMapPin] { vm.mapPins(for: records) }

    var body: some View {
        ZStack(alignment: .bottom) {
            WorkoutClusterMapView(
                pins: pins,
                fitAllToken: fitAllToken,
                onSelectWorkout: { id in
                    detailRecord = records.first { $0.id == id }
                },
                onSelectCluster: { ids in
                    let set = Set(ids)
                    let list = records.filter { set.contains($0.id) }.sorted { $0.start > $1.start }
                    guard !list.isEmpty else { return }
                    clusterSheet = ClusterSheet(records: list)
                }
            )
            .ignoresSafeArea(edges: .bottom)

            overlayBar
        }
        .navigationTitle("运动地图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    fitAllToken += 1
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .disabled(pins.isEmpty)
                .accessibilityLabel("显示全部地点")
            }
        }
        .task {
            await vm.ensurePins(for: records)
        }
        .sheet(item: $clusterSheet) { sheet in
            NavigationStack {
                clusterList(sheet.records)
            }
            .presentationDetents([.medium, .large])
        }
        .navigationDestination(isPresented: Binding(
            get: { detailRecord != nil },
            set: { if !$0 { detailRecord = nil } }
        )) {
            if let detailRecord {
                WorkoutDetailView(record: detailRecord)
            }
        }
    }

    private var overlayBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rangeLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if vm.isLoadingPins && pins.isEmpty {
                    Text("正在读取户外轨迹…")
                        .font(.subheadline.weight(.medium))
                } else if pins.isEmpty {
                    Text("没有带 GPS 的户外运动")
                        .font(.subheadline.weight(.medium))
                } else {
                    Text("\(pins.count) 次户外运动")
                        .font(.subheadline.weight(.semibold))
                }
            }
            Spacer()
            if vm.isLoadingPins {
                ProgressView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    private func clusterList(_ list: [WorkoutRecord]) -> some View {
        List {
            ForEach(list) { record in
                Button {
                    clusterSheet = nil
                    detailRecord = record
                } label: {
                    WorkoutRow(record: record)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .navigationTitle("\(list.count) 次运动")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { clusterSheet = nil }
            }
        }
    }
}

private struct ClusterSheet: Identifiable {
    let id = UUID()
    let records: [WorkoutRecord]
}

// MARK: - 200 米地理聚合

private enum PlaceClustering {
    static let mergeMeters: CLLocationDistance = 200

    static func groups(from pins: [WorkoutMapPin]) -> [PlaceGroup] {
        let n = pins.count
        guard n > 0 else { return [] }
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            if parent[i] != i { parent[i] = find(parent[i]) }
            return parent[i]
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        let locations = pins.map {
            CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        if n > 1 {
            for i in 0..<(n - 1) {
                for j in (i + 1)..<n {
                    if locations[i].distance(from: locations[j]) <= mergeMeters {
                        union(i, j)
                    }
                }
            }
        }

        var buckets: [Int: [WorkoutMapPin]] = [:]
        for i in 0..<n {
            buckets[find(i), default: []].append(pins[i])
        }
        return buckets.values.map { PlaceGroup(pins: $0) }
    }
}

private struct PlaceGroup {
    let pins: [WorkoutMapPin]

    var workoutIDs: [UUID] { pins.map(\.id) }

    var coordinate: CLLocationCoordinate2D {
        let lat = pins.map(\.coordinate.latitude).reduce(0, +) / Double(pins.count)
        let lon = pins.map(\.coordinate.longitude).reduce(0, +) / Double(pins.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var latest: WorkoutMapPin {
        pins.max { $0.start < $1.start } ?? pins[0]
    }
}

// MARK: - MapKit

private struct WorkoutClusterMapView: UIViewRepresentable {
    let pins: [WorkoutMapPin]
    let fitAllToken: Int
    var onSelectWorkout: (UUID) -> Void
    var onSelectCluster: ([UUID]) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = false
        map.isPitchEnabled = false
        if #available(iOS 17.0, *) {
            map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.onSelectWorkout = onSelectWorkout
        context.coordinator.onSelectCluster = onSelectCluster
        context.coordinator.sync(pins: pins, on: map)
        if fitAllToken != context.coordinator.lastFitToken {
            context.coordinator.lastFitToken = fitAllToken
            context.coordinator.fitAll(on: map, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onSelectWorkout: (UUID) -> Void = { _ in }
        var onSelectCluster: ([UUID]) -> Void = { _ in }
        var lastFitToken = 0
        private var lastIDs: Set<UUID> = []
        private var didInitialFit = false

        func sync(pins: [WorkoutMapPin], on map: MKMapView) {
            let ids = Set(pins.map(\.id))
            guard ids != lastIDs else { return }
            lastIDs = ids

            let existing = map.annotations.compactMap { $0 as? PlaceAnnotation }
            map.removeAnnotations(existing)
            let groups = PlaceClustering.groups(from: pins)
            map.addAnnotations(groups.map { PlaceAnnotation(group: $0) })

            if !didInitialFit, !groups.isEmpty {
                didInitialFit = true
                fitAll(on: map, animated: false)
            }
        }

        func fitAll(on map: MKMapView, animated: Bool) {
            let coords = map.annotations.compactMap { $0 as? PlaceAnnotation }.map(\.coordinate)
            guard !coords.isEmpty else { return }
            let polyline = MKPolyline(coordinates: coords, count: coords.count)
            var rect = polyline.boundingMapRect
            if rect.size.width < 200 || rect.size.height < 200 {
                rect = rect.insetBy(dx: -400, dy: -400)
            }
            map.setVisibleMapRect(
                rect,
                edgePadding: UIEdgeInsets(top: 80, left: 48, bottom: 120, right: 48),
                animated: animated
            )
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if annotation is MKClusterAnnotation {
                let id = CountBubbleView.reuseId
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? CountBubbleView)
                    ?? CountBubbleView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.displayPriority = .required
                view.clusteringIdentifier = nil
                return view
            }

            guard let place = annotation as? PlaceAnnotation else { return nil }

            if place.workoutCount > 1 {
                let id = CountBubbleView.reuseId
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? CountBubbleView)
                    ?? CountBubbleView(annotation: place, reuseIdentifier: id)
                view.annotation = place
                view.clusteringIdentifier = PlaceAnnotation.clusterID
                view.collisionMode = .circle
                view.displayPriority = .defaultHigh
                view.canShowCallout = false
                return view
            }

            let id = "workout-place-single"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: place, reuseIdentifier: id)
            view.annotation = place
            view.clusteringIdentifier = PlaceAnnotation.clusterID
            view.collisionMode = .circle
            view.displayPriority = .defaultHigh
            view.markerTintColor = UIColor(Color(themeName: place.activityType.tintName))
            view.glyphImage = UIImage(systemName: place.activityType.symbolName)
            view.canShowCallout = false
            return view
        }

        func mapView(
            _ mapView: MKMapView,
            clusterAnnotationForMemberAnnotations memberAnnotations: [any MKAnnotation]
        ) -> MKClusterAnnotation {
            let cluster = MKClusterAnnotation(memberAnnotations: memberAnnotations)
            let total = Self.workoutCount(in: memberAnnotations)
            cluster.title = "\(total) 次"
            return cluster
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            // 先拷贝成员，再取消选中——否则 MapKit 会拆掉 cluster，列表变成 0 次
            let ids = Self.workoutIDs(in: annotation)
            let memberPlaces = (annotation as? MKClusterAnnotation)?
                .memberAnnotations
                .compactMap { $0 as? PlaceAnnotation } ?? []
            mapView.deselectAnnotation(annotation, animated: false)

            if annotation is MKClusterAnnotation {
                let span = spanMeters(memberPlaces.map(\.coordinate))
                if memberPlaces.count >= 2, span > PlaceClustering.mergeMeters + 50 {
                    zoom(to: memberPlaces, on: mapView)
                } else if !ids.isEmpty {
                    onSelectCluster(ids)
                }
                return
            }

            if let place = annotation as? PlaceAnnotation {
                if place.workoutCount == 1, let id = place.workoutIDs.first {
                    onSelectWorkout(id)
                } else if !ids.isEmpty {
                    onSelectCluster(ids)
                }
            }
        }

        private func zoom(to members: [PlaceAnnotation], on map: MKMapView) {
            guard !members.isEmpty else { return }
            let coords = members.map(\.coordinate)
            let polyline = MKPolyline(coordinates: coords, count: coords.count)
            var rect = polyline.boundingMapRect
            rect = rect.insetBy(dx: -rect.size.width * 0.35 - 80, dy: -rect.size.height * 0.35 - 80)
            map.setVisibleMapRect(
                rect,
                edgePadding: UIEdgeInsets(top: 80, left: 40, bottom: 120, right: 40),
                animated: true
            )
        }

        private func spanMeters(_ coords: [CLLocationCoordinate2D]) -> Double {
            guard let first = coords.first else { return 0 }
            var maxDist = 0.0
            let origin = CLLocation(latitude: first.latitude, longitude: first.longitude)
            for c in coords.dropFirst() {
                let d = origin.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                maxDist = max(maxDist, d)
            }
            return maxDist
        }

        static func workoutIDs(in annotation: MKAnnotation) -> [UUID] {
            if let place = annotation as? PlaceAnnotation {
                return place.workoutIDs
            }
            if let cluster = annotation as? MKClusterAnnotation {
                return cluster.memberAnnotations.flatMap { workoutIDs(in: $0) }
            }
            return []
        }

        static func workoutCount(in annotations: [any MKAnnotation]) -> Int {
            annotations.reduce(0) { $0 + workoutIDs(in: $1).count }
        }
    }
}

private final class PlaceAnnotation: MKPointAnnotation {
    static let clusterID = "workout-place"

    let workoutIDs: [UUID]
    let activityType: HKWorkoutActivityType
    var workoutCount: Int { workoutIDs.count }

    init(group: PlaceGroup) {
        self.workoutIDs = group.workoutIDs
        self.activityType = group.latest.activityType
        super.init()
        coordinate = ChinaCoordinateTransform.wgs84ToGcj02(group.coordinate)
        title = workoutCount > 1 ? "\(workoutCount) 次" : group.latest.activityType.displayName
    }
}

/// 次数气泡：200 米地点 或 缩小后的屏幕聚合，数字都是运动次数。
private final class CountBubbleView: MKAnnotationView {
    static let reuseId = "workout-count-bubble"

    private let countLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .circle
        canShowCallout = false
        countLabel.textAlignment = .center
        countLabel.textColor = .white
        countLabel.font = .systemFont(ofSize: 15, weight: .bold)
        countLabel.adjustsFontSizeToFitWidth = true
        addSubview(countLabel)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 3
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override var annotation: MKAnnotation? {
        didSet { refresh() }
    }

    private func refresh() {
        let count: Int
        if let place = annotation as? PlaceAnnotation {
            count = place.workoutCount
        } else if let cluster = annotation as? MKClusterAnnotation {
            count = WorkoutClusterMapView.Coordinator.workoutCount(in: cluster.memberAnnotations)
        } else {
            count = 0
        }
        let side: CGFloat = count >= 20 ? 52 : (count >= 8 ? 46 : 40)
        bounds = CGRect(x: 0, y: 0, width: side, height: side)
        centerOffset = .zero
        countLabel.frame = bounds.insetBy(dx: 4, dy: 4)
        countLabel.text = "\(count)"
        backgroundColor = .systemOrange
        layer.cornerRadius = side / 2
    }
}
