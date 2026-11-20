import Foundation

struct LookError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

indirect enum JSON {
    case null
    case bool(Bool)
    case num(Double)
    case str(String)
    case arr([JSON])
    case obj([String: JSON])

    static func parse(_ data: Data, what: String) throws -> JSON {
        do {
            let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return from(any)
        } catch {
            let ns = error as NSError
            let detail = (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription
            throw LookError("\(what) is not valid JSON: \(detail)")
        }
    }

    static func from(_ any: Any) -> JSON {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .num(n.doubleValue)
        case let s as String: return .str(s)
        case let a as [Any]: return .arr(a.map(from))
        case let o as [String: Any]: return .obj(o.mapValues(from))
        default: return .null
        }
    }

    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .num: return "number"
        case .str: return "string"
        case .arr: return "list"
        case .obj: return "object"
        }
    }

    var brief: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .num(let n): return formatNumber(n)
        case .str(let s): return "\"\(s.prefix(40))\""
        case .arr(let a): return "a list of \(a.count)"
        case .obj: return "an object"
        }
    }
}

func formatNumber(_ n: Double) -> String {
    if n.isNaN || n.isInfinite { return "\(n)" }
    if n == n.rounded() && abs(n) < 1e15 { return String(Int64(n)) }
    var s = String(format: "%.4f", n)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}
