INSERT INTO nutrients (code, name, unit, category) VALUES
    ('CALCIUM_MG', 'Calcium', 'mg', 'micro'),
    ('IRON_MG', 'Iron', 'mg', 'micro'),
    ('MAGNESIUM_MG', 'Magnesium', 'mg', 'micro'),
    ('ZINC_MG', 'Zinc', 'mg', 'micro'),
    ('PHOSPHORUS_MG', 'Phosphorus', 'mg', 'micro'),
    ('VITAMIN_A_UG', 'Vitamin A', 'ug', 'micro'),
    ('VITAMIN_C_MG', 'Vitamin C', 'mg', 'micro'),
    ('VITAMIN_D_UG', 'Vitamin D', 'ug', 'micro'),
    ('VITAMIN_E_MG', 'Vitamin E', 'mg', 'micro'),
    ('VITAMIN_B6_MG', 'Vitamin B6', 'mg', 'micro'),
    ('VITAMIN_B12_UG', 'Vitamin B12', 'ug', 'micro'),
    ('FOLATE_UG', 'Folate', 'ug', 'micro'),
    ('MONOUNSATURATED_FAT_G', 'Monounsaturated Fat', 'g', 'macro'),
    ('POLYUNSATURATED_FAT_G', 'Polyunsaturated Fat', 'g', 'macro')
ON CONFLICT (code) DO NOTHING;
