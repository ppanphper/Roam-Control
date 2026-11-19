import Foundation

@main struct MovementTests {
    private struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    private static func rejects(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw Failure(description: "Accepted invalid input: \(label)")
    }

    private static func point(_ lat: Double, _ lon: Double) -> RouteCoordinate { .init(latitude: lat, longitude: lon) }

    private static func testRoutesAndGPX() throws {
        let first = point(30.0000000001, 122)
        let end = point(30.25, 122.25)
        let route = try MovementRoute(name: "Creek & <Trail>", points: [first, first, end], source: .points, mode: .cycling)
        try check(route.points == [first, end], "Adjacent duplicates are removed")
        try check(route.distanceMetres > 30_000, "Route length matches coordinates")
        let reverse = try route.reversed()
        try check(reverse.start == route.destination && reverse.destination == route.start, "Reversing swaps route targets")
        let decoded = try JSONDecoder().decode(MovementRoute.self, from: JSONEncoder().encode(reverse))
        try check(decoded == reverse, "Codable round trip preserves geometry and endpoint order")
        let bad = """
        {"id":"\(route.id)","name":"Bad","points":[{"latitude":91,"longitude":0},{"latitude":0,"longitude":0}],"source":"points","mode":"walking"}
        """
        try rejects("decoded coordinates outside the valid range") {
            _ = try JSONDecoder().decode(MovementRoute.self, from: Data(bad.utf8))
        }
        try rejects("NaN") { _ = try MovementRoute(name: "Bad", points: [point(.nan, 0), end], source: .points, mode: .walking) }
        try rejects("equivalent antimeridian points") {
            _ = try MovementRoute(name: "Bad", points: [point(0, 180), point(0, -180)], source: .points, mode: .walking)
        }
        let dateline = try MovementRoute(name: "Date Line", points: [point(10, 179.999), point(10, -179.999)], source: .gpx, mode: .walking)
        let half = MovementPath(dateline).coordinate(at: dateline.distanceMetres / 2)
        try check(dateline.distanceMetres < 230 && abs(half.longitude) > 179.9999, "Date line uses short arc")

        let input = try GPXService.encode(route)
        let gpx = try GPXService.decode(input, name: "Fallback", mode: .cycling)
        try check(gpx.name == route.name && gpx.points == route.points && gpx.source == .gpx, "GPX imports its escaped title and original geometry")
        try check(gpx.start.origin == .wgs84 && gpx.destination.origin == .wgs84, "Exported GPX reports explicit WGS84 provenance")
        let east180 = try MovementRoute(name: "Edge", points: [point(-0.0000001, 180), point(0, 179.9)], source: .points, mode: .walking)
        let restored180 = try GPXService.decode(GPXService.encode(east180), name: "Edge", mode: .walking)
        try check(restored180.points[0].distance(to: east180.points[0]) < 1e-7, "GPX preserves date-line geometry and tiny decimal values")
        let joined = """
        <g:gpx xmlns:g="http://www.topografix.com/GPX/1/1" xmlns:e="urn:extension" version="1.1">
          <g:trk><g:trkseg><g:trkpt lat="0" lon="0"/><g:trkpt lat="1" lon="1"/></g:trkseg>
          <g:trkseg><g:trkpt lat="1" lon="1"/><e:trkpt lat="43" lon="44"/><g:trkpt lat="2" lon="2"/></g:trkseg></g:trk>
        </g:gpx>
        """
        let fromSegments = try GPXService.decode(Data(joined.utf8), name: "Joined", mode: .walking)
        try check(fromSegments.points == [point(0, 0), point(1, 1), point(2, 2)], "Only explicitly connected segments are joined; extensions ignored")
        let rte = "<gpx><rte><name><![CDATA[Route <Title>]]></name><rtept lat=\"0\" lon=\"0\"/><rtept lat=\"1\" lon=\"1\"/></rte></gpx>"
        let fromRte = try GPXService.decode(Data(rte.utf8), name: "Fallback", mode: .driving)
        try check(fromRte.name == "Route <Title>" && fromRte.mode == .driving, "GPX routes and CDATA names")
        let failures: [(String, String)] = [
            ("malformed XML", "<gpx><trk></gpx>"),
            ("empty route", "<gpx><rte/></gpx>"),
            ("unsupported version", rte.replacingOccurrences(of: "<gpx>", with: "<gpx version=\"1.0\">")),
            ("invalid longitude", rte.replacingOccurrences(of: "lon=\"1\"", with: "lon=\"181\"")),
            ("nonfinite latitude", rte.replacingOccurrences(of: "lat=\"1\"", with: "lat=\"nan\"")),
            ("disconnected segments", joined.replacingOccurrences(of: "<g:trkseg><g:trkpt lat=\"1\"", with: "<g:trkseg><g:trkpt lat=\"3\"")),
            ("multiple tracks or routes", rte.replacingOccurrences(of: "</gpx>", with: "<rte><rtept lat=\"3\" lon=\"4\"/></rte></gpx>")),
            ("external entity", "<!DOCTYPE gpx [<!ENTITY remote SYSTEM \"file:///dev/null\">]>" + rte.replacingOccurrences(of: "<![CDATA[Route <Title>]]>", with: "&remote;")),
            ("internal entity", "<!DOCTYPE gpx [<!ENTITY payload \"abc\">]>" + rte),
            ("mismatched XML text encoding", "<?xml version=\"1.0\" encoding=\"UTF-16\"?>" + rte)
        ]
        for (label, contents) in failures {
            try rejects(label) { _ = try GPXService.decode(Data(contents.utf8), name: "Rejected", mode: .walking) }
        }
        try rejects("excessive file size") {
            _ = try GPXService.decode(Data(count: GPXService.maximumInputBytes + 1), name: "Huge", mode: .walking)
        }
        try rejects("excessive point count even when points duplicate") {
            let giant = "<gpx><rte>" + String(repeating: "<rtept lat=\"0\" lon=\"0\"/>", count: MovementRoute.maximumPoints + 1) + "</rte></gpx>"
            _ = try GPXService.decode(Data(giant.utf8), name: "Huge", mode: .walking)
        }
        print("PASS route and GPX: JSON validation, disconnected tracks, namespace rules, unsafe XML, limits and geometry round trip")
    }

