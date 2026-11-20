import Foundation

/// Plain JSON. The one untyped value in the package. It exists only at boundaries (document text, data
/// state files, the tree a look returns) and is parsed into typed values right there.
package enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Strict RFC 8259 JSON. A duplicate key or a number too large for a double is an error, and every
    /// error names its line and column.
    package static func parse(_ data: Data) throws(Diagnostic) -> JSONValue {
        var parser = Parser(bytes: [UInt8](data))
        return try parser.document()
    }

    /// Compact JSON with object keys sorted by their UTF-8 bytes, whole numbers written without a
    /// fraction, and only the escapes JSON requires, so equal values always encode to equal bytes.
    /// JSON has no NaN or infinity, so a non-finite number encodes as `null`.
    package func encoded() -> Data {
        var out: [UInt8] = []
        write(to: &out)
        return Data(out)
    }

    /// How an error line names a value: `the string "6am"`, `the number 3`, `a list`.
    var described: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .number(let value): "the number \(Self.format(value))"
        case .string(let value): "the string \(Diagnostic.quote(value))"
        case .array: "a list"
        case .object: "an object"
        }
    }

    static func format(_ number: Double) -> String {
        guard number.isFinite else { return "null" }
        if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        return "\(number)"
    }

    private func write(to out: inout [UInt8]) {
        switch self {
        case .null: out += "null".utf8
        case .bool(let value): out += (value ? "true" : "false").utf8
        case .number(let value): out += Self.format(value).utf8
        case .string(let value): Self.write(value, to: &out)
        case .array(let items):
            out.append(ascii("["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(ascii(",")) }
                item.write(to: &out)
            }
            out.append(ascii("]"))
        case .object(let members):
            out.append(ascii("{"))
            let keys = members.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out.append(ascii(",")) }
                Self.write(key, to: &out)
                out.append(ascii(":"))
                members[key, default: .null].write(to: &out)
            }
            out.append(ascii("}"))
        }
    }

    private static func write(_ string: String, to out: inout [UInt8]) {
        out.append(ascii("\""))
        for byte in string.utf8 {
            switch byte {
            case ascii("\""): out += "\\\"".utf8
            case ascii("\\"): out += "\\\\".utf8
            case 0x0A: out += "\\n".utf8
            case 0x0D: out += "\\r".utf8
            case 0x09: out += "\\t".utf8
            case 0x08: out += "\\b".utf8
            case 0x0C: out += "\\f".utf8
            case 0..<0x20: out += String(format: "\\u%04x", byte).utf8
            default: out.append(byte)
            }
        }
        out.append(ascii("\""))
    }
}

private func ascii(_ scalar: Unicode.Scalar) -> UInt8 { UInt8(ascii: scalar) }

private func isDigit(_ byte: UInt8) -> Bool { (ascii("0")...ascii("9")).contains(byte) }

private struct Parser {
    static let maxDepth = 256

