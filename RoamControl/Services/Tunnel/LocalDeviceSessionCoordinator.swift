import BackgroundTasks
import Darwin
import Foundation
import Network
import Observation
import RoamPairingFFI
import UIKit

enum DeviceSessionPhase: Equatable {
    case idle
    case openingLocalDevVPN
    case discovering
    case connecting
    case active(LocationTarget)
    case stopping
    case failed(String)
}

enum DeviceRestorationStatus: Equatable {
    case notRequired
    case pending
    case clearing
    case deviceConfirmed
    case userConfirmed
    case requiresRecovery(String)
}

enum MobileDataGuidance: Equatable {
    case connectionHelp
    case turnOff
    case turnBackOn
}

enum ActiveLocationUpdateResult: Equatable {
    case unavailable
    case updated
    case failed
}

@MainActor
@Observable
final class LocalDeviceSessionCoordinator: NSObject {
    private struct PendingSession {
        let pairingRecord: Data
        let target: LocationTarget
        let clearOnly: Bool
    }

    private struct RemotePairingService: Sendable {
        let port: UInt16
        let identifier: String
        let authTag: String
        let interfaceIndex: UInt32
    }

    private static let enableURL = URL(
        string: "localdevvpn://enable?scheme=\(BackgroundTaskIdentifier.callbackScheme)"
    )!

    private(set) var phase: DeviceSessionPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    private(set) var mobileDataGuidance: MobileDataGuidance?
    private(set) var executionMode: SessionExecutionMode = .inactive
    private(set) var restorationStatus: DeviceRestorationStatus = .notRequired
    /// Once a worker finishes, reports whether this attempt could have sent a coordinate.
    var didAttemptLocationWrite: Bool { writeEvidence.didAttemptWrite }
    private var writeEvidence = LocationSessionWriteEvidence()

    var onPhaseChange: ((DeviceSessionPhase) -> Void)?
    /// Called synchronously on the main actor before exposing a new coordinate to the worker.
    var onLocationWriteWillBegin: (() -> Void)?

    private var browser: NetServiceBrowser?
    private let wifiPathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let wifiPathMonitorQueue = DispatchQueue(
        label: "com.ppanphper.roamcontrol.wifi-path",
        qos: .utility
    )
    private let serviceProbeQueue = DispatchQueue(
        label: "com.ppanphper.roamcontrol.service-probe",
        qos: .userInitiated
    )
    private var discoveredServices: [NetService] = []
    private var discoveryTimeout: Task<Void, Never>?
    private var automaticDiscoveryTask: Task<Void, Never>?
    private var networkDecisionTask: Task<Void, Never>?
    private var mobileDataDiscoveryLoopTask: Task<Void, Never>?
    private var mobileDataGuidanceDelay: Task<Void, Never>?
    private var localDevVPNProbeTask: Task<Void, Never>?
    private var localDevVPNReturn = LocalDevVPNReturnGate()
    private var pendingSession: PendingSession?
    private var attemptIdentifier: UUID?
    private var retries = ConsecutiveLocationRetries()
    private var foregroundRevision = 0
    private var clearRequestedFromStop = false
    private var reconnectTask: Task<Void, Never>?
    private var reconnectDeadline: Task<Void, Never>?
    private var backgroundLaunchTimeout: Task<Void, Never>?
    private var mobileDataDeadline: Task<Void, Never>?
    private var hasUnconfirmedLocation: Bool {
        if case .requiresRecovery = restorationStatus { return true }
        return restorationStatus == .pending || restorationStatus == .clearing
    }
    private var resolvedService: RemotePairingService?
    private var sawNonMatchingService = false
    private var isDiscoveringServices = false
    private var hasRequestedLocalDevVPNThisAttempt = false
    private var isReconnectingActiveLocation = false
    private var wifiPathStatusIsKnown = false
    private var isWiFiPathSatisfied = false
    private var isMobileDataStartupMode = false
    private var serviceProbeConnection: NWConnection?
    private var serviceProbeTimeout: Task<Void, Never>?
    private var serviceProbeRetryTask: Task<Void, Never>?
    private var serviceProbeAttemptCount = 0

    private var activeSession: OpaquePointer?
    private var activeRunIdentifier: UUID?
    private var submittedTaskIdentifier: String?
    private var backgroundTask: BGContinuedProcessingTask?
    private var backgroundProgressTask: Task<Void, Never>?
    private var workerIsRunning = false
    private var cancellationRequested = false
    private var pendingFailureMessage: String?

