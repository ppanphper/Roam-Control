import Foundation

@main
struct LocationSessionRetryPolicyTests {
    @MainActor
    static func main() async throws {
        let oldLaunch = UUID()
        let currentLaunch = UUID()
        var returnGate = LocalDevVPNReturnGate()
        returnGate.open(oldLaunch)
        returnGate.open(currentLaunch)
        precondition(returnGate.beginDiscovery(for: oldLaunch, usesMobileData: false) == nil)
        // Only a matching return event starts the discovery clock; external app
        // time is never represented in the return gate.
        precondition(returnGate.beginDiscovery(for: currentLaunch, usesMobileData: true) == .mobileData)
        precondition(returnGate.beginDiscovery(for: currentLaunch, usesMobileData: true) == nil)

        let start = ContinuousClock().now
        var budget = ForegroundDiscoveryBudget(duration: .seconds(60), now: start)
        for second in 1...40 {
            precondition(!budget.step(now: start.advanced(by: .seconds(second))))
        }
        // A woken task can run before didBecomeActive. It does not charge that gap.
        precondition(!budget.step(now: start.advanced(by: .seconds(105))))
        for second in 106...124 {
            precondition(!budget.step(now: start.advanced(by: .seconds(second))))
        }
        precondition(budget.step(now: start.advanced(by: .seconds(125))))

        var shortBudget = ForegroundDiscoveryBudget(duration: .seconds(3), now: start)
        precondition(!shortBudget.step(now: start.advanced(by: .seconds(1))))
        precondition(!shortBudget.step(now: start.advanced(by: .seconds(2)), isActive: false))
        precondition(!shortBudget.step(now: start.advanced(by: .seconds(3)), isActive: true))
        precondition(!shortBudget.step(now: start.advanced(by: .seconds(4)), uninterrupted: false))
        precondition(!shortBudget.step(now: start.advanced(by: .seconds(5))))
        precondition(shortBudget.step(now: start.advanced(by: .seconds(6))))

        // Older restoration responsibility is orthogonal to this attempt's evidence.
        // A fresh worker may fail while connecting and prove it did not write.
        var fresh = LocationSessionWriteEvidence()
        fresh.beginWorker()
        precondition(fresh.didAttemptWrite)
        fresh.finishedWorker(clear: .notNeeded, clearOnly: false)
        precondition(!fresh.didAttemptWrite)
        fresh.finishedWorker(clear: .unconfirmed, clearOnly: true)
        precondition(!fresh.didAttemptWrite)

        // Reconnecting a worker before its first new write must keep the current
        // attempt's prior coordinate, including when the first set timed out.
        var reconnect = LocationSessionWriteEvidence()
        reconnect.beginWorker()
        reconnect.startedLocation()
        reconnect.finishedWorker(clear: .notNeeded, clearOnly: false)
        precondition(reconnect.didAttemptWrite)
        var uncertain = LocationSessionWriteEvidence()
        uncertain.beginWorker()
        uncertain.finishedWorker(clear: .unconfirmed, clearOnly: false)
        uncertain.finishedWorker(clear: .notNeeded, clearOnly: false)
        precondition(uncertain.didAttemptWrite)

        func action(_ clear: LocationSessionRetryPolicy.Clear, unresolved: Bool = true,
                    retryable: Bool = true, cancelled: Bool = false, forced: String? = nil,
                    clearOnly: Bool = false, retries: Int = 0) -> LocationSessionRetryPolicy.Action {
            LocationSessionRetryPolicy.action(
                clear: clear, unresolved: unresolved, retryable: retryable, hasError: true,
                wasCancelled: cancelled, forcedFailure: forced, currentAttemptIsClearOnly: clearOnly,
                retryCount: retries
            )
        }
        precondition(action(.unconfirmed) == .reconnect)
        precondition(action(.confirmed, unresolved: false) == .reconnect)
        precondition(action(.unconfirmed, retryable: false) == .finish)
        precondition(action(.notNeeded, retries: 2) == .finish)
        precondition(action(.notNeeded, cancelled: true) == .clearOnly)
        precondition(action(.unconfirmed, cancelled: true) == .clearOnly)
        precondition(action(.unconfirmed, cancelled: true, clearOnly: true) == .finish)
        precondition(action(.notNeeded, cancelled: true, forced: "expired") == .finish)
        precondition(action(.confirmed, unresolved: false, cancelled: true) == .finish)
        precondition(LocationSessionRetryPolicy.finishMessage(
            error: nil, forcedFailure: "expired", wasCancelled: true, clear: .confirmed, unresolved: false
        ) == "expired")
        precondition(LocationSessionRetryPolicy.finishMessage(
            error: nil, forcedFailure: nil, wasCancelled: true, clear: .confirmed, unresolved: false
        ) == nil)
        precondition(LocationSessionRetryPolicy.finishMessage(
            error: nil, forcedFailure: nil, wasCancelled: true, clear: .notNeeded, unresolved: true
        ) != nil)

        var retries = ConsecutiveLocationRetries()
        for _ in 1...2 {
            for _ in 1...2 {
                precondition(action(.notNeeded, retries: retries.count) == .reconnect)
                retries.recordRetry()
            }
            precondition(action(.notNeeded, retries: retries.count) == .finish)
            retries.locationStarted()
        }

        var submission = PairingExpirySubmission<UUID>()
        submission.submit(for: oldLaunch)
        precondition(submission.isPending)
        precondition(!submission.complete(for: currentLaunch))
        precondition(submission.isPending)
        // UIKit expiration clears the pending wait synchronously.
        submission.clear()
        submission.submit(for: currentLaunch)
        precondition(!submission.complete(for: oldLaunch))
        precondition(submission.complete(for: currentLaunch))
        precondition(!submission.isPending)
        precondition(!submission.complete(for: currentLaunch))

        precondition(Set(PairingExpiryStage.allCases.map(\.message)).count == 4)
        precondition(PairingExpiryStage.waitingForSettings.message.contains("choose Pair with Roam Control"))
        precondition(PairingExpiryStage.showingPIN.message.contains("new code"))
        precondition(PairingExpiryStage.storing.message.contains("check whether it finished"))
        try await pairingPickerCopies()
        print("Location retry, foreground discovery, pairing expiry, and temporary copy checks passed")
    }

