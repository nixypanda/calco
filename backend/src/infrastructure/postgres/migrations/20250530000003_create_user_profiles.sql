CREATE TABLE user_profiles (
    id UUID PRIMARY KEY,
    identity_id UUID NOT NULL UNIQUE REFERENCES identities(id),
    display_name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);
