import Foundation

struct MovementPath {
    let points: [RouteCoordinate]
    private let cumulative: [Double]
    private let bearings: [Double]
    private let corners: [Corner]
    private let manoeuvreStops: [Double]

    private struct Corner {
        let distance: Double
        let deflection: Double
    }

    init(_ route: MovementRoute) {
        points = route.points
        var distances = [0.0]
        var headings: [Double] = []
        var turns: [Corner] = []
        var stops: [Double] = []
        for index in 1..<points.count {
            let previous = points[index - 1]
            let point = points[index]
            distances.append(distances[index - 1] + previous.distance(to: point))
            let heading = previous.bearing(to: point)
            headings.append(heading)
            if index > 1 {
                let reverseHeading = previous.bearing(to: points[index - 2])
                let change = heading - reverseHeading - .pi
                let deflection = abs(atan2(sin(change), cos(change)))
                if deflection > .pi / 12 {
                    turns.append(Corner(distance: distances[index - 1], deflection: deflection))
                }
                // Geometry can identify a sharp manoeuvre, not the presence of a stop sign or signal.
                // Skip tiny bends and densely clustered geometry to avoid artificial stop-and-go.
                let vertex = distances[index - 1]
                if route.mode == .driving, deflection >= .pi * 2 / 3,
                   vertex - distances[index - 2] >= 8, distances[index] - vertex >= 8,
                   vertex - (stops.last ?? -Double.infinity) >= 30 {
                    stops.append(vertex)
                }
            }
        }
        cumulative = distances
        bearings = headings
        corners = turns
        manoeuvreStops = stops
    }

    var length: Double { cumulative[cumulative.count - 1] }

    func coordinate(at distance: Double) -> RouteCoordinate {
        if distance <= 0 { return points[0] }
        if distance >= length { return points[points.count - 1] }
        let index = precedingIndex(for: distance, in: cumulative, value: { $0 })
        return points[index].advanced(metres: distance - cumulative[index], bearing: bearings[index])
    }

    func estimatedDuration(at distance: Double, limit: Double, pauseRemaining: Double = 0) -> Double {
        let next = precedingIndex(for: distance, in: manoeuvreStops, value: { $0 }) + 1
        let futurePauses = manoeuvreStops.count - next
        return max(0, length - distance) / limit + pauseRemaining
            + Double(futurePauses) * MovementPhysics.manoeuvrePauseSeconds
    }

    func advance(distance: Double, speed: Double, limit: Double, mode: MovementMode, elapsed: Double,
                 pauseRemaining: Double = 0) -> (distance: Double, speed: Double, pauseRemaining: Double) {
        let position = min(max(distance, 0), length)
        let dt = MovementPhysics.boundedElapsed(elapsed)
        if position >= length { return (length, 0, 0) }
        if dt == 0 { return (position, speed, pauseRemaining) }
        if pauseRemaining > 0 { return (position, 0, max(0, pauseRemaining - dt)) }

        let braking = MovementPhysics.braking(for: mode)
        let nextStopIndex = precedingIndex(for: position, in: manoeuvreStops, value: { $0 }) + 1
        let scheduledStop = nextStopIndex < manoeuvreStops.count ? manoeuvreStops[nextStopIndex] : nil
        let nextStop = scheduledStop ?? length
        var desired = min(limit, sqrt(2 * braking * (nextStop - position)))
        if mode != .walking {
            let index = precedingIndex(for: position, in: corners, value: \.distance)
            // Include the most recently crossed vertex for a short distance so speed recovers smoothly.
            for corner in corners.dropFirst(max(0, index)) {
                let ahead = max(0, corner.distance - position)
                if ahead >= desired * desired / (2 * braking) { break }
                let turnFraction = 1 - (corner.deflection / .pi) * (mode == .driving ? 0.8 : 0.7)
                let cornerSpeed = limit * turnFraction
                if corner.distance >= position || position - corner.distance <= max(0.25, cornerSpeed * 0.25) {
                    desired = min(desired, sqrt(cornerSpeed * cornerSpeed + 2 * braking * ahead))
                }
            }
        }
        let nextSpeed = MovementPhysics.approachSpeed(speed, desired, mode: mode, elapsed: dt)
        let nextPosition = min(nextStop, position + (speed + nextSpeed) * 0.5 * dt)
        if nextPosition == nextStop { return (nextStop, 0, scheduledStop == nil ? 0 : MovementPhysics.manoeuvrePauseSeconds) }
        return (nextPosition, nextSpeed, 0)
    }

    private func precedingIndex<Element>(for distance: Double, in values: [Element], value: (Element) -> Double) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let mid = low + (high - low) / 2
            if value(values[mid]) <= distance { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }
}

enum MovementPhysics {
    static let tickInterval: Duration = .milliseconds(200)
    static let manoeuvrePauseSeconds = MovementSnapshot.maximumManoeuvrePause

    static func boundedElapsed(_ elapsed: Double) -> Double {
        guard elapsed.isFinite else { return 0 }
        return min(max(0, elapsed), 0.5)
    }

    static func acceleration(for mode: MovementMode) -> Double {
        switch mode {
        case .walking: 2
        case .cycling: 2.5
        case .driving: 3
        }
    }

    static func braking(for mode: MovementMode) -> Double {
        switch mode {
        case .walking: 3
        case .cycling: 4
        case .driving: 6
        }
    }

    static func approachSpeed(_ speed: Double, _ target: Double, mode: MovementMode, elapsed: Double) -> Double {
        if target > speed { return min(target, speed + acceleration(for: mode) * elapsed) }
        return max(target, speed - braking(for: mode) * elapsed)
    }
}

struct JoystickMotion {
    private var commanded = SIMD2<Double>.zero
    private var velocity = SIMD2<Double>.zero

    var isReleased: Bool { commanded == .zero }

    mutating func setInput(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else {
            release()
            return
        }
        let input = SIMD2(min(max(x, -1), 1), min(max(y, -1), 1))
        let magnitude = hypot(input.x, input.y)
        let deadZone = 0.06
        guard magnitude > deadZone else {
            release()
            return
        }
        let fraction = (min(magnitude, 1) - deadZone) / (1 - deadZone)
        commanded = input * (fraction * fraction / magnitude)
    }

    mutating func release() {
        commanded = .zero
        velocity = .zero
    }

    mutating func advance(from position: RouteCoordinate, limit: Double, mode: MovementMode, elapsed: Double)
        -> (coordinate: RouteCoordinate, distance: Double, speed: Double) {
        let dt = MovementPhysics.boundedElapsed(elapsed)
        guard !isReleased, dt > 0 else { return (position, 0, 0) }
        let target = commanded * limit
        let change = target - velocity
        let changeMagnitude = hypot(change.x, change.y)
        let speed = hypot(velocity.x, velocity.y)
        let rate = hypot(target.x, target.y) <= speed ? MovementPhysics.braking(for: mode) : MovementPhysics.acceleration(for: mode)
        let nextVelocity = changeMagnitude > rate * dt ? velocity + change * (rate * dt / changeMagnitude) : target
        let movement = (velocity + nextVelocity) * (0.5 * dt)
        velocity = nextVelocity
        let distance = hypot(movement.x, movement.y)
        return (position.advanced(metres: distance, bearing: atan2(movement.x, movement.y)), distance,
                hypot(velocity.x, velocity.y))
    }
}