    private static func testCompatibility() throws {
        func target(_ lat: Double, _ lon: Double, _ origin: LocationOrigin?) -> LocationTarget {
            LocationTarget(name: "Test place", subtitle: "Test description", latitude: lat, longitude: lon, origin: origin)
        }
        let beijing = target(39.91022649807321, 116.4037135824225, .map)
        let repaired = CoordinateTransform.deviceTarget(beijing, compatibility: .automatic)
        try check(abs(repaired.latitude - 39.908823) < 2e-6 && abs(repaired.longitude - 116.397470) < 2e-6, "GCJ-02 inverse matches Beijing sample")
        try check(repaired.name == beijing.name && repaired.origin == beijing.origin && repaired.subtitle == beijing.subtitle, "Only destination coordinates change")
        try check(CoordinateTransform.deviceTarget(beijing, compatibility: .off) == beijing, "Off preserves coordinates")
        for origin in [LocationOrigin.search, .route] {
            let eligible = target(beijing.latitude, beijing.longitude, origin)
            try check(CoordinateTransform.deviceTarget(eligible, compatibility: .automatic).latitude == repaired.latitude, "Eligible \(origin) source corrects")
        }
        for origin in [LocationOrigin.manualCoordinate, nil] {
            let entered = target(beijing.latitude, beijing.longitude, origin)
            try check(CoordinateTransform.deviceTarget(entered, compatibility: .automatic) == entered, "Manual/WGS84 or unknown provenance remains unchanged")
            try check(CoordinateTransform.deviceTarget(entered, compatibility: .force).latitude == repaired.latitude, "Force interprets eligible mainland manual coordinates as GCJ-02")
        }
        let exclusions = [target(22.3193, 114.1694, .map), target(22.1987, 113.5439, .search),
                          target(25.033, 121.5654, .map), target(35.6895, 139.6917, .route),
                          target(51.5072, -0.1276, .map), target(37.5665, 126.978, .map),
                          target(47.9184, 106.9177, .map), target(17.96, 102.61, .map)]
        for excluded in exclusions {
            try check(CoordinateTransform.deviceTarget(excluded, compatibility: .automatic) == excluded, "Automatic excludes \(excluded.coordinate)")
            try check(CoordinateTransform.deviceTarget(excluded, compatibility: .force) == excluded, "Force still excludes \(excluded.coordinate)")
        }
        print("PASS compatibility: Beijing reference, eligible sources, explicit WGS84, unsupported regions and Off")
    }