    override init() {
        super.init()
        wifiPathMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.wifiPathStatusIsKnown = true
                self?.isWiFiPathSatisfied = isSatisfied
            }
        }
        wifiPathMonitor.start(queue: wifiPathMonitorQueue)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    var isBusy: Bool {
        switch phase {
        case .openingLocalDevVPN, .discovering, .connecting, .stopping:
            true
        case .idle, .active, .failed:
            false
        }
    }

    func start(pairingRecord: Data, target: LocationTarget) {
        beginAttempt(pairingRecord: pairingRecord, target: target, clearOnly: false)
    }

    func restore(pairingRecord: Data, target: LocationTarget) {
        beginAttempt(pairingRecord: pairingRecord, target: target, clearOnly: true)
    }

    private func beginAttempt(pairingRecord: Data, target: LocationTarget, clearOnly: Bool) {
        guard !workerIsRunning, !isBusy else { return }
        writeEvidence = LocationSessionWriteEvidence()

#if targetEnvironment(simulator)
        fail("A real iPhone is required to start a location session.")
#else
        cancellationRequested = false
        pendingFailureMessage = nil
        mobileDataGuidance = nil
        hasRequestedLocalDevVPNThisAttempt = false
        isMobileDataStartupMode = false
        retries = ConsecutiveLocationRetries()
        attemptIdentifier = UUID()
        pendingSession = PendingSession(pairingRecord: pairingRecord, target: target, clearOnly: clearOnly)
        if clearOnly {
            restorationStatus = .pending
        } else if !hasUnconfirmedLocation {
            restorationStatus = .notRequired
        }
        resolvedService = nil
        phase = .discovering
        routeStartupForCurrentNetwork()
#endif
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == BackgroundTaskIdentifier.callbackScheme,
              pendingSession != nil, phase == .openingLocalDevVPN else { return }
        automaticDiscoveryTask?.cancel()
        automaticDiscoveryTask = nil

        guard let launch = localDevVPNReturn.launch else { return }
        discoverAfterLocalDevVPNReturn(launch)
    }

    private func discoverAfterLocalDevVPNReturn(_ launch: UUID) {
        switch localDevVPNReturn.beginDiscovery(for: launch, usesMobileData: isMobileDataStartupMode) {
        case .mobileData: enterMobileDataGuidance()
        case .standard: beginDiscovery(showConnectionHelpIfUnavailable: true)
        case nil: break
        }
    }

    @discardableResult
    func updateLocation(_ target: LocationTarget) -> ActiveLocationUpdateResult {
        guard
            workerIsRunning,
            case .active = phase,
            let activeSession,
            let pendingSession
        else { return .unavailable }

        if target.latitude != pendingSession.target.latitude || target.longitude != pendingSession.target.longitude {
            onLocationWriteWillBegin?()
            // An observer may have stopped the session before the update was queued.
            guard case .active = phase, self.activeSession == activeSession else { return .unavailable }
        }
        guard rc_location_session_update(activeSession, target.latitude, target.longitude) == 0 else {
            fail("Roam Control could not update the active location.")
            return .failed
        }

        self.pendingSession = PendingSession(
            pairingRecord: pendingSession.pairingRecord,
            target: target,
            clearOnly: pendingSession.clearOnly
        )
        phase = .active(target)
        backgroundTask?.updateTitle(
            "Roam Control",
            subtitle: "Location active at \(target.name)"
        )
        return .updated
    }

    func openLocalDevVPN() {
#if !targetEnvironment(simulator)
        if pendingSession != nil, !workerIsRunning {
            openLocalDevVPNForPendingSession()
            return
        }

        let phaseWhenOpened = phase
        UIApplication.shared.open(Self.enableURL) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                guard let self, self.phase == phaseWhenOpened, self.pendingSession == nil else { return }
                self.fail("Install LocalDevVPN before starting a location session.")
            }
        }
