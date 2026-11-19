import Foundation
import Observation

enum RouteUnits: String, Codable, CaseIterable, Identifiable {
    case metric, imperial
    var id: Self { self }
    var title: String { self == .metric ? "Kilometres" : "Miles" }
    var speedSymbol: String { self == .metric ? "km/h" : "mph" }
    var speedFactor: Double { self == .metric ? 3.6 : 2.2369362920544 }
    static var regionalDefault: Self {
        Locale.current.measurementSystem == .metric ? .metric : .imperial
    }

    func distance(_ metres: Double, locale: Locale = .current) -> String {
        let value = max(metres.isFinite ? metres : 0, 0)
        func number(_ value: Double, fraction: Int) -> String {
            value.formatted(.number.precision(.fractionLength(fraction)).locale(locale))
        }
        if self == .metric {
            return value < 1_000 ? "\(number(value, fraction: 0)) m" : "\(number(value / 1_000, fraction: 1)) km"
        }
        let miles = value / 1_609.344
        return miles < 0.25 ? "\(number(value / 0.9144, fraction: 0)) yd" : "\(number(miles, fraction: 1)) mi"
    }

    func speed(_ metresPerSecond: Double, locale: Locale = .current) -> String {
        "\(displaySpeed(metresPerSecond).formatted(.number.precision(.fractionLength(1)).locale(locale))) \(speedSymbol)"
    }

    func displaySpeed(_ metresPerSecond: Double) -> Double {
        max(metresPerSecond.isFinite ? metresPerSecond : 0, 0) * speedFactor
    }

    func metresPerSecond(_ displayed: Double) -> Double { displayed / speedFactor }
}

struct FeaturePreferencesSnapshot: Codable, Equatable {
    var movementMode: MovementMode = .walking
    var units: RouteUnits = .regionalDefault
    var compatibility: CoordinateCompatibility = .automatic
    var languageCode: String = "system"
    var speeds: [String: Double] = [:]

    func validated() throws -> Self {
        guard FeaturePreferences.supportedLanguageCodes.contains(languageCode) else {
            throw BackupError.invalidPreferences
        }
        for (key, speed) in speeds {
            guard let mode = MovementMode(rawValue: key), speed.isFinite,
                  mode.speedRange.contains(speed) else { throw BackupError.invalidPreferences }
        }
        return self
    }
}

@MainActor
@Observable
final class FeaturePreferences {
    static let storageKey = "movementAndInterfacePreferences.v1"
    nonisolated static let supportedLanguageCodes = ["system", "en", "he", "ar", "zh-Hans", "zh-Hant", "ja", "vi", "fr", "de", "es"]
    @ObservationIgnored private let defaults: UserDefaults
    private var value: FeaturePreferencesSnapshot
    var automaticUpdateChecks: Bool {
        didSet { defaults.set(automaticUpdateChecks, forKey: "automaticUpdateChecks") }
    }

    init(preferences: UserDefaults = .standard) {
        defaults = preferences
        value = preferences.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(FeaturePreferencesSnapshot.self, from: $0) }
            .flatMap { try? $0.validated() } ?? .init()
        automaticUpdateChecks = preferences.bool(forKey: "automaticUpdateChecks")
    }

    var movementMode: MovementMode {
        get { value.movementMode }
        set { value.movementMode = newValue; persist() }
    }
    var units: RouteUnits {
        get { value.units }
        set { value.units = newValue; persist() }
    }
    var compatibility: CoordinateCompatibility {
        get { value.compatibility }
        set { value.compatibility = newValue; persist() }
    }
    var languageCode: String {
        get { value.languageCode }
        set {
            guard Self.supportedLanguageCodes.contains(newValue) else { return }
            value.languageCode = newValue; persist()
        }
    }
    var snapshot: FeaturePreferencesSnapshot { value }
    func speed(for mode: MovementMode) -> Double {
        value.speeds[mode.rawValue] ?? mode.defaultSpeedMetresPerSecond
    }
    func setSpeed(_ speed: Double, for mode: MovementMode) {
        guard speed.isFinite else { return }
        value.speeds[mode.rawValue] = min(max(speed, mode.speedRange.lowerBound), mode.speedRange.upperBound)
        persist()
    }
    func apply(_ snapshot: FeaturePreferencesSnapshot) throws {
        value = try snapshot.validated()
        persist()
    }
    func reset() {
        value = .init()
        automaticUpdateChecks = false
        persist()
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
