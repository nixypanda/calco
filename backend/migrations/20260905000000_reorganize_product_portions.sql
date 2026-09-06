ALTER TABLE product_servings ADD COLUMN position integer;

WITH ranked AS (
    SELECT id, row_number() OVER (PARTITION BY product_id ORDER BY created_at, id) - 1 AS position
    FROM product_servings
)
UPDATE product_servings AS serving SET position = ranked.position
FROM ranked WHERE serving.id = ranked.id;

DELETE FROM product_servings AS duplicate
USING product_servings AS first
WHERE duplicate.product_id = first.product_id
  AND duplicate.unit = first.unit
  AND duplicate.position > first.position;

ALTER TABLE product_servings
    ALTER COLUMN position SET NOT NULL,
    ADD CONSTRAINT product_servings_position_non_negative CHECK (position >= 0),
    ADD CONSTRAINT product_servings_product_position_unique UNIQUE (product_id, position),
    ADD CONSTRAINT product_servings_product_unit_unique UNIQUE (product_id, unit);

UPDATE products AS product
SET default_quantity = product.default_quantity * unit.canonical_grams,
    default_unit = 'g'
FROM units AS unit
WHERE product.default_unit = unit.code
  AND unit.kind = 'mass'
  AND product.default_unit <> 'g';

UPDATE products AS product
SET default_quantity = NULL, default_unit = NULL
WHERE product.default_unit IS NOT NULL
  AND product.default_unit <> 'g'
  AND NOT EXISTS (
      SELECT 1 FROM product_servings AS serving
      WHERE serving.product_id = product.id
        AND serving.unit = product.default_unit
        AND serving.quantity = product.default_quantity
  );

ALTER TABLE products DROP COLUMN serving_size_g;
ALTER TABLE staging_products DROP COLUMN serving_size_g;
