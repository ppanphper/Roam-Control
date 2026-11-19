import Foundation

@main
struct AuditRegressionTests {
    @MainActor
    static func main() async throws {
        var failures: [String] = []
        var checks = 0
        var suites: [String] = []
        func defaults() -> UserDefaults {
            let name = "RoamAuditRegression.\(UUID().uuidString)"
            suites.append(name)
            return UserDefaults(suiteName: name)!
        }
        defer { for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) } }
        func expect(_ value: Bool, _ label: String) {
            checks += 1
            print("\(value ? "PASS" : "FAIL"): \(label)")
            if !value { failures.append(label) }
        }
        let route = try MovementRoute(name: "Audit destination", points: [
            .init(latitude: 39.908823, longitude: 116.397470),
            .init(latitude: 39.910823, longitude: 116.399470)
        ], source: .points, mode: .walking)
        let snapshot = MovementSnapshot(route: route, mode: .walking, speedMetresPerSecond: 1.4,
                                        distanceTravelled: 0, isPaused: false, isJoystick: false)
        let movementDefaults = defaults()
        let movement = AppModel(pairingService: TestPairingService(), preferences: movementDefaults)
        await movement.restorePairingStatus()
        await movement.startMovementSession(at: route.start, snapshot: snapshot)
        expect(movement.locationHistory.first?.id == route.destination.id, "P1-01: route history records destination, not start")
        let place = LocationTarget(name: "Chosen public place", subtitle: "Original address", latitude: 39.9111,
                                   longitude: 116.3997, origin: .search)
        let roadRoute = try MovementRoute(name: place.name, points: route.points, source: .appleMaps,
                                         mode: .walking, requestedDestination: place)
        let placeApp = AppModel(pairingService: TestPairingService(), preferences: defaults())
        await placeApp.restorePairingStatus()
        let placeSnapshot = MovementSnapshot(route: roadRoute, mode: .walking, speedMetresPerSecond: 1.4,
                                             distanceTravelled: 0, isPaused: false, isJoystick: false)
        await placeApp.startMovementSession(at: roadRoute.start, snapshot: placeSnapshot)
        expect(placeApp.locationHistory.first == place, "P3: route history retains the chosen POI, address and original coordinate")
        let savedRoad = try JSONDecoder().decode(MovementRoute.self, from: JSONEncoder().encode(roadRoute))
        expect(try savedRoad.replacingMode(.cycling).historyDestination == place,
               "P3: recovery and mode changes retain the original destination")
        expect(try savedRoad.reversed().historyDestination.id == roadRoute.start.id,
               "P3: route-back history points to the other endpoint")
        expect(try savedRoad.reversed().reversed().historyDestination == place,
               "P3: reversing back retains original destination metadata")
        let originalOutput = movement.deviceSession.lastWrittenTarget!
        movement.featurePreferences.compatibility = .off
        _ = movement.updateMovementLocation(route.start, snapshot: snapshot)
        expect(movement.deviceSession.lastWrittenTarget?.latitude == originalOutput.latitude
               && movement.deviceSession.lastWrittenTarget?.longitude == originalOutput.longitude,
               "B5: changing preference cannot move an active session into another coordinate space")
        expect(!movement.canChangeCoordinateCompatibility, "B5: active coordinate preference control is disabled")
        let frozenRecord = try JSONDecoder().decode(SessionRecoveryRecord.self,
                                                    from: movementDefaults.data(forKey: "activeSessionRecovery")!)
        expect(frozenRecord.coordinateCompatibility == .automatic,
               "B5: recovery stores the coordinate mode used by the device session")
        let frozenRestart = AppModel(pairingService: TestPairingService(), preferences: movementDefaults)
        expect(frozenRestart.sessionCoordinateCompatibility == .automatic,
               "B5: restart reads saved coordinate mode even if settings changed")
        let invalidSnapshot = MovementSnapshot(route: route, mode: .walking, speedMetresPerSecond: 999,
                                               distanceTravelled: 0, isPaused: false, isJoystick: false)
        expect(movement.updateMovementLocation(route.destination, snapshot: invalidSnapshot) == .failed,
               "R5: invalid update is rejected before touching device or recovery")
        movement.continueAsFixedLocation()
        let fixed = try JSONDecoder().decode(SessionRecoveryRecord.self,
                                             from: movementDefaults.data(forKey: "activeSessionRecovery")!)
        expect(fixed.kind == .fixedLocation && fixed.movement == nil,
               "P1-02: leaving movement replaces recovery with the current fixed position")
        expect(movement.deviceSession.lastWrittenTarget == originalOutput && movement.connectionState == .active,
               "P1-02: leaving movement keeps native session and position")
        await movement.removePairingRecord()
        expect(movement.pairingOperationError != nil, "B1: blocked removal has a visible operation error")
        expect(movement.connectionState == .active, "B1: blocked removal cannot stop active session")

        let remove = AppModel(pairingService: TestPairingService(), preferences: defaults())
        await remove.restorePairingStatus()
        remove.deviceSession.emit(.failed("discovery timeout"))
        await remove.removePairingRecord()
        if case .notPaired = remove.pairingStatus { expect(true, "B1: ordinary failed session permits removing pairing") }
        else { expect(false, "B1: ordinary failed session permits removing pairing") }

        let reset = AppModel(pairingService: TestPairingService(), preferences: defaults())
        await reset.restorePairingStatus()
        reset.deviceSession.emit(.failed("discovery timeout"))
        do { try await reset.resetApp(); expect(true, "B1: ordinary failed session permits app reset") }
        catch { expect(false, "B1: ordinary failed session permits app reset") }

        let unresolved = AppModel(pairingService: TestPairingService(), preferences: defaults())
        await unresolved.restorePairingStatus()
        unresolved.deviceSession.restorationStatus = .requiresRecovery("uncertain clear")
        unresolved.deviceSession.emit(.failed("uncertain clear"))
        await unresolved.removePairingRecord()
        expect(unresolved.pairingOperationError != nil, "B1: unresolved clear still protects pairing needed for recovery")
        do { try await unresolved.resetApp(); expect(false, "B1: unresolved clear must block reset") }
        catch { expect(true, "B1: unresolved clear must block reset") }
        do { try unresolved.restoreBackup(unresolved.makeBackup()); expect(false, "B1: unresolved clear must also block backup restore") }
        catch { expect(true, "B1: unresolved clear must also block backup restore") }

        var phases: [DeviceSessionPhase] = []
        let observer = reset.observeSessionPhase { phases.append($0) }
        await Task.yield()
        reset.deviceSession.emit(.discovering)
        reset.deviceSession.emit(.active(route.start))
        expect(phases == [.discovering, .active(route.start)], "R2: asynchronous phase events reach observers without a SwiftUI view")
        reset.removeSessionPhaseObserver(observer)
        reset.deviceSession.emit(.idle)
        expect(phases.count == 2, "R2: removed observer cannot mutate a subsequent session")

        let damagedDefaults = defaults()
        var record = SessionRecoveryRecord.fixed(at: route.start)
        record.kind = .movement
        record.movement = snapshot
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        var savedMovement = object["movement"] as! [String: Any]
        savedMovement["speedMetresPerSecond"] = 999
        object["movement"] = savedMovement
        damagedDefaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "activeSessionRecovery")
        let damaged = AppModel(pairingService: TestPairingService(), preferences: damagedDefaults)
        expect(damaged.interruptedSession?.lastReportedLocation == route.start,
               "R5: damaged movement snapshot retains last position and restoration entry")
        expect(damaged.interruptedSession?.kind == .fixedLocation && damaged.interruptedSession?.movement == nil,
               "R5: damaged route offers fixed restoration without an unsafe resume")

        for mayHaveWritten in [false, true] {
            let priorDefaults = defaults()
            let prior = SessionRecoveryRecord.fixed(at: route.start)
            priorDefaults.set(try JSONEncoder().encode(prior), forKey: "activeSessionRecovery")
            let attempt = AppModel(pairingService: TestPairingService(), preferences: priorDefaults)
            await attempt.restorePairingStatus()
            attempt.deviceSession.automaticallyActivate = false
            await attempt.startLocationSession(at: place)
            attempt.deviceSession.onLocationWriteWillBegin?()
            attempt.deviceSession.didAttemptLocationWrite = mayHaveWritten
            attempt.deviceSession.restorationStatus = .requiresRecovery("prior location may still be set")
            attempt.deviceSession.emit(.failed("retry failed"))
            expect(attempt.interruptedSession?.lastReportedLocation == (mayHaveWritten ? place : route.start),
                   mayHaveWritten ? "R4: an uncertain new set keeps the candidate recovery" : "R4: proven no-write retry retains the prior location")
        }
        for terminal: DeviceSessionPhase in [.failed("set and clear uncertain"), .idle] {
            let priorDefaults = defaults()
            priorDefaults.set(try JSONEncoder().encode(SessionRecoveryRecord.fixed(at: route.start)),
                              forKey: "activeSessionRecovery")
            let attempt = AppModel(pairingService: TestPairingService(), preferences: priorDefaults)
            await attempt.restorePairingStatus()
            attempt.deviceSession.automaticallyActivate = false
            await attempt.startLocationSession(at: place)
            attempt.deviceSession.onLocationWriteWillBegin?()
            attempt.deviceSession.didAttemptLocationWrite = true
            attempt.deviceSession.restorationStatus = .requiresRecovery("new location may be set")
            attempt.deviceSession.emit(terminal)
            expect(priorDefaults.data(forKey: "priorSessionRecoveryBeforeWrite") == nil,
                   "R4: promoting uncertain recovery retires the obsolete disk fallback (\(terminal))")
            await attempt.restoreRealLocationFromInterruptedSession()
            attempt.deviceSession.restorationStatus = .requiresRecovery("clear discovery failed")
            attempt.deviceSession.emit(.failed("clear discovery failed"))
            expect(attempt.interruptedSession?.lastReportedLocation == place,
                   "R4: failed clear-only retry retains the latest uncertain location (\(terminal))")
            let restarted = AppModel(pairingService: TestPairingService(), preferences: priorDefaults)
            expect(restarted.interruptedSession?.lastReportedLocation == place,
                   "R4: restart cannot resurrect the older recovery after clear-only failure (\(terminal))")
            expect(attempt.deviceSession.restoreOnlyRequests == 1
                   && attempt.deviceSession.lastWrittenTarget == nil,
                   "R4: restoration remains clear-only (\(terminal))")
        }
        expect(RouteUnits.metric.distance(1500, locale: Locale(identifier: "en_US")) == "1.5 km"
               && RouteUnits.metric.distance(1500, locale: Locale(identifier: "de_DE")) == "1,5 km",
               "P2-05: distance formatting follows the selected language locale")
        expect(RouteUnits.metric.speed(1.5, locale: Locale(identifier: "de_DE")) == "5,4 km/h",
               "P2-05: speed formatting follows the selected language locale")
        expect(UsageAnalyticsEvent.sessionStarted(for: record) == .walkingStarted,
               "P2-08: a walking movement is not counted as a fixed location")

        print("Audit regressions: \(checks - failures.count)/\(checks) passed")
        if !failures.isEmpty { exit(1) }
    }
}