    private static func testRedirectCompatibility() throws {
        let automatic = CoordinateCompatibility.automatic
        let mapStart = point(39.9102265, 116.4037136)
        let mapEnd = point(39.915, 116.42)
        let gpsStart = CoordinateTransform.deviceCoordinate(mapStart, origin: .route, compatibility: automatic)
        let gpsEnd = CoordinateTransform.deviceCoordinate(mapEnd, origin: .route, compatibility: automatic)
        try check(gpsStart.distance(to: mapStart) > 150, "Beijing fixture requires a cross-source comparison")

        for source in [RouteSource.points, .appleMaps, .freehand] {
            let fromGPX = try MovementRoute(name: "Map", points: [mapStart, mapEnd], source: source, mode: .walking)
            let joined = try fromGPX.joined(toDeviceCoordinate: gpsStart, compatibility: automatic)
            let firstWrite = CoordinateTransform.deviceTarget(joined.start, compatibility: automatic)
            try check(RouteCoordinate(firstWrite.coordinate).distance(to: gpsStart) < 0.001,
                      "GPX → \(source.rawValue) starts at the active device position")
            try check(joined.points.count == 2 && joined.points.last == mapEnd && joined.source == source,
                      "Same-place connector avoids a false detour and preserves native route geometry")
            let exported = try GPXService.encode(joined, compatibility: automatic)
            let reimported = try GPXService.decode(exported, name: "Reimported", mode: .walking)
            try check(reimported.points[0].distance(to: gpsStart) < 0.001 && reimported.points[1].distance(to: gpsEnd) < 0.001,
                      "GPX export and reimport preserve corrected device-space geometry")
            let decoded = try JSONDecoder().decode(MovementRoute.self, from: JSONEncoder().encode(joined))
            let reverseTarget = CoordinateTransform.deviceTarget(try decoded.reversed().destination, compatibility: automatic)
            try check(RouteCoordinate(reverseTarget.coordinate).distance(to: gpsStart) < 0.001,
                      "Persisting and reversing retains the source-specific anchor")
        }

        let road = try MovementRoute(name: "Snapped road", points: [mapStart, mapEnd], source: .appleMaps, mode: .walking)
        let park = gpsStart.advanced(metres: 480, bearing: 0)
        let longJoin = try road.joined(toDeviceCoordinate: park, compatibility: automatic)
        let connector = MovementPath(longJoin)
        let startOfRoadDistance = longJoin.points[0].distance(to: mapStart)
        try check(startOfRoadDistance > 150 && longJoin.points.dropFirst().elementsEqual(road.points),
                  "A distant MapKit snap adds a connector and preserves every road vertex")
        func devicePoint(at distance: Double) -> RouteCoordinate {
            RouteCoordinate(CoordinateTransform.deviceTarget(longJoin.target(at: connector.coordinate(at: distance)),
                                                             compatibility: automatic).coordinate)
        }
        try check(devicePoint(at: 0).distance(to: park) < 0.001, "Redirect starts at the last device position")
        let tick = connector.advance(distance: 0, speed: 0, limit: 1.4, mode: .walking, elapsed: 0.2)
        let firstStep = devicePoint(at: tick.distance).distance(to: park)
        try check(firstStep > 0 && firstStep < 0.5 && devicePoint(at: startOfRoadDistance).distance(to: gpsStart) < 0.001,
                  "The 480 m connector moves at walking speed and ends at the snapped road vertex")

        let gpx = try MovementRoute(name: "GPX", points: [gpsStart, gpsEnd], source: .gpx, mode: .cycling)
        let fromMap = try gpx.joined(toDeviceCoordinate: gpsStart, compatibility: automatic)
        try check(fromMap.points == gpx.points && fromMap.start.origin == .manualCoordinate,
                  "Map → GPX anchors at the corrected coordinate without applying correction twice")
        try rejects("GPX start is far away in device coordinates despite matching raw mainland coordinates") {
            let farGPX = try MovementRoute(name: "Far GPX", points: [mapStart, mapEnd], source: .gpx, mode: .walking)
            _ = try farGPX.joined(toDeviceCoordinate: gpsStart, compatibility: automatic)
        }

        for compatibility in [CoordinateCompatibility.off, .force] {
            let first = CoordinateTransform.deviceCoordinate(mapStart, origin: .route, compatibility: compatibility)
            let rawOffsetStart = mapStart.advanced(metres: 25, bearing: 0)
            let route = try MovementRoute(name: "Nearby", points: [rawOffsetStart, mapEnd], source: .gpx, mode: .walking)
            let joined = try route.joined(toDeviceCoordinate: first, compatibility: compatibility)
            let firstWrite = CoordinateTransform.deviceTarget(joined.start, compatibility: compatibility)
            try check(joined.points.count == 3 && joined.points[1] == rawOffsetStart,
                      "Nearby connector retains the imported route instead of moving its first point")
            try check(RouteCoordinate(firstWrite.coordinate).distance(to: first) < 0.001,
                      "Off/Force maintains the actual previously written coordinate")
        }
        print("PASS redirect: GPX ↔ map, 480 m MapKit snap connector, restored reversal and Off/Force")
    }

