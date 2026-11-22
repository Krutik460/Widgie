import Foundation
import Rows
import Spec
import Synchronization
import Testing

/// Every test that opens a file store. Serialized, because GRDB's suspension notification reaches every file
/// store in the process.
@Suite(.serialized) struct FileStores {
    let noon = "2026-11-18T12:00:00-05:00"

    @Test func twoPoolsOnOneFileWriteInterleavedWithoutLoss() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try Bench(store: RowStore.open(directory: directory))
        let second = try Bench(store: RowStore.open(directory: directory), widget: first.widget)
        let failures = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 2) { lane in
            let bench = lane == 0 ? first : second
            for _ in 0..<500 {
                do {
                    if try bench.tap("drink", at: noon) != .written { failures.withLock { $0.append("ignored") } }
                } catch {
                    failures.withLock { $0.append("\(error)") }
                }
            }
        }
        #expect(failures.withLock { $0 }.isEmpty)
        #expect(try first.number("glassesAll", at: noon) == 1000)
        #expect(try second.number("glassesAll", at: noon) == 1000)
        let feed = try first.store.feed()
        let inserts = feed.filter { if case .insertRow = $0.change { true } else { false } }
        #expect(inserts.count == 1000)
        #expect(Set(inserts.map(\.stamp)).count == 1000, "one clock: no two writes share a stamp")
        #expect(Set(feed.map(\.replica)).count == 1, "both connections are one replica")
        #expect(Set(try second.store.feed()) == Set(feed))
    }

    @Test func aTapResolvedBeforeAnotherPoolDeletesItsWidgetWritesNothing() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try Bench(store: RowStore.open(directory: directory))
        let second = try RowStore.open(directory: directory)
        let dashboard = try Bench(store: second)
        let glasses = try #require(first.spec.table(named: "glasses")).id
        try second.bind(
            dashboard.widget, table: glasses,
            to: try #require(try first.store.dataset(of: first.widget, table: glasses)))
        _ = try first.store.save(first.widget, spec: first.spec, assets: [:])
        try first.tap("drink", at: noon)
        #expect(try first.store.widget(first.widget) != nil, "the tap found its widget live")

        try second.delete(first.widget)
        #expect(try first.tap("drink", at: noon) == .ignored("widget \(first.widget.raw) was deleted"))
        #expect(try dashboard.number("glassesAll", at: noon) == 1, "the widget sharing the rows shows no new glass")
    }

    @Test func eitherProcessMayOpenAFreshFileFirst() throws {
        for _ in 0..<10 {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let stores = Mutex<[RowStore]>([])
            let failures = Mutex<[String]>([])
            DispatchQueue.concurrentPerform(iterations: 2) { _ in
                do {
                    let store = try RowStore.open(directory: directory)
                    stores.withLock { $0.append(store) }
                } catch {
                    failures.withLock { $0.append("\(error)") }
                }
            }
            #expect(failures.withLock { $0 }.isEmpty)
            let opened = stores.withLock { $0 }
            try #require(opened.count == 2)
            let first = try Bench(store: opened[0])
            let second = try Bench(store: opened[1], widget: first.widget)
            try first.tap("drink", at: noon)
            try second.tap("drink", at: noon)
            #expect(try first.number("glassesAll", at: noon) == 2)
            #expect(Set(try first.store.feed().map(\.replica)).count == 1, "one migration made one replica")
        }
    }

    @Test func reopeningKeepsRowsAndTheReplica() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let widget: WidgetKey
        let before: [Stamped]
        do {
            let bench = try Bench(store: RowStore.open(directory: directory))
            widget = bench.widget
            try bench.tap("add", at: noon)
            before = try bench.store.feed()
        }
        let bench = try Bench(store: RowStore.open(directory: directory), widget: widget)
        #expect(try bench.number("open", at: noon) == 1)
        try bench.tap("drink", at: noon)
        #expect(Set(try bench.store.feed().map(\.replica)) == Set(before.map(\.replica)))
    }

    @Test func aFileFromANewerBuildIsRefused() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let bench = try Bench(store: RowStore.open(directory: directory))
            try bench.tap("drink", at: noon)
        }
        let file = directory.appending(path: "store.sqlite")
        let wal = directory.appending(path: "store.sqlite-wal")
        try #require(
            !FileManager.default.fileExists(atPath: wal.path(percentEncoded: false))
                || (try FileManager.default.attributesOfItem(atPath: wal.path(percentEncoded: false))[.size] as? Int)
                    == 0,
            "the last connection checkpointed the log")
        let handle = try FileHandle(forUpdating: file)
        try handle.seek(toOffset: 60)
        try handle.write(contentsOf: Data([0, 0, 0, 99]))
        try handle.close()
        #expect(throws: StoreError.self) { try RowStore.open(directory: directory) }
    }

    @Test func onCommitRunsAfterEveryWriteAndNotAfterAStaleTap() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let commits = Counter()
        let bench = try Bench(store: RowStore.open(directory: directory) { commits.count.withLock { $0 += 1 } })
        #expect(commits.count.withLock { $0 } == 1, "binding the new widget's tables")
        try bench.store.bind(tablesOf: bench.spec, to: bench.widget)
        #expect(commits.count.withLock { $0 } == 1, "every table was already bound")
        commits.count.withLock { $0 = 0 }
        try bench.tap("drink", at: noon)
        #expect(commits.count.withLock { $0 } == 1)
        let glass = try #require(bench.rows("lastGlass", at: noon).first)
        try bench.tap("undo", row: glass.key, at: noon)
        try bench.tap("undo", row: glass.key, at: noon)
        #expect(commits.count.withLock { $0 } == 2, "the second undo was stale")
        try bench.seed("busy", at: noon)
        _ = try bench.store.save(bench.widget, spec: bench.spec, assets: [:])
        #expect(commits.count.withLock { $0 } == 4)
    }

    /// Suspension is process-wide, so this one test covers both kinds of store and a first open, and opens a
    /// single window in which other suites' writes could fail. A pool opened after the suspend misses GRDB's
    /// notification, so the open itself must refuse.
    @Test func aSuspendedStoreRefusesWritesAndOpensAndStillReadsWhileAScratchStoreKeepsWriting() throws {
        let directory = temporaryDirectory()
        let other = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: other)
        }
        let bench = try Bench(store: RowStore.open(directory: directory))
        let scratch = try Bench(store: RowStore.open(directory: temporaryDirectory(), isScratch: true))
        try bench.tap("drink", at: noon)
        RowStore.suspend()
        defer { RowStore.resume() }
        let refused = #expect(throws: StoreError.self) { try bench.tap("drink", at: noon) }
        #expect(refused?.suspended == true)
        let unopened = #expect(throws: StoreError.self) { try RowStore.open(directory: other) }
        #expect(unopened?.suspended == true)
        #expect(try bench.number("glassesAll", at: noon) == 1)
        #expect(try scratch.tap("drink", at: noon) == .written)
        RowStore.resume()
        #expect(try scratch.number("glassesAll", at: noon) == 1)
        #expect(try bench.tap("drink", at: noon) == .written)
        #expect(try bench.number("glassesAll", at: noon) == 2)
        #expect(try Bench(store: RowStore.open(directory: other)).tap("drink", at: noon) == .written)
    }

    /// 50,000 rows over two years in a file store, then the four reads a habit or log widget makes. Prints
    /// the median, minimum, and maximum of 50 runs of each. Mac numbers, not iPhone numbers.
    @Test func timingOverTwoYearsOfRows() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spec = try parse(
            #"""
            {"name": "Log", "look": "function render(ctx) { return { type: 'spacer' }; }",
             "tables": {"logs": {"fields": {"note": "text"}}},
             "queries": {
               "today": {"count": "logs", "window": "today"},
               "days": {"daily": "logs", "days": 35},
               "streak": {"streak": "logs"},
               "recent": {"list": "logs", "limit": 20, "window": "all"}
             }}
            """#)
        let bench = try Bench(store: RowStore.open(directory: directory), spec: spec)
        let today = try instant(noon)
        let perDay = (0..<730).map { 68 + ($0 < 360 ? 1 : 0) }
        for anchor in stride(from: 0, to: 730, by: 10) {
            let rows = (0..<10).map { offset in
                #"{"daysAgo": \#(offset), "repeat": \#(perDay[anchor + offset]), "note": "Logged"}"#
            }
            let state = try spec.parseState(Data(#"{"logs": [\#(rows.joined(separator: ","))]}"#.utf8), name: "log")
            let date = try #require(bench.calendar.date(byAdding: .day, value: -anchor, to: today))
            try bench.store.seed(state, widget: bench.widget, today: Today(at: date, calendar: bench.calendar))
        }
        #expect(perDay.reduce(0, +) == 50_000)
        #expect(try bench.number("today", at: noon) == 69)
        #expect(try bench.number("streak", at: noon) == 730)
        #expect(try bench.days("days", at: noon).map(\.count) == Array(perDay[0..<35].reversed()))
        let recent = try bench.rows("recent", at: noon)
        #expect(recent.count == 20 && recent.allSatisfy { $0.text("note") == "Logged" })

        let clock = ContinuousClock()
        var report: [String] = []
        for name in ["today", "days", "streak", "recent"] {
            let query = try #require(spec.queries.first { $0.id.raw == name })
            let todayValue = try bench.today(noon)
            var samples: [Double] = []
            for _ in 0..<50 {
                let elapsed = try clock.measure {
                    _ = try bench.store.results(of: [query], widget: bench.widget, today: todayValue)
                }
                samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3)
            }
            samples.sort()
            report.append(
                String(format: "%@ median %.3f ms (min %.3f, max %.3f)", name, samples[25], samples[0], samples[49]))
        }
        print("timing, 50,000 rows over 730 days, 50 runs each:\n  " + report.joined(separator: "\n  "))
    }
}

final class Counter: Sendable {
    let count = Mutex(0)
}
