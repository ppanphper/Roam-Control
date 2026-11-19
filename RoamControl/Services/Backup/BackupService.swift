import Foundation

enum BackupError: LocalizedError {
    case tooLarge, unsupportedVersion, invalidLocations, invalidPreferences, sessionActive
    var errorDescription: String? {
        switch self {
        case .tooLarge: "This backup exceeds the 10 MB limit."
        case .unsupportedVersion: "This backup format is not supported."
        case .invalidLocations: "The backup contains invalid places or too many saved items."
        case .invalidPreferences: "The backup contains invalid preferences."
        case .sessionActive: "Stop and restore the current location session before restoring a backup."
        }
    }
}

struct AppBackup: Codable, Equatable {
    var format = "RoamControlPersonalBackup"
    var version = 1
    var createdAt = Date()
    var favourites: [LocationTarget]
    var history: [LocationTarget]
    var appearance: AppAppearance
    var mapStyle: MapDisplayStyle
    var preferences: FeaturePreferencesSnapshot

    func validated() throws -> Self {
        guard format == "RoamControlPersonalBackup", version == 1 else { throw BackupError.unsupportedVersion }
        guard favourites.count <= 10_000, history.count <= 30 else { throw BackupError.invalidLocations }
        for location in favourites + history {
            guard location.latitude.isFinite, location.longitude.isFinite,
                  (-90...90).contains(location.latitude), (-180...180).contains(location.longitude),
                  location.name.utf8.count <= 8_192, location.subtitle.utf8.count <= 16_384 else {
                throw BackupError.invalidLocations
            }
        }
        guard Set(favourites.map(\.id)).count == favourites.count,
              Set(history.map(\.id)).count == history.count else { throw BackupError.invalidLocations }
        _ = try preferences.validated()
        return self
    }
}

enum BackupService {
    static let byteLimit = 10 * 1_024 * 1_024
    static let journalKey = "pendingValidatedBackupRestore.v1"

    static func encode(_ backup: AppBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup.validated())
        guard data.count <= byteLimit else { throw BackupError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> AppBackup {
        guard data.count <= byteLimit else { throw BackupError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppBackup.self, from: data).validated()
    }

    /// A durable journal makes an interrupted multi-key restore replayable at launch.
    /// All encodings and validation finish before any preference is changed.
    @MainActor
    static func restore(_ backup: AppBackup, into defaults: UserDefaults) throws {
        let data = try encode(backup)
        let encoder = JSONEncoder()
        let favourites = try encoder.encode(backup.favourites)
        let history = try encoder.encode(backup.history)
        let preferences = try encoder.encode(backup.preferences)
        defaults.set(data, forKey: journalKey)
        defaults.set(favourites, forKey: "favouriteLocations")
        defaults.set(history, forKey: "locationHistory")
        defaults.set(backup.appearance.rawValue, forKey: "appAppearance")
        defaults.set(backup.mapStyle.rawValue, forKey: "mapDisplayStyle")
        defaults.set(preferences, forKey: FeaturePreferences.storageKey)
        defaults.removeObject(forKey: journalKey)
    }

    @MainActor
    static func replayPendingRestore(in defaults: UserDefaults) {
        guard let data = defaults.data(forKey: journalKey), let backup = try? decode(data) else { return }
        try? restore(backup, into: defaults)
    }
}
