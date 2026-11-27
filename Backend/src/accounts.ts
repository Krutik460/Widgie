// Accounts and their token, and the pull. One account per App Attest key: registering again returns the same account
// with a new token. The token is `<account id>.<secret>`, the secret 32 random bytes as unpadded base64url; only the
// secret's SHA-256 is stored, and it is compared in constant time against the row the id names.

import { insertTask, type Stored, scheduleTask } from "./automations";
import { fromBase64, sha256, toBase64Url, toHex } from "./bytes";
import { HOUR } from "./schedule";
import { encodePage, isUuid, mintUuid } from "./wire";

/// The most changes one pull returns. The phone asks again from the page's last id.
export const PAGE_SIZE = 500;

export interface Account {
    id: string;
    replica: string;
    timeZone: string | null;
    parkedAt: number | null;
}

/// A new token for the account of `attestKey`, creating the account the first time; a dev registration (no key)
/// always creates one. One statement, so two registrations of one key can never make two accounts.
export async function register(db: D1Database, attestKey: string | null, now: number): Promise<string> {
    const secret = crypto.getRandomValues(new Uint8Array(32));
    const hash = toHex(await sha256(secret));
    const row = await db
        .prepare(
            `INSERT INTO accounts (id, token_hash, attest_key, replica, created_at, pulled_at) VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT (attest_key) DO UPDATE SET token_hash = excluded.token_hash
             RETURNING id`,
        )
        .bind(mintUuid(), hash, attestKey, mintUuid(), now, now)
        .first<{ id: string }>();
    if (!row) throw new Error("registering returned no account");
    return `${row.id}.${toBase64Url(secret)}`;
}

/// The account an `Authorization: Bearer <token>` header names, or null.
export async function authenticate(db: D1Database, header: string | null): Promise<Account | null> {
    const match = /^Bearer ([0-9a-f-]{36})\.([A-Za-z0-9_-]{43})$/.exec(header ?? "");
    if (!match?.[1] || !match[2] || !isUuid(match[1])) return null;
    const secret = fromBase64(`${match[2].replaceAll("-", "+").replaceAll("_", "/")}=`);
    // Only the canonical spelling: the 43rd character carries two bits that must be zero.
    if (secret?.byteLength !== 32 || toBase64Url(secret) !== match[2]) return null;
    const row = await db
        .prepare("SELECT id, token_hash, replica, time_zone, parked_at FROM accounts WHERE id = ?")
        .bind(match[1])
        .first<{
            id: string;
            token_hash: string;
            replica: string;
            time_zone: string | null;
            parked_at: number | null;
        }>();
    if (!row) return null;
    const encoder = new TextEncoder();
    const given = encoder.encode(toHex(await sha256(secret)));
    const kept = encoder.encode(row.token_hash);
    if (given.byteLength !== kept.byteLength || !crypto.subtle.timingSafeEqual(given, kept)) return null;
    return { id: row.id, replica: row.replica, timeZone: row.time_zone, parkedAt: row.parked_at };
}

/// The page of the account's changes after `after`, as WIRE.md writes it, and how many it holds. A pull records that
/// the phone is alive (at most once an hour, to spare writes) and re-arms a parked account first.
export async function pull(
    db: D1Database,
    account: Account,
    after: number,
    now: number,
): Promise<{ body: string; count: number }> {
    if (account.parkedAt !== null) await rearm(db, account, now);
    const [page, next] = await db.batch([
        db
            .prepare("SELECT id, change FROM changes WHERE account = ? AND id > ? ORDER BY id LIMIT ?")
            .bind(account.id, after, PAGE_SIZE),
        // When the server next expects to write: the earliest time a task of the account is due.
        db.prepare("SELECT min(due_at) AS next FROM tasks WHERE account = ?").bind(account.id),
        db
            .prepare("UPDATE accounts SET pulled_at = ?1 WHERE id = ?2 AND pulled_at <= ?1 - ?3")
            .bind(now, account.id, HOUR),
    ]);
    const entries = (page?.results ?? []) as { id: number; change: string }[];
    const nextWrite = (next?.results[0] as { next: number | null } | undefined)?.next ?? null;
    return { body: encodePage(account.replica, entries, nextWrite), count: entries.length };
}

/// Gives each automation of a parked account its schedule again from now, and unparks it. A schedule an upload made
/// in the meantime stays.
export async function rearm(db: D1Database, account: Account, now: number): Promise<void> {
    const { results } = await db
        .prepare("SELECT widget, automation, version, every, at, weekday FROM automations WHERE account = ?")
        .bind(account.id)
        .all<Pick<Stored, "widget" | "automation" | "version" | "every" | "at" | "weekday">>();
    const zone = account.timeZone;
    const statements = zone
        ? results.map((row) => insertTask(db, account.id, row, scheduleTask(account.id, row, zone, now), true))
        : [];
    statements.push(
        db.prepare("UPDATE accounts SET parked_at = NULL, pulled_at = ? WHERE id = ?").bind(now, account.id),
    );
    await db.batch(statements);
}
