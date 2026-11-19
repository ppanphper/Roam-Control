import SwiftUI

struct SessionRecoveryView: View {
    @Environment(\.appLocalization) private var l10n
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let recovery: SessionRecoveryRecord
    let units: RouteUnits
    let isPaired: Bool
    let isResuming: Bool
    let isRestoring: Bool
    let errorMessage: String?
    let onResume: () -> Void
    let onRestore: () -> Void
    let onAlreadyRestored: () -> Void
    let onCancel: () -> Void

    var body: some View {
        GeometryReader { geometry in
            VStack {
                Spacer(minLength: 0)
                content
                    .movementPanel(maximumHeight: max(160, geometry.size.height - 56))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Interrupted Session", systemImage: "location.slash.circle.fill")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 8) {
                detail("Mode", value: Text(modeTitle), symbol: modeSymbol)
                detail("Last reported location", value: Text(verbatim: l10n.name(of: recovery.lastReportedLocation)), symbol: "mappin")
                if let destination = recovery.movement?.route?.destination ?? recovery.destination {
                    detail("Destination", value: Text(verbatim: l10n.name(of: destination)), symbol: "flag.checkered")
                }
                if let movement = recovery.movement {
                    detail("Target speed", value: Text(units.speed(movement.speedMetresPerSecond, locale: l10n.locale)), symbol: "speedometer")
                    if let route = movement.route {
                        let fraction = min(movement.distanceTravelled / max(route.distanceMetres, 1e-8), 1)
                        detail("Route progress", value: Text(fraction.formatted(.percent.precision(.fractionLength(0)).locale(l10n.locale))), symbol: "point.bottomleft.forward.to.point.topright.scurvepath")
                        if movement.isPaused {
                            Label("Paused", systemImage: "pause.circle").font(.subheadline)
                        }
                    }
                }
                detail("Last active", value: Text(recovery.updatedAt.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(l10n.locale))), symbol: "clock")
            }

            if let errorMessage {
                Label(l10n.text(errorMessage), systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isResuming || isRestoring {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(verbatim: l10n.text(isRestoring ? "Restoring real location…" : "Resuming session…"))
                }
                .font(.subheadline)
                .frame(minHeight: 44)
                MapPanelButton(title: "Cancel", symbol: "xmark", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
            } else {
                MapPanelButton(title: resumeTitle, symbol: modeSymbol, action: onResume)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isPaired)
                MapPanelButton(title: "Restore Real Location", symbol: "location.slash.fill", role: .destructive, action: onRestore)
                    .buttonStyle(.bordered)
                    .disabled(!isPaired)
                Button("My Real Location Is Already Back", action: onAlreadyRestored)
                    .font(.subheadline)
                    .frame(minHeight: 44, alignment: .leading)
                if !isPaired {
                    Label("Pair this iPhone before resuming or restoring the session.", systemImage: "iphone.and.arrow.forward")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeTitle: LocalizedStringKey {
        if recovery.movement?.isJoystick == true { return "Joystick" }
        if let mode = recovery.movement?.mode { return LocalizedStringKey(mode.title) }
        return recovery.isWalkingRoute ? "Walking" : "Fixed Location"
    }

    private var modeSymbol: String {
        if recovery.movement?.isJoystick == true { return "gamecontroller" }
        return recovery.movement?.mode.symbol ?? (recovery.isWalkingRoute ? "figure.walk" : "mappin")
    }

    private var resumeTitle: LocalizedStringKey {
        if recovery.movement?.isJoystick == true { return "Resume Joystick" }
        if recovery.movement?.route != nil || recovery.isWalkingRoute { return "Resume Route" }
        return "Resume Location"
    }

    private func detail(_ title: LocalizedStringKey, value: Text, symbol: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return Label {
            layout {
                Text(title).foregroundStyle(.secondary)
                value.fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}
