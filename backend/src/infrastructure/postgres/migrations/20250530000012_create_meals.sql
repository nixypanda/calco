CREATE TABLE IF NOT EXISTS meals (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    notes TEXT,
    total_quantity_amount NUMERIC,
    total_quantity_unit TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS meal_components (
    id UUID PRIMARY KEY,
    meal_id UUID NOT NULL REFERENCES meals(id) ON DELETE CASCADE,
    component_product_id UUID REFERENCES products(id) ON DELETE SET NULL,
    component_meal_id UUID REFERENCES meals(id) ON DELETE SET NULL,
    quantity NUMERIC NOT NULL,
    unit TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT meal_components_item_check CHECK (
        (component_product_id IS NOT NULL AND component_meal_id IS NULL)
        OR (component_product_id IS NULL AND component_meal_id IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS meal_components_meal_id_idx ON meal_components(meal_id);
CREATE INDEX IF NOT EXISTS meals_user_id_idx ON meals(user_id);
