import Foundation

indirect enum Expr {
    case lit(JSON)
    case name(String)
    case member(Expr, String)
    case index(Expr, Expr)
    case call(String, [Expr])
    case unary(String, Expr)
    case binary(String, Expr, Expr)
    case ternary(Expr, Expr, Expr)
}

enum Tok: Equatable {
    case num(Double)
    case str(String)
    case ident(String)
    case op(String)
    case end
}

struct ExprParser {
    let src: String
    var toks: [Tok] = []
    var pos = 0

    init(_ src: String) throws {
        self.src = src
        toks = try Self.lex(src)
    }

    static func lex(_ src: String) throws -> [Tok] {
        var out: [Tok] = []
        let cs = Array(src)
        var i = 0
        let ops3 = ["===", "!=="]
        let ops2 = ["==", "!=", "<=", ">=", "&&", "||"]
        while i < cs.count {
            let c = cs[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < cs.count && cs[i + 1].isNumber) {
                var j = i
                while j < cs.count && (cs[j].isNumber || cs[j] == ".") { j += 1 }
                guard let v = Double(String(cs[i..<j])) else { throw LookError("bad number in expression \"\(src)\"") }
                out.append(.num(v)); i = j; continue
            }
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < cs.count && (cs[j].isLetter || cs[j].isNumber || cs[j] == "_" || cs[j] == "$") { j += 1 }
                out.append(.ident(String(cs[i..<j]))); i = j; continue
            }
            if c == "'" || c == "\"" {
                var j = i + 1
                var s = ""
                while j < cs.count && cs[j] != c {
                    if cs[j] == "\\" && j + 1 < cs.count { j += 1 }
                    s.append(cs[j]); j += 1
                }
                guard j < cs.count else { throw LookError("unterminated string in expression \"\(src)\"") }
                out.append(.str(s)); i = j + 1; continue
            }
            if i + 2 < cs.count, ops3.contains(String(cs[i...i + 2])) {
                out.append(.op(String(cs[i...i + 1]))); i += 3; continue
            }
            if i + 1 < cs.count, ops2.contains(String(cs[i...i + 1])) {
                out.append(.op(String(cs[i...i + 1]))); i += 2; continue
            }
            if "+-*/%<>!?:()[],.".contains(c) {
                out.append(.op(String(c))); i += 1; continue
            }
            throw LookError("unexpected character '\(c)' in expression \"\(src)\"")
        }
        out.append(.end)
        return out
    }

    var peek: Tok { toks[pos] }
    mutating func next() -> Tok { let t = toks[pos]; pos += 1; return t }
    mutating func accept(_ op: String) -> Bool {
        if peek == .op(op) { pos += 1; return true }
        return false
    }
    mutating func expect(_ op: String) throws {
        if !accept(op) { throw LookError("expected '\(op)' in expression \"\(src)\"") }
    }

    mutating func parseAll() throws -> Expr {
        let e = try ternary()
        if peek != .end { throw LookError("unexpected token in expression \"\(src)\" (expressions support literals, data paths, + - * / %, comparisons, && || !, ?:, and the functions min max round floor ceil abs clamp len str lerpColor range)") }
        return e
    }

    mutating func ternary() throws -> Expr {
        let c = try binary(0)
        if accept("?") {
            let a = try ternary()
            try expect(":")
            let b = try ternary()
            return .ternary(c, a, b)
        }
        return c
    }

    static let levels: [[String]] = [["||"], ["&&"], ["==", "!="], ["<", "<=", ">", ">="], ["+", "-"], ["*", "/", "%"]]

    mutating func binary(_ level: Int) throws -> Expr {
        if level >= Self.levels.count { return try unary() }
        var lhs = try binary(level + 1)
        while case .op(let o) = peek, Self.levels[level].contains(o) {
            pos += 1
            let rhs = try binary(level + 1)
            lhs = .binary(o, lhs, rhs)
        }
        return lhs
    }

    mutating func unary() throws -> Expr {
        if accept("-") { return .unary("-", try unary()) }
        if accept("!") { return .unary("!", try unary()) }
        return try postfix()
    }

    mutating func postfix() throws -> Expr {
        var e = try primary()
        while true {
            if accept(".") {
                guard case .ident(let n) = next() else { throw LookError("expected a field name after '.' in expression \"\(src)\"") }
                if peek == .op("(") { throw LookError("method calls like .\(n)() are not supported in expression \"\(src)\" (only the functions min max round floor ceil abs clamp len str lerpColor range)") }
                e = .member(e, n)
            } else if accept("[") {
                let i = try ternary()
                try expect("]")
                e = .index(e, i)
            } else {
                return e
            }
        }
    }

    mutating func primary() throws -> Expr {
        switch next() {
        case .num(let v): return .lit(.num(v))
        case .str(let s): return .lit(.str(s))
        case .ident(let n):
            if n == "true" { return .lit(.bool(true)) }
            if n == "false" { return .lit(.bool(false)) }
            if n == "null" { return .lit(.null) }
            if accept("(") {
                var args: [Expr] = []
                if !accept(")") {
                    repeat { args.append(try ternary()) } while accept(",")
                    try expect(")")
                }
                return .call(n, args)
            }
            return .name(n)
        case .op("("):
            let e = try ternary()
            try expect(")")
            return e
        default:
            throw LookError("unexpected token in expression \"\(src)\"")
        }
    }
}

