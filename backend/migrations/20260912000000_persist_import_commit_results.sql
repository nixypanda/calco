ALTER TABLE imports
    ADD COLUMN products_created bigint CHECK (products_created >= 0),
    ADD COLUMN products_updated bigint CHECK (products_updated >= 0),
    ADD COLUMN nutrients_written bigint CHECK (nutrients_written >= 0),
    ADD COLUMN servings_written bigint CHECK (servings_written >= 0),
    ADD COLUMN errors_logged bigint CHECK (errors_logged >= 0);
