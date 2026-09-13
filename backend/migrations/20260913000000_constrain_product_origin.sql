ALTER TABLE products
    ADD CONSTRAINT products_origin_consistent
    CHECK (
        (
            source = 'USER'
            AND user_id IS NOT NULL
            AND source_id IS NULL
            AND barcode IS NULL
        )
        OR
        (
            source IN ('OFF', 'USDA', 'IFCT', 'INDB')
            AND user_id IS NULL
            AND source_id IS NOT NULL
            AND btrim(source_id) <> ''
        )
    ) NOT VALID;

ALTER TABLE products
    VALIDATE CONSTRAINT products_origin_consistent;
