CREATE INDEX identities_username_idx ON identities (username);
CREATE INDEX sessions_token_hash_idx ON sessions (session_token_hash);
CREATE INDEX sessions_identity_id_idx ON sessions (identity_id);
CREATE INDEX sessions_expires_at_idx ON sessions (expires_at);
