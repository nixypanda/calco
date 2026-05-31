ALTER TABLE products
    ADD COLUMN IF NOT EXISTS categories text[] NOT NULL DEFAULT '{}';

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'products' AND column_name = 'category'
    ) THEN
        UPDATE products
        SET categories = COALESCE(
            (
                SELECT ARRAY_AGG(category_value ORDER BY category_value)
                FROM (
                    SELECT DISTINCT LOWER(TRIM(value)) AS category_value
                    FROM UNNEST(STRING_TO_ARRAY(category, ',')) AS value
                    WHERE TRIM(value) <> ''
                ) normalized
            ),
            '{}'
        )
        WHERE category IS NOT NULL;
    END IF;
END $$;

DROP INDEX IF EXISTS products_category_idx;
CREATE INDEX IF NOT EXISTS products_categories_gin_idx ON products USING gin (categories);

ALTER TABLE products
    DROP COLUMN IF EXISTS category;

ALTER TABLE staging_products
    ADD COLUMN IF NOT EXISTS categories text[] NOT NULL DEFAULT '{}';

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'staging_products' AND column_name = 'category'
    ) THEN
        UPDATE staging_products
        SET categories = COALESCE(
            (
                SELECT ARRAY_AGG(category_value ORDER BY category_value)
                FROM (
                    SELECT DISTINCT LOWER(TRIM(value)) AS category_value
                    FROM UNNEST(STRING_TO_ARRAY(category, ',')) AS value
                    WHERE TRIM(value) <> ''
                ) normalized
            ),
            '{}'
        )
        WHERE category IS NOT NULL;
    END IF;
END $$;

ALTER TABLE staging_products
    DROP COLUMN IF EXISTS category;
