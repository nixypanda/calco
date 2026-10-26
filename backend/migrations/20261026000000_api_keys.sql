CREATE TABLE IF NOT EXISTS api_keys (
    id UUID PRIMARY KEY,
    identity_id UUID NOT NULL REFERENCES identities(id),
    identity_security_stamp UUID NOT NULL,
    name TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    token_hint TEXT NOT NULL,
    scope TEXT NOT NULL CHECK (scope IN ('read', 'read_write')),
    created_at TIMESTAMPTZ NOT NULL,
    last_used_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    CONSTRAINT api_keys_name_length
        CHECK (char_length(name) BETWEEN 1 AND 64),
    CONSTRAINT api_keys_expiry_after_creation
        CHECK (expires_at IS NULL OR expires_at > created_at)
);

CREATE INDEX IF NOT EXISTS api_keys_identity_id_idx ON api_keys (identity_id);
