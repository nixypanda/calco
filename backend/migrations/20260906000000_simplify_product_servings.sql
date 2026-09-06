-- Preserve the implicit default previously supplied by the first serving. The
-- old serving quantity remains meaningful as the default amount after grams is
-- normalized to a per-unit value.
WITH first_servings AS (
    SELECT DISTINCT ON (product_id)
        product_id,
        quantity,
        unit
    FROM product_servings
    ORDER BY product_id, position, created_at, id
)
UPDATE products AS product
SET default_quantity = serving.quantity,
    default_unit = serving.unit
FROM first_servings AS serving
WHERE product.id = serving.product_id
  AND product.default_quantity IS NULL
  AND product.default_unit IS NULL;

ALTER TABLE product_servings
    DROP CONSTRAINT product_servings_quantity_positive;

UPDATE product_servings
SET grams = grams / quantity;

ALTER TABLE product_servings
    RENAME COLUMN grams TO grams_per_unit;

ALTER TABLE product_servings
    RENAME CONSTRAINT product_servings_grams_positive
    TO product_servings_grams_per_unit_positive;

ALTER TABLE product_servings
    DROP COLUMN label,
    DROP COLUMN quantity;

-- The staging primary key previously allowed multiple labels for the same unit.
-- Retain the row that the import finalizer would have selected, so pending
-- imports continue deterministically under the new one-row-per-unit model.
WITH ranked_servings AS (
    SELECT
        ctid,
        row_number() OVER (
            PARTITION BY import_id, source, source_id, unit
            ORDER BY row_number NULLS LAST, label
        ) AS unit_rank
    FROM staging_product_servings
)
DELETE FROM staging_product_servings AS serving
USING ranked_servings AS ranked
WHERE serving.ctid = ranked.ctid
  AND ranked.unit_rank > 1;

UPDATE staging_product_servings
SET grams = grams / quantity;

ALTER TABLE staging_product_servings
    DROP CONSTRAINT staging_product_servings_pkey;

ALTER TABLE staging_product_servings
    RENAME COLUMN grams TO grams_per_unit;

ALTER TABLE staging_product_servings
    DROP COLUMN label,
    DROP COLUMN quantity;

ALTER TABLE staging_product_servings
    ADD CONSTRAINT staging_product_servings_grams_per_unit_positive
    CHECK (grams_per_unit > 0),
    ADD PRIMARY KEY (import_id, source, source_id, unit);