#endif
    }

    func dismissMobileDataGuidance() {
        mobileDataGuidance = nil
    }

    func confirmMobileDataIsOff() {
        guard mobileDataGuidance == .turnOff, pendingSession != nil else { return }
        automaticDiscoveryTask?.cancel()
        mobileDataDiscoveryLoopTask?.cancel()
        mobileDataDiscoveryLoopTask = nil
        automaticDiscoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            self.automaticDiscoveryTask = nil
            self.startMobileDataDiscoveryLoop()
        }
    }

    func useMobileDataGuidance() {
        guard mobileDataGuidance == .connectionHelp, pendingSession != nil else { return }
        isMobileDataStartupMode = true
        enterMobileDataGuidance()
    }

    func retryConnection() {
        guard mobileDataGuidance == .connectionHelp, pendingSession != nil else { return }
        mobileDataGuidance = nil
        resolvedService = nil
        beginDiscovery(showConnectionHelpIfUnavailable: true)
    }

    @objc private func appWillResignActive() {
        foregroundRevision &+= 1
        automaticDiscoveryTask?.cancel()
        automaticDiscoveryTask = nil
        if mobileDataGuidance == .turnOff {
            mobileDataDeadline?.cancel()
            mobileDataDeadline = nil
        }
    }

    @objc func appDidBecomeActive() {
        if
            phase == .openingLocalDevVPN,
            pendingSession != nil,
            !workerIsRunning,
            let launch = localDevVPNReturn.launch
        {
            guard automaticDiscoveryTask == nil else { return }
            automaticDiscoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled, let self else { return }
                self.automaticDiscoveryTask = nil
                guard self.pendingSession != nil, self.phase == .openingLocalDevVPN,
                      !self.workerIsRunning, UIApplication.shared.applicationState == .active else { return }
                self.discoverAfterLocalDevVPNReturn(launch)
            }
            return
        }

        guard mobileDataGuidance == .turnOff else { return }
        armMobileDataDeadlineIfActive()
        startMobileDataDiscoveryLoop()
    }

    func stop() {
        mobileDataGuidance = nil
        switch phase {
        case .idle, .failed, .stopping:
            return
        case .openingLocalDevVPN, .discovering, .connecting, .active:
            reconnectDeadline?.cancel()
            reconnectDeadline = nil
            cancellationRequested = true
            if let activeSession {
                if hasUnconfirmedLocation {
                    restorationStatus = .clearing
                }
                phase = .stopping
                rc_location_session_cancel(activeSession)
            } else if hasUnconfirmedLocation, let pendingSession, !pendingSession.clearOnly {
                beginStopRecovery(pendingSession)
            } else {
                finishWithoutNativeWrite()
            }
        }
    }

    func reset() {
        stop()
        // Forgetting setup must not turn a failed clear into an apparent recovery.
        if !workerIsRunning, !hasUnconfirmedLocation, phase != .idle {
            finishWithoutNativeWrite()
        }
    }

    var canAcknowledgeManualRestoration: Bool {
        guard !workerIsRunning, !isBusy else { return false }
        if case .active = phase { return false }
        return true
    }

    /// The user checked their real position outside this app. This is not a device clear receipt.
    func acknowledgeManualRestoration() {
        guard canAcknowledgeManualRestoration else { return }
        clearPendingSession()
        restorationStatus = .userConfirmed
        phase = .idle
    }

    private func finishWithoutNativeWrite() {
        let requiresRecovery = hasUnconfirmedLocation
        finishBackgroundTask(success: false)
        clearPendingSession()
        cancellationRequested = false
        if requiresRecovery {
            let message = "Real location has not been restored. Reconnect and try again."
            restorationStatus = .requiresRecovery(message)
            phase = .failed(message)
        } else {
            phase = .idle
        }
    }

    private func beginDiscovery(
        reportTimeout: Bool = true,
        openLocalDevVPNIfUnavailable: Bool = false,
        showConnectionHelpIfUnavailable: Bool = false
    ) {
        cleanupDiscovery()
        sawNonMatchingService = false
        isDiscoveringServices = true
        phase = .discovering
        let browser = NetServiceBrowser()
        self.browser = browser
        browser.includesPeerToPeer = true
        browser.delegate = self
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

        if showConnectionHelpIfUnavailable {
            mobileDataGuidanceDelay = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard
                    !Task.isCancelled,
                    let self,
                    self.pendingSession != nil,
                    self.phase == .discovering,
                    !self.workerIsRunning,
                    self.resolvedService == nil
                else { return }
                self.mobileDataGuidance = .connectionHelp
            }
        }

        if openLocalDevVPNIfUnavailable {
            localDevVPNProbeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard
                    !Task.isCancelled,
                    let self,
                    self.pendingSession != nil,
                    self.phase == .discovering,
                    !self.workerIsRunning,
                    self.resolvedService == nil
                else { return }

                self.localDevVPNProbeTask = nil
                self.openLocalDevVPNForPendingSession()
            }
        }

        if reportTimeout {
            discoveryTimeout = foregroundDeadline(after: .seconds(30)) { coordinator in
                guard coordinator.phase == .discovering else { return }
                if coordinator.sawNonMatchingService {
                    coordinator.fail(
                        "Roam Control found an outdated device announcement. Toggle LocalDevVPN off and on, then try again."
                    )
                } else {
                    coordinator.fail(
                        "Roam Control could not find this iPhone through LocalDevVPN. Check that the tunnel is enabled and try again."
                    )
                }
            }
        }
    }

    private func resolve(_ service: NetService) {
        service.delegate = self
        service.includesPeerToPeer = true
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 8)
        discoveredServices.append(service)
    }

    private func useResolvedService(_ service: NetService) {
        guard phase == .discovering, discoveredServices.contains(where: { $0 === service }) else { return }
        guard service.port > 0, service.port <= Int(UInt16.max) else { return }
        guard
            let txtData = service.txtRecordData(),
            let identifierData = NetService.dictionary(fromTXTRecord: txtData)["identifier"],
            let authTagData = NetService.dictionary(fromTXTRecord: txtData)["authTag"]
        else { return }

        let identifier = String(decoding: identifierData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let authTag = String(decoding: authTagData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !authTag.isEmpty else { return }
        guard let pairingRecord = pendingSession?.pairingRecord else { return }

        let matchesPairedDevice = pairingRecord.withUnsafeBytes { recordBytes in
            guard let recordBaseAddress = recordBytes.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }

            return identifier.withCString { serviceIdentifier in
                authTag.withCString { authTag in
                    rc_pairing_record_matches_service(
                        recordBaseAddress,
                        pairingRecord.count,
                        serviceIdentifier,
                        authTag
                    ) == 1
                }
            }
        }

        guard matchesPairedDevice else {
            sawNonMatchingService = true
            service.startMonitoring()
            return
        }

        guard serviceProbeConnection == nil, serviceProbeRetryTask == nil else { return }
        verifyServiceIsReachable(port: UInt16(service.port), identifier: identifier, authTag: authTag)
    }

    private func submitLocationTask() {
        if backgroundTask != nil {
            phase = .connecting
            runNativeLocationSession()
            return
        }
        guard let pendingSession, resolvedService != nil else {
            fail("Roam Control could not prepare the selected location.")
            return
        }

        phase = .connecting
        guard let prefix = BackgroundTaskIdentifier.prefix(for: "location") else {
            beginForegroundLocation()
            return
        }
        let identifier = "\(prefix).\(UUID().uuidString)"
        let wasRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            MainActor.assumeIsolated {
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.beginLocationSession(with: task, identifier: identifier)
            }
        }

        guard wasRegistered else {
            beginForegroundLocation()
            return
        }

        submittedTaskIdentifier = identifier
        executionMode = .waitingForSystem
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Roam Control",
            subtitle: pendingSession.clearOnly ? "Restoring real location…" : "Connecting to \(pendingSession.target.name)…"
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            beginForegroundLocation()
            return
        }
        backgroundLaunchTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.submittedTaskIdentifier == identifier,
                  self.backgroundTask == nil else { return }
            self.beginForegroundLocation()
        }
    }

    private func beginForegroundLocation() {
        guard phase == .connecting, !workerIsRunning else { return }
        finishBackgroundTask(success: false)
        executionMode = .foregroundOnly
        runNativeLocationSession()
    }

    private func beginLocationSession(with task: BGContinuedProcessingTask, identifier: String) {
        guard submittedTaskIdentifier == identifier, phase == .connecting, !workerIsRunning else {
            task.setTaskCompleted(success: false)
            return
        }

        backgroundLaunchTimeout?.cancel()
        backgroundLaunchTimeout = nil
        backgroundTask = task
        executionMode = .background
        task.progress.totalUnitCount = 5_760
        task.progress.completedUnitCount = 1
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.submittedTaskIdentifier == identifier else { return }
                self.locationTaskExpired()
            }
        }
        startBackgroundProgress(for: task)
        runNativeLocationSession()
    }

    private func startBackgroundProgress(for task: BGContinuedProcessingTask) {
        backgroundProgressTask?.cancel()
        backgroundProgressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard
                    !Task.isCancelled,
                    let self,
                    self.backgroundTask === task
                else { return }

                task.progress.completedUnitCount = min(
                    task.progress.completedUnitCount + 1,
                    task.progress.totalUnitCount - 1
                )
            }
        }
    }

    private func runNativeLocationSession() {
        guard let pendingSession, let resolvedService else {
            fail("Roam Control lost the location session details.")
            return
        }
        guard let session = rc_location_session_create() else {
            fail("Roam Control could not start its location engine.")
            return
        }

        let runIdentifier = UUID()
        activeRunIdentifier = runIdentifier
        activeSession = session
        workerIsRunning = true

        let sessionBits = UInt(bitPattern: session)
        let callbackContext = LocationCallbackContext(coordinator: self, runIdentifier: runIdentifier)
        let contextBits = UInt(bitPattern: Unmanaged.passRetained(callbackContext).toOpaque())
        let pairingRecord = pendingSession.pairingRecord
        let target = pendingSession.target
        let clearOnly = pendingSession.clearOnly
        if clearOnly {
            restorationStatus = .clearing
        } else if !didAttemptLocationWrite {
            writeEvidence.beginWorker()
            onLocationWriteWillBegin?()
        }
        let peerAddressString = LocalDevVPNEndpoint.peerAddress

        DispatchQueue.global(qos: .userInitiated).async {
            guard
                let session = OpaquePointer(bitPattern: sessionBits),
                let context = UnsafeMutableRawPointer(bitPattern: contextBits)
            else { return }

            var result = RCLocationResult()
            let returnCode = pairingRecord.withUnsafeBytes { recordBytes in
                guard let recordBaseAddress = recordBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return Int32(-1)
                }

                return peerAddressString.withCString { peerAddress in
                    resolvedService.identifier.withCString { serviceIdentifier in
                        resolvedService.authTag.withCString { authTag in
                            rc_location_session_run(
                                session,
                                recordBaseAddress,
                                pairingRecord.count,
                                peerAddress,
                                resolvedService.interfaceIndex,
                                resolvedService.port,
                                serviceIdentifier,
                                authTag,
                                target.latitude,
                                target.longitude,
                                clearOnly ? 1 : 0,
                                locationStartedCallback,
                                context,
                                &result
                            )
                        }
                    }
                }
            }

            let outcome = NativeLocationOutcome(result: result, returnCode: returnCode)
            rc_location_result_destroy(&result)

            DispatchQueue.main.async {
                if let session = OpaquePointer(bitPattern: sessionBits) {
                    rc_location_session_destroy(session)
                }
                guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else { return }
                let callbackContext = Unmanaged<LocationCallbackContext>.fromOpaque(context).takeRetainedValue()
                callbackContext.coordinator.nativeLocationFinished(outcome, runIdentifier: runIdentifier)
            }
        }
    }

    fileprivate func nativeLocationStarted(runIdentifier: UUID) {
        guard activeRunIdentifier == runIdentifier, workerIsRunning, !cancellationRequested,
              let target = pendingSession?.target else { return }
        writeEvidence.startedLocation()
        restorationStatus = .pending
        retries.locationStarted()
        isReconnectingActiveLocation = false
        reconnectDeadline?.cancel()
        reconnectDeadline = nil
        mobileDataDiscoveryLoopTask?.cancel()
        mobileDataDiscoveryLoopTask = nil
        phase = .active(target)
        if mobileDataGuidance == .turnOff {
            mobileDataGuidance = .turnBackOn
        }
        backgroundTask?.updateTitle(
            "Roam Control",
            subtitle: "Location active at \(target.name)"
        )
    }

    private func nativeLocationFinished(_ outcome: NativeLocationOutcome, runIdentifier: UUID) {
        guard activeRunIdentifier == runIdentifier else { return }
        activeRunIdentifier = nil
        activeSession = nil
        workerIsRunning = false

        let mayRequireRecovery = hasUnconfirmedLocation || pendingSession?.clearOnly == true
        let confirm = outcome.clearStatus == .confirmed
        // A fresh attempt can fail before writing while older coordinates still
        // need clearing. A worker reconnecting this attempt retains its evidence.
        writeEvidence.finishedWorker(clear: outcome.clearStatus, clearOnly: pendingSession?.clearOnly == true)
        let unresolved = outcome.clearStatus == .unconfirmed || (mayRequireRecovery && !confirm)
        let requestedStop = cancellationRequested
        cancellationRequested = false
        let forcedFailure = pendingFailureMessage
        let failure = forcedFailure ?? outcome.error
        pendingFailureMessage = nil

        if let pendingSession {
            switch LocationSessionRetryPolicy.action(
                clear: outcome.clearStatus, unresolved: unresolved, retryable: outcome.retryable,
                hasError: outcome.error != nil, wasCancelled: requestedStop, forcedFailure: forcedFailure,
                currentAttemptIsClearOnly: pendingSession.clearOnly, retryCount: retries.count
            ) {
            case .clearOnly:
                beginStopRecovery(pendingSession)
                return
            case .reconnect:
                if unresolved {
                    restorationStatus = pendingSession.clearOnly ? .clearing : .pending
                } else if confirm {
                    restorationStatus = .deviceConfirmed
                }
                retries.recordRetry()
                if didAttemptLocationWrite && !pendingSession.clearOnly {
                    isReconnectingActiveLocation = true
                    if !isMobileDataStartupMode { armReconnectDeadline() }
                }
                scheduleReconnect()
                return
            case .finish:
                break
            }
        }

        finishBackgroundTask(success: failure == nil && !unresolved)
        mobileDataGuidance = confirm && pendingSession?.clearOnly == true && isMobileDataStartupMode ? .turnBackOn : nil
        clearPendingSession()
        if confirm {
            restorationStatus = .deviceConfirmed
        } else if unresolved {
            restorationStatus = .requiresRecovery(failure ?? "The iPhone did not confirm that its simulated location was cleared.")
        }

        if let message = LocationSessionRetryPolicy.finishMessage(
            error: failure, forcedFailure: forcedFailure, wasCancelled: requestedStop,
            clear: outcome.clearStatus, unresolved: unresolved
        ) {
            phase = .failed(message)
        } else {
            phase = .idle
        }
    }

    private func beginStopRecovery(_ session: PendingSession) {
        // Fence the interrupted attempt so its late discovery cannot send a set.
        let useMobileData = isMobileDataStartupMode
        clearPendingSession()
        attemptIdentifier = UUID()
        pendingSession = PendingSession(pairingRecord: session.pairingRecord, target: session.target, clearOnly: true)
        isMobileDataStartupMode = useMobileData
        clearRequestedFromStop = true
        restorationStatus = .clearing
        cancellationRequested = false
        retries = ConsecutiveLocationRetries()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard let attemptIdentifier else { return }
        resolvedService = nil
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self, self.attemptIdentifier == attemptIdentifier,
                  self.phase == .discovering, !self.workerIsRunning else { return }
            self.reconnectTask = nil
            if self.isMobileDataStartupMode {
                self.enterMobileDataGuidance()
            } else {
                self.beginDiscovery(showConnectionHelpIfUnavailable: true)
            }
        }
        phase = .discovering
    }

    private func armReconnectDeadline() {
        guard reconnectDeadline == nil, let attemptIdentifier else { return }
        reconnectDeadline = foregroundDeadline(after: .seconds(60)) { coordinator in
            guard coordinator.attemptIdentifier == attemptIdentifier else { return }
            coordinator.fail("Real location has not been restored. Reconnect and try again.")
        }
    }

    private func locationTaskExpired() {
        // If the user already asked to stop, scheduler expiry only ends the grant.
        if !cancellationRequested, !clearRequestedFromStop, pendingFailureMessage == nil {
            if activeSession != nil {
                cancellationRequested = true
            }
            fail("iOS stopped the background session.")
        }
        // Expiration must be acknowledged immediately. Clear is reported separately by the engine.
        finishBackgroundTask(success: false)
    }

    private func fail(_ message: String) {
        localDevVPNReturn.clear()
        mobileDataGuidance = nil
        cleanupDiscovery()

        if workerIsRunning, let activeSession {
            pendingFailureMessage = message
            if hasUnconfirmedLocation { restorationStatus = .clearing }
            phase = .stopping
            rc_location_session_cancel(activeSession)
            return
        }
        finishBackgroundTask(success: false)
        clearPendingSession()
        if hasUnconfirmedLocation { restorationStatus = .requiresRecovery(message) }
        phase = .failed(message)
    }

    private func cleanupDiscovery() {
        isDiscoveringServices = false
        cleanupServiceProbe()
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        mobileDataGuidanceDelay?.cancel()
        mobileDataGuidanceDelay = nil
        localDevVPNProbeTask?.cancel()
        localDevVPNProbeTask = nil
        browser?.delegate = nil
        browser?.stop()
        browser = nil

        for service in discoveredServices {
            service.stopMonitoring()
            service.stop()
            service.remove(from: .main, forMode: .common)
            service.delegate = nil
        }
        discoveredServices = []
    }

    private func verifyServiceIsReachable(port: UInt16, identifier: String, authTag: String) {
        guard phase == .discovering, pendingSession != nil, serviceProbeConnection == nil else { return }
        let interfaceIndex = LocalDevVPNEndpoint.interfaceIndex() ?? 0
        let service = RemotePairingService(port: port, identifier: identifier, authTag: authTag, interfaceIndex: interfaceIndex)
        serviceProbeAttemptCount += 1
        guard interfaceIndex != 0, let connection = LocalDevVPNEndpoint.makeProbe(port: port) else {
            handleServiceProbeResult(false, service: service)
            return
        }
        serviceProbeConnection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                Task { @MainActor [weak self] in
                    self?.finishServiceProbe(connection, service: service, reachable: true)
                }
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.finishServiceProbe(connection, service: service, reachable: false)
                }
            case .setup, .waiting, .preparing:
                break
            @unknown default:
                break
            }
        }

        serviceProbeTimeout = Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self, let connection else { return }
            self.finishServiceProbe(connection, service: service, reachable: false)
        }
        connection.start(queue: serviceProbeQueue)
    }

    private func finishServiceProbe(
        _ connection: NWConnection,
        service: RemotePairingService,
        reachable: Bool
    ) {
        guard serviceProbeConnection === connection else { return }
        serviceProbeConnection = nil
        serviceProbeTimeout?.cancel()
        serviceProbeTimeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        handleServiceProbeResult(reachable, service: service)
    }

    private func handleServiceProbeResult(
        _ reachable: Bool,
        service: RemotePairingService
    ) {
        guard phase == .discovering, pendingSession != nil else { return }

        if reachable {
            serviceProbeAttemptCount = 0
            resolvedService = service
            mobileDataDiscoveryLoopTask?.cancel()
            mobileDataDiscoveryLoopTask = nil
            mobileDataDeadline?.cancel()
            mobileDataDeadline = nil
            if mobileDataGuidance == .connectionHelp {
                mobileDataGuidance = nil
            }
            cleanupDiscovery()
            submitLocationTask()
            return
        }

        if isMobileDataStartupMode {
            serviceProbeAttemptCount = 0
            return
        }

        if !hasRequestedLocalDevVPNThisAttempt && !isReconnectingActiveLocation && !clearRequestedFromStop {
            serviceProbeAttemptCount = 0
            openLocalDevVPNForPendingSession()
            return
        }

        guard serviceProbeAttemptCount < 3 else {
            serviceProbeAttemptCount = 0
            mobileDataGuidance = .connectionHelp
            return
        }

        serviceProbeRetryTask?.cancel()
        serviceProbeRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            self.serviceProbeRetryTask = nil
            self.verifyServiceIsReachable(port: service.port, identifier: service.identifier, authTag: service.authTag)
        }
    }

    private func cleanupServiceProbe() {
        serviceProbeTimeout?.cancel()
        serviceProbeTimeout = nil
        serviceProbeRetryTask?.cancel()
        serviceProbeRetryTask = nil
        serviceProbeConnection?.stateUpdateHandler = nil
        serviceProbeConnection?.cancel()
        serviceProbeConnection = nil
        serviceProbeAttemptCount = 0
    }

    private func clearPendingSession() {
        automaticDiscoveryTask?.cancel()
        automaticDiscoveryTask = nil
        networkDecisionTask?.cancel()
        networkDecisionTask = nil
        mobileDataDiscoveryLoopTask?.cancel()
        mobileDataDiscoveryLoopTask = nil
        localDevVPNReturn.clear()
        cleanupDiscovery()
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectDeadline?.cancel()
        reconnectDeadline = nil
        mobileDataDeadline?.cancel()
        mobileDataDeadline = nil
        pendingSession = nil
        resolvedService = nil
        attemptIdentifier = nil
        hasRequestedLocalDevVPNThisAttempt = false
        isMobileDataStartupMode = false
        isReconnectingActiveLocation = false
        clearRequestedFromStop = false
    }

    private func finishBackgroundTask(success: Bool) {
        backgroundLaunchTimeout?.cancel()
        backgroundLaunchTimeout = nil
        backgroundProgressTask?.cancel()
        backgroundProgressTask = nil
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

    private func routeStartupForCurrentNetwork() {
        networkDecisionTask?.cancel()
        networkDecisionTask = nil
        mobileDataGuidance = nil

        if wifiPathStatusIsKnown {
            if isWiFiPathSatisfied {
                beginDiscovery(openLocalDevVPNIfUnavailable: true)
            } else {
                isMobileDataStartupMode = true
                openLocalDevVPNForPendingSession()
            }
            return
        }

        networkDecisionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard
                !Task.isCancelled,
                let self,
                self.pendingSession != nil,
                !self.workerIsRunning
            else { return }

            self.networkDecisionTask = nil
            if self.wifiPathStatusIsKnown, !self.isWiFiPathSatisfied {
                self.isMobileDataStartupMode = true
                self.openLocalDevVPNForPendingSession()
            } else {
                self.beginDiscovery(openLocalDevVPNIfUnavailable: true)
            }
        }
    }

    private func enterMobileDataGuidance() {
        guard pendingSession != nil, !workerIsRunning else { return }
        cleanupDiscovery()
        phase = .discovering
        mobileDataGuidance = .turnOff
        armMobileDataDeadlineIfActive()
        startMobileDataDiscoveryLoop()
    }

    private func armMobileDataDeadlineIfActive() {
        guard mobileDataDeadline == nil, let attemptIdentifier,
              UIApplication.shared.applicationState == .active else { return }
        mobileDataDeadline = foregroundDeadline(after: .seconds(60)) { coordinator in
            guard coordinator.attemptIdentifier == attemptIdentifier,
                  coordinator.mobileDataGuidance == .turnOff, !coordinator.workerIsRunning else { return }
            coordinator.mobileDataDeadline = nil
            coordinator.fail("The tunnel did not become available after turning off mobile data. Reopen LocalDevVPN and try again.")
        }
    }

    private func foregroundDeadline(
        after duration: Duration, onTimeout: @escaping @MainActor (LocalDeviceSessionCoordinator) -> Void
    ) -> Task<Void, Never> {
        let clock = ContinuousClock()
        var revision = foregroundRevision
        var budget = ForegroundDiscoveryBudget(duration: duration, now: clock.now,
                                               isActive: canSpendDiscoveryTime)
        return Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if budget.step(now: clock.now, isActive: self.canSpendDiscoveryTime,
                               uninterrupted: revision == self.foregroundRevision) {
                    onTimeout(self)
                    return
                }
                revision = self.foregroundRevision
            }
        }
    }

    private var canSpendDiscoveryTime: Bool {
        phase != .openingLocalDevVPN && UIApplication.shared.applicationState == .active
    }

    private func startMobileDataDiscoveryLoop() {
        guard
            isMobileDataStartupMode,
            mobileDataGuidance == .turnOff,
            pendingSession != nil,
            !workerIsRunning
        else { return }

        mobileDataDiscoveryLoopTask?.cancel()
        mobileDataDiscoveryLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard
                    let self,
                    self.isMobileDataStartupMode,
                    self.mobileDataGuidance == .turnOff,
                    self.pendingSession != nil,
                    !self.workerIsRunning
                else { return }

                self.resolvedService = nil
                self.beginDiscovery(reportTimeout: false)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func openLocalDevVPNForPendingSession() {
#if !targetEnvironment(simulator)
        guard pendingSession != nil, !workerIsRunning, let attemptIdentifier else { return }
        cleanupDiscovery()
        automaticDiscoveryTask?.cancel()
        automaticDiscoveryTask = nil
        mobileDataDeadline?.cancel()
        mobileDataDeadline = nil
        mobileDataGuidance = nil
        hasRequestedLocalDevVPNThisAttempt = true
        phase = .openingLocalDevVPN

        // LocalDevVPN may need an arbitrary amount of time in Settings. The
        // callback or a foreground return starts a fresh, bounded discovery.
        let launchIdentifier = UUID()
        localDevVPNReturn.open(launchIdentifier)
        UIApplication.shared.open(Self.enableURL) { [weak self] opened in
            guard !opened else { return }
            Task { @MainActor in
                guard let self, self.attemptIdentifier == attemptIdentifier,
                      self.localDevVPNReturn.launch == launchIdentifier,
                      self.phase == .openingLocalDevVPN else { return }
                self.fail("Install LocalDevVPN before starting a location session.")
            }
        }
#endif
    }

}