struct Scope {
    var vars: [String: JSON]
}

func truthy(_ v: JSON) -> Bool {
    switch v {
    case .null: return false
    case .bool(let b): return b
    case .num(let n): return n != 0
    case .str(let s): return !s.isEmpty
    default: return true
    }
}

func stringify(_ v: JSON) -> String {
    switch v {
    case .null: return ""
    case .bool(let b): return b ? "true" : "false"
    case .num(let n): return formatNumber(n)
    case .str(let s): return s
    default: return v.brief
    }
}

func jsonEqual(_ a: JSON, _ b: JSON) -> Bool {
    switch (a, b) {
    case (.null, .null): return true
    case (.bool(let x), .bool(let y)): return x == y
    case (.num(let x), .num(let y)): return x == y
    case (.str(let x), .str(let y)): return x == y
    default: return false
    }
}

func parseHex(_ s: String) -> (Double, Double, Double, Double)? {
    guard s.hasPrefix("#") else { return nil }
    var h = String(s.dropFirst())
    if h.count == 3 || h.count == 4 { h = h.map { "\($0)\($0)" }.joined() }
    guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
    if h.count == 6 {
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255, 1)
    }
    return (Double((v >> 24) & 0xff) / 255, Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
}

func evalExpr(_ e: Expr, _ scope: Scope, _ src: String) throws -> JSON {
    func num(_ v: JSON, _ what: String) throws -> Double {
        guard case .num(let n) = v else { throw LookError("\(what) needs a number, got \(v.brief) in expression \"\(src)\"") }
        return n
    }
    switch e {
    case .lit(let v): return v
    case .name(let n):
        guard let v = scope.vars[n] else {
            throw LookError("unknown name '\(n)' in expression \"\(src)\" (known names: \(scope.vars.keys.sorted().joined(separator: ", ")))")
        }
        return v
    case .member(let base, let field):
        let b = try evalExpr(base, scope, src)
        guard case .obj(let d) = b else {
            if case .arr = b, field == "length" { throw LookError("use len(list) instead of .length in expression \"\(src)\"") }
            throw LookError("cannot read .\(field) of \(b.brief) in expression \"\(src)\"")
        }
        guard let v = d[field] else {
            throw LookError("no field '\(field)' in expression \"\(src)\" (fields here: \(d.keys.sorted().joined(separator: ", ")))")
        }
        return v
    case .index(let base, let idx):
        let b = try evalExpr(base, scope, src)
        let i = try evalExpr(idx, scope, src)
        switch (b, i) {
        case (.arr(let a), .num(let n)):
            let k = Int(n)
            guard Double(k) == n, k >= 0, k < a.count else {
                throw LookError("index \(formatNumber(n)) is out of range for a list of \(a.count) in expression \"\(src)\"")
            }
            return a[k]
        case (.obj(let d), .str(let k)):
            guard let v = d[k] else { throw LookError("no field '\(k)' in expression \"\(src)\"") }
            return v
        default:
            throw LookError("cannot index \(b.brief) with \(i.brief) in expression \"\(src)\"")
        }
    case .unary(let op, let x):
        let v = try evalExpr(x, scope, src)
        if op == "!" { return .bool(!truthy(v)) }
        return .num(-(try num(v, "unary -")))
    case .ternary(let c, let a, let b):
        return truthy(try evalExpr(c, scope, src)) ? try evalExpr(a, scope, src) : try evalExpr(b, scope, src)
    case .binary(let op, let l, let r):
        if op == "&&" {
            if !truthy(try evalExpr(l, scope, src)) { return .bool(false) }
            return .bool(truthy(try evalExpr(r, scope, src)))
        }
        if op == "||" {
            if truthy(try evalExpr(l, scope, src)) { return .bool(true) }
            return .bool(truthy(try evalExpr(r, scope, src)))
        }
        let a = try evalExpr(l, scope, src)
        let b = try evalExpr(r, scope, src)
        switch op {
        case "==": return .bool(jsonEqual(a, b))
        case "!=": return .bool(!jsonEqual(a, b))
        case "+":
            if case .str = a { return .str(stringify(a) + stringify(b)) }
            if case .str = b { return .str(stringify(a) + stringify(b)) }
            return .num(try num(a, "+") + (try num(b, "+")))
        case "-": return .num(try num(a, "-") - (try num(b, "-")))
        case "*": return .num(try num(a, "*") * (try num(b, "*")))
        case "/":
            let d = try num(b, "/")
            if d == 0 { throw LookError("division by zero in expression \"\(src)\"") }
            return .num(try num(a, "/") / d)
        case "%":
            let d = try num(b, "%")
            if d == 0 { throw LookError("division by zero in expression \"\(src)\"") }
            return .num((try num(a, "%")).truncatingRemainder(dividingBy: d))
        case "<", "<=", ">", ">=":
            if case .str(let x) = a, case .str(let y) = b {
                return .bool(op == "<" ? x < y : op == "<=" ? x <= y : op == ">" ? x > y : x >= y)
            }
            let x = try num(a, op), y = try num(b, op)
            return .bool(op == "<" ? x < y : op == "<=" ? x <= y : op == ">" ? x > y : x >= y)
        default: throw LookError("unknown operator \(op) in expression \"\(src)\"")
        }
    case .call(let fn, let argExprs):
        let args = try argExprs.map { try evalExpr($0, scope, src) }
        func need(_ n: Int) throws {
            if args.count != n { throw LookError("\(fn)() takes \(n) argument\(n == 1 ? "" : "s"), got \(args.count) in expression \"\(src)\"") }
        }
        switch fn {
        case "min", "max":
            if args.isEmpty { throw LookError("\(fn)() needs at least one argument in expression \"\(src)\"") }
            let ns = try args.map { try num($0, fn) }
            return .num(fn == "min" ? ns.min()! : ns.max()!)
        case "round": try need(1); return .num((try num(args[0], fn)).rounded())
        case "floor": try need(1); return .num((try num(args[0], fn)).rounded(.down))
        case "ceil": try need(1); return .num((try num(args[0], fn)).rounded(.up))
        case "abs": try need(1); return .num(abs(try num(args[0], fn)))
        case "clamp":
            try need(3)
            return .num(min(max(try num(args[0], fn), try num(args[1], fn)), try num(args[2], fn)))
        case "len":
            try need(1)
            if case .arr(let a) = args[0] { return .num(Double(a.count)) }
            if case .str(let s) = args[0] { return .num(Double(s.count)) }
            throw LookError("len() needs a list or string, got \(args[0].brief) in expression \"\(src)\"")
        case "str": try need(1); return .str(stringify(args[0]))
        case "range":
            try need(1)
            let n = try num(args[0], fn)
            guard n >= 0, n <= 500 else { throw LookError("range(n) needs 0 <= n <= 500, got \(formatNumber(n)) in expression \"\(src)\"") }
            return .arr((0..<Int(n)).map { .num(Double($0)) })
        case "lerpColor":
            try need(3)
            guard case .str(let ca) = args[0], case .str(let cb) = args[1], let x = parseHex(ca), let y = parseHex(cb) else {
                throw LookError("lerpColor(a, b, t) needs two hex colors, got \(args[0].brief) and \(args[1].brief) in expression \"\(src)\"")
            }
            let t = min(max(try num(args[2], fn), 0), 1)
            func mix(_ p: Double, _ q: Double) -> Int { Int(((p + (q - p) * t) * 255).rounded()) }
            return .str(String(format: "#%02X%02X%02X%02X", mix(x.0, y.0), mix(x.1, y.1), mix(x.2, y.2), mix(x.3, y.3)))
        default:
            throw LookError("unknown function '\(fn)' in expression \"\(src)\" (available: min max round floor ceil abs clamp len str lerpColor range)")
        }
    }
}

func evalSource(_ src: String, _ scope: Scope) throws -> JSON {
    var p = try ExprParser(src)
    let e = try p.parseAll()
    return try evalExpr(e, scope, src)
}
