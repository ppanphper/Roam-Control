import Foundation
import MapKit

enum RouteSource: String, Codable, Sendable {
    case appleMaps, points, freehand, gpx

    var targetOrigin: LocationOrigin { self == .gpx ? .manualCoordinate : .route }
}

enum MovementRouteError: LocalizedError {
    case invalidCoordinate, insufficientPoints, tooManyPoints, redirectTooFar, redirectUnrepresentable

    var errorDescription: String? {
        switch self {
        case .invalidCoordinate: "The route contains an invalid coordinate."
        case .insufficientPoints: "A route needs at least two distinct points."
        case .tooManyPoints: "The route contains too many points."
        case .redirectTooFar: "The new route must start near the simulated location."
        case .redirectUnrepresentable: "The new route could not be joined to the simulated location."
        }
    }
}

struct MovementRoute: Codable, Equatable, Identifiable, Sendable {
    static let maximumPoints = 20_000

    let id: UUID
    let name: String
    let points: [RouteCoordinate]
    let source: RouteSource
    let mode: MovementMode
    let distanceMetres: Double
    private let startsAtNamedDestination: Bool
    private let deviceWGS84: Bool?
    private let requestedDestination: LocationTarget?

    init(name: String, points: [RouteCoordinate], source: RouteSource, mode: MovementMode,
         deviceWGS84: Bool = false, requestedDestination: LocationTarget? = nil) throws {
        try self.init(id: UUID(), name: name, points: points, source: source, mode: mode,
                      startsAtNamedDestination: false, deviceWGS84: deviceWGS84, requestedDestination: requestedDestination)
    }

    private init(id: UUID, name: String, points: [RouteCoordinate], source: RouteSource, mode: MovementMode,
                 startsAtNamedDestination: Bool, deviceWGS84: Bool, requestedDestination: LocationTarget?) throws {
        guard requestedDestination.map({ RouteCoordinate($0.coordinate).isValid }) ?? true else {
            throw MovementRouteError.invalidCoordinate
        }
        guard points.count <= Self.maximumPoints else { throw MovementRouteError.tooManyPoints }
        var cleaned: [RouteCoordinate] = []
        cleaned.reserveCapacity(points.count)
        var distance = 0.0
        for point in points {
            guard point.isValid else { throw MovementRouteError.invalidCoordinate }
            if let last = cleaned.last {
                let separation = last.distance(to: point)
                // Equivalent longitudes at the date line and at the poles are the same point.
                guard separation > 1e-8 else { continue }
                distance += separation
            }
            cleaned.append(point)
        }
        guard cleaned.count >= 2 else { throw MovementRouteError.insufficientPoints }
        self.id = id
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = title.isEmpty ? "Route" : String(title.prefix(256))
        self.points = cleaned
        self.source = source
        self.mode = mode
        self.distanceMetres = distance
        self.startsAtNamedDestination = startsAtNamedDestination
        self.deviceWGS84 = source == .gpx && deviceWGS84 ? true : nil
        self.requestedDestination = requestedDestination
    }

    var nameKey: String? {
        switch source {
        case .points: "Point Route"
        case .freehand: "Freehand Route"
        case .appleMaps, .gpx: nil
        }
    }

    var start: LocationTarget {
        startsAtNamedDestination ? target(at: points[0]) : startMarker(at: points[0])
    }

    var destination: LocationTarget {
        let point = points[points.count - 1]
        return startsAtNamedDestination ? startMarker(at: point) : target(at: point)
    }

    /// Keep the chosen place/address in history; motion still ends at the route's actual last vertex.
    var historyDestination: LocationTarget {
        startsAtNamedDestination ? destination : (requestedDestination ?? destination)
    }

    var targetOrigin: LocationOrigin { deviceWGS84 == true ? .wgs84 : source.targetOrigin }

    func target(at point: RouteCoordinate, name: String? = nil) -> LocationTarget {
        LocationTarget(name: name ?? self.name, subtitle: "Route", latitude: point.latitude, longitude: point.longitude,
                       origin: targetOrigin, nameKey: name == nil ? nameKey : nil, subtitleKey: "Route")
    }

    private func startMarker(at point: RouteCoordinate) -> LocationTarget {
        LocationTarget(name: "Route Start", subtitle: "Route", latitude: point.latitude, longitude: point.longitude,
                       origin: targetOrigin, nameKey: "Route Start", subtitleKey: "Route")
    }

    var polyline: MKPolyline {
        let coordinates = points.map(\.coordinate)
        return MKPolyline(coordinates: coordinates, count: coordinates.count)
    }

    func reversed() throws -> MovementRoute {
        try MovementRoute(id: UUID(), name: name, points: Array(points.reversed()), source: source, mode: mode,
                          startsAtNamedDestination: !startsAtNamedDestination, deviceWGS84: deviceWGS84 == true,
                          requestedDestination: requestedDestination)
    }

    func replacingPoints(_ points: [RouteCoordinate]) throws -> MovementRoute {
        try MovementRoute(id: UUID(), name: name, points: points, source: source, mode: mode,
                          startsAtNamedDestination: startsAtNamedDestination, deviceWGS84: deviceWGS84 == true,
                          requestedDestination: requestedDestination)
    }

    func replacingMode(_ mode: MovementMode) throws -> MovementRoute {
        try MovementRoute(id: UUID(), name: name, points: points, source: source, mode: mode,
                          startsAtNamedDestination: startsAtNamedDestination, deviceWGS84: deviceWGS84 == true,
                          requestedDestination: requestedDestination)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, points, source, mode, startsAtNamedDestination, deviceWGS84, requestedDestination
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var encodedPoints = try container.nestedUnkeyedContainer(forKey: .points)
        if let count = encodedPoints.count, count > Self.maximumPoints { throw MovementRouteError.tooManyPoints }
        var points: [RouteCoordinate] = []
        points.reserveCapacity(encodedPoints.count ?? 0)
        while !encodedPoints.isAtEnd {
            guard points.count < Self.maximumPoints else { throw MovementRouteError.tooManyPoints }
            points.append(try encodedPoints.decode(RouteCoordinate.self))
        }
        try self.init(id: container.decode(UUID.self, forKey: .id),
                      name: container.decode(String.self, forKey: .name),
                      points: points,
                      source: container.decode(RouteSource.self, forKey: .source),
                      mode: container.decode(MovementMode.self, forKey: .mode),
                      startsAtNamedDestination: container.decodeIfPresent(Bool.self, forKey: .startsAtNamedDestination) ?? false,
                      deviceWGS84: container.decodeIfPresent(Bool.self, forKey: .deviceWGS84) ?? false,
                      requestedDestination: container.decodeIfPresent(LocationTarget.self, forKey: .requestedDestination))
    }
}
