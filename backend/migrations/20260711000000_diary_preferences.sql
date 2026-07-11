CREATE TABLE diary_preferences (
    user_id UUID PRIMARY KEY REFERENCES user_profiles(id) ON DELETE CASCADE,
    enabled_meal_slots TEXT[] NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT diary_preferences_enabled_meal_slots_not_empty
        CHECK (cardinality(enabled_meal_slots) > 0),
    CONSTRAINT diary_preferences_enabled_meal_slots_known
        CHECK (enabled_meal_slots <@ ARRAY[
            'breakfast', 'lunch', 'dinner', 'snack', 'late_night_snack'
        ]::TEXT[])
);
