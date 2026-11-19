import Foundation

// Deterministic transport double. These tests execute the production AppModel,
// codecs and preferences, without opening Keychain or any phone connection.
enum DeviceSessionPhase: Equatable {
    case idle, openingLocalDevVPN, discovering, connecting, active(LocationTarget), stopping, failed(String)
}
enum ActiveLocationUpdateResult { case unavailable, updated, failed }
enum TestRestorationStatus: Equatable { case notRequired, pending, clearing, deviceConfirmed, userConfirmed, requiresRecovery(String) }
enum MobileDataGuidance { case connectionHelp, turnOff, turnBackOn }

@MainActor
final class LocalDeviceSessionCoordinator {
    var onPhaseChange: ((DeviceSessionPhase) -> Void)?
    private(set) var phase: DeviceSessionPhase = .idle
    var restorationStatus: TestRestorationStatus = .notRequired
    var mobileDataGuidance: MobileDataGuidance?
    var lastWrittenTarget: LocationTarget?
    var restoreOnlyRequests = 0
    var beforeWrite: (() -> Void)?
    var onLocationWriteWillBegin: (() -> Void)?
    var didAttemptLocationWrite = false
    var automaticallyActivate = true
    var isBusy: Bool {
        switch phase {
        case .openingLocalDevVPN, .discovering, .connecting, .stopping: true
        default: false
        }
    }
    var canAcknowledgeManualRestoration: Bool {
        if case .active = phase { return false }
        return !isBusy
    }
    func acknowledgeManualRestoration() {
        guard canAcknowledgeManualRestoration else { return }
        restorationStatus = .userConfirmed
        emit(.idle)
    }
    func emit(_ phase: DeviceSessionPhase) { self.phase = phase; onPhaseChange?(phase) }
    func start(pairingRecord: Data, target: LocationTarget) {
        didAttemptLocationWrite = false
        guard automaticallyActivate else { restorationStatus = .notRequired; emit(.discovering); return }
        didAttemptLocationWrite = true
        onLocationWriteWillBegin?()
        beforeWrite?()
        restorationStatus = .pending; lastWrittenTarget = target; emit(.active(target))
    }
    func restore(pairingRecord: Data, target: LocationTarget) {
        didAttemptLocationWrite = false
        restoreOnlyRequests += 1; restorationStatus = .clearing; emit(.connecting)
    }
    func updateLocation(_ target: LocationTarget) -> ActiveLocationUpdateResult {
        guard case .active = phase else { return .unavailable }
        didAttemptLocationWrite = true
        onLocationWriteWillBegin?()
        beforeWrite?()
        lastWrittenTarget = target; emit(.active(target)); return .updated
    }
    func stop() {
        switch phase {
        case .idle, .failed, .stopping: return
        case .discovering where restorationStatus == .notRequired: emit(.idle)
        default: restorationStatus = .clearing; emit(.stopping)
        }
    }
    func reset() { emit(.idle) }
    func handleOpenURL(_ url: URL) {}
    func appDidBecomeActive() {}
    func dismissMobileDataGuidance() { mobileDataGuidance = nil }
}

@MainActor
final class OnDevicePairingCoordinator {
    static let shared = OnDevicePairingCoordinator()
    var isRunning = false
    func start(_ save: @escaping (Data, Data?) async throws -> PairingRecordSummary) {}
    func reset() {}
    func cancel() {}
}

actor TestPairingService: PairingService {
    func storedRecord() -> PairingRecordSummary? { summary }
    func importRecord(from url: URL) -> PairingRecordSummary { summary }
    func storeGeneratedRecord(_ data: Data, hostAltIRK: Data?) -> PairingRecordSummary { summary }
    func pairingRecordData() -> Data? { Data("synthetic transport fixture; not a pairing record".utf8) }
    func removeRecord() {}
    private var summary: PairingRecordSummary {
        PairingRecordSummary(identifier: "test-device", fingerprint: "test-fingerprint", importedAt: Date(timeIntervalSince1970: 0))
    }
}

actor DelayedPairingService: PairingService {
    private var waiting: CheckedContinuation<Data?, Error>?
    func storedRecord() -> PairingRecordSummary? {
        .init(identifier: "synthetic", fingerprint: "none", importedAt: .distantPast)
    }
    func importRecord(from url: URL) -> PairingRecordSummary { storedRecord()! }
    func storeGeneratedRecord(_ data: Data, hostAltIRK: Data?) -> PairingRecordSummary { storedRecord()! }
    func pairingRecordData() async throws -> Data? {
        try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func waitUntilRequested() async { while waiting == nil { await Task.yield() } }
    func finish(_ data: Data?) { waiting?.resume(returning: data); waiting = nil }
    func removeRecord() {}
}
