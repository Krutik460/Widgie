import Foundation
import GRDB
import Spec

/// Everything persisted in the App Group directory: the SQLite database and the asset files.
///
/// Layout:
///     <directory>/store.sqlite (+ -wal, -shm)
///     <directory>/assets/<sha256 hex>      immutable, content-addressed
///
/// Two processes open this at once. The rules that make that safe all live here:
/// - Both open a GRDB `DatabasePool` (WAL) with a busy timeout of 2 s, and both observe GRDB's suspension
///   notifications. The app calls `RowStore.suspend()` and `resume()` on scene phase changes, which is
///   GRDB's mitigation for 0xdead10cc.
/// - Every write is one short `BEGIN IMMEDIATE` transaction. The API is synchronous, so no transaction can
///   span an await.
/// - The replica id and the hybrid logical clock live in the database and advance inside the write
///   transaction, so writes from the app and the extension are totally ordered without any IPC.
/// - Either process may migrate first, because after an app update the extension can open the file first.
/// - The extension writes rows and cells only. Revisions, heads, and asset files are written by the app.
///   Asset files are written (temp file, then rename) before the revision that names them commits.
/// - This target owns content addressing. It hashes asset bytes and revision bodies itself, so a name always
///   matches the bytes it names.
package final class RowStore: Sendable {
    private let database: any DatabaseWriter
    private let directory: URL
    private let ownsDirectory: Bool
    private let onCommit: (@Sendable () -> Void)?

    private init(
        database: any DatabaseWriter, directory: URL, ownsDirectory: Bool, onCommit: (@Sendable () -> Void)?
    ) {
        self.database = database
        self.directory = directory
        self.ownsDirectory = ownsDirectory
        self.onCommit = onCommit
    }

    /// The connections close before the files go, because a stored property outlives `deinit`'s body.
    deinit {
        guard ownsDirectory else { return }
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// `onCommit` runs on the writing thread after every transaction that commits a write. A stale tap
    /// writes nothing and does not run it. With `ownsDirectory` the store deletes `directory` when it is
    /// released, and `suspend()` does not stop its writes.
    ///
    /// Opening and migrating run under a file coordinator, as GRDB's sharing guide prescribes: two
    /// connections switching a new file to WAL at once fail with SQLITE_BUSY, which no busy timeout covers.
    package static func open(
        directory: URL, onCommit: (@Sendable () -> Void)? = nil, ownsDirectory: Bool = false
    ) throws(StoreError) -> RowStore {
        try guarded {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var configuration = Configuration()
            configuration.busyMode = .timeout(2)
            // A store that owns its directory lives in the app's private temporary folder, which no other process
            // opens, so iOS has no shared lock to guard and a background build can keep saving.
            configuration.observesSuspensionNotifications = !ownsDirectory
            configuration.maximumReaderCount = 2
            configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA cache_size = -512") }
            var opened: Result<DatabasePool, any Error>?
            var coordination: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: directory.appending(path: "store.sqlite"), options: .forMerging, error: &coordination
            ) { file in
                opened = Result {
                    let pool = try DatabasePool(path: file.path(percentEncoded: false), configuration: configuration)
                    try migrate(pool)
                    return pool
                }
            }
            if let coordination { throw coordination }
            guard let pool = try opened?.get() else { throw StoreError(message: "the file coordinator never ran") }
            return RowStore(database: pool, directory: directory, ownsDirectory: ownsDirectory, onCommit: onCommit)
        }
    }

    /// An in-memory store with the same schema and write path, and asset files in a temporary directory it
    /// removes when released. Proofs seed states into one of these.
    package static func scratch() throws(StoreError) -> RowStore {
        try guarded {
            let queue = try DatabaseQueue()
            try migrate(queue)
            return RowStore(
                database: queue,
                directory: FileManager.default.temporaryDirectory.appending(path: "rows-\(UUID().uuidString)"),
                ownsDirectory: true, onCommit: nil)
        }
    }

    /// Once suspended, every store in this process that does not own its directory refuses writes (reads
    /// still work), so iOS never finds the app holding a lock on the shared database while suspended. The app
    /// calls this when it moves to the background.
    package static func suspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    package static func resume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    // MARK: Documents (written by the app)

    /// Newest creation first. The order is the "default to the latest creation" policy. Each widget is drawn
    /// from its newest revision that passed its proof on this device (`StoredWidget.revision`), which is the
    /// head once the head is proved. A widget with no such revision, or whose drawn revision this build cannot
    /// read (a newer format arriving by sync), is left out.
    package func widgets() throws(StoreError) -> [StoredWidget] {
        try read { db in
            try Row.fetchAll(db, sql: "\(StoredWidget.select) WHERE w.deleted IS NULL ORDER BY w.created_at DESC")
                .compactMap { try? StoredWidget(row: $0) }
        }
    }

    /// Nil for an unknown or deleted widget, or one with no revision proved here. Throws when the drawn
    /// revision does not parse.
    package func widget(_ key: WidgetKey) throws(StoreError) -> StoredWidget? {
        try read { db in
            try Row.fetchOne(
                db, sql: "\(StoredWidget.select) WHERE w.deleted IS NULL AND w.key = ?", arguments: [key.raw]
            ).map(StoredWidget.init(row:))
        }
    }

    /// Saves a new revision and moves the widget's head to it, creating the widget when `key` is new. Hashes
    /// and writes `assets` first, fills their digests into the spec (`Spec.fillingDigests`), encodes it
    /// (`Spec.encoded`), and names the revision by the hash of those bytes. Saving bytes that already exist
    /// adds nothing but the head move. The caller proved the spec, so the revision is marked proved here.
    package func save(_ key: WidgetKey, spec: Spec, assets: [Spec.AssetID: Data]) throws(StoreError) -> Spec.Digest {
        let digests = try guarded { try assets.mapValues(writeAsset) }
        let body = spec.fillingDigests(digests).encoded()
        let revision = digest(of: body)
        let now = Date()
        try write(at: now) { db in
            try mark(revision, verdict: nil, db)
            return .changes(
                [.putRevision(body: body), .moveHead(key, to: revision, createdAt: milliseconds(now))]
                    + (try newBindings(key, spec, db)))
        }
        return revision
    }

    /// Binds every table of `spec` that `key` has no dataset for to a new dataset, and keeps every existing
    /// binding, including those of tables a later revision dropped, so a restore reconnects their rows. `save`
    /// does this in its own transaction; a proof's scratch store calls it before seeding.
    package func bind(tablesOf spec: Spec, to key: WidgetKey, at instant: Date = Date()) throws(StoreError) {
        try write(at: instant) { db in
            let binds = try newBindings(key, spec, db)
            return binds.isEmpty ? .ignored("every table is bound") : .changes(binds)
        }
    }

    /// Points one table of a widget at an existing dataset, so it reads and writes another widget's rows.
    package func bind(_ key: WidgetKey, table: Spec.TableID, to dataset: DatasetKey) throws(StoreError) {
        try write(at: Date()) { _ in .changes([.bind(key, table: table.raw, to: dataset)]) }
    }

    /// The dataset a table of a widget reads and writes, or nil when it has none.
    package func dataset(of key: WidgetKey, table: Spec.TableID) throws(StoreError) -> DatasetKey? {
        try read { db in try Rows.dataset(of: key, table: table.raw, db) }
    }

    /// Every other live widget that reads a dataset a table of `key` is bound to, with the two table ids.
    /// The builder checks field kinds against each, so widgets sharing rows agree on what a value means.
    package func sharers(of key: WidgetKey) throws(StoreError) -> [Sharer] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT mine.tbl AS mine, theirs.tbl AS theirs, w.key, r.digest, w.created_at, r.body
                    FROM binding mine
                    JOIN binding theirs ON theirs.dataset = mine.dataset AND theirs.widget != mine.widget
                    JOIN widget w ON w.key = theirs.widget AND w.deleted IS NULL
                    JOIN revision r ON r.digest = \(StoredWidget.drawn)
                    WHERE mine.widget = ?
                    ORDER BY w.created_at, mine.tbl
                    """, arguments: [key.raw]
            ).compactMap { row in
                (try? StoredWidget(row: row)).map { Sharer(table: row["mine"], widget: $0, as: row["theirs"]) }
            }
        }
    }

    /// The kinds of the cells already stored in the live rows of each dataset a table of `key` is bound to,
    /// by table id and field id. They come from every writer, deleted widgets and other devices included, so
    /// the builder checks a new kind against them too. A field with no cells is absent and may change kind.
    package func storedKinds(of key: WidgetKey) throws(StoreError) -> [String: [String: Set<Spec.FieldKind>]] {
        try read { db in
            var kinds: [String: [String: Set<Spec.FieldKind>]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT b.tbl, c.field, c.kind FROM binding b
                    JOIN row r ON r.dataset = b.dataset AND r.deleted IS NULL
                    JOIN cell c ON c.row = r.key AND c.dataset = r.dataset
                    WHERE b.widget = ?
                    """, arguments: [key.raw])
            {
                guard let kind = Spec.FieldKind.allCases.first(where: { $0.code == row["kind"] }) else { continue }
                kinds[row["tbl"], default: [:]][row["field"], default: []].insert(kind)
            }
            return kinds
        }
    }

    /// Every revision this widget's head has pointed at, newest first. The first is the current head.
    package func revisions(of key: WidgetKey) throws(StoreError) -> [Revision] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT h.revision, r.saved_at FROM history h JOIN revision r ON r.digest = h.revision
                    WHERE h.widget = ? ORDER BY h.stamp DESC, h.replica DESC
                    """, arguments: [key.raw]
            ).compactMap { row in
                Spec.Digest(hex: row["revision"]).map { Revision(digest: $0, savedAt: date(row["saved_at"])) }
            }
        }
    }

    /// Moves the head back to an earlier revision of the same widget: "undo that change". The widget draws
    /// it only once it is proved here, as any head.
    package func restore(_ key: WidgetKey, to revision: Spec.Digest) throws(StoreError) {
        let now = Date()
        try write(at: now) { db in
            guard
                try Bool.fetchOne(
                    db, sql: "SELECT EXISTS (SELECT 1 FROM history WHERE widget = ? AND revision = ?)",
                    arguments: [key.raw, revision.hex]) == true
            else {
                throw StoreError(message: "revision \(revision) was never a head of widget \(key.raw)")
            }
            return .changes([.moveHead(key, to: revision, createdAt: milliseconds(now))])
        }
    }

    /// A revision by its name, for sharing. The bytes are the canonical document.
    package func revision(_ digest: Spec.Digest) throws(StoreError) -> Data? {
        try read { db in
            try Data.fetchOne(db, sql: "SELECT body FROM revision WHERE digest = ?", arguments: [digest.hex])
        }
    }

    /// The body of `revision` when it is in `key`'s history, and nil otherwise, so a revision another widget
    /// saved never answers for this one. Taps carry the revision they were drawn from and run as it defines
    /// them.
    package func revision(_ revision: Spec.Digest, of key: WidgetKey) throws(StoreError) -> Data? {
        try read { db in
            try Data.fetchOne(
                db,
                sql: """
                    SELECT r.body FROM revision r
                    WHERE r.digest = ? AND EXISTS (SELECT 1 FROM history h WHERE h.widget = ? AND h.revision = r.digest)
                    """, arguments: [revision.hex, key.raw])
        }
    }

    /// The heads of live widgets that this device has not proved: revisions another device saved, for the
    /// app to prove before they draw. Oldest saved first.
    package func unprovedHeads() throws(StoreError) -> [Spec.Digest] {
        try read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT r.digest FROM widget w JOIN revision r ON r.digest = w.head
                    WHERE w.deleted IS NULL AND NOT EXISTS (SELECT 1 FROM proved p WHERE p.revision = w.head)
                    ORDER BY r.saved_at, r.digest
                    """
            ).compactMap(Spec.Digest.init(hex:))
        }
    }

    /// Records this device's proof of a revision: nil when it passed, the rejection line otherwise. Local
    /// only, never synced. A pass can change what a widget draws, so `onCommit` runs.
    package func recordProof(of revision: Spec.Digest, verdict: String?) throws(StoreError) {
        try guarded { try database.write { db in try mark(revision, verdict: verdict, db) } }
        onCommit?()
    }

    /// Tombstones the widget. Its bindings and rows stay: other widgets may read the same datasets. A dataset
    /// no live widget is bound to, files, and unreferenced revisions go when a collector runs.
    package func delete(_ key: WidgetKey) throws(StoreError) {
        try write(at: Date()) { _ in .changes([.deleteWidget(key)]) }
    }

    package func assetURL(_ digest: Spec.Digest) -> URL {
        directory.appending(path: "assets/\(digest.hex)")
    }

    /// Content-addressed and immutable, so a file already at its name is already right. The atomic write is
    /// a temp file and a rename, so a reader never sees half a file.
    private func writeAsset(_ bytes: Data) throws -> Spec.Digest {
        let name = digest(of: bytes)
        let url = assetURL(name)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
        }
        return name
    }

    // MARK: Data (written by both processes)

    /// Runs every query in one read transaction, so the results are one consistent snapshot.
    package func results(of queries: [Spec.Query], widget: WidgetKey, today: Today) throws(StoreError) -> [Spec.QueryID:
        QueryResult]
    {
        try read { db in
            let me = try local(db).replica
            var results: [Spec.QueryID: QueryResult] = [:]
            for query in queries {
                results[query.id] = try evaluate(query.shape, widget: widget, today: today, me: me, db)
            }
            return results
        }
    }

    /// Applies one action as one stamped batch through `merge`. Checks that a tapped row exists, is live, and
    /// belongs to the dataset (widget, effect's table) is bound to; otherwise writes nothing and says why.
    /// `.insert` and `.insertOn` ignore `row`. `.insertOn` writes only on a `day` in
    /// `Effect.loggableDays(from: today.day)`, and every other effect ignores `day`.
    /// `.form` writes only with input: without a row it inserts, with one it sets the given fields. Input
    /// values are already typed against the form's fields.
    package func apply(
        _ action: Spec.Action, widget: WidgetKey, row: RowKey?, day: Day? = nil, input: [Spec.FieldValue],
        today: Today, at instant: Date
    ) throws(StoreError) -> Applied {
        let at = milliseconds(instant)
        return try write(at: instant) { db in
            func target(_ table: Spec.TableID, _ change: (RowKey, DatasetKey) throws -> [Change]) throws -> Plan {
                guard let row else { return .ignored("action \(action.id) needs a row") }
                switch try tapped(row, widget: widget, table: table, db) {
                case .success(let dataset): return .changes(try change(row, dataset))
                case .failure(let stale): return .ignored(stale.reason)
                }
            }
            func insert(into table: Spec.TableID, _ values: [Spec.FieldValue], on day: Day? = nil) throws -> Plan {
                guard let dataset = try Rows.dataset(of: widget, table: table.raw, db) else {
                    return .ignored("table \(table) has no dataset")
                }
                return .changes(insertion(into: dataset, values, day: day ?? today.day, at: at))
            }
            switch action.effect {
            case .insert(let table, let values):
                return try insert(into: table.id, values)
            case .insertOn(let table, let values):
                guard let day else { return .ignored("action \(action.id) needs a day") }
                let loggable = Spec.Effect.loggableDays(from: today.day)
                guard loggable.contains(day) else {
                    return .ignored("day \(day) is not between \(loggable.lowerBound) and today, \(today.day)")
                }
                return try insert(into: table.id, values, on: day)
            case .set(let value):
                return try target(value.field.table) {
                    [.setCell($0, dataset: $1, field: value.field.id.raw, value.value)]
                }
            case .toggle(let field):
                return try target(field.table) { row, dataset in
                    let on =
                        try Bool.fetchOne(
                            db,
                            sql: "SELECT value FROM cell WHERE row = ? AND dataset = ? AND field = ? AND kind = ?",
                            arguments: [row.raw, dataset.raw, field.id.raw, Spec.FieldKind.bool.code]) ?? false
                    return [.setCell(row, dataset: dataset, field: field.id.raw, .bool(!on))]
                }
            case .delete(let table):
                return try target(table.id) { [.deleteRow($0, dataset: $1)] }
            case .form(let form):
                guard !input.isEmpty else { return .ignored("form \(action.id) writes only with input") }
                guard row != nil else { return try insert(into: form.table.id, input) }
                return try target(form.table.id) { row, dataset in
                    input.map { .setCell(row, dataset: dataset, field: $0.field.id.raw, $0.value) }
                }
            }
        }
    }

    /// The tapped row's current values, for prefilling an edit form. Nil when the row is gone, deleted, or
    /// not a row of the dataset (widget, table) is bound to.
    package func values(of row: RowKey, in table: Spec.Table, widget: WidgetKey) throws(StoreError) -> [Spec.FieldID:
        Spec.Cell]?
    {
        try read { db in
            guard case .success(let dataset) = try tapped(row, widget: widget, table: table.id, db) else { return nil }
            return try cells(of: [row], in: table, dataset: dataset, db)[row] ?? [:]
        }
    }

    /// Inserts a state's rows through the insert path a tap uses, one per `count`, in one transaction, placed
    /// as `insertions` describes. A row `by` another member is stamped with that member's sample replica and
    /// the member's name is recorded, so the look sees it as another person's row. Every table the sample
    /// names must be bound.
    package func seed(_ sample: Spec.Sample, widget: WidgetKey, today: Today) throws(StoreError) {
        guard !sample.rows.isEmpty else { return }
        try write(at: Date()) { db in
            .authored(
                try insertions(sample, today: today) { table in
                    guard let dataset = try Rows.dataset(of: widget, table: table.id.raw, db) else {
                        throw StoreError(message: "table \(table.id) has no dataset to seed")
                    }
                    return dataset
                })
        }
    }

    /// Moves each of `tables` to a new, empty dataset and seeds `sample` into them, in one transaction, so
    /// the widget shows exactly the sample's rows. The rows it showed before stay in datasets nothing reads.
    /// A preview switches samples with this.
    package func replaceRows(of widget: WidgetKey, tables: [Spec.Table], with sample: Spec.Sample, today: Today)
        throws(StoreError)
    {
        let datasets = tables.map { (table: $0.id, dataset: DatasetKey.mint()) }
        try write(at: Date()) { _ in
            let binds = datasets.map { Authored(Change.bind(widget, table: $0.table.raw, to: $0.dataset), by: nil) }
            let rows = try insertions(sample, today: today) { table in
                guard let dataset = datasets.first(where: { $0.table == table.id })?.dataset else {
                    throw StoreError(message: "the sample names table \(table.id), which the widget does not have")
                }
                return dataset
            }
            return binds.isEmpty ? .ignored("the widget has no tables") : .authored(binds + rows)
        }
    }

    // MARK: Sync

    /// What sync pushes: every change this replica made after `watermark`, grouped by `Change.scope` and
    /// oldest first within each, so the server routes each dataset's changes to its members and account
    /// changes only to this account's devices. Keys another replica wrote last are left out, since that
    /// replica pushes them. Proof verdicts are local and never appear.
    package func changes(after watermark: Stamp? = nil) throws(StoreError) -> [Scope: [Stamped]] {
        try read { db in
            try Rows.changes(by: local(db).replica, after: watermark ?? Stamp(raw: 0), in: db)
        }
    }

    /// The longest a remote stamp may run ahead of the local clock before `receive` holds it back.
    package static let clockSkew: TimeInterval = 10 * 60

    /// What sync pulls: changes stamped by any replica, merged by the same rule as local writes. Two kinds of
    /// change are not merged:
    /// - `held`: stamped more than `clockSkew` after `now`. Neither merged nor clamped (clamping would make
    ///   replicas disagree), and the local clock does not advance past them. The sync layer offers them again
    ///   later.
    /// - `refused`: a text cell longer than a stored text may be, so a peer or an automation cannot pass the
    ///   limits a tap obeys. Dropped for good.
    @discardableResult
    package func receive(_ batch: [Stamped], now: Date) throws(StoreError) -> Received {
        let horizon = milliseconds(now.addingTimeInterval(Self.clockSkew))
        var accepted: [Stamped] = []
        var received = Received()
        for item in batch {
            if item.stamp.milliseconds > horizon {
                received.held.append(item)
            } else if case .setCell(_, _, _, let cell) = item.change, !cell.withinLimits {
                received.refused.append(item)
            } else {
                accepted.append(item)
            }
        }
        guard !accepted.isEmpty else { return received }
        try guarded { try database.write { db in try merge(accepted, in: db) } }
        onCommit?()
        return received
    }

    // MARK: The write funnel

    private enum Plan {
        case changes([Change])
        /// Changes some of which another member wrote: only sample rows, never a tap.
        case authored([Authored])
        case ignored(String)
    }

    /// One immediate transaction: read what the plan needs, stamp its changes with the next clock value, and
    /// merge them. `onCommit` runs after a commit that wrote.
    @discardableResult
    private func write(at instant: Date, _ plan: (Database) throws -> Plan) throws(StoreError) -> Applied {
        let applied: Applied = try guarded {
            try database.write { db in
                switch try plan(db) {
                case .ignored(let reason):
                    return .ignored(reason)
                case .changes(let changes):
                    let (replica, clock) = try local(db)
                    let stamp = Stamp.next(after: clock, at: milliseconds(instant))
                    try merge(changes.map { Stamped(change: $0, stamp: stamp, replica: replica) }, in: db)
                    return .written
                case .authored(let changes):
                    let (replica, clock) = try local(db)
                    let stamp = Stamp.next(after: clock, at: milliseconds(instant))
                    for name in Set(changes.compactMap(\.by)) {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO member(replica, name) VALUES (?, ?)",
                            arguments: [Authored.replica(of: name), name])
                    }
                    try merge(
                        changes.map {
                            Stamped(change: $0.change, stamp: stamp, replica: $0.by.map(Authored.replica) ?? replica)
                        }, in: db)
                    return .written
                }
            }
        }
        if applied == .written { onCommit?() }
        return applied
    }

    private func read<T>(_ body: (Database) throws -> T) throws(StoreError) -> T {
        try guarded { try database.read(body) }
    }
}

