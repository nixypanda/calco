ALTER TABLE food_logs
    ADD COLUMN IF NOT EXISTS idempotency_key TEXT,
    ADD COLUMN IF NOT EXISTS request_fingerprint TEXT,
    ADD CONSTRAINT food_logs_idempotency_fields
        CHECK (request_fingerprint IS NULL OR idempotency_key IS NOT NULL),
    ADD CONSTRAINT food_logs_idempotency_key_length
        CHECK (idempotency_key IS NULL OR char_length(idempotency_key) BETWEEN 1 AND 128),
    ADD CONSTRAINT food_logs_request_fingerprint_format
        CHECK (request_fingerprint IS NULL OR request_fingerprint ~ '^[0-9a-f]{64}$');

CREATE UNIQUE INDEX IF NOT EXISTS food_logs_user_idempotency_key_idx
    ON food_logs (user_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;
