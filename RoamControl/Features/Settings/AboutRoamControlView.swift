import SwiftUI

struct AboutRoamControlView: View {
    @Environment(\.appLocalization) private var l10n
    var body: some View {
        List {
            appSummary
            quickStart

            Section("Choose a location") {
                guideRow(
                    "Search",
                    symbol: "magnifyingglass",
                    text: "Find a place by name or enter latitude and longitude. Choosing a result also clears the search ready for the next one."
                )
                guideRow(
                    "Tap the map",
                    symbol: "hand.tap",
                    text: "Drop a precise pin anywhere on the map. The close button on its card clears that pin."
                )
                guideRow(
                    "Favourite",
                    symbol: "heart",
                    text: "Save the selected place for quick use later. Favourites can be renamed or removed from the saved-locations screen."
                )
                guideRow(
                    "Favourites & history",
                    symbol: "list.bullet.rectangle",
                    text: "Open saved favourites and recently used locations. Swipe an item to remove it."
                )
                guideRow(
                    "Resume last location",
                    symbol: "arrow.clockwise",
                    text: "Quickly select your most recent location again. Use its close button if you no longer want the suggestion."
                )
            }

            Section("Map controls") {
                guideRow(
                    "Current location",
                    symbol: "location.fill",
                    text: "Fly back to this iPhone’s real location and return the map to north-up."
                )
                guideRow(
                    "Compass",
                    symbol: "safari",
                    text: "Appears when the map is rotated. It shows the map heading; tap it to face north again."
                )
                guideRow(
                    "Connection status",
                    symbol: "circle.fill",
                    text: "Shows whether Roam Control is ready, connecting or active. Tap it for pairing and connection details."
                )
                guideRow(
                    "Settings",
                    symbol: "gearshape.fill",
                    text: "Change appearance and map style, check the connection, manage pairing and view app information."
                )
            }

            Section("Location control") {
                guideRow(
                    "Start Location",
                    symbol: "location.fill",
                    text: "Start reporting the selected place as this iPhone’s location. LocalDevVPN must be connected."
                )
                guideRow(
                    "Update Location",
                    symbol: "arrow.triangle.2.circlepath",
                    text: "Move an active location session to a newly selected place without restarting the whole connection flow."
                )
                guideRow(
                    "Stop Location",
                    symbol: "location.slash.fill",
                    text: "End the active session and restore this iPhone’s real location."
                )
                guideRow(
                    "Mobile-data guidance",
                    symbol: "antenna.radiowaves.left.and.right",
                    text: "When using mobile data, temporarily turn it off when asked. Roam Control continues automatically once the local connection is available, and tells you when data can go back on."
                )
                guideRow(
                    "Interrupted-session recovery",
                    symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                    text: "If Roam Control did not receive a normal end signal, the next launch offers to resume, reconnect briefly to restore the real location, or confirm that it is already back."
                )
            }

            Section("Routes and Movement") {
                guideRow(
                    "Preview Route",
                    symbol: "figure.walk",
                    text: "Choose Walking, Cycling or Driving and preview a route from the current or active simulated point before starting."
                )
                guideRow(
                    "Custom Speeds",
                    symbol: "speedometer",
                    text: "Choose how quickly the simulated location moves along the route."
                )
                guideRow(
                    "Start Movement",
                    symbol: "figure.walk.motion",
                    text: "Move along the route at the selected speed. Background execution depends on iOS; foreground fallback requires keeping this app open."
                )
                guideRow(
                    "Pause or Resume",
                    symbol: "pause.fill",
                    text: "Hold the current point on the route, then continue from exactly where it paused."
                )
                guideRow(
                    "Reverse Route",
                    symbol: "arrow.uturn.backward",
                    text: "Reverse the prepared route or return after arrival using the same movement mode."
                )
                guideRow(
                    "New Location",
                    symbol: "mappin.and.ellipse",
                    text: "Keep the active session and return to the map so you can choose another destination."
                )
                guideRow(
                    "Stop & Restore",
                    symbol: "stop.fill",
                    text: "Stop walking, clear the route and restore the real location. A confirmation helps prevent accidental stops."
                )
            }

            Section("Drawing, GPX and Joystick") {
                guideRow("Manual Route", symbol: "point.topleft.down.curvedto.point.bottomright.up",
                         text: "Add route points on the map or draw a stroke. Use Undo to remove the last point or stroke. Two fingers move the map while drawing.")
                guideRow("GPX", symbol: "doc",
                         text: "Import one GPX track or route, preview it, then start movement. Export a prepared route to save or share it. Separate track segments are not joined automatically.")
                guideRow("Joystick", symbol: "gamecontroller",
                         text: "Push to move in a direction. The distance from the centre controls speed. Release to hold position; Stop & Restore ends the location session.")
                guideRow("Follow Location", symbol: "location.viewfinder",
                         text: "Follow the simulated point while moving. Dragging the map pauses follow; the location button resumes it.")
                guideRow("Backup & Restore", symbol: "externaldrive",
                         text: "Back up favourites, history and supported preferences before moving to a new installation. Pairing and active sessions are excluded.")
            }

            Section("Setup & support") {
                guideRow(
                    "Pairing & Connection",
                    symbol: "iphone.and.arrow.forward",
                    text: "Pair this iPhone once so Roam Control can identify it through LocalDevVPN."
                )
                guideRow(
                    "Connection Health",
                    symbol: "stethoscope",
                    text: "Check pairing and the local connection without changing your location. You can also share a readable diagnostics report."
                )
                guideRow(
                    "Replay Introduction",
                    symbol: "sparkles",
                    text: "View onboarding again without deleting your pairing, favourites, history or preferences."
                )
                guideRow(
                    "Reset Roam Control",
                    symbol: "arrow.counterclockwise",
                    text: "Erase the pairing record and all saved app choices, then return to onboarding. LocalDevVPN itself is not changed."
                )
            }
            Section("Feedback") {
                Link("Open Fork Issues", destination: URL(string: "https://github.com/ppanphper/Roam-Control/issues")!)
            }
        }
        .navigationTitle(Text(verbatim: l10n.text("About Roam Control")))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appSummary: some View {
        Section {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 74, height: 74)

                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 5) {
                    Text("Roam Control")
                        .font(.title2.bold())

                    Text("Choose, test and move this iPhone’s reported location from one clean map.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
        }
    }

    private var quickStart: some View {
        Section {
            stepRow(1, "Pair this iPhone once.")
            stepRow(2, "Connect LocalDevVPN.")
            stepRow(3, "Search, choose or drop a location.")
            stepRow(4, "Start a fixed location, route or joystick session.")
        } header: {
            Text("How it works")
        } footer: {
            Text("Roam Control is intended for location-based app development and testing on your own device.")
        }
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.blue, in: Circle())

            Text(verbatim: l10n.text(text))
                .font(.subheadline)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: l10n.format("Step %lld. %@", Int64(number), l10n.text(text))))
    }

    private func guideRow(_ title: String, symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 26, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: l10n.text(title))
                    .font(.subheadline.weight(.semibold))

                Text(verbatim: l10n.text(text))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: l10n.format("%@. %@", l10n.text(title), l10n.text(text))))
    }
}

#Preview {
    NavigationStack {
        AboutRoamControlView()
    }
}
