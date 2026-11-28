// The query plans of the cron's, the runner's, and the upkeep's statements: each reads through an index or an id
// range, never all of a table that grows with every account.

import { env } from "cloudflare:workers";
import { expect, it } from "vitest";
import { PAGE } from "../src/accounts";
import { DELETE_AUTOMATIONS, DELETE_SCHEDULES, DELETE_TASKS, RERUN_VERSIONS } from "../src/automations";
import { CLAIM } from "../src/cron";
import { LATEST_CELLS, LATEST_ROWS, START } from "../src/runner";
import { PRUNE_SLICE, SLICES } from "../src/upkeep";

async function plan(sql: string, ...values: unknown[]): Promise<string> {
    const { results } = await env.DB.prepare(`EXPLAIN QUERY PLAN ${sql}`)
        .bind(...values)
        .all<{ detail: string }>();
    return results.map((row) => row.detail).join("\n");
}

/// The tasks of one automation, read by the task table's unique key.
const SIBLINGS = /SEARCH other USING INDEX sqlite_autoindex_tasks_1 \(account=\? AND widget=\? AND automation=\?\)/;

it("claims through tasks_due, and looks for the automation's other tasks by its key", async () => {
    const detail = await plan(CLAIM, 1, 1, 100);
    expect(detail).toMatch(/SEARCH t USING INDEX tasks_due \(due_at<\?\)/);
    expect(detail).toMatch(/SEARCH tasks USING INTEGER PRIMARY KEY \(rowid=\?\)/);
    expect(detail).toMatch(SIBLINGS);
    expect(detail).toMatch(
        /SEARCH other USING INDEX sqlite_autoindex_tasks_1 \(account=\? AND widget=\? AND automation=\? AND once=\?\)/,
    );
    expect(detail).not.toMatch(/SCAN/);
});

it("starts a run by the task's id, and looks for the automation's other tasks by its key", async () => {
    const detail = await plan(START, 1, 1, 1, "row", 0);
    expect(detail).toMatch(/SEARCH t USING INTEGER PRIMARY KEY \(rowid=\?\)/);
    expect(detail).toMatch(SIBLINGS);
    expect(detail).not.toMatch(/SCAN/);
});

it("reads a dataset's recent rows and their cells through changes_dataset, finding the dataset by the task's id", async () => {
    for (const sql of [LATEST_ROWS, LATEST_CELLS]) {
        const detail = await plan(sql, 1, "row", 60);
        expect(detail).toMatch(/SEARCH t USING INTEGER PRIMARY KEY \(rowid=\?\)/);
        expect(detail).toMatch(/SEARCH c USING INDEX changes_dataset \(account=\? AND dataset=\?\)/);
        expect(detail).not.toMatch(/SCAN (c|changes|t|tasks|a|automations)\b/);
    }
});

it("prunes by id range: the slices in id order, and each slice's datasets through changes_dataset", async () => {
    // Read from the upkeep's place by id; the window and the outer query read only what the inner one kept.
    const slices = await plan(SLICES, 10_000, 200_001);
    expect(slices).toMatch(/SEARCH changes USING INTEGER PRIMARY KEY \(rowid>\?\)/);
    expect(slices).toMatch(/SEARCH upkeep USING INTEGER PRIMARY KEY \(rowid=\?\)/);
    expect(slices).not.toMatch(/SCAN (changes|upkeep)\b/);

    const prune = await plan(PRUNE_SLICE, 1, 10_001, 1, 59);
    // The slice's datasets, read by id.
    expect(prune).toMatch(/SEARCH changes USING INTEGER PRIMARY KEY \(rowid>\? AND rowid<\?\)/);
    // Each dataset's limit: its account's watermark by key, its 60th newest row through changes_dataset.
    expect(prune).toMatch(/SEARCH accounts USING INDEX sqlite_autoindex_accounts_1 \(id=\?\)/);
    expect(prune).toMatch(/SEARCH changes USING INDEX changes_dataset \(account=\? AND dataset=\?\)/);
    // The deletes: each account's part of the slice, by its id range.
    expect(prune).toMatch(/SEARCH c USING INDEX changes_account \(account=\? AND id>\? AND id<\?\)/);
    // Only the materialized datasets and limits are scanned, never a table.
    for (const line of prune.split("\n").filter((line) => line.includes("SCAN"))) {
        expect(line).toMatch(/^SCAN (d|l)$/);
    }
});

/// No line of a plan scans a table that grows with every account; scanning the JSON list a statement is given is fine.
function scansNoTable(detail: string) {
    for (const line of detail.split("\n").filter((line) => line.includes("SCAN"))) {
        expect(line).not.toMatch(/\b(tasks|automations|changes|accounts)\b/);
    }
}

it("an upload deletes and re-versions the listed automations and their tasks through their unique keys", async () => {
    const list = JSON.stringify([{ widget: "w", automation: "a", version: "v" }]);
    const automations = await plan(DELETE_AUTOMATIONS, "acc", list);
    expect(automations).toMatch(
        /USING (COVERING )?INDEX sqlite_autoindex_automations_1 \(account=\? AND widget=\? AND automation=\?\)/,
    );
    scansNoTable(automations);
    for (const sql of [DELETE_TASKS, DELETE_SCHEDULES, RERUN_VERSIONS]) {
        const detail = await plan(sql, "acc", list);
        expect(detail).toMatch(
            /USING (COVERING )?INDEX sqlite_autoindex_tasks_1 \(account=\? AND widget=\? AND automation=\?/,
        );
        scansNoTable(detail);
    }
});

it("a pull reads its page through changes_account by the watermark", async () => {
    const detail = await plan(PAGE, "acc", 0, 500);
    expect(detail).toMatch(/USING (COVERING )?INDEX changes_account \(account=\? AND id>\?\)/);
    scansNoTable(detail);
});
