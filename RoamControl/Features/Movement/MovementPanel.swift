import CoreLocation
import SwiftUI
import UIKit

private struct MovementPanelLayout<Content: View, Footer: View>: View {
    let maximumHeight: CGFloat
    let content: Content
    let footer: Footer
    @State private var contentHeight: CGFloat?

    var body: some View {
        VStack(spacing: 6) {
            ScrollView {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                        contentHeight = height
                    }
            }
            .defaultScrollAnchor(.top)
            .scrollEdgeEffectHidden()
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight ?? maximumHeight, maximumHeight))

            footer
        }
        .padding(16)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 7)
    }
}

extension View {
    func movementPanel(maximumHeight: CGFloat) -> some View {
        MovementPanelLayout(maximumHeight: maximumHeight, content: self, footer: EmptyView())
    }

    func movementPanel<Footer: View>(maximumHeight: CGFloat, @ViewBuilder footer: () -> Footer) -> some View {
        MovementPanelLayout(maximumHeight: maximumHeight, content: self, footer: footer())
    }
}

enum MapAction: String, CaseIterable, Identifiable {
    case fixed, route, joystick
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .fixed: "Fixed Location"
        case .route: "Route"
        case .joystick: "Joystick"
        }
    }

    var symbol: String {
        switch self {
        case .fixed: "mappin"
        case .route: "point.topleft.down.to.point.bottomright.curvepath"
        case .joystick: "gamecontroller"
        }
    }
}

struct MapActionPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: MapAction

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            menu
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(MapAction.allCases) { action in
                        Button {
                            selection = action
                        } label: {
                            Label(action.title, systemImage: action.symbol)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minHeight: 44)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(action == selection ? .accentColor : .secondary)
                        .accessibilityAddTraits(action == selection ? .isSelected : [])
                    }
                }
                menu
            }
        }
    }

    private var menu: some View {
        MovementChoiceMenu(title: "Location mode", value: selection.title) {
            Picker("Location mode", selection: $selection) {
                ForEach(MapAction.allCases) { action in
                    Label(action.title, systemImage: action.symbol).tag(action)
                }
            }
        }
    }
}

struct MovementModePicker: View {
    @Binding var mode: MovementMode

    var body: some View {
        MovementChoiceMenu(title: "Travel mode", value: LocalizedStringKey(mode.title)) {
            Picker("Travel mode", selection: $mode) {
                ForEach(MovementMode.allCases) { item in
                    Label(LocalizedStringKey(item.title), systemImage: item.symbol).tag(item)
                }
            }
        }
    }
}

struct RouteSourcePicker: View {
    @Binding var source: RouteSource

    private var title: LocalizedStringKey {
        switch source {
        case .appleMaps: "Apple Maps"
        case .points: "Draw by Points"
        case .freehand: "Freehand"
        case .gpx: "GPX File"
        }
    }

    var body: some View {
        MovementChoiceMenu(title: "Route source", value: title) {
            Picker("Route source", selection: $source) {
                Label("Apple Maps", systemImage: "map").tag(RouteSource.appleMaps)
                Label("Draw by Points", systemImage: "point.3.connected.trianglepath.dotted").tag(RouteSource.points)
                Label("Freehand", systemImage: "pencil.tip").tag(RouteSource.freehand)
                Label("GPX File", systemImage: "doc").tag(RouteSource.gpx)
            }
        }
    }
}

private struct MovementChoiceMenu<Choices: View>: View {
    let title: LocalizedStringKey
    let value: LocalizedStringKey
    @ViewBuilder let choices: () -> Choices

