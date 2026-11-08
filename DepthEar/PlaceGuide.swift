import CoreLocation
import MapKit

struct NearbyPlace {
    var name: String
    var category: String?
    var coordinate: CLLocationCoordinate2D
}

/// A mapped place in a given direction.
struct FacingPlace: Equatable {
    var name: String
    var category: String?
    var distance: Double
    /// Place bearing minus the reference bearing, -180…180. Positive = right.
    var offsetDeg: Double
}

/// What the guide should say on its own. Snapshot of the tunables.
struct GuideSettings {
    /// Standing still: name the place the head points at.
    var headCallouts: Bool
    /// Walking: name the nearest place on each side.
    var sideCallouts: Bool
    /// Announce the street when it changes.
    var streetCallouts: Bool
    /// Spoken summary every this many seconds; 0 = off.
    var summaryInterval: TimeInterval
}

/// Speech priority the guide asks for. Mirrors SpeechPriority.
enum CalloutKind {
    /// Short, replaceable: head and side callouts.
    case callout
    /// Must be heard whole: street changes, walking/stopped, summaries.
    case important
}

/// GPS position, Apple Maps points of interest and streets around it, and
/// what to say about them.
///
/// Two modes, switched by ActivityMonitor:
/// - Walking: the nearest place on the left and on the right of the direction
///   of travel, spoken when either changes. Head-turn callouts are off, so the
///   two do not talk over each other.
/// - Standing: turn the head and hold still; the place in that direction is
///   spoken with where it is relative to the body ("on your left").
/// In both modes the street is announced when it changes, and a full summary
/// is spoken every `summaryInterval`.
///
/// Accuracy limits, all of which the UI states: GPS is good to roughly 5–20 m
/// outdoors and much worse indoors; bearings inherit ARKit's compass alignment
/// (off by 10°+ near steel and electronics) plus AirPods yaw drift since the
/// last recenter; reverse geocoding near a corner can name the cross street.
/// Callouts say "about" and round distances.
@MainActor
final class PlaceGuide: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let searchRadius: CLLocationDistance = 300
    /// Side callouts only consider places this close.
    static let sideRadius: CLLocationDistance = 60
    /// Search again after moving this far from the last search centre.
    private static let researchDistance: CLLocationDistance = 50
    private static let researchInterval: TimeInterval = 180
    /// Head must stay on the same place this long before it is spoken.
    private static let dwell: TimeInterval = 0.7
    private static let minimumGap: TimeInterval = 2.0
    private static let sideGap: TimeInterval = 6.0
    /// Reverse-geocode for the street at most this often, and only after
    /// moving this far. Apple throttles geocoding per app.
    private static let streetInterval: TimeInterval = 15
    private static let streetDistance: CLLocationDistance = 15

    @Published private(set) var location: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var preciseLocation = true
    @Published private(set) var facing: FacingPlace?
    @Published private(set) var left: FacingPlace?
    @Published private(set) var right: FacingPlace?
    @Published private(set) var street: String?
    @Published private(set) var isWalking = false
    @Published private(set) var placeCount = 0
    @Published private(set) var searchError: String?

    var onCallout: ((String, CalloutKind) -> Void)?

    private let manager = CLLocationManager()
    private let activity = ActivityMonitor()
    private var places: [NearbyPlace] = []
    private var lastSearchCenter: CLLocation?
    private var lastSearchTime: TimeInterval = 0
    private var searching = false

    private var candidate: (name: String?, since: TimeInterval)?
    private var lastSpoken: String?
    private var lastSpokenTime: TimeInterval = 0
    private var lastSides: (left: String?, right: String?)?
    private var lastSideTime: TimeInterval = 0

    private var geocoding = false
    private var lastStreetCheck: (location: CLLocation, time: TimeInterval)?
    private var streetAnnounced: String?
    private var settings = GuideSettings(headCallouts: true, sideCallouts: true, streetCallouts: true, summaryInterval: 300)
    private var lastSummaryTime: TimeInterval?
    private var summarizing = false
    private var bodyBearing: Double?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        manager.activityType = .otherNavigation
        activity.onChange = { [weak self] walking in
            guard let self else { return }
            self.isWalking = walking
            self.candidate = nil
            self.lastSides = nil
            self.onCallout?(walking ? "Walking." : "Stopped.", .important)
        }
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        activity.start()
        // First summary comes one interval after the app opens, not at once.
        lastSummaryTime = ProcessInfo.processInfo.systemUptime
    }

    func stop() {
        manager.stopUpdatingLocation()
        activity.stop()
        candidate = nil
        lastSides = nil
    }

    /// Call at the readout rate.
    /// - headBearing: compass bearing of the head (or the phone without head tracking).
    /// - bodyBearing: compass bearing of the phone, worn on the chest.
    func update(headBearing: Double?, bodyBearing: Double?, settings: GuideSettings) {
        self.settings = settings
        self.bodyBearing = bodyBearing
        let now = ProcessInfo.processInfo.systemUptime
        maybeSpeakSummary(headBearing: headBearing, now: now)

        guard let location else {
            facing = nil; left = nil; right = nil
            return
        }

        // Sides are relative to the direction of travel. GPS course is the
        // most reliable while moving; otherwise use where the body faces.
        let travel = Self.course(of: location) ?? bodyBearing ?? headBearing
        if let travel {
            left = Self.bestPlace(in: places, from: location.coordinate, bearing: Self.wrap(travel - 90), sideways: true)
            right = Self.bestPlace(in: places, from: location.coordinate, bearing: Self.wrap(travel + 90), sideways: true)
        } else {
            left = nil; right = nil
        }
        facing = headBearing.flatMap { Self.bestPlace(in: places, from: location.coordinate, bearing: $0, sideways: false) }

        if isWalking {
            if settings.sideCallouts { speakSidesIfChanged(now: now) }
        } else if settings.headCallouts {
            speakFacingIfSettled(headBearing: headBearing, now: now)
        }
    }

    /// Full spoken summary: street, address, accuracy, facing, sides, nearest.
    func whereAmI(headBearing: Double?) async -> String {
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            return "Location access is off. Enable it in Settings, Privacy and Security, Location Services, DepthEar."
        }
        guard let location else { return "Finding your location. Try again in a few seconds." }

        var parts: [String] = []
        let lookup = await Self.lookUp(location)
        if let lookup {
            street = lookup.street ?? street
            if let road = lookup.street { parts.append("You are on \(road).") }
            if let address = lookup.address { parts.append("Near \(address).") }
        } else {
            parts.append("Address not available.")
        }
        parts.append("Location accurate to about \(Self.roundedDistance(location.horizontalAccuracy)) metres.")
        parts.append(isWalking ? "Walking." : "Standing still.")

        let reference = bodyBearing ?? headBearing
        if let headBearing {
            parts.append("Facing \(Self.compassName(headBearing)).")
            if let facing = Self.bestPlace(in: places, from: location.coordinate, bearing: headBearing, sideways: false) {
                parts.append("Ahead: \(Self.describe(facing)).")
            }
        }
        if let left { parts.append("On your left: \(Self.describe(left)).") }
        if let right { parts.append("On your right: \(Self.describe(right)).") }
        if let nearest = nearestPlace(from: location) {
            let (bearing, distance) = Self.bearingAndDistance(from: location.coordinate, to: nearest.coordinate)
            var sentence = "Nearest mapped place: \(nearest.name), about \(Self.roundedDistance(distance)) metres"
            if let reference {
                sentence += ", at \(Self.clockPosition(Self.signedDifference(bearing, reference))) o'clock"
            }
            parts.append(sentence + ".")
        } else if places.isEmpty {
            parts.append(searching ? "Still looking up nearby places." : "No mapped places found nearby.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Callouts

    private func speakFacingIfSettled(headBearing: Double?, now: TimeInterval) {
        let name = facing?.name
        if candidate?.name != name {
            candidate = (name, now)
            return
        }
        guard let since = candidate?.since, now - since >= Self.dwell, name != lastSpoken else { return }
        guard let facing, let headBearing else {
            // Looking at nothing mapped: allow the last place to be repeated
            // when the head comes back to it.
            lastSpoken = nil
            return
        }
        guard now - lastSpokenTime >= Self.minimumGap else { return }
        lastSpoken = name
        lastSpokenTime = now
        // Where the head points relative to the body, so "on your left" means
        // the same thing as turning the head left.
        var text = Self.describe(facing)
        if let bodyBearing {
            text = Self.relativeDirection(Self.signedDifference(headBearing, bodyBearing)) + ": " + text
        }
        onCallout?(text, .callout)
    }

    private func speakSidesIfChanged(now: TimeInterval) {
        let sides = (left: left?.name, right: right?.name)
        if let last = lastSides, last.left == sides.left, last.right == sides.right { return }
        guard now - lastSideTime >= Self.sideGap else { return }
        let previous = lastSides
        lastSides = sides
        lastSideTime = now
        // Say only the side that changed, unless both did.
        var parts: [String] = []
        if let left, sides.left != previous?.left { parts.append("Left: \(Self.describe(left)).") }
        if let right, sides.right != previous?.right { parts.append("Right: \(Self.describe(right)).") }
        if !parts.isEmpty { onCallout?(parts.joined(separator: " "), .callout) }
    }

    private func maybeSpeakSummary(headBearing: Double?, now: TimeInterval) {
        guard settings.summaryInterval > 0, !summarizing,
              let last = lastSummaryTime, now - last >= settings.summaryInterval else { return }
        lastSummaryTime = now
        summarizing = true
        Task {
            let text = await whereAmI(headBearing: headBearing)
            summarizing = false
            onCallout?(text, .important)
        }
    }

    private func checkStreet(_ location: CLLocation) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !geocoding, location.horizontalAccuracy < 50 else { return }
        if let last = lastStreetCheck,
           now - last.time < Self.streetInterval || location.distance(from: last.location) < Self.streetDistance { return }
        geocoding = true
        lastStreetCheck = (location, now)
        Task {
            defer { geocoding = false }
            guard let road = await Self.lookUp(location)?.street else { return }
            street = road
            guard road != streetAnnounced else { return }
            let first = streetAnnounced == nil
            streetAnnounced = road
            if settings.streetCallouts {
                onCallout?(first ? "On \(road)." : "Now on \(road).", .important)
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            authorization = manager.authorizationStatus
            preciseLocation = manager.accuracyAuthorization == .fullAccuracy
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let latest = locations.last, latest.horizontalAccuracy >= 0 else { return }
            location = latest
            activity.noteLocation(latest)
            refreshPlacesIfNeeded(around: latest)
            checkStreet(latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; the manager keeps trying.
    }

    // MARK: Places

    private func refreshPlacesIfNeeded(around location: CLLocation) {
        let now = ProcessInfo.processInfo.systemUptime
        if searching { return }
        if let center = lastSearchCenter,
           location.distance(from: center) < Self.researchDistance,
           now - lastSearchTime < Self.researchInterval { return }
        // A very rough fix would fetch the wrong neighbourhood.
        guard location.horizontalAccuracy < 150 else { return }

        searching = true
        lastSearchCenter = location
        lastSearchTime = now
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: Self.searchRadius)
        request.pointOfInterestFilter = .includingAll
        Task {
            defer { searching = false }
            do {
                let response = try await MKLocalSearch(request: request).start()
                places = response.mapItems.compactMap(Self.place)
                placeCount = places.count
                searchError = nil
            } catch {
                searchError = "Could not look up nearby places: \(error.localizedDescription)"
                // Allow a retry on the next location update.
                lastSearchCenter = nil
            }
        }
    }

    private func nearestPlace(from location: CLLocation) -> NearbyPlace? {
        places.min {
            Self.bearingAndDistance(from: location.coordinate, to: $0.coordinate).distance
                < Self.bearingAndDistance(from: location.coordinate, to: $1.coordinate).distance
        }
    }

    private static func place(from item: MKMapItem) -> NearbyPlace? {
        guard let name = item.name, !name.isEmpty else { return nil }
        let coordinate: CLLocationCoordinate2D
        if #available(iOS 26.0, *) {
            coordinate = item.location.coordinate
        } else {
            coordinate = item.placemark.coordinate
        }
        return NearbyPlace(name: name, category: item.pointOfInterestCategory.map(categoryName), coordinate: coordinate)
    }

    /// The place closest to `bearing`, favouring nearer ones. Near places get
    /// a wider window because they span a wider angle. `sideways` looks for
    /// places beside a walking route: a ±40° window, within `sideRadius`.
    static func bestPlace(in places: [NearbyPlace], from origin: CLLocationCoordinate2D, bearing: Double, sideways: Bool) -> FacingPlace? {
        let maxDistance = sideways ? sideRadius : searchRadius
        var best: (score: Double, place: FacingPlace)?
        for place in places {
            let (placeBearing, distance) = bearingAndDistance(from: origin, to: place.coordinate)
            guard distance <= maxDistance, distance > 1 else { continue }
            let offset = signedDifference(placeBearing, bearing)
            let halfWidth = sideways ? 40 : max(15, degrees(atan(20 / distance)))
            guard abs(offset) <= halfWidth else { continue }
            let score = abs(offset) / halfWidth + distance / maxDistance
            if best == nil || score < best!.score {
                best = (score, FacingPlace(name: place.name, category: place.category, distance: distance, offsetDeg: offset))
            }
        }
        return best?.place
    }

    // MARK: Geometry and wording

    /// GPS direction of travel, when it is trustworthy.
    private static func course(of location: CLLocation) -> Double? {
        guard location.course >= 0, location.speed > 0.5,
              location.courseAccuracy >= 0, location.courseAccuracy < 30 else { return nil }
        return location.course
    }

    /// Initial great-circle bearing (degrees from true north) and distance (m).
    static func bearingAndDistance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> (bearing: Double, distance: Double) {
        let lat1 = radians(a.latitude), lat2 = radians(b.latitude)
        let dLon = radians(b.longitude - a.longitude)
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let distance = CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        return (wrap(degrees(atan2(y, x))), distance)
    }

    /// Wrapped to 0…360.
    nonisolated static func wrap(_ bearing: Double) -> Double {
        let r = bearing.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// a - b wrapped to -180…180.
    static func signedDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// Head direction relative to the body, in words.
    static func relativeDirection(_ offsetDeg: Double) -> String {
        switch offsetDeg {
        case -25...25: return "Ahead"
        case 25..<65: return "Ahead to your right"
        case 65...115: return "On your right"
        case -65 ..< -25: return "Ahead to your left"
        case -115 ... -65: return "On your left"
        default: return "Behind you"
        }
    }

    /// 12 = straight ahead, 3 = right, 9 = left.
    static func clockPosition(_ offsetDeg: Double) -> Int {
        let hour = Int((offsetDeg / 30).rounded())
        let wrapped = ((hour % 12) + 12) % 12
        return wrapped == 0 ? 12 : wrapped
    }

    static func compassName(_ bearing: Double) -> String {
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        return names[Int((bearing / 45).rounded()) % 8]
    }

    static func roundedDistance(_ metres: Double) -> Int {
        let step: Double = metres < 50 ? 5 : 10
        return max(Int(step), Int((metres / step).rounded() * step))
    }

    static func describe(_ place: FacingPlace) -> String {
        var text = place.name
        if let category = place.category { text += ", \(category)" }
        return text + ", about \(roundedDistance(place.distance)) metres"
    }

    /// MKPOICategoryPublicTransport -> "public transport".
    private static func categoryName(_ category: MKPointOfInterestCategory) -> String {
        let raw = category.rawValue.replacingOccurrences(of: "MKPOICategory", with: "")
        var words = ""
        for character in raw {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(character)
        }
        return words.lowercased()
    }

    /// Street name and short address for a location.
    private static func lookUp(_ location: CLLocation) async -> (street: String?, address: String?)? {
        if #available(iOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location: location),
                  let item = try? await request.mapItems.first else { return nil }
            let address = item.address?.shortAddress ?? item.name
            return (address.flatMap { streetName(fromShortAddress: $0) }, address)
        } else {
            guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
            let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
            let parts = [street.isEmpty ? placemark.name : street, placemark.locality].compactMap { $0 }
            return (placemark.thoroughfare, parts.isEmpty ? nil : parts.joined(separator: ", "))
        }
    }

    /// "123–125 Main St, Springfield" -> "Main St". The iOS 26 address type
    /// has no separate street field, so the house number is stripped from the
    /// first line.
    static func streetName(fromShortAddress address: String) -> String? {
        guard let firstLine = address.split(separator: ",").first else { return nil }
        let words = firstLine.split(separator: " ").drop { $0.contains(where: \.isNumber) }
        let name = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
