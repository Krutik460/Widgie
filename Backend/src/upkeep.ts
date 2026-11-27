// The daily upkeep the upkeep cron runs (cron.ts): parking and deleting idle accounts, and deleting old changes every
// phone of their account has pulled. Plain functions over D1, so the cron only calls them.

import { RECENT_ROWS } from "./run";
import { DAY } from "./schedule";

/// An account with no pull for this long has its tasks parked; a pull re-arms them (`rearm` in accounts.ts).
export const PARK_AFTER = 30 * DAY;
/// An account with no pull for this long is deleted, with its automations, tasks, and changes.
export const DELETE_AFTER = 90 * DAY;
/// Changes older than this that the account's last pull has passed are deleted, except a dataset's recent rows.
export const KEEP_CHANGES = 120 * DAY;
/// Deletes per D1 batch, each for one dataset of one account.
const PRUNE_BATCH = 50;

/// Runs the daily upkeep at `now`, and answers what it did.
export async function upkeep(db: D1Database, now: number) {
    const parked = await parkIdle(db, now);
    const deleted = await deleteIdle(db, now);
    const pruned = await pruneChanges(db, now);
    return { parked, deleted, pruned };
}

/// Parks every account idle for `PARK_AFTER`: marks it and deletes its tasks. Answers how many it parked. A pull or an
/// upload unparks the account in the same statement that records it alive, so neither loses tasks to a parking.
export async function parkIdle(db: D1Database, now: number): Promise<number> {
    const [parked] = await db.batch([
        db
            .prepare("UPDATE accounts SET parked_at = ?1 WHERE parked_at IS NULL AND pulled_at < ?1 - ?2")
            .bind(now, PARK_AFTER),
        db.prepare("DELETE FROM tasks WHERE account IN (SELECT id FROM accounts WHERE parked_at IS NOT NULL)"),
    ]);
    return parked?.meta.changes ?? 0;
}

/// Deletes every account idle for `DELETE_AFTER`; the foreign keys delete the rest. Answers how many it deleted.
export async function deleteIdle(db: D1Database, now: number): Promise<number> {
    const result = await db.prepare("DELETE FROM accounts WHERE pulled_at < ? - ?").bind(now, DELETE_AFTER).run();
    return result.meta.changes;
}

/// The first change written at or after a time: the ones below it are older. It reads the table in id order and stops
/// there, so it reads only the old changes.
export const FIRST_KEPT = "SELECT id FROM changes WHERE written_at >= ? ORDER BY id LIMIT 1";
/// Each dataset of each account with old changes its last pull has passed. NOT INDEXED keeps SQLite to the id range
/// of the old changes, where it would otherwise read all of `changes_dataset` for the DISTINCT.
export const OLD_DATASETS = `SELECT DISTINCT c.account, c.dataset
    FROM changes AS c NOT INDEXED JOIN accounts AS a ON a.id = c.account
    WHERE c.id < ? AND c.id <= a.pulled_after`;
/// One dataset's old, pulled changes below its RECENT_ROWS-th newest insertRow, read through `changes_dataset`. A
/// dataset with fewer rows has no such insertRow, and the comparison with NULL keeps them all.
export const PRUNE = `DELETE FROM changes
    WHERE account = ?1 AND dataset = ?2 AND id < ?3
        AND id <= (SELECT pulled_after FROM accounts WHERE id = ?1)
        AND id < (SELECT id FROM changes WHERE account = ?1 AND dataset = ?2 AND op = 'insertRow'
            ORDER BY id DESC LIMIT 1 OFFSET ?4)`;

/// Deletes the changes written more than `KEEP_CHANGES` ago that the account's last pull has passed
/// (`accounts.pulled_after`), except those of each dataset's last RECENT_ROWS rows, which the next run reads back for
/// the repeat check. Answers how many it deleted.
///
/// A change goes when its id is below the insertRow of its dataset's RECENT_ROWS-th newest row. A row's changes are
/// its insertRow and setCells, written in one batch, and later perhaps its deleteRow, so its ids only grow from its
/// insertRow's: a kept row keeps every change, and a deleted row's tombstone outlives its insertRow or goes with it,
/// never the other way round, so a phone that pulls from the start never sees a row its tombstone should hide.
///
/// "Written more than KEEP_CHANGES ago" is read as an id below the first change written since, since ids and write
/// times rise together; that way only the old changes are read, not the whole table.
export async function pruneChanges(db: D1Database, now: number): Promise<number> {
    const first = await db
        .prepare(FIRST_KEPT)
        .bind(now - KEEP_CHANGES)
        .first<number>("id");
    const before = first ?? Number.MAX_SAFE_INTEGER;
    const { results: datasets } = await db
        .prepare(OLD_DATASETS)
        .bind(before)
        .all<{ account: string; dataset: string }>();
    let pruned = 0;
    for (let start = 0; start < datasets.length; start += PRUNE_BATCH) {
        const results = await db.batch(
            datasets
                .slice(start, start + PRUNE_BATCH)
                .map(({ account, dataset }) => db.prepare(PRUNE).bind(account, dataset, before, RECENT_ROWS - 1)),
        );
        pruned += results.reduce((total, result) => total + result.meta.changes, 0);
    }
    return pruned;
}
