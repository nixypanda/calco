INSERT INTO units (code, name, kind) VALUES
    ('g', 'Gram', 'mass'),
    ('kg', 'Kilogram', 'mass'),
    ('mg', 'Milligram', 'mass'),
    ('ug', 'Microgram', 'mass'),
    ('ml', 'Millilitre', 'volume'),
    ('l', 'Litre', 'volume'),
    ('serving', 'Serving', 'serving'),
    ('piece', 'Piece', 'count'),
    ('packet', 'Packet', 'count'),
    ('cup', 'Cup', 'volume'),
    ('tbsp', 'Tablespoon', 'volume'),
    ('tsp', 'Teaspoon', 'volume')
ON CONFLICT (code) DO NOTHING;

INSERT INTO nutrients (code, name, unit, category) VALUES
    ('ENERGY_KCAL', 'Energy', 'kcal', 'macro'),
    ('PROTEIN_G', 'Protein', 'g', 'macro'),
    ('CARBS_G', 'Carbohydrates', 'g', 'macro'),
    ('FAT_G', 'Fat', 'g', 'macro'),
    ('FIBER_G', 'Fiber', 'g', 'macro'),
    ('SUGAR_G', 'Sugar', 'g', 'macro'),
    ('SATURATED_FAT_G', 'Saturated Fat', 'g', 'macro'),
    ('TRANS_FAT_G', 'Trans Fat', 'g', 'macro'),
    ('SODIUM_MG', 'Sodium', 'mg', 'micro'),
    ('CHOLESTEROL_MG', 'Cholesterol', 'mg', 'micro'),
    ('POTASSIUM_MG', 'Potassium', 'mg', 'micro')
ON CONFLICT (code) DO NOTHING;
