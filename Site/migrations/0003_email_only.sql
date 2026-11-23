-- The list is email only. The form asks for nothing else, so a signup from the home page has no audience and is
-- stored as "any". Invites are gone (the app will share widgets itself), so pair codes and joined_via_link go too.
-- SQLite cannot alter a CHECK constraint or drop a NOT NULL column in place, so the table is rebuilt.
CREATE TABLE signups_next (
    id INTEGER PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    segment TEXT NOT NULL CHECK (segment IN ('partners', 'growth', 'any', 'home', 'us')),
    idea TEXT,
    source TEXT,
    created_at TEXT NOT NULL,
    sent_at TEXT NOT NULL,
    confirmed_at TEXT
);

INSERT INTO signups_next SELECT id, email, segment, idea, source, created_at, sent_at, confirmed_at FROM signups;
DROP TABLE signups;
ALTER TABLE signups_next RENAME TO signups;
