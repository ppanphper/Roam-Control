import Foundation

struct SessionRecoveryRecord: Codable, Equatable {
    enum Kind: String, Codable {
        case fixedLocation
        case walkingRoute
        case movement
    }

    var kind: Kind
    var lastReportedLocation: LocationTarget
    var destination: LocationTarget?
    var walkingPaceMetresPerSecond: Double?
    let startedAt: Date
    var updatedAt: Date
    var movement: MovementSnapshot? = nil
    var coordinateCompatibility: CoordinateCompatibility? = nil

    private enum CodingKeys: String, CodingKey {
        case kind, lastReportedLocation, destination, walkingPaceMetresPerSecond
        case startedAt, updatedAt, movement, coordinateCompatibility
    }

    var isWalkingRoute: Bool {
        kind == .walkingRoute && destination != nil
    }

    static func fixed(at target: LocationTarget) -> SessionRecoveryRecord {
        SessionRecoveryRecord(
            kind: .fixedLocation,
            lastReportedLocation: target,
            destination: nil,
            walkingPaceMetresPerSecond: nil,
            startedAt: .now,
            updatedAt: .now
        )
    }

    static func walking(
        from start: LocationTarget,
        to destination: LocationTarget,
        paceMetresPerSecond: Double
    ) -> SessionRecoveryRecord {
        SessionRecoveryRecord(
            kind: .walkingRoute,
            lastReportedLocation: start,
            destination: destination,
            walkingPaceMetresPerSecond: paceMetresPerSecond,
            startedAt: .now,
            updatedAt: .now
        )
    }
}

extension SessionRecoveryRecord {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let position = try values.decode(LocationTarget.self, forKey: .lastReportedLocation)
        guard position.latitude.isFinite, position.longitude.isFinite,
              (-90...90).contains(position.latitude), (-180...180).contains(position.longitude) else {
            throw DecodingError.dataCorruptedError(forKey: .lastReportedLocation, in: values,
                                                  debugDescription: "Invalid last reported location.")
        }
        let kind = (try? values.decode(Kind.self, forKey: .kind)) ?? .fixedLocation
        let movement = try? values.decodeIfPresent(MovementSnapshot.self, forKey: .movement)
        self.init(kind: kind, lastReportedLocation: position,
                  destination: try? values.decodeIfPresent(LocationTarget.self, forKey: .destination),
                  walkingPaceMetresPerSecond: try? values.decodeIfPresent(Double.self, forKey: .walkingPaceMetresPerSecond),
                  startedAt: try values.decode(Date.self, forKey: .startedAt),
                  updatedAt: try values.decode(Date.self, forKey: .updatedAt),
                  movement: movement,
                  coordinateCompatibility: try? values.decodeIfPresent(CoordinateCompatibility.self, forKey: .coordinateCompatibility))
        // A damaged route must not hide the obligation to restore the device's real location.
        if (kind == .movement && movement == nil) || (kind == .walkingRoute && destination == nil) {
            self.kind = .fixedLocation
            self.destination = nil
            self.walkingPaceMetresPerSecond = nil
            self.movement = nil
        }
    }
}
