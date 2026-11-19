import BackgroundTasks
import Foundation
import Observation
import RoamPairingFFI
import UIKit

struct PairedDeviceDetails: Equatable, Sendable {
    let name: String
    let model: String
    let udid: String
}

enum OnDevicePairingPhase: Equatable {
    case idle
    case preparing
    case waitingForSettings
    case showingPIN(String)
    case storing
    case cancelling
    case success(PairedDeviceDetails)
    case failed(String)
}

@MainActor
@Observable
final class OnDevicePairingCoordinator {
    typealias RecordStore = @MainActor (Data, Data?) async throws -> PairingRecordSummary

    static let shared = OnDevicePairingCoordinator()

    private(set) var phase: OnDevicePairingPhase = .idle
    private(set) var executionMode: SessionExecutionMode = .inactive
    private(set) var expiryMessage: String?

    private let publisher = PairingBonjourPublisher()
    private let notifications = PairingNotifications()
    private var localization = AppLocalization(language: AppLanguage(preference: "system"))
    private var pairingAttemptIdentifier: UUID?
    private var foregroundLease: UIBackgroundTaskIdentifier = .invalid
    private var foregroundLeaseDeadline: Task<Void, Never>?
    private var expirySubmission = PairingExpirySubmission<UUID>()
    private var expirySubmissionDeadline: Task<Void, Never>?
    private var didEnterBackground: (any NSObjectProtocol)?
    private var activeSession: OpaquePointer?
    private var activeRunIdentifier: UUID?
    private var submittedTaskIdentifier: String?
    private var backgroundTask: BGContinuedProcessingTask?
    private var recordStore: RecordStore?
    private var cancellationRequested = false
    private var pendingFailureMessage: String?
    private var backgroundLaunchTimeout: Task<Void, Never>?
    private var workerIsRunning = false

    var isRunning: Bool {
        workerIsRunning || expirySubmission.isPending || phase == .preparing || phase == .storing
    }

    var isAvailableOnThisDevice: Bool {
#if targetEnvironment(simulator)
        false
#else
        true
#endif
    }

