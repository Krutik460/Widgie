# PR 24: accounts, automations, and the pull in the Worker

Branch `phase-3-p2-worker` into `phase-2b-b2` (PR 23). This is P2 of [tasks/phase-3-ai-block.md](../../tasks/phase-3-ai-block.md) (see its "P2 results" note). The Worker gets a D1 database, accounts with a bearer token, a replace-all upload of the account's automations that turns into versions, tasks, and tombstones, and a pull that returns the account's changes in the wire format. Nothing runs an automation yet: P3 adds the cron that claims due tasks and the Queue consumer that writes rows. Nothing is deployed and no real D1 database exists yet.

The branch merges the wire format commit from P1 (`fbd865f`, via `71cf631`), which brings `docs/engine/WIRE.md`, `Engine/Vectors/wire.json`, and the Swift reader. Review it in PR 22. Here it is the contract: the Worker writes exactly what [WIRE.md](../engine/WIRE.md) defines and is checked against the same vectors. The Swift files in the diff (`Wire.swift`, `RowStore.swift`, `Merge.swift`, `WireTests.swift`, `JSON.swift`, `Spec.swift`) all come from that merge. One line of WIRE.md changes here: `nextWrite` is never sooner than five minutes after the pull (section 3).

Background reading: [WIRE.md](../engine/WIRE.md) sections "What the server writes" (line 80) and "The automation payload" (line 89), and the plan's "How it works (decided)" (lines 72 to 87).

**No usage limits for now.** The user removed them on 2026-11-27 for simplicity: no runs per day, no automations per account, no spend cap, and no rate limits on the sync routes. They come back later; the OpenRouter key's credit limit is the backstop. The document's own rules, which the engine also enforces, are still checked.

## Core changes

