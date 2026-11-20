import Foundation
import GRDB
import Spec

// The schema and the single write path. Every local write (`apply`, `seed`, `save`, `restore`, `delete`)
// becomes `[Change]` stamped with the local clock and goes through `merge`. Sync feeds remote changes,
// stamped by their writers, through the same `merge` (`RowStore.receive`). Each change kind is idempotent and
// commutes with every other change, the same key included, so any delivery order and any number of replays
// leave the same state.

let schema = """
    CREATE TABLE replica (                -- exactly one row
      id     TEXT    NOT NULL,            -- this install; shared by the app and the extension
      clock  INTEGER NOT NULL             -- the largest stamp issued or merged
    );
    CREATE TABLE revision (               -- immutable, content-addressed
      digest   TEXT PRIMARY KEY,          -- SHA-256 of body, computed by merge
      body     BLOB    NOT NULL,          -- canonical exchange JSON, asset digests included
      saved_at INTEGER NOT NULL           -- ms of the earliest save
    );
    CREATE TABLE widget (
      key        TEXT PRIMARY KEY,
      head       TEXT,                    -- revision digest; NULL only on a tombstone that arrived first
      created_at INTEGER,                 -- ms; orders the picker
      stamp      INTEGER NOT NULL,        -- (stamp, replica) of the winning head move
      replica    TEXT    NOT NULL,
      deleted    INTEGER,                 -- (deleted, deleter) of the tombstone; NULL while live
      deleter    TEXT,
      CHECK (head IS NOT NULL OR deleted IS NOT NULL)
    );
    CREATE TABLE history (                -- every revision a head has named; the newest entry is the head
      widget   TEXT    NOT NULL,
      revision TEXT    NOT NULL,
      stamp    INTEGER NOT NULL,
      replica  TEXT    NOT NULL,
      PRIMARY KEY (widget, revision)
    ) WITHOUT ROWID;
    CREATE TABLE binding (                -- which dataset each table of a widget reads and writes
      widget   TEXT    NOT NULL,
      tbl      TEXT    NOT NULL,          -- a table id of the widget's spec, in any revision
      dataset  TEXT    NOT NULL,
      stamp    INTEGER NOT NULL,          -- (stamp, replica) of the winning bind
      replica  TEXT    NOT NULL,
      PRIMARY KEY (widget, tbl)
    ) WITHOUT ROWID;
    CREATE INDEX binding_dataset ON binding(dataset);
    CREATE TABLE row (
      key     TEXT PRIMARY KEY,           -- UUIDv7
      dataset TEXT,                       -- NULL only on a tombstone that arrived before its row
      day     INTEGER,                    -- the writer's local calendar day at insert; never changes
      at      INTEGER,                    -- ms at insert; orders rows within a day
      stamp   INTEGER NOT NULL,
      replica TEXT    NOT NULL,
      deleted INTEGER,
      deleter TEXT,
      CHECK (dataset IS NOT NULL OR deleted IS NOT NULL)
    );
    CREATE INDEX row_live ON row(dataset, day, at) WHERE deleted IS NULL;
    CREATE TABLE cell (
      row     TEXT    NOT NULL,           -- no foreign key: a remote cell may arrive before its row
      field   TEXT    NOT NULL,
      value           NOT NULL,           -- TEXT, REAL, INTEGER 0/1 for bool, INTEGER day index for date
      stamp   INTEGER NOT NULL,
      replica TEXT    NOT NULL,
      PRIMARY KEY (row, field)
    ) WITHOUT ROWID;
    """

/// Step `n` takes the file from `user_version` n to n + 1. Append only.
private let migrations: [@Sendable (Database) throws -> Void] = [
    { db in
        try db.execute(sql: schema)
        try db.execute(
            sql: "INSERT INTO replica(id, clock) VALUES (?, 0)", arguments: [UUID().uuidString.lowercased()])
    }
]

