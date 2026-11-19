import MapKit
import SwiftUI

struct HomeView: View {
    @Environment(\.appLocalization) private var l10n
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var mapModel = MapViewModel()
    @State private var planner = RoutePlanner()
    @State private var movement = MovementController()
    @State private var mapAction: MapAction = .fixed
    @State private var routeSource: RouteSource = .appleMaps
    @State private var draft = RouteDraft()
    @State private var routePreview: MovementRoute?
    @State private var displayedRoutePolyline: (id: UUID, polyline: MKPolyline)?
    @State private var routeError: String?
    @State private var planningTask: Task<Void, Never>?
    @State private var isRedirecting = false
    @State private var wasMovingBeforeRedirect = false
    @State private var isDrawingStroke = false
    @State private var speedEditorMode: MovementMode?
    @State private var documentPickerMode: GPXDocumentPicker.Mode?
    @State private var isFollowing = false
    @GestureState private var isChangingMap = false
    @State private var visibleMapCamera: MapCamera?
    @State private var mapPositionInterpolator = MapPositionInterpolator(duration: MovementPhysics.tickInterval)
    @State private var initialMovementFollowDistance: CLLocationDistance?
    @State private var isConfirmingStop = false
    @State private var isShowingDeviceSetup: Bool
    @State private var isShowingSettings: Bool
    @State private var isShowingSavedPlaces = false
    @State private var isShowingUpdates = false
    @State private var isPanelCollapsed = false
    @State private var shouldRefreshRealLocationWhenActive = false
    @State private var isResumingRecovery = false
    @State private var recoveryError: String?
    @State private var recoveryTask: Task<Void, Never>?
    @State private var recoveryGeneration: UUID?
    @FocusState private var isSearchFocused: Bool

    init(showDeviceSetupInitially: Bool = false, showSettingsInitially: Bool = false) {
        _isShowingDeviceSetup = State(initialValue: showDeviceSetupInitially)
        _isShowingSettings = State(initialValue: showSettingsInitially)
    }

