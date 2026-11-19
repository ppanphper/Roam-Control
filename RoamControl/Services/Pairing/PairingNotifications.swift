import UIKit
import UserNotifications

/// Identifiers are per attempt so a delayed PIN notification cannot leak into a retry.
@MainActor
final class PairingNotifications {
    private let center = UNUserNotificationCenter.current()
    private let prefix = "roamcontrol.pairing."
    private var postingTask: Task<Void, Never>?
    private var pendingPIN: String?
    private var pendingExpiry: String?

    func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func showPIN(_ pin: String, attempt: UUID, localization: AppLocalization) {
        guard UIApplication.shared.applicationState != .active else { return }
        let identifier = prefix + attempt.uuidString + ".pin"
        guard pendingPIN != identifier else { return }
        clearPIN()
        pendingPIN = identifier
        let content = UNMutableNotificationContent()
        content.title = localization.text("Pairing code ready")
        content.body = localization.format("Enter %@ in Settings", localization.technical(pin))
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        postingTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            try? await center.add(request)
            if Task.isCancelled || pendingPIN != identifier { remove(identifier) }
        }
    }

    func showExpiry(_ reason: String, attempt: UUID, localization: AppLocalization,
                    completion: @escaping @MainActor @Sendable () -> Void) {
        guard UIApplication.shared.applicationState != .active else {
            completion()
            return
        }
        clearExpiry()
        let identifier = prefix + attempt.uuidString + ".expired"
        pendingExpiry = identifier
        let content = UNMutableNotificationContent()
        content.title = localization.text("Pairing expired")
        content.body = localization.text(reason)
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        // This overload submits synchronously; on UIKit's expiration path there
        // may not be another opportunity to run an async Task before suspension.
        center.add(request) { [weak self] _ in
            Task { @MainActor in
                if let self, self.pendingExpiry != identifier { self.remove(identifier) }
                completion()
            }
        }
    }

    func clearPIN() {
        postingTask?.cancel()
        postingTask = nil
        if let pendingPIN { remove(pendingPIN) }
        pendingPIN = nil
    }

    func clearExpiry() {
        if let pendingExpiry { remove(pendingExpiry) }
        pendingExpiry = nil
    }

    private func remove(_ identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
