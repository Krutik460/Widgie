-- The two audiences are now partners and growth. "home" and "us" stay valid for rows made before the change.
-- SQLite cannot alter a CHECK constraint, so the table is rebuilt with the same columns.
CREATE TABLE signups_next (
    id INTEGER PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    segment TEXT NOT NULL CHECK (segment IN ('partners', 'growth', 'home', 'us')),
    pair_code TEXT NOT NULL,
    joined_via_link INTEGER NOT NULL DEFAULT 0,
    idea TEXT,
    source TEXT,
    created_at TEXT NOT NULL,
    sent_at TEXT NOT NULL,
    confirmed_at TEXT
);

INSERT INTO signups_next SELECT id, email, segment, pair_code, joined_via_link, idea, source, created_at, sent_at, confirmed_at FROM signups;
DROP TABLE signups;
ALTER TABLE signups_next RENAME TO signups;
CREATE INDEX signups_pair ON signups (pair_code);
