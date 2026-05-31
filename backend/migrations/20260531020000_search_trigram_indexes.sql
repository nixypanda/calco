CREATE INDEX IF NOT EXISTS products_name_trgm_idx
    ON products USING gin (lower(name) gin_trgm_ops);

CREATE INDEX IF NOT EXISTS products_brand_trgm_idx
    ON products USING gin (lower(brand) gin_trgm_ops)
    WHERE brand IS NOT NULL;
