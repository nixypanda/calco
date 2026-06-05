ALTER TABLE food_logs
ADD COLUMN log_date DATE;

UPDATE food_logs
SET log_date = (logged_at AT TIME ZONE 'UTC')::date
WHERE log_date IS NULL;

ALTER TABLE food_logs
ADD COLUMN device_timezone TEXT;

ALTER TABLE food_logs
ALTER COLUMN log_date SET NOT NULL;

DROP INDEX IF EXISTS idx_food_logs_user_date;
DROP INDEX IF EXISTS idx_food_logs_user_meal;

ALTER TABLE food_logs
DROP COLUMN logged_at;

CREATE INDEX IF NOT EXISTS idx_food_logs_user_date ON food_logs (user_id, log_date);
CREATE INDEX IF NOT EXISTS idx_food_logs_user_date_meal ON food_logs (user_id, log_date, meal_slot);
