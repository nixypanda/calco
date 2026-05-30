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