/// A change and the sample member who wrote it, or nil for the person on this device.
private struct Authored {
    let change: Change
    let by: String?

    init(_ change: Change, by: String?) {
        self.change = change
        self.by = by
    }

    /// The replica that stands for a sample member. Not a UUID, so it never names a real device.
    static func replica(of name: String) -> String { "sample:\(name)" }
}

/// A sample's rows as inserts, each in the dataset `dataset` names for its table. A row placed by
/// `minutesAgo` lands that many minutes before `today.instant`, on the day that moment falls on. Any other
/// row lands at midday of `today.day - daysAgo`, or for today, just before `today.instant` if that is
/// earlier but never before today began, so no sample row is written in the future or shows yesterday's
/// time. Rows keep document order, a millisecond apart.
private func insertions(
    _ sample: Spec.Sample, today: Today, dataset: (Spec.Table) throws -> DatasetKey
) rethrows -> [Authored] {
    let midday = milliseconds(today.nextDayStart) - 12 * 3_600_000
    let now = milliseconds(today.instant)
    let dayStart = milliseconds(today.dayStart)
    let total = Int64(sample.rows.reduce(0) { $0 + $1.count })
    var changes: [Authored] = []
    var sequence: Int64 = 0
    for entry in sample.rows {
        let target = try dataset(entry.table)
        for _ in 0..<entry.count {
            let latest = now - total + sequence
            let at: Int64
            let day: Day
            if let minutes = entry.minutesAgo {
                at = latest - Int64(minutes) * 60_000
                day = today.day(of: date(at))
            } else {
                let planned = midday - Int64(entry.daysAgo) * 86_400_000 + sequence
                at = entry.daysAgo == 0 ? min(planned, max(latest, dayStart + sequence)) : planned
                day = today.day.adding(-entry.daysAgo)
            }
            changes += insertion(into: target, entry.values, day: day, at: at).map { Authored($0, by: entry.by) }
            sequence += 1
        }
    }
    return changes
}