    private static func testForceGPXRoundTrip() throws {
        let raw = [point(39.9102265, 116.4037136), point(39.915, 116.42), point(39.924, 116.421)]
        let route = try MovementRoute(name: "Beijing", points: raw, source: .appleMaps, mode: .cycling)
        func writtenPoints(_ route: MovementRoute, _ compatibility: CoordinateCompatibility) -> [RouteCoordinate] {
            route.points.map { RouteCoordinate(CoordinateTransform.deviceTarget(route.target(at: $0), compatibility: compatibility).coordinate) }
        }
        func matches(_ left: [RouteCoordinate], _ right: [RouteCoordinate]) -> Bool {
            left.count == right.count && zip(left, right).allSatisfy { $0.distance(to: $1) < 0.001 }
        }
        let expected = writtenPoints(route, .force)
        try check(expected[0].distance(to: raw[0]) > 150, "Round trip fixture requires Force correction")
        let exported = try GPXService.encode(route, compatibility: .force)
        let reimported = try GPXService.decode(exported, name: "Import", mode: .cycling)
        try check(reimported.source == .gpx && matches(reimported.points, expected), "GPX serializes standard WGS84 coordinates")
        try check(matches(writtenPoints(reimported, .force), expected), "Force must not move any points of a reimported GPX by 0.001 m or more")
        let changedMode = try reimported.replacingMode(.driving)
        try check(changedMode.mode == .driving && matches(writtenPoints(changedMode, .force), expected),
                  "Changing imported route mode preserves explicit WGS84 provenance")
        let json = try JSONEncoder().encode(reimported)
        let restored = try JSONDecoder().decode(MovementRoute.self, from: json)
        let reversed = try restored.reversed()
        try check(matches(writtenPoints(reversed, .force), Array(expected.reversed())), "Route JSON and reversal preserve explicit WGS84")
        let joined = try restored.joined(toDeviceCoordinate: expected[0], compatibility: .force)
        try check(matches(writtenPoints(joined, .force), expected), "A GPX redirect keeps the WGS84 anchor and native route geometry")
        let exportedAgain = try GPXService.encode(joined, compatibility: .force)
        let reimportedAgain = try GPXService.decode(exportedAgain, name: "Import", mode: .cycling)
        try check(matches(writtenPoints(reimportedAgain, .force), expected), "Repeated Force exports do not accumulate displacement")

        // Unmarked files and older recovery route JSON keep the user's existing Force override.
        let external = """
        <gpx version="1.1" creator="External" xmlns="http://www.topografix.com/GPX/1/1" xmlns:ext="urn:unrelated">
          <rte><rtept lat="\(raw[0].latitude)" lon="\(raw[0].longitude)"/><rtept lat="\(raw[1].latitude)" lon="\(raw[1].longitude)"/></rte>
          <extensions><ext:deviceWGS84/></extensions>
        </gpx>
        """
        let externalRoute = try GPXService.decode(Data(external.utf8), name: "External", mode: .cycling)
        try check(externalRoute.start.origin == .manualCoordinate && matches(writtenPoints(externalRoute, .automatic), Array(raw.prefix(2))) &&
                  matches(writtenPoints(externalRoute, .force), Array(expected.prefix(2))),
                  "An external GPX works without the export marker, and an unrelated namespace cannot override Force")
        let legacy = """
        {"id":"\(route.id)","name":"Legacy","points":[{"latitude":\(raw[0].latitude),"longitude":\(raw[0].longitude)},
        {"latitude":\(raw[1].latitude),"longitude":\(raw[1].longitude)}],"source":"gpx","mode":"cycling"}
        """
        let restoredLegacy = try JSONDecoder().decode(MovementRoute.self, from: Data(legacy.utf8))
        try check(restoredLegacy.start.origin == .manualCoordinate && matches(writtenPoints(restoredLegacy, .force), Array(expected.prefix(2))),
                  "Legacy route JSON still decodes and retains Force correction")
        print("PASS GPX Force: WGS84 round trip, re-export, JSON recovery and reversal, unmarked GPX and legacy JSON")
    }

