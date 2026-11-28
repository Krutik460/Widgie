-- Phase 3: accounts, their automations, the tasks that run them, the changes a pull returns, and the upkeep's place.
-- Times are milliseconds since 1970-01-01T00:00:00Z. D1 enforces foreign keys, so deleting an account deletes the rest.

-- One per App Attest key, or per dev registration (attest_key NULL). The token is `<id>.<secret>`; only the SHA-256
-- of the secret's 32 bytes is kept, as hex. replica is the automation replica every server change is written under,
-- and last_stamp the last stamp it issued, a 64-bit integer that leaves SQL only as text. revision rises with every
-- upload, which writes only if it still holds the revision it read. pulled_at is when the phone was last heard from
-- (a pull, at most hourly, or an upload), and pulled_after the watermark of its last pull: it has every change up to
-- that id, which the cleanup reads.
CREATE TABLE accounts (
    id TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL,
    attest_key TEXT UNIQUE,
    replica TEXT NOT NULL UNIQUE,
    last_stamp INTEGER NOT NULL DEFAULT 0,
    revision INTEGER NOT NULL DEFAULT 0,
    time_zone TEXT,
    created_at INTEGER NOT NULL,
    pulled_at INTEGER NOT NULL,
    pulled_after INTEGER NOT NULL DEFAULT 0,
    parked_at INTEGER
) STRICT;

-- The account's automations as the phone last uploaded them (docs/engine/WIRE.md, the automation payload). every, at,
-- and weekday are the cadence (at is ":MM" for every hour); fields is the writes table's {id: kind} as sorted JSON.
-- version is the SHA-256 of prompt, cadence, time zone, dataset, and fields.
CREATE TABLE automations (
    account TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    widget TEXT NOT NULL,
    automation TEXT NOT NULL,
    version TEXT NOT NULL,
    prompt TEXT NOT NULL,
    every TEXT NOT NULL CHECK (every IN ('hour', 'day', 'week')),
    at TEXT NOT NULL,
    weekday TEXT,
    dataset TEXT NOT NULL,
    fields TEXT NOT NULL,
    PRIMARY KEY (account, widget, automation)
) STRICT;

-- One run of an automation. once = 0 is the automation's schedule, which moves on to its next run after each run;
-- once = 1 is a run now, deleted after it runs. run_at is the row's `at`, row_key the row's UUIDv7, minted with the
-- task so a replayed write lands on the same row. The cron claims a task when due_at has passed and no claim is live;
-- claimed_until keeps it from other claims while its message waits and its run runs. attempts counts the runs that
-- started since the task last moved on.
CREATE TABLE tasks (
    id INTEGER PRIMARY KEY,
    account TEXT NOT NULL,
    widget TEXT NOT NULL,
    automation TEXT NOT NULL,
    version TEXT NOT NULL,
    once INTEGER NOT NULL CHECK (once IN (0, 1)),
    run_at INTEGER NOT NULL,
    row_key TEXT NOT NULL,
    due_at INTEGER NOT NULL,
    claimed_until INTEGER,
    attempts INTEGER NOT NULL DEFAULT 0,
    UNIQUE (account, widget, automation, once),
    FOREIGN KEY (account, widget, automation) REFERENCES automations (account, widget, automation) ON DELETE CASCADE
) STRICT;

CREATE INDEX tasks_due ON tasks (due_at);

-- Every change a pull returns, in the wire format, under ids that only grow (AUTOINCREMENT never reuses one, so a
-- watermark stays valid after cleanup). op, dataset, row_key, widget, automation, and at repeat what the change holds
-- so tombstones and the repeat check can find an automation's rows.
CREATE TABLE changes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account TEXT NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    op TEXT NOT NULL CHECK (op IN ('insertRow', 'setCell', 'deleteRow')),
    dataset TEXT NOT NULL,
    row_key TEXT NOT NULL,
    widget TEXT,
    automation TEXT,
    at INTEGER,
    change TEXT NOT NULL,
    written_at INTEGER NOT NULL
) STRICT;

-- The pull's page; the tombstones' rows still ahead of an automation and the check for a row already deleted (partial,
-- so each holds only its op); and P3's read-back of a dataset's recent rows.
CREATE INDEX changes_account ON changes (account, id);
CREATE INDEX changes_inserted ON changes (account, widget, automation, at) WHERE op = 'insertRow';
CREATE INDEX changes_deleted ON changes (account, row_key) WHERE op = 'deleteRow';
CREATE INDEX changes_dataset ON changes (account, dataset, id);

-- The daily upkeep's place in `changes` (upkeep.ts): the id its next prune starts from. One row.
CREATE TABLE upkeep (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    prune_from INTEGER NOT NULL
) STRICT;

INSERT INTO upkeep (id, prune_from) VALUES (1, 0);
