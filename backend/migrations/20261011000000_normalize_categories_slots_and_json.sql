CREATE TABLE IF NOT EXISTS product_categories (
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    category TEXT NOT NULL,
    PRIMARY KEY (product_id, category)
);

INSERT INTO product_categories (product_id, category)
SELECT DISTINCT product.id, category.value
FROM products AS product
CROSS JOIN LATERAL unnest(product.categories) AS category(value)
ON CONFLICT (product_id, category) DO NOTHING;

CREATE INDEX IF NOT EXISTS product_categories_category_idx ON product_categories(category);

ALTER TABLE products DROP COLUMN IF EXISTS categories;

CREATE TABLE IF NOT EXISTS staging_product_categories (
    import_id UUID NOT NULL REFERENCES imports(id) ON DELETE CASCADE,
    source TEXT NOT NULL,
    source_id TEXT NOT NULL,
    category TEXT NOT NULL,
    PRIMARY KEY (import_id, source, source_id, category)
);

INSERT INTO staging_product_categories (import_id, source, source_id, category)
SELECT DISTINCT staged.import_id, staged.source, staged.source_id, category.value
FROM staging_products AS staged
CROSS JOIN LATERAL unnest(staged.categories) AS category(value)
ON CONFLICT (import_id, source, source_id, category) DO NOTHING;

CREATE INDEX IF NOT EXISTS staging_product_categories_import_id_idx
    ON staging_product_categories(import_id);

ALTER TABLE staging_products DROP COLUMN IF EXISTS categories;

CREATE TABLE IF NOT EXISTS diary_preference_meal_slots (
    user_id UUID NOT NULL REFERENCES user_profiles(id) ON DELETE CASCADE,
    meal_slot TEXT NOT NULL,
    PRIMARY KEY (user_id, meal_slot),
    CONSTRAINT diary_preference_meal_slots_known CHECK (
        meal_slot IN ('breakfast', 'lunch', 'dinner', 'snack', 'late_night_snack')
    )
);

INSERT INTO diary_preference_meal_slots (user_id, meal_slot)
SELECT DISTINCT preferences.user_id, slot.value
FROM diary_preferences AS preferences
CROSS JOIN LATERAL unnest(preferences.enabled_meal_slots) AS slot(value)
ON CONFLICT (user_id, meal_slot) DO NOTHING;

ALTER TABLE diary_preferences DROP COLUMN IF EXISTS enabled_meal_slots;

ALTER TABLE auth_audit_events ALTER COLUMN metadata DROP DEFAULT;
ALTER TABLE auth_audit_events ALTER COLUMN metadata TYPE TEXT USING metadata::text;
ALTER TABLE auth_audit_events ALTER COLUMN metadata SET DEFAULT '{}';

ALTER TABLE staging_products ALTER COLUMN raw_payload TYPE TEXT USING raw_payload::text;
ALTER TABLE staging_product_nutrients ALTER COLUMN raw_payload TYPE TEXT USING raw_payload::text;
ALTER TABLE staging_product_servings ALTER COLUMN raw_payload TYPE TEXT USING raw_payload::text;
ALTER TABLE import_errors ALTER COLUMN raw_payload TYPE TEXT USING raw_payload::text;
