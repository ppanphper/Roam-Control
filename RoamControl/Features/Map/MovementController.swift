import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class MovementController {
    private(set) var phase: MovementPhase = .idle
    private(set) var route: MovementRoute?
    private(set) var currentCoordinate: CLLocationCoordinate2D?
    private(set) var distanceTravelled = 0.0
    private(set) var currentSpeedMetresPerSecond = 0.0
    private(set) var isJoystick = false

    private var selectedMode: MovementMode = .walking
    private var speedLimit = MovementMode.walking.defaultSpeedMetresPerSecond
    private var routeLength = 0.0
    private var manoeuvrePauseRemaining = 0.0

    @ObservationIgnored private var path: MovementPath?
    @ObservationIgnored private var joystick = JoystickMotion()
    @ObservationIgnored private var joystickAnchor: LocationTarget?
    @ObservationIgnored private var pendingResumePaused = false
    @ObservationIgnored private var movementTask: Task<Void, Never>?
    @ObservationIgnored private var startInProgress = false
    @ObservationIgnored private var startGeneration = UUID()
    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private var phaseObserverID: UUID?

    var mode: MovementMode {
        get { selectedMode }
        set {
            guard !locksDestination, selectedMode != newValue else { return }
            reset()
            selectedMode = newValue
            speedLimit = newValue.defaultSpeedMetresPerSecond
        }
    }

    var speedMetresPerSecond: Double {
        get { speedLimit }
        set {
            guard newValue.isFinite else { return }
            let speed = mode.limitedSpeed(newValue)
            guard speed != speedLimit else { return }
            speedLimit = speed
            saveCheckpoint()
        }
    }

    var progress: Double { routeLength > 0 ? min(distanceTravelled / routeLength, 1) : 0 }
    var remainingDistance: Double { max(routeLength - distanceTravelled, 0) }
    /// Approximation at the selected speed, including planned manoeuvre holds.
    var remainingDuration: TimeInterval {
        path?.estimatedDuration(at: distanceTravelled, limit: speedLimit, pauseRemaining: manoeuvrePauseRemaining) ?? 0
    }

    var locksDestination: Bool {
        switch phase {
        case .preparing, .moving, .paused, .arrived, .stopping: true
        case .idle, .failed: false
        }
    }

    func prepare(_ route: MovementRoute) {
        guard !locksDestination, !startInProgress else { return }
        reset()
        if mode != route.mode {
            selectedMode = route.mode
            speedLimit = route.mode.defaultSpeedMetresPerSecond
        }
        installRoute(route)
    }

    func start(using appModel: AppModel) async {
        guard !locksDestination, !startInProgress else { return }
        guard let position = currentTarget ?? route?.start else { return }
        currentCoordinate = position.coordinate
        await start(at: position, using: appModel)
    }

    func startJoystick(at position: LocationTarget, using appModel: AppModel) async {
        guard !locksDestination, !startInProgress else { return }
        guard RouteCoordinate(position.coordinate).isValid else {
            phase = .failed("Choose a valid position for the joystick.")
            return
        }
        reset()
        isJoystick = true
        joystickAnchor = position
        currentCoordinate = position.coordinate
        await start(at: position, using: appModel)
    }

    func setJoystick(x: Double, y: Double) {
        guard isJoystick, phase == .moving else { return }
        joystick.setInput(x: x, y: y)
        if joystick.isReleased { currentSpeedMetresPerSecond = 0 }
    }

    func togglePause() {
        switch phase {
        case .moving:
            stopTicks()
            phase = .paused
            pendingResumePaused = true
            saveCheckpoint()
        case .paused:
            phase = .moving
            pendingResumePaused = false
            saveCheckpoint()
            beginTicks()
        default:
            break
        }
    }

    func reverseRoute() throws {
        guard let route, phase != .preparing, phase != .stopping, !startInProgress else { return }
        let reversed = try route.reversed()
        let priorPosition = distanceTravelled
        let isLive = phase == .moving || phase == .paused || phase == .arrived
        let shouldKeepPosition = isLive || currentCoordinate != nil
        let newDistance = shouldKeepPosition ? max(0, routeLength - priorPosition) : 0
        stopTicks()
        installRoute(reversed)
        manoeuvrePauseRemaining = 0
        distanceTravelled = min(newDistance, routeLength)
        if shouldKeepPosition { currentCoordinate = path?.coordinate(at: distanceTravelled).coordinate }
        if isLive {
            if phase == .arrived { phase = .moving }
            saveCheckpoint()
            if phase == .moving { beginTicks() }
        }
    }

    func restore(_ snapshot: MovementSnapshot, at position: LocationTarget) {
        guard !locksDestination, !startInProgress else { return }
        reset()
        guard snapshot.isValid, RouteCoordinate(position.coordinate).isValid else {
            phase = .failed("This movement session could not be restored.")
            return
        }
        selectedMode = snapshot.mode
        speedLimit = snapshot.speedMetresPerSecond
        if let route = snapshot.route { installRoute(route) }
        distanceTravelled = snapshot.isJoystick ? snapshot.distanceTravelled : min(snapshot.distanceTravelled, routeLength)
        isJoystick = snapshot.isJoystick
        if snapshot.isJoystick { joystickAnchor = position }
        currentCoordinate = position.coordinate
        pendingResumePaused = snapshot.isPaused
        manoeuvrePauseRemaining = snapshot.manoeuvrePauseRemaining
    }

    func handleSessionPhase(_ devicePhase: DeviceSessionPhase) {
        switch devicePhase {
        case .active:
            guard phase == .preparing, !startInProgress else { return }
            if pendingResumePaused { phase = .paused }
            else if !isJoystick && distanceTravelled >= routeLength { phase = .arrived }
            else { phase = .moving }
            saveCheckpoint()
            if phase == .moving { beginTicks() }
        case .stopping:
            guard locksDestination || isFailure else { return }
            stopTicks()
            phase = .stopping
        case .idle:
            guard !startInProgress else { return }
            if phase == .stopping || phase == .preparing { reset() }
            else if phase == .moving || phase == .paused || phase == .arrived {
                fail("The active location session ended before movement finished.")
            }
        case .failed(let message):
            guard locksDestination || isFailure else { return }
            fail(message)
        case .openingLocalDevVPN, .discovering, .connecting:
            if phase == .moving || phase == .paused || phase == .arrived {
                pendingResumePaused = phase == .paused || pendingResumePaused
                stopTicks()
                phase = .preparing
            }
        }
    }

    func stop(using appModel: AppModel) {
        guard locksDestination || isFailure else { return }
        startGeneration = UUID()
        startInProgress = false
        stopTicks()
        phase = .stopping
        appModel.stopLocationSession()
        handleSessionPhase(appModel.deviceSession.phase)
    }

    func reset() {
        startGeneration = UUID()
        startInProgress = false
        stopTicks()
        route = nil
        path = nil
        routeLength = 0
        joystickAnchor = nil
        isJoystick = false
        currentCoordinate = nil
        distanceTravelled = 0
        pendingResumePaused = false
        manoeuvrePauseRemaining = 0
        phase = .idle
        if let phaseObserverID { appModel?.removeSessionPhaseObserver(phaseObserverID) }
        phaseObserverID = nil
        appModel = nil
    }

    var snapshot: MovementSnapshot {
        MovementSnapshot(route: route, mode: mode, speedMetresPerSecond: speedLimit,
                         distanceTravelled: distanceTravelled, isPaused: phase == .paused || pendingResumePaused,
                         isJoystick: isJoystick, manoeuvrePauseRemaining: manoeuvrePauseRemaining)
    }

    private var isFailure: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var currentTarget: LocationTarget? {
        guard let currentCoordinate else { return nil }
        if let route {
            if distanceTravelled == 0 { return route.start }
            if distanceTravelled >= routeLength { return route.destination }
            return route.target(at: RouteCoordinate(currentCoordinate))
        }
        guard let joystickAnchor else { return nil }
        return LocationTarget(name: joystickAnchor.name, subtitle: joystickAnchor.subtitle,
                              latitude: currentCoordinate.latitude, longitude: currentCoordinate.longitude,
                              origin: joystickAnchor.origin)
    }

    private func installRoute(_ route: MovementRoute) {
        let path = MovementPath(route)
        self.path = path
        self.route = route
        routeLength = path.length
    }

    private func start(at position: LocationTarget, using appModel: AppModel) async {
        guard case .paired = appModel.pairingStatus else {
            fail("Pair this iPhone before starting movement.")
            return
        }
        guard !appModel.deviceSession.isBusy else {
            fail("Wait for the current location session to finish connecting or stopping.")
            return
        }
        if let phaseObserverID { self.appModel?.removeSessionPhaseObserver(phaseObserverID) }
        self.appModel = appModel
        phaseObserverID = appModel.observeSessionPhase { [weak self] phase in
            self?.handleSessionPhase(phase)
        }
        startInProgress = true
        let generation = UUID()
        startGeneration = generation
        phase = .preparing
        await appModel.startMovementSession(at: position, snapshot: snapshot)
        guard startGeneration == generation else { return }
        startInProgress = false
        // Only the still-current attempt may stop or update this controller after suspension.
        if phase == .stopping || phase == .idle || Task.isCancelled {
            phase = .stopping
            appModel.stopLocationSession()
            handleSessionPhase(appModel.deviceSession.phase)
            return
        }
        if phase == .preparing, case .idle = appModel.deviceSession.phase {
            if case .failed(let message) = appModel.connectionState { fail(message) }
            else { fail("Roam Control could not start the movement session.") }
        } else {
            handleSessionPhase(appModel.deviceSession.phase)
        }
    }

    private func stopTicks() {
        movementTask?.cancel()
        movementTask = nil
        joystick.release()
        currentSpeedMetresPerSecond = 0
    }

    private func beginTicks() {
        movementTask?.cancel()
        movementTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var lastTick = clock.now
            var deadline = lastTick.advanced(by: MovementPhysics.tickInterval)
            while !Task.isCancelled {
                do { try await clock.sleep(until: deadline) } catch { return }
                guard !Task.isCancelled, let self, self.phase == .moving else { return }
                let now = clock.now
                let duration = lastTick.duration(to: now).components
                lastTick = now
                self.tick(elapsed: Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                deadline = deadline.advanced(by: MovementPhysics.tickInterval)
                // After a scheduling delay, resume once; do not send a burst of stale positions.
                if deadline <= now { deadline = now.advanced(by: MovementPhysics.tickInterval) }
            }
        }
    }

    private func tick(elapsed: Double) {
        guard let appModel, let currentCoordinate else { return }
        let destination: LocationTarget
        let newDistance: Double
        let newSpeed: Double
        let newPauseRemaining: Double
        if isJoystick, let joystickAnchor {
            let step = joystick.advance(from: RouteCoordinate(currentCoordinate), limit: speedLimit, mode: mode, elapsed: elapsed)
            currentSpeedMetresPerSecond = step.speed
            guard step.distance > 0 else { return }
            newDistance = distanceTravelled + step.distance
            newSpeed = step.speed
            newPauseRemaining = 0
            destination = LocationTarget(name: joystickAnchor.name, subtitle: joystickAnchor.subtitle,
                                         latitude: step.coordinate.latitude, longitude: step.coordinate.longitude,
                                         origin: joystickAnchor.origin)
        } else if let path, let route {
            let step = path.advance(distance: distanceTravelled, speed: currentSpeedMetresPerSecond,
                                    limit: speedLimit, mode: mode, elapsed: elapsed, pauseRemaining: manoeuvrePauseRemaining)
            newDistance = step.distance
            newSpeed = step.speed
            newPauseRemaining = step.pauseRemaining
            if newDistance == distanceTravelled, manoeuvrePauseRemaining > 0 {
                manoeuvrePauseRemaining = newPauseRemaining
                saveCheckpoint()
                return
            }
            if newDistance >= routeLength { destination = route.destination }
            else { destination = route.target(at: path.coordinate(at: newDistance)) }
        } else {
            fail("Roam Control could not follow this route.")
            return
        }

        let checkpoint = MovementSnapshot(route: route, mode: mode, speedMetresPerSecond: speedLimit,
                                          distanceTravelled: newDistance, isPaused: false, isJoystick: isJoystick,
                                          manoeuvrePauseRemaining: newPauseRemaining)
        guard appModel.updateMovementLocation(destination, snapshot: checkpoint) == .updated else {
            if case .failed(let message) = appModel.deviceSession.phase { fail(message) }
            else { fail("The active location session ended before movement finished.") }
            return
        }
        self.currentCoordinate = destination.coordinate
        distanceTravelled = newDistance
        manoeuvrePauseRemaining = newPauseRemaining
        currentSpeedMetresPerSecond = newSpeed
        if !isJoystick, newDistance >= routeLength {
            stopTicks()
            phase = .arrived
        }
    }

    private func saveCheckpoint() {
        guard phase == .moving || phase == .paused || phase == .arrived,
              let appModel, let currentTarget else { return }
        appModel.saveMovementRecovery(at: currentTarget, snapshot: snapshot)
    }

    private func fail(_ message: String) {
        stopTicks()
        phase = .failed(message)
    }
}