    var body: some View {
        ZStack {
            mapSurface
                .ignoresSafeArea()

            GeometryReader { geometry in
                VStack(spacing: 8) {
                    header
                    Spacer(minLength: 4)
                    mapTools
                    if !isSearchFocused || isLocationSessionActive {
                        bottomPanel(maximumHeight: max(100, geometry.size.height * 0.54 - 32))
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .accessibilityHidden(appModel.interruptedSession != nil || appModel.deviceSession.mobileDataGuidance != nil)

            if let guidance = appModel.deviceSession.mobileDataGuidance {
                Color.black.opacity(0.34)
                    .ignoresSafeArea()

                VStack {
                    Spacer()
                    MobileDataGuidanceView(
                        guidance: guidance,
                        onOpenLocalDevVPN: appModel.deviceSession.openLocalDevVPN,
                        onRetry: appModel.deviceSession.retryConnection,
                        onUseMobileData: appModel.deviceSession.useMobileDataGuidance,
                        onMobileDataOff: appModel.deviceSession.confirmMobileDataIsOff,
                        onCancel: stopCurrentSession,
                        onDone: {
                            if appModel.isRestoringInterruptedSession {
                                appModel.completeInterruptedSessionRestorationAfterMobileData()
                            } else {
                                appModel.deviceSession.dismissMobileDataGuidance()
                            }
                        }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                .zIndex(10)
            }

            if
                let recovery = appModel.interruptedSession,
                appModel.deviceSession.mobileDataGuidance == nil
            {
                Color.black.opacity(0.34)
                    .ignoresSafeArea()

                SessionRecoveryView(
                        recovery: recovery,
                        units: units,
                        isPaired: isPaired,
                        isResuming: isResumingRecovery,
                        isRestoring: appModel.isRestoringInterruptedSession,
                        errorMessage: recoveryError ?? appModel.interruptedSessionError,
                        onResume: {
                            resumeInterruptedSession(recovery)
                        },
                        onRestore: {
                            recoveryError = nil
                            movement.reset()
                            planner.clear()
                            Task { await appModel.restoreRealLocationFromInterruptedSession() }
                        },
                        onAlreadyRestored: {
                            dismissInterruptedSessionRecovery()
                        },
                        onCancel: {
                            if appModel.isRestoringInterruptedSession {
                                appModel.cancelInterruptedSessionRestoration()
                            } else {
                                cancelRecoveryPreparation()
                            }
                        }
                    )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                .zIndex(9)
            }
        }
        .task {
            await appModel.restorePairingStatus()
            if let interruptedLocation = appModel.interruptedSession?.lastReportedLocation {
                mapModel.center(on: interruptedLocation)
            } else if let lastLocation = appModel.resumeLocation {
                mapModel.center(on: lastLocation)
            }
            mapModel.prepareCurrentLocation(
                recenter: appModel.resumeLocation == nil && appModel.interruptedSession == nil
            )
            if isShowingDeviceSetup {
                appModel.deviceSetupWasPresented()
            }
        }
        .onChange(of: appModel.deviceSession.phase, handleDevicePhaseChange)
        .onChange(of: mapModel.selectedLocation?.id) { _, _ in
            if !showsMovementControls && (routeSource == .appleMaps || routeSource == .points) { clearPreview() }
            if mapModel.selectedLocation != nil { isPanelCollapsed = false }
        }
        .onChange(of: mapAction) { _, _ in
            isPanelCollapsed = false
            if !isShowingImportedRoute { clearRouteEditor() }
        }
        .onChange(of: routeSource) { _, _ in
            if !isShowingImportedRoute { clearRouteEditor() }
        }
        .onChange(of: appModel.pendingGPXImportURL, initial: true) { _, _ in
            openPendingGPXIfReady()
        }
        .onChange(of: canOpenPendingGPX) { _, _ in
            openPendingGPXIfReady()
        }
        .onChange(of: preferences.movementMode) { _, newMode in
            if let routePreview, routeSource != .appleMaps {
                self.routePreview = try? routePreview.replacingMode(newMode)
            } else {
                clearPreview()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                movement.setJoystick(x: 0, y: 0)
                return
            }
            refreshRealLocationIfNeeded()
        }
        .onChange(of: displayedRoute?.id, initial: true) { _, _ in
            displayedRoutePolyline = displayedRoute.map { (id: $0.id, polyline: $0.polyline) }
        }
        .onChange(of: mapPositionSample, initial: true) { _, sample in
            mapPositionInterpolator.accept(sample.coordinate, at: .now,
                                           interpolate: sample.interpolates && initialMovementFollowDistance == nil)
        }
        .onChange(of: movement.phase) { oldPhase, phase in
            switch phase {
            case .moving, .paused, .arrived:
                if let distance = initialMovementFollowDistance {
                    mapPositionInterpolator.accept(mapPositionSample.coordinate, at: .now, interpolate: false)
                    initialMovementFollowDistance = nil
                    followCurrentLocation(initialDistance: distance)
                }
            case .failed, .stopping: initialMovementFollowDistance = nil
            case .idle:
                if oldPhase == .preparing { initialMovementFollowDistance = nil }
            case .preparing: break
            }
        }
        .onChange(of: isChangingMap) { _, isChanging in
            if !isChanging { followCurrentLocation() }
        }
        .sheet(isPresented: $isShowingDeviceSetup) { PairingSetupView().environment(appModel) }
        .sheet(isPresented: $isShowingSettings) { SettingsView().environment(appModel) }
        .sheet(isPresented: $isShowingUpdates) {
            NavigationStack {
                UpdatesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingUpdates = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $isShowingSavedPlaces) {
            SavedPlacesView(
                favourites: appModel.favouriteLocations,
                history: appModel.locationHistory,
                isFavourite: appModel.isFavourite,
                onSelect: { target in
                    guard canSelectLocation else { return }
                    isFollowing = false
                    mapModel.show(target)
                },
                onToggleFavourite: appModel.toggleFavourite,
                onDeleteFavourite: appModel.removeFavourite,
                onMoveFavourites: appModel.moveFavourites,
                onRenameFavourite: appModel.renameFavourite,
                onDeleteHistory: appModel.removeFromHistory,
                onClearFavourites: appModel.clearFavouriteLocations,
                onClearHistory: appModel.clearLocationHistory
            )
        }
        .sheet(item: $speedEditorMode) { mode in
            MovementSpeedEditor(mode: mode, units: units, speed: speedForEditor(mode)) { speed in
                preferences.setSpeed(speed, for: mode)
                if showsMovementControls && movement.mode == mode {
                    movement.speedMetresPerSecond = speed
                }
            }
        }
        .sheet(item: $documentPickerMode) { mode in
            GPXDocumentPicker(mode: mode) { url in
                if case .open = mode { importGPX(from: url) }
                documentPickerMode = nil
            } onCancel: {
                documentPickerMode = nil
            }
        }
    }

    private var displayedRoute: MovementRoute? {
        routePreview ?? (isRedirecting ? nil : movement.route)
    }

    private var mapSurface: some View {
        let route = displayedRoute
        // Reuse the rendered geometry between frames. Never draw a prior route while the new one is prepared.
        let routePolyline = displayedRoutePolyline.flatMap { $0.id == route?.id ? $0.polyline : nil }
        let endpoints = route.map { (start: $0.start.coordinate, end: $0.destination.coordinate) }
        // Drafts and their point annotations are only visible while the movement timeline is paused.
        let showsDraft = isDrafting
        let draftGeometry = showsDraft ? draftCoordinates : []
        let polyline = if route == nil && draftGeometry.count > 1 {
            MKPolyline(coordinates: draftGeometry.map(\.coordinate), count: draftGeometry.count)
        } else { routePolyline }
        let animatesPosition = !showsDraft && mapPositionSample.interpolates && mapPositionInterpolator.isInterpolating
        return TimelineView(.animation(paused: !animatesPosition)) { _ in
            let coordinate = presentedMapPosition
            mapSurface(at: coordinate, endpoints: endpoints, polyline: polyline,
                       showsDraft: showsDraft, draftStart: draftGeometry.first)
                .onChange(of: coordinate) { _, position in
                    if let position { followMapPosition(position) }
                    mapPositionInterpolator.finishIfReached(position)
                }
        }
    }

    private func mapSurface(at displayCoordinate: RouteCoordinate?,
                            endpoints: (start: CLLocationCoordinate2D, end: CLLocationCoordinate2D)?,
                            polyline: MKPolyline?, showsDraft: Bool, draftStart: RouteCoordinate?) -> some View {
        MapReader { proxy in
            Map(position: $mapModel.cameraPosition) {
                if let polyline {
                    MapPolyline(polyline).stroke(Color.accentColor, lineWidth: 5)
                }
                if let endpoints {
                    Marker("Route Start", systemImage: "circle.circle", coordinate: endpoints.start).tint(.green)
                    Marker("Destination", systemImage: "flag.checkered", coordinate: endpoints.end).tint(.blue)
                }
                if showsDraft {
                    if routeSource == .points {
                        if let start = draft.pointStart ?? defaultPointStart {
                            Marker("Route Start", systemImage: "circle.circle", coordinate: start.coordinate).tint(.green)
                        }
                        if let destination = pointDraftDestination {
                            Marker("Destination", systemImage: "flag.checkered", coordinate: destination.coordinate).tint(.blue)
                        }
                        ForEach(draft.points.indices, id: \.self) { index in
                            Annotation(l10n.format("Point %lld", Int64(index + 1)), coordinate: draft.points[index].coordinate) {
                                Text((index + 1).formatted())
                                    .font(.caption.weight(.bold)).monospacedDigit()
                                    .frame(minWidth: 26, minHeight: 26)
                                    .padding(.horizontal, 3)
                                    .foregroundStyle(.white)
                                    .background(Color.accentColor, in: Capsule())
                            }
                        }
                    } else if let start = draftStart {
                        Marker("Route Start", systemImage: "circle.circle", coordinate: start.coordinate).tint(.green)
                    }
                }
                if !isLocationSessionActive && !isStopping && appModel.interruptedSession == nil { UserAnnotation() }
                if let target = mapModel.selectedLocation, routePreview == nil, canSelectLocation, !isDrafting {
                    Marker(l10n.name(of: target), coordinate: target.coordinate).tint(.blue)
                }
                if let displayCoordinate {
                    Annotation("Simulated Location", coordinate: displayCoordinate.coordinate) {
                        Image(systemName: showsMovementControls ? movement.mode.symbol : "location.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.green, in: Circle())
                            .padding(4)
                            .background(.regularMaterial, in: Circle())
                    }
                }
            }
            .roamControlMapStyle(appModel.mapDisplayStyle)
            .mapControls { MapScaleView() }
            .onMapCameraChange(frequency: .continuous) { context in visibleMapCamera = context.camera }
            .gesture(MapSingleFingerPan(enabled: isFreehandDrafting || (isFollowing && !isDrafting),
                                        claimsMapPan: isFreehandDrafting) { state, point in
                if isFreehandDrafting {
                    drawFreehand(state, at: point, using: proxy)
                } else if state == .began {
                    isFollowing = false
                }
            })
            .simultaneousGesture(MagnifyGesture()
                .updating($isChangingMap) { _, changing, _ in changing = true }
                .onChanged { _ in
                    if isDrawingStroke {
                        draft.cancelStroke()
                        isDrawingStroke = false
                    }
                })
            .simultaneousGesture(SpatialTapGesture().onEnded { event in
                if isSearchFocused {
                    isSearchFocused = false
                    return
                }
                guard let coordinate = proxy.convert(event.location, from: .local) else { return }
                if isDrafting && routeSource == .points {
                    draft.addPoint(coordinate)
                    routeError = nil
                } else if canSelectLocation {
                    isFollowing = false
                    Task { await mapModel.selectDroppedPin(at: coordinate) }
                }
            })
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            MapSearchBar(
                query: Binding(
                    get: { mapModel.searchQuery },
                    set: { mapModel.updateSearchQuery($0) }
                ),
                isFocused: $isSearchFocused,
                isSearching: mapModel.isSearching,
                onSubmit: {
                    Task { await mapModel.search() }
                },
                onClear: mapModel.clearSearch
            )
            .disabled(!canSelectLocation)

            if preferences.automaticUpdateChecks, !isSearchFocused, !isLocationSessionActive, !isBusy,
               appModel.interruptedSession == nil, appModel.deviceSession.mobileDataGuidance == nil,
               let release = appModel.releaseUpdates.automaticUpdateNotice {
                UpdateNoticeView(release: release, onOpenUpdates: { isShowingUpdates = true },
                                 onDismiss: { appModel.releaseUpdates.dismiss(release) })
            }

            if mapModel.isShowingSuggestions && canSelectLocation {
                SearchSuggestionsView(
                    suggestions: mapModel.searchSuggestions,
                    onSelect: { suggestion in
                        isSearchFocused = false
                        Task { await mapModel.selectSuggestion(suggestion) }
                    }
                )
            }

            if dynamicTypeSize.isAccessibilitySize {
                HStack { Spacer(minLength: 0); shortcuts }
                if !needsPairingPrompt { connectionControl.frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                HStack {
                    connectionControl
                    Spacer(minLength: 0)
                    shortcuts
                }
            }

            if needsPairingPrompt && !isSearchFocused { pairingPrompt }
        }
    }

    private var connectionControl: some View {
        Button {
            isShowingDeviceSetup = true
        } label: {
            ConnectionBadge(state: appModel.connectionState)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .accessibilityHint("Opens device pairing setup")
    }

    private var shortcuts: some View {
        HStack(spacing: 10) {
            Button {
                isShowingSavedPlaces = true
            } label: {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Favourites and history")

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    private var pairingPrompt: some View {
        Button {
            isShowingDeviceSetup = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Pair this iPhone")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text("Required before location control")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Image(systemName: "chevron.forward")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(minHeight: 44)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    private var mapTools: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                if shouldShowMapCompass {
                    Button(action: resetMapHeading) {
                        CompassRoseDial()
                            .rotationEffect(.degrees(-normalisedMapHeading))
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Return map to north")
                }
                if followingLocation != nil {
                    mapTool(isFollowing ? "location.fill" : "location", title: "Follow simulated location") {
                        isFollowing.toggle()
                        if isFollowing { followCurrentLocation(animate: true) }
                    }
                    .accessibilityAddTraits(isFollowing ? .isSelected : [])
                } else if !isBusy {
                    Button { showCurrentLocationNorthUp() } label: {
                        Group {
                            if mapModel.isFindingRealLocation {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "location.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(.blue)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(mapModel.isFindingRealLocation)
                    .accessibilityLabel("Show my current location")
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }

    private func mapTool(_ symbol: String, title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44).background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private func bottomPanel(maximumHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isPanelCollapsed && canCollapsePanel {
                HStack(alignment: .center, spacing: 4) {
                    collapsedPanelSummary
                    Spacer(minLength: 0)
                    collapseButton
                }
            } else if showsMovementControls {
                HStack(alignment: .top, spacing: 4) {
                    movementStatus
                    Spacer(minLength: 0)
                    if canCollapsePanel { collapseButton }
                }
                movementControls
            } else if isStopping {
                Label("Restoring real location…", systemImage: "location.slash")
                    .frame(minHeight: 44)
            } else {
                if !isRedirecting && !isBusy && routePreview == nil {
                    HStack(alignment: .center, spacing: 4) {
                        MapActionPicker(selection: $mapAction)
                            .disabled(restorationNeedsAttention)
                        Spacer(minLength: 0)
                        collapseButton
                    }
                } else if canCollapsePanel {
                    collapseButton.frame(maxWidth: .infinity, alignment: .trailing)
                }
                switch mapAction {
                case .fixed: fixedControls
                case .route: routeEditor
                case .joystick: joystickReadyControls
                }
            }
            if appModel.pendingGPXImportURL != nil && !canOpenPendingGPX {
                Label("Stop and restore the current location before opening this GPX file.", systemImage: "doc.badge.clock")
                    .font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = routeError ?? mapModel.errorMessage {
                Label(l10n.text(error), systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            sessionNotice
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .movementPanel(maximumHeight: maximumHeight) {
            if isRedirecting {
                MapPanelButton(title: "Cancel Redirect", symbol: "xmark", action: cancelRedirect)
                    .buttonStyle(.bordered)
            }
            if isLocationSessionActive {
                if showsMovementControls { pauseButton }
                stopButton
            } else if !isStopping && (isBusy || movement.phase == .preparing) {
                MapPanelButton(title: "Cancel", symbol: "xmark", role: .cancel, action: stopCurrentSession)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var canCollapsePanel: Bool { !isBusy && !isRedirecting }

    private var collapseButton: some View {
        Button {
            isPanelCollapsed.toggle()
        } label: {
            Image(systemName: isPanelCollapsed ? "chevron.up" : "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPanelCollapsed ? "Expand location controls" : "Collapse location controls")
    }

    @ViewBuilder
    private var collapsedPanelSummary: some View {
        if showsMovementControls {
            movementStatus
        } else if let routePreview {
            Label(l10n.name(of: routePreview.destination), systemImage: routePreview.mode.symbol)
                .font(.subheadline.weight(.semibold))
        } else if let location = mapModel.selectedLocation ?? followingLocation {
            Label(l10n.name(of: location), systemImage: mapAction.symbol)
                .font(.subheadline.weight(.semibold))
        } else {
            Label(mapAction.title, systemImage: mapAction.symbol)
                .font(.subheadline.weight(.semibold))
        }
    }

    @ViewBuilder
    private var fixedControls: some View {
        let selection = mapModel.selectedLocation ?? (isLocationSessionActive ? appModel.activeDisplayTarget : nil)
        if let target = selection {
            MapPlaceSummary(location: target, isFavourite: appModel.isFavourite(target), onFavourite: {
                appModel.toggleFavourite(target)
            }, onClear: isBusy ? nil : { mapModel.clearSelectedLocation() })
            if isBusy {
                connectionProgress
            } else {
                let isCurrent = isLocationSessionActive && appModel.activeDisplayTarget?.id == target.id
                if !isCurrent {
                    MapPanelButton(title: isLocationSessionActive ? "Update Location" : "Start Location", symbol: "location.fill") {
                        movement.reset()
                        isFollowing = true
                        Task { await appModel.startLocationSession(at: target) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isPaired || restorationNeedsAttention)
                }
            }
        } else if isBusy {
            connectionProgress
        } else if let target = appModel.resumeLocation {
            MapPlaceSummary(location: target, isFavourite: appModel.isFavourite(target), onFavourite: {
                appModel.toggleFavourite(target)
            }, onClear: {
                appModel.dismissResumeLocation()
                mapModel.prepareCurrentLocation(recenter: true)
            })
            MapPanelButton(title: "Resume Location", symbol: "arrow.clockwise") {
                mapModel.show(target)
                isFollowing = true
                Task { await appModel.startLocationSession(at: target) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isPaired || restorationNeedsAttention)
        } else {
            Label("Search or tap the map to choose a location", systemImage: "hand.tap")
                .foregroundStyle(Color(uiColor: .secondaryLabel))
        }
    }

    @ViewBuilder
    private var routeEditor: some View {
        if let routePreview {
            if routePreview.source == .gpx {
                MovementModePicker(mode: modeBinding)
            }
            RouteInformation(route: routePreview, destination: routeSource == .appleMaps || routeSource == .points ? mapModel.selectedLocation : nil,
                             metres: routePreview.distanceMetres, duration: routePreview.distanceMetres / preferredSpeed,
                             units: units)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { speedButton(mode: routePreview.mode); exportButton(routePreview) }
                VStack(alignment: .leading, spacing: 4) { speedButton(mode: routePreview.mode); exportButton(routePreview) }
            }
            MapPanelButton(title: "Start Route", symbol: "play.fill") { start(routePreview) }
                .buttonStyle(.borderedProminent)
                .disabled(!isPaired || isBusy || restorationNeedsAttention)
            MapPanelButton(title: "Edit Route", symbol: "pencil") { clearPreview() }
                .buttonStyle(.bordered)
        } else {
            if dynamicTypeSize.isAccessibilitySize {
                routeChoicesStacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        MovementModePicker(mode: modeBinding).fixedSize(horizontal: true, vertical: false)
                        RouteSourcePicker(source: $routeSource).fixedSize(horizontal: true, vertical: false)
                    }
                    routeChoicesStacked
                }
            }
            switch routeSource {
            case .appleMaps:
                if let destination = mapModel.selectedLocation, !isRedirecting || destination.id != appModel.activeDisplayTarget?.id {
                    MapPlaceSummary(location: destination, isFavourite: appModel.isFavourite(destination), onFavourite: {
                        appModel.toggleFavourite(destination)
                    }, onClear: { mapModel.clearSelectedLocation() })
                    if planner.isLoading {
                        HStack { ProgressView(); Text("Planning Route…") }.frame(minHeight: 44)
                    } else {
                        MapPanelButton(title: "Preview Route", symbol: "map") { previewDirections(to: destination) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Label("Choose a destination on the map", systemImage: "mappin")
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
            case .points, .freehand:
                draftControls
            case .gpx:
                MapPanelButton(title: "Import GPX", symbol: "square.and.arrow.down") { documentPickerMode = .open }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var routeChoicesStacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            MovementModePicker(mode: modeBinding)
            RouteSourcePicker(source: $routeSource)
        }
    }

    private var draftControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let destination = pointDraftDestination {
                Label(l10n.name(of: destination), systemImage: "flag.checkered")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if draft.coordinates.isEmpty {
                Label(routeSource == .points ? "Tap the map to add route points" : "Draw a route with one finger",
                      systemImage: routeSource == .points ? "hand.tap" : "pencil.tip")
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            if routeSource == .points, draft.points.isEmpty, draft.pointStart == nil,
               defaultPointStart == nil, let start = routeStart,
               let represented = CoordinateTransform.sourceCoordinate(forDeviceCoordinate: RouteCoordinate(start.coordinate),
                                                                      origin: RouteSource.points.targetOrigin,
                                                                      compatibility: appModel.sessionCoordinateCompatibility) {
                MapPanelButton(title: "Use Current Location as Start", symbol: "location") {
                    draft.setPointStart(represented)
                    mapModel.center(on: represented.coordinate, keeping: visibleMapCamera)
                }
                .buttonStyle(.bordered)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { draftUndo; draftClear }
                VStack(alignment: .leading, spacing: 4) { draftUndo; draftClear }
            }
            MapPanelButton(title: "Preview Route", symbol: "map", action: previewDraft)
                .buttonStyle(.borderedProminent)
                .disabled(draftCoordinates.count < 2 || isDrawingStroke)
        }
    }

    private var draftUndo: some View {
        MapPanelButton(title: "Undo", symbol: "arrow.uturn.backward") {
            draft.undo(source: routeSource)
            routeError = nil
        }
        .buttonStyle(.bordered)
        .disabled(!draft.canUndo || isDrawingStroke)
    }

    private var draftClear: some View {
        MapPanelButton(title: "Clear Route", symbol: "xmark") {
            draft = RouteDraft()
            if routeSource == .points { mapModel.clearSelectedLocation() }
            routeError = nil
        }
        .buttonStyle(.bordered)
        .disabled((!draft.canUndo && pointDraftDestination == nil) || isDrawingStroke)
    }

    private var joystickReadyControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let target = mapModel.selectedLocation ?? routeStart {
                Text(verbatim: l10n.name(of: target)).font(.headline)
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading) { MovementModePicker(mode: modeBinding); speedButton(mode: preferences.movementMode) }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack { MovementModePicker(mode: modeBinding).fixedSize(horizontal: true, vertical: false); speedButton(mode: preferences.movementMode) }
                        VStack(alignment: .leading) { MovementModePicker(mode: modeBinding); speedButton(mode: preferences.movementMode) }
                    }
                }
                MapPanelButton(title: "Start Joystick", symbol: "gamecontroller") {
                    movement.mode = preferences.movementMode
                    movement.speedMetresPerSecond = preferredSpeed
                    beginMovementFollowing(mode: movement.mode, isJoystick: true)
                    Task { await movement.startJoystick(at: target, using: appModel) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isPaired || isBusy || restorationNeedsAttention)
            } else {
                Label("Choose a joystick start location", systemImage: "mappin")
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
        }
    }

    private var movementControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if movement.isJoystick && movement.phase == .moving {
                JoystickPad(onDirection: movement.setJoystick)
            } else if let route = movement.route {
                RouteInformation(route: route, destination: nil, metres: movement.remainingDistance,
                                 duration: movement.remainingDuration, units: units, isRemaining: true)
                ProgressView(value: movement.progress)
                    .accessibilityLabel("Route progress")
            }
            if movement.phase == .moving || movement.phase == .paused || movement.phase == .arrived {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { movementSpeed; if !movement.isJoystick { exportActiveRoute } }
                    VStack(alignment: .leading, spacing: 4) { movementSpeed; if !movement.isJoystick { exportActiveRoute } }
                }
            }
            if isLocationSessionActive && !movement.isJoystick {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 4) { reverseButton; redirectButton }
                } else {
                    HStack(spacing: 8) { reverseButton; redirectButton }
                }
            }
            if canContinueAsFixedLocation {
                MapPanelButton(title: "New Location", symbol: "mappin.and.ellipse", action: continueAsFixedLocation)
                    .buttonStyle(.bordered)
            }
            if movement.phase == .stopping {
                Label("Restoring real location…", systemImage: "location.slash")
            } else if case .failed = movement.phase, !isLocationSessionActive && !restorationNeedsAttention {
                if movement.currentCoordinate != nil, movement.route != nil || movement.isJoystick {
                    MapPanelButton(title: movement.isJoystick ? "Resume Joystick" : "Resume Route",
                                   symbol: "play.fill") {
                        beginMovementFollowing(mode: movement.mode, isJoystick: movement.isJoystick)
                        Task { await movement.start(using: appModel) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isPaired || isBusy)
                }
                MapPanelButton(title: "Done", symbol: "checkmark") { movement.reset() }
                    .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var movementStatus: some View {
        switch movement.phase {
        case .preparing: connectionProgress
        case .moving:
            let speed = units.speed(movement.currentSpeedMetresPerSecond, locale: l10n.locale)
            let title = movement.isJoystick ? "Joystick" : movement.mode.title
            Label {
                Text("\(Text(LocalizedStringKey(title))) · \(speed)").monospacedDigit()
            } icon: {
                Image(systemName: movement.isJoystick ? "gamecontroller" : movement.mode.symbol)
            }
            .font(.headline)
            .accessibilityLabel(Text(LocalizedStringKey(title)))
            .accessibilityValue(speed)
        case .paused: Label("Paused", systemImage: "pause.circle").font(.headline)
        case .arrived: Label("Arrived", systemImage: "checkmark.circle").font(.headline)
        case .failed(let message):
            Label(l10n.text(message), systemImage: "exclamationmark.circle")
                .font(.subheadline).foregroundStyle(.red)
        case .idle, .stopping: EmptyView()
        }
    }

    private var movementSpeed: some View { speedButton(mode: movement.mode) }

    @ViewBuilder
    private var exportActiveRoute: some View {
        if let route = movement.route { exportButton(route) }
    }

    @ViewBuilder
    private var pauseButton: some View {
        if movement.phase == .moving || movement.phase == .paused {
            MapPanelButton(title: movement.phase == .paused ? "Continue" : "Pause",
                           symbol: movement.phase == .paused ? "play.fill" : "pause.fill", action: movement.togglePause)
                .buttonStyle(.borderedProminent)
        }
    }

    private var reverseButton: some View {
        MapPanelButton(title: "Reverse", symbol: "arrow.left.arrow.right") {
            do { try movement.reverseRoute(); routeError = nil }
            catch { routeError = error.localizedDescription }
        }
        .buttonStyle(.bordered)
    }

    private var redirectButton: some View {
        MapPanelButton(title: "Redirect", symbol: "arrow.turn.up.right", action: beginRedirect)
            .buttonStyle(.bordered)
    }

    private func speedButton(mode: MovementMode) -> some View {
        MovementSpeedButton(speed: speedForEditor(mode), units: units) { speedEditorMode = mode }
    }

    private var stopButton: some View {
        MapPanelButton(title: "Stop & Restore", symbol: "stop.circle.fill", role: .destructive) {
            isConfirmingStop = true
        }
        .buttonStyle(.bordered)
        .confirmationDialog("Stop and restore real location", isPresented: $isConfirmingStop, titleVisibility: .visible) {
            Button("Stop & Restore", role: .destructive) {
                if isLocationSessionActive { stopCurrentSession() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if movement.route != nil { Text("Your route progress will be reset.") }
        }
    }

    private func stopCurrentSession() {
        initialMovementFollowDistance = nil
        if movement.phase != .idle { movement.stop(using: appModel) }
        else { appModel.stopLocationSession() }
    }

    private func exportButton(_ route: MovementRoute) -> some View {
        MapPanelButton(title: "Export GPX", symbol: "square.and.arrow.up") { exportGPX(route) }
            .buttonStyle(.bordered)
    }

    private var connectionProgress: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(connectionProgressTitle).font(.subheadline.weight(.semibold))
        }
        .frame(minHeight: 44)
    }

    private var connectionProgressTitle: LocalizedStringKey {
        switch appModel.deviceSession.phase {
        case .openingLocalDevVPN: "Opening LocalDevVPN…"
        case .discovering: "Finding This iPhone…"
        default: "Starting Location…"
        }
    }

    @ViewBuilder
    private var sessionNotice: some View {
        if case .failed(let message) = appModel.deviceSession.phase, !showsMovementControls {
            Label(l10n.text(message), systemImage: "exclamationmark.circle").foregroundStyle(.red)
            if message.localizedCaseInsensitiveContains("Install LocalDevVPN") {
                Link(destination: appModel.localDevVPNInstallURL) {
                    Label("Get LocalDevVPN", systemImage: "arrow.up.right.square").frame(minHeight: 44)
                }
            }
        } else if appModel.deviceSession.restorationStatus == .deviceConfirmed && mapModel.awaitingRealLocationAfterSession {
            Label("Simulated location cleared. Waiting for GPS…", systemImage: "location")
                .foregroundStyle(Color(uiColor: .secondaryLabel))
        } else if isLocationSessionActive && appModel.deviceSession.executionMode == .foregroundOnly {
            Label("Keep this app open to continue the session.", systemImage: "iphone")
                .font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
        }
    }

    private var preferences: FeaturePreferences { appModel.featurePreferences }
    private var units: RouteUnits { preferences.units }
    private var preferredSpeed: Double { preferences.speed(for: preferences.movementMode) }
    private var modeBinding: Binding<MovementMode> {
        Binding(get: { preferences.movementMode }, set: { preferences.movementMode = $0 })
    }
    private var isPaired: Bool { if case .paired = appModel.pairingStatus { true } else { false } }
    private var needsPairingPrompt: Bool {
        switch appModel.pairingStatus {
        case .notPaired, .failed: true
        case .checking, .importing, .paired: false
        }
    }
    private var isStopping: Bool { appModel.deviceSession.phase == .stopping }
    private var restorationNeedsAttention: Bool {
        if case .requiresRecovery = appModel.deviceSession.restorationStatus { return true }
        return appModel.interruptedSession != nil
    }
    private var isLocationSessionActive: Bool {
        if case .active = appModel.deviceSession.phase { return true }
        return false
    }
    private var isBusy: Bool {
        if appModel.isPreparingLocationSession { return true }
        return switch appModel.deviceSession.phase {
        case .openingLocalDevVPN, .discovering, .connecting, .stopping: true
        case .active, .idle, .failed: false
        }
    }
    private var showsMovementControls: Bool { !isRedirecting && movement.phase != .idle }
    private var isDrafting: Bool {
        mapAction == .route && !showsMovementControls && routePreview == nil
            && (routeSource == .points || routeSource == .freehand)
    }
    private var isFreehandDrafting: Bool { isDrafting && routeSource == .freehand }
    private var canSelectLocation: Bool {
        !isBusy && !showsMovementControls && !isFreehandDrafting && appModel.interruptedSession == nil
    }
    private var routeStart: LocationTarget? {
        isLocationSessionActive ? appModel.activeDisplayTarget : mapModel.routeStart
    }
    private var activeDeviceCoordinate: RouteCoordinate? {
        if case .active(let target) = appModel.deviceSession.phase { return RouteCoordinate(target.coordinate) }
        return nil
    }
    private var activePointStart: RouteCoordinate? {
        guard routeSource == .points, let activeDeviceCoordinate else { return nil }
        return CoordinateTransform.sourceCoordinate(forDeviceCoordinate: activeDeviceCoordinate, origin: RouteSource.points.targetOrigin,
                                                     compatibility: appModel.sessionCoordinateCompatibility)
    }
    private var defaultPointStart: RouteCoordinate? {
        if isLocationSessionActive { return activePointStart }
        guard pointDraftDestination != nil, let start = mapModel.routeStart else { return nil }
        // A real GPS fix is already in device space, including in Force mode.
        return CoordinateTransform.sourceCoordinate(forDeviceCoordinate: RouteCoordinate(start.coordinate),
                                                     origin: RouteSource.points.targetOrigin,
                                                     compatibility: appModel.sessionCoordinateCompatibility)
    }
    private var pointDraftDestination: LocationTarget? {
        routeSource == .points ? mapModel.selectedLocation : nil
    }
    private var draftCoordinates: [RouteCoordinate] {
        guard routeSource == .points else { return draft.coordinates }
        let end = pointDraftDestination.flatMap { routeCoordinate(for: $0, source: .points) }
        return draft.orderedPoints(start: defaultPointStart, destination: end)
    }

    private func routeCoordinate(for target: LocationTarget, source: RouteSource) -> RouteCoordinate? {
        let raw = RouteCoordinate(target.coordinate)
        let device = CoordinateTransform.deviceCoordinate(raw, origin: target.origin, compatibility: appModel.sessionCoordinateCompatibility)
        return CoordinateTransform.sourceCoordinate(forDeviceCoordinate: device, origin: source.targetOrigin,
                                                     compatibility: appModel.sessionCoordinateCompatibility)
    }

    private var followingLocation: LocationTarget? {
        isLocationSessionActive ? appModel.activeDisplayTarget : nil
    }

    private var mapPositionSample: MapPositionSample {
        let interpolates = !reduceMotion && scenePhase == .active && !isRedirecting
            && (movement.phase == .moving || movement.phase == .paused || movement.phase == .arrived)
        return MapPositionSample(coordinate: followingLocation.map { RouteCoordinate($0.coordinate) },
                                 interpolates: interpolates)
    }

    private var presentedMapPosition: RouteCoordinate? {
        let sample = mapPositionSample
        guard let coordinate = sample.coordinate else { return nil }
        return sample.interpolates ? mapPositionInterpolator.position(at: .now) ?? coordinate : coordinate
    }

    private func speedForEditor(_ mode: MovementMode) -> Double {
        showsMovementControls && movement.mode == mode ? movement.speedMetresPerSecond : preferences.speed(for: mode)
    }

    private func clearPreview() {
        planningTask?.cancel()
        planningTask = nil
        planner.clear()
        routePreview = nil
        routeError = nil
    }

    private func clearRouteEditor() {
        clearPreview()
        draft = RouteDraft()
        isDrawingStroke = false
    }

    private func previewDirections(to destination: LocationTarget) {
        routeError = nil
        isFollowing = false
        isPanelCollapsed = false
        let mode = preferences.movementMode
        let origin: LocationTarget?
        if let activeDeviceCoordinate, let active = followingLocation {
            guard let mappedStart = CoordinateTransform.sourceCoordinate(forDeviceCoordinate: activeDeviceCoordinate,
                                                                         origin: RouteSource.appleMaps.targetOrigin,
                                                                         compatibility: appModel.sessionCoordinateCompatibility) else {
                routeError = MovementRouteError.redirectUnrepresentable.localizedDescription
                return
            }
            origin = CoordinateTransform.replacingCoordinate(of: active, with: mappedStart, origin: RouteSource.appleMaps.targetOrigin)
        } else {
            origin = routeStart
        }
        planningTask?.cancel()
        planningTask = Task {
            let route = await planner.preview(to: destination, from: origin, mode: mode)
            guard !Task.isCancelled, mapAction == .route, routeSource == .appleMaps else { return }
            if let route {
                routePreview = route
                mapModel.show(route)
            } else {
                routeError = planner.errorMessage
            }
        }
    }

    private func previewDraft() {
        do {
            if let destination = pointDraftDestination, routeCoordinate(for: destination, source: .points) == nil {
                throw MovementRouteError.invalidCoordinate
            }
            let name = routeSource == .points ? "Point Route" : "Freehand Route"
            let route = try MovementRoute(name: name, points: draftCoordinates, source: routeSource, mode: preferences.movementMode,
                                          requestedDestination: routeSource == .points ? pointDraftDestination : nil)
            routePreview = route
            routeError = nil
            isFollowing = false
            mapModel.show(route)
        } catch { routeError = error.localizedDescription }
    }

    private func drawFreehand(_ state: UIGestureRecognizer.State, at point: CGPoint, using proxy: MapProxy) {
        switch state {
        case .began:
            guard !isChangingMap, let coordinate = proxy.convert(point, from: .local) else { return }
            let end = draft.coordinates.last.flatMap { proxy.convert($0.coordinate, to: .local) }
            isDrawingStroke = draft.beginStroke(coordinate, at: point, previousEnd: end)
            routeError = isDrawingStroke ? nil : "Continue drawing from the end of the last stroke."
        case .changed:
            guard isDrawingStroke, !isChangingMap, let coordinate = proxy.convert(point, from: .local) else { return }
            draft.appendStroke(coordinate, at: point)
        case .ended:
            if isDrawingStroke { draft.finishStroke() }
            isDrawingStroke = false
        case .cancelled, .failed:
            draft.cancelStroke()
            isDrawingStroke = false
        default: break
        }
    }

    private func start(_ route: MovementRoute) {
        var routeToStart = route
        if isRedirecting || (isLocationSessionActive && (route.source == .points || route.source == .appleMaps)) {
            guard let current = activeDeviceCoordinate else {
                routeError = "The previous route is no longer active."
                return
            }
            do {
                routeToStart = try route.joined(toDeviceCoordinate: current, compatibility: appModel.sessionCoordinateCompatibility)
            } catch {
                routeError = error.localizedDescription
                return
            }
        }
        mapModel.clearSelectedLocation()
        clearRouteEditor()
        beginMovementFollowing(mode: routeToStart.mode, isJoystick: false)
        isRedirecting = false
        wasMovingBeforeRedirect = false
        // The old movement timer is already paused; reuse the active device session.
        movement.reset()
        movement.prepare(routeToStart)
        movement.speedMetresPerSecond = preferences.speed(for: routeToStart.mode)
        Task { await movement.start(using: appModel) }
    }

    private var canContinueAsFixedLocation: Bool {
        guard followingLocation != nil, !isBusy, !restorationNeedsAttention else { return false }
        return movement.phase == .arrived || (movement.isJoystick && (movement.phase == .moving || movement.phase == .paused))
    }

    private func continueAsFixedLocation() {
        guard canContinueAsFixedLocation else { return }
        movement.reset()
        initialMovementFollowDistance = nil
        appModel.continueAsFixedLocation()
        mapAction = .fixed
        isPanelCollapsed = false
        mapModel.clearSelectedLocation()
        mapModel.clearSearch()
        clearRouteEditor()
    }

    private func beginRedirect() {
        guard isLocationSessionActive else { return }
        wasMovingBeforeRedirect = movement.phase == .moving
        if wasMovingBeforeRedirect { movement.togglePause() }
        preferences.movementMode = movement.mode
        mapAction = .route
        routeSource = .appleMaps
        isRedirecting = true
        isPanelCollapsed = false
        isFollowing = false
        mapModel.clearSelectedLocation()
        clearRouteEditor()
    }

    private func cancelRedirect() {
        isRedirecting = false
        clearRouteEditor()
        mapModel.clearSelectedLocation()
        if wasMovingBeforeRedirect && movement.phase == .paused { movement.togglePause() }
        wasMovingBeforeRedirect = false
    }

    private var isShowingImportedRoute: Bool {
        mapAction == .route && routeSource == .gpx && routePreview?.source == .gpx
    }

    private var canOpenPendingGPX: Bool {
        !isLocationSessionActive && !isBusy && !restorationNeedsAttention && movement.phase == .idle
    }

    private func openPendingGPXIfReady() {
        guard canOpenPendingGPX, let url = appModel.pendingGPXImportURL else { return }
        appModel.consumeGPXImportURL()
        importGPX(from: url, openedFromFiles: true)
    }

    private func importGPX(from url: URL, openedFromFiles: Bool = false) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: GPXService.maximumInputBytes + 1) ?? Data()
            let route = try GPXService.decode(data, name: url.deletingPathExtension().lastPathComponent,
                                              mode: preferences.movementMode)
            if openedFromFiles {
                clearRouteEditor()
                mapAction = .route
                routeSource = .gpx
            }
            isFollowing = false
            isPanelCollapsed = false
            routeError = nil
            routePreview = route
            mapModel.show(route)
        } catch { routeError = error.localizedDescription }
    }

    private func exportGPX(_ route: MovementRoute) {
        do {
            let data = try GPXService.encode(route, compatibility: appModel.sessionCoordinateCompatibility)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = String(route.name.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "-" }.prefix(56))
            let url = directory.appendingPathComponent(name.isEmpty ? "Route" : name).appendingPathExtension("gpx")
            do { try data.write(to: url, options: .atomic) }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
            documentPickerMode = .save(url)
        } catch { routeError = error.localizedDescription }
    }

    private func handleDevicePhaseChange(_ oldPhase: DeviceSessionPhase, _ newPhase: DeviceSessionPhase) {
        switch newPhase {
        case .openingLocalDevVPN, .discovering, .connecting, .active, .stopping:
            mapModel.invalidateRealLocationCache()
            mapModel.awaitingRealLocationAfterSession = false
        case .idle, .failed: break
        }
        guard oldPhase != newPhase, appModel.deviceSession.restorationStatus == .deviceConfirmed else { return }
        switch newPhase {
        case .idle, .failed: break
        default: return
        }
        isFollowing = false
        isRedirecting = false
        wasMovingBeforeRedirect = false
        mapModel.awaitingRealLocationAfterSession = true
        clearRouteEditor()
        mapModel.clearSelectedLocation()
        shouldRefreshRealLocationWhenActive = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            refreshRealLocationIfNeeded()
        }
    }

    private func refreshRealLocationIfNeeded() {
        guard shouldRefreshRealLocationWhenActive, scenePhase == .active else { return }
        shouldRefreshRealLocationWhenActive = false
        mapModel.showRealLocationAfterSession()
    }

    private var normalisedMapHeading: Double {
        let remainder = (visibleMapCamera?.heading ?? 0).truncatingRemainder(dividingBy: 360)
        return remainder >= 0 ? remainder : remainder + 360
    }

    private var shouldShowMapCompass: Bool {
        let heading = normalisedMapHeading
        return min(heading, 360 - heading) > 1
    }

    private func resetMapHeading() {
        guard let camera = visibleMapCamera else { return }
        let northUpCamera = MapCamera(centerCoordinate: camera.centerCoordinate, distance: camera.distance,
                                      heading: 0, pitch: camera.pitch)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { mapModel.cameraPosition = .camera(northUpCamera) }
    }

    private func showCurrentLocationNorthUp() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { mapModel.showCurrentLocation() }
    }

    private func beginMovementFollowing(mode: MovementMode, isJoystick: Bool) {
        initialMovementFollowDistance = MapViewModel.initialFollowDistance(for: mode, isJoystick: isJoystick)
        mapPositionInterpolator.accept(mapPositionSample.coordinate, at: .now, interpolate: false)
        isFollowing = true
    }

    private func followCurrentLocation(animate: Bool = false, initialDistance: CLLocationDistance? = nil) {
        let position = initialDistance == nil ? presentedMapPosition : mapPositionSample.coordinate
        guard let position else { return }
        followMapPosition(position, animate: animate, initialDistance: initialDistance)
    }

    private func followMapPosition(_ position: RouteCoordinate, animate: Bool = false,
                                   initialDistance: CLLocationDistance? = nil) {
        guard isFollowing, !isChangingMap else { return }
        withAnimation(animate && !reduceMotion ? .easeInOut(duration: 0.2) : nil) {
            mapModel.center(on: position.coordinate, keeping: visibleMapCamera, distance: initialDistance)
            if initialDistance != nil { visibleMapCamera = mapModel.cameraPosition.camera }
        }
    }

    private func resumeInterruptedSession(_ recovery: SessionRecoveryRecord) {
        guard !isResumingRecovery else { return }
        recoveryError = nil
        isResumingRecovery = true
        isPanelCollapsed = false
        let generation = UUID()
        recoveryGeneration = generation
        recoveryTask = Task {
            defer {
                if recoveryGeneration == generation {
                    isResumingRecovery = false
                    recoveryTask = nil
                    recoveryGeneration = nil
                }
            }
            guard !Task.isCancelled, recoveryGeneration == generation else { return }
            if let snapshot = recovery.movement {
                movement.reset()
                movement.restore(snapshot, at: recovery.lastReportedLocation)
                if let route = snapshot.route { mapModel.show(route) }
                beginMovementFollowing(mode: snapshot.mode, isJoystick: snapshot.isJoystick)
                await movement.start(using: appModel)
            } else if recovery.isWalkingRoute, let destination = recovery.destination {
                guard let route = await planner.preview(to: destination, from: recovery.lastReportedLocation, mode: .walking) else {
                    if !Task.isCancelled, recoveryGeneration == generation { recoveryError = planner.errorMessage ?? "The remaining route could not be prepared." }
                    return
                }
                guard !Task.isCancelled, recoveryGeneration == generation else { return }
                movement.reset()
                movement.prepare(route)
                movement.speedMetresPerSecond = MovementMode.walking.limitedSpeed(
                    recovery.walkingPaceMetresPerSecond ?? preferences.speed(for: .walking)
                )
                mapModel.show(route)
                beginMovementFollowing(mode: .walking, isJoystick: false)
                await movement.start(using: appModel)
            } else {
                mapModel.show(recovery.lastReportedLocation)
                isFollowing = true
                await appModel.startLocationSession(at: recovery.lastReportedLocation)
            }
        }
    }

    private func cancelRecoveryPreparation() {
        recoveryGeneration = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        stopCurrentSession()
        isResumingRecovery = false
        planner.clear()
    }

    private func dismissInterruptedSessionRecovery() {
        recoveryError = nil
        recoveryGeneration = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        isResumingRecovery = false
        movement.reset()
        clearRouteEditor()
        appModel.dismissInterruptedSessionRecovery()
        mapModel.showRealLocationAfterSession()
    }
}

private struct MapPositionSample: Equatable {
    let coordinate: RouteCoordinate?
    let interpolates: Bool
}

private struct CompassRoseDial: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.primary.opacity(0.06))

            Circle()
                .strokeBorder(.primary.opacity(0.28), lineWidth: 0.8)

            Text("N")
                .foregroundStyle(.red)
                .offset(y: -10.5)

            Text("E")
                .offset(x: 10.5)

            Text("S")
                .offset(y: 10.5)

            Text("W")
                .offset(x: -10.5)

            Circle()
                .fill(.primary.opacity(0.65))
                .frame(width: 3, height: 3)
        }
        .font(.system(size: 7.5, weight: .bold, design: .rounded))
        .foregroundStyle(.primary.opacity(0.78))
        .frame(width: 34, height: 34)
    }
}

private extension View {
    @ViewBuilder
    func roamControlMapStyle(_ style: MapDisplayStyle) -> some View {
        switch style {
        case .standard:
            mapStyle(.standard(elevation: .realistic))
        case .satellite:
            mapStyle(.imagery(elevation: .realistic))
        case .hybrid:
            mapStyle(.hybrid(elevation: .realistic))
        }
    }
}

#Preview {
    HomeView()
        .environment(AppModel())
}