/// A new row and its values, the same for a tap, a form, and a seeded sample.
private func insertion(into dataset: DatasetKey, _ values: [Spec.FieldValue], day: Day, at: Int64) -> [Change] {
    let key = RowKey.mint(milliseconds: at)
    return [.insertRow(key, dataset: dataset, day: day, at: at)]
        + values.map { .setCell(key, dataset: dataset, field: $0.field.id.raw, $0.value) }
}

/// Records this device's proof of `revision`, inside the caller's write transaction.
private func mark(_ revision: Spec.Digest, verdict: String?, _ db: Database) throws {
    try db.execute(
        sql: """
            INSERT INTO proved(revision, verdict) VALUES (?, ?)
            ON CONFLICT(revision) DO UPDATE SET verdict = excluded.verdict
            """, arguments: [revision.hex, verdict])
}

func dataset(of widget: WidgetKey, table: String, _ db: Database) throws -> DatasetKey? {
    try String.fetchOne(
        db, sql: "SELECT dataset FROM binding WHERE widget = ? AND tbl = ?", arguments: [widget.raw, table]
    ).flatMap(DatasetKey.init(parsing:))
}

/// A bind to a new dataset for each table of `spec` that `widget` has no binding for.
private func newBindings(_ widget: WidgetKey, _ spec: Spec, _ db: Database) throws -> [Change] {
    try spec.tables.compactMap { table in
        try dataset(of: widget, table: table.id.raw, db) == nil
            ? .bind(widget, table: table.id.raw, to: .mint()) : nil
    }
}