    private static func testPhysics() throws {
        let start = point(0, 0)
        let straight = try MovementRoute(name: "Straight", points: [start, point(0, 0.02)], source: .points, mode: .driving)
        let corner = try MovementRoute(name: "Corner", points: [start, point(0, 0.001), point(0.02, 0.001)], source: .points, mode: .driving)
        let straightPath = MovementPath(straight)
        let cornerPath = MovementPath(corner)
        let car = straightPath.advance(distance: 0, speed: 0, limit: 20, mode: .driving, elapsed: 0.2)
        try check(car.speed > 0 && car.speed < 20 && car.distance > 0 && car.distance < 1, "Car speeds up gradually")
        let stall = straightPath.advance(distance: 0, speed: 0, limit: 20, mode: .driving, elapsed: 60)
        try check(stall.speed <= 1.5 && stall.distance < 1, "Suspension cannot skip sixty seconds of movement")
        try check(MovementPhysics.boundedElapsed(.nan) == 0 && MovementPhysics.boundedElapsed(-0.1) == 0, "Invalid tick deltas are rejected")
        let beforeCorner = start.distance(to: corner.points[1]) - 7
        for mode in [MovementMode.driving, .cycling] {
            let straightStep = straightPath.advance(distance: beforeCorner, speed: 20, limit: 20, mode: mode, elapsed: 0.2)
            let turnStep = cornerPath.advance(distance: beforeCorner, speed: 20, limit: 20, mode: mode, elapsed: 0.2)
            try check(turnStep.speed < straightStep.speed, "\(mode) slows before a right angle")
        }
        var progress = 0.0
        var speed = 0.0
        var slowdownObserved = false
        for _ in 0..<2_000 {
            let step = straightPath.advance(distance: progress, speed: speed, limit: 20, mode: .driving, elapsed: 0.2)
            try check(step.distance >= progress && step.speed <= 20, "Car distance remains monotonic and speed capped")
            if step.distance < straightPath.length && step.distance > straightPath.length - 30 && step.speed < speed { slowdownObserved = true }
            progress = step.distance
            speed = step.speed
            if progress == straightPath.length { break }
        }
        try check(slowdownObserved && progress == straightPath.length && speed == 0, "Car brakes before and stops at the endpoint")
        let sharpTurn = try MovementRoute(name: "Hairpin", points: [start, point(0, 0.001), point(0.00012, 0.0002)],
                                          source: .points, mode: .driving)
        let sharpPath = MovementPath(sharpTurn)
        let vertex = sharpTurn.points[0].distance(to: sharpTurn.points[1])
        let baselineETA = sharpPath.length / 15
        try check(abs(sharpPath.estimatedDuration(at: 0, limit: 15) - baselineETA - 0.8) < 1e-6, "ETA includes a planned manoeuvre hold")
        var drivingStep = (distance: 0.0, speed: 0.0, pauseRemaining: 0.0)
        var heldAtVertex = 0.0
        var holdsScheduled = 0
        var passedVertex = false
        for _ in 0..<400 {
            let previous = drivingStep
            drivingStep = sharpPath.advance(distance: previous.distance, speed: previous.speed, limit: 15,
                                            mode: .driving, elapsed: 0.2, pauseRemaining: previous.pauseRemaining)
            if previous.pauseRemaining == 0 && drivingStep.pauseRemaining > 0 {
                holdsScheduled += 1
                try check(drivingStep.distance == vertex && drivingStep.speed == 0, "The car stops at the sharp manoeuvre")
            }
            if previous.pauseRemaining > 0 && drivingStep.distance == vertex { heldAtVertex += 0.2 }
            if drivingStep.distance > vertex { passedVertex = true }
            if drivingStep.distance == sharpPath.length { break }
        }
        try check(holdsScheduled == 1 && heldAtVertex >= 0.8 && passedVertex, "A manoeuvre hold occurs once and then movement resumes")
        let pauseSnapshot = MovementSnapshot(route: sharpTurn, mode: .driving, speedMetresPerSecond: 15, distanceTravelled: vertex,
                                             isPaused: false, isJoystick: false, manoeuvrePauseRemaining: 0.4)
        let decodedPause = try JSONDecoder().decode(MovementSnapshot.self, from: JSONEncoder().encode(pauseSnapshot))
        try check(decodedPause == pauseSnapshot, "Recovery includes time remaining in a manoeuvre hold")
        var joystick = JoystickMotion()
        joystick.setInput(x: 1, y: 0)
        let first = joystick.advance(from: start, limit: 5, mode: .cycling, elapsed: 0.2)
        let second = joystick.advance(from: first.coordinate, limit: 5, mode: .cycling, elapsed: 0.2)
        try check(second.speed > first.speed && second.coordinate.longitude > first.coordinate.longitude, "Joystick ramps speed to the east")
        joystick.setInput(x: 0, y: 0)
        let release = joystick.advance(from: second.coordinate, limit: 5, mode: .cycling, elapsed: 0.5)
        try check(release.coordinate == second.coordinate && release.speed == 0, "Released joystick moves no further")
        joystick.setInput(x: 0, y: 0.4)
        let north = joystick.advance(from: start, limit: 5, mode: .cycling, elapsed: 0.5)
        try check(north.coordinate.latitude > 0 && abs(north.coordinate.longitude) < 1e-8 && north.speed < 1, "Partial stick gives slow northward movement")
        joystick.setInput(x: .infinity, y: 0)
        try check(joystick.isReleased, "Nonfinite stick input stops the joystick")
        print("PASS physics: acceleration, steering, road corner braking and hold, arrival, monotonic time bounds and joystick release")
    }

