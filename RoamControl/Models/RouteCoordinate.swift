import CoreLocation
import Foundation

struct RouteCoordinate: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && CLLocationCoordinate2DIsValid(coordinate)
    }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    func distance(to other: Self) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLat = (lat2 - lat1) / 2
        let dLon = Self.wrapLongitude(other.longitude - longitude) * .pi / 360
        let haversine = pow(sin(dLat), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon), 2)
        return 2 * Self.earthRadius * asin(sqrt(min(max(haversine, 0), 1)))
    }

    func bearing(to other: Self) -> Double {
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let dLon = Self.wrapLongitude(other.longitude - longitude) * .pi / 180
        return atan2(sin(dLon) * cos(lat2), cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon))
    }

    func advanced(metres: Double, bearing: Double) -> Self {
        guard metres > 0 else { return self }
        let lat1 = latitude * .pi / 180
        let lon1 = longitude * .pi / 180
        let arc = metres / Self.earthRadius
        let lat2 = asin(min(max(sin(lat1) * cos(arc) + cos(lat1) * sin(arc) * cos(bearing), -1), 1))
        let lon2 = lon1 + atan2(sin(bearing) * sin(arc) * cos(lat1), cos(arc) - sin(lat1) * sin(lat2))
        return Self(latitude: lat2 * 180 / .pi, longitude: Self.wrapLongitude(lon2 * 180 / .pi))
    }

    private static let earthRadius = 6_371_008.8

    private static func wrapLongitude(_ degrees: Double) -> Double {
        let wrapped = (degrees + 180).truncatingRemainder(dividingBy: 360)
        return (wrapped < 0 ? wrapped + 360 : wrapped) - 180
    }
}
