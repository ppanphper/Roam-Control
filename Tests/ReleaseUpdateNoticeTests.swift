import Foundation

@main
struct ReleaseUpdateNoticeTests {
    @MainActor
    static func main() async {
        let suiteName = "RoamControlReleaseUpdateNoticeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let service = ReleaseUpdateService(defaults: defaults, session: session)
        await service.check()
        guard case let .available(manualRelease) = service.state else {
            preconditionFailure("Manual checks report available versions")
        }
        precondition(manualRelease.tag_name == "v9.10.0+fixture", "Only stable releases from the fork qualify")
        precondition(service.automaticUpdateNotice == nil, "Manual checks do not show a notice")

        await service.check(automatic: true)
        precondition(service.automaticUpdateNotice == manualRelease, "Automatic availability shows a notice")
        await service.check()
        precondition(service.automaticUpdateNotice == manualRelease, "Manual checks do not dismiss an existing notice")
        service.dismiss(manualRelease)
        precondition(service.automaticUpdateNotice == nil && service.state == .idle, "Dismiss clears the notice")
        precondition(defaults.string(forKey: "dismissedReleaseVersion") == "9.10.0", "Ignore by SemVer identity")

        let reopened = ReleaseUpdateService(defaults: defaults, session: session)
        await reopened.check(automatic: true)
        precondition(reopened.automaticUpdateNotice == nil, "Ignored version stays hidden on a fresh launch")
        await reopened.check()
        precondition(reopened.state == .available(manualRelease), "Ignored versions remain visible on manual checks")
        precondition(reopened.automaticUpdateNotice == nil, "Manual result cannot restore an ignored notice")

        defaults.set("9.9.0", forKey: "dismissedReleaseVersion")
        let newer = ReleaseUpdateService(defaults: defaults, session: session)
        await newer.check(automatic: true)
        precondition(newer.automaticUpdateNotice == manualRelease, "Ignoring an older version does not hide a newer one")
        print("PASS: release update notice checks")
    }
}

/// Intercepts the service request in memory; tests never contact GitHub.
private final class ReleaseFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        precondition(request.httpMethod == "GET" && url.host == "api.github.com"
                     && url.path == "/repos/ppanphper/Roam-Control/releases", "Use the personal fork's read-only releases API")
        let fixture = """
        [
          {"tag_name":"v99.0.0","html_url":"https://github.com/another/repo/releases/tag/v99.0.0","draft":false,"prerelease":false},
          {"tag_name":"v11.0.0","html_url":"https://github.com/ppanphper/Roam-Control/releases/tag/v11.0.0","draft":true,"prerelease":false},
          {"tag_name":"v10.0.0-rc.1","html_url":"https://github.com/ppanphper/Roam-Control/releases/tag/v10.0.0-rc.1","draft":false,"prerelease":true},
          {"tag_name":"v9.10.0+fixture","html_url":"https://github.com/ppanphper/Roam-Control/releases/tag/v9.10.0%2Bfixture","draft":false,"prerelease":false}
        ]
        """
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
