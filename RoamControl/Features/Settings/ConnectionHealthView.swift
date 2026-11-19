import SwiftUI

struct ConnectionHealthView: View {
    @Environment(\.appLocalization) private var l10n
    @Environment(AppModel.self) private var appModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var diagnostics = ConnectionDiagnosticsCoordinator()
    @State private var isShowingDeviceSetup = false
    @State private var isReviewingReport = false
    @State private var includesLocation = false

    var body: some View {
        List {
            Section("Connection Health") {
                healthRow(
                    title: "Pairing",
                    value: pairingValue,
                    symbol: pairingSymbol,
                    color: pairingColor
                )

                healthRow(
                    title: "LocalDevVPN",
                    value: localDevVPNValue,
                    symbol: localDevVPNSymbol,
                    color: localDevVPNColor
                )

                healthRow(
                    title: "Location Session",
                    value: sessionValue,
                    symbol: sessionSymbol,
                    color: sessionColor
                )
                LabeledContent("Execution", value: l10n.text(executionValue))
                LabeledContent("Restoration", value: l10n.text(restorationValue))
            }

            Section("Current Location") {
                LabeledContent("Place", value: activeTarget.map(l10n.name) ?? l10n.text("None"))
                LabeledContent("Coordinates", value: renderedCoordinates)

                if let activeTarget, !activeTarget.subtitle.isEmpty {
                    LabeledContent("Area", value: l10n.subtitle(of: activeTarget))
                }
            }

            Section {
                Button {
                    Task { await runConnectionCheck() }
                } label: {
                    HStack {
                        Label("Run Connection Check", systemImage: "stethoscope")
                        Spacer()
                        if diagnostics.state == .running {
                            ProgressView()
                        }
                    }
                }
                .disabled(diagnostics.state == .running)

                if let resultMessage {
                    Label(l10n.text(resultMessage), systemImage: resultSymbol)
                        .font(.subheadline)
                        .foregroundStyle(resultColor)
                }

                if let lastChecked = diagnostics.lastChecked {
                    LabeledContent(
                        "Last checked",
                        value: lastChecked.formatted(.dateTime.hour().minute().locale(l10n.locale))
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Connection Check")
            } footer: {
                Text("This checks the saved pairing record and whether the paired iPhone is visible through LocalDevVPN. It never starts, changes, or stops your location.")
            }

            Section {
                Button("Review Diagnostics", systemImage: "doc.text.magnifyingglass") { isReviewingReport = true }
            } footer: {
                Text("Review the report before choosing where to share it. Location details are excluded by default. Pairing keys and PINs are never included.")
            }

            Section("Other VPNs") {
                Text("LocalDevVPN must remain connected. A Personal VPN may coexist, but another Device VPN can replace its tunnel. If connection fails, pause the other VPN and retry while keeping LocalDevVPN enabled.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Help") {
                Button {
                    isShowingDeviceSetup = true
                } label: {
                    Label("Pairing & Connection", systemImage: "iphone.and.arrow.forward")
                }
                .foregroundStyle(.primary)

                Link(destination: appModel.localDevVPNInstallURL) {
                    Label("Open LocalDevVPN in App Store", systemImage: "arrow.up.right.square")
                }
            }
        }
        .navigationTitle(Text(verbatim: l10n.text("Connection Health")))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            diagnostics.cancel()
        }
        .sheet(isPresented: $isShowingDeviceSetup) {
            PairingSetupView()
                .environment(appModel)
        }
        .sheet(isPresented: $isReviewingReport) {
            NavigationStack {
                List {
                    Toggle("Include Place and Coordinates", isOn: $includesLocation)
                    Text(diagnosticsText).font(.footnote.monospaced()).textSelection(.enabled)
                    ShareLink(item: diagnosticsText, subject: Text("Roam Control Diagnostics")) {
                        Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                    }
                }
                .navigationTitle(Text(verbatim: l10n.text("Review Diagnostics")))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { isReviewingReport = false } } }
            }
        }
    }

    private var activeTarget: LocationTarget? {
        if case .active(let target) = appModel.deviceSession.phase {
            return target
        }
        return nil
    }

    private var coordinatesValue: String {
        guard let activeTarget else { return "None" }
        return String(format: "%.5f, %.5f", activeTarget.latitude, activeTarget.longitude)
    }

    private var renderedCoordinates: String {
        activeTarget == nil ? l10n.text("None") : l10n.technical(coordinatesValue)
    }

    private var pairingValue: String {
        switch appModel.pairingStatus {
        case .checking: "Checking"
        case .importing: "Importing"
        case .notPaired: "Not paired"
        case .paired: "Ready"
        case .failed: "Problem"
        }
    }

