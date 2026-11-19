import Foundation

@main
struct MovementLifecycleTests {
    @MainActor
    static func main() async throws {
        var failures: [String] = []
        var count = 0
        func expect(_ value: Bool, _ label: String) {
            count += 1
            print("\(value ? "PASS" : "FAIL"): \(label)")
            if !value { failures.append(label) }
        }
        let route = try MovementRoute(name: "Lifecycle", points: [
            .init(latitude: 51.5, longitude: -0.12), .init(latitude: 51.51, longitude: -0.12)
        ], source: .points, mode: .walking)

        let cancelled = MovementController()
        let cancelApp = AppModel()
        cancelApp.startup = .discovering
        cancelled.prepare(route)
        await cancelled.start(using: cancelApp)
        expect(cancelled.phase == .preparing, "discovery leaves movement waiting for activation")
        cancelApp.deviceSession.phase = .idle
        cancelled.handleSessionPhase(.idle)
        expect(cancelled.phase == .idle, "B3: cancellation through mobile-data guidance releases preparing state")

        let motion = MovementController()
        let app = AppModel()
        app.startup = .discovering
        motion.prepare(route)
        await motion.start(using: app)
        await Task.yield()
        app.deviceSession.phase = .active(route.start)
        try await Task.sleep(for: .milliseconds(450))
        expect(motion.phase == .moving && !app.writes.isEmpty,
               "R2: delayed activation starts ticks without a SwiftUI onChange")
        let writes = app.writes.count
        app.deviceSession.phase = .discovering
        try await Task.sleep(for: .milliseconds(250))
        expect(motion.phase == .preparing && app.writes.count == writes,
               "R4: reconnecting suspends writes while preserving the route")
        app.deviceSession.phase = .active(route.start)
        try await Task.sleep(for: .milliseconds(250))
        expect(motion.phase == .moving && app.writes.count > writes, "R4: successful reconnect resumes movement")
        motion.togglePause()
        app.deviceSession.phase = .discovering
        app.deviceSession.phase = .active(route.start)
        expect(motion.phase == .paused, "R4: reconnect preserves a user's pause")
        app.deviceSession.phase = .stopping
        app.deviceSession.phase = .failed("iOS stopped the background session.")
        expect(motion.phase == .failed("iOS stopped the background session.") && motion.route == route,
               "B4: system expiry remains visible and preserves a route for restart")
        motion.reset()
        app.deviceSession.phase = .active(route.start)
        expect(motion.phase == .idle, "old observer cannot reactivate a reset controller")
        print("Movement lifecycle: \(count - failures.count)/\(count) passed")
        if !failures.isEmpty { exit(1) }
    }
}
