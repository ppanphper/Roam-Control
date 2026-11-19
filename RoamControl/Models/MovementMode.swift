import Foundation

enum MovementMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case walking, cycling, driving

    var id: Self { self }

    var title: String {
        switch self {
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .driving: "Driving"
        }
    }

    var symbol: String {
        switch self {
        case .walking: "figure.walk"
        case .cycling: "bicycle"
        case .driving: "car"
        }
    }

    var defaultSpeedMetresPerSecond: Double {
        switch self {
        case .walking: 1.4
        case .cycling: 5
        case .driving: 50 / 3.6
        }
    }

    var speedRange: ClosedRange<Double> {
        switch self {
        case .walking: 0.1...6
        case .cycling: 0.3...20
        case .driving: 0.5...60
        }
    }

    func limitedSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSpeedMetresPerSecond }
        return min(max(value, speedRange.lowerBound), speedRange.upperBound)
    }
}
