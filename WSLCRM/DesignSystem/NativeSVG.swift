import CoreGraphics
import Foundation
import UIKit

/// Draws an SVG (a workspace logo) into a bitmap natively, with Core Graphics.
///
/// UIKit has no public SVG decoder and the app shows no web views, so this covers what logos use:
/// `rect` (rounded), `circle`, `ellipse`, `line`, `polyline`, `polygon`, `path` (every command,
/// arcs included), `text`, nested `g`, `fill`/`stroke`/opacity, `fill-rule`, `transform`
/// (translate, scale, rotate, matrix) and inline `style`. Gradients, filters, masks and images are
/// not drawn; a logo that relies on them still renders its shapes.
enum NativeSVG {
    /// nil when the data isn't an SVG with a usable size.
    static func render(_ data: Data, side: CGFloat = 240, scale: CGFloat = 3) -> UIImage? {
        guard let document = SVGDocument.parse(data), document.viewBox.width > 0, document.viewBox.height > 0 else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cg = context.cgContext
            // preserveAspectRatio="xMidYMid meet": fit, centred.
            let box = document.viewBox
            let factor = min(side / box.width, side / box.height)
            cg.translateBy(x: (side - box.width * factor) / 2, y: (side - box.height * factor) / 2)
            cg.scaleBy(x: factor, y: factor)
            cg.translateBy(x: -box.minX, y: -box.minY)
            for node in document.nodes { draw(node, in: cg, style: SVGStyle()) }
        }
    }

    private static func draw(_ node: SVGNode, in cg: CGContext, style inherited: SVGStyle) {
        let style = inherited.applying(node.attributes)
        guard style.display else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        if let transform = node.attributes["transform"] { cg.concatenate(SVGTransform.parse(transform)) }

        switch node.name {
        case "g", "svg", "a":
            for child in node.children { draw(child, in: cg, style: style) }
        case "text":
            drawText(node, in: cg, style: style)
        default:
            guard let path = SVGShape.path(for: node) else { return }
            paint(path, in: cg, style: style)
        }
    }

    private static func paint(_ path: CGPath, in cg: CGContext, style: SVGStyle) {
        if let fill = style.fill {
            cg.addPath(path)
            cg.setFillColor(fill.copy(alpha: fill.alpha * style.fillOpacity * style.opacity) ?? fill)
            cg.fillPath(using: style.evenOdd ? .evenOdd : .winding)
        }
        if let stroke = style.stroke, style.strokeWidth > 0 {
            cg.addPath(path)
            cg.setStrokeColor(stroke.copy(alpha: stroke.alpha * style.strokeOpacity * style.opacity) ?? stroke)
            cg.setLineWidth(style.strokeWidth)
            cg.setLineCap(style.lineCap)
            cg.setLineJoin(style.lineJoin)
            cg.strokePath()
        }
    }

    private static func drawText(_ node: SVGNode, in cg: CGContext, style: SVGStyle) {
        let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let fill = style.fill else { return }
        let x = SVGShape.number(node.attributes["x"]) ?? 0
        let y = SVGShape.number(node.attributes["y"]) ?? 0
        let weight: UIFont.Weight = switch style.fontWeight {
        case ..<350: .light
        case ..<550: .regular
        case ..<650: .semibold
        case ..<750: .bold
        default: .heavy
        }
        let font = UIFont.systemFont(ofSize: style.fontSize, weight: weight)
        let color = UIColor(cgColor: fill.copy(alpha: fill.alpha * style.fillOpacity * style.opacity) ?? fill)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .kern: style.letterSpacing,
        ])
        let width = attributed.size().width
        let originX: CGFloat = switch style.textAnchor {
        case "middle": x - width / 2
        case "end": x - width
        default: x
        }
        // SVG puts text on its baseline; UIKit draws from the top of the line.
        UIGraphicsPushContext(cg)
        attributed.draw(at: CGPoint(x: originX, y: y - font.ascender))
        UIGraphicsPopContext()
    }
}

// MARK: - Document

struct SVGNode {
    let name: String
    let attributes: [String: String]
    var children: [SVGNode] = []
    var text = ""
}

struct SVGDocument {
    let viewBox: CGRect
    let nodes: [SVGNode]

    static func parse(_ data: Data) -> SVGDocument? {
        let builder = SVGTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root, root.name == "svg" else { return nil }
        var box = CGRect.zero
        if let raw = root.attributes["viewBox"] {
            let numbers = SVGShape.numbers(raw)
            if numbers.count == 4 { box = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) }
        }
        if box.width <= 0 || box.height <= 0 {
            box = CGRect(x: 0, y: 0, width: SVGShape.number(root.attributes["width"]) ?? 0,
                         height: SVGShape.number(root.attributes["height"]) ?? 0)
        }
        return SVGDocument(viewBox: box, nodes: [root])
    }
}

