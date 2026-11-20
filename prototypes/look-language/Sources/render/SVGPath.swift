import SwiftUI

func parseSVGPath(_ d: String) throws -> Path {
    let cs = Array(d)
    var i = 0

    func skipSep() {
        while i < cs.count, cs[i].isWhitespace || cs[i] == "," { i += 1 }
    }
    func hasNumber() -> Bool {
        skipSep()
        guard i < cs.count else { return false }
        return cs[i].isNumber || cs[i] == "-" || cs[i] == "+" || cs[i] == "."
    }
    func number() throws -> CGFloat {
        skipSep()
        let start = i
        if i < cs.count, cs[i] == "-" || cs[i] == "+" { i += 1 }
        var seenDot = false
        while i < cs.count {
            if cs[i].isNumber { i += 1 }
            else if cs[i] == ".", !seenDot { seenDot = true; i += 1 }
            else if cs[i] == "e" || cs[i] == "E" {
                i += 1
                if i < cs.count, cs[i] == "-" || cs[i] == "+" { i += 1 }
            } else { break }
        }
        guard let v = Double(String(cs[start..<i])) else {
            throw LookError("bad number in path data near \"\(String(cs[start..<min(cs.count, start + 12)]))\"")
        }
        return CGFloat(v)
    }
    func flag() throws -> Bool {
        skipSep()
        guard i < cs.count, cs[i] == "0" || cs[i] == "1" else { throw LookError("bad arc flag in path data") }
        i += 1
        return cs[i - 1] == "1"
    }

    var path = Path()
    var cur = CGPoint.zero
    var start = CGPoint.zero
    var lastCtrl: CGPoint?
    var lastCmd: Character = " "

    skipSep()
    while i < cs.count {
        let c = cs[i]
        guard c.isLetter else { throw LookError("unexpected '\(c)' in path data; expected a command letter") }
        i += 1
        let rel = c.isLowercase
        let cmd = Character(c.uppercased())
        func pt() throws -> CGPoint {
            let x = try number(), y = try number()
            return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }
        var first = true
        repeat {
            switch cmd {
            case "M":
                let p = try pt()
                if first { path.move(to: p); start = p } else { path.addLine(to: p) }
                cur = p; lastCtrl = nil
            case "L":
                let p = try pt(); path.addLine(to: p); cur = p; lastCtrl = nil
            case "H":
                let x = try number()
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur); lastCtrl = nil
            case "V":
                let y = try number()
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur); lastCtrl = nil
            case "C":
                let c1 = try pt(), c2 = try pt(), p = try pt()
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; lastCtrl = c2
            case "S":
                let c2 = try pt(), p = try pt()
                let c1 = ("CS".contains(lastCmd) && lastCtrl != nil) ? CGPoint(x: 2 * cur.x - lastCtrl!.x, y: 2 * cur.y - lastCtrl!.y) : cur
                path.addCurve(to: p, control1: c1, control2: c2); cur = p; lastCtrl = c2
            case "Q":
                let c1 = try pt(), p = try pt()
                path.addQuadCurve(to: p, control: c1); cur = p; lastCtrl = c1
            case "T":
                let p = try pt()
                let c1 = ("QT".contains(lastCmd) && lastCtrl != nil) ? CGPoint(x: 2 * cur.x - lastCtrl!.x, y: 2 * cur.y - lastCtrl!.y) : cur
                path.addQuadCurve(to: p, control: c1); cur = p; lastCtrl = c1
            case "A":
                let rx = try number(), ry = try number(), rot = try number()
                let large = try flag(), sweep = try flag()
                let p = try pt()
                addArc(&path, from: cur, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep, to: p)
                cur = p; lastCtrl = nil
            case "Z":
                path.closeSubpath(); cur = start; lastCtrl = nil
            default:
                throw LookError("unsupported path command '\(c)' (supported: M L H V C S Q T A Z)")
            }
            lastCmd = cmd
            first = false
        } while cmd != "Z" && hasNumber()
        skipSep()
    }
    return path
}

func addArc(_ path: inout Path, from p0: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool, to p1: CGPoint) {
    if p0 == p1 { return }
    var rx = abs(rxIn), ry = abs(ryIn)
    if rx == 0 || ry == 0 { path.addLine(to: p1); return }
    let phi = rotation * .pi / 180
    let cosP = cos(phi), sinP = sin(phi)
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let x1 = cosP * dx + sinP * dy
    let y1 = -sinP * dx + cosP * dy
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
    let numer = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let denom = rx * rx * y1 * y1 + ry * ry * x1 * x1
    let coef = (large != sweep ? 1 : -1) * sqrt(max(0, numer / denom))
    let cxp = coef * (rx * y1 / ry)
    let cyp = coef * -(ry * x1 / rx)
    let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
    let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
    func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
        let dot = ux * vx + uy * vy
        let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
        var a = acos(min(max(dot / len, -1), 1))
        if ux * vy - uy * vx < 0 { a = -a }
        return a
    }
    let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
    var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
    if !sweep && delta > 0 { delta -= 2 * .pi }
    if sweep && delta < 0 { delta += 2 * .pi }
    let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
    let step = delta / CGFloat(segments)
    let t = 4.0 / 3.0 * tan(step / 4)
    func map(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
        CGPoint(x: cx + rx * px * cosP - ry * py * sinP, y: cy + rx * px * sinP + ry * py * cosP)
    }
    for s in 0..<segments {
        let a1 = theta1 + CGFloat(s) * step
        let a2 = a1 + step
        let c1 = map(cos(a1) - t * sin(a1), sin(a1) + t * cos(a1))
        let c2 = map(cos(a2) + t * sin(a2), sin(a2) - t * cos(a2))
        path.addCurve(to: map(cos(a2), sin(a2)), control1: c1, control2: c2)
    }
}

struct SVGShape: Shape {
    let source: Path
    let viewBox: CGRect

    func path(in rect: CGRect) -> Path {
        guard viewBox.width > 0, viewBox.height > 0 else { return source }
        let s = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let tx = rect.minX + (rect.width - viewBox.width * s) / 2 - viewBox.minX * s
        let ty = rect.minY + (rect.height - viewBox.height * s) / 2 - viewBox.minY * s
        return source.applying(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty))
    }
}
