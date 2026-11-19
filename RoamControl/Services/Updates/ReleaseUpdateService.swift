import Foundation
import Observation

struct SemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]
    var identity: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let buildParts = value.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        let release = String(buildParts[0]).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = release[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        func component(_ s: Substring) -> Int? {
            guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }), s.count == 1 || !s.hasPrefix("0") else { return nil }
            return Int(s)
        }
        guard let major = component(numbers[0]), let minor = component(numbers[1]), let patch = component(numbers[2]) else { return nil }
        let prerelease = release.count == 2 ? release[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        let metadata = buildParts.count == 2 ? buildParts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        func validIdentifier(_ s: String) -> Bool {
            !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        guard prerelease.allSatisfy(validIdentifier), metadata.allSatisfy(validIdentifier),
              prerelease.allSatisfy({ !$0.allSatisfy(\.isNumber) || $0.count == 1 || !$0.hasPrefix("0") }) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            let an = a.allSatisfy(\.isNumber), bn = b.allSatisfy(\.isNumber)
            if an && bn { return a.count == b.count ? a < b : a.count < b.count }
            if an != bn { return an }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct PublicRelease: Decodable, Equatable {
    let tag_name: String
    let name: String?
    let html_url: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
}

enum ReleaseCheckState: Equatable {
    case idle, checking, current, noPublishedRelease
    case available(PublicRelease)
    case failed(String)
}

@MainActor
@Observable
final class ReleaseUpdateService {
    static let repository = "ppanphper/Roam-Control"
    private static let dismissedVersionKey = "dismissedReleaseVersion"
    private(set) var state: ReleaseCheckState = .idle
    private var lastAutomaticCheck: Date?
    private var automaticallyDiscoveredVersion: String?
    private let defaults: UserDefaults
    private let session: URLSession

    var automaticUpdateNotice: PublicRelease? {
        guard case let .available(release) = state,
              let version = SemanticVersion(release.tag_name)?.identity,
              automaticallyDiscoveredVersion == version,
              defaults.string(forKey: Self.dismissedVersionKey) != version else { return nil }
        return release
    }

    init(defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.defaults = defaults
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration)
    }

    func check(automatic: Bool = false) async {
        guard state != .checking else { return }
        if automatic, let lastAutomaticCheck, Date().timeIntervalSince(lastAutomaticCheck) < 86_400 { return }
        if automatic {
            lastAutomaticCheck = .now
            automaticallyDiscoveredVersion = nil
        }
        state = .checking
        do {
            let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=100")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Roam-Control-Personal-Fork", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if response.statusCode == 404 { state = .noPublishedRelease; return }
            guard response.statusCode == 200, data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
            let releases = try JSONDecoder().decode([PublicRelease].self, from: data)
            let stable = releases.filter {
                !$0.draft && !$0.prerelease && SemanticVersion($0.tag_name)?.prerelease.isEmpty == true
                && $0.html_url.scheme == "https" && $0.html_url.host == "github.com"
                && $0.html_url.path.hasPrefix("/\(Self.repository)/releases/tag/")
            }.sorted { SemanticVersion($0.tag_name)! > SemanticVersion($1.tag_name)! }
            guard let latest = stable.first else { state = .noPublishedRelease; return }
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.9"
            guard let currentVersion = SemanticVersion(current) else { throw URLError(.cannotParseResponse) }
            let latestVersion = SemanticVersion(latest.tag_name)!
            guard latestVersion > currentVersion else { state = .current; return }
            if automatic {
                guard defaults.string(forKey: Self.dismissedVersionKey) != latestVersion.identity else {
                    state = .idle
                    return
                }
                automaticallyDiscoveredVersion = latestVersion.identity
            }
            state = .available(latest)
        } catch is CancellationError { state = .idle }
        catch { state = .failed("Could not check this fork's releases. Please try again later.") }
    }

    func dismiss(_ release: PublicRelease) {
        guard let version = SemanticVersion(release.tag_name)?.identity else { return }
        defaults.set(version, forKey: Self.dismissedVersionKey)
        if automaticallyDiscoveredVersion == version { automaticallyDiscoveredVersion = nil }
        if case let .available(current) = state, SemanticVersion(current.tag_name)?.identity == version {
            state = .idle
        }
    }
}
