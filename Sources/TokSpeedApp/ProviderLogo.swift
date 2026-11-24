import AppKit

enum ProviderLogo {
    private static var cache: [SourceMode: NSImage] = [:]

    static func image(_ source: SourceMode) -> NSImage? {
        if source == .auto { return nil }
        if let image = cache[source] { return image }
        var roots = [Bundle.main.resourceURL].compactMap { $0 }
        #if DEBUG
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        roots.append(development)
        #endif
        let urls = roots.map { $0.appendingPathComponent("Logos/\(source.rawValue).svg") }
        guard let svg = urls.compactMap({ try? String(contentsOf: $0, encoding: .utf8) }).first,
              let path = parsePath(svg) else { return nil }
        let bounds = path.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = 16 / max(bounds.width, bounds.height)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = AffineTransform(
                m11: scale, m12: 0, m21: 0, m22: -scale,
                tX: (18 - bounds.width * scale) / 2 - bounds.minX * scale,
                tY: (18 - bounds.height * scale) / 2 + bounds.maxY * scale)
            let rendered = path.copy() as! NSBezierPath
            rendered.transform(using: transform)
            NSColor.black.setFill()
            rendered.fill()
            return true
        }
        image.isTemplate = true
        cache[source] = image
        return image
    }

    // Decodes monochrome SVG <path> elements using M/m, L/l, H/h, V/v, C/c, S/s, Q/q, T/t, Z/z.
    static func parsePath(_ svg: String) -> NSBezierPath? {
        guard let attrRegex = try? NSRegularExpression(pattern: #"\bd="([^"]+)""#) else { return nil }
        let fullSVG = NSRange(svg.startIndex..., in: svg)
        let pathMatches = attrRegex.matches(in: svg, range: fullSVG)
        guard !pathMatches.isEmpty else { return nil }

        let tokenPattern = #"[MLHVCZSQTmlhvczsqt]|[-+]?(?:\d*\.)?\d+(?:[eE][-+]?\d+)?"#
        guard let tokenRegex = try? NSRegularExpression(pattern: tokenPattern) else { return nil }

        let combined = NSBezierPath()
        combined.windingRule = svg.contains("evenodd") ? .evenOdd : .nonZero

        for match in pathMatches {
            guard let range = Range(match.range(at: 1), in: svg) else { continue }
            let data = String(svg[range])
            let fullRange = NSRange(data.startIndex..., in: data)
            let residue = tokenRegex.stringByReplacingMatches(in: data, range: fullRange, withTemplate: "")
            guard residue.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))).isEmpty else {
                return nil
            }
            let tokens = tokenRegex.matches(in: data, range: fullRange).map { String(data[Range($0.range, in: data)!]) }
            guard appendSubpath(tokens: tokens, to: combined) else { return nil }
        }
        return combined.isEmpty ? nil : combined
    }

    private static func appendSubpath(tokens: [String], to path: NSBezierPath) -> Bool {
        var index = 0
        var current = NSPoint.zero
        var subpathStart = NSPoint.zero
        var lastCommand: Character = " "
        var lastCubicControl: NSPoint?
        var lastQuadControl: NSPoint?

        func isCommand(_ token: String) -> Bool {
            token.count == 1 && token.first?.isLetter == true
        }
        func hasMoreNumbers() -> Bool {
            index < tokens.count && !isCommand(tokens[index])
        }
        func number() -> CGFloat? {
            guard index < tokens.count, !isCommand(tokens[index]),
                  let value = Double(tokens[index]), value.isFinite else { return nil }
            index += 1
            return CGFloat(value)
        }
        func point(relative: Bool) -> NSPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? NSPoint(x: current.x + x, y: current.y + y) : NSPoint(x: x, y: y)
        }
        func addQuad(control q: NSPoint, end p2: NSPoint) {
            let p0 = current
            let c1 = NSPoint(x: p0.x + (2.0 / 3.0) * (q.x - p0.x), y: p0.y + (2.0 / 3.0) * (q.y - p0.y))
            let c2 = NSPoint(x: p2.x + (2.0 / 3.0) * (q.x - p2.x), y: p2.y + (2.0 / 3.0) * (q.y - p2.y))
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        func reflect(_ control: NSPoint?, around point: NSPoint) -> NSPoint {
            guard let c = control else { return point }
            return NSPoint(x: 2 * point.x - c.x, y: 2 * point.y - c.y)
        }

        while index < tokens.count {
            let cmdToken = tokens[index]
            guard isCommand(cmdToken), let cmd = cmdToken.first else { return false }
            index += 1
            var activeCmd = cmd

            if activeCmd == "Z" || activeCmd == "z" {
                path.close()
                current = subpathStart
                lastCommand = activeCmd
                lastCubicControl = nil
                lastQuadControl = nil
                continue
            }

            repeat {
                let rel = activeCmd.isLowercase
                switch activeCmd.uppercased().first {
                case "M":
                    guard let p = point(relative: rel) else { return false }
                    path.move(to: p)
                    current = p
                    subpathStart = p
                    lastCubicControl = nil
                    lastQuadControl = nil
                    activeCmd = rel ? "l" : "L"
                case "L":
                    guard let p = point(relative: rel) else { return false }
                    path.line(to: p)
                    current = p
                    lastCubicControl = nil
                    lastQuadControl = nil
                case "H":
                    guard let x = number() else { return false }
                    let p = NSPoint(x: rel ? current.x + x : x, y: current.y)
                    path.line(to: p)
                    current = p
                    lastCubicControl = nil
                    lastQuadControl = nil
                case "V":
                    guard let y = number() else { return false }
                    let p = NSPoint(x: current.x, y: rel ? current.y + y : y)
                    path.line(to: p)
                    current = p
                    lastCubicControl = nil
                    lastQuadControl = nil
                case "C":
                    guard let c1 = point(relative: rel),
                          let c2 = point(relative: rel),
                          let end = point(relative: rel) else { return false }
                    path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
                    lastCubicControl = c2
                    lastQuadControl = nil
                    current = end
                case "S":
                    let isPrevCubic = lastCommand == "C" || lastCommand == "c" || lastCommand == "S" || lastCommand == "s"
                    let c1 = isPrevCubic ? reflect(lastCubicControl, around: current) : current
                    guard let c2 = point(relative: rel), let end = point(relative: rel) else { return false }
                    path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
                    lastCubicControl = c2
                    lastQuadControl = nil
                    current = end
                case "Q":
                    guard let c = point(relative: rel), let end = point(relative: rel) else { return false }
                    addQuad(control: c, end: end)
                    lastQuadControl = c
                    lastCubicControl = nil
                    current = end
                case "T":
                    let isPrevQuad = lastCommand == "Q" || lastCommand == "q" || lastCommand == "T" || lastCommand == "t"
                    let c = isPrevQuad ? reflect(lastQuadControl, around: current) : current
                    guard let end = point(relative: rel) else { return false }
                    addQuad(control: c, end: end)
                    lastQuadControl = c
                    lastCubicControl = nil
                    current = end
                default:
                    return false
                }
                lastCommand = activeCmd
            } while hasMoreNumbers()
        }
        return true
    }
}
