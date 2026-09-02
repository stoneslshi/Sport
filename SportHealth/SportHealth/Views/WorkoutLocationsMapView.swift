import SwiftUI
import MapKit
import HealthKit

/// 户外运动地图日记：地点气泡 + 城市/国家汇总。
struct WorkoutLocationsMapView: View {
    @Environment(HealthViewModel.self) private var vm
    let records: [WorkoutRecord]
    let rangeLabel: String

    @State private var clusterSheet: ClusterSheet?
    @State private var detailRecord: WorkoutRecord?
    @State private var fitAllToken = 0
    @State private var focusGeneration = 0
    @State private var focusCoordinates: [CLLocationCoordinate2D] = []
    @State private var places: [UUID: WorkoutPlaceInfo] = [:]
    @State private var isGeocoding = false
    @State private var sheetDetent: DiarySheetDetent = .medium
    @State private var dragOffset: CGFloat = 0
    @State private var listMode: DiaryListMode = .cities
    @State private var selectedCityID: String?
    @State private var selectedCountryID: String?

    private var pins: [WorkoutMapPin] { vm.mapPins(for: records) }
    private var recordsSignature: String {
        records.map(\.id.uuidString).sorted().joined(separator: ",")
    }

    private var cities: [MapCityStat] {
        MapDiaryAggregator.cities(pins: pins, places: places, geocodingDone: !isGeocoding)
    }

    private var countries: [MapCountryStat] {
        MapDiaryAggregator.countries(from: cities)
    }

