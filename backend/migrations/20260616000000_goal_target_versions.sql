CREATE TABLE IF NOT EXISTS goal_target_versions (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    effective_from DATE NOT NULL,
    calorie_target NUMERIC NOT NULL,
    protein_target_g NUMERIC NOT NULL,
    carbs_target_g NUMERIC NOT NULL,
    fat_target_g NUMERIC NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, effective_from)
);

CREATE INDEX IF NOT EXISTS goal_target_versions_user_effective_from_idx
    ON goal_target_versions (user_id, effective_from DESC);
