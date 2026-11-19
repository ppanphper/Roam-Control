import CoreLocation
import MapKit
import Observation

@MainActor
@Observable
final class RoutePlanner {
    private(set) var route: MovementRoute?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var directions: MKDirections?

    func preview(to target: LocationTarget, from source: LocationTarget? = nil, mode: MovementMode) async -> MovementRoute? {
        clear()
        guard RouteCoordinate(target.coordinate).isValid, source.map({ RouteCoordinate($0.coordinate).isValid }) ?? true else {
            errorMessage = "Choose a valid start and destination."
            return nil
        }
        guard !Task.isCancelled else { return nil }
        let request = MKDirections.Request()
        request.source = source.map(Self.mapItem(for:)) ?? .forCurrentLocation()
        request.destination = Self.mapItem(for: target)
        request.transportType = switch mode {
        case .walking: .walking
        case .cycling: .cycling
        case .driving: .automobile
        }
        request.requestsAlternateRoutes = false

        let calculation = MKDirections(request: request)
        directions = calculation
        isLoading = true
        defer {
            if directions === calculation {
                directions = nil
                isLoading = false
            }
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await calculation.calculate()
            } onCancel: {
                Task { @MainActor in calculation.cancel() }
            }
            guard directions === calculation, !Task.isCancelled else { return nil }
            guard let polyline = response.routes.first?.polyline else {
                errorMessage = "No route was found for this mode."
                return nil
            }
            // Bound the allocation even if MapKit returns an unusually dense line.
            guard polyline.pointCount <= MovementRoute.maximumPoints else { throw MovementRouteError.tooManyPoints }
            let vertices = polyline.points()
            let result = try MovementRoute(name: target.name,
                                           points: (0..<polyline.pointCount).map { RouteCoordinate(vertices[$0].coordinate) },
                                           source: .appleMaps, mode: mode, requestedDestination: target)
            route = result
            return result
        } catch {
            guard directions === calculation, !Task.isCancelled, !(error is CancellationError) else { return nil }
            if let routeError = error as? MovementRouteError {
                errorMessage = routeError.localizedDescription
            } else if mode == .cycling {
                errorMessage = "Cycling directions are unavailable. Try another route, draw a route, or import a GPX file."
            } else {
                errorMessage = "Directions are unavailable. Check Location access and your internet connection, then try again."
            }
            return nil
        }
    }

    func clear() {
        directions?.cancel()
        directions = nil
        route = nil
        isLoading = false
        errorMessage = nil
    }

    private static func mapItem(for target: LocationTarget) -> MKMapItem {
        MKMapItem(location: CLLocation(latitude: target.latitude, longitude: target.longitude), address: nil)
    }
}
