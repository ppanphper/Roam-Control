import Foundation

// The standalone executable exercises the actual controller and timer without starting an iPhone session.
enum DeviceSessionPhase: Equatable {
    case idle, openingLocalDevVPN, discovering, connecting, active(LocationTarget), stopping, failed(String)
}
enum ActiveLocationUpdateResult { case updated, unavailable, failed }

@MainActor final class MovementSessionDouble {
    var onPhaseChange: ((DeviceSessionPhase) -> Void)?
    var phase = DeviceSessionPhase.idle { didSet { onPhaseChange?(phase) } }
    var isBusy: Bool {
        switch phase {
        case .connecting, .openingLocalDevVPN, .discovering, .stopping: true
        default: false
        }
    }
}

@MainActor final class AppModel {
    enum PairingState { case paired, notPaired }
    enum ConnectionState { case idle, failed(String) }

    let deviceSession = MovementSessionDouble()
    var pairingStatus: PairingState = .paired
    var connectionState: ConnectionState = .idle
    var startup: DeviceSessionPhase?
    var needsConfirmation = false
    var shouldFailUpdate = false
    var shouldSuspendStartup = false
    var startupContinuation: CheckedContinuation<Void, Never>?
    var starts: [(LocationTarget, MovementSnapshot)] = []
    var writes: [(LocationTarget, MovementSnapshot)] = []
    var saves: [(LocationTarget, MovementSnapshot)] = []
    var stops = 0
    private var preparationGeneration = UUID()
    private var phaseObservers: [UUID: (DeviceSessionPhase) -> Void] = [:]

    init() {
        deviceSession.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            for observer in Array(self.phaseObservers.values) { observer(phase) }
        }
    }

    func observeSessionPhase(_ observer: @escaping (DeviceSessionPhase) -> Void) -> UUID {
        let id = UUID()
        phaseObservers[id] = observer
        return id
    }

    func removeSessionPhaseObserver(_ id: UUID) { phaseObservers.removeValue(forKey: id) }

    func startMovementSession(at target: LocationTarget, snapshot: MovementSnapshot) async {
        let generation = UUID()
        preparationGeneration = generation
        starts.append((target, snapshot))
        if shouldSuspendStartup { await withCheckedContinuation { startupContinuation = $0 } }
        // Mirrors production AppModel's token contract, independently tested by AppModelIntegrationTests.
        guard generation == preparationGeneration, !Task.isCancelled else { return }
        deviceSession.phase = startup ?? .active(target)
    }

    func updateMovementLocation(_ target: LocationTarget, snapshot: MovementSnapshot) -> ActiveLocationUpdateResult {
        guard case .active = deviceSession.phase else { return .unavailable }
        if shouldFailUpdate {
            deviceSession.phase = .failed("Device update failed")
            return .failed
        }
        writes.append((target, snapshot))
        deviceSession.phase = .active(target)
        return .updated
    }

    func saveMovementRecovery(at target: LocationTarget, snapshot: MovementSnapshot) {
        saves.append((target, snapshot))
    }

    func stopLocationSession() {
        preparationGeneration = UUID()
        stops += 1
        if needsConfirmation, case .active = deviceSession.phase { deviceSession.phase = .stopping }
        else { deviceSession.phase = .idle }
    }
}