    private init() {
        publisher.onPublished = { [weak self] in
            self?.advertisementDidPublish()
        }
        publisher.onFailure = { [weak self] in
            self?.advertisementDidFail()
        }
        didEnterBackground = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showCurrentPINNotification() }
        }
    }

    func requestNotificationPermission() async {
        await notifications.requestPermission()
    }

    func setLocalization(_ localization: AppLocalization) {
        self.localization = localization
    }

    func start(storeRecord: @escaping RecordStore) {
        guard isAvailableOnThisDevice else {
            phase = .failed("On-device pairing needs your physical iPhone.")
            return
        }
        guard !isRunning else { return }

        cancellationRequested = false
        pendingFailureMessage = nil
        pairingAttemptIdentifier = UUID()
        expiryMessage = nil
        notifications.clearPIN()
        notifications.clearExpiry()
        recordStore = storeRecord
        phase = .preparing

        guard let prefix = BackgroundTaskIdentifier.prefix(for: "pairing") else {
            beginForegroundPairing()
            return
        }
        let identifier = "\(prefix).\(UUID().uuidString)"
        let wasRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            MainActor.assumeIsolated {
                Self.shared.beginPairing(with: task, identifier: identifier)
            }
        }

        guard wasRegistered else {
            beginForegroundPairing()
            return
        }

        submittedTaskIdentifier = identifier
        executionMode = .waitingForSystem
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Roam Control",
            subtitle: "Preparing secure pairing…"
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            beginForegroundPairing()
            return
        }
        backgroundLaunchTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.submittedTaskIdentifier == identifier,
                  self.backgroundTask == nil else { return }
            self.beginForegroundPairing()
        }
    }

    func cancel() {
        // Once the iPhone has paired, let the Keychain transaction finish.
        guard phase != .storing else { return }
        guard isRunning else {
            notifications.clearExpiry()
            expiryMessage = nil
            phase = .idle
            return
        }

        cancellationRequested = true
        notifications.clearPIN()
        notifications.clearExpiry()
        publisher.stop()
        if let activeSession {
            phase = .cancelling
            rc_remote_pairing_session_cancel(activeSession)
        } else {
            recordStore = nil
            cancellationRequested = false
            finishBackgroundTask(success: false)
            phase = .idle
        }
    }

    func reset() {
        cancel()
        if !isRunning {
            phase = .idle
        }
    }

    private func beginForegroundPairing() {
        guard phase == .preparing, !workerIsRunning else { return }
        finishBackgroundTask(success: false)
        executionMode = .foregroundOnly
        beginForegroundLease()
        runNativePairing()
    }

    private func beginForegroundLease() {
        guard let pairingAttemptIdentifier else { return }
        foregroundLease = UIApplication.shared.beginBackgroundTask(withName: "Roam Control Pairing") { [weak self] in
            // UIKit invokes this handler on the main thread. Submit the notice
            // and end the UIKit lease inside this callback, before suspension.
            MainActor.assumeIsolated {
                guard let self, self.pairingAttemptIdentifier == pairingAttemptIdentifier,
                      self.foregroundLease != .invalid else { return }
                self.pairingTaskExpired(endingLeaseImmediately: true)
            }
        }
        guard foregroundLease != .invalid else { return }
        // The native waits total up to three minutes. Never keep a UIKit lease
        // beyond that bounded pairing window, even if iOS doesn't expire it.
        foregroundLeaseDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, let self, self.pairingAttemptIdentifier == pairingAttemptIdentifier else { return }
            self.pairingTaskExpired()
        }
    }

    private func endForegroundLease() {
        foregroundLeaseDeadline?.cancel()
        foregroundLeaseDeadline = nil
        guard foregroundLease != .invalid else { return }
        let lease = foregroundLease
        foregroundLease = .invalid
        UIApplication.shared.endBackgroundTask(lease)
    }

    private func beginPairing(with task: BGContinuedProcessingTask, identifier: String) {
        guard submittedTaskIdentifier == identifier, phase == .preparing, !workerIsRunning else {
            task.setTaskCompleted(success: false)
            return
        }

        backgroundLaunchTimeout?.cancel()
        backgroundLaunchTimeout = nil
        backgroundTask = task
        executionMode = .background
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 5
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.submittedTaskIdentifier == identifier else { return }
                self.pairingTaskExpired(endingLeaseImmediately: true)
            }
        }

        runNativePairing()
    }

    private func runNativePairing() {
        guard let session = rc_remote_pairing_session_create() else {
            fail("Roam Control could not start its pairing engine.")
            return
        }

        let runIdentifier = UUID()
        activeRunIdentifier = runIdentifier
        activeSession = session
        workerIsRunning = true

        let sessionBits = UInt(bitPattern: session)
        let callbackContext = PairingCallbackContext(coordinator: self, runIdentifier: runIdentifier)
        let contextBits = UInt(bitPattern: Unmanaged.passRetained(callbackContext).toOpaque())

        DispatchQueue.global(qos: .userInitiated).async {
            guard
                let session = OpaquePointer(bitPattern: sessionBits),
                let context = UnsafeMutableRawPointer(bitPattern: contextBits)
            else { return }

            var result = RCRemotePairingResult()
            let returnCode = "Roam Control".withCString { hostName in
                "Mac17,7".withCString { hostModel in
                    rc_remote_pairing_session_run(
                        session,
                        hostName,
                        hostModel,
                        remotePairingReadyCallback,
                        remotePairingPINCallback,
                        context,
                        &result
                    )
                }
            }

            let outcome = NativePairingOutcome(result: result, returnCode: returnCode)
            rc_remote_pairing_result_destroy(&result)
            DispatchQueue.main.async {
                if let session = OpaquePointer(bitPattern: sessionBits) {
                    rc_remote_pairing_session_destroy(session)
                }
                guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else { return }
                let callback = Unmanaged<PairingCallbackContext>.fromOpaque(context).takeRetainedValue()
                callback.coordinator.nativePairingFinished(outcome, runIdentifier: runIdentifier)
            }
        }
    }

    fileprivate func publish(_ advertisement: PairingAdvertisement, runIdentifier: UUID) {
        guard activeRunIdentifier == runIdentifier, phase == .preparing,
              !cancellationRequested, pendingFailureMessage == nil else { return }
        publisher.publish(advertisement)
    }

    fileprivate func presentPIN(_ pin: String, runIdentifier: UUID) {
        guard activeRunIdentifier == runIdentifier, !cancellationRequested, pendingFailureMessage == nil else { return }
        phase = .showingPIN(pin)
        showCurrentPINNotification()
        backgroundTask?.progress.completedUnitCount = 55
        backgroundTask?.updateTitle(
            "Roam Control pairing code",
            subtitle: "Enter \(pin) in Settings"
        )
    }

    private func showCurrentPINNotification() {
        guard let pairingAttemptIdentifier, case .showingPIN(let pin) = phase else { return }
        notifications.showPIN(pin, attempt: pairingAttemptIdentifier, localization: localization)
    }

    private func advertisementDidPublish() {
        guard workerIsRunning, phase == .preparing, !cancellationRequested else { return }
        phase = .waitingForSettings
        backgroundTask?.progress.completedUnitCount = 25
        backgroundTask?.updateTitle(
            "Roam Control",
            subtitle: "Choose Pair with Roam Control in Settings"
        )
    }

    private func advertisementDidFail() {
        guard workerIsRunning, !cancellationRequested, pendingFailureMessage == nil else { return }
        fail(
            "Local Network access is required. Enable it in Settings › Apps › Roam Control, then try again."
        )
    }

    private func nativePairingFinished(
        _ outcome: NativePairingOutcome,
        runIdentifier: UUID
    ) {
        guard activeRunIdentifier == runIdentifier else { return }

        activeRunIdentifier = nil
        activeSession = nil
        workerIsRunning = false
        publisher.stop()
        notifications.clearPIN()

        if let pendingFailureMessage {
            self.pendingFailureMessage = nil
            recordStore = nil
            phase = .failed(pendingFailureMessage)
            finishBackgroundTask(success: false)
            return
        }

        if cancellationRequested {
            cancellationRequested = false
            recordStore = nil
            phase = .idle
            finishBackgroundTask(success: false)
            return
        }

        switch outcome {
        case .success(let record, let hostAltIRK, let device):
            phase = .storing
            backgroundTask?.progress.completedUnitCount = 80

            guard let recordStore else {
                fail("Roam Control could not securely store the new pairing.")
                return
            }

            Task {
                do {
                    _ = try await recordStore(record, hostAltIRK)
                    self.recordStore = nil
                    self.expiryMessage = nil
                    self.notifications.clearExpiry()
                    self.phase = .success(device)
                    self.backgroundTask?.progress.completedUnitCount = 100
                    self.backgroundTask?.updateTitle(
                        "Roam Control",
                        subtitle: "Pairing complete"
                    )
                    self.finishBackgroundTask(success: true)
                } catch {
                    self.fail(self.expiryMessage ?? error.localizedDescription)
                }
            }

        case .expired:
            pairingTaskExpired()
        case .failure(let message):
            fail(message)
        }
    }

    private func pairingTaskExpired(endingLeaseImmediately: Bool = false) {
        defer { if endingLeaseImmediately { finishBackgroundTask(success: false, immediate: true) } }
        // A native timeout and a system expiration may arrive for the same attempt.
        guard expiryMessage == nil else { return }
        let stage: PairingExpiryStage
        switch phase {
        case .preparing: stage = .preparing
        case .waitingForSettings: stage = .waitingForSettings
        case .showingPIN: stage = .showingPIN
        case .storing: stage = .storing
        case .idle, .cancelling, .success, .failed:
            finishBackgroundTask(success: false)
            return
        }
        let message = stage.message
        expiryMessage = message
        notifications.clearPIN()
        if let attempt = pairingAttemptIdentifier {
            if !endingLeaseImmediately {
                expirySubmission.submit(for: attempt)
                // Don't retain a grant indefinitely if the notification server
                // never completes the request.
                expirySubmissionDeadline = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    self?.expiryNotificationFinished(for: attempt)
                }
            }
            notifications.showExpiry(message, attempt: attempt, localization: localization) { [weak self] in
                self?.expiryNotificationFinished(for: attempt)
            }
        }
        if phase == .storing {
            // Storage may already be committing. Its real result can replace
            // this notice when the app can run again.
            finishBackgroundTask(success: false)
        } else {
            fail(message)
        }
    }

    private func expiryNotificationFinished(for attempt: UUID) {
        guard pairingAttemptIdentifier == attempt, expirySubmission.complete(for: attempt) else { return }
        finishBackgroundTask(success: false)
    }

    private func fail(_ message: String) {
        if workerIsRunning, let activeSession {
            pendingFailureMessage = message
            rc_remote_pairing_session_cancel(activeSession)
        }
        publisher.stop()
        notifications.clearPIN()
        recordStore = nil
        phase = .failed(message)
        finishBackgroundTask(success: false)
    }

    private func finishBackgroundTask(success: Bool, immediate: Bool = false) {
        guard immediate || success || !expirySubmission.isPending else { return }
        expirySubmission.clear()
        expirySubmissionDeadline?.cancel()
        expirySubmissionDeadline = nil
        endForegroundLease()
        backgroundLaunchTimeout?.cancel()
        backgroundLaunchTimeout = nil
        if let task = backgroundTask {
            task.expirationHandler = nil
            task.setTaskCompleted(success: success)
        } else if let submittedTaskIdentifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: submittedTaskIdentifier)
        }
        backgroundTask = nil
        submittedTaskIdentifier = nil
        executionMode = .inactive
    }

}

