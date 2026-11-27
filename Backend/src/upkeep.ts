// The daily upkeep the phase 3 cron runs: parking and deleting idle accounts. Plain functions over D1, so the cron only
// calls them.

import { DAY } from "./schedule";

/// An account with no pull for this long has its tasks parked; a pull re-arms them (`rearm` in accounts.ts).
export const PARK_AFTER = 30 * DAY;
/// An account with no pull for this long is deleted, with its automations, tasks, and changes.
export const DELETE_AFTER = 90 * DAY;

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
