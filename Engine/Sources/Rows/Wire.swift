import Foundation
import Spec

// The wire format of docs/engine/WIRE.md: one JSON object per row change, and the page a pull returns.
// Decoding is strict, so the Swift and TypeScript readers of Engine/Vectors/wire.json agree on every case: each
// object has exactly its keys, ids are lowercase, integers have no fraction, and a page decodes whole or not at
// all. Limits that merging enforces (text length, clock skew) are not decoding errors. A number is always finite
// here: `JSONValue.parse` refuses one too large for a Double, and a key twice in one object, as invalid JSON.

/// A page of the account's changes, as `GET /v1/changes` returns it.
package struct Page: Sendable, Equatable {
    package struct Entry: Sendable, Equatable {
        /// The change's id in the server's `changes` table. Strictly increasing through a page.
        package let id: Int64
        package let change: Stamped
    }

    /// The account's automation replica, which joins `mine`.
    package let replica: String
    package let changes: [Entry]
    /// When the server next expects to write a change for the account, or nil when it expects none.
    package let nextWrite: Date?

    /// Decodes a page, or says in one line why it is not one. One entry that does not decode refuses the page.
    package init(json: Data) throws(Diagnostic) {
        let fields = try Fields(try JSONValue.parse(json), keys: ["changes", "nextWrite", "replica"], what: "a page")
        replica = try fields.uuid("replica")
        nextWrite = try fields.optionalInteger("nextWrite", in: Wire.instants).map { date($0) }
        guard case .array(let items) = fields["changes"] else {
            throw Diagnostic("\"changes\" must be a list, not \(fields["changes"].described)")
        }
        var changes: [Entry] = []
        for (index, item) in items.enumerated() {
            do throws(Diagnostic) {
                let entry = try Fields(item, keys: ["change", "id"], what: "an entry")
                let id = try entry.integer("id", in: 1...Wire.largestInteger)
                if let last = changes.last, id <= last.id {
                    throw Diagnostic("id \(id) does not follow id \(last.id); ids increase through a page")
                }
                changes.append(Entry(id: id, change: try Stamped(wire: entry["change"])))
            } catch {
                throw error.within("changes[\(index)]")
            }
        }
        self.changes = changes
    }
}

extension Stamped {
    /// One change as the wire writes it: `insertRow`, `setCell`, or `deleteRow`. Nothing else crosses the wire
    /// yet; phase 4 adds the account changes.
    package init(wire value: JSONValue) throws(Diagnostic) {
        guard case .object(let members) = value, case .string(let op)? = members["op"] else {
            throw Diagnostic("a change must be an object with an \"op\", not \(value.described)")
        }
        let common = ["dataset", "op", "replica", "row", "stamp"]
        let fields: Fields
        switch op {
        case "insertRow": fields = try Fields(value, keys: common + ["at", "day"], what: "a change")
        case "setCell": fields = try Fields(value, keys: common + ["field", "kind", "value"], what: "a change")
        case "deleteRow": fields = try Fields(value, keys: common, what: "a change")
        default:
            throw Diagnostic("\"op\" must be insertRow, setCell, or deleteRow, not \(Diagnostic.quote(op))")
        }
        let row = try fields.rowKey("row")
        let dataset = try fields.dataset("dataset")
        let change: Change
        switch op {
        case "insertRow":
            change = .insertRow(
                row, dataset: dataset, day: Day(index: Int(try fields.integer("day", in: Wire.days))),
                at: try fields.integer("at", in: Wire.instants))
        case "setCell":
            let field = try fields.string("field")
            guard Spec.FieldID.accepts(field) else {
                throw Diagnostic(
                    "\"field\" must be a field id (a lowercase letter, then letters and digits, at most 32), not \(Diagnostic.quote(field))"
                )
            }
            change = .setCell(row, dataset: dataset, field: field, try fields.cell())
        default:
            change = .deleteRow(row, dataset: dataset)
        }
        self.init(change: change, stamp: try fields.stamp("stamp"), replica: try fields.uuid("replica"))
    }
}

private enum Wire {
    /// The largest integer a JSON number holds exactly in JavaScript, 2^53 - 1.
    static let largestInteger: Int64 = 9_007_199_254_740_991
    /// Milliseconds from 1970-01-01T00:00:00Z through the end of 9999.
    static let instants: ClosedRange<Int64> = 0...253_402_300_799_999
    /// Day indexes from 0001-01-01 through 9999-12-31.
    static let days: ClosedRange<Int64> = -719_162...2_932_896
}