    var body: some View {
        Menu(content: choices) {
            HStack(spacing: 8) {
                Text(value).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
    }
}

struct MovementSpeedButton: View {
    @Environment(\.appLocalization) private var l10n
    let speed: Double
    let units: RouteUnits
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            Label(units.speed(speed, locale: l10n.locale), systemImage: "speedometer")
                .monospacedDigit()
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Target speed")
        .accessibilityValue(units.speed(speed, locale: l10n.locale))
        .accessibilityHint("Opens speed settings")
    }
}

struct MovementSpeedEditor: View {
    @Environment(\.appLocalization) private var l10n
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    let mode: MovementMode
    let units: RouteUnits
    let speed: Double
    let onSave: (Double) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Target speed", text: $input, prompt: Text(units.speedSymbol))
                        .keyboardType(.decimalPad)
                        .monospacedDigit()
                        .accessibilityValue(input.isEmpty ? "" : "\(input) \(units.speedSymbol)")
                } footer: {
                    Text("Allowed range: \(units.speed(mode.speedRange.lowerBound, locale: l10n.locale))–\(units.speed(mode.speedRange.upperBound, locale: l10n.locale))")
                }
                Button("Reset to Default") {
                    input = editValue(mode.defaultSpeedMetresPerSecond)
                }
            }
            .navigationTitle(Text(verbatim: l10n.text("Target Speed")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let validSpeed else { return }
                        onSave(validSpeed)
                        dismiss()
                    }
                    .disabled(validSpeed == nil)
                }
            }
            .onAppear { input = editValue(speed) }
        }
    }

    private var validSpeed: Double? {
        let format = FloatingPointFormatStyle<Double>.number.locale(l10n.locale)
        guard let displayed = try? format.parseStrategy.parse(input), displayed.isFinite else { return nil }
        let minValue = units.displaySpeed(mode.speedRange.lowerBound)
        let maxValue = units.displaySpeed(mode.speedRange.upperBound)
        guard displayed >= (minValue * 100).rounded() / 100,
              displayed <= (maxValue * 100).rounded() / 100 else { return nil }
        return min(max(units.metresPerSecond(displayed), mode.speedRange.lowerBound), mode.speedRange.upperBound)
    }

    private func editValue(_ metresPerSecond: Double) -> String {
        units.displaySpeed(metresPerSecond).formatted(.number.locale(l10n.locale).precision(.fractionLength(0...2)))
    }
}

struct MapPlaceSummary: View {
    @Environment(\.appLocalization) private var l10n
    @State private var copiedLocation: LocationTarget?
    @State private var copyID: UUID?

    let location: LocationTarget
    let isFavourite: Bool
    let onFavourite: () -> Void
    let onClear: (() -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 4) { title; Spacer(minLength: 4); actions }
            VStack(alignment: .leading, spacing: 4) { title; actions }
        }
        .task(id: copyID) {
            guard copyID != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedLocation = nil
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: l10n.name(of: location)).font(.headline).lineLimit(2)
            if !location.subtitle.isEmpty {
                Text(verbatim: l10n.subtitle(of: location))
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button(action: onFavourite) {
                Image(systemName: isFavourite ? "heart.fill" : "heart")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(isFavourite ? "Remove favourite" : "Add favourite")
            Button(action: copyLocation) {
                Image(systemName: copiedLocation == location ? "checkmark" : "doc.on.doc")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(copiedLocation == location ? "Location copied" : "Copy location")
            ShareLink(item: "\(location.latitude), \(location.longitude)") {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Share coordinates")
            if let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Clear selection")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private func copyLocation() {
        let name = l10n.name(of: location).trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = l10n.subtitle(of: location).trimmingCharacters(in: .whitespacesAndNewlines)
        if subtitle.isEmpty || subtitle.caseInsensitiveCompare(name) == .orderedSame {
            UIPasteboard.general.string = name
        } else if subtitle.lowercased().hasPrefix(name.lowercased()) {
            UIPasteboard.general.string = subtitle
        } else {
            UIPasteboard.general.string = "\(name), \(subtitle)"
        }
        copiedLocation = location
        copyID = UUID()
    }
}

struct RouteInformation: View {
    @Environment(\.appLocalization) private var l10n
    let route: MovementRoute
    let destination: LocationTarget?
    let metres: Double
    let duration: TimeInterval
    let units: RouteUnits
    var isRemaining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(verbatim: isRemaining ? (route.nameKey.map(l10n.text) ?? route.name)
                    : "\(l10n.name(of: route.start)) \(l10n.language.isRightToLeft ? "←" : "→") \(l10n.name(of: destination ?? route.destination))")
                    .font(.headline)
                    .lineLimit(2)
            } icon: {
                Image(systemName: route.mode.symbol).foregroundStyle(Color.accentColor)
            }
            if duration.isFinite && duration >= 0 {
                let time = Duration.seconds(duration).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2).locale(l10n.locale))
                if isRemaining {
                    Text("Remaining: \(units.distance(metres, locale: l10n.locale)) · \(time)")
                } else {
                    Text("\(units.distance(metres, locale: l10n.locale)) · About \(time)")
                }
                if duration > 0 {
                    TimelineView(.everyMinute) { _ in
                        Text("Arrive at \(arrivalTime(after: duration, from: .now))")
                            .font(.subheadline)
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private func arrivalTime(after duration: TimeInterval, from now: Date) -> String {
        let arrival = now.addingTimeInterval(duration)
        let time = Date.FormatStyle().hour().minute().locale(l10n.locale)
        return arrival.formatted(Calendar.current.isDate(arrival, inSameDayAs: now)
                                 ? time : time.month(.abbreviated).day())
    }
}

struct MapPanelButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: LocalizedStringKey
    let symbol: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Group {
                if isEnabled {
                    Label(title, systemImage: symbol)
                } else {
                    Label(title, systemImage: symbol)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
            }
                .frame(maxWidth: .infinity, minHeight: 44)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
