import Foundation

func stripBraces(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("{{"), t.hasSuffix("}}"), !t.dropFirst(2).contains("{{") {
        return String(t.dropFirst(2).dropLast(2))
    }
    return t
}

func substituteString(_ s: String, _ scope: Scope) throws -> JSON {
    guard s.contains("{{") else { return .str(s) }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("{{"), t.hasSuffix("}}"), !t.dropFirst(2).contains("{{") {
        return try evalSource(String(t.dropFirst(2).dropLast(2)), scope)
    }
    var out = ""
    var rest = Substring(s)
    while let open = rest.range(of: "{{") {
        out += rest[rest.startIndex..<open.lowerBound]
        guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else {
            throw LookError("unclosed {{ in \"\(s)\"")
        }
        out += stringify(try evalSource(String(rest[open.upperBound..<close.lowerBound]), scope))
        rest = rest[close.upperBound...]
    }
    out += rest
    return .str(out)
}

func substituteValue(_ v: JSON, _ scope: Scope, _ path: String) throws -> JSON {
    switch v {
    case .str(let s): return try substituteString(s, scope)
    case .arr(let a): return .arr(try a.map { try substituteValue($0, scope, path) })
    case .obj(let d):
        if d["type"] != nil {
            let nodes = try expandNode(v, scope, path)
            guard nodes.count == 1 else { throw LookError("\(path) must produce exactly one node, got \(nodes.count)") }
            return nodes[0]
        }
        return .obj(try d.mapValues { try substituteValue($0, scope, path) })
    default: return v
    }
}

func expandList(_ v: JSON?, _ scope: Scope, _ path: String) throws -> [JSON] {
    guard let v else { return [] }
    switch v {
    case .arr(let a):
        var out: [JSON] = []
        for (i, c) in a.enumerated() { out += try expandNode(c, scope, "\(path)[\(i)]") }
        return out
    case .obj: return try expandNode(v, scope, path)
    case .null: return []
    default: throw LookError("\(path) must be a node or a list of nodes, got \(v.brief)")
    }
}

func expandNode(_ node: JSON, _ scope: Scope, _ path: String) throws -> [JSON] {
    guard case .obj(let d) = node else { throw LookError("\(path) must be a node object, got \(node.brief)") }
    guard case .str(let type)? = d["type"] else { throw LookError("\(path) is missing \"type\"") }

    func checkKeys(_ allowed: [String]) throws {
        for k in d.keys.sorted() where !allowed.contains(k) {
            throw LookError("unknown prop \"\(k)\" on \"\(type)\" at \(path) (allowed: \(allowed.joined(separator: ", ")))")
        }
    }

    if type == "repeat" {
        try checkKeys(["type", "over", "item", "index", "children"])
        guard case .str(let overSrc)? = d["over"] else { throw LookError("repeat at \(path) needs \"over\": \"{{ list or range(n) }}\"") }
        let over = try evalSource(stripBraces(overSrc), scope)
        guard case .arr(let items) = over else { throw LookError("repeat \"over\" at \(path) must be a list or range(n), got \(over.brief)") }
        var itemName = "item", indexName = "index"
        if let v = d["item"] { guard case .str(let s) = v else { throw LookError("repeat \"item\" at \(path) must be a name string") }; itemName = s }
        if let v = d["index"] { guard case .str(let s) = v else { throw LookError("repeat \"index\" at \(path) must be a name string") }; indexName = s }
        var out: [JSON] = []
        for (i, it) in items.enumerated() {
            var inner = scope
            inner.vars[itemName] = it
            inner.vars[indexName] = .num(Double(i))
            out += try expandList(d["children"], inner, "\(path).children")
        }
        return out
    }

    if type == "if" {
        try checkKeys(["type", "test", "then", "else"])
        guard case .str(let testSrc)? = d["test"] else { throw LookError("if at \(path) needs \"test\": \"{{ expression }}\"") }
        let test = try evalSource(stripBraces(testSrc), scope)
        return try expandList(truthy(test) ? d["then"] : d["else"], scope, truthy(test) ? "\(path).then" : "\(path).else")
    }

    var out: [String: JSON] = [:]
    for (k, v) in d {
        if k == "children" {
            out[k] = .arr(try expandList(v, scope, "\(path).children"))
        } else {
            out[k] = try substituteValue(v, scope, "\(path).\(k)")
        }
    }
    return [.obj(out)]
}

func expandTemplate(source: Data, scope: Scope) throws -> JSON {
    let raw = try JSON.parse(source, what: "the template")
    let nodes = try expandNode(raw, scope, "root")
    guard nodes.count == 1 else { throw LookError("the root must produce exactly one node, got \(nodes.count)") }
    return nodes[0]
}
