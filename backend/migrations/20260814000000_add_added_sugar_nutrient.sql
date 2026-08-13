INSERT INTO nutrients (code, name, unit, category)
VALUES ('ADDED_SUGAR_G', 'Added Sugars', 'g', 'macro')
ON CONFLICT (code) DO NOTHING;
