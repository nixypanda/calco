-- Defense-in-depth CHECK constraints mirroring the domain-layer validation in
-- the nutrition catalog. Domain code already enforces these invariants; the DB
-- constraints guard against writes that bypass the domain (imports, manual SQL).
--
-- These constraints are expected not to exist yet; the migration is intentionally
-- not guarded so it fails loudly if that assumption is ever violated.

ALTER TABLE products
    ADD CONSTRAINT products_source_known
    CHECK (source IN ('USER', 'OFF', 'USDA', 'IFCT', 'INDB'));

ALTER TABLE products
    ADD CONSTRAINT products_visibility_known
    CHECK (visibility IN ('global', 'user_private'));

ALTER TABLE products
    ADD CONSTRAINT products_serving_size_g_positive
    CHECK (serving_size_g IS NULL OR serving_size_g > 0);

ALTER TABLE products
    ADD CONSTRAINT products_default_quantity_positive
    CHECK (default_quantity IS NULL OR default_quantity > 0);

ALTER TABLE product_servings
    ADD CONSTRAINT product_servings_quantity_positive
    CHECK (quantity > 0);

ALTER TABLE product_servings
    ADD CONSTRAINT product_servings_grams_positive
    CHECK (grams > 0);

ALTER TABLE product_nutrients
    ADD CONSTRAINT product_nutrients_amount_non_negative
    CHECK (amount_per_100g >= 0);
