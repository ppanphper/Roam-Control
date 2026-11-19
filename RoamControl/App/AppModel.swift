import Foundation
import Observation

enum AppOperationError: LocalizedError {
    case resetDuringSession
    var errorDescription: String? {
        "Stop and restore the current location session before resetting Roam Control."
    }
}

@MainActor
@Observable
final class AppModel {
    private static let onboardingKey = "hasCompletedOnboarding"
    private static let favouritesKey = "favouriteLocations"
    private static let historyKey = "locationHistory"
    private static let dismissedResumeLocationKey = "dismissedResumeLocation"
    private static let appearanceKey = "appAppearance"
    private static let mapDisplayStyleKey = "mapDisplayStyle"
    private static let activeSessionRecoveryKey = "activeSessionRecovery"
    private static let priorSessionRecoveryKey = "priorSessionRecoveryBeforeWrite"
    private static let anonymousUsageStatisticsKey = "sharesAnonymousUsageStatistics"

    private let preferences: UserDefaults

    private(set) var hasCompletedOnboarding: Bool
    private(set) var shouldPresentDeviceSetup = false
    private(set) var connectionState: ConnectionState = .notConfigured
    private(set) var pairingStatus: PairingStatus = .checking
    private(set) var selectedTarget: LocationTarget?
    private(set) var favouriteLocations: [LocationTarget]
    private(set) var locationHistory: [LocationTarget]
    private(set) var dismissedResumeLocationID: String?
    private(set) var appearance: AppAppearance
    private(set) var mapDisplayStyle: MapDisplayStyle
    private(set) var sharesAnonymousUsageStatistics: Bool
    private(set) var interruptedSession: SessionRecoveryRecord?
    private(set) var isRestoringInterruptedSession = false
    private(set) var interruptedSessionError: String?
    private(set) var pairingOperationError: String?
    private(set) var activeDisplayTarget: LocationTarget?
    private(set) var pendingGPXImportURL: URL?
    let featurePreferences: FeaturePreferences
    let releaseUpdates: ReleaseUpdateService

    private var activeSessionRecovery: SessionRecoveryRecord?
    private var lastRecoverySaveDate: Date?
    private var restorationReachedActiveSession = false
    private var pendingSessionAnalyticsEvent: UsageAnalyticsEvent?
    private var sessionPreparationToken: UUID?
    private var recoveryBeforeAttempt: SessionRecoveryRecord?
    private var awaitingFirstLocationWrite = false
    private var setupOperationInProgress = false
    @ObservationIgnored private var sessionPhaseObservers: [UUID: (DeviceSessionPhase) -> Void] = [:]
    var isPreparingLocationSession: Bool { sessionPreparationToken != nil }

    var sessionCoordinateCompatibility: CoordinateCompatibility {
        activeSessionRecovery?.coordinateCompatibility
            ?? interruptedSession?.coordinateCompatibility
            ?? featurePreferences.compatibility
    }

    var canChangeCoordinateCompatibility: Bool {
        canDiscardLocationState
    }

    private var canDiscardLocationState: Bool {
        guard !setupOperationInProgress, sessionPreparationToken == nil, !isRestoringInterruptedSession,
              deviceSession.canAcknowledgeManualRestoration,
              activeSessionRecovery == nil, interruptedSession == nil else { return false }
        switch deviceSession.restorationStatus {
        case .pending, .clearing, .requiresRecovery: return false
        default: return true
        }
    }

    @discardableResult
    func observeSessionPhase(_ observer: @escaping (DeviceSessionPhase) -> Void) -> UUID {
        let id = UUID()
        sessionPhaseObservers[id] = observer
        return id
    }

    func removeSessionPhaseObserver(_ id: UUID) { sessionPhaseObservers.removeValue(forKey: id) }

