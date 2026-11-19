import Foundation

enum CoordinateTransform {
    static func deviceTarget(_ target: LocationTarget, compatibility: CoordinateCompatibility) -> LocationTarget {
        let original = RouteCoordinate(target.coordinate)
        let corrected = deviceCoordinate(original, origin: target.origin, compatibility: compatibility)
        guard corrected != original else { return target }
        return replacingCoordinate(of: target, with: corrected, origin: target.origin)
    }

    static func deviceCoordinate(_ point: RouteCoordinate, origin: LocationOrigin?,
                                 compatibility: CoordinateCompatibility) -> RouteCoordinate {
        guard point.isValid, usesCorrection(origin: origin, compatibility: compatibility),
              MainlandCoordinateRegion.contains(point) else { return point }
        let corrected = wgs84(fromGCJ02: point)
        return corrected.isValid ? corrected : point
    }

    /// Express an already-written device position as input to a different source.
    /// Validate on the same final-write path, since the mainland mask has boundaries.
    static func sourceCoordinate(forDeviceCoordinate point: RouteCoordinate, origin: LocationOrigin?,
                                 compatibility: CoordinateCompatibility) -> RouteCoordinate? {
        guard point.isValid else { return nil }
        guard usesCorrection(origin: origin, compatibility: compatibility) else { return point }
        if !(17...55).contains(point.latitude) || !(72...136).contains(point.longitude) { return point }
        let offset = gcjOffset(at: point)
        let candidate = RouteCoordinate(latitude: point.latitude + offset.latitude, longitude: point.longitude + offset.longitude)
        for input in [candidate, point] where input.isValid {
            if deviceCoordinate(input, origin: origin, compatibility: compatibility).distance(to: point) < 0.001 {
                return input
            }
        }
        return nil
    }

    static func replacingCoordinate(of target: LocationTarget, with point: RouteCoordinate,
                                    origin: LocationOrigin?) -> LocationTarget {
        LocationTarget(name: target.name, subtitle: target.subtitle, latitude: point.latitude, longitude: point.longitude,
                       origin: origin, nameKey: target.nameKey, subtitleKey: target.subtitleKey)
    }

    private static func usesCorrection(origin: LocationOrigin?, compatibility: CoordinateCompatibility) -> Bool {
        switch compatibility {
        case .off: false
        case .force: origin != .wgs84
        case .automatic: origin == .map || origin == .search || origin == .route
        }
    }

    // Invert the local forward offset without replacing the coordinate used by the UI or persistence.
    private static func wgs84(fromGCJ02 point: RouteCoordinate) -> RouteCoordinate {
        var estimate = point
        for _ in 0..<8 {
            let offset = gcjOffset(at: estimate)
            let latError = estimate.latitude + offset.latitude - point.latitude
            let lonError = estimate.longitude + offset.longitude - point.longitude
            estimate.latitude -= latError
            estimate.longitude -= lonError
            if max(abs(latError), abs(lonError)) < 1e-9 { break }
        }
        return estimate
    }

    private static func gcjOffset(at point: RouteCoordinate) -> RouteCoordinate {
        let axis = 6_378_245.0
        let eccentricitySquared = 0.006693421622965943
        let x = point.longitude - 105
        let y = point.latitude - 35
        let rootX = sqrt(abs(x))
        let joint = (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        let deltaLat = -100 + (2 * x + 3 * y) + (0.2 * y * y + 0.1 * x * y) + 0.2 * rootX
            + joint + (20 * sin(y * .pi) + 40 * sin(y * .pi / 3)) * 2 / 3
            + (160 * sin(y * .pi / 12) + 320 * sin(y * .pi / 30)) * 2 / 3
        let deltaLon = 300 + (x + 2 * y) + (0.1 * x * x + 0.1 * x * y) + 0.1 * rootX
            + joint + (20 * sin(x * .pi) + 40 * sin(x * .pi / 3)) * 2 / 3
            + (150 * sin(x * .pi / 12) + 300 * sin(x * .pi / 30)) * 2 / 3
        let radians = point.latitude * .pi / 180
        let s = sin(radians)
        let magic = 1 - eccentricitySquared * s * s
        let root = sqrt(magic)
        return RouteCoordinate(
            latitude: deltaLat * 180 / (axis * (1 - eccentricitySquared) / (magic * root) * .pi),
            longitude: deltaLon * 180 / (axis / root * cos(radians) * .pi)
        )
    }
}

extension MovementRoute {
    /// Join in device coordinates first, then keep the whole new path in its own source space.
    func joined(toDeviceCoordinate current: RouteCoordinate, compatibility: CoordinateCompatibility) throws -> MovementRoute {
        guard current.isValid else { throw MovementRouteError.redirectUnrepresentable }
        let origin = targetOrigin
        let first = CoordinateTransform.deviceCoordinate(points[0], origin: origin, compatibility: compatibility)
        let distance = first.distance(to: current)
        // Apple directions can snap the first vertex to a road far from the requested start.
        // Other sources supply explicit points; keep guarding against joining the wrong route.
        guard source == .appleMaps || distance <= 150 else { throw MovementRouteError.redirectTooFar }
        guard let anchor = CoordinateTransform.sourceCoordinate(forDeviceCoordinate: current, origin: origin,
                                                                compatibility: compatibility) else {
            throw MovementRouteError.redirectUnrepresentable
        }
        // If directions snap the first vertex away from the active position, traverse the
        // connector at normal movement speed instead of writing the snapped position first.
        let tail = distance < 0.001 ? points.dropFirst() : points[...]
        return try replacingPoints([anchor] + tail)
    }
}
