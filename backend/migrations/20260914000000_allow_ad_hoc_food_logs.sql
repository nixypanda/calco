ALTER TABLE food_logs
    DROP CONSTRAINT exactly_one_item;

ALTER TABLE food_logs
    ADD CONSTRAINT exactly_one_item CHECK (
        (item_product_id IS NOT NULL)::INT
        + (item_meal_id IS NOT NULL)::INT <= 1
    );
