ALTER TABLE food_logs
    ADD COLUMN IF NOT EXISTS idempotency_key TEXT
        CHECK (idempotency_key IS NULL OR char_length(idempotency_key) BETWEEN 1 AND 128);

CREATE UNIQUE INDEX IF NOT EXISTS food_logs_user_idempotency_key_idx
    ON food_logs (user_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;
