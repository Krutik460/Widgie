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
/// How much of `changes` one upkeep reads: slices of `rows` changes in id order, at most `slices` of them, one
/// statement each. With parking and deleting, a run makes at most 5 + slices queries, well within Workers Free's 50,
/// and each statement reads a bounded number of rows however large the table grows.
export const PRUNE = { rows: 10_000, slices: 20 } as const;

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

/// Where the next prune's slices start: the first change at or after the upkeep's place (`upkeep.prune_from`), then
/// every ?1-th change of the next ?2, each with its write time. Read by id, so it reads only those changes.
export const SLICES = `SELECT id, written_at FROM (
        SELECT id, written_at, row_number() OVER (ORDER BY id) AS n FROM (
            SELECT id, written_at FROM changes WHERE id >= (SELECT prune_from FROM upkeep WHERE id = 1)
            ORDER BY id LIMIT ?2))
    WHERE (n - 1) % ?1 = 0
    ORDER BY id`;

/// One slice's deletes: its changes (ids ?1 up to ?2) written before ?3 that their account's last pull has passed,
/// below the RECENT_ROWS-th newest insertRow (OFFSET ?4) of their dataset. A dataset with fewer rows has no such
/// insertRow, and the 0 keeps all of it. The slice's datasets are read by id, the limit of each is worked out once
/// (`below`, through the accounts' key and `changes_dataset`), and the deletes read each account's part of the slice
/// through `changes_account`.
export const PRUNE_SLICE = `WITH datasets AS MATERIALIZED (
        SELECT DISTINCT account, dataset FROM changes WHERE id >= ?1 AND id < ?2 AND written_at < ?3),
    limits AS MATERIALIZED (
        SELECT d.account, d.dataset, min(
            (SELECT pulled_after + 1 FROM accounts WHERE id = d.account),
            coalesce((SELECT id FROM changes WHERE account = d.account AND dataset = d.dataset AND op = 'insertRow'
                ORDER BY id DESC LIMIT 1 OFFSET ?4), 0)) AS below
        FROM datasets AS d)
    DELETE FROM changes WHERE id IN (
        SELECT c.id FROM changes AS c JOIN limits AS l ON l.account = c.account AND l.dataset = c.dataset
        WHERE c.id >= ?1 AND c.id < ?2 AND c.written_at < ?3 AND c.id < l.below)`;

/// Deletes the changes written more than `KEEP_CHANGES` ago that the account's last pull has passed
/// (`accounts.pulled_after`), except those of each dataset's last RECENT_ROWS rows, which the next run reads back for
/// the repeat check. Answers how many it deleted.
///
/// A change goes when its id is below the insertRow of its dataset's RECENT_ROWS-th newest row. A row's changes are
/// its insertRow and setCells, written in one batch, and later perhaps its deleteRow, so its ids only grow from its
/// insertRow's: a kept row keeps every change, and a deleted row's tombstone outlives its insertRow or goes with it,
/// never the other way round, so a phone that pulls from the start never sees a row its tombstone should hide.
///
/// Each run reads at most `PRUNE.slices` slices of `PRUNE.rows` changes from the upkeep's place, and moves the place
/// past them. Ids and write times rise together, so a slice that starts at a change newer than KEEP_CHANGES has
/// nothing old after it: the run stops there and the next one starts again from the first change, as it does at the
/// end of the table. A pass over the old changes therefore spans as many days as it needs, and changes it kept (a
/// dataset's last rows, or ones a pull had not passed) are looked at again on the next pass.
export async function pruneChanges(
    db: D1Database,
    now: number,
    prune: { rows: number; slices: number } = PRUNE,
): Promise<number> {
    const old = now - KEEP_CHANGES;
    const { results: starts } = await db
        .prepare(SLICES)
        .bind(prune.rows, prune.rows * prune.slices + 1)
        .all<{ id: number; written_at: number }>();
    // The slices that start at an old change. The pass is done when a slice would start at a new change, or the
    // table ends within this run's slices.
    const firstNew = starts.findIndex((start) => start.written_at >= old);
    const count = Math.min(firstNew === -1 ? starts.length : firstNew, prune.slices);
    const done = firstNew !== -1 || starts.length <= prune.slices;
    let pruned = 0;
    for (let i = 0; i < count; i++) {
        const from = starts[i]?.id ?? 0;
        const to = starts[i + 1]?.id ?? Number.MAX_SAFE_INTEGER;
        const result = await db
            .prepare(PRUNE_SLICE)
            .bind(from, to, old, RECENT_ROWS - 1)
            .run();
        pruned += result.meta.changes;
    }
    const next = done ? 0 : (starts[prune.slices]?.id ?? 0);
    await db.prepare("UPDATE upkeep SET prune_from = ? WHERE id = 1").bind(next).run();
    return pruned;
}
