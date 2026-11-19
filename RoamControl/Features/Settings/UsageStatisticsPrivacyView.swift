import SwiftUI

struct UsageStatisticsPrivacyView: View {
    @Environment(\.appLocalization) private var l10n
    var body: some View {
        List {
            Section {
                Label {
                    Text("Roam Control sends only a small, fixed set of anonymous activity counts when sharing is enabled.")
                } icon: {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                }
            }

            Section("Shared") {
                privacyRow("Hashed random installation identifier", symbol: "number.circle")
                privacyRow("Approximate event time", symbol: "clock")
                privacyRow("App opened or returned to foreground", symbol: "app.badge.checkmark")
                privacyRow("App version and build", symbol: "number")
                privacyRow("Introduction completed", symbol: "sparkles")
                privacyRow("Pairing completed", symbol: "iphone.and.arrow.forward")
                privacyRow("Fixed, route or joystick session started", symbol: "figure.walk")
                privacyRow("Active location updated", symbol: "location.fill")
            }

            Section("Never Included in Statistics") {
                privacyRow("Coordinates or place names", symbol: "mappin.slash")
                privacyRow("Searches, favourites, history or routes", symbol: "magnifyingglass")
                privacyRow("Pairing records or PINs", symbol: "key.slash")
                privacyRow("Apple ID, device name or personal details", symbol: "person.crop.circle.badge.xmark")
                privacyRow("Diagnostic reports", symbol: "doc.text.magnifyingglass")
            }

            Section("Maps and Files") {
                Text("Place search, reverse lookup and Apple Maps directions use Apple's online services independently of the statistics switch. This build does not add a third-party search provider or an install-country counter.")
                Text("Backups and GPX files contain coordinates. Diagnostic reports stay on this iPhone until you review and share them; including location details is optional.")
            }

            Section("Storage and Control") {
                Text("A random identifier is created for this installation and irreversibly hashed before it is sent. It is used only to estimate activity from participating installations.")
                    .foregroundStyle(.secondary)

                Text("Turning sharing off immediately stops new reporting and removes the identifier from Roam Control. It cannot withdraw anonymous events already received by TelemetryDeck.")
                    .foregroundStyle(.secondary)

                Text("TelemetryDeck says it does not store IP addresses. Anonymous events may be retained for roughly 7–10 years, with no guaranteed exact deletion date.")
                    .foregroundStyle(.secondary)

                Text("Roam Control uses a narrow first-party sender instead of an analytics SDK, so extra device metadata cannot be added automatically.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text(verbatim: l10n.text("Anonymous Statistics")))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func privacyRow(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
    }
}

#Preview {
    NavigationStack {
        UsageStatisticsPrivacyView()
    }
}