/// One JSON object with exactly `keys`, read key by key.
private struct Fields {
    private let members: [String: JSONValue]

    init(_ value: JSONValue, keys: [String], what: String) throws(Diagnostic) {
        guard case .object(let members) = value else {
            throw Diagnostic("\(what) must be an object, not \(value.described)")
        }
        if let missing = keys.first(where: { members[$0] == nil }) { throw Diagnostic("needs \"\(missing)\"") }
        if let extra = members.keys.sorted().first(where: { !keys.contains($0) }) {
            throw Diagnostic("unknown key \(Diagnostic.quote(extra)) (keys: \(keys.joined(separator: ", ")))")
        }
        self.members = members
    }

    subscript(key: String) -> JSONValue { members[key] ?? .null }

    func string(_ key: String) throws(Diagnostic) -> String {
        guard case .string(let text) = self[key] else {
            throw Diagnostic("\"\(key)\" must be a string, not \(self[key].described)")
        }
        return text
    }

    func integer(_ key: String, in range: ClosedRange<Int64>) throws(Diagnostic) -> Int64 {
        guard case .number(let number) = self[key], let integer = Int64(exactly: number), range.contains(integer) else {
            throw Diagnostic(
                "\"\(key)\" must be a whole number from \(range.lowerBound) through \(range.upperBound), not \(self[key].described)"
            )
        }
        return integer
    }

    func optionalInteger(_ key: String, in range: ClosedRange<Int64>) throws(Diagnostic) -> Int64? {
        self[key] == .null ? nil : try integer(key, in: range)
    }

    /// Any UUID, written lowercase with hyphens: `8-4-4-4-12` hex digits.
    func uuid(_ key: String) throws(Diagnostic) -> String {
        let text = try string(key)
        let hex = Set("0123456789abcdef")
        let shape =
            text.count == 36
            && text.enumerated().allSatisfy { offset, character in
                [8, 13, 18, 23].contains(offset) ? character == "-" : hex.contains(character)
            }
        guard shape else {
            throw Diagnostic(
                "\"\(key)\" must be a lowercase UUID like 3f6c1d2e-8b4a-4c9e-9d7f-2a1b3c4d5e6f, not \(Diagnostic.quote(text))"
            )
        }
        return text
    }

    /// A UUIDv7: version nibble 7 and variant bits 10.
    func rowKey(_ key: String) throws(Diagnostic) -> RowKey {
        let text = try uuid(key)
        let characters = Array(text)
        guard characters[14] == "7", "89ab".contains(characters[19]), let row = RowKey(parsing: text) else {
            throw Diagnostic("\"\(key)\" must be a UUIDv7, not \(Diagnostic.quote(text))")
        }
        return row
    }

    func dataset(_ key: String) throws(Diagnostic) -> DatasetKey {
        guard let dataset = DatasetKey(parsing: try uuid(key)) else {
            throw Diagnostic("\"\(key)\" must be a lowercase UUID")
        }
        return dataset
    }

    /// Decimal digits of a non-negative 64-bit integer, with no sign and no leading zero.
    func stamp(_ key: String) throws(Diagnostic) -> Stamp {
        let text = try string(key)
        guard (1...19).contains(text.utf8.count), text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
            text == "0" || !text.hasPrefix("0"), let raw = Int64(text)
        else {
            throw Diagnostic(
                "\"\(key)\" must be a 64-bit stamp in decimal digits with no leading zero, like \"117635678208000000\", not \(Diagnostic.quote(text))"
            )
        }
        return Stamp(raw: raw)
    }

    /// A cell from `kind` and `value`.
    func cell() throws(Diagnostic) -> Spec.Cell {
        let kind = try string("kind")
        let value = self["value"]
        switch (kind, value) {
        case ("text", .string(let text)): return .text(text)
        case ("number", .number(let number)): return .number(number)
        case ("bool", .bool(let flag)): return .bool(flag)
        case ("date", _): return .date(Day(index: Int(try integer("value", in: Wire.days))))
        case ("text", _): throw Diagnostic("a text cell's \"value\" must be a string, not \(value.described)")
        case ("number", _): throw Diagnostic("a number cell's \"value\" must be a number, not \(value.described)")
        case ("bool", _): throw Diagnostic("a bool cell's \"value\" must be true or false, not \(value.described)")
        default:
            throw Diagnostic("\"kind\" must be text, number, bool, or date, not \(Diagnostic.quote(kind))")
        }
    }
}
