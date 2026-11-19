import Foundation

enum CoordinateCompatibility: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, automatic, force

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "Off"
        case .automatic: "Automatic"
        case .force: "Force"
        }
    }
}
