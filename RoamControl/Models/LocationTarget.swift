import CoreLocation

enum LocationOrigin: String, Codable, Sendable {
    case map, search, manualCoordinate, route, wgs84
}

struct LocationTarget: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double
    var origin: LocationOrigin? = nil
    // Only app-generated labels have keys. MapKit and user-entered names remain verbatim.
    var nameKey: String? = nil
    var subtitleKey: String? = nil

    var id: String {
        "\(latitude.bitPattern)-\(longitude.bitPattern)"
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