fileprivate struct PairingAdvertisement: Sendable {
    let serviceIdentifier: String
    let port: Int32
    let textRecords: [String: Data]
}

private enum NativePairingOutcome: Sendable {
    case success(
        record: Data,
        hostAltIRK: Data?,
        device: PairedDeviceDetails
    )
    case failure(String)
    case expired

    init(result: RCRemotePairingResult, returnCode: Int32) {
        guard returnCode != 3 else {
            self = .expired
            return
        }
        guard returnCode == 0 else {
            let message = Self.string(from: result.error_message)
            self = .failure(message.isEmpty ? "The iPhone could not finish pairing." : message)
            return
        }

        guard
            let recordPointer = result.pairing_record,
            result.pairing_record_length > 0
        else {
            self = .failure("The pairing engine returned an empty record.")
            return
        }

        let record = Data(bytes: recordPointer, count: result.pairing_record_length)
        let hostAltIRK: Data?
        if let pointer = result.host_alt_irk, result.host_alt_irk_length > 0 {
            hostAltIRK = Data(bytes: pointer, count: result.host_alt_irk_length)
        } else {
            hostAltIRK = nil
        }

        self = .success(
            record: record,
            hostAltIRK: hostAltIRK,
            device: PairedDeviceDetails(
                name: Self.string(from: result.device_name),
                model: Self.string(from: result.device_model),
                udid: Self.string(from: result.device_udid)
            )
        )
    }

