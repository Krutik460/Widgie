-- One row per email. People who share a home or a couple share a pair_code: the founder's row gets a fresh code and
-- everyone who joins through their link takes the same one. A pair counts its confirmed rows only.
CREATE TABLE signups (
    id INTEGER PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    segment TEXT NOT NULL CHECK (segment IN ('home', 'us')),
    pair_code TEXT NOT NULL,
    joined_via_link INTEGER NOT NULL DEFAULT 0,
    idea TEXT,
    source TEXT,
    created_at TEXT NOT NULL,
    sent_at TEXT NOT NULL,
    confirmed_at TEXT
);

CREATE INDEX signups_pair ON signups (pair_code);
