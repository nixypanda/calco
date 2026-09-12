CREATE TABLE product_upsert_operations (
    id uuid PRIMARY KEY,
    products_created bigint NOT NULL DEFAULT 0 CHECK (products_created >= 0),
    products_updated bigint NOT NULL DEFAULT 0 CHECK (products_updated >= 0),
    nutrients_written bigint NOT NULL DEFAULT 0 CHECK (nutrients_written >= 0),
    servings_written bigint NOT NULL DEFAULT 0 CHECK (servings_written >= 0),
    created_at timestamptz NOT NULL DEFAULT now()
);
