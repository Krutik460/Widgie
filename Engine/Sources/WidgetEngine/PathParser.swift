import CoreGraphics
import Foundation
import Spec

extension PathData {
    /// SVG path data: M L H V C S Q T A Z, absolute (upper case) and relative (lower case). Arcs become cubic
    /// curves here, so the renderer draws four kinds of segment.
    static func parse(_ d: String) throws(Diagnostic) -> PathData {
        var parser = PathParser(Array(d.utf8))
        return PathData(commands: try parser.parse())
    }
}

private struct PathParser {
    private let bytes: [UInt8]
    private var index = 0
    private var commands: [PathData.Command] = []
    private var current = CGPoint.zero
    private var start = CGPoint.zero
    /// The last curve's second control point, for the reflection that S and T need.
    private var lastControl: CGPoint?

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func parse() throws(Diagnostic) -> [PathData.Command] {
        skipSeparators()
        while index < bytes.count {
            let letter = bytes[index]
            guard isLetter(letter) else {
                throw Diagnostic("\"d\" has \(near()) where a command letter (M L H V C S Q T A Z) belongs")
            }
            index += 1
            let relative = letter >= 0x61
            let command = relative ? letter - 0x20 : letter
            var first = true
            repeat {
                try segment(command, relative: relative, first: first)
                first = false
            } while command != ascii("Z") && hasNumber()
            skipSeparators()
        }
        guard case .move? = commands.first else {
            throw Diagnostic("\"d\" must start with a move, like \"M 0 0 L 10 10\"")
        }
        return commands
    }

    private mutating func segment(_ command: UInt8, relative: Bool, first: Bool) throws(Diagnostic) {
        func point() throws(Diagnostic) -> CGPoint {
            let x = try number()
            let y = try number()
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }
        switch command {
        case ascii("M"):
            let target = try point()
            if first {
                commands.append(.move(target))
                start = target
            } else {
                commands.append(.line(target))
            }
            current = target
            lastControl = nil
        case ascii("L"):
            let target = try point()
            commands.append(.line(target))
            current = target
            lastControl = nil
        case ascii("H"):
            let x = try number()
            current = CGPoint(x: relative ? current.x + x : x, y: current.y)
            commands.append(.line(current))
            lastControl = nil
        case ascii("V"):
            let y = try number()
            current = CGPoint(x: current.x, y: relative ? current.y + y : y)
            commands.append(.line(current))
            lastControl = nil
        case ascii("C"):
            let control1 = try point()
            let control2 = try point()
            let target = try point()
            commands.append(.cubic(target, control1: control1, control2: control2))
            current = target
            lastControl = control2
        case ascii("S"):
            let control2 = try point()
            let target = try point()
            let control1 = reflected(.cubic)
            commands.append(.cubic(target, control1: control1, control2: control2))
            current = target
            lastControl = control2
        case ascii("Q"):
            let control = try point()
            let target = try point()
            commands.append(.quad(target, control: control))
            current = target
            lastControl = control
        case ascii("T"):
            let target = try point()
            let control = reflected(.quad)
            commands.append(.quad(target, control: control))
            current = target
            lastControl = control
        case ascii("A"):
            let rx = try number()
            let ry = try number()
            let rotation = try number()
            let large = try flag()
            let sweep = try flag()
            let target = try point()
            arc(to: target, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
            current = target
            lastControl = nil
        case ascii("Z"):
            commands.append(.close)
            current = start
            lastControl = nil
        default:
            throw Diagnostic(
                "\"d\" uses command \(Diagnostic.quote(String(decoding: [command], as: UTF8.self))), which is not supported (commands: M L H V C S Q T A Z)"
            )
        }
    }

    private enum Curve { case cubic, quad }

    /// The last control point mirrored through the current point when the previous segment is the same kind
    /// of curve, else the current point, as SVG defines S and T.
    private func reflected(_ curve: Curve) -> CGPoint {
        guard let lastControl, let previous = commands.last else { return current }
        switch (previous, curve) {
        case (.cubic, .cubic), (.quad, .quad):
            return CGPoint(x: 2 * current.x - lastControl.x, y: 2 * current.y - lastControl.y)
        default:
            return current
        }
    }

    private mutating func arc(
        to end: CGPoint, rx rxIn: Double, ry ryIn: Double, rotation: Double, large: Bool, sweep: Bool
    ) {
        let begin = current
        guard begin != end else { return }
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        guard rx > 0, ry > 0 else {
            commands.append(.line(end))
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (begin.x - end.x) / 2
        let dy = (begin.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = (large != sweep ? 1 : -1) * max(0, numerator / denominator).squareRoot()
        let cxp = coefficient * (rx * y1 / ry)
        let cyp = coefficient * -(ry * x1 / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (begin.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (begin.y + end.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let length = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            let unsigned = acos(min(max(dot / length, -1), 1))
            return ux * vy - uy * vx < 0 ? -unsigned : unsigned
        }
        let theta = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let handle = 4.0 / 3.0 * tan(step / 4)
        func map(_ px: Double, _ py: Double) -> CGPoint {
            CGPoint(x: cx + rx * px * cosPhi - ry * py * sinPhi, y: cy + rx * px * sinPhi + ry * py * cosPhi)
        }
        for segment in 0..<segments {
            let a1 = theta + Double(segment) * step
            let a2 = a1 + step
            commands.append(
                .cubic(
                    segment == segments - 1 ? end : map(cos(a2), sin(a2)),
                    control1: map(cos(a1) - handle * sin(a1), sin(a1) + handle * cos(a1)),
                    control2: map(cos(a2) + handle * sin(a2), sin(a2) - handle * cos(a2))))
        }
    }

    private mutating func skipSeparators() {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x2C || (0x09...0x0D).contains(bytes[index])
        {
            index += 1
        }
    }

    private mutating func hasNumber() -> Bool {
        skipSeparators()
        guard index < bytes.count else { return false }
        let byte = bytes[index]
        return isDigit(byte) || byte == ascii("-") || byte == ascii("+") || byte == ascii(".")
    }

    private mutating func number() throws(Diagnostic) -> Double {
        skipSeparators()
        let begin = index
        if index < bytes.count, bytes[index] == ascii("-") || bytes[index] == ascii("+") { index += 1 }
        var seenDot = false
        while index < bytes.count {
            let byte = bytes[index]
            if isDigit(byte) {
                index += 1
            } else if byte == ascii("."), !seenDot {
                seenDot = true
                index += 1
            } else if byte == ascii("e") || byte == ascii("E") {
                index += 1
                if index < bytes.count, bytes[index] == ascii("-") || bytes[index] == ascii("+") { index += 1 }
            } else {
                break
            }
        }
        guard let value = Double(String(decoding: bytes[begin..<index], as: UTF8.self)), value.isFinite else {
            index = begin
            throw Diagnostic("\"d\" has \(near()) where a number belongs")
        }
        return value
    }

    private mutating func flag() throws(Diagnostic) -> Bool {
        skipSeparators()
        guard index < bytes.count, bytes[index] == ascii("0") || bytes[index] == ascii("1") else {
            throw Diagnostic("\"d\" has \(near()) where an arc flag (0 or 1) belongs")
        }
        index += 1
        return bytes[index - 1] == ascii("1")
    }

    private func near() -> String {
        guard index < bytes.count else { return "nothing" }
        return Diagnostic.quote(String(decoding: bytes[index..<min(bytes.count, index + 12)], as: UTF8.self))
    }

    private func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
    private func isLetter(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
}

private func ascii(_ scalar: Unicode.Scalar) -> UInt8 { UInt8(scalar.value) }