    let pairingService: any PairingService
    let onDevicePairing: OnDevicePairingCoordinator
    let deviceSession: LocalDeviceSessionCoordinator
    private let usageAnalytics: UsageAnalyticsService
    let localDevVPNInstallURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    init(
        pairingService: any PairingService = SecurePairingService(),
        preferences: UserDefaults = .standard
    ) {
        BackupService.replayPendingRestore(in: preferences)
        self.featurePreferences = FeaturePreferences(preferences: preferences)
        self.releaseUpdates = ReleaseUpdateService(defaults: preferences)
        self.pairingService = pairingService
        self.onDevicePairing = .shared
        self.deviceSession = LocalDeviceSessionCoordinator()
        self.usageAnalytics = UsageAnalyticsService(preferences: preferences)
        self.preferences = preferences
        let hasCompletedOnboarding = preferences.bool(forKey: Self.onboardingKey)
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.favouriteLocations = Self.locations(forKey: Self.favouritesKey, in: preferences)
        self.locationHistory = Self.locations(forKey: Self.historyKey, in: preferences)
        self.dismissedResumeLocationID = preferences.string(forKey: Self.dismissedResumeLocationKey)
        self.appearance = AppAppearance(
            rawValue: preferences.string(forKey: Self.appearanceKey) ?? ""
        ) ?? .automatic
        self.mapDisplayStyle = MapDisplayStyle(
            rawValue: preferences.string(forKey: Self.mapDisplayStyleKey) ?? ""
        ) ?? .standard
        self.sharesAnonymousUsageStatistics = Self.initialUsageStatisticsPreference(
            in: preferences
        )
        self.interruptedSession = Self.recoveryRecord(in: preferences)

        deviceSession.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            self.applyDeviceSessionPhase(phase)
            for observer in Array(self.sessionPhaseObservers.values) { observer(phase) }
        }
        deviceSession.onLocationWriteWillBegin = { [weak self] in
            guard let self, self.awaitingFirstLocationWrite else { return }
            if let previous = self.recoveryBeforeAttempt, let data = try? JSONEncoder().encode(previous) {
                self.preferences.set(data, forKey: Self.priorSessionRecoveryKey)
            }
            self.persistRecoveryBeforeFirstWrite()
            self.awaitingFirstLocationWrite = false
        }

