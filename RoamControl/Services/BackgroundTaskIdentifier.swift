import Foundation

enum SessionExecutionMode: Equatable {
    case inactive
    case waitingForSystem
    case background
    case foregroundOnly
}

enum BackgroundTaskIdentifier {
    static let appIdentifier = "com.ppanphper.roamcontrol"
    static let callbackScheme = "roamcontrol-pandy"

    static func prefix(for component: String) -> String? {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? appIdentifier
        let knownIdentifiers = ["\(bundleIdentifier).\(component).*", "\(appIdentifier).\(component).*"]
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard let identifier = knownIdentifiers.first(where: permitted.contains) else { return nil }
        return String(identifier.dropLast(2))
    }
}
