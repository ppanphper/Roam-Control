import Foundation

@main
struct MapPositionInterpolatorTests {
    static func main() {
        let start = ContinuousClock.now
        let a = RouteCoordinate(latitude: 60, longitude: 30)
        let b = RouteCoordinate(latitude: 62, longitude: 32)
        let c = RouteCoordinate(latitude: 64, longitude: 34)
        var marker = MapPositionInterpolator(duration: .milliseconds(200))

        marker.accept(a, at: start, interpolate: true)
        assert(marker.position(at: start) == a && !marker.isInterpolating)
        marker.accept(b, at: start, interpolate: true)
        let midpoint = start.advanced(by: .milliseconds(100))
        let end = start.advanced(by: .milliseconds(200))
        let halfAB = RouteCoordinate(latitude: 61, longitude: 31)
        assert(marker.isInterpolating && marker.position(at: start) == a)
        assert(marker.position(at: midpoint) == halfAB)
        assert(marker.position(at: end) == b)
        assert(marker.position(at: end.advanced(by: .seconds(5))) == b)
        print("PASS: starting snaps, new samples interpolate, late frames clamp")

        marker.accept(c, at: midpoint, interpolate: true)
        assert(marker.position(at: midpoint) == halfAB)
        assert(marker.position(at: end) == RouteCoordinate(latitude: 62.5, longitude: 32.5))
        let newEnd = midpoint.advanced(by: .milliseconds(200))
        assert(marker.position(at: newEnd) == c)
        marker.finishIfReached(marker.position(at: end))
        assert(marker.isInterpolating)
        marker.finishIfReached(marker.position(at: newEnd))
        assert(marker.position(at: newEnd) == c && !marker.isInterpolating)
        print("PASS: early samples retarget from the visual position; animation idles at rest")

        marker.accept(a, at: start, interpolate: true)
        marker.accept(a, at: midpoint, interpolate: false)
        assert(marker.position(at: midpoint) == a && !marker.isInterpolating)
        marker.accept(nil, at: midpoint, interpolate: true)
        assert(marker.position(at: midpoint) == nil && !marker.isInterpolating)
        marker.accept(c, at: midpoint, interpolate: true)
        assert(marker.position(at: midpoint) == c && !marker.isInterpolating)
        print("PASS: disabling animation snaps immediately; clearing drops the prior session")

        let east = RouteCoordinate(latitude: 0, longitude: 179)
        let west = RouteCoordinate(latitude: 0, longitude: -179)
        for (first, last) in [(east, west), (west, east)] {
            marker.accept(first, at: start, interpolate: false)
            marker.accept(last, at: start, interpolate: true)
            assert(marker.position(at: midpoint).map { abs($0.longitude) } == 180)
            assert(marker.position(at: end) == last)
        }
        print("PASS: date line crossings use the shorter path in both directions")
    }
}
