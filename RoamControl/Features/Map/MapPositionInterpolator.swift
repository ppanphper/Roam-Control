import Foundation

/// Smooths accepted location samples for the map. These coordinates never enter the movement engine.
struct MapPositionInterpolator {
    private let duration: Duration
    private var start: RouteCoordinate?
    private var end: RouteCoordinate?
    private var sampleTime: ContinuousClock.Instant?

    init(duration: Duration) {
        self.duration = duration
    }

    var isInterpolating: Bool { start != nil }

    mutating func accept(_ sample: RouteCoordinate?, at now: ContinuousClock.Instant, interpolate: Bool) {
        guard let sample, sample.isValid else {
            start = nil
            end = nil
            sampleTime = nil
            return
        }
        if interpolate && sample == end { return }
        let previous = position(at: now)
        end = sample
        if interpolate, let previous, previous != sample, duration > .zero {
            start = previous
            sampleTime = now
        } else {
            start = nil
            sampleTime = nil
        }
    }

    func position(at now: ContinuousClock.Instant) -> RouteCoordinate? {
        guard let start, let end, let sampleTime else { return end }
        let fraction = sampleTime.duration(to: now) / duration
        guard fraction > 0 else { return start }
        guard fraction < 1 else { return end }

        // Take the short path when samples cross the antimeridian.
        let delta = Self.wrappedLongitude(end.longitude - start.longitude)
        return RouteCoordinate(latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                               longitude: Self.wrappedLongitude(start.longitude + delta * fraction))
    }

    mutating func finishIfReached(_ position: RouteCoordinate?) {
        guard position == end else { return }
        start = nil
        sampleTime = nil
    }

    private static func wrappedLongitude(_ degrees: Double) -> Double {
        if degrees > 180 { return degrees - 360 }
        if degrees < -180 { return degrees + 360 }
        return degrees
    }
}
