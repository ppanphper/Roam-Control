enum PairingExpiryStage: CaseIterable {
    case preparing
    case waitingForSettings
    case showingPIN
    case storing

    var message: String {
        switch self {
        case .preparing:
            "Pairing expired before it was ready. Start pairing again, or import an RPPairing file."
        case .waitingForSettings:
            "The iPhone did not connect in time. Start pairing again, then choose Pair with Roam Control in Settings."
        case .showingPIN:
            "Pairing did not finish in time. Start again and enter the new code in Settings."
        case .storing:
            "iOS interrupted saving the pairing. Return to Roam Control to check whether it finished."
        }
    }
}

/// A native worker may finish while the notification server is still accepting
/// the expiry request. Only the originating attempt may release the wait.
struct PairingExpirySubmission<Attempt: Equatable> {
    private var pending: Attempt?

    var isPending: Bool { pending != nil }

    mutating func submit(for attempt: Attempt) { pending = attempt }

    mutating func complete(for attempt: Attempt) -> Bool {
        guard pending == attempt else { return false }
        pending = nil
        return true
    }

    mutating func clear() { pending = nil }
}
