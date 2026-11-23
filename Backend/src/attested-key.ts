// One App Attest key's state, in its own SQLite-backed Durable Object named by the key id: the public key, the
// assertion counter, today's quota, and a pending challenge. Nothing is written in the constructor or on a
// refusal, and the table is created only right before a write, so a random key id never leaves an object behind.
//
// The Worker verifies an attestation itself, between `takeChallenge` and `storeKey`, so this object never needs the
// pinned root or the clock the verifier is tested with. Each method's reads and writes run with no `await` between
// them, so two requests can never both pass a check that the first one's write would fail.

import { DurableObject } from "cloudflare:workers";
import { verifyAssertion } from "./attestation";
import { toBase64Url } from "./bytes";

export const CHALLENGE_LIFE_MS = 5 * 60 * 1000;
export const DEFAULT_QUOTA_PER_DAY = 40;

/// QUOTA_PER_DAY, or the default when it is unset or empty. Anything but a whole number is a broken setting.
export function quotaPerDay(value: string | undefined): number {
    if (value === undefined || value === "") return DEFAULT_QUOTA_PER_DAY;
    const quota = Number(value);
    if (!Number.isSafeInteger(quota) || quota < 0 || String(quota) !== value) {
        throw new Error(`QUOTA_PER_DAY must be a whole number, not "${value}"`);
    }
    return quota;
}

interface Row extends Record<string, SqlStorageValue> {
    public_key: ArrayBuffer | null;
    counter: number;
    quota_day: string | null;
    quota_count: number;
    challenge: string | null;
    challenge_expires: number | null;
}

export class AttestedKey extends DurableObject<Cloudflare.Env> {
    /// A new one-use challenge for this key, replacing any pending one, with an alarm at its expiry.
    async issueChallenge(): Promise<{ challenge: string } | { code: "attested" }> {
        if (this.row()?.public_key) return { code: "attested" };
        const challenge = toBase64Url(crypto.getRandomValues(new Uint8Array(32)));
        const expires = Date.now() + CHALLENGE_LIFE_MS;
        this.createTable();
        this.sql(
            `INSERT INTO attested_key (id, challenge, challenge_expires) VALUES (1, ?, ?)
             ON CONFLICT (id) DO UPDATE SET challenge = excluded.challenge, challenge_expires = excluded.challenge_expires`,
            challenge,
            expires,
        );
        await this.ctx.storage.setAlarm(expires);
        return { challenge };
    }

    /// Takes and deletes the pending challenge if it is `challenge` and unexpired. Null when taken.
    async takeChallenge(challenge: string): Promise<"bad-attestation" | "attested" | null> {
        const row = this.row();
        if (row?.public_key) return "attested";
        if (!row || row.challenge !== challenge || (row.challenge_expires ?? 0) <= Date.now()) {
            return "bad-attestation";
        }
        this.sql("UPDATE attested_key SET challenge = NULL, challenge_expires = NULL WHERE id = 1");
        return null;
    }

    /// Stores a verified key with counter 0 unless one is already stored, and cancels the cleanup alarm. Null when
    /// stored. It works even after the alarm cleared the object while the Worker was verifying.
    async storeKey(publicKey: Uint8Array): Promise<"attested" | null> {
        if (this.row()?.public_key) return "attested";
        this.createTable();
        this.sql(
            `INSERT INTO attested_key (id, public_key, counter, quota_day, quota_count, challenge, challenge_expires)
             VALUES (1, ?, 0, NULL, 0, NULL, NULL)
             ON CONFLICT (id) DO UPDATE SET public_key = excluded.public_key, counter = 0, quota_day = NULL,
                 quota_count = 0, challenge = NULL, challenge_expires = NULL`,
            publicKey,
        );
        await this.ctx.storage.deleteAlarm();
        return null;
    }

    /// Checks an assertion over `clientDataHash` and, if its counter is newer than the stored one, stores the counter
    /// and takes one call from today's quota (UTC). Null when reserved. A refusal changes nothing.
    async verifyAndReserve(
        clientDataHash: Uint8Array,
        assertion: Uint8Array,
    ): Promise<"unknown-key" | "bad-assertion" | "daily-quota" | null> {
        const publicKey = this.row()?.public_key;
        if (!publicKey) return "unknown-key";
        const counter = await verifyAssertion({
            publicKey: new Uint8Array(publicKey),
            appId: this.env.APP_ID,
            clientDataHash,
            assertion,
        });
        if (counter === null) return "bad-assertion";

        // No await from here to the write.
        const row = this.row();
        if (!row || counter <= row.counter) return "bad-assertion";
        const today = new Date().toISOString().slice(0, 10);
        const used = row.quota_day === today ? row.quota_count : 0;
        if (used >= quotaPerDay(this.env.QUOTA_PER_DAY)) return "daily-quota";
        this.sql(
            "UPDATE attested_key SET counter = ?, quota_day = ?, quota_count = ? WHERE id = 1",
            counter,
            today,
            used + 1,
        );
        return null;
    }

    /// The challenge's expiry: deletes the object unless a key is stored.
    override async alarm(): Promise<void> {
        if (this.row()?.public_key) return;
        await this.ctx.storage.deleteAll();
    }

    /// The single row, or undefined when the object holds nothing. Reads only.
    private row(): Row | undefined {
        const tables = this.sql("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'attested_key'");
        if (tables.toArray().length === 0) return undefined;
        return this.sql<Row>(
            `SELECT public_key, counter, quota_day, quota_count, challenge, challenge_expires
             FROM attested_key WHERE id = 1`,
        ).toArray()[0];
    }

    private createTable() {
        this.sql(
            `CREATE TABLE IF NOT EXISTS attested_key (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                public_key BLOB,
                counter INTEGER NOT NULL DEFAULT 0,
                quota_day TEXT,
                quota_count INTEGER NOT NULL DEFAULT 0,
                challenge TEXT,
                challenge_expires INTEGER
            )`,
        );
    }

    private sql<T extends Record<string, SqlStorageValue> = Record<string, SqlStorageValue>>(
        query: string,
        ...bindings: unknown[]
    ): SqlStorageCursor<T> {
        return this.ctx.storage.sql.exec<T>(query, ...bindings);
    }
}
