import Foundation
import Rows
import Spec
import Synchronization
import Testing

/// Engine/Vectors/wire.json, which the Worker's tests read too, so the two readers of docs/engine/WIRE.md agree
/// on every case.
let wireVectors: JSONValue = {
    do {
        return try JSONValue.parse(Data(contentsOf: engineDirectory.appending(path: "Vectors/wire.json")))
    } catch {
        preconditionFailure("Engine/Vectors/wire.json does not parse: \(error)")
    }
}()

/// Each case in a section of the vectors, as (name, case).
func vectors(_ section: String) -> [(name: String, value: JSONValue)] {
    guard case .array(let items) = wireVectors[section] else { return [] }
    return items.map { (($0["name"]).text ?? "", $0) }
}

extension JSONValue {
    subscript(key: String) -> JSONValue {
        if case .object(let members) = self { members[key] ?? .null } else { .null }
    }

    var text: String? { if case .string(let text) = self { text } else { nil } }

    var integer: Int64? { if case .number(let number) = self { Int64(exactly: number) } else { nil } }

    var data: Data { encoded() }

    /// An object with one member replaced.
    func with(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var members) = self else { return self }
        members[key] = value
        return .object(members)
    }
}

/// An instant written as ISO 8601 with milliseconds, as milliseconds since 1970.
func milliseconds(iso: String) throws -> Int64 {
    let date = try Date(iso, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    return Int64((date.timeIntervalSince1970 * 1000).rounded())
}

func moment(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
}

/// Refused with a line containing the case's `error`, so a bad case cannot pass by failing for another reason.
func refused<T>(_ name: String, _ vector: JSONValue, _ decode: () throws -> T) {
    guard let fragment = vector["error"].text, !fragment.isEmpty else {
        Issue.record("\(name) names no error")
        return
    }
    do {
        _ = try decode()
        Issue.record("\(name) decoded")
    } catch let error as Diagnostic {
        #expect(error.line.contains(fragment), "\(name): \(error.line)")
    } catch {
        Issue.record("\(name) threw \(error)")
    }
}

@Suite struct WireTests {
    /// The first change of the vectors, for cases that vary one value of a valid change.
    let insert = vectors("changes")[0].value["wire"]

    @Test func everySectionHasCases() {
        for section in ["stamps", "badStamps", "days", "keys", "badKeys", "changes", "badChanges", "pages", "badPages"]
            + ["receive"]
        {
            #expect(!vectors(section).isEmpty, "\(section)")
        }
        #expect(wireVectors["format"] == .number(1))
    }

    @Test func stampsAreMillisecondsAboveASixteenBitCounter() throws {
        for (name, stamp) in vectors("stamps") {
            let ms = try #require(stamp["ms"].integer, "\(name)")
            let counter = try #require(stamp["counter"].integer, "\(name)")
            let decoded = try Stamped(wire: insert.with("stamp", stamp["stamp"])).stamp
            #expect(decoded == Stamp(raw: ms << 16 | counter), "\(name)")
            #expect(decoded.milliseconds == ms, "\(name)")
            #expect(String(decoded.raw) == stamp["stamp"].text, "\(name)")
        }
        for (name, stamp) in vectors("badStamps") {
            refused(name, stamp) { try Stamped(wire: insert.with("stamp", stamp["stamp"])) }
        }
    }

    /// A server writes a row's `day` as the day of its `at` in the automation's time zone, and the phone reads
    /// days the same way: `Today` in a calendar of that zone.
    @Test func aRowsDayIsTheDayOfItsInstantInItsTimeZone() throws {
        for (name, vector) in vectors("days") {
            let zone = try #require(vector["timeZone"].text.flatMap(TimeZone.init(identifier:)), "\(name)")
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let today = Today(at: moment(try #require(vector["at"].integer)), calendar: calendar)
            #expect(Int64(today.day.index) == vector["day"].integer, "\(name)")
            #expect(today.day.iso == vector["date"].text, "\(name)")
        }
    }

    @Test func rowKeysAreLowercaseUUIDv7s() throws {
        for (name, vector) in vectors("keys") {
            let decoded = try Stamped(wire: insert.with("row", vector["key"]))
            guard case .insertRow(let row, _, _, _) = decoded.change else { throw Unexpected() }
            #expect(row.raw == vector["key"].text, "\(name)")
            let prefix = row.raw.replacing("-", with: "").prefix(12)
            #expect(Int64(prefix, radix: 16) == vector["ms"].integer, "\(name): the first 48 bits are milliseconds")
        }
        for (name, vector) in vectors("badKeys") {
            refused(name, vector) { try Stamped(wire: insert.with("row", vector["key"])) }
        }
    }

    @Test func everyChangeDecodesToWhatItMeans() throws {
        for (name, vector) in vectors("changes") {
            #expect(try Stamped(wire: vector["wire"]) == (try meaning(vector["means"])), "\(name)")
        }
    }

    @Test func everyBadChangeIsRefused() {
        for (name, vector) in vectors("badChanges") {
            refused(name, vector) { try Stamped(wire: vector["wire"]) }
        }
    }

    @Test func everyPageDecodes() throws {
        for (name, vector) in vectors("pages") {
            let wire = vector["wire"]
            let page = try Page(json: wire.data)
            #expect(page.replica == wire["replica"].text, "\(name)")
            #expect(
                page.nextWrite.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } == wire["nextWrite"].integer)
            guard case .array(let entries) = wire["changes"] else { throw Unexpected() }
            #expect(page.changes.map(\.id) == entries.compactMap { $0["id"].integer }, "\(name)")
            #expect(page.changes.map(\.change) == (try entries.map { try Stamped(wire: $0["change"]) }), "\(name)")
        }
    }

    /// A case given as `text` is raw bytes: a number too large for a 64-bit float, or a key twice in one
    /// object, which no parsed value can hold.
    @Test func everyBadPageIsRefusedWhole() {
        for (name, vector) in vectors("badPages") {
            refused(name, vector) { try Page(json: vector["text"].text.map { Data($0.utf8) } ?? vector["wire"].data) }
        }
    }

    @Test func aBadEntryNamesItsPlaceInThePage() throws {
        let bad = try #require(vectors("badPages").first { $0.name.hasPrefix("one change") }).value["wire"]
        do {
            _ = try Page(json: bad.data)
            Issue.record("the page decoded")
        } catch {
            #expect(error.line.hasPrefix("changes[1]: "), "\(error.line)")
        }
    }

    /// Each scenario's pages received in order by a fresh store whose widget reads the vectors' dataset: the
    /// watermark, whether the commit hook ran, what was held and refused after each page, then the rows a list
    /// shows at `readAt`, each with whether it counts as the person's.
    @Test(arguments: vectors("receive").map(\.name)) func aScenarioMergesAsTheVectorsSay(_ name: String) throws {
        let scenario = try #require(vectors("receive").first { $0.name == name }).value
        let fields = scenario["fields"]
        let spec = try parse(
            String(
                decoding: JSONValue.object([
                    "name": .string("Vectors"), "look": .string("function render(ctx) { return { type: 'spacer' }; }"),
                    "tables": .object(["words": .object(["fields": fields])]),
                    "queries": .object([
                        "all": .object([
                            "list": .string("words"), "sort": .string("oldest"), "limit": .number(100),
                            "window": .string("all"),
                        ])
                    ]),
                ]).encoded(), as: UTF8.self))
        let commits = Mutex(0)
        let store = try RowStore.open(
            directory: temporaryDirectory(), onCommit: { commits.withLock { $0 += 1 } }, isScratch: true)
        let widget = WidgetKey.mint()
        let table = try #require(spec.table(named: "words"))
        let pages = try scenario["steps"].items.map { try Page(json: $0["page"].data) }
        let dataset = pages.flatMap(\.changes).compactMap(datasetOf).first ?? .mint()
        try store.bind(widget, table: table.id, to: dataset)

        for (index, step) in scenario["steps"].items.enumerated() {
            let before = commits.withLock { $0 }
            let received = try store.receive(
                try Page(json: step["page"].data), now: moment(try #require(step["now"].integer)))
            let context = "\(name), step \(index + 1)"
            #expect(try store.watermark() == step["watermark"].integer, "\(context)")
            #expect((commits.withLock { $0 } > before) == (step["changed"] == .bool(true)), "\(context)")
            #expect(Int64(received.held.count) == step["held"].integer, "\(context)")
            #expect(Int64(received.refused.count) == step["refused"].integer, "\(context)")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let query = try #require(spec.queries.first)
        let today = Today(at: moment(try #require(scenario["readAt"].integer)), calendar: calendar)
        guard case .rows(let rows)? = try store.results(of: [query], widget: widget, today: today)[query.id] else {
            throw Unexpected()
        }
        let expected = scenario["rows"].items
        #expect(rows.map(\.key.raw) == expected.compactMap { $0["row"].text }, "\(name)")
        for (row, want) in zip(rows, expected) {
            #expect(row.day.iso == want["day"].text, "\(name)")
            #expect(Int64((row.at.timeIntervalSince1970 * 1000).rounded()) == want["at"].integer, "\(name)")
            #expect(.object(row.fields.mapValues(\.wire)) == want["cells"], "\(name)")
            #expect(want["mine"] == .bool(row.by.me), "\(name): who counts as the person")
        }
    }
}

struct Unexpected: Error {}

private func datasetOf(_ entry: Page.Entry) -> DatasetKey? {
    switch entry.change.change {
    case .insertRow(_, let dataset, _, _), .setCell(_, let dataset, _, _), .deleteRow(_, let dataset): dataset
    default: nil
    }
}

/// The change a vector's `means` describes, in readable units: a stamp's milliseconds and counter, a day or
/// date as `YYYY-MM-DD`, and `at` as ISO 8601.
private func meaning(_ means: JSONValue) throws -> Stamped {
    let row = try #require(means["row"].text.flatMap(RowKey.init(parsing:)))
    let dataset = try #require(means["dataset"].text.flatMap(DatasetKey.init(parsing:)))
    let change: Change
    switch means["op"].text {
    case "insertRow":
        change = .insertRow(
            row, dataset: dataset, day: try #require(means["day"].text.flatMap(Day.init(iso:))),
            at: try milliseconds(iso: try #require(means["at"].text)))
    case "setCell":
        let cell: Spec.Cell =
            if case .string(let text) = means["text"] {
                .text(text)
            } else if case .number(let number) = means["number"] {
                .number(number)
            } else if case .bool(let flag) = means["bool"] {
                .bool(flag)
            } else {
                .date(try #require(means["date"].text.flatMap(Day.init(iso:))))
            }
        change = .setCell(row, dataset: dataset, field: try #require(means["field"].text), cell)
    default:
        change = .deleteRow(row, dataset: dataset)
    }
    let ms = try #require(means["ms"].integer)
    let counter = try #require(means["counter"].integer)
    return Stamped(change: change, stamp: Stamp(raw: ms << 16 | counter), replica: try #require(means["replica"].text))
}

extension JSONValue {
    var items: [JSONValue] { if case .array(let items) = self { items } else { [] } }
}

extension Spec.Cell {
    /// The value as the wire writes it.
    var wire: JSONValue {
        switch self {
        case .text(let text): .string(text)
        case .number(let number): .number(number)
        case .bool(let flag): .bool(flag)
        case .date(let day): .number(Double(day.index))
        }
    }
}
