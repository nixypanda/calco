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