    var body: some View {
        GeometryReader { geo in
            let sheet = displayedSheetHeight(in: geo.size.height)
            ZStack(alignment: .bottom) {
                WorkoutClusterMapView(
                    pins: pins,
                    cities: cities,
                    countries: countries,
                    fitAllToken: fitAllToken,
                    focusGeneration: focusGeneration,
                    focusCoordinates: focusCoordinates,
                    bottomPadding: sheet,
                    onSelectWorkout: { id in
                        detailRecord = records.first { $0.id == id }
                    },
                    onSelectCluster: { presentCluster(ids: $0) },
                    onSelectCity: { focusCity(id: $0) },
                    onSelectCountry: { focusCountry(id: $0) }
                )
                .ignoresSafeArea(edges: .bottom)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if sheetDetent != .expanded {
                        HStack {
                            Spacer()
                            fitAllButton
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 10)
                    }
                    MapDiaryPanel(
                        rangeLabel: rangeLabel,
                        pinCount: pins.count,
                        isLoadingPins: vm.isLoadingPins,
                        isGeocoding: isGeocoding,
                        cities: cities,
                        countries: countries,
                        listMode: $listMode,
                        selectedCityID: selectedCityID,
                        selectedCountryID: selectedCountryID,
                        onDragChanged: { dragOffset = $0 },
                        onDragEnded: { settleSheet(translation: $0) },
                        onSelectCity: handleCityTap,
                        onSelectCountry: handleCountryTap
                    )
                    .frame(height: sheet)
                }
            }
        }
        .navigationTitle("运动地图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    selectedCityID = nil
                    selectedCountryID = nil
                    fitAllToken += 1
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .disabled(pins.isEmpty)
                .accessibilityLabel("显示全部地点")
            }
        }
        .task(id: recordsSignature) {
            await vm.ensurePins(for: records)
            if Task.isCancelled { return }
            await resolvePlaces()
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

    private var fitAllButton: some View {
        Button {
            selectedCityID = nil
            selectedCountryID = nil
            fitAllToken += 1
        } label: {
            Image(systemName: "location.north.circle.fill")
                .font(.system(size: 32))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.primary, Color(.systemBackground))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        }
        .disabled(pins.isEmpty)
        .accessibilityLabel("显示全部地点")
    }

    private func displayedSheetHeight(in total: CGFloat) -> CGFloat {
        let base = sheetDetent.height(in: total)
        return min(max(base - dragOffset, DiarySheetDetent.peek.height(in: total)), total - 48)
    }

    private func settleSheet(translation: CGFloat) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            if translation > 70 {
                sheetDetent = sheetDetent.lower
            } else if translation < -70 {
                sheetDetent = sheetDetent.upper
            }
            dragOffset = 0
        }
    }

    private func handleCityTap(_ city: MapCityStat) {
        if selectedCityID == city.id {
            presentCluster(ids: city.workoutIDs)
            return
        }
        focusCity(id: city.id)
    }

    private func handleCountryTap(_ country: MapCountryStat) {
        if selectedCountryID == country.id {
            listMode = .cities
            return
        }
        focusCountry(id: country.id)
    }

    private func focusCity(id: String) {
        guard let city = cities.first(where: { $0.id == id }) else { return }
        selectedCityID = id
        selectedCountryID = nil
        listMode = .cities
        let coords = pins.filter { city.workoutIDs.contains($0.id) }.map(\.coordinate)
        focusCoordinates = coords.isEmpty ? [city.centroid] : coords
        focusGeneration += 1
    }

    private func focusCountry(id: String) {
        guard let country = countries.first(where: { $0.id == id }) else { return }
        selectedCountryID = id
        selectedCityID = nil
        listMode = .countries
        let coords = pins.filter { country.workoutIDs.contains($0.id) }.map(\.coordinate)
        focusCoordinates = coords.isEmpty ? [country.centroid] : coords
        focusGeneration += 1
    }

    private func presentCluster(ids: [UUID]) {
        let set = Set(ids)
        let list = records.filter { set.contains($0.id) }.sorted { $0.start > $1.start }
        guard !list.isEmpty else { return }
        clusterSheet = ClusterSheet(records: list)
    }

    private func resolvePlaces() async {
        let current = pins
        guard !current.isEmpty else {
            places = [:]
            isGeocoding = false
            return
        }

        var next: [UUID: WorkoutPlaceInfo] = [:]
        for pin in current {
            if let cached = WorkoutLocalCache.shared.place(id: pin.id, start: pin.start) {
                next[pin.id] = cached
            }
        }
        places = next

        var cellToPins: [String: [WorkoutMapPin]] = [:]
        for pin in current where next[pin.id] == nil {
            cellToPins[PlaceGeocodeCache.cellKey(pin.coordinate), default: []].append(pin)
        }
        guard !cellToPins.isEmpty else {
            isGeocoding = false
            return
        }

        isGeocoding = true
        defer { isGeocoding = false }

        for (_, group) in cellToPins {
            if Task.isCancelled { return }
            guard let coord = group.first?.coordinate else { continue }
            let info = await PlaceGeocoder.shared.place(for: coord)
            guard let info, info.isResolved else { continue }
            for pin in group {
                next[pin.id] = info
                let fingerprint = records.first { $0.id == pin.id }.map(WorkoutLocalCache.fingerprint(for:)) ?? ""
                WorkoutLocalCache.shared.savePlace(
                    id: pin.id,
                    start: pin.start,
                    coordinate: pin.coordinate,
                    fingerprint: fingerprint,
                    place: info
                )
            }
            places = next
        }
        let ids = Set(current.map(\.id))
        places = next.filter { ids.contains($0.key) }
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

private enum DiarySheetDetent {
    case peek, medium, expanded

    func height(in total: CGFloat) -> CGFloat {
        switch self {
        case .peek: return 158
        case .medium: return min(max(total * 0.46, 300), 430)
        case .expanded: return max(total - 52, 440)
        }
    }

    var lower: DiarySheetDetent {
        switch self {
        case .expanded: return .medium
        case .medium: return .peek
        case .peek: return .peek
        }
    }

    var upper: DiarySheetDetent {
        switch self {
        case .peek: return .medium
        case .medium: return .expanded
        case .expanded: return .expanded
        }
    }
}

private enum DiaryListMode {
    case cities, countries
}

// MARK: - 底部日记面板

private struct MapDiaryPanel: View {
    let rangeLabel: String
    let pinCount: Int
    let isLoadingPins: Bool
    let isGeocoding: Bool
    let cities: [MapCityStat]
    let countries: [MapCountryStat]
    @Binding var listMode: DiaryListMode
    let selectedCityID: String?
    let selectedCountryID: String?
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: (CGFloat) -> Void
    var onSelectCity: (MapCityStat) -> Void
    var onSelectCountry: (MapCountryStat) -> Void

    private var headline: String {
        if isLoadingPins && pinCount == 0 { return "正在读取户外轨迹…" }
        if pinCount == 0 { return "没有带 GPS 的户外运动" }
        if isGeocoding && cities.isEmpty { return "正在识别城市…" }
        return "你的足迹"
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { onDragChanged($0.translation.height) }
                        .onEnded { onDragEnded($0.translation.height) }
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.title3.weight(.bold))
                Text(MapDiaryAggregator.caption(
                    rangeLabel: rangeLabel,
                    pinCount: pinCount,
                    cities: cities,
                    countries: countries,
                    isGeocoding: isGeocoding
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            if countries.count > 1 {
                HStack(spacing: 8) {
                    modeChip("城市 \(cities.count)", active: listMode == .cities) {
                        listMode = .cities
                    }
                    modeChip("国家 \(countries.count)", active: listMode == .countries) {
                        listMode = .countries
                    }
                    Spacer(minLength: 0)
                    if isGeocoding {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            } else if !cities.isEmpty {
                HStack {
                    modeChip("城市 \(cities.count)", active: true, action: {})
                    Spacer(minLength: 0)
                    if isGeocoding { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
            }

            ScrollView {
                if listMode == .countries, countries.count > 1 {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(countries) { country in
                            Button { onSelectCountry(country) } label: {
                                MapRegionCard(
                                    title: country.name,
                                    countText: "\(country.workoutCount) 条",
                                    detailText: "\(country.cityCount) 座城市 · \(MapDiaryAggregator.kmText(country.totalKM))",
                                    stamp: MapDiaryAggregator.monthStamp(country.firstDate),
                                    selected: selectedCountryID == country.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(cities) { city in
                            Button { onSelectCity(city) } label: {
                                MapRegionCard(
                                    title: city.name,
                                    countText: "\(city.workoutCount) 条",
                                    detailText: MapDiaryAggregator.kmText(city.totalKM),
                                    stamp: MapDiaryAggregator.monthStamp(city.firstDate),
                                    selected: selectedCityID == city.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 22))
        .shadow(color: .black.opacity(0.14), radius: 18, y: -4)
    }

    private func modeChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(active ? Color.white : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(active ? Color.orange : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct MapRegionCard: View {
    let title: String
    let countText: String
    let detailText: String
    let stamp: String
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(stamp)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Spacer(minLength: 2)
            HStack(alignment: .bottom) {
                Text(countText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)
                Spacer()
                Text(detailText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "globe")
                .font(.system(size: 36))
                .foregroundStyle(.primary.opacity(0.06))
                .padding(8)
                .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? Color.orange : Color.clear, lineWidth: 2)
        )
    }
}

// MARK: - 城市 / 国家聚合

private enum MapDiaryAggregator {
    static func cities(pins: [WorkoutMapPin], places: [UUID: WorkoutPlaceInfo], geocodingDone: Bool) -> [MapCityStat] {
        var buckets: [String: [WorkoutMapPin]] = [:]
        var meta: [String: (name: String, country: String, countryKey: String)] = [:]
        for pin in pins {
            if let info = places[pin.id] {
                buckets[info.cityKey, default: []].append(pin)
                meta[info.cityKey] = (info.cityName, info.countryName, info.countryKey)
            } else if geocodingDone {
                buckets["unknown|未知地点", default: []].append(pin)
                meta["unknown|未知地点"] = ("未知地点", "未知国家", "unknown")
            }
        }
        return buckets.compactMap { key, group -> MapCityStat? in
            guard let info = meta[key], !group.isEmpty else { return nil }
            return MapCityStat(
                id: key,
                name: info.name,
                countryName: info.country,
                countryKey: info.countryKey,
                workoutCount: group.count,
                totalKM: group.reduce(0) { $0 + $1.distanceKM },
                firstDate: group.map(\.start).min() ?? group[0].start,
                lastDate: group.map(\.start).max() ?? group[0].start,
                centroid: centroid(of: group.map(\.coordinate)),
                workoutIDs: group.map(\.id)
            )
        }
        .sorted {
            if $0.workoutCount != $1.workoutCount { return $0.workoutCount > $1.workoutCount }
            return $0.totalKM > $1.totalKM
        }
    }

    static func countries(from cities: [MapCityStat]) -> [MapCountryStat] {
        var buckets: [String: [MapCityStat]] = [:]
        for city in cities {
            buckets[city.countryKey, default: []].append(city)
        }
        return buckets.map { key, group in
            let ids = group.flatMap(\.workoutIDs)
            return MapCountryStat(
                id: key,
                name: group.first?.countryName ?? key,
                cityCount: group.count,
                workoutCount: group.reduce(0) { $0 + $1.workoutCount },
                totalKM: group.reduce(0) { $0 + $1.totalKM },
                firstDate: group.map(\.firstDate).min() ?? Date(),
                lastDate: group.map(\.lastDate).max() ?? Date(),
                centroid: centroid(of: group.map(\.centroid)),
                workoutIDs: ids
            )
        }
        .sorted {
            if $0.workoutCount != $1.workoutCount { return $0.workoutCount > $1.workoutCount }
            return $0.totalKM > $1.totalKM
        }
    }

    static func centroid(of coords: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard !coords.isEmpty else {
            return CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
        let lat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
        let lon = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    static func caption(
        rangeLabel: String,
        pinCount: Int,
        cities: [MapCityStat],
        countries: [MapCountryStat],
        isGeocoding: Bool
    ) -> String {
        if pinCount == 0 {
            return "当前范围没有带定位的户外运动。换个时间或去掉类型过滤再试。"
        }
        let period = rangeLabel == "自定义" ? "这段时间" : rangeLabel
        let namedCities = cities.filter { !$0.id.hasPrefix("unknown|") }
        let namedCountries = countries.filter { $0.id != "unknown" }
        if namedCities.isEmpty {
            if isGeocoding { return "已记录 \(pinCount) 次户外运动，正在把地点收成城市…" }
            return "\(period)共 \(pinCount) 次户外运动，暂时没识别出城市。"
        }
        if namedCountries.count >= 2 {
            return "\(period)里，你跑过 \(namedCountries.count) 个国家、\(namedCities.count) 座城市。你的地图，已经有了世界的形状。"
        }
        if namedCities.count >= 2 {
            return "\(period)里，你跑过 \(namedCities.count) 座城市。足迹正在铺开成一张自己的地图。"
        }
        let name = namedCities[0].name
        return "\(period)的户外运动，都留在了\(name)。"
    }

    static func kmText(_ km: Double) -> String {
        if km <= 0 { return "—" }
        if km >= 100 { return String(format: "%.0f km", km) }
        return String(format: "%.1f km", km)
    }

    static func monthStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }
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

private enum MapLabelMode {
    case countries, cities, places

    static func resolve(span: MKCoordinateSpan, countryCount: Int, cityCount: Int) -> MapLabelMode {
        // 还没识别出城市时，继续露出地点次数气泡，避免缩小后地图空掉。
        if cityCount == 0 || span.latitudeDelta < 0.38 { return .places }
        if countryCount >= 2, span.latitudeDelta > 18 { return .countries }
        return .cities
    }

    func showsCityLabels(kind: RegionLabelAnnotation.Kind) -> Bool {
        switch kind {
        case .city: return self == .cities
        case .country: return self == .countries
        }
    }
}

/// 进入地图时先落在「一座城」的尺度，避免缩到街道或被第一批 GPS 点锁死。
private enum CameraFit {
    /// 约 70 km，刚好能看到城市标签，而不是 200 米地点气泡。
    static let minLatitudeDelta = 0.62
    static let paddingFactor = 1.28

    static func region(covering coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coords.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 35.0, longitude: 105.0),
                span: MKCoordinateSpan(latitudeDelta: minLatitudeDelta, longitudeDelta: minLatitudeDelta)
            )
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords.dropFirst() {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude)
            maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let latDelta = max((maxLat - minLat) * paddingFactor, minLatitudeDelta)
        let lonDelta = max((maxLon - minLon) * paddingFactor, minLatitudeDelta * 0.85)
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    static func mapRect(for region: MKCoordinateRegion) -> MKMapRect {
        let topLeft = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: region.center.latitude + region.span.latitudeDelta / 2,
                longitude: region.center.longitude - region.span.longitudeDelta / 2
            )
        )
        let bottomRight = MKMapPoint(
            CLLocationCoordinate2D(
                latitude: region.center.latitude - region.span.latitudeDelta / 2,
                longitude: region.center.longitude + region.span.longitudeDelta / 2
            )
        )
        return MKMapRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }
}

// MARK: - MapKit

private struct WorkoutClusterMapView: UIViewRepresentable {
    let pins: [WorkoutMapPin]
    let cities: [MapCityStat]
    let countries: [MapCountryStat]
    let fitAllToken: Int
    let focusGeneration: Int
    let focusCoordinates: [CLLocationCoordinate2D]
    let bottomPadding: CGFloat
    var onSelectWorkout: (UUID) -> Void
    var onSelectCluster: ([UUID]) -> Void
    var onSelectCity: (String) -> Void
    var onSelectCountry: (String) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = false
        map.showsScale = false
        map.isPitchEnabled = false
        if #available(iOS 17.0, *) {
            let config = MKStandardMapConfiguration(elevationStyle: .flat)
            config.emphasisStyle = .muted
            config.pointOfInterestFilter = .excludingAll
            map.preferredConfiguration = config
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectWorkout = onSelectWorkout
        coordinator.onSelectCluster = onSelectCluster
        coordinator.onSelectCity = onSelectCity
        coordinator.onSelectCountry = onSelectCountry
        coordinator.bottomPadding = bottomPadding
        coordinator.sync(pins: pins, on: map)
        coordinator.syncRegions(cities: cities, countries: countries, on: map)
        if fitAllToken != coordinator.lastFitToken {
            coordinator.lastFitToken = fitAllToken
            coordinator.userAdjustedCamera = false
            coordinator.fitAll(on: map, animated: true)
        }
        if focusGeneration != coordinator.lastFocusGeneration {
            coordinator.lastFocusGeneration = focusGeneration
            coordinator.userAdjustedCamera = true
            coordinator.fit(coordinates: focusCoordinates, on: map, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onSelectWorkout: (UUID) -> Void = { _ in }
        var onSelectCluster: ([UUID]) -> Void = { _ in }
        var onSelectCity: (String) -> Void = { _ in }
        var onSelectCountry: (String) -> Void = { _ in }
        var lastFitToken = 0
        var lastFocusGeneration = 0
        var bottomPadding: CGFloat = 160
        var userAdjustedCamera = false
        private var lastIDs: Set<UUID> = []
        private var lastCityIDs: [String] = []
        private var lastCountryIDs: [String] = []
        private var didFitOnce = false
        private var isProgrammaticFit = false
        private var labelMode: MapLabelMode = .cities

        func sync(pins: [WorkoutMapPin], on map: MKMapView) {
            let ids = Set(pins.map(\.id))
            guard ids != lastIDs else { return }
            lastIDs = ids

            // 系统 MKClusterAnnotation 与成员钉不能一次 remove，会 nil key 崩溃。
            stripSystemClusters(on: map)
            removeMatchingAnnotations(on: map) { $0 is PlaceAnnotation }
            let groups = PlaceClustering.groups(from: pins)
            if !groups.isEmpty {
                map.addAnnotations(groups.map { PlaceAnnotation(group: $0) })
            }

            if !userAdjustedCamera, !groups.isEmpty {
                fitAll(on: map, animated: didFitOnce)
                didFitOnce = true
            }
            applyLabelMode(on: map, force: true)
        }

        func syncRegions(cities: [MapCityStat], countries: [MapCountryStat], on map: MKMapView) {
            let cityIDs = cities.map(\.id)
            let countryIDs = countries.map(\.id)
            guard cityIDs != lastCityIDs || countryIDs != lastCountryIDs else {
                applyLabelMode(on: map, force: false)
                return
            }
            lastCityIDs = cityIDs
            lastCountryIDs = countryIDs

            stripSystemClusters(on: map)
            removeMatchingAnnotations(on: map) { $0 is RegionLabelAnnotation }
            var labels: [MKAnnotation] = []
            labels.append(contentsOf: cities.map { RegionLabelAnnotation(city: $0) })
            labels.append(contentsOf: countries.map { RegionLabelAnnotation(country: $0) })
            if !labels.isEmpty {
                map.addAnnotations(labels)
            }
            applyLabelMode(on: map, force: true)
        }

        /// 先单独拿掉系统聚合气泡；成员钉会重新露出来，下一拍再删。
        private func stripSystemClusters(on map: MKMapView) {
            let clusters = Array(map.annotations).compactMap { $0 as? MKClusterAnnotation }
            guard !clusters.isEmpty else { return }
            map.selectedAnnotations.forEach { map.deselectAnnotation($0, animated: false) }
            map.removeAnnotations(clusters)
        }

        private func removeMatchingAnnotations(on map: MKMapView, matching: (MKAnnotation) -> Bool) {
            let stale = Array(map.annotations).filter { annotation in
                !(annotation is MKUserLocation)
                    && !(annotation is MKClusterAnnotation)
                    && matching(annotation)
            }
            guard !stale.isEmpty else { return }
            map.selectedAnnotations.forEach { map.deselectAnnotation($0, animated: false) }
            map.removeAnnotations(stale)
        }

        func fitAll(on map: MKMapView, animated: Bool) {
            let coords = map.annotations.compactMap { $0 as? PlaceAnnotation }.map(\.coordinate)
            fitDisplayed(coords, on: map, animated: animated)
        }

        func fit(coordinates: [CLLocationCoordinate2D], on map: MKMapView, animated: Bool) {
            let display = coordinates.map { ChinaCoordinateTransform.wgs84ToGcj02($0) }
            fitDisplayed(display, on: map, animated: animated)
        }

        private func fitDisplayed(_ coords: [CLLocationCoordinate2D], on map: MKMapView, animated: Bool) {
            guard !coords.isEmpty else { return }
            let region = CameraFit.region(covering: coords)
            let rect = CameraFit.mapRect(for: region)
            isProgrammaticFit = true
            map.setVisibleMapRect(
                rect,
                edgePadding: UIEdgeInsets(top: 88, left: 36, bottom: max(bottomPadding, 160) + 16, right: 36),
                animated: animated
            )
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            guard !isProgrammaticFit, hasActivePanOrPinch(on: mapView) else { return }
            userAdjustedCamera = true
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            isProgrammaticFit = false
            applyLabelMode(on: mapView, force: false)
        }

        private func hasActivePanOrPinch(on map: MKMapView) -> Bool {
            map.subviews.contains { view in
                view.gestureRecognizers?.contains {
                    $0.state == .began || $0.state == .changed
                } == true
            }
        }

        private func applyLabelMode(on map: MKMapView, force: Bool) {
            let regions = map.annotations.compactMap { $0 as? RegionLabelAnnotation }
            let countryCount = regions.filter { $0.kind == .country }.count
            let cityCount = regions.filter { $0.kind == .city }.count
            let mode = MapLabelMode.resolve(span: map.region.span, countryCount: countryCount, cityCount: cityCount)
            guard force || mode != labelMode else { return }
            labelMode = mode
            for annotation in map.annotations {
                guard let view = map.view(for: annotation) else { continue }
                configureVisibility(view, annotation: annotation, mode: mode)
            }
        }

        private func configureVisibility(_ view: MKAnnotationView, annotation: MKAnnotation, mode: MapLabelMode) {
            if annotation is MKUserLocation { return }
            let visible: Bool
            if let region = annotation as? RegionLabelAnnotation {
                visible = mode.showsCityLabels(kind: region.kind)
            } else {
                visible = mode == .places
            }
            // MapKit 经常忽略 isHidden，用优先级控制显隐，标签才能在缩小时保住。
            view.isHidden = false
            view.alpha = visible ? 1 : 0
            view.isEnabled = visible
            view.displayPriority = visible ? .required : MKFeatureDisplayPriority(rawValue: 1)
            view.collisionMode = .none
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            for view in views {
                guard let annotation = view.annotation else { continue }
                configureVisibility(view, annotation: annotation, mode: labelMode)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let region = annotation as? RegionLabelAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: RegionLabelView.reuseId) as? RegionLabelView)
                    ?? RegionLabelView(annotation: region, reuseIdentifier: RegionLabelView.reuseId)
                view.annotation = region
                view.clusteringIdentifier = nil
                view.canShowCallout = false
                configureVisibility(view, annotation: region, mode: labelMode)
                return view
            }

            guard let place = annotation as? PlaceAnnotation else { return nil }

            if place.workoutCount > 1 {
                let id = CountBubbleView.reuseId
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? CountBubbleView)
                    ?? CountBubbleView(annotation: place, reuseIdentifier: id)
                view.annotation = place
                view.clusteringIdentifier = nil
                view.canShowCallout = false
                configureVisibility(view, annotation: place, mode: labelMode)
                return view
            }

            let id = "workout-place-single"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: place, reuseIdentifier: id)
            view.annotation = place
            view.clusteringIdentifier = nil
            view.markerTintColor = UIColor(Color(themeName: place.activityType.tintName))
            view.glyphImage = UIImage(systemName: place.activityType.symbolName)
            view.canShowCallout = false
            configureVisibility(view, annotation: place, mode: labelMode)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            if let region = annotation as? RegionLabelAnnotation {
                mapView.deselectAnnotation(annotation, animated: false)
                if region.kind == .city {
                    onSelectCity(region.regionID)
                } else {
                    onSelectCountry(region.regionID)
                }
                return
            }

            let ids = Self.workoutIDs(in: annotation)
            mapView.deselectAnnotation(annotation, animated: false)

            if let cluster = annotation as? MKClusterAnnotation {
                let clusteredIDs = Self.workoutIDs(in: cluster)
                if !clusteredIDs.isEmpty { onSelectCluster(clusteredIDs) }
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

private final class RegionLabelAnnotation: MKPointAnnotation {
    enum Kind { case city, country }

    let kind: Kind
    let regionID: String
    let count: Int
    let titleText: String

    init(city: MapCityStat) {
        kind = .city
        regionID = city.id
        count = city.workoutCount
        titleText = city.name
        super.init()
        coordinate = ChinaCoordinateTransform.wgs84ToGcj02(city.centroid)
        title = city.name
    }

    init(country: MapCountryStat) {
        kind = .country
        regionID = country.id
        count = country.workoutCount
        titleText = country.name
        super.init()
        coordinate = ChinaCoordinateTransform.wgs84ToGcj02(country.centroid)
        title = country.name
    }
}

private final class RegionLabelView: MKAnnotationView {
    static let reuseId = "region-count-label"

    private let bubble = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .none
        displayPriority = .required
        canShowCallout = false
        bubble.textAlignment = .center
        bubble.layer.cornerRadius = 14
        bubble.layer.masksToBounds = true
        bubble.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        addSubview(bubble)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowRadius = 3
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override var annotation: MKAnnotation? {
        didSet { refresh() }
    }

    private func refresh() {
        guard let region = annotation as? RegionLabelAnnotation else { return }
        let name = NSAttributedString(
            string: "\(region.titleText)  ",
            attributes: [
                .foregroundColor: UIColor.white,
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold)
            ]
        )
        let count = NSAttributedString(
            string: "\(region.count)条",
            attributes: [
                .foregroundColor: UIColor.systemOrange,
                .font: UIFont.systemFont(ofSize: 12, weight: .bold)
            ]
        )
        let text = NSMutableAttributedString(attributedString: name)
        text.append(count)
        bubble.attributedText = text
        bubble.sizeToFit()
        let size = CGSize(width: ceil(bubble.bounds.width) + 20, height: 28)
        bubble.frame = CGRect(origin: .zero, size: size)
        bounds = bubble.frame
        centerOffset = .zero
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
