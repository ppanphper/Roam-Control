import Foundation
import Network
import Observation
import RoamPairingFFI

enum ConnectionCheckState: Equatable {
    case notRun
    case running
    case passed(String)
    case failed(String)
}

@MainActor
@Observable
final class ConnectionDiagnosticsCoordinator: NSObject {
    private var browser: NetServiceBrowser?
    private let probeQueue = DispatchQueue(label: "com.ppanphper.roamcontrol.connection-diagnostics", qos: .utility)
    private var connection: NWConnection?
    private var sawMatchedService = false
    private var pairingRecord: Data?
    private var discoveredServices: [NetService] = []
    private var timeoutTask: Task<Void, Never>?
    private var sawNonMatchingService = false

    private(set) var state: ConnectionCheckState = .notRun
    private(set) var lastChecked: Date?

    func run(pairingRecord: Data?, sessionPhase: DeviceSessionPhase) {
        cancel(resetState: false)

        guard let pairingRecord else {
            finish(.failed("This iPhone is not paired. Open Pairing & Connection and pair it first."))
            return
        }

        switch sessionPhase {
        case .active:
            finish(.passed("The secure location session is active and responding."))
            return
        case .openingLocalDevVPN, .discovering, .connecting, .stopping:
            finish(.failed("Roam Control is already changing the connection. Let it finish, then run the check again."))
            return
        case .idle, .failed:
            break
        }

#if targetEnvironment(simulator)
        finish(.failed("LocalDevVPN reachability can only be checked on a physical iPhone."))
#else
        self.pairingRecord = pairingRecord
        sawNonMatchingService = false
        state = .running
        let browser = NetServiceBrowser()
        self.browser = browser
        browser.delegate = self
        browser.includesPeerToPeer = true
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.state == .running else { return }

            if self.sawMatchedService {
                self.finish(.failed("The device announcement matches your pairing file, but the LocalDevVPN connection could not be reached."))
            } else if self.sawNonMatchingService {
                self.finish(.failed(
                    "LocalDevVPN is visible, but its device announcement does not match the paired iPhone. Toggle LocalDevVPN off and on, then try again."
                ))
            } else {
                self.finish(.failed(
                    "This iPhone was not reachable through LocalDevVPN. Check that the tunnel is connected. On mobile data, switch data off briefly and run the check again."
                ))
            }
        }
#endif
    }

    func cancel() {
        cancel(resetState: true)
    }

    private func cancel(resetState: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.delegate = nil
        browser?.stop()
        browser = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        for service in discoveredServices {
            service.stopMonitoring()
            service.stop()
            service.remove(from: .main, forMode: .common)
            service.delegate = nil
        }

        discoveredServices = []
        pairingRecord = nil
        sawNonMatchingService = false
        sawMatchedService = false

        if resetState, state == .running {
            state = .notRun
        }
    }

    private func resolve(_ service: NetService) {
        guard state == .running else { return }
        service.delegate = self
        service.includesPeerToPeer = true
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 7)
        discoveredServices.append(service)
    }

    private func inspect(_ service: NetService) {
        guard state == .running, discoveredServices.contains(where: { $0 === service }),
              service.port > 0, service.port <= Int(UInt16.max) else { return }
        service.startMonitoring()

        guard
            let pairingRecord,
            let txtData = service.txtRecordData()
        else { return }

        let values = NetService.dictionary(fromTXTRecord: txtData)
        guard
            let identifierData = values["identifier"],
            let authTagData = values["authTag"]
        else { return }

        let identifier = String(decoding: identifierData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let authTag = String(decoding: authTagData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !authTag.isEmpty else { return }

        let matchesPairedDevice = pairingRecord.withUnsafeBytes { recordBytes in
            guard let recordBaseAddress = recordBytes.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }

            return identifier.withCString { serviceIdentifier in
                authTag.withCString { serviceAuthTag in
                    rc_pairing_record_matches_service(
                        recordBaseAddress,
                        pairingRecord.count,
                        serviceIdentifier,
                        serviceAuthTag
                    ) == 1
                }
            }
        }

        guard matchesPairedDevice else {
            sawNonMatchingService = true
            return
        }
        sawMatchedService = true
        guard connection == nil, LocalDevVPNEndpoint.interfaceIndex() != nil,
              let probe = LocalDevVPNEndpoint.makeProbe(port: UInt16(service.port)) else { return }
        connection = probe
        probe.stateUpdateHandler = { [weak self, weak probe] state in
            guard let probe else { return }
            Task { @MainActor in
                guard let self, self.connection === probe else { return }
                switch state {
                case .ready:
                    self.finish(.passed("The paired iPhone's service is reachable through LocalDevVPN."))
                case .failed, .cancelled:
                    probe.stateUpdateHandler = nil
                    probe.cancel()
                    self.connection = nil
                default:
                    break
                }
            }
        }
        probe.start(queue: probeQueue)
    }

    private func finish(_ newState: ConnectionCheckState) {
        cancel(resetState: false)
        state = newState
        lastChecked = Date()
    }
}

extension ConnectionDiagnosticsCoordinator: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        MainActor.assumeIsolated {
            guard self.browser === browser else { return }
            resolve(service)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        MainActor.assumeIsolated {
            guard self.browser === browser else { return }
            finish(.failed("Local Network access is unavailable. Allow it in iPhone Settings, then try again."))
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            inspect(sender)
        }
    }

    nonisolated func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        MainActor.assumeIsolated {
            inspect(sender)
        }
    }
}