private struct Stale: Error {
    let reason: String
}

/// The dataset a tapped row belongs to when the row is live and of the dataset (widget, table) is bound to;
/// otherwise why the tap is stale.
private func tapped(_ key: RowKey, widget: WidgetKey, table: Spec.TableID, _ db: Database) throws -> Result<
    DatasetKey, Stale
> {
    let bound = try dataset(of: widget, table: table.raw, db)
    let found = try Row.fetchAll(db, sql: "SELECT dataset, day, deleted FROM row WHERE key = ?", arguments: [key.raw])
    guard let bound, let row = found.first(where: { $0["dataset"] == bound.raw }) else {
        return .failure(
            Stale(
                reason: found.contains { $0["day"] as Int? != nil }
                    ? "row \(key.raw) is not a row of \(table)" : "row \(key.raw) does not exist"))
    }
    if row["deleted"] as Int64? != nil { return .failure(Stale(reason: "row \(key.raw) was deleted")) }
    return .success(bound)
}

private func guarded<T>(_ body: () throws -> T) throws(StoreError) -> T {
    do {
        return try body()
    } catch let error as StoreError {
        throw error
    } catch {
        throw StoreError(message: String(describing: error))
    }
}

func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
}

func date(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
}

package struct StoredWidget: Sendable {
    package let key: WidgetKey
    /// The revision the widget draws: its newest history entry that passed its proof on this device. That is
    /// the head once the head is proved here.
    package let revision: Spec.Digest
    /// Asset digests live inside the spec's assets.
    package let spec: Spec
    package let createdAt: Date

    /// The drawn revision of widget `w`, as a scalar subquery. The head is always the newest history entry.
    fileprivate static let drawn = """
        (SELECT h.revision FROM history h JOIN proved p ON p.revision = h.revision AND p.verdict IS NULL
         WHERE h.widget = w.key ORDER BY h.stamp DESC, h.replica DESC LIMIT 1)
        """

    fileprivate static let select = """
        SELECT w.key, r.digest, w.created_at, r.body FROM widget w JOIN revision r ON r.digest = \(drawn)
        """

    fileprivate init(row: Row) throws {
        guard let key = WidgetKey(parsing: row["key"]), let revision = Spec.Digest(hex: row["digest"]) else {
            throw StoreError(message: "widget \(row["key"] as String) has a malformed key or revision")
        }
        do throws(Diagnostic) {
            spec = try Spec.parse(row["body"])
        } catch {
            throw StoreError(message: "widget \(key.raw): \(error.line)")
        }
        self.key = key
        self.revision = revision
        createdAt = date(row["created_at"])
    }
}

