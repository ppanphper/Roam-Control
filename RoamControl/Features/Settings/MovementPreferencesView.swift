import SwiftUI

struct MovementPreferencesView: View {
    @Environment(\.appLocalization) private var l10n
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var preferences = appModel.featurePreferences
        Form {
            Section("Units") {
                Picker("Distance and Speed", selection: $preferences.units) {
                    ForEach(RouteUnits.allCases) { unit in Text(LocalizedStringKey(unit.title)).tag(unit) }
                }
            }
            Section("Custom Speeds") {
                ForEach(MovementMode.allCases) { mode in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(LocalizedStringKey(mode.title))
                            Spacer()
                            Text(preferences.units.speed(preferences.speed(for: mode), locale: l10n.locale)).monospacedDigit()
                        }
                        Slider(value: Binding(get: { preferences.speed(for: mode) },
                                              set: { preferences.setSpeed($0, for: mode) }),
                               in: mode.speedRange, step: 0.1)
                            .accessibilityLabel(Text(LocalizedStringKey(mode.title)))
                            .accessibilityValue(preferences.units.speed(preferences.speed(for: mode), locale: l10n.locale))
                    }
                }
            }
            Section {
                Picker("Coordinate Compatibility", selection: $preferences.compatibility) {
                    ForEach(CoordinateCompatibility.allCases) { mode in
                        Text(LocalizedStringKey(mode.title)).tag(mode)
                    }
                }
                .disabled(!appModel.canChangeCoordinateCompatibility)
                if !appModel.canChangeCoordinateCompatibility {
                    Text("Stop and restore the current session before changing coordinate compatibility.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: { Text("Location Compatibility") } footer: {
                Text("Automatic corrects eligible map and search coordinates in mainland China only when sending them to the device. Manually entered coordinates and GPX remain unchanged. Force Correction treats eligible mainland coordinates as GCJ-02. Map markers keep the selected coordinates.")
            }
        }
        .navigationTitle(Text(verbatim: l10n.text("Movement & Coordinates")))
        .navigationBarTitleDisplayMode(.inline)
    }
}
