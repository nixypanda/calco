-- Enforce at most one admin identity. Closes the TOCTOU race in
-- `create_bootstrap_admin` where two concurrent callers can both pass the
-- `admin_exists()` check and insert. Duplicate inserts now surface as a
-- unique-violation that the postgres adapter maps to `AdminAlreadyExists`.
CREATE UNIQUE INDEX IF NOT EXISTS identities_single_admin_idx
    ON identities ((role))
    WHERE role = 'admin';
