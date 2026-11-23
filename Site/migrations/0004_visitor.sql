-- The visitor's anonymous PostHog id, sent by the form, so the server's confirm and leave events join the same funnel as
-- the visit that brought the person. Null when analytics was blocked or the row is older than this column.
ALTER TABLE signups ADD COLUMN visitor TEXT;
