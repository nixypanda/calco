ALTER TABLE units
    ADD COLUMN IF NOT EXISTS canonical_grams numeric;

UPDATE units SET canonical_grams = 1        WHERE code = 'g';
UPDATE units SET canonical_grams = 1000     WHERE code = 'kg';
UPDATE units SET canonical_grams = 0.001    WHERE code = 'mg';
UPDATE units SET canonical_grams = 0.000001 WHERE code = 'ug';
