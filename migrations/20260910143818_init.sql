-- Add migration script here
CREATE TABLE IF NOT EXISTS links (
    id BIGSERIAL PRIMARY KEY,
    code TEXT NOT NULL UNIQUE,
    url TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)