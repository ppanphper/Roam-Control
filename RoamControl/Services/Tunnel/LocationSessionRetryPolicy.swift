import Foundation

/// An external app can be open indefinitely. Only a return event may start discovery.
struct LocalDevVPNReturnGate {
    enum Discovery: Equatable { case standard, mobileData }

    private(set) var launch: UUID?

    mutating func open(_ identifier: UUID) { launch = identifier }
    mutating func clear() { launch = nil }

    mutating func beginDiscovery(for identifier: UUID, usesMobileData: Bool) -> Discovery? {
        guard launch == identifier else { return nil }
        clear()
        return usesMobileData ? .mobileData : .standard
    }
}

/// Outcome facts from the current worker. The prior restoration responsibility is independent.
struct LocationSessionRetryPolicy {
    enum Clear: Equatable { case notNeeded, confirmed, unconfirmed }
    enum Action: Equatable { case reconnect, clearOnly, finish }

    static let maximumRetries = 2

    static func action(
        clear: Clear,
        unresolved: Bool,
        retryable: Bool,
        hasError: Bool,
        wasCancelled: Bool,
        forcedFailure: String?,
        currentAttemptIsClearOnly: Bool,
        retryCount: Int
    ) -> Action {
        guard forcedFailure == nil else { return .finish }
        if wasCancelled {
            // A worker that was reconnecting might have been cancelled before it
            // could clear a previous worker's location, or during a lost transport.
            return unresolved && !currentAttemptIsClearOnly && (clear == .notNeeded || retryable)
                ? .clearOnly : .finish
        }
        return hasError && retryable && retryCount < maximumRetries ? .reconnect : .finish
    }

    static func finishMessage(
        error: String?, forcedFailure: String?, wasCancelled: Bool, clear: Clear, unresolved: Bool
    ) -> String? {
        if let forcedFailure { return forcedFailure }
        if unresolved { return error ?? "The iPhone did not confirm that its simulated location was cleared." }
        return wasCancelled && clear == .confirmed ? nil : error
    }
}

/// Separate evidence for this start from an older attempt's restoration status.
struct LocationSessionWriteEvidence {
    private(set) var didAttemptWrite = false
    private var attemptMayHaveWritten = false

    mutating func beginWorker() { didAttemptWrite = true }

    mutating func startedLocation() {
        attemptMayHaveWritten = true
        didAttemptWrite = true
    }

    mutating func finishedWorker(clear: LocationSessionRetryPolicy.Clear, clearOnly: Bool) {
        guard !clearOnly else { return }
        if clear == .unconfirmed { attemptMayHaveWritten = true }
        if clear == .notNeeded { didAttemptWrite = attemptMayHaveWritten }
    }
}

struct ConsecutiveLocationRetries {
    private(set) var count = 0

    mutating func recordRetry() { count += 1 }
    mutating func locationStarted() { count = 0 }
}

/// Only time between consecutive foreground heartbeats counts. A long gap is
/// ignored even if the timer wakes before UIKit delivers the return event.
struct ForegroundDiscoveryBudget {
    private let duration: Duration
    private var elapsed: Duration = .zero
    private var prior: ContinuousClock.Instant
    private var priorWasActive: Bool

    init(duration: Duration, now: ContinuousClock.Instant, isActive: Bool = true) {
        self.duration = duration
        self.prior = now
        self.priorWasActive = isActive
    }

    mutating func step(now: ContinuousClock.Instant, isActive: Bool = true, uninterrupted: Bool = true) -> Bool {
        let increment = prior.duration(to: now)
        if isActive, priorWasActive, uninterrupted, increment >= .zero, increment <= .seconds(2) {
            elapsed += increment
        }
        prior = now
        priorWasActive = isActive
        return isActive && elapsed >= duration
    }
}
