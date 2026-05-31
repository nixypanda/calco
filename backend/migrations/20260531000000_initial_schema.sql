CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS identities (
    id UUID PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('user', 'admin')),
    status TEXT NOT NULL CHECK (status IN ('active', 'disabled')),
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    last_login_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS user_profiles (
    id UUID PRIMARY KEY,
    identity_id UUID NOT NULL UNIQUE REFERENCES identities(id),
    display_name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    id UUID PRIMARY KEY,
    identity_id UUID NOT NULL REFERENCES identities(id),
    session_token_hash TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS auth_audit_events (
    id UUID PRIMARY KEY,
    actor_identity_id UUID REFERENCES identities(id),
    target_identity_id UUID REFERENCES identities(id),
    event_type TEXT NOT NULL,
    metadata JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS identities_username_idx ON identities (username);
CREATE INDEX IF NOT EXISTS sessions_token_hash_idx ON sessions (session_token_hash);
CREATE INDEX IF NOT EXISTS sessions_identity_id_idx ON sessions (identity_id);
CREATE INDEX IF NOT EXISTS sessions_expires_at_idx ON sessions (expires_at);

CREATE TABLE IF NOT EXISTS nutrients (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL,
    name text NOT NULL,
    unit text NOT NULL,
    category text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS nutrients_code_idx ON nutrients (code);

CREATE TABLE IF NOT EXISTS units (
    code text PRIMARY KEY,
    name text NOT NULL,
    kind text NOT NULL,
    canonical_grams numeric
);

ALTER TABLE units
    ADD COLUMN IF NOT EXISTS canonical_grams numeric;

INSERT INTO units (code, name, kind, canonical_grams) VALUES
    ('g', 'Gram', 'mass', 1),
    ('kg', 'Kilogram', 'mass', 1000),
    ('mg', 'Milligram', 'mass', 0.001),
    ('ug', 'Microgram', 'mass', 0.000001),
    ('ml', 'Millilitre', 'volume', NULL),
    ('l', 'Litre', 'volume', NULL),
    ('serving', 'Serving', 'serving', NULL),
    ('piece', 'Piece', 'count', NULL),
    ('packet', 'Packet', 'count', NULL),
    ('cup', 'Cup', 'volume', NULL),
    ('tbsp', 'Tablespoon', 'volume', NULL),
    ('tsp', 'Teaspoon', 'volume', NULL)
ON CONFLICT (code) DO NOTHING;

UPDATE units SET canonical_grams = 1        WHERE code = 'g';
UPDATE units SET canonical_grams = 1000     WHERE code = 'kg';
UPDATE units SET canonical_grams = 0.001    WHERE code = 'mg';
UPDATE units SET canonical_grams = 0.000001 WHERE code = 'ug';

INSERT INTO nutrients (code, name, unit, category) VALUES
    ('ENERGY_KCAL', 'Energy', 'kcal', 'macro'),
    ('PROTEIN_G', 'Protein', 'g', 'macro'),
    ('CARBS_G', 'Carbohydrates', 'g', 'macro'),
    ('FAT_G', 'Fat', 'g', 'macro'),
    ('FIBER_G', 'Fiber', 'g', 'macro'),
    ('SUGAR_G', 'Sugar', 'g', 'macro'),
    ('SATURATED_FAT_G', 'Saturated Fat', 'g', 'macro'),
    ('TRANS_FAT_G', 'Trans Fat', 'g', 'macro'),
    ('SODIUM_MG', 'Sodium', 'mg', 'micro'),
    ('CHOLESTEROL_MG', 'Cholesterol', 'mg', 'micro'),
    ('POTASSIUM_MG', 'Potassium', 'mg', 'micro'),
    ('CALCIUM_MG', 'Calcium', 'mg', 'micro'),
    ('IRON_MG', 'Iron', 'mg', 'micro'),
    ('MAGNESIUM_MG', 'Magnesium', 'mg', 'micro'),
    ('ZINC_MG', 'Zinc', 'mg', 'micro'),
    ('PHOSPHORUS_MG', 'Phosphorus', 'mg', 'micro'),
    ('VITAMIN_A_UG', 'Vitamin A', 'ug', 'micro'),
    ('VITAMIN_C_MG', 'Vitamin C', 'mg', 'micro'),
    ('VITAMIN_D_UG', 'Vitamin D', 'ug', 'micro'),
    ('VITAMIN_E_MG', 'Vitamin E', 'mg', 'micro'),
    ('VITAMIN_B6_MG', 'Vitamin B6', 'mg', 'micro'),
    ('VITAMIN_B12_UG', 'Vitamin B12', 'ug', 'micro'),
    ('FOLATE_UG', 'Folate', 'ug', 'micro'),
    ('MONOUNSATURATED_FAT_G', 'Monounsaturated Fat', 'g', 'macro'),
    ('POLYUNSATURATED_FAT_G', 'Polyunsaturated Fat', 'g', 'macro')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS products (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source text NOT NULL,
    source_id text,
    user_id uuid REFERENCES user_profiles(id),
    visibility text NOT NULL DEFAULT 'global',
    barcode text,
    name text NOT NULL,
    brand text,
    category text,
    default_quantity numeric,
    default_unit text,
    serving_size_g numeric,
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source, source_id)
);

CREATE INDEX IF NOT EXISTS products_barcode_idx ON products (barcode);
CREATE INDEX IF NOT EXISTS products_source_idx ON products (source);
CREATE INDEX IF NOT EXISTS products_user_id_idx ON products (user_id);
CREATE INDEX IF NOT EXISTS products_brand_idx ON products (brand);
CREATE INDEX IF NOT EXISTS products_category_idx ON products (category);

CREATE TABLE IF NOT EXISTS product_nutrients (
    product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    nutrient_id uuid NOT NULL REFERENCES nutrients(id),
    amount_per_100g numeric NOT NULL,
    source text,
    confidence text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (product_id, nutrient_id)
);

CREATE TABLE IF NOT EXISTS product_servings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    label text NOT NULL,
    quantity numeric NOT NULL,
    unit text NOT NULL,
    grams numeric NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS food_logs (
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

CREATE INDEX IF NOT EXISTS idx_food_logs_user_date ON food_logs (user_id, logged_at);
CREATE INDEX IF NOT EXISTS idx_food_logs_user_meal ON food_logs (user_id, meal_slot, logged_at);

CREATE TABLE IF NOT EXISTS food_log_nutrients (
    food_log_id UUID NOT NULL REFERENCES food_logs(id) ON DELETE CASCADE,
    nutrient_id uuid NOT NULL REFERENCES nutrients(id),
    amount      NUMERIC NOT NULL,
    unit        TEXT NOT NULL,
    PRIMARY KEY (food_log_id, nutrient_id)
);

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

CREATE TABLE IF NOT EXISTS imports (
    id uuid PRIMARY KEY,
    source text NOT NULL,
    status text NOT NULL DEFAULT 'pending',
    created_by uuid REFERENCES user_profiles(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    committed_at timestamptz,
    failed_at timestamptz
);

CREATE TABLE IF NOT EXISTS staging_products (
    import_id uuid NOT NULL REFERENCES imports(id) ON DELETE CASCADE,
    source text NOT NULL,
    source_id text NOT NULL,
    barcode text,
    name text NOT NULL,
    brand text,
    category text,
    serving_size_g numeric,
    raw_payload jsonb,
    row_number integer,
    PRIMARY KEY (import_id, source, source_id)
);

CREATE TABLE IF NOT EXISTS staging_product_nutrients (
    import_id uuid NOT NULL REFERENCES imports(id) ON DELETE CASCADE,
    source text NOT NULL,
    source_id text NOT NULL,
    nutrient_code text NOT NULL,
    amount_per_100g numeric NOT NULL,
    raw_payload jsonb,
    row_number integer,
    PRIMARY KEY (import_id, source, source_id, nutrient_code)
);

CREATE TABLE IF NOT EXISTS import_errors (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    import_id uuid NOT NULL REFERENCES imports(id) ON DELETE CASCADE,
    row_number integer,
    error text NOT NULL,
    raw_payload jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS import_errors_import_id_idx ON import_errors (import_id);
CREATE INDEX IF NOT EXISTS staging_products_import_id_idx ON staging_products (import_id);
CREATE INDEX IF NOT EXISTS staging_nutrients_import_id_idx ON staging_product_nutrients (import_id);

CREATE TABLE IF NOT EXISTS staging_product_servings (
    import_id uuid NOT NULL REFERENCES imports(id) ON DELETE CASCADE,
    source text NOT NULL,
    source_id text NOT NULL,
    label text NOT NULL,
    quantity numeric NOT NULL,
    unit text NOT NULL,
    grams numeric NOT NULL,
    raw_payload jsonb,
    row_number integer,
    PRIMARY KEY (import_id, source, source_id, label, unit)
);

CREATE INDEX IF NOT EXISTS staging_servings_import_id_idx ON staging_product_servings (import_id);
