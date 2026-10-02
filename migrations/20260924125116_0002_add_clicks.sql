-- Add migration script here
CREATE TABLE IF NOT EXISTS clicks (
    id BIGSERIAL PRIMARY KEY,
    code TEXT NOT NULL,
    ts TIMESTAMPTZ NOT NULL DEFAULT now(),
    ip_hash TEXT
);
-- GET /:code/stats filters by code; without this it is a sequential scan
-- over a table that grows with every redirect.
CREATE INDEX IF NOT EXISTS idx_clicks_code_ts ON clicks (code,ts DESC);