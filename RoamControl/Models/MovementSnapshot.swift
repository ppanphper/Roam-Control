import Foundation

struct MovementSnapshot: Codable, Equatable, Sendable {
    static let maximumManoeuvrePause = 0.8

    let route: MovementRoute?
    let mode: MovementMode
    let speedMetresPerSecond: Double
    let distanceTravelled: Double
    let isPaused: Bool
    let isJoystick: Bool
    let manoeuvrePauseRemaining: Double

    var isValid: Bool {
        guard speedMetresPerSecond.isFinite, mode.speedRange.contains(speedMetresPerSecond),
              distanceTravelled.isFinite, distanceTravelled >= 0,
              (0...Self.maximumManoeuvrePause).contains(manoeuvrePauseRemaining),
              manoeuvrePauseRemaining == 0 || (mode == .driving && !isJoystick) else { return false }
        if isJoystick { return route == nil }
        guard let route, route.mode == mode else { return false }
        // Summation rounding may vary when decoding the same route on another architecture.
        return distanceTravelled <= route.distanceMetres + 1e-6
            && (manoeuvrePauseRemaining == 0 || distanceTravelled < route.distanceMetres)
    }

    init(route: MovementRoute?, mode: MovementMode, speedMetresPerSecond: Double, distanceTravelled: Double,
         isPaused: Bool, isJoystick: Bool, manoeuvrePauseRemaining: Double = 0) {
        self.route = route
        self.mode = mode
        self.speedMetresPerSecond = speedMetresPerSecond
        self.distanceTravelled = distanceTravelled
        self.isPaused = isPaused
        self.isJoystick = isJoystick
        self.manoeuvrePauseRemaining = manoeuvrePauseRemaining
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(route: try values.decodeIfPresent(MovementRoute.self, forKey: .route),
                  mode: try values.decode(MovementMode.self, forKey: .mode),
                  speedMetresPerSecond: try values.decode(Double.self, forKey: .speedMetresPerSecond),
                  distanceTravelled: try values.decode(Double.self, forKey: .distanceTravelled),
                  isPaused: try values.decode(Bool.self, forKey: .isPaused),
                  isJoystick: try values.decode(Bool.self, forKey: .isJoystick),
                  manoeuvrePauseRemaining: try values.decodeIfPresent(Double.self, forKey: .manoeuvrePauseRemaining) ?? 0)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid movement snapshot."))
        }
    }
}

enum MovementPhase: Equatable {
    case idle, preparing, moving, paused, arrived, stopping, failed(String)
}
