CREATE TABLE IF NOT EXISTS nutrients (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL,
    name text NOT NULL,
    unit text NOT NULL,
    category text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS nutrients_code_idx ON nutrients (code);
