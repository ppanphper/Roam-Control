import Foundation

@main
struct FeatureDataTests {
    @MainActor
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label)
            checks += 1
        }
        func rejects(_ label: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(label) }
            catch { checks += 1 }
        }

        expect(AppLanguage.supportedCodes == FeaturePreferences.supportedLanguageCodes, "language picker and persisted codes agree")
        expect(AppLanguage(preference: "system", preferredLanguages: ["zh-HK"]).code == "zh-Hant", "Hong Kong uses traditional Chinese")
        expect(AppLanguage(preference: "system", preferredLanguages: ["zh-Hans-TW"]).code == "zh-Hans", "explicit Chinese script wins over region")
        expect(AppLanguage(preference: "system", preferredLanguages: ["zz", "fr-CA"]).code == "fr", "first supported system language wins")
        expect(AppLanguage(preference: "ar").isRightToLeft && AppLanguage(preference: "he").isRightToLeft, "both RTL languages")
        expect(AppLanguage(preference: "en", preferredLanguages: ["ar"]).code == "en", "app language overrides system language")
        let rtl = AppLocalization(language: AppLanguage(preference: "ar"))
        expect(rtl.technical("123456") == "\u{2066}123456\u{2069}", "pairing PIN isolation preserves digit order")

        let versions = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        for (a, b) in zip(versions, versions.dropFirst()) {
            expect(SemanticVersion(a)! < SemanticVersion(b)!, "SemVer precedence \(a) < \(b)")
        }
        expect(SemanticVersion("v0.9.9")! < SemanticVersion("0.10.0")!, "numeric minor comparison")
        expect(SemanticVersion("1.0.0+build.30") == SemanticVersion("1.0.0+build.105"), "build metadata excluded from precedence")
        for invalid in ["1.0", "01.0.0", "1.0.0-", "1.0.0+", "1.0.0-01", "1.0.0/a", "1.0.0++a"] {
            expect(SemanticVersion(invalid) == nil, "invalid SemVer \(invalid)")
        }

        let a = LocationTarget(name: "London", subtitle: "Public test coordinate", latitude: 51.5, longitude: -0.12, origin: .manualCoordinate)
        let b = LocationTarget(name: "Tokyo", subtitle: "Public test coordinate", latitude: 35.68, longitude: 139.76, origin: .search)
        let legacy = Data("{\"name\":\"Legacy\",\"subtitle\":\"\",\"latitude\":1,\"longitude\":2}".utf8)
        let legacyTarget = try JSONDecoder().decode(LocationTarget.self, from: legacy)
        expect(legacyTarget.origin == nil, "legacy target without origin decodes")

        let backup = AppBackup(favourites: [a, b], history: [b], appearance: .dark, mapStyle: .satellite,
                               preferences: .init(movementMode: .cycling, units: .metric, compatibility: .off,
                                                  languageCode: "zh-Hans", speeds: ["cycling": 6]))
        let data = try BackupService.encode(backup)
        let roundtrip = try BackupService.decode(data)
        expect(roundtrip.favourites == backup.favourites && roundtrip.preferences == backup.preferences, "backup geometry and preferences roundtrip")
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for excluded in ["pairing", "pairingRecord", "private_key", "activeSessionRecovery", "sharesAnonymousUsageStatistics", "anonymousUsageIdentifier", "diagnostics"] {
            expect(object[excluded] == nil, "private/session key excluded: \(excluded)")
        }
        var bad = backup
        bad.version = 99
        rejects("future backup version rejected") { _ = try BackupService.encode(bad) }
        bad = backup
        bad.favourites = [LocationTarget(name: "Invalid", subtitle: "", latitude: 91, longitude: 0)]
        rejects("out-of-range backup coordinate rejected") { _ = try BackupService.encode(bad) }
        bad = backup; bad.favourites = [a, a]
        rejects("duplicate places rejected") { _ = try BackupService.encode(bad) }
        bad = backup; bad.preferences.speeds = ["walking": .infinity]
        rejects("nonfinite speed rejected") { _ = try bad.validated() }
        bad = backup; bad.preferences.speeds = ["walking": 60]
        rejects("out-of-range speed rejected") { _ = try bad.validated() }
        bad = backup; bad.preferences.languageCode = "unsupported"
        rejects("invalid language rejected") { _ = try BackupService.encode(bad) }
        rejects("bad JSON rejected") { _ = try BackupService.decode(Data("not JSON".utf8)) }
        rejects("backup size bounded") { _ = try BackupService.decode(Data(repeating: 0, count: BackupService.byteLimit + 1)) }

        let suite = "RoamControlTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "sharesAnonymousUsageStatistics")
        defaults.set("test-existing-identity", forKey: "anonymousUsageIdentifier")
        try BackupService.restore(backup, into: defaults)
        expect(defaults.string(forKey: "appAppearance") == "dark", "restore applies appearance")
        expect(defaults.string(forKey: "anonymousUsageIdentifier") == "test-existing-identity", "restore leaves identity alone")
        expect(defaults.bool(forKey: "sharesAnonymousUsageStatistics") == false, "restore does not opt in")
        expect(defaults.data(forKey: BackupService.journalKey) == nil, "successful journal cleared")
        let before = defaults.data(forKey: "favouriteLocations")
        rejects("invalid restore must fail before mutation") { try BackupService.restore(bad, into: defaults) }
        expect(defaults.data(forKey: "favouriteLocations") == before, "invalid restore preserves existing locations")
        defaults.set(data, forKey: BackupService.journalKey)
        defaults.removeObject(forKey: "favouriteLocations")
        BackupService.replayPendingRestore(in: defaults)
        let replayedLocations = try JSONDecoder().decode([LocationTarget].self, from: defaults.data(forKey: "favouriteLocations")!)
        expect(replayedLocations == backup.favourites, "interrupted restore journal replayed")
        let preferences = FeaturePreferences(preferences: defaults)
        expect(preferences.languageCode == "zh-Hans" && preferences.speed(for: .cycling) == 6, "preferences survive fresh load")
        preferences.setSpeed(.nan, for: .walking)
        expect(preferences.speed(for: .walking).isFinite, "nonfinite slider input does not persist")
        preferences.reset()
        expect(!preferences.automaticUpdateChecks, "automatic updates off by default")
        expect(RouteUnits.imperial.displaySpeed(1) > 2.23, "mph conversion")
        expect(abs(RouteUnits.metric.metresPerSecond(36) - 10) < 0.00001, "kmh conversion")

        let oldRecord = SessionRecoveryRecord.walking(from: a, to: b, paceMetresPerSecond: 1.4)
        let decodedRecord = try JSONDecoder().decode(SessionRecoveryRecord.self, from: JSONEncoder().encode(oldRecord))
        expect(decodedRecord.movement == nil && decodedRecord.isWalkingRoute, "legacy recovery retained")
        print("PASS: \(checks) feature-data checks")
    }
}
