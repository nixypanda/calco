CREATE TABLE auth_audit_events (
    id UUID PRIMARY KEY,
    actor_identity_id UUID REFERENCES identities(id),
    target_identity_id UUID REFERENCES identities(id),
    event_type TEXT NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL
);
