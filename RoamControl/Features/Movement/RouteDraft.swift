import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct RouteDraft {
    private(set) var points: [RouteCoordinate] = []
    private(set) var pointStart: RouteCoordinate?
    private(set) var strokes: [[RouteCoordinate]] = []
    private var stroke: [RouteCoordinate] = []
    private var lastScreenPoint: CGPoint?
    private let maximumDraftPoints = 4_000

    var coordinates: [RouteCoordinate] { points + strokes.flatMap { $0 } + stroke }
    var canUndo: Bool { pointStart != nil || !points.isEmpty || !strokes.isEmpty }

    func orderedPoints(start fallbackStart: RouteCoordinate?, destination: RouteCoordinate?) -> [RouteCoordinate] {
        var ordered = [pointStart ?? fallbackStart].compactMap { $0 }
        ordered.append(contentsOf: points)
        if let destination { ordered.append(destination) }
        return ordered.reduce(into: []) { result, point in
            if result.last != point { result.append(point) }
        }
    }

    mutating func setPointStart(_ start: RouteCoordinate) { pointStart = start }

    mutating func addPoint(_ coordinate: CLLocationCoordinate2D) {
        guard points.count < maximumDraftPoints else { return }
        let point = RouteCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if points.last != point { points.append(point) }
    }

    mutating func beginStroke(_ coordinate: CLLocationCoordinate2D, at screenPoint: CGPoint, previousEnd: CGPoint?) -> Bool {
        cancelStroke()
        if !strokes.isEmpty,
           previousEnd.map({ hypot(screenPoint.x - $0.x, screenPoint.y - $0.y) > 36 }) ?? true {
            return false
        }
        appendStroke(coordinate, at: screenPoint)
        return true
    }

    mutating func appendStroke(_ coordinate: CLLocationCoordinate2D, at screenPoint: CGPoint) {
        guard strokes.reduce(0, { $0 + $1.count }) + stroke.count < maximumDraftPoints else { return }
        if let lastScreenPoint, hypot(screenPoint.x - lastScreenPoint.x, screenPoint.y - lastScreenPoint.y) < 7 { return }
        let point = RouteCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if stroke.last != point { stroke.append(point) }
        lastScreenPoint = screenPoint
    }

    mutating func finishStroke() {
        if stroke.count > 1 { strokes.append(stroke) }
        cancelStroke()
    }

    mutating func cancelStroke() {
        stroke.removeAll(keepingCapacity: true)
        lastScreenPoint = nil
    }

    mutating func undo(source: RouteSource) {
        if source == .freehand { _ = strokes.popLast() }
        if source == .points {
            if points.isEmpty { pointStart = nil }
            else { _ = points.popLast() }
        }
    }
}

/// Both recognizers receive the original Map view touches. The drawing recognizer
/// only claims a single finger; MapKit retains its pinch, rotation and two-finger pan.
struct MapSingleFingerPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let claimsMapPan: Bool
    let onChange: (UIGestureRecognizer.State, CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Delegate { Delegate() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = enabled
        context.coordinator.claimsMapPan = claimsMapPan
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        if recognizer.isEnabled != enabled { recognizer.isEnabled = enabled }
        context.coordinator.claimsMapPan = claimsMapPan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        onChange(recognizer.state, context.converter.localLocation)
    }

    final class Delegate: NSObject, UIGestureRecognizerDelegate {
        var claimsMapPan = false

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard claimsMapPan, let pan = other as? UIPanGestureRecognizer else { return false }
            return pan.minimumNumberOfTouches == 1
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard claimsMapPan, let pan = other as? UIPanGestureRecognizer else { return true }
            return pan.minimumNumberOfTouches > 1
        }
    }
}