/// Brings the file to the current schema. Either process may get here first: the version check and every
/// step run in one immediate transaction, so the second process waits on the write lock, then finds nothing
/// left to do. A file from a newer build is refused rather than misread.
func migrate(_ database: any DatabaseWriter) throws {
    func version(_ db: Database) throws -> Int {
        let found = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        guard found <= migrations.count else {
            throw StoreError(
                message:
                    "the store has schema \(found), newer than this build reads (\(migrations.count)); update the app"
            )
        }
        return found
    }
    guard try database.read(version) < migrations.count else { return }
    try database.write { db in
        let found = try version(db)
        for step in migrations[found...] { try step(db) }
        try db.execute(sql: "PRAGMA user_version = \(migrations.count)")
    }
}

/// A hybrid logical clock value: milliseconds in the high bits, a counter in the low 16. The last value
/// lives in `replica.clock` and advances inside each write transaction, so the app and the extension draw
/// from one clock and never issue the same stamp.
package struct Stamp: Hashable, Comparable, Sendable {
    package let raw: Int64

    package static func < (a: Stamp, b: Stamp) -> Bool { a.raw < b.raw }

    static func next(after last: Int64, at milliseconds: Int64) -> Stamp {
        Stamp(raw: max(last + 1, min(max(milliseconds, 0), Int64.max >> 16) << 16))
    }

    var milliseconds: Int64 { raw >> 16 }
}

/// A cell value as stored. The merge never needs a field's kind; reads apply the spec's kind.
package enum StoredValue: Hashable, Sendable {
    case text(String)
    case real(Double)
    case integer(Int64)

    init?(_ value: DatabaseValue) {
        switch value.storage {
        case .string(let text): self = .text(text)
        case .double(let number): self = .real(number)
        case .int64(let number): self = .integer(number)
        case .null, .blob: return nil
        }
    }

    var databaseValue: DatabaseValue {
        switch self {
        case .text(let text): text.databaseValue
        case .real(let number): number.databaseValue
        case .integer(let number): number.databaseValue
        }
    }

    /// Nil when the stored value does not fit `kind`: a field a later revision redeclared with another kind
    /// reads as having no value.
    func cell(as kind: Spec.FieldKind) -> Spec.Cell? {
        switch (kind, self) {
        case (.text, .text(let text)): .text(text)
        case (.number, .real(let number)): .number(number)
        case (.number, .integer(let number)): .number(Double(number))
        case (.bool, .integer(let flag)): .bool(flag != 0)
        case (.date, .integer(let index)): .date(Day(index: Int(index)))
        default: nil
        }
    }
}

extension Spec.Cell {
    var stored: StoredValue {
        switch self {
        case .text(let text): .text(text)
        case .number(let number): .real(number)
        case .bool(let flag): .integer(flag ? 1 : 0)
        case .date(let day): .integer(Int64(day.index))
        }
    }
}

/// Every write, local or remote. Tables and fields are raw ids because the merge sits below the spec: a
/// remote change may name a table the local head does not have yet.
package enum Change: Hashable, Sendable {
    /// Keeps the first identity a key gets. Fills in a tombstone that arrived first.
    case insertRow(RowKey, dataset: DatasetKey, day: Day, at: Int64)
    /// Per-field last writer wins by (stamp, replica).
    case setCell(RowKey, field: String, StoredValue)
    /// A tombstone. The larger (stamp, replica) is kept, and nothing brings the row back.
    case deleteRow(RowKey)
    /// Named by the hash of `body`, which the merge computes.
    case putRevision(body: Data)
    /// Head last writer wins by (stamp, replica); the move is kept in history either way.
    case moveHead(WidgetKey, to: Spec.Digest, createdAt: Int64)
    case deleteWidget(WidgetKey)
    /// Points a table of a widget at a dataset. Last writer wins per (widget, table).
    case bind(WidgetKey, table: String, to: DatasetKey)
}

package struct Stamped: Hashable, Sendable {
    package let change: Change
    package let stamp: Stamp
    package let replica: String
}