        if hasCompletedOnboarding {
            usageAnalytics.recordActivation(enabled: sharesAnonymousUsageStatistics)
        }
    }

    func chooseTarget(_ target: LocationTarget) {
        selectedTarget = target
        addToHistory(target)
    }

    var resumeLocation: LocationTarget? {
        guard let lastLocation = locationHistory.first else { return nil }
        return lastLocation.id == dismissedResumeLocationID ? nil : lastLocation
    }

    func dismissResumeLocation() {
        guard let lastLocation = locationHistory.first else { return }
        dismissedResumeLocationID = lastLocation.id
        preferences.set(lastLocation.id, forKey: Self.dismissedResumeLocationKey)
    }

    func isFavourite(_ target: LocationTarget) -> Bool {
        favouriteLocations.contains { $0.id == target.id }
    }

    func toggleFavourite(_ target: LocationTarget) {
        if let index = favouriteLocations.firstIndex(where: { $0.id == target.id }) {
            favouriteLocations.remove(at: index)
        } else {
            favouriteLocations.insert(target, at: 0)
        }
        save(favouriteLocations, forKey: Self.favouritesKey)
    }

    func removeFavourite(_ target: LocationTarget) {
        favouriteLocations.removeAll { $0.id == target.id }
        save(favouriteLocations, forKey: Self.favouritesKey)
    }

    func renameFavourite(_ target: LocationTarget, to proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !name.isEmpty,
            let index = favouriteLocations.firstIndex(where: { $0.id == target.id })
        else { return }

        let renamed = LocationTarget(
            name: name,
            subtitle: target.subtitle,
            latitude: target.latitude,
            longitude: target.longitude,
            origin: target.origin
        )
        favouriteLocations[index] = renamed
        if selectedTarget?.id == target.id {
            selectedTarget = renamed
        }
        save(favouriteLocations, forKey: Self.favouritesKey)
    }

    func removeFromHistory(_ target: LocationTarget) {
        locationHistory.removeAll { $0.id == target.id }
        save(locationHistory, forKey: Self.historyKey)
    }

    func clearLocationHistory() {
        locationHistory = []
        dismissedResumeLocationID = nil
        preferences.removeObject(forKey: Self.historyKey)
    }

    func clearFavouriteLocations() {
        favouriteLocations = []
        preferences.removeObject(forKey: Self.favouritesKey)
    }

    func moveFavourites(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let valid = offsets.filter { favouriteLocations.indices.contains($0) }
        let moved = valid.map { favouriteLocations[$0] }
        var remaining = favouriteLocations.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = min(max(destination - valid.filter { $0 < destination }.count, 0), remaining.count)
        remaining.insert(contentsOf: moved, at: insertion)
        favouriteLocations = remaining
        save(favouriteLocations, forKey: Self.favouritesKey)
    }

    func makeBackup() -> AppBackup {
        AppBackup(favourites: favouriteLocations, history: locationHistory,
                  appearance: appearance, mapStyle: mapDisplayStyle,
                  preferences: featurePreferences.snapshot)
    }

    func restoreBackup(_ backup: AppBackup) throws {
        guard canDiscardLocationState else { throw BackupError.sessionActive }
        let checked = try backup.validated()
        try BackupService.restore(checked, into: preferences)
        favouriteLocations = checked.favourites
        locationHistory = checked.history
        setAppearance(checked.appearance)
        setMapDisplayStyle(checked.mapStyle)
        try featurePreferences.apply(checked.preferences)
        dismissedResumeLocationID = nil
        preferences.removeObject(forKey: Self.dismissedResumeLocationKey)
    }

    func setAppearance(_ appearance: AppAppearance) {
        self.appearance = appearance
        preferences.set(appearance.rawValue, forKey: Self.appearanceKey)
    }

    func setMapDisplayStyle(_ style: MapDisplayStyle) {
        mapDisplayStyle = style
        preferences.set(style.rawValue, forKey: Self.mapDisplayStyleKey)
    }

    func setSharesAnonymousUsageStatistics(_ enabled: Bool) {
        sharesAnonymousUsageStatistics = enabled
        preferences.set(enabled, forKey: Self.anonymousUsageStatisticsKey)

        if enabled, hasCompletedOnboarding {
            usageAnalytics.recordActivation(enabled: true)
        } else if !enabled {
            usageAnalytics.revokeLocalIdentity()
        }
    }

    func completeOnboarding() {
        preferences.set(
            sharesAnonymousUsageStatistics,
            forKey: Self.anonymousUsageStatisticsKey
        )
        preferences.set(true, forKey: Self.onboardingKey)
        shouldPresentDeviceSetup = true
        hasCompletedOnboarding = true
        usageAnalytics.record(
            .onboardingCompleted,
            enabled: sharesAnonymousUsageStatistics
        )
        usageAnalytics.recordActivation(enabled: sharesAnonymousUsageStatistics)
    }

    func deviceSetupWasPresented() {
        shouldPresentDeviceSetup = false
    }

    func resetApp() async throws {
        guard canDiscardLocationState, !onDevicePairing.isRunning else { throw AppOperationError.resetDuringSession }
        setupOperationInProgress = true
        defer { setupOperationInProgress = false }
        onDevicePairing.reset()
        deviceSession.reset()
        try await pairingService.removeRecord()

        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            preferences.removePersistentDomain(forName: bundleIdentifier)
        } else {
            preferences.removeObject(forKey: Self.onboardingKey)
        }

        selectedTarget = nil
        activeDisplayTarget = nil
        favouriteLocations = []
        locationHistory = []
        appearance = .automatic
        mapDisplayStyle = .standard
        featurePreferences.reset()
        sharesAnonymousUsageStatistics = false
        interruptedSession = nil
        activeSessionRecovery = nil
        isRestoringInterruptedSession = false
        interruptedSessionError = nil
        pairingOperationError = nil
        pairingStatus = .notPaired
        connectionState = .notConfigured
        shouldPresentDeviceSetup = false
        hasCompletedOnboarding = false
        usageAnalytics.revokeLocalIdentity()
    }

    func restorePairingStatus() async {
        pairingStatus = .checking

        do {
            if let summary = try await pairingService.storedRecord() {
                pairingStatus = .paired(summary)
                if deviceSession.phase == .idle {
                    connectionState = .ready
                }
            } else {
                pairingStatus = .notPaired
                connectionState = .notConfigured
            }
        } catch {
            pairingStatus = .failed(message: error.localizedDescription)
            connectionState = .failed(message: error.localizedDescription)
        }
    }

    func importPairingRecord(from url: URL) async {
        pairingStatus = .importing

        do {
            let summary = try await pairingService.importRecord(from: url)
            pairingStatus = .paired(summary)
            connectionState = .ready
        } catch {
            pairingStatus = .failed(message: error.localizedDescription)
            connectionState = .failed(message: error.localizedDescription)
        }
    }

    func startOnDevicePairing() {
        onDevicePairing.start { [weak self] record, hostAltIRK in
            guard let self else {
                throw PairingServiceError.corruptStoredRecord
            }

            let summary = try await self.pairingService.storeGeneratedRecord(
                record,
                hostAltIRK: hostAltIRK
            )
            self.pairingStatus = .paired(summary)
            self.connectionState = .ready
            self.usageAnalytics.record(
                .pairingCompleted,
                enabled: self.sharesAnonymousUsageStatistics
            )
            return summary
        }
    }

    func cancelOnDevicePairing() {
        onDevicePairing.cancel()
    }

    func startLocationSession(at target: LocationTarget) async {
        await startLocationSession(
            at: target,
            selectedTarget: target,
            historyTarget: target,
            recovery: .fixed(at: target)
        )
    }

    func startWalkingLocationSession(
        at initialTarget: LocationTarget,
        destination: LocationTarget,
        paceMetresPerSecond: Double
    ) async {
        await startLocationSession(
            at: initialTarget,
            selectedTarget: destination,
            historyTarget: destination,
            recovery: .walking(
                from: initialTarget,
                to: destination,
                paceMetresPerSecond: paceMetresPerSecond
            )
        )
    }

    func startMovementSession(at target: LocationTarget, snapshot: MovementSnapshot) async {
        guard snapshot.isValid else {
            interruptedSessionError = "This movement session could not be restored."
            return
        }
        var recovery = SessionRecoveryRecord.fixed(at: target)
        recovery.kind = .movement
        recovery.destination = snapshot.route?.destination
        recovery.walkingPaceMetresPerSecond = snapshot.speedMetresPerSecond
        recovery.movement = snapshot
        await startLocationSession(at: target, selectedTarget: snapshot.route?.historyDestination ?? target,
                                   historyTarget: snapshot.route?.historyDestination ?? target,
                                   recovery: recovery, recordsHistory: !snapshot.isJoystick)
    }

    func updateMovementLocation(_ target: LocationTarget, snapshot: MovementSnapshot) -> ActiveLocationUpdateResult {
        guard snapshot.isValid, RouteCoordinate(target.coordinate).isValid else { return .failed }
        guard case .active = deviceSession.phase else { return .unavailable }
        activeDisplayTarget = target
        if var recovery = activeSessionRecovery {
            if recovery.movement?.isPaused != snapshot.isPaused
                || recovery.movement?.mode != snapshot.mode
                || recovery.movement?.speedMetresPerSecond != snapshot.speedMetresPerSecond
                || recovery.movement?.route?.id != snapshot.route?.id
                || Self.justArrived(previous: recovery.movement, current: snapshot) {
                lastRecoverySaveDate = nil
            }
            recovery.movement = snapshot
            activeSessionRecovery = recovery
        }
        let result = deviceSession.updateLocation(CoordinateTransform.deviceTarget(target, compatibility: sessionCoordinateCompatibility))
        if result == .updated { saveMovementRecovery(at: target, snapshot: snapshot) }
        return result
    }

    func saveMovementRecovery(at target: LocationTarget, snapshot: MovementSnapshot) {
        guard snapshot.isValid else { return }
        let old = activeSessionRecovery?.movement
        var recovery = activeSessionRecovery ?? .fixed(at: target)
        recovery.coordinateCompatibility = sessionCoordinateCompatibility
        recovery.kind = .movement
        recovery.destination = snapshot.route?.destination
        recovery.movement = snapshot
        recovery.lastReportedLocation = target
        recovery.updatedAt = .now
        activeSessionRecovery = recovery
        let stateChanged = old?.isPaused != snapshot.isPaused || old?.mode != snapshot.mode
            || old?.speedMetresPerSecond != snapshot.speedMetresPerSecond
            || old?.route?.id != snapshot.route?.id || old?.isJoystick != snapshot.isJoystick
            || Self.justArrived(previous: old, current: snapshot)
        if stateChanged { lastRecoverySaveDate = nil }
        persistActiveSessionRecovery(at: target)
    }

    /// End movement controls while leaving the native location connection at its current point.
    func continueAsFixedLocation() {
        guard case .active = deviceSession.phase, let target = activeDisplayTarget else { return }
        var recovery = SessionRecoveryRecord.fixed(at: target)
        recovery.coordinateCompatibility = sessionCoordinateCompatibility
        activeSessionRecovery = recovery
        selectedTarget = target
        lastRecoverySaveDate = nil
        persistActiveSessionRecovery(at: target)
    }

    private func startLocationSession(
        at deviceTarget: LocationTarget,
        selectedTarget: LocationTarget,
        historyTarget: LocationTarget,
        recovery: SessionRecoveryRecord,
        recordsHistory: Bool = true
    ) async {
        guard case .paired = pairingStatus else {
            connectionState = .notConfigured
            return
        }
        guard !setupOperationInProgress, sessionPreparationToken == nil, !isRestoringInterruptedSession, !deviceSession.isBusy else { return }
        var recovery = recovery
        let compatibility = sessionCoordinateCompatibility
        recovery.coordinateCompatibility = compatibility
        let outputTarget = CoordinateTransform.deviceTarget(deviceTarget, compatibility: compatibility)
        func prepareRecovery() {
            recoveryBeforeAttempt = interruptedSession ?? activeSessionRecovery
            self.selectedTarget = selectedTarget
            activeDisplayTarget = deviceTarget
            interruptedSession = nil
            interruptedSessionError = nil
            activeSessionRecovery = recovery
            lastRecoverySaveDate = nil
            dismissedResumeLocationID = nil
            preferences.removeObject(forKey: Self.dismissedResumeLocationKey)
            if recordsHistory { addToHistory(historyTarget) }
            awaitingFirstLocationWrite = true
        }
        if case .active = deviceSession.phase {
            prepareRecovery()
            switch deviceSession.updateLocation(outputTarget) {
        case .updated:
            recoveryBeforeAttempt = nil
            usageAnalytics.record(
                .activeLocationUpdated,
                enabled: sharesAnonymousUsageStatistics
            )
            return
        case .failed:
            return
        case .unavailable:
            break
            }
        }
        let token = UUID()
        sessionPreparationToken = token
        connectionState = .connecting
        defer {
            if sessionPreparationToken == token {
                sessionPreparationToken = nil
                if Task.isCancelled { applyDeviceSessionPhase(deviceSession.phase) }
            }
        }
        do {
            let record = try await pairingService.pairingRecordData()
            guard sessionPreparationToken == token, !Task.isCancelled else { return }
            guard let pairingRecord = record else {
                pairingStatus = .notPaired
                connectionState = .notConfigured
                return
            }
            prepareRecovery()
            pendingSessionAnalyticsEvent = UsageAnalyticsEvent.sessionStarted(for: recovery)
            deviceSession.start(pairingRecord: pairingRecord, target: outputTarget)
        } catch {
            guard sessionPreparationToken == token, !Task.isCancelled else { return }
            pendingSessionAnalyticsEvent = nil
            connectionState = .failed(message: error.localizedDescription)
            interruptedSessionError = error.localizedDescription
        }
    }

    func restoreRealLocationFromInterruptedSession() async {
        guard let recovery = interruptedSession else { return }
        guard sessionPreparationToken == nil, !isRestoringInterruptedSession, !deviceSession.isBusy else { return }
        guard case .paired = pairingStatus else {
            interruptedSessionError = "Pair this iPhone before restoring its real location."
            return
        }

        interruptedSessionError = nil
        isRestoringInterruptedSession = true
        restorationReachedActiveSession = false
        let token = UUID()
        sessionPreparationToken = token
        defer {
            if sessionPreparationToken == token {
                sessionPreparationToken = nil
                if Task.isCancelled { isRestoringInterruptedSession = false }
            }
        }
        do {
            let record = try await pairingService.pairingRecordData()
            guard sessionPreparationToken == token, !Task.isCancelled else { return }
            guard let pairingRecord = record else {
                isRestoringInterruptedSession = false
                interruptedSessionError = "The saved pairing record is unavailable. Pair this iPhone again."
                return
            }
            deviceSession.restore(
                pairingRecord: pairingRecord,
                target: recovery.lastReportedLocation
            )
        } catch {
            guard sessionPreparationToken == token, !Task.isCancelled else { return }
            isRestoringInterruptedSession = false
            interruptedSessionError = error.localizedDescription
        }
    }

    func cancelInterruptedSessionRestoration() {
        guard isRestoringInterruptedSession else { return }
        sessionPreparationToken = nil
        isRestoringInterruptedSession = false
        restorationReachedActiveSession = false
        deviceSession.stop()
    }

    func completeInterruptedSessionRestorationAfterMobileData() {
        guard isRestoringInterruptedSession, restorationReachedActiveSession else { return }
        deviceSession.dismissMobileDataGuidance()
        deviceSession.stop()
    }

    func dismissInterruptedSessionRecovery() {
        guard sessionPreparationToken == nil, !isRestoringInterruptedSession,
              deviceSession.canAcknowledgeManualRestoration else { return }
        forgetSessionRecovery()
        deviceSession.acknowledgeManualRestoration()
    }

    private func forgetSessionRecovery() {
        interruptedSession = nil
        interruptedSessionError = nil
        activeSessionRecovery = nil
        recoveryBeforeAttempt = nil
        awaitingFirstLocationWrite = false
        lastRecoverySaveDate = nil
        activeDisplayTarget = nil
        preferences.removeObject(forKey: Self.activeSessionRecoveryKey)
        preferences.removeObject(forKey: Self.priorSessionRecoveryKey)
    }

    func stopLocationSession() {
        sessionPreparationToken = nil
        deviceSession.stop()
        if deviceSession.phase == .idle { applyDeviceSessionPhase(.idle) }
    }

    func handleOpenURL(_ url: URL) {
        if url.isFileURL, url.pathExtension.lowercased() == "gpx" {
            pendingGPXImportURL = url
            return
        }
        deviceSession.handleOpenURL(url)
    }

    func consumeGPXImportURL() { pendingGPXImportURL = nil }

    func appBecameActive() {
        deviceSession.appDidBecomeActive()
        guard hasCompletedOnboarding else { return }
        usageAnalytics.recordActivation(enabled: sharesAnonymousUsageStatistics)
        if featurePreferences.automaticUpdateChecks {
            Task { await releaseUpdates.check(automatic: true) }
        }
    }

    func removePairingRecord() async {
        pairingOperationError = nil
        guard canDiscardLocationState, !onDevicePairing.isRunning else {
            pairingOperationError = "Restore the real location before removing pairing."
            return
        }
        setupOperationInProgress = true
        defer { setupOperationInProgress = false }
        onDevicePairing.reset()
        deviceSession.reset()
        do {
            try await pairingService.removeRecord()
            pairingStatus = .notPaired
            connectionState = .notConfigured
        } catch {
            pairingOperationError = error.localizedDescription
            pairingStatus = .failed(message: error.localizedDescription)
            connectionState = .failed(message: error.localizedDescription)
        }
    }

    private func addToHistory(_ target: LocationTarget) {
        locationHistory.removeAll { $0.id == target.id }
        locationHistory.insert(target, at: 0)
        locationHistory = Array(locationHistory.prefix(30))
        save(locationHistory, forKey: Self.historyKey)
    }

    private func applyDeviceSessionPhase(_ phase: DeviceSessionPhase) {
        switch phase {
        case .idle:
            activeDisplayTarget = nil
            pendingSessionAnalyticsEvent = nil
            let confirmed = deviceSession.restorationStatus == .deviceConfirmed
            if isRestoringInterruptedSession {
                isRestoringInterruptedSession = false
                restorationReachedActiveSession = false
                if confirmed {
                    forgetSessionRecovery()
                }
            }
            if confirmed {
                forgetSessionRecovery()
            } else if !deviceSession.didAttemptLocationWrite || deviceSession.restorationStatus == .userConfirmed {
                isRestoringInterruptedSession = false
                restorationReachedActiveSession = false
                retainRecoveryBeforeUnwrittenAttempt()
            } else {
                retainUnconfirmedActiveRecovery()
            }
            if case .paired = pairingStatus {
                connectionState = .ready
            } else {
                connectionState = .notConfigured
            }
        case .openingLocalDevVPN, .discovering, .connecting, .stopping:
            connectionState = .connecting
        case .active(let target):
            if recoveryBeforeAttempt != nil || awaitingFirstLocationWrite {
                recoveryBeforeAttempt = nil
                awaitingFirstLocationWrite = false
                preferences.removeObject(forKey: Self.priorSessionRecoveryKey)
            }
            connectionState = .active
            if let event = pendingSessionAnalyticsEvent {
                usageAnalytics.record(event, enabled: sharesAnonymousUsageStatistics)
                pendingSessionAnalyticsEvent = nil
            }
            if isRestoringInterruptedSession {
                restorationReachedActiveSession = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard let self, self.isRestoringInterruptedSession else { return }
                    if self.deviceSession.mobileDataGuidance != .turnBackOn {
                        self.deviceSession.stop()
                    }
                }
            } else {
                persistActiveSessionRecovery(at: activeDisplayTarget ?? target)
            }
        case .failed(let message):
            pendingSessionAnalyticsEvent = nil
            connectionState = .failed(message: message)
            if deviceSession.restorationStatus == .deviceConfirmed {
                isRestoringInterruptedSession = false
                restorationReachedActiveSession = false
                forgetSessionRecovery()
                activeDisplayTarget = nil
            } else if !deviceSession.didAttemptLocationWrite || deviceSession.restorationStatus == .userConfirmed {
                isRestoringInterruptedSession = false
                restorationReachedActiveSession = false
                interruptedSessionError = message
                retainRecoveryBeforeUnwrittenAttempt()
            } else if isRestoringInterruptedSession {
                isRestoringInterruptedSession = false
                restorationReachedActiveSession = false
                interruptedSessionError = message
            } else if activeSessionRecovery != nil {
                retainUnconfirmedActiveRecovery()
                interruptedSessionError = message
            }
        }
    }

    private func retainUnconfirmedActiveRecovery() {
        guard let recovery = activeSessionRecovery else { return }
        interruptedSession = recovery
        // This attempt may have changed the device. A later clear-only failure
        // must retain this record instead of resurrecting the older target.
        recoveryBeforeAttempt = nil
        awaitingFirstLocationWrite = false
        preferences.removeObject(forKey: Self.priorSessionRecoveryKey)
        if let data = try? JSONEncoder().encode(recovery) {
            preferences.set(data, forKey: Self.activeSessionRecoveryKey)
        }
    }

    private func retainRecoveryBeforeUnwrittenAttempt() {
        let recovery = recoveryBeforeAttempt ?? interruptedSession
        recoveryBeforeAttempt = nil
        awaitingFirstLocationWrite = false
        preferences.removeObject(forKey: Self.priorSessionRecoveryKey)
        activeSessionRecovery = nil
        activeDisplayTarget = nil
        interruptedSession = recovery
        lastRecoverySaveDate = nil
        if let recovery, let data = try? JSONEncoder().encode(recovery) {
            preferences.set(data, forKey: Self.activeSessionRecoveryKey)
        } else {
            preferences.removeObject(forKey: Self.activeSessionRecoveryKey)
        }
    }

    private func persistActiveSessionRecovery(at target: LocationTarget) {
        guard var recovery = activeSessionRecovery else { return }
        let now = Date.now

        if
            recovery.kind == .walkingRoute,
            let destination = recovery.destination,
            destination.id == target.id
        {
            recovery = .fixed(at: destination)
        } else {
            recovery.lastReportedLocation = target
            recovery.updatedAt = now
        }
        activeSessionRecovery = recovery

        let shouldSave = lastRecoverySaveDate == nil
            || now.timeIntervalSince(lastRecoverySaveDate ?? .distantPast) >= 5
            || recovery.kind == .fixedLocation
        guard shouldSave, let data = try? JSONEncoder().encode(recovery) else { return }
        preferences.set(data, forKey: Self.activeSessionRecoveryKey)
        lastRecoverySaveDate = now
    }

    private func persistRecoveryBeforeFirstWrite() {
        guard let recovery = activeSessionRecovery, let data = try? JSONEncoder().encode(recovery) else { return }
        preferences.set(data, forKey: Self.activeSessionRecoveryKey)
        lastRecoverySaveDate = .now
    }

    private static func justArrived(previous: MovementSnapshot?, current: MovementSnapshot) -> Bool {
        guard !current.isJoystick, let route = current.route else { return false }
        return current.distanceTravelled >= route.distanceMetres
            && (previous?.distanceTravelled ?? -1) < route.distanceMetres
    }

    private func clearActiveSessionRecovery() {
        guard activeSessionRecovery != nil else { return }
        activeSessionRecovery = nil
        lastRecoverySaveDate = nil
        preferences.removeObject(forKey: Self.activeSessionRecoveryKey)
    }

    private func save(_ locations: [LocationTarget], forKey key: String) {
        guard let data = try? JSONEncoder().encode(locations) else { return }
        preferences.set(data, forKey: key)
    }

    private static func locations(forKey key: String, in preferences: UserDefaults) -> [LocationTarget] {
        guard
            let data = preferences.data(forKey: key),
            let locations = try? JSONDecoder().decode([LocationTarget].self, from: data)
        else {
            return []
        }
        return locations
    }

    private static func recoveryRecord(in preferences: UserDefaults) -> SessionRecoveryRecord? {
        for key in [Self.activeSessionRecoveryKey, Self.priorSessionRecoveryKey] {
            if let data = preferences.data(forKey: key),
               let recovery = try? JSONDecoder().decode(SessionRecoveryRecord.self, from: data) { return recovery }
        }
        return nil
    }

    private static func initialUsageStatisticsPreference(
        in preferences: UserDefaults
    ) -> Bool {
        if preferences.object(forKey: Self.anonymousUsageStatisticsKey) != nil {
            return preferences.bool(forKey: Self.anonymousUsageStatisticsKey)
        }

        // A missing preference is never treated as consent. Existing saved
        // choices continue unchanged when the app is upgraded.
        return false
    }
}

enum PairingStatus: Equatable {
    case checking
    case importing
    case notPaired
    case paired(PairingRecordSummary)
    case failed(message: String)
}

enum ConnectionState: Equatable {
    case notConfigured
    case ready
    case connecting
    case active
    case failed(message: String)
}