    private var pairingSymbol: String {
        switch appModel.pairingStatus {
        case .checking, .importing: "arrow.triangle.2.circlepath"
        case .notPaired: "exclamationmark.circle"
        case .paired: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var pairingColor: Color {
        switch appModel.pairingStatus {
        case .checking, .importing: .blue
        case .notPaired: .orange
        case .paired: .green
        case .failed: .red
        }
    }

    private var localDevVPNValue: String {
        switch diagnostics.state {
        case .notRun:
            if case .active = appModel.deviceSession.phase { return "Connected" }
            return "Not checked"
        case .running: return "Checking"
        case .passed: return "Reachable"
        case .failed: return "Not reachable"
        }
    }

    private var localDevVPNSymbol: String {
        switch diagnostics.state {
        case .notRun:
            if case .active = appModel.deviceSession.phase { return "checkmark.circle.fill" }
            return "questionmark.circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var localDevVPNColor: Color {
        switch diagnostics.state {
        case .notRun:
            if case .active = appModel.deviceSession.phase { return .green }
            return .secondary
        case .running: return .blue
        case .passed: return .green
        case .failed: return .red
        }
    }

    private var sessionValue: String {
        switch appModel.deviceSession.phase {
        case .idle: "Inactive"
        case .openingLocalDevVPN: "Opening LocalDevVPN"
        case .discovering: "Finding this iPhone"
        case .connecting: "Connecting"
        case .active: "Active"
        case .stopping: "Stopping"
        case .failed: "Failed"
        }
    }

    private var sessionSymbol: String {
        switch appModel.deviceSession.phase {
        case .idle: "pause.circle"
        case .openingLocalDevVPN, .discovering, .connecting: "arrow.triangle.2.circlepath"
        case .active: "location.circle.fill"
        case .stopping: "stop.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var sessionColor: Color {
        switch appModel.deviceSession.phase {
        case .idle: .secondary
        case .openingLocalDevVPN, .discovering, .connecting, .stopping: .blue
        case .active: .green
        case .failed: .red
        }
    }

    private var executionValue: String {
        switch appModel.deviceSession.executionMode {
        case .inactive: "Inactive"
        case .waitingForSystem: "Waiting for iOS"
        case .background: "Background Task"
        case .foregroundOnly: "Keep This App Open"
        }
    }

    private var restorationValue: String {
        switch appModel.deviceSession.restorationStatus {
        case .notRequired: "Not Required"
        case .pending: "Location May Still Be Simulated"
        case .clearing: "Clearing Simulated Location…"
        case .deviceConfirmed: "Device Confirmed Clear; Waiting for Real GPS"
        case .userConfirmed: "Confirmed by You"
        case .requiresRecovery: "Recovery Required"
        }
    }

    private var resultMessage: String? {
        switch diagnostics.state {
        case .notRun, .running: nil
        case .passed(let message), .failed(let message): message
        }
    }

    private var resultSymbol: String {
        switch diagnostics.state {
        case .passed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .notRun, .running: "circle"
        }
    }

    private var resultColor: Color {
        switch diagnostics.state {
        case .passed: .green
        case .failed: .red
        case .notRun, .running: .secondary
        }
    }

    private func healthRow(
        title: String,
        value: String,
        symbol: String,
        color: Color
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .foregroundStyle(color)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: l10n.text(title))
                        Text(verbatim: l10n.text(value))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .foregroundStyle(color)
                        .frame(width: 22)
                    Text(verbatim: l10n.text(title))
                    Spacer()
                    Text(verbatim: l10n.text(value))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: l10n.format("%@, %@", l10n.text(title), l10n.text(value))))
    }

    @MainActor
    private func runConnectionCheck() async {
        do {
            let pairingRecord = try await appModel.pairingService.pairingRecordData()
            diagnostics.run(
                pairingRecord: pairingRecord,
                sessionPhase: appModel.deviceSession.phase
            )
        } catch {
            diagnostics.run(pairingRecord: nil, sessionPhase: appModel.deviceSession.phase)
        }
    }

    private var diagnosticsText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let dateStyle = Date.FormatStyle(date: .numeric, time: .standard, locale: l10n.locale)
        let checked = diagnostics.lastChecked?.formatted(dateStyle) ?? l10n.text("Not run")
        let location = includesLocation
            ? "\((appModel.activeDisplayTarget ?? activeTarget).map(l10n.name) ?? l10n.text("None")) — \(renderedCoordinates)"
            : l10n.text("Excluded")
        let rows: [(String, String)] = [
            ("Generated", Date().formatted(dateStyle)),
            ("App", l10n.technical("\(version ?? l10n.text("Unknown")) (\(build ?? l10n.text("Unknown")))")),
            ("iOS", l10n.technical(UIDevice.current.systemVersion)),
            ("Pairing", l10n.text(pairingValue)),
            ("LocalDevVPN", l10n.text(localDevVPNValue)),
            ("Session", l10n.text(sessionValue)),
            ("Execution", l10n.text(executionValue)),
            ("Restoration", l10n.text(restorationValue)),
            ("Location", location),
            ("Last connection check", checked),
            ("Connection check result", diagnosticResultText),
            ("Appearance", l10n.text(appModel.appearance.title)),
            ("Map Style", l10n.text(appModel.mapDisplayStyle.title))
        ]
        return ([l10n.text("Roam Control Diagnostics")] + rows.map { "\(l10n.text($0.0)): \($0.1)" })
            .joined(separator: "\n")
    }

    private var diagnosticResultText: String {
        switch diagnostics.state {
        case .notRun: l10n.text("Not run")
        case .running: l10n.text("Running")
        case .passed(let message): l10n.format("Passed — %@", l10n.text(message))
        case .failed(let message): l10n.format("Failed — %@", l10n.text(message))
        }
    }

}

#Preview {
    NavigationStack {
        ConnectionHealthView()
            .environment(AppModel())
    }
}