/// Another live widget bound to the same dataset as `table` of the widget asked about, under its own `as` id.
package struct Sharer: Sendable {
    package let table: String
    package let widget: StoredWidget
    package let `as`: String
}

package struct Revision: Sendable, Equatable {
    package let digest: Spec.Digest
    package let savedAt: Date
}

package enum QueryResult: Sendable, Equatable {
    case number(Double)
    case row(RowValue?)
    case rows([RowValue])
    case days([DayCount])
}

package struct RowValue: Sendable, Equatable {
    package let key: RowKey
    package let day: Day
    /// The instant the row was inserted, by the writer's clock.
    package let at: Date
    package let by: RowAuthor
    /// Fields with no cell are absent here. The look context writes them as null, and a bool as false.
    package let values: [Spec.FieldID: Spec.Cell]
}

/// Who inserted a row. `me` when this store's replica wrote it. `name` comes from the local `member` table,
/// and is nil for a writer it does not name: before sharing exists, every row but a sample's.
package struct RowAuthor: Sendable, Equatable {
    package let me: Bool
    package let name: String?
}

package struct DayCount: Sendable, Equatable {
    package let day: Day
    /// Rows that day.
    package let count: Int
    /// The sum of the measured field that day, for a `daily` over a field. Nil for a `daily` over a table.
    package let sum: Double?

    package init(day: Day, count: Int, sum: Double? = nil) {
        self.day = day
        self.count = count
        self.sum = sum
    }
}

/// What `receive` did not merge.
package struct Received: Sendable, Equatable {
    /// Stamped too far ahead of the local clock. Offer them again later.
    package var held: [Stamped]
    /// Over a limit. Dropped for good.
    package var refused: [Stamped]

    package init(held: [Stamped] = [], refused: [Stamped] = []) {
        self.held = held
        self.refused = refused
    }
}

package enum Applied: Sendable, Equatable {
    case written
    /// A stale tap: row gone, wrong table, already deleted.
    case ignored(String)
}

package struct StoreError: Error, Sendable {
    package let message: String
}