- **A D1 schema.** [0001_automations.sql](../../Backend/migrations/0001_automations.sql) creates `accounts` (token hash, attest key, automation replica, `last_stamp`, `revision`, time zone, `pulled_at`, `pulled_after`, `parked_at`), `automations` (the uploaded payload plus a `version`), `tasks` (`once`, `run_at`, `row_key`, `due_at`, `claimed_until`, `attempts`, at most one of each kind per automation), and `changes` (`AUTOINCREMENT` ids, the wire JSON, and its key columns repeated). Indexes `tasks(due_at)`, `changes(account, id)`, the partial `changes(account, widget, automation, at) WHERE op = 'insertRow'` and `changes(account, row_key) WHERE op = 'deleteRow'`, and `changes(account, dataset, id)` for P3's read-back. Foreign keys cascade from `accounts`.
- **`POST /v1/account`.** An empty body signed with the B2 App Attest key (`POST\n/v1/account\n<hex SHA-256 of nothing>`) answers `{token}`. A new `AttestedKey.verify` checks and stores the counter without taking build quota. One account per attest key: registering again returns the same account with a new token, in one `INSERT ... ON CONFLICT (attest_key)` statement. On `dev` only, an `X-Widgie-Dev-Secret` header carrying `DEV_REGISTRATION_SECRET` registers a new account for the simulator.
- **A bearer token.** `<account id>.<secret>`, the secret 32 random bytes as base64url. Only the SHA-256 is stored, and it is compared with `crypto.subtle.timingSafeEqual`. Refusals are 401 `bad-token`.
- **`PUT /v1/automations`.** Replaces the account's automations with the payload from WIRE.md, read strictly and checked against `Spec.swift`'s rules (4 per widget, prompts of 1 to 2,000 grapheme clusters, 16 fields, reserved ids, canonical cadence spellings, an IANA zone stored by its canonical name). The three limits refuse with 422, a stable `code`, and a sentence the app shows. Answers `{digest}`, the SHA-256 of the bytes received.
- **Versions, tasks, tombstones in one D1 batch, guarded by a revision.** A version hashes prompt, cadence, time zone, dataset, and fields. New, or a changed prompt or table: a run now plus the next scheduled run. A changed cadence or zone: only the schedule moves. Any change or removal: a `deleteRow` for each of the automation's rows whose `at` is still ahead, under one new stamp of the account's automation replica, selected inside the same batch. The batch writes only if the account's `revision` is still the one it read; otherwise it reads and plans again (3 attempts, then 409 `conflict`). The upload also unparks the account and records it alive.
- **`GET /v1/changes?after=<id>`.** At most 500 changes with ids above `after`, oldest first, the account's automation `replica`, and `nextWrite` (the earliest `due_at` of the account's tasks, at least 5 minutes ahead). A pull records `pulled_at` at most once an hour, records `after` in `pulled_after` when it changed, and re-arms a parked account.
- **Schedule math for P3.** [schedule.ts](../../Backend/src/schedule.ts) has `nextRun` (Foundation's `.nextTime` rules over `Intl` time zones, except where the server keeps its own rule), `dayOf`, `canonicalZone`, and `leadMs`: daily 26 to 38 hours, weekly 7 to 8 days, hourly 65 to 90 minutes, at a stable FNV-1a offset per automation.
- **A wire writer, no reader.** [wire.ts](../../Backend/src/wire.ts) writes stamps, UUIDv7 row keys, day indexes, changes, and pages. The strict reader stays the phone's; phase 4 adds a TypeScript reader with the refusal vectors.
- **Upkeep for P3's daily cron.** [upkeep.ts](../../Backend/src/upkeep.ts): `parkIdle` (30 days without a pull or upload) and `deleteIdle` (90 days).
- **Routes carry their method.** `ROUTES` maps each path to one method, so `GET /v1/changes` and `PUT /v1/automations` sit beside the POST routes. The shared `jsonBody` reads a capped JSON body for the attest routes and the upload.
- **Tests: 233 Worker tests, 154 new.** [account.test.ts](../../Backend/test/account.test.ts), [automations.test.ts](../../Backend/test/automations.test.ts), [changes.test.ts](../../Backend/test/changes.test.ts), [schedule.test.ts](../../Backend/test/schedule.test.ts), [upkeep.test.ts](../../Backend/test/upkeep.test.ts), and [wire.test.ts](../../Backend/test/wire.test.ts), on [helpers/accounts.ts](../../Backend/test/helpers/accounts.ts). [vitest.config.ts](../../Backend/vitest.config.ts) reads the migrations in Node and [setup.ts](../../Backend/test/setup.ts) applies them to the local D1 before each file. The test configuration is production's with `DEV_REGISTRATION_SECRET` set, so a test can prove production refuses it.
- **D1 setup before the first deploy.** [wrangler.jsonc](../../Backend/wrangler.jsonc) binds `DB` with placeholder database ids and adds `ENVIRONMENT`. From `Backend/`:

  ```sh
  npx wrangler d1 create widgie
  npx wrangler d1 create widgie-dev
  # put the two printed database ids in wrangler.jsonc in place of the PLACEHOLDER values
  npx wrangler d1 migrations apply widgie-dev --env dev --remote
  npx wrangler d1 migrations apply widgie --remote
  npx wrangler secret put DEV_REGISTRATION_SECRET --env dev
  ```

## 1. Registering an account: `POST /v1/account`

The phone (P4) registers once with its App Attest key and keeps the token in a Keychain group the extension shares. The simulator, which cannot attest, uses the dev secret on `dev`.

```mermaid
flowchart TD
  REQ["POST /v1/account"] --> DEV{"X-Widgie-Dev-Secret header?"}
  DEV -->|"yes"| DR["devRegistration: ENVIRONMENT is dev, secret set, SHA-256 of both compared with timingSafeEqual"]
  DR -->|"no"| R401d["401 bad-dev-secret"]
  DR -->|"yes"| E1{"body empty?"}
  E1 -->|"no"| R413a["413"]
  E1 -->|"yes"| REGD["register(DB, attestKey null): always a new account"]
  DEV -->|"no"| HDR["X-Widgie-Key canonical, X-Widgie-Assertion base64 under 1 KB"]
  HDR -->|"bad"| R401u["401 bad-assertion (unsigned)"]
  HDR --> E2{"body empty?"}
  E2 -->|"no"| R413b["413"]
  E2 -->|"yes"| CD["client data: POST newline /v1/account newline hex SHA256 of empty"]
  CD --> VER["AttestedKey.verify: signature, rpIdHash, rising counter, stores counter, no quota"]
  VER -->|"unknown-key or bad-assertion"| R401k["401 with code"]
  VER -->|"ok"| REGA["register(DB, keyId)"]
  REGA --> UPS["INSERT accounts (new id, token hash, key, new replica) ON CONFLICT (attest_key) DO UPDATE token_hash RETURNING id"]
  REGD --> UPS
  UPS --> TOK["200 {token: id.base64url(secret)}"]
  TOK -.-> AUTH["later routes: authenticate(Authorization)"]
  AUTH --> PARSE["Bearer uuid.43 chars, canonical base64url only"]
  PARSE --> ROW["SELECT the account row by id"]
  ROW --> CMP["timingSafeEqual(hex SHA256(secret), token_hash)"]
  CMP -->|"fail"| R401t["401 bad-token"]
  CMP -->|"ok"| ACC["Account {id, replica, timeZone, parkedAt}"]
```

Files:

- [index.ts:219](../../Backend/src/index.ts#L219): `account`. The dev branch at line 224, the signed branch from line 232, the client data at line 237, `verify` at 238. [index.ts:244](../../Backend/src/index.ts#L244): `devRegistration`. [index.ts:250](../../Backend/src/index.ts#L250): `isEmpty`, a `readCapped` of 0 bytes. [index.ts:53](../../Backend/src/index.ts#L53): the new refusal codes.
- [attested-key.ts:90](../../Backend/src/attested-key.ts#L90): `verify`, sharing `check` (line 94) with `verifyAndReserve`. The no-quota branch is at line 112.
- [accounts.ts:24](../../Backend/src/accounts.ts#L24): `register`. [accounts.ts:40](../../Backend/src/accounts.ts#L40): `authenticate`, with the canonical spelling check at line 45 and the constant-time compare at line 60.
- [0001_automations.sql:10](../../Backend/migrations/0001_automations.sql#L10): `accounts`, `attest_key UNIQUE` and `replica UNIQUE`.
- [wrangler.jsonc](../../Backend/wrangler.jsonc): `ENVIRONMENT` is `production` at the top level and `dev` under `env.dev`. [env.d.ts](../../Backend/src/env.d.ts): `ENVIRONMENT`, `DEV_REGISTRATION_SECRET`, `DB`.
- Tests: [account.test.ts:38](../../Backend/test/account.test.ts#L38) (a token, same account on re-register and the old token stops working, no build quota taken, replay and misdirected assertions, a body refused), [account.test.ts:102](../../Backend/test/account.test.ts#L102) (production refuses the right secret, dev accepts it, wrong or empty or unconfigured is refused), [account.test.ts:134](../../Backend/test/account.test.ts#L134) (malformed and non-canonical tokens).

Key decisions:

- **The token, not an assertion, guards sync routes.** The widget extension has no App Attest key and an attest key changes on reinstall, so App Attest is used once to name the account and a token does the rest (as the phase 2b plan recorded).
- **Registration takes no build quota** but still stores the counter, so a captured registration cannot be replayed.
- **One statement makes or finds the account.** `ON CONFLICT (attest_key)` means two concurrent registrations of one key can never make two accounts. Re-registering rotates the token, so the previous token stops working.
- **The token carries the account id.** The id finds the row with a primary key lookup, and only the secret's hash is compared, in constant time with `timingSafeEqual`, the one comparison in Workers that is.
- **Only the canonical token spelling passes.** The 43rd base64url character holds two bits that must be zero, so one secret never has two accepted spellings.
- **The dev path is closed twice.** It needs `ENVIRONMENT` to be `dev` and the secret to be set, so production refuses it even if the secret were configured there. A dev registration makes a new account each time, since the simulator has no key to name one by.
- **No rate limit on registration for now,** with the other usage limits (see the top). The attest routes keep B2's per-address limit.

## 2. Uploading automations: `PUT /v1/automations`

The phone sends every automation of the account after any change that can move them. The Worker diffs the payload against what it holds and writes the result in one batch.

```mermaid
flowchart TD
  PUT["PUT /v1/automations"] --> AUTH["authenticate: 401 bad-token"]
  AUTH --> BODY["jsonBody: 415, 413 over 256 KB, 400 not JSON"]
  BODY --> PARSE["parsePayload: exact keys, canonicalZone(timeZone), each entry checked, no duplicates"]
  PARSE -->|"BadRequest"| R400["400 with the first problem, prefixed automations[i]"]
  PARSE -->|"OverLimit"| R422["422 with code and sentence: too-many-on-widget, prompt-too-long, too-many-fields"]
  PARSE --> VERS["versionOf(entry, canonical zone) for each entry"]
  VERS --> READ["readState: one batch, SELECT the account's revision and its stored automations"]
  READ --> PLAN["for each payload entry"]
  PLAN --> SAME["same version: same"]
  PLAN --> NEW["not stored: new"]
  PLAN --> CONTENT["prompt, dataset, or fields differ: content"]
  PLAN --> SCHED["only cadence or zone differ: schedule"]
  READ --> REM["stored but missing from the payload: removed"]
  CONTENT --> TOMB["tombstoned set"]
  SCHED --> TOMB
  REM --> TOMB
  TOMB --> BATCH["one db.batch"]
  NEW --> BATCH
  SAME --> BATCH
  BATCH --> S1["first: UPDATE accounts revision = CASE WHEN revision = read THEN +1 END, time_zone, last_stamp when anything is tombstoned, pulled_at = max(pulled_at, now), parked_at NULL"]
  S1 -->|"revision moved: NULL fails NOT NULL, D1 rolls back the whole batch"| RETRY{"revision re-read differs?"}
  RETRY -->|"yes, attempts left"| READ
  RETRY -->|"yes, 3rd attempt"| R409["409 conflict"]
  RETRY -->|"no"| R500["rethrow: the batch's own failure"]
  BATCH --> S2["per tombstoned: TOMBSTONES, INSERT INTO changes SELECT deleteRow for its insertRow with at after now and no deleteRow yet"]
  BATCH --> S3["per removed: DELETE automations (tasks cascade)"]
  BATCH --> S4["per new or content: upsert automation, delete its tasks, insert run now (once 1, due now), insert schedule"]
  BATCH --> S5["per schedule: upsert automation, delete schedule task, run now takes the new version, insert new schedule"]
  BATCH --> S6["per same: INSERT OR IGNORE its schedule, back if parking took it"]
  S1 --> OK["200 {digest: hex SHA256(body bytes)}"]
```

Files:

- [index.ts:264](../../Backend/src/index.ts#L264): `automations`, the refusals at line 275, the digest at line 283. [index.ts:300](../../Backend/src/index.ts#L300): `jsonBody`. [index.ts:42](../../Backend/src/index.ts#L42): `MAX_AUTOMATIONS_BODY`, a memory guard, not a usage limit. [index.ts:55](../../Backend/src/index.ts#L55): `conflict`.
- [automations.ts:24](../../Backend/src/automations.ts#L24): `LIMITS`. [automations.ts:37](../../Backend/src/automations.ts#L37): `OverLimit` and its codes. [automations.ts:83](../../Backend/src/automations.ts#L83): `parsePayload`, the zone at line 86, the per-widget check at line 106. [automations.ts:116](../../Backend/src/automations.ts#L116): one entry, with the grapheme count and `prompt-too-long` at line 132. [automations.ts:149](../../Backend/src/automations.ts#L149): `cadence`, canonical `"06:00"` and `":15"` only. [automations.ts:174](../../Backend/src/automations.ts#L174): `fieldKinds`, `too-many-fields` at line 179.
- [automations.ts:256](../../Backend/src/automations.ts#L256): `versionOf`. [automations.ts:316](../../Backend/src/automations.ts#L316): `TOMBSTONES`. [automations.ts:330](../../Backend/src/automations.ts#L330): `replaceAutomations`, the retry loop at line 341 and the revision re-read from line 349. [automations.ts:358](../../Backend/src/automations.ts#L358): `readState`. [automations.ts:374](../../Backend/src/automations.ts#L374): `replaceStatements`: the plan at line 383, the revision statement at line 403, tombstones at 413, removals at 416, upserts and tasks from 423 (the `same` re-arm at 425).
- [automations.ts:270](../../Backend/src/automations.ts#L270): `scheduleTask` (section 4). [automations.ts:283](../../Backend/src/automations.ts#L283): `insertTask`, with `ifAbsent` for re-arming.
- [0001_automations.sql:27](../../Backend/migrations/0001_automations.sql#L27): `automations`. [0001_automations.sql:44](../../Backend/migrations/0001_automations.sql#L44): `tasks`, `UNIQUE (account, widget, automation, once)`. [0001_automations.sql:65](../../Backend/migrations/0001_automations.sql#L65): `changes`, and its indexes at lines 80 to 83.
- [wire.ts:58](../../Backend/src/wire.ts#L58): `nextStamp`, the rule the SQL stamp mirrors. [wire.ts:90](../../Backend/src/wire.ts#L90): `mintRowKey`.
- Tests: [automations.test.ts:94](../../Backend/test/automations.test.ts#L94) (a new automation gets a run now and its schedule), [automations.test.ts:148](../../Backend/test/automations.test.ts#L148) (same payload changes nothing, content change, cadence change, zone change, removal), [automations.test.ts:226](../../Backend/test/automations.test.ts#L226) (tombstones: rows ahead only, one rising stamp even when the clock goes back, once per row, never for an unchanged automation), [automations.test.ts:286](../../Backend/test/automations.test.ts#L286) (payload refusals, the three limits with their codes and sentences, the limits at their edge, no usage limits, the canonical zone), [automations.test.ts:452](../../Backend/test/automations.test.ts#L452) (concurrent uploads: the review's interleaving, and a batch that fails its revision check writes nothing), [automations.test.ts:501](../../Backend/test/automations.test.ts#L501) (`EXPLAIN QUERY PLAN` of the tombstones and the read-back uses the new indexes), [upkeep.test.ts:58](../../Backend/test/upkeep.test.ts#L58) (an upload unparks and re-arms).

Key decisions:

- **Replace-all.** The upload is idempotent, has no orphans, and needs no outbox on the phone. An automation missing from the payload is a removal.
- **The version decides the work.** A content change (prompt, dataset, fields) gets a run now so a refine shows at once, and a fresh schedule with a new row key. A schedule-only change keeps the pending run now and its row key, gives it the new version, and moves only the schedule. An unchanged automation writes nothing but an `INSERT OR IGNORE` of its schedule.
- **An optimistic revision, not a lock.** The read happens outside the batch, so another upload can commit in between: S0 is stored, B reads S0 to upload S0 again, A commits S1, and B's plan from S0 would write nothing and acknowledge S0's digest while the server holds S1. The batch's first statement sets `revision` to NULL on a mismatch; `revision` is NOT NULL, so the statement fails and D1 rolls back the whole batch (the test checks nothing of it is stored). B then re-reads S1 and plans S0 from it. Every upload raises the revision, even an unchanged one. After 3 attempts it answers 409 `conflict` and the phone sends again on its next foreground. A failed batch whose revision did not move is rethrown, so a real error is never retried as a conflict.
- **Tombstones are selected inside the batch.** The batch is one D1 transaction, so a P3 runner's write either lands before the tombstones (and is deleted by them) or after (and finds its version gone, so the version guard drops it).
- **The tombstone query reads only the automation's rows.** The partial index `changes_inserted` holds only `insertRow` changes keyed by automation and `at`, and `changes_deleted` only `deleteRow` changes by row key, so neither scans the account's changes. The plan, recorded in the P2 results note: `SEARCH inserted USING INDEX changes_inserted (account=? AND widget=? AND automation=? AND at>?)`, `SEARCH changes USING COVERING INDEX changes_deleted (account=? AND row_key=?)`, and a temp B-tree for `ORDER BY id` over that automation's rows ahead. The literal `op = 'insertRow'` in the query is what lets SQLite use the partial index; a bound `op = ?` would not.
- **One stamp per write, taken in SQL.** `max(last_stamp + 1, ms * 65536)` runs in the same transaction, so two writers never take the same stamp and the stamp rises even if the Worker's clock goes back. It is taken only when there is something to tombstone.
- **Only rows still ahead are tombstoned.** A revealed row (`at` at or before now) stays as history. A row that already has a `deleteRow` is skipped, so a second change writes no duplicate.
- **An upload re-arms a parked account.** The same statement clears `parked_at` and sets `pulled_at` (now the last pull or upload), so the next `parkIdle` neither deletes the run now the upload just made nor parks the account again; unchanged automations get their schedules back.
- **The three limits are the document's own,** which the engine enforces too: 4 automations a widget, 2,000 characters a prompt, 16 fields a table. Each refuses with 422, a stable `code`, and a sentence: `A widget has 5 automations, and the limit is 4 a widget.`, `The prompt of "daily" is 2001 characters, and the limit is 2000.`, `"daily" writes 17 fields, and the limit is 16.` The usage limits (60 runs a day, 16 automations an account) were built in review, then removed by the user with the spend cap and rate limits.
- **The zone is stored by its canonical name.** `canonicalZone` answers Intl's `resolvedOptions().timeZone`, so every spelling of a zone is one stored name and one version, and the formatter cache is keyed by it. Requiring the phone's spelling to equal the canonical one was the review's suggestion, but this runtime's Intl resolves links ("Asia/Kolkata" to "Asia/Calcutta", "Europe/Kyiv" to "Europe/Kiev", "GMT" to "UTC") and `TimeZone.current.identifier` sends "Asia/Kolkata", so that would refuse India.
- **The cadence takes only the canonical spellings** the engine writes. Swift's reader also takes `"+6:00"`, which no payload carries.
- **The payload is read strictly** (unknown, missing, or wrongly typed keys are refused), except duplicate JSON keys, since `JSON.parse` keeps the last.
- **The digest is of the bytes received,** which the phone compares with its own `automationPayload().digest` to know the server has its latest.

## 3. Pulling changes: `GET /v1/changes?after=<id>`

The app and the extension (P4) pull with their watermark and hand the bytes to `RemotePage(json:)`.

```mermaid
flowchart TD
  GET["GET /v1/changes?after=id"] --> AUTH["authenticate: 401 bad-token"]
  AUTH --> AFTER["after: 0 or digits with no leading zero, at most 2^53 - 1"]
  AFTER -->|"bad"| R400["400"]
  AFTER --> PARK{"account parked?"}
  PARK -->|"yes"| REARM["rearm: INSERT OR IGNORE a schedule task per automation from now, parked_at NULL"]
  PARK -->|"no"| BATCH
  REARM --> BATCH["one db.batch"]
  BATCH --> Q1["SELECT id, change FROM changes WHERE account AND id after ORDER BY id LIMIT 500"]
  BATCH --> Q2["SELECT min(due_at) FROM tasks WHERE account"]
  BATCH --> Q3["UPDATE pulled_at if an hour old, pulled_after = after, only when either changes"]
  Q1 --> ENC["encodePage(replica, stored change JSON, nextWrite)"]
  Q2 --> NW["nextWrite = max(min due_at, now + 5 min), or null"]
  NW --> ENC
  ENC --> RES["200 replica, changes [id, change], nextWrite (log: count)"]
  RES -.-> PHONE["phone: Engine.receive, next pull from the new watermark"]
```

Files:

- [index.ts:288](../../Backend/src/index.ts#L288): `changes`, the `after` check at line 293. [index.ts:96](../../Backend/src/index.ts#L96): `encoded` on the responder, for a body already encoded.
- [accounts.ts:67](../../Backend/src/accounts.ts#L67): `pull`, the batch at line 74, the liveness and watermark update at line 82, `nextWrite` at line 90. [accounts.ts:13](../../Backend/src/accounts.ts#L13): `NEXT_WRITE_GAP`. [accounts.ts:96](../../Backend/src/accounts.ts#L96): `rearm`. [accounts.ts:11](../../Backend/src/accounts.ts#L11): `PAGE_SIZE`.
- [wire.ts:159](../../Backend/src/wire.ts#L159): `encodePage`, from changes as the table stores them. [wire.ts:137](../../Backend/src/wire.ts#L137): `encodeChange`, keys in WIRE.md's order, which P3's runner will use to fill `changes.change`.
- [upkeep.ts:13](../../Backend/src/upkeep.ts#L13): `parkIdle` (marks and deletes tasks). [upkeep.ts:24](../../Backend/src/upkeep.ts#L24): `deleteIdle` (cascades).
- [0001_automations.sql:80](../../Backend/migrations/0001_automations.sql#L80): `changes_account (account, id)`, the pull's index.
- [WIRE.md:74](../engine/WIRE.md#L74): `nextWrite`, now never sooner than five minutes after the pull.
- Tests: [changes.test.ts:64](../../Backend/test/changes.test.ts#L64) (empty page with the replica, paging by 500 in the wire format, `after` skipping other accounts' ids, `nextWrite` is the earliest `due_at` but at least 5 minutes ahead, bad `after`, `pulled_at` hourly, `pulled_after` is the last pull's watermark, re-arm, a schedule uploaded meanwhile is kept). [upkeep.test.ts:38](../../Backend/test/upkeep.test.ts#L38) (park, unpark by upload, delete). [wire.test.ts:82](../../Backend/test/wire.test.ts#L82) (every good change and page vector written byte for byte from what it means).

Key decisions:

- **Ids only grow.** `AUTOINCREMENT` never reuses an id after cleanup, so a phone's watermark stays valid forever. Ids may skip, as WIRE.md allows, since one table serves every account.
- **The page is assembled from stored bytes.** Each change is encoded once when it is written, and a pull only joins strings, so it costs almost no CPU.
- **`nextWrite` is the earliest `due_at`,** when the server expects to write, not the earliest `run_at`, but never sooner than 5 minutes after the pull. A due task waiting for the cron would otherwise name a time in the past and make the extension pull at every render. WIRE.md's `nextWrite` row says so; that line also lives on PR 22.
- **Every page names the replica,** even an empty one, so the first pull puts the automation replica in the phone's `mine`.
- **A pull is the liveness signal, with an upload.** `pulled_at` is written at most once an hour to spare D1 writes. A parked account (30 days idle) is re-armed by its next pull with `INSERT OR IGNORE`, so a schedule an upload made meanwhile stays.
- **The last pull's watermark is kept for the cleanup.** `pulled_after` is the `after` of the last pull, written only when it changes: the phone has every change up to it. It is the last, not the largest, so a phone set up again from 0 holds the cleanup back until it catches up.
- **The Worker writes the format and reads none of it.** The good vectors are checked by building each change from its `means` and comparing bytes, so the test never trusts the writer's own reading. The refusal vectors wait for phase 4's TypeScript reader.

## 4. The schedule math P3's cron will use: `nextRun` and lead times

Each task's `run_at` is the row's `at` and its `due_at` is when the cron should claim it. P2 computes both on upload and re-arm; P3's runner will call the same `scheduleTask` after each run.

```mermaid
flowchart TD
  ST["scheduleTask(account, row, timeZone, now)"] --> CAD["cadenceOf(row): hour minute, day hour minute, or week weekday hour minute"]
  CAD --> NR["nextRun(cadence, zone, now): first run strictly after now"]
  NR -->|"hour"| NH["nextHourly: every instant whose wall clock shows the minute, so a repeated hour runs twice and a skipped hour not at all"]
  NR -->|"day or week"| LOOP["days from wall day - 1 through +9, weekday filter"]
  LOOP --> INST["firstInstant(zone, day, hour, minute)"]
  INST -->|"one instant"| ONE["normal day"]
  INST -->|"two instants"| TWO["clocks fall back: the first only"]
  INST -->|"none"| GAP["clocks skip it: binary search to the minute of the change, run then"]
  ONE --> CMP{"first instant after now?"}
  TWO --> CMP
  GAP --> CMP
  CMP -->|"no: the day has had its run"| LOOP
  CMP -->|"yes"| RUN["runAt"]
  NH --> RUN
  RUN --> LEAD["leadMs(every, leadSeed(account, widget, automation))"]
  LEAD --> WIN["min + FNV-1a fraction x (max - min): hour 65 to 90 min, day 26 to 38 h, week 7 to 8 days"]
  WIN --> DUE["dueAt = runAt - lead"]
  DUE --> TASK["task {once 0, runAt, dueAt, rowKey: UUIDv7 minted now}"]
  RUN --> DAY["dayOf(runAt, zone): the row's day for P3's insertRow"]
```

Files:

- [schedule.ts:131](../../Backend/src/schedule.ts#L131): `nextRun`. [schedule.ts:152](../../Backend/src/schedule.ts#L152): `firstInstant`, the skipped-time search at line 160. [schedule.ts:173](../../Backend/src/schedule.ts#L173): `nextHourly`. [schedule.ts:122](../../Backend/src/schedule.ts#L122): `offset`, from `Intl.DateTimeFormat.formatToParts`. [schedule.ts:117](../../Backend/src/schedule.ts#L117): `dayOf`. [schedule.ts:83](../../Backend/src/schedule.ts#L83): `canonicalZone`, names only, no offsets. [schedule.ts:68](../../Backend/src/schedule.ts#L68): `formatter`, cached by canonical name.
- [schedule.ts:24](../../Backend/src/schedule.ts#L24): `LEADS`. [schedule.ts:32](../../Backend/src/schedule.ts#L32): `leadMs`, with the FNV-1a fraction at line 38.
- [automations.ts:265](../../Backend/src/automations.ts#L265): `leadSeed`. [automations.ts:270](../../Backend/src/automations.ts#L270): `scheduleTask`.
- [wire.ts:111](../../Backend/src/wire.ts#L111): `dayIndex`, Hinnant's `days_from_civil`, the same index as Swift's `Day`.
- Tests: [schedule.test.ts:27](../../Backend/test/schedule.test.ts#L27) (daily: wall time, spring forward, fall back runs once, never the second of a repeated time even asked from between, half-hour zones, 06:00 local on every day of a year, Lord Howe's half-hour gap), [schedule.test.ts:128](../../Backend/test/schedule.test.ts#L128) (weekly, including a skipped time on its day), [schedule.test.ts:154](../../Backend/test/schedule.test.ts#L154) (hourly across both changes), [schedule.test.ts:188](../../Backend/test/schedule.test.ts#L188) (leads stay in their windows and are stable), [schedule.test.ts:208](../../Backend/test/schedule.test.ts#L208) (zone names, and one canonical name for every spelling). [wire.test.ts:48](../../Backend/test/wire.test.ts#L48) (day vectors from 0001-01-01 through 9999-12-31).

Key decisions:

- **Foundation's rules, with three deliberate differences.** `nextRun` matches every case printed from `Calendar.nextDate(... .nextTime)` across DST in New York, London, Santiago, Havana, Kolkata, and Lord Howe, except three. Where Foundation skips a run (a weekly time the clocks skip, where it moves a week, and a time inside Lord Howe's half-hour gap, where it moves a day), the Worker runs at the moment the clocks change. And on the fall-back night Foundation answers a repeated time's second instant when asked from between the two, so a daily run could happen twice; the server's rule is that a time that happens twice runs once, at the first, and a day whose first instant is at or before `after` has had its run. The phone only uses its `nextRun` for its reload time, so the server's answer decides when a row shows. P3 aligns `Automations.swift` to these rules and its exported vectors include all three.
- **`Intl` carries the tz database,** the same one Foundation reads, so no zone data ships with the Worker.
- **Leads are more than one period.** A row is on the phone a full period before its time, so its timeline entry changes the face offline and a cron minute missed during a deploy costs nothing.
- **Each automation has a stable place in its window,** hashed from account, widget, and automation id, so one time zone's 06:00 does not reach the model service at once, and a re-upload does not move the due time.
- **The row key is minted with the task,** so a replayed P3 write reuses it and lands on the same row.
