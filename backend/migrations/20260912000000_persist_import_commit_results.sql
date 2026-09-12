ALTER TABLE imports
    ADD COLUMN products_created bigint CHECK (products_created >= 0),
    ADD COLUMN products_updated bigint CHECK (products_updated >= 0),
    ADD COLUMN nutrients_inserted bigint CHECK (nutrients_inserted >= 0),
    ADD COLUMN servings_inserted bigint CHECK (servings_inserted >= 0),
    ADD COLUMN errors_logged bigint CHECK (errors_logged >= 0);