extension LocalDeviceSessionCoordinator: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        MainActor.assumeIsolated {
            guard self.browser === browser, self.isDiscoveringServices else { return }
            resolve(service)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        MainActor.assumeIsolated {
            guard self.browser === browser, self.isDiscoveringServices else { return }
            fail("Local Network access is required to find this iPhone.")
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            useResolvedService(sender)
        }
    }

    nonisolated func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        MainActor.assumeIsolated {
            useResolvedService(sender)
        }
    }
}

enum LocalDevVPNEndpoint {
    static let peerAddress = "10.7.0.1"
    private static let sourceAddress = "10.7.1.1"

    static func interfaceIndex() -> UInt32? {
        var entries: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&entries) == 0, let entries else { return nil }
        defer { freeifaddrs(entries) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = entries
        var expected = in_addr()
        guard inet_pton(AF_INET, sourceAddress, &expected) == 1 else { return nil }
        while let entry = cursor {
            let interface = entry.pointee
            cursor = interface.ifa_next
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP | IFF_POINTOPOINT) == UInt32(IFF_UP | IFF_POINTOPOINT) else { continue }
            let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            guard ip.s_addr == expected.s_addr else { continue }
            let index = if_nametoindex(interface.ifa_name)
            if index != 0 { return index }
        }
        return nil
    }

    static func makeProbe(port: UInt16) -> NWConnection? {
        guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(sourceAddress), port: .any)
        return NWConnection(host: NWEndpoint.Host(peerAddress), port: port, using: parameters)
    }
}

