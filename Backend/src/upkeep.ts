// The daily upkeep the phase 3 cron runs, and the spend row that stops claims on a bad day. Plain functions over D1,
// so the cron only calls them.

import { DAY } from "./schedule";

/// An account with no pull for this long has its tasks parked; a pull re-arms them (`rearm` in accounts.ts).
export const PARK_AFTER = 30 * DAY;
/// An account with no pull for this long is deleted, with its automations, tasks, and changes.
export const DELETE_AFTER = 90 * DAY;

/// Parks every account idle for `PARK_AFTER`: marks it and deletes its tasks. Answers how many it parked.
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

/// The UTC day a spend counts toward, as `YYYY-MM-DD`.
export function spendDay(now: number): string {
    return new Date(now).toISOString().slice(0, 10);
}

/// Whether today's model spend is still under `limit` US dollars, so claims may go on.
export async function spendAllows(db: D1Database, now: number, limit: number): Promise<boolean> {
    const row = await db.prepare("SELECT cost FROM spend WHERE day = ?").bind(spendDay(now)).first<{ cost: number }>();
    return (row?.cost ?? 0) < limit;
}

/// Adds a run's cost to today's spend.
export async function addSpend(db: D1Database, now: number, cost: number): Promise<void> {
    await db
        .prepare(
            "INSERT INTO spend (day, cost) VALUES (?, ?) ON CONFLICT (day) DO UPDATE SET cost = cost + excluded.cost",
        )
        .bind(spendDay(now), cost)
        .run();
}