private enum SQL {
    static let insertRow = """
        INSERT INTO row(key, dataset, day, at, stamp, replica) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET dataset = excluded.dataset, day = excluded.day, at = excluded.at,
          stamp = excluded.stamp, replica = excluded.replica
        WHERE row.dataset IS NULL
        """

    static let mergeCell = """
        INSERT INTO cell(row, field, value, stamp, replica) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(row, field) DO UPDATE SET value = excluded.value, stamp = excluded.stamp, replica = excluded.replica
        WHERE (excluded.stamp, excluded.replica) > (cell.stamp, cell.replica)
        """

    static let deleteRow = """
        INSERT INTO row(key, stamp, replica, deleted, deleter) VALUES (?, 0, '', ?, ?)
        ON CONFLICT(key) DO UPDATE SET deleted = excluded.deleted, deleter = excluded.deleter
        WHERE row.deleted IS NULL OR (excluded.deleted, excluded.deleter) > (row.deleted, row.deleter)
        """

    static let putRevision = """
        INSERT INTO revision(digest, body, saved_at) VALUES (?, ?, ?)
        ON CONFLICT(digest) DO UPDATE SET saved_at = excluded.saved_at WHERE excluded.saved_at < revision.saved_at
        """

    static let recordHead = """
        INSERT INTO history(widget, revision, stamp, replica) VALUES (?, ?, ?, ?)
        ON CONFLICT(widget, revision) DO UPDATE SET stamp = excluded.stamp, replica = excluded.replica
        WHERE (excluded.stamp, excluded.replica) > (history.stamp, history.replica)
        """

    static let moveHead = """
        INSERT INTO widget(key, head, created_at, stamp, replica) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET head = excluded.head, stamp = excluded.stamp, replica = excluded.replica
        WHERE (excluded.stamp, excluded.replica) > (widget.stamp, widget.replica)
        """

    static let keepCreation = """
        UPDATE widget SET created_at = ?2 WHERE key = ?1 AND (created_at IS NULL OR created_at > ?2)
        """

    static let deleteWidget = """
        INSERT INTO widget(key, stamp, replica, deleted, deleter) VALUES (?, 0, '', ?, ?)
        ON CONFLICT(key) DO UPDATE SET deleted = excluded.deleted, deleter = excluded.deleter
        WHERE widget.deleted IS NULL OR (excluded.deleted, excluded.deleter) > (widget.deleted, widget.deleter)
        """

    static let bind = """
        INSERT INTO binding(widget, tbl, dataset, stamp, replica) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(widget, tbl) DO UPDATE SET dataset = excluded.dataset, stamp = excluded.stamp,
          replica = excluded.replica
        WHERE (excluded.stamp, excluded.replica) > (binding.stamp, binding.replica)
        """
}

/// The one write rule. Runs inside the caller's write transaction. Also applies the clock's receive rule,
/// so a later local write outranks every stamp this store has seen.
func merge(_ batch: [Stamped], in db: Database) throws {
    func run(_ sql: String, _ arguments: StatementArguments) throws {
        try db.cachedStatement(sql: sql).execute(arguments: arguments)
    }
    for item in batch {
        let stamp = item.stamp.raw
        let replica = item.replica
        switch item.change {
        case .insertRow(let key, let dataset, let day, let at):
            try run(SQL.insertRow, [key.raw, dataset.raw, day.index, at, stamp, replica])
        case .setCell(let row, let field, let value):
            try run(SQL.mergeCell, [row.raw, field, value.databaseValue, stamp, replica])
        case .deleteRow(let key):
            try run(SQL.deleteRow, [key.raw, stamp, replica])
        case .putRevision(let body):
            try run(SQL.putRevision, [digest(of: body).hex, body, item.stamp.milliseconds])
        case .moveHead(let widget, let revision, let createdAt):
            try run(SQL.recordHead, [widget.raw, revision.hex, stamp, replica])
            try run(SQL.moveHead, [widget.raw, revision.hex, createdAt, stamp, replica])
            try run(SQL.keepCreation, [widget.raw, createdAt])
        case .deleteWidget(let key):
            try run(SQL.deleteWidget, [key.raw, stamp, replica])
        case .bind(let widget, let table, let dataset):
            try run(SQL.bind, [widget.raw, table, dataset.raw, stamp, replica])
        }
    }
    if let latest = batch.map(\.stamp).max() {
        try run("UPDATE replica SET clock = max(clock, ?)", [latest.raw])
    }
}