    private static func string(from pointer: UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        return String(cString: pointer)
    }
}

@MainActor
private final class PairingBonjourPublisher: NSObject, NetServiceDelegate {
    var onPublished: (() -> Void)?
    var onFailure: (() -> Void)?

    private var service: NetService?

    func publish(_ advertisement: PairingAdvertisement) {
        stop()

        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: advertisement.serviceIdentifier,
            port: advertisement.port
        )
        service.includesPeerToPeer = true
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: advertisement.textRecords))
        service.schedule(in: .main, forMode: .common)
        self.service = service
        service.publish()
    }

    func stop() {
        service?.stop()
        service?.remove(from: .main, forMode: .common)
        service?.delegate = nil
        service = nil
    }

    nonisolated func netServiceDidPublish(_ sender: NetService) {
        MainActor.assumeIsolated {
            guard service === sender else { return }
            onPublished?()
        }
    }

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated {
            guard service === sender else { return }
            onFailure?()
        }
    }
}

private final class PairingCallbackContext {
    let coordinator: OnDevicePairingCoordinator
    let runIdentifier: UUID

    init(coordinator: OnDevicePairingCoordinator, runIdentifier: UUID) {
        self.coordinator = coordinator
        self.runIdentifier = runIdentifier
    }
}

private let remotePairingReadyCallback: RCRemotePairingReadyCallback = {
    context,
    serviceIdentifier,
    port,
    keys,
    values,
    count in
    guard
        let context,
        let serviceIdentifier,
        let keys,
        let values
    else { return }

    var textRecords: [String: Data] = [:]
    for index in 0..<Int(count) {
        guard let key = keys[index], let value = values[index] else { continue }
        textRecords[String(cString: key)] = Data(String(cString: value).utf8)
    }

    let advertisement = PairingAdvertisement(
        serviceIdentifier: String(cString: serviceIdentifier),
        port: Int32(port),
        textRecords: textRecords
    )
    let callback = Unmanaged<PairingCallbackContext>.fromOpaque(context).takeUnretainedValue()
    let coordinator = callback.coordinator
    let runIdentifier = callback.runIdentifier
    DispatchQueue.main.async {
        coordinator.publish(advertisement, runIdentifier: runIdentifier)
    }
}

private let remotePairingPINCallback: RCRemotePairingPINCallback = { context, pin in
    guard let context, let pin else { return }

    let value = String(cString: pin)
    let callback = Unmanaged<PairingCallbackContext>.fromOpaque(context).takeUnretainedValue()
    let coordinator = callback.coordinator
    let runIdentifier = callback.runIdentifier
    DispatchQueue.main.async {
        coordinator.presentPIN(value, runIdentifier: runIdentifier)
    }
}