private final class SVGTreeBuilder: NSObject, XMLParserDelegate {
    var root: SVGNode?
    private var stack: [SVGNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        stack.append(SVGNode(name: name, attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard var node = stack.popLast() else { return }
        // A <tspan> adds its words to the text around it.
        if node.name == "tspan", !stack.isEmpty {
            stack[stack.count - 1].text += node.text
            return
        }
        if stack.isEmpty {
            root = node
        } else if ["defs", "title", "desc", "metadata", "style", "clipPath", "mask", "linearGradient",
                   "radialGradient", "filter", "symbol"].contains(node.name) {
            return
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }
}

// MARK: - Style

struct SVGStyle {
    var fill: CGColor? = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    var stroke: CGColor?
    var strokeWidth: CGFloat = 1
    var opacity: CGFloat = 1
    var fillOpacity: CGFloat = 1
    var strokeOpacity: CGFloat = 1
    var evenOdd = false
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    var fontSize: CGFloat = 16
    var fontWeight: Int = 400
    var letterSpacing: CGFloat = 0
    var textAnchor = "start"
    var display = true

    /// This node's own presentation attributes and `style="…"` on top of what it inherits.
    func applying(_ attributes: [String: String]) -> SVGStyle {
        var properties = attributes
        if let inline = attributes["style"] {
            for declaration in inline.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { properties[parts[0]] = parts[1] }
            }
        }
        var style = self
        // Opacity multiplies down the tree; the rest is inherited and overridden.
        style.opacity = opacity
        if let value = properties["fill"] { style.fill = SVGColor.parse(value) }
        if let value = properties["stroke"] { style.stroke = SVGColor.parse(value) }
        if let value = SVGShape.number(properties["stroke-width"]) { style.strokeWidth = value }
        if let value = SVGShape.number(properties["opacity"]) { style.opacity = opacity * value }
        if let value = SVGShape.number(properties["fill-opacity"]) { style.fillOpacity = value }
        if let value = SVGShape.number(properties["stroke-opacity"]) { style.strokeOpacity = value }
        if let value = properties["fill-rule"] { style.evenOdd = value == "evenodd" }
        if let value = properties["stroke-linecap"] {
            style.lineCap = value == "round" ? .round : value == "square" ? .square : .butt
        }
        if let value = properties["stroke-linejoin"] {
            style.lineJoin = value == "round" ? .round : value == "bevel" ? .bevel : .miter
        }
        if let value = SVGShape.number(properties["font-size"]) { style.fontSize = value }
        if let value = properties["font-weight"] {
            style.fontWeight = Int(value) ?? (value == "bold" || value == "bolder" ? 700 : 400)
        }
        if let value = SVGShape.number(properties["letter-spacing"]) { style.letterSpacing = value }
        if let value = properties["text-anchor"] { style.textAnchor = value }
        if properties["display"] == "none" || properties["visibility"] == "hidden" { style.display = false }
        return style
    }
}

enum SVGColor {
    static func parse(_ raw: String) -> CGColor? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "none" || value == "transparent" || value.hasPrefix("url(") { return nil }
        if value.hasPrefix("#") { return hex(String(value.dropFirst())) }
        if value.hasPrefix("rgb") {
            let numbers = SVGShape.numbers(value.replacingOccurrences(of: "%", with: ""))
            guard numbers.count >= 3 else { return nil }
            let percent = value.contains("%")
            let channel: (CGFloat) -> CGFloat = { percent ? $0 / 100 : $0 / 255 }
            return CGColor(red: channel(numbers[0]), green: channel(numbers[1]), blue: channel(numbers[2]),
                           alpha: numbers.count > 3 ? numbers[3] : 1)
        }
        if let named = names[value] { return hex(named) }
        return CGColor(red: 0, green: 0, blue: 0, alpha: 1)  // currentColor and unknown names
    }

    private static func hex(_ digits: String) -> CGColor? {
        var text = digits
        if text.count == 3 || text.count == 4 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let a = hasAlpha ? CGFloat(value & 0xff) / 255 : 1
        return CGColor(red: r, green: g, blue: b, alpha: a)
    }

    private static let names: [String: String] = [
        "black": "000000", "white": "ffffff", "red": "ff0000", "green": "008000", "blue": "0000ff",
        "yellow": "ffff00", "orange": "ffa500", "purple": "800080", "grey": "808080", "gray": "808080",
        "navy": "000080", "teal": "008080", "silver": "c0c0c0", "maroon": "800000", "lime": "00ff00",
        "aqua": "00ffff", "fuchsia": "ff00ff", "olive": "808000", "pink": "ffc0cb", "gold": "ffd700",
    ]
}

// MARK: - Transforms

enum SVGTransform {
    static func parse(_ raw: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        let scanner = raw.replacingOccurrences(of: ",", with: " ")
        var rest = Substring(scanner)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: .whitespaces)
            let values = SVGShape.numbers(String(rest[rest.index(after: open)..<close]))
            var step = CGAffineTransform.identity
            switch name {
            case "translate":
                step = CGAffineTransform(translationX: values.first ?? 0, y: values.count > 1 ? values[1] : 0)
            case "scale":
                step = CGAffineTransform(scaleX: values.first ?? 1, y: values.count > 1 ? values[1] : (values.first ?? 1))
            case "rotate":
                let angle = (values.first ?? 0) * .pi / 180
                if values.count == 3 {
                    step = CGAffineTransform(translationX: values[1], y: values[2]).rotated(by: angle)
                        .translatedBy(x: -values[1], y: -values[2])
                } else {
                    step = CGAffineTransform(rotationAngle: angle)
                }
            case "matrix" where values.count == 6:
                step = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            case "skewX":
                step = CGAffineTransform(a: 1, b: 0, c: tan((values.first ?? 0) * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewY":
                step = CGAffineTransform(a: 1, b: tan((values.first ?? 0) * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default:
                break
            }
            // Listed transforms apply right to left, which is left-multiplication in Core Graphics.
            result = step.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }
}

// MARK: - Shapes and paths

enum SVGShape {
    static func path(for node: SVGNode) -> CGPath? {
        let a = node.attributes
        func n(_ key: String) -> CGFloat { number(a[key]) ?? 0 }
        let path = CGMutablePath()
        switch node.name {
        case "rect":
            let rect = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
            guard rect.width > 0, rect.height > 0 else { return nil }
            var rx = number(a["rx"]) ?? number(a["ry"]) ?? 0
            var ry = number(a["ry"]) ?? number(a["rx"]) ?? 0
            rx = min(rx, rect.width / 2)
            ry = min(ry, rect.height / 2)
            if rx > 0 || ry > 0 {
                path.addRoundedRect(in: rect, cornerWidth: rx, cornerHeight: ry)
            } else {
                path.addRect(rect)
            }
        case "circle":
            let r = n("r")
            guard r > 0 else { return nil }
            path.addEllipse(in: CGRect(x: n("cx") - r, y: n("cy") - r, width: r * 2, height: r * 2))
        case "ellipse":
            let rx = n("rx"), ry = n("ry")
            guard rx > 0, ry > 0 else { return nil }
            path.addEllipse(in: CGRect(x: n("cx") - rx, y: n("cy") - ry, width: rx * 2, height: ry * 2))
        case "line":
            path.move(to: CGPoint(x: n("x1"), y: n("y1")))
            path.addLine(to: CGPoint(x: n("x2"), y: n("y2")))
        case "polyline", "polygon":
            let values = numbers(a["points"] ?? "")
            guard values.count >= 4 else { return nil }
            path.move(to: CGPoint(x: values[0], y: values[1]))
            var i = 2
            while i + 1 < values.count {
                path.addLine(to: CGPoint(x: values[i], y: values[i + 1]))
                i += 2
            }
            if node.name == "polygon" { path.closeSubpath() }
        case "path":
            guard let d = a["d"] else { return nil }
            return SVGPathParser.parse(d)
        default:
            return nil
        }
        return path
    }

    static func number(_ raw: String?) -> CGFloat? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        for unit in ["px", "pt", "em"] where text.hasSuffix(unit) { text.removeLast(unit.count) }
        return Double(text).map { CGFloat($0) }
    }

    /// Every number in a string ("0 0 96 96", "10,20 30-40", "1e-3").
    static func numbers(_ raw: String) -> [CGFloat] {
        // Only numbers matter here: words and brackets (`rgb(`) are separators.
        let cleaned = String(raw.map { c -> Character in
            (c.isLetter && c != "e" && c != "E") || c == "(" || c == ")" || c == "%" ? " " : c
        })
        var scanner = SVGNumberScanner(cleaned)
        var result: [CGFloat] = []
        while let value = scanner.next() { result.append(value) }
        return result
    }
}

/// Reads SVG numbers, which may run together ("10-5", ".5.5").
struct SVGNumberScanner {
    private let scalars: [Character]
    private(set) var index = 0

    init(_ text: String) { scalars = Array(text) }

    var isAtEnd: Bool {
        var i = index
        while i < scalars.count, scalars[i] == " " || scalars[i] == "," || scalars[i].isNewline || scalars[i] == "\t" { i += 1 }
        return i >= scalars.count
    }

    mutating func skipSeparators() {
        while index < scalars.count, scalars[index] == " " || scalars[index] == "," || scalars[index].isNewline
                || scalars[index] == "\t" { index += 1 }
    }

    /// The next character without consuming it (after separators).
    mutating func peek() -> Character? {
        skipSeparators()
        return index < scalars.count ? scalars[index] : nil
    }

    mutating func advance() { index += 1 }

    mutating func next() -> CGFloat? {
        skipSeparators()
        guard index < scalars.count else { return nil }
        var text = ""
        var seenDot = false, seenExponent = false
        if scalars[index] == "-" || scalars[index] == "+" { text.append(scalars[index]); index += 1 }
        while index < scalars.count {
            let c = scalars[index]
            if c.isNumber { text.append(c) }
            else if c == ".", !seenDot, !seenExponent { seenDot = true; text.append(c) }
            else if (c == "e" || c == "E"), !seenExponent, !text.isEmpty {
                seenExponent = true
                text.append(c)
                if index + 1 < scalars.count, scalars[index + 1] == "-" || scalars[index + 1] == "+" {
                    index += 1
                    text.append(scalars[index])
                }
            } else { break }
            index += 1
        }
        guard let value = Double(text) else { return nil }
        return CGFloat(value)
    }

    /// An arc flag: a single 0 or 1, which may be written with no separator ("a1 1 0 01 1 1").
    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < scalars.count, scalars[index] == "0" || scalars[index] == "1" else { return nil }
        defer { index += 1 }
        return scalars[index] == "1"
    }
}

enum SVGPathParser {
    static func parse(_ d: String) -> CGPath? {
        let path = CGMutablePath()
        var scanner = SVGNumberScanner(d)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "
        var command: Character?

        while let next = scanner.peek() {
            if next.isLetter, next != "e", next != "E" {
                command = next
                scanner.advance()
            } else if command == nil {
                return nil
            }
            guard let cmd = command else { break }
            let relative = cmd.isLowercase
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch cmd.uppercased().first! {
            case "M":
                guard let x = scanner.next(), let y = scanner.next() else { return path }
                current = point(x, y)
                start = current
                path.move(to: current)
                // Further pairs after a move are lines.
                command = relative ? "l" : "L"
                lastControl = nil
            case "L":
                guard let x = scanner.next(), let y = scanner.next() else { return path }
                current = point(x, y)
                path.addLine(to: current)
                lastControl = nil
            case "H":
                guard let x = scanner.next() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case "V":
                guard let y = scanner.next() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
            case "C":
                guard let x1 = scanner.next(), let y1 = scanner.next(), let x2 = scanner.next(), let y2 = scanner.next(),
                      let x = scanner.next(), let y = scanner.next() else { return path }
                let c1 = point(x1, y1), c2 = point(x2, y2), end = point(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "S":
                guard let x2 = scanner.next(), let y2 = scanner.next(), let x = scanner.next(), let y = scanner.next() else {
                    return path
                }
                let c1 = "CScs".contains(lastCommand) && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                let c2 = point(x2, y2), end = point(x, y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "Q":
                guard let x1 = scanner.next(), let y1 = scanner.next(), let x = scanner.next(), let y = scanner.next() else {
                    return path
                }
                let c = point(x1, y1), end = point(x, y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c
                current = end
            case "T":
                guard let x = scanner.next(), let y = scanner.next() else { return path }
                let c = "QTqt".contains(lastCommand) && lastControl != nil
                    ? CGPoint(x: 2 * current.x - lastControl!.x, y: 2 * current.y - lastControl!.y) : current
                let end = point(x, y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c
                current = end
            case "A":
                guard let rx = scanner.next(), let ry = scanner.next(), let rotation = scanner.next(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.next(), let y = scanner.next() else { return path }
                let end = point(x, y)
                addArc(path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end
                lastControl = nil
            case "Z":
                path.closeSubpath()
                current = start
                lastControl = nil
                command = nil
            default:
                return path
            }
            lastCommand = cmd
            if command == nil, let peek = scanner.peek(), !peek.isLetter { return path }
        }
        return path
    }

    /// SVG's endpoint arc as Bézier curves (SVG 1.1 implementation notes, F.6.5).
    static func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                       rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if large == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let length = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(max(-1, min(1, dot / length)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        // At most a quarter turn per curve keeps the approximation tight.
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        var theta = theta1
        for _ in 0..<segments {
            let cos1 = cos(theta), sin1 = sin(theta)
            let cos2 = cos(theta + step), sin2 = sin(theta + step)
            func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * x * cosPhi - ry * y * sinPhi, y: cy + rx * x * sinPhi + ry * y * cosPhi)
            }
            let c1 = map(cos1 - t * sin1, sin1 + t * cos1)
            let c2 = map(cos2 + t * sin2, sin2 - t * cos2)
            let end = map(cos2, sin2)
            path.addCurve(to: end, control1: c1, control2: c2)
            theta += step
        }
    }
}