    @MainActor
    private static func pairingPickerCopies() async throws {
        let fileManager = FileManager.default
        let testArea = fileManager.temporaryDirectory.appending(path: "roam-copy-test-\(UUID())")
        defer { try? fileManager.removeItem(at: testArea) }
        let tmp = testArea.appending(path: "tmp")
        let inbox = tmp.appending(path: "com.roamcontrol-Inbox")
        let siblingInbox = testArea.appending(path: "tmp-sibling/com.roamcontrol-Inbox")
        let external = testArea.appending(path: "my-files")
        for directory in [inbox, siblingInbox, external] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let content = Data("example pairing file".utf8)
        func file(in parent: URL, named name: String = "test.rppairing") throws -> URL {
            let url = parent.appending(path: name)
            try content.write(to: url)
            return url
        }

        let normalCopy = try file(in: inbox)
        let read = try await PairingPickerCopy(url: normalCopy).use(temporaryDirectory: tmp) {
            try Data(contentsOf: $0)
        }
        precondition(read == content && !fileManager.fileExists(atPath: normalCopy.path))

        enum ReadFailure: Error { case invalidRecord }
        let invalidCopy = try file(in: inbox)
        do {
            _ = try await PairingPickerCopy(url: invalidCopy).use(temporaryDirectory: tmp) { url in
                _ = try Data(contentsOf: url)
                throw ReadFailure.invalidRecord
            }
            preconditionFailure("Failed import unexpectedly succeeded")
        } catch ReadFailure.invalidRecord {}
        precondition(!fileManager.fileExists(atPath: invalidCopy.path))

        let cancelledCopy = try file(in: inbox)
        let task = Task { @MainActor in
            await PairingPickerCopy(url: cancelledCopy).use(temporaryDirectory: tmp) { _ in
                preconditionFailure("Cancelled import attempted to read")
            }
        }
        task.cancel()
        _ = await task.value
        precondition(!fileManager.fileExists(atPath: cancelledCopy.path))

        let externalFile = try file(in: external)
        let siblingFile = try file(in: siblingInbox)
        let unrelatedTemporaryFile = try file(in: tmp)
        let link = inbox.appending(path: "linked.rppairing")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: externalFile)
        let linkedInbox = tmp.appending(path: "linked-Inbox")
        try fileManager.createSymbolicLink(at: linkedInbox, withDestinationURL: external)
        let aliased = linkedInbox.appending(path: externalFile.lastPathComponent)
        for original in [externalFile, siblingFile, unrelatedTemporaryFile, link, aliased] {
            let read = try await PairingPickerCopy(url: original).use(temporaryDirectory: tmp) {
                try Data(contentsOf: $0)
            }
            precondition(read == content && fileManager.fileExists(atPath: original.path))
        }
    }
}
