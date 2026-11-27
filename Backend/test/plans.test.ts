// The query plans of the cron's, the runner's, and the upkeep's statements: each reads through an index or an id
// range, never all of a table that grows with every account.

import { env } from "cloudflare:workers";
import { expect, it } from "vitest";
import { CLAIM } from "../src/cron";
import { LATEST_CELLS, LATEST_ROWS } from "../src/runner";
import { FIRST_KEPT, OLD_DATASETS, PRUNE } from "../src/upkeep";
import { DATASET } from "./helpers/accounts";

async function plan(sql: string, ...values: unknown[]): Promise<string> {
    const { results } = await env.DB.prepare(`EXPLAIN QUERY PLAN ${sql}`)
        .bind(...values)
        .all<{ detail: string }>();
    return results.map((row) => row.detail).join("\n");
}

it("claims through tasks_due", async () => {
    const detail = await plan(CLAIM, 1, 1, 100);
    expect(detail).toMatch(/SEARCH tasks USING INDEX tasks_due \(due_at<\?\)/);
    expect(detail).toMatch(/SEARCH tasks USING INTEGER PRIMARY KEY \(rowid=\?\)/);
    expect(detail).not.toMatch(/SCAN/);
});

it("reads a dataset's recent rows and their cells through changes_dataset", async () => {
    for (const sql of [LATEST_ROWS, LATEST_CELLS]) {
        const detail = await plan(sql, "account", DATASET, 60);
        expect(detail).toMatch(/SEARCH changes USING INDEX changes_dataset \(account=\? AND dataset=\?\)/);
        expect(detail).not.toMatch(/SCAN/);
    }
});

it("prunes by id range: the old changes in id order, and each dataset through changes_dataset", async () => {
    // Read in id order and stopped at the first change new enough, with no sort.
    const first = await plan(FIRST_KEPT, 1);
    expect(first).toBe("SCAN changes");
    const datasets = await plan(OLD_DATASETS, 1);
    expect(datasets).toMatch(/SEARCH c USING INTEGER PRIMARY KEY \(rowid<\?\)/);
    expect(datasets).not.toMatch(/SCAN/);
    const prune = await plan(PRUNE, "account", DATASET, 1, 59);
    expect(prune).toMatch(
        /SEARCH changes USING COVERING INDEX changes_dataset \(account=\? AND dataset=\? AND id<\?\)/,
    );
    expect(prune).not.toMatch(/SCAN/);
});
