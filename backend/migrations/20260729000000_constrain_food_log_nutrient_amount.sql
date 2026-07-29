-- rust_decimal::Decimal has a 96-bit mantissa and supports at most 28 digits
-- of scale. Restrict PostgreSQL's otherwise-unbounded NUMERIC so every stored
-- food-log nutrient amount can be decoded without loss.
ALTER TABLE food_log_nutrients
    ALTER COLUMN amount TYPE NUMERIC(28, 12)
    USING round(amount, 12);