    let bytes: [UInt8]
    var position = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { position = 3 }
    }

    mutating func document() throws(Diagnostic) -> JSONValue {
        guard String(validating: bytes, as: UTF8.self) != nil else {
            throw Diagnostic("not valid JSON: the text is not UTF-8")
        }
        skipWhitespace()
        guard position < bytes.count else { throw Diagnostic("not valid JSON: the text is empty") }
        let result = try value(depth: 0)
        skipWhitespace()
        guard position == bytes.count else { throw failure("there is more text after the end of the JSON value") }
        return result
    }

    private var current: UInt8? { position < bytes.count ? bytes[position] : nil }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { position += 1 }
    }

    private mutating func value(depth: Int) throws(Diagnostic) -> JSONValue {
        guard depth < Self.maxDepth else { throw failure("values are nested more than \(Self.maxDepth) deep") }
        guard let byte = current else { throw failure("the text ends where a value should be") }
        switch byte {
        case ascii("{"): return try object(depth: depth)
        case ascii("["): return try array(depth: depth)
        case ascii("\""): return .string(try string())
        case ascii("t"): return try literal("true", .bool(true))
        case ascii("f"): return try literal("false", .bool(false))
        case ascii("n"): return try literal("null", .null)
        case ascii("-"), ascii("0")...ascii("9"): return try number()
        case ascii("'"): throw failure("use double quotes for strings, not single quotes")
        case ascii("/"): throw failure("JSON has no comments")
        default: throw failure("expected a value")
        }
    }

    private mutating func literal(_ word: String, _ result: JSONValue) throws(Diagnostic) -> JSONValue {
        let utf8 = Array(word.utf8)
        guard bytes[position...].starts(with: utf8) else { throw failure("expected a value") }
        position += utf8.count
        return result
    }

    private mutating func object(depth: Int) throws(Diagnostic) -> JSONValue {
        position += 1
        var members: [String: JSONValue] = [:]
        skipWhitespace()
        if current == ascii("}") {
            position += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            let keyStart = position
            guard current == ascii("\"") else {
                if current == ascii("}") { throw failure("remove the comma before \"}\"") }
                if current == ascii("'") { throw failure("use double quotes for keys, not single quotes") }
                throw failure("expected a key in double quotes")
            }
            let key = try string()
            skipWhitespace()
            guard current == ascii(":") else {
                throw failure("expected \":\" after the key \(Diagnostic.quote(key))")
            }
            position += 1
            skipWhitespace()
            let member = try value(depth: depth + 1)
            guard members.updateValue(member, forKey: key) == nil else {
                throw failure(at: keyStart, "the key \(Diagnostic.quote(key)) appears twice in one object")
            }
            skipWhitespace()
            if current == ascii(",") {
                position += 1
            } else if current == ascii("}") {
                position += 1
                return .object(members)
            } else {
                throw failure("expected \",\" or \"}\" after the value of \(Diagnostic.quote(key))")
            }
        }
    }

    private mutating func array(depth: Int) throws(Diagnostic) -> JSONValue {
        position += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if current == ascii("]") {
            position += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            if current == ascii("]") { throw failure("remove the comma before \"]\"") }
            items.append(try value(depth: depth + 1))
            skipWhitespace()
            if current == ascii(",") {
                position += 1
            } else if current == ascii("]") {
                position += 1
                return .array(items)
            } else {
                throw failure("expected \",\" or \"]\" after a list item")
            }
        }
    }

    private mutating func string() throws(Diagnostic) -> String {
        position += 1
        var out: [UInt8] = []
        while true {
            guard let byte = current else { throw failure("a string is missing its closing quote") }
            switch byte {
            case ascii("\""):
                position += 1
                return String(decoding: out, as: UTF8.self)
            case ascii("\\"):
                position += 1
                try escape(into: &out)
            case 0x0A:
                throw failure("a string contains a line break; write it as \\n")
            case 0..<0x20:
                throw failure("a string contains a control character; escape it")
            default:
                out.append(byte)
                position += 1
            }
        }
    }

    private mutating func escape(into out: inout [UInt8]) throws(Diagnostic) {
        guard let byte = current else { throw failure("a string is missing its closing quote") }
        position += 1
        switch byte {
        case ascii("\""), ascii("\\"), ascii("/"): out.append(byte)
        case ascii("b"): out.append(0x08)
        case ascii("f"): out.append(0x0C)
        case ascii("n"): out.append(0x0A)
        case ascii("r"): out.append(0x0D)
        case ascii("t"): out.append(0x09)
        case ascii("u"):
            let start = position - 2
            var code = try hex4()
            if (0xD800...0xDBFF).contains(code) {
                guard bytes[position...].starts(with: [ascii("\\"), ascii("u")]) else {
                    throw failure(at: start, "a \\u escape is half of a surrogate pair")
                }
                position += 2
                let low = try hex4()
                guard (0xDC00...0xDFFF).contains(low) else {
                    throw failure(at: start, "a \\u escape is half of a surrogate pair")
                }
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            }
            guard let scalar = Unicode.Scalar(code) else {
                throw failure(at: start, "a \\u escape is half of a surrogate pair")
            }
            out += String(scalar).utf8
        default:
            throw failure(at: position - 2, "\\\(Character(Unicode.Scalar(byte))) is not a JSON escape")
        }
    }

    private mutating func hex4() throws(Diagnostic) -> UInt32 {
        var code: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current, let digit = Character(Unicode.Scalar(byte)).hexDigitValue else {
                throw failure("\\u needs four hex digits")
            }
            code = code * 16 + UInt32(digit)
            position += 1
        }
        return code
    }

    private mutating func number() throws(Diagnostic) -> JSONValue {
        let start = position
        if current == ascii("-") { position += 1 }
        guard let first = current, isDigit(first) else { throw failure("expected a digit") }
        position += 1
        if first == ascii("0"), let next = current, isDigit(next) {
            throw failure(at: start, "a number cannot start with 0")
        }
        skipDigits()
        if current == ascii(".") {
            position += 1
            guard let digit = current, isDigit(digit) else { throw failure("expected a digit after the decimal point") }
            skipDigits()
        }
        if current == ascii("e") || current == ascii("E") {
            position += 1
            if current == ascii("+") || current == ascii("-") { position += 1 }
            guard let digit = current, isDigit(digit) else { throw failure("expected a digit in the exponent") }
            skipDigits()
        }
        let text = String(decoding: bytes[start..<position], as: UTF8.self)
        guard let number = Double(text), number.isFinite else {
            throw failure(at: start, "the number \(text) is too large")
        }
        return .number(number)
    }

    private mutating func skipDigits() {
        while let byte = current, isDigit(byte) { position += 1 }
    }

    private func failure(at offset: Int? = nil, _ message: String) -> Diagnostic {
        var line = 1
        var column = 1
        for byte in bytes[..<min(offset ?? position, bytes.count)] {
            if byte == 0x0A {
                line += 1
                column = 1
            } else if byte & 0xC0 != 0x80 {
                column += 1
            }
        }
        return Diagnostic("not valid JSON at line \(line), column \(column): \(message)")
    }
}
