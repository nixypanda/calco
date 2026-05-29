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
