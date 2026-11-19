import Foundation

@main
struct AppModelIntegrationTests {
    @MainActor
    static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name); checks += 1
        }
        let suite = "RoamAppModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func persistedRecovery() -> SessionRecoveryRecord? {
            defaults.data(forKey: "activeSessionRecovery").flatMap {
                try? JSONDecoder().decode(SessionRecoveryRecord.self, from: $0)
            }
        }
        defaults.set(true, forKey: "hasCompletedOnboarding")
        let app = AppModel(pairingService: TestPairingService(), preferences: defaults)
        await app.restorePairingStatus()
        let target = LocationTarget(name: "Beijing public test", subtitle: "", latitude: 39.908823, longitude: 116.397470, origin: .map)
        app.deviceSession.beforeWrite = {
            expect(defaults.data(forKey: "activeSessionRecovery") != nil, "recovery is durable before first possible device write")
        }
        await app.startLocationSession(at: target)
        app.deviceSession.beforeWrite = nil
        expect(app.connectionState == .active, "initial set acknowledged")
        expect(app.activeDisplayTarget == target, "map coordinate remains raw")
        expect(app.deviceSession.lastWrittenTarget?.latitude != target.latitude, "correction applied at device boundary")
        let saved = try JSONDecoder().decode(SessionRecoveryRecord.self, from: defaults.data(forKey: "activeSessionRecovery")!)
        expect(saved.lastReportedLocation == target, "recovery stores raw coordinate, preventing double correction")
        do { try app.restoreBackup(app.makeBackup()); preconditionFailure("active backup restore accepted") }
        catch { checks += 1 }
        do { try await app.resetApp(); preconditionFailure("active reset accepted") }
        catch { checks += 1 }

        app.stopLocationSession()
        app.deviceSession.restorationStatus = .requiresRecovery("test clear failure")
        app.deviceSession.emit(.failed("test clear failure"))
        expect(app.interruptedSession != nil, "failed clear retains recovery UI")
        expect(defaults.data(forKey: "activeSessionRecovery") != nil, "failed clear retains restart recovery")
        let relaunched = AppModel(pairingService: TestPairingService(), preferences: defaults)
        await relaunched.restorePairingStatus()
        expect(relaunched.interruptedSession?.lastReportedLocation == target, "restart loads failed-stop recovery")
        await relaunched.restoreRealLocationFromInterruptedSession()
        expect(relaunched.deviceSession.restoreOnlyRequests == 1, "restoration uses clear-only operation")
        expect(relaunched.deviceSession.lastWrittenTarget == nil, "restoration never re-applies old target")
        relaunched.deviceSession.restorationStatus = .deviceConfirmed
        relaunched.deviceSession.emit(.idle)
        expect(relaunched.interruptedSession == nil && !relaunched.isRestoringInterruptedSession, "confirmed clear dismisses restoration")
        expect(defaults.data(forKey: "activeSessionRecovery") == nil, "confirmed clear deletes persisted recovery")

        let route = try MovementRoute(name: "Test Route", points: [
            .init(latitude: 51.5, longitude: -0.12), .init(latitude: 51.501, longitude: -0.12)
        ], source: .points, mode: .cycling)
        let snapshot = MovementSnapshot(route: route, mode: .cycling, speedMetresPerSecond: 5,
                                        distanceTravelled: 0, isPaused: false, isJoystick: false)
        await relaunched.startMovementSession(at: route.start, snapshot: snapshot)
        let paused = MovementSnapshot(route: route, mode: .cycling, speedMetresPerSecond: 6,
                                      distanceTravelled: 10, isPaused: true, isJoystick: false)
        relaunched.saveMovementRecovery(at: route.start, snapshot: paused)
        let persisted = try JSONDecoder().decode(SessionRecoveryRecord.self, from: defaults.data(forKey: "activeSessionRecovery")!)
        expect(persisted.movement == paused, "pause and speed snapshot persist without 5-second delay")
        let reversedRoute = try route.reversed()
        let reversed = MovementSnapshot(route: reversedRoute, mode: .cycling, speedMetresPerSecond: 6,
                                        distanceTravelled: 10, isPaused: true, isJoystick: false)
        relaunched.saveMovementRecovery(at: reversedRoute.start, snapshot: reversed)
        let savedReverse = try JSONDecoder().decode(SessionRecoveryRecord.self, from: defaults.data(forKey: "activeSessionRecovery")!)
        expect(savedReverse.movement?.route?.id == reversedRoute.id, "route reversal persists immediately")
        let arrived = MovementSnapshot(route: reversedRoute, mode: .cycling, speedMetresPerSecond: 6,
                                       distanceTravelled: reversedRoute.distanceMetres, isPaused: false, isJoystick: false)
        _ = relaunched.updateMovementLocation(reversedRoute.destination, snapshot: arrived)
        let savedArrival = try JSONDecoder().decode(SessionRecoveryRecord.self, from: defaults.data(forKey: "activeSessionRecovery")!)
        expect(savedArrival.movement?.distanceTravelled == reversedRoute.distanceMetres, "arrival persists immediately")
        let count = relaunched.locationHistory.count
        let joystick = MovementSnapshot(route: nil, mode: .walking, speedMetresPerSecond: 1.4,
                                        distanceTravelled: 0, isPaused: false, isJoystick: true)
        await relaunched.startMovementSession(at: route.start, snapshot: joystick)
        for i in 0..<10 {
            let point = LocationTarget(name: "Joystick", subtitle: "", latitude: 51.5 + Double(i) / 10_000, longitude: -0.12, origin: .route)
            _ = relaunched.updateMovementLocation(point, snapshot: joystick)
        }
        expect(relaunched.locationHistory.count == count, "joystick updates do not flood history")
        expect(!relaunched.sharesAnonymousUsageStatistics, "all flows preserve statistics default off")
        relaunched.stopLocationSession()
        relaunched.deviceSession.restorationStatus = .requiresRecovery("manual recovery fixture")
        relaunched.deviceSession.emit(.failed("manual recovery fixture"))
        relaunched.dismissInterruptedSessionRecovery()
        expect(relaunched.interruptedSession == nil && relaunched.deviceSession.restorationStatus == .userConfirmed,
               "manual confirmation releases recovery gate without pretending device acknowledgement")
        try relaunched.restoreBackup(relaunched.makeBackup())
        expect(defaults.data(forKey: "activeSessionRecovery") == nil, "manual confirmation clears memory and disk for backup restore")

        let oldRecovery = SessionRecoveryRecord.fixed(at: target)
        let oldData = try JSONEncoder().encode(oldRecovery)
        defaults.set(oldData, forKey: "activeSessionRecovery")
        let delayedService = DelayedPairingService()
        let delayed = AppModel(pairingService: delayedService, preferences: defaults)
        await delayed.restorePairingStatus()
        let resume = Task { await delayed.startLocationSession(at: target) }
        await delayedService.waitUntilRequested()
        expect(defaults.data(forKey: "activeSessionRecovery") == oldData, "resume preserves old recovery during pairing read")
        delayed.stopLocationSession()
        await delayedService.finish(Data("fixture".utf8))
        await resume.value
        expect(delayed.deviceSession.lastWrittenTarget == nil, "cancelled preparation cannot later write location")
        expect(delayed.interruptedSession == oldRecovery, "cancelled preparation retains previous interrupted session")
        let clear = Task { await delayed.restoreRealLocationFromInterruptedSession() }
        await delayedService.waitUntilRequested()
        delayed.cancelInterruptedSessionRestoration()
        await delayedService.finish(Data("fixture".utf8))
        await clear.value
        expect(delayed.deviceSession.restoreOnlyRequests == 0 && !delayed.isRestoringInterruptedSession,
               "cancelled clear preparation cannot later start clear")
        let missingPair = Task { await delayed.startLocationSession(at: target) }
        await delayedService.waitUntilRequested()
        await delayedService.finish(nil)
        await missingPair.value
        // Re-encoding preserves all fields, but JSON object key order is not a
        // persistence contract. Compare the complete record after transitions.
        expect(delayed.interruptedSession == oldRecovery && persistedRecovery() == oldRecovery,
               "missing pairing record never deletes old recovery")

        let discoveryRetry = AppModel(pairingService: TestPairingService(), preferences: defaults)
        await discoveryRetry.restorePairingStatus()
        discoveryRetry.deviceSession.automaticallyActivate = false
        let beforeDiscovery = defaults.data(forKey: "activeSessionRecovery")
        await discoveryRetry.startLocationSession(at: route.start)
        expect(defaults.data(forKey: "activeSessionRecovery") == beforeDiscovery,
               "discovery before native write keeps original record on disk")
        discoveryRetry.deviceSession.restorationStatus = .requiresRecovery("old clear still unresolved")
        discoveryRetry.deviceSession.emit(.failed("discovery cancelled"))
        expect(discoveryRetry.interruptedSession == oldRecovery && persistedRecovery() == oldRecovery,
               "failed unwritten retry restores old record even when previous clear is unresolved")

        defaults.removeObject(forKey: "activeSessionRecovery")
        let cancelledDiscovery = AppModel(pairingService: TestPairingService(), preferences: defaults)
        await cancelledDiscovery.restorePairingStatus()
        cancelledDiscovery.deviceSession.automaticallyActivate = false
        await cancelledDiscovery.startLocationSession(at: target)
        cancelledDiscovery.stopLocationSession()
        expect(cancelledDiscovery.interruptedSession == nil, "confirmed no-write cancellation does not invent recovery")
        try cancelledDiscovery.restoreBackup(cancelledDiscovery.makeBackup())
        await delayed.restorePairingStatus()
        let first = Task { await delayed.startLocationSession(at: target) }
        await delayedService.waitUntilRequested()
        await delayed.startLocationSession(at: route.destination)
        await delayedService.finish(Data("fixture".utf8))
        await first.value
        expect(delayed.activeDisplayTarget == target, "concurrent starts cannot replace in-flight recovery metadata")
        print("PASS: \(checks) AppModel integration checks (transport double; no device execution)")
    }
}