private struct NativeLocationOutcome: Sendable {
    let error: String?
    let clearStatus: LocationSessionRetryPolicy.Clear
    let retryable: Bool

    init(result: RCLocationResult, returnCode: Int32) {
        switch result.clear_status {
        case RC_LOCATION_CLEAR_NOT_NEEDED: clearStatus = .notNeeded
        case RC_LOCATION_CLEAR_CONFIRMED: clearStatus = .confirmed
        default: clearStatus = .unconfirmed
        }
        retryable = result.retryable != 0
        if returnCode == 0 {
            error = nil
        } else if let message = result.error_message {
            error = String(cString: message)
        } else {
            error = "The iPhone could not finish the location session."
        }
    }
}

private final class LocationCallbackContext {
    let coordinator: LocalDeviceSessionCoordinator
    let runIdentifier: UUID

    init(coordinator: LocalDeviceSessionCoordinator, runIdentifier: UUID) {
        self.coordinator = coordinator
        self.runIdentifier = runIdentifier
    }
}

private let locationStartedCallback: RCLocationStartedCallback = { context in
    guard let context else { return }
    let callback = Unmanaged<LocationCallbackContext>.fromOpaque(context).takeUnretainedValue()
    let coordinator = callback.coordinator
    let runIdentifier = callback.runIdentifier
    DispatchQueue.main.async {
        coordinator.nativeLocationStarted(runIdentifier: runIdentifier)
    }
}
