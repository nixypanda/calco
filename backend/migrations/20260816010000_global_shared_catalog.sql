-- CalCo is a shared homelab catalog. Products are visible to every authenticated
-- user; user_id remains creator attribution for creator-only custom-food writes.

UPDATE products
SET visibility = 'global'
WHERE visibility <> 'global';

ALTER TABLE products
    DROP CONSTRAINT products_visibility_known;

ALTER TABLE products
    ADD CONSTRAINT products_visibility_global_only
    CHECK (visibility = 'global');