/// This store's replica id and the last stamp it issued or merged.
func local(_ db: Database) throws -> (replica: String, clock: Int64) {
    guard let row = try Row.fetchOne(db, sql: "SELECT id, clock FROM replica") else {
        throw StoreError(message: "the store has no replica row")
    }
    return (row["id"], row["clock"])
}

/// What sync pushes: the current state of every key this replica last wrote after `watermark`, as changes.
/// A head move carries its revision body, so a receiver never holds a head it cannot read.
func changes(by replica: String, after watermark: Stamp, in db: Database) throws -> [Stamped] {
    var feed: [Stamped] = []
    func add(_ change: Change?, _ stamp: Int64) {
        if let change { feed.append(Stamped(change: change, stamp: Stamp(raw: stamp), replica: replica)) }
    }
    let arguments: StatementArguments = [replica, watermark.raw]
    for row in try Row.fetchAll(
        db, sql: "SELECT key, dataset, day, at, stamp FROM row WHERE replica = ? AND stamp > ? AND dataset NOTNULL",
        arguments: arguments)
    {
        add(
            RowKey(parsing: row["key"]).flatMap { key in
                DatasetKey(parsing: row["dataset"]).map { dataset in
                    .insertRow(key, dataset: dataset, day: Day(index: row["day"]), at: row["at"])
                }
            }, row["stamp"])
    }
    for row in try Row.fetchAll(
        db, sql: "SELECT widget, tbl, dataset, stamp FROM binding WHERE replica = ? AND stamp > ?",
        arguments: arguments)
    {
        add(
            WidgetKey(parsing: row["widget"]).flatMap { widget in
                DatasetKey(parsing: row["dataset"]).map { .bind(widget, table: row["tbl"], to: $0) }
            }, row["stamp"])
    }
    for row in try Row.fetchAll(
        db, sql: "SELECT key, deleted FROM row WHERE deleter = ? AND deleted > ?", arguments: arguments)
    {
        add(RowKey(parsing: row["key"]).map { .deleteRow($0) }, row["deleted"])
    }
    for row in try Row.fetchAll(
        db, sql: "SELECT row, field, value, stamp FROM cell WHERE replica = ? AND stamp > ?", arguments: arguments)
    {
        add(
            RowKey(parsing: row["row"]).flatMap { key in
                StoredValue(row["value"]).map { .setCell(key, field: row["field"], $0) }
            }, row["stamp"])
    }
    for row in try Row.fetchAll(
        db,
        sql: """
            SELECT h.widget, h.revision, h.stamp, w.created_at, r.body FROM history h
            JOIN widget w ON w.key = h.widget JOIN revision r ON r.digest = h.revision
            WHERE h.replica = ? AND h.stamp > ?
            """, arguments: arguments)
    {
        add(.putRevision(body: row["body"]), row["stamp"])
        add(
            WidgetKey(parsing: row["widget"]).flatMap { widget in
                Spec.Digest(hex: row["revision"]).map { .moveHead(widget, to: $0, createdAt: row["created_at"]) }
            }, row["stamp"])
    }
    for row in try Row.fetchAll(
        db, sql: "SELECT key, deleted FROM widget WHERE deleter = ? AND deleted > ?", arguments: arguments)
    {
        add(WidgetKey(parsing: row["key"]).map { .deleteWidget($0) }, row["deleted"])
    }
    return feed.sorted { $0.stamp < $1.stamp }
}
