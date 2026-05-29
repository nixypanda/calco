CREATE TABLE food_logs (
    id              UUID PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES user_profiles(id),
    logged_at       TIMESTAMPTZ NOT NULL,
    meal_slot       TEXT,
    item_product_id UUID REFERENCES products(id),
    item_meal_id    UUID,
    quantity        NUMERIC NOT NULL,
    unit            TEXT NOT NULL,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT exactly_one_item CHECK (
        (item_product_id IS NOT NULL)::INT +
        (item_meal_id IS NOT NULL)::INT = 1
    )
);

CREATE INDEX idx_food_logs_user_date ON food_logs (user_id, logged_at);
CREATE INDEX idx_food_logs_user_meal ON food_logs (user_id, meal_slot, logged_at);

CREATE TABLE food_log_nutrients (
    food_log_id UUID NOT NULL REFERENCES food_logs(id) ON DELETE CASCADE,
    nutrient_id uuid NOT NULL REFERENCES nutrients(id),
    amount      NUMERIC NOT NULL,
    unit        TEXT NOT NULL,
    PRIMARY KEY (food_log_id, nutrient_id)
);