    @MainActor private static func testController() async throws {
        let app = AppModel()
        let motion = MovementController()
        let route = try MovementRoute(name: "Test Run", points: [point(31, 112), point(31, 112.0002)], source: .gpx, mode: .driving)
        motion.prepare(route)
        motion.speedMetresPerSecond = 9
        await motion.start(using: app)
        try check(motion.phase == .moving && app.starts.count == 1, "Explicit start activates one route")
        try check(app.starts[0].0.origin == .manualCoordinate, "Start preserves GPX origin")
        try await Task.sleep(for: .milliseconds(660))
        try check((2...4).contains(app.writes.count), "Position updates run near 5 Hz; observed \(app.writes.count) in 660 ms")
        try check(motion.distanceTravelled > 0 && motion.currentSpeedMetresPerSecond > 0, "Controller advances route")
        motion.togglePause()
        let writesAtPause = app.writes.count
        let distanceAtPause = motion.distanceTravelled
        motion.speedMetresPerSecond = 7
        try check(motion.phase == .paused && app.saves.last?.1.speedMetresPerSecond == 7 && app.saves.last?.1.isPaused == true, "Pause and speed save immediately")
        try await Task.sleep(for: .milliseconds(240))
        try check(app.writes.count == writesAtPause, "Pausing cancels position writes")
        let current = RouteCoordinate(motion.currentCoordinate!)
        try motion.reverseRoute()
        try check(abs(motion.distanceTravelled + distanceAtPause - route.distanceMetres) < 1e-6, "Reversing preserves progress origin")
        try check(RouteCoordinate(motion.currentCoordinate!).distance(to: current) < 0.002, "Reversing does not teleport")
        guard let recovery = app.saves.last else { throw Failure(description: "No recovery checkpoint") }
        let snapshot = try JSONDecoder().decode(MovementSnapshot.self, from: JSONEncoder().encode(recovery.1))
        try check(snapshot == recovery.1, "Route recovery roundtrip agrees")
        app.needsConfirmation = true
        motion.stop(using: app)
        try check(motion.phase == .stopping, "Wait for the device after Stop")
        app.deviceSession.phase = .idle
        motion.handleSessionPhase(app.deviceSession.phase)
        try check(motion.phase == .idle && motion.currentCoordinate == nil, "Device-confirmed stop resets state")

        motion.restore(snapshot, at: recovery.0)
        try check(app.starts.count == 1 && motion.phase == .idle && motion.currentCoordinate != nil, "Restore never starts automatically")
        await motion.start(using: app)
        try check(motion.phase == .paused && motion.distanceTravelled == snapshot.distanceTravelled && motion.speedMetresPerSecond == 7, "Resume recreates the original paused route and speed")
        motion.togglePause()
        app.shouldFailUpdate = true
        try await Task.sleep(for: .milliseconds(290))
        try check(motion.phase == .failed("Device update failed"), "Device failure stops simulation and keeps its message")
        app.shouldFailUpdate = false
        app.deviceSession.phase = .idle
        motion.reset()

        let start = LocationTarget(name: "Joystick", subtitle: "", latitude: 30, longitude: 110, origin: .search)
        await motion.startJoystick(at: start, using: app)
        motion.setJoystick(x: 1, y: 0)
        try await Task.sleep(for: .milliseconds(275))
        motion.setJoystick(x: 0, y: 0)
        let writesAtRelease = app.writes.count
        guard let stickRecovery = app.writes.last else { throw Failure(description: "No joystick write") }
        try check(stickRecovery.1.isJoystick && stickRecovery.1.route == nil && stickRecovery.0.origin == .search, "Joystick preserves position and source")
        try await Task.sleep(for: .milliseconds(230))
        try check(app.writes.count == writesAtRelease && motion.currentSpeedMetresPerSecond == 0, "Joystick sends no updates after release")
        app.needsConfirmation = false
        motion.stop(using: app)
        motion.restore(stickRecovery.1, at: stickRecovery.0)
        await motion.start(using: app)
        let afterRestart = app.writes.count
        try await Task.sleep(for: .milliseconds(230))
        try check(motion.isJoystick && motion.distanceTravelled == stickRecovery.1.distanceTravelled && app.writes.count == afterRestart, "Recovered joystick remains released at its last position")
        motion.stop(using: app)

        app.shouldSuspendStartup = true
        motion.prepare(route)
        let task = Task { await motion.start(using: app) }
        for _ in 0..<30 where app.startupContinuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        guard let continuation = app.startupContinuation else { throw Failure(description: "Fixture did not suspend start") }
        motion.stop(using: app)
        continuation.resume()
        await task.value
        try check(motion.phase == .idle && app.deviceSession.phase == .idle, "Stop during a suspended startup cannot leave an active session")

        print("PASS controller: 5 Hz, pause persistence, reverse, device failure, recovery, release and stop during startup")
    }

    @MainActor static func main() async throws {
        try testRoutesAndGPX()
        try testCompatibility()
        try testRedirectCompatibility()
        try testForceGPXRoundTrip()
        try testPhysics()
        try await testController()
        let invalid = MovementSnapshot(route: nil, mode: .walking, speedMetresPerSecond: 1.4, distanceTravelled: -1, isPaused: false, isJoystick: true)
        try rejects("invalid recovery distance") { _ = try JSONDecoder().decode(MovementSnapshot.self, from: JSONEncoder().encode(invalid)) }
    }
}
