-- Which visit and which post brought each person, so the server's confirm and leave events join the same PostHog
-- funnel as that visit and can be split by post. `visitor` is the anonymous PostHog id the form sent; the others are
-- the first touch's medium, campaign, content (the post) and referring site. All null when the form sent none.
ALTER TABLE signups ADD COLUMN visitor TEXT;
ALTER TABLE signups ADD COLUMN medium TEXT;
ALTER TABLE signups ADD COLUMN campaign TEXT;
ALTER TABLE signups ADD COLUMN content TEXT;
ALTER TABLE signups ADD COLUMN referrer TEXT;
