ALTER TABLE food_logs
    ADD COLUMN item_name TEXT,
    ADD COLUMN item_brand TEXT;

UPDATE food_logs fl
SET item_name = p.name,
    item_brand = p.brand
FROM products p
WHERE fl.item_product_id = p.id;

UPDATE food_logs fl
SET item_name = m.name,
    item_brand = NULL
FROM meals m
WHERE fl.item_meal_id = m.id;

UPDATE food_logs
SET item_name = CASE
    WHEN item_product_id IS NOT NULL THEN 'Unknown food'
    ELSE 'Unknown meal'
END
WHERE item_name IS NULL;

ALTER TABLE food_logs
    ALTER COLUMN item_name SET NOT NULL;
