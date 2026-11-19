import Foundation

// GPX 1.1 coordinates use WGS84. Ignore timing and extensions other than our coordinate provenance marker.
enum GPXService {
    static let maximumInputBytes = 5 * 1_024 * 1_024
    private static let namespace = "http://www.topografix.com/GPX/1/1"
    private static let provenanceNamespace = "urn:com.ppanphper.roamcontrol:gpx:1"

    enum Failure: LocalizedError {
        case tooLarge, invalidXML, unsupportedEncoding, prohibitedDeclaration, disconnectedSegments, multipleRoutes

        var errorDescription: String? {
            switch self {
            case .tooLarge: "The GPX file is too large. The limit is 5 MB."
            case .invalidXML: "The file is not a valid GPX 1.1 document."
            case .unsupportedEncoding: "The GPX file must use UTF-8 text."
            case .prohibitedDeclaration: "The GPX file contains a prohibited XML declaration."
            case .disconnectedSegments: "The GPX file contains disconnected track segments. Import one continuous track."
            case .multipleRoutes: "The GPX file contains more than one route or track. Import one at a time."
            }
        }
    }

    static func decode(_ data: Data, name: String, mode: MovementMode) throws -> MovementRoute {
        guard data.count <= maximumInputBytes else { throw Failure.tooLarge }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw Failure.unsupportedEncoding }
        // Disable external resolution and reject DTDs altogether, including internal entity expansion.
        guard !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { throw Failure.prohibitedDeclaration }
        let xml = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        if xml.hasPrefix("<?xml"), let declarationEnd = xml.range(of: "?>") {
            let declaration = String(xml[..<declarationEnd.lowerBound])
            if let match = declaration.range(of: #"\bencoding\s*=\s*(['"])([^'"]+)\1"#, options: .regularExpression) {
                let value = declaration[match].split(whereSeparator: { $0 == "\"" || $0 == "'" }).last?.lowercased()
                guard value == "utf-8" || value == "us-ascii" else { throw Failure.unsupportedEncoding }
            }
        }

        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let reader = Reader()
        parser.delegate = reader
        let parsed = parser.parse()
        if let failure = reader.failure { throw failure }
        guard parsed, reader.hasRoot else { throw Failure.invalidXML }
        let suppliedName = reader.routeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return try MovementRoute(name: suppliedName.isEmpty ? name : suppliedName, points: reader.points, source: .gpx,
                                 mode: mode, deviceWGS84: reader.hasDeviceWGS84)
    }

    static func encode(_ route: MovementRoute, compatibility: CoordinateCompatibility = .off) throws -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Roam Control" xmlns="\(namespace)" xmlns:roam="\(provenanceNamespace)">
          <trk>
            <name>\(escapedXML(route.name))</name>
            <trkseg>

        """
        for raw in route.points {
            // A GPX export contains device-space geometry, not mainland display offsets.
            let point = CoordinateTransform.deviceCoordinate(raw, origin: route.targetOrigin, compatibility: compatibility)
            let longitude = point.longitude == 180 ? -180 : point.longitude
            xml += "      <trkpt lat=\"\(decimal(point.latitude))\" lon=\"\(decimal(longitude))\"/>\n"
        }
        xml += "    </trkseg>\n  </trk>\n  <extensions><roam:deviceWGS84/></extensions>\n</gpx>\n"
        let bytes = Data(xml.utf8)
        guard bytes.count <= maximumInputBytes else { throw Failure.tooLarge }
        return bytes
    }

    // GPX XML Schema uses decimal, so express the shortest Swift representation without an exponent.
    private static func decimal(_ value: Double) -> String {
        let parts = String(value).split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return String(value) }
        let sign = value < 0 ? "-" : ""
        let mantissa = parts[0].drop(while: { $0 == "-" }).split(separator: ".")
        let digits = mantissa.joined()
        let position = mantissa[0].count + exponent
        if position <= 0 { return sign + "0." + String(repeating: "0", count: -position) + digits }
        if position >= digits.count { return sign + digits + String(repeating: "0", count: position - digits.count) }
        return sign + digits.prefix(position) + "." + digits.dropFirst(position)
    }

    private static func escapedXML(_ text: String) -> String {
        var clean = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x26: clean += "&amp;"
            case 0x3C: clean += "&lt;"
            case 0x3E: clean += "&gt;"
            case 0x0D: clean += "&#13;"
            case 0x09, 0x0A, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                clean.unicodeScalars.append(scalar)
            default: clean += "\u{fffd}"
            }
        }
        return clean
    }

    private final class Reader: NSObject, XMLParserDelegate {
        private var elements: [String] = []
        private var rootNamespace = ""
        private var groupIndex = 0
        private var segmentIndex = 0
        private var lastGroupWithPoints: Int?
        private var lastSegmentWithPoints: Int?
        private var groupName = ""
        private var pointsSeen = 0
        private(set) var hasRoot = false
        private(set) var hasDeviceWGS84 = false
        private(set) var failure: Error?
        private(set) var points: [RouteCoordinate] = []
        private(set) var routeName = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            if elements.count >= 64 {
                abort(parser, with: Failure.invalidXML)
                return
            }
            let uri = namespaceURI ?? ""
            if elements.isEmpty {
                guard !hasRoot, elementName == "gpx", uri.isEmpty || uri == GPXService.namespace,
                      attributes["version"].map({ $0 == "1.1" }) ?? true else {
                    abort(parser, with: Failure.invalidXML)
                    return
                }
                hasRoot = true
                rootNamespace = uri
            }
            if elements == ["gpx", "extensions"], uri == GPXService.provenanceNamespace, elementName == "deviceWGS84" {
                hasDeviceWGS84 = true
            }
            elements.append(uri == rootNamespace ? elementName : "")

            switch elements {
            case ["gpx", "trk"], ["gpx", "rte"]:
                groupIndex += 1
                groupName = ""
            case ["gpx", "trk", "trkseg"]:
                segmentIndex += 1
            case ["gpx", "trk", "trkseg", "trkpt"], ["gpx", "rte", "rtept"]:
                pointsSeen += 1
                guard pointsSeen <= MovementRoute.maximumPoints else {
                    abort(parser, with: MovementRouteError.tooManyPoints)
                    return
                }
                guard let lat = attributes["lat"].flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
                      let lon = attributes["lon"].flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) else {
                    abort(parser, with: MovementRouteError.invalidCoordinate)
                    return
                }
                let coordinate = RouteCoordinate(latitude: lat, longitude: lon)
                guard coordinate.isValid else {
                    abort(parser, with: MovementRouteError.invalidCoordinate)
                    return
                }
                if let lastGroupWithPoints, lastGroupWithPoints != groupIndex {
                    abort(parser, with: Failure.multipleRoutes)
                    return
                }
                if let lastSegmentWithPoints, lastSegmentWithPoints != segmentIndex,
                   let last = points.last, last.distance(to: coordinate) > 1e-8 {
                    abort(parser, with: Failure.disconnectedSegments)
                    return
                }
                lastGroupWithPoints = groupIndex
                lastSegmentWithPoints = segmentIndex
                points.append(coordinate)
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard elements == ["gpx", "trk", "name"] || elements == ["gpx", "rte", "name"] else { return }
            if groupName.count < 256 { groupName += string.prefix(256 - groupName.count) }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if (elements == ["gpx", "trk"] || elements == ["gpx", "rte"]), lastGroupWithPoints == groupIndex {
                routeName = groupName
            }
            _ = elements.popLast()
        }

        private func abort(_ parser: XMLParser, with failure: Error) {
            self.failure = failure
            parser.abortParsing()
        }
    }
}
