# Serving Review Gram Estimates

Manual review recommendations for `data/step-9-out-serving-review.csv`.

Confidence scale: `high` = explicit unit or standard item, `medium` = common household estimate, `low` = ambiguous custom/branded serving.

## Top 20 by Reuse

| description | row_count | example_serving | corrected_serving_grams | confidence | notes |
|---|---:|---|---:|---|---|
| Whey | 268 | 1.0 scoop | 30 | high | standard whey scoop |
| Roti | 242 | 1.0 piese | 40 | high | standard homemade roti |
| Egg White | 202 | 1.0 Egg White | 33 | high | standard large egg white |
| Banana | 127 | 1.0 medium (7" to 7-7/8" long) | 118 | high | standard medium banana edible portion |
| Boiled eggs | 109 | 1.0 egg | 50 | high | standard large boiled egg |
| Protein Lassi Rose flavour | 81 | 200.0 ml | 200 | high | explicit ml serving label |
| Almond Milk, Plain | 50 | 250.0 ml | 250 | high | explicit ml serving label |
| Nutrela - Soya Granules Dry Sabzi | 47 | 1.0 cup cooked | 150 | medium | cup-cooked estimate for soy sabzi |
| Kaddu Ki Sabzi [Indian Pumpkin Vegetable] | 34 | 1.0 bowl | 150 | medium | bowl estimate for cooked sabzi |
| Moong (Yellow) Dal | 30 | 1.0 Cup | 200 | medium | cup estimate for cooked dal |
| Punjabi Kadhi No Pakoras | 28 | 1.0 cup cooked | 240 | medium | cup estimate for kadhi |
| Amul High Protein Blueberry Shake | 27 | 200.0 ml | 200 | high | explicit ml serving label |
| paneer parantha | 22 | 1.0 pcs | 100 | medium | piece estimate for stuffed paratha |
| Aloo beans | 18 | 1.0 cup cooked | 150 | medium | cup-cooked estimate for sabzi |
| Four Fruits Fruit Spread | 18 | 1.0 tbsp | 20 | high | standard tablespoon of fruit spread |
| PRO Bowl - Grilled Barbeque Chicken | 18 | 1.0 bowl | 380 | low | branded bowl estimate |
| Lauki With Chana Dal | 16 | 1.0 cup cooked | 200 | medium | cup-cooked estimate for dal-based sabzi |
| Overnight Oats | 16 | 1.0 serving | 350 | low | custom serving estimate from typical overnight oats jar |
| Strawberry Fruit Spread | 16 | 1.0 tbsp | 20 | high | standard tablespoon of fruit spread |
| Masoor Dhal (Mysore Dal) | 14 | 1.0 cup | 200 | medium | cup estimate for cooked dal |

## All Non-Mass Recommendations

| description | row_count | serving_mode | example_serving | corrected_serving_grams | confidence |
|---|---:|---|---|---:|---|
| Whey | 268 | serving_unit | 1.0 scoop | 30 | high |
| Roti | 242 | serving_unit | 1.0 piese | 40 | high |
| Egg White | 202 | serving_unit | 1.0 Egg White | 33 | high |
| Banana | 127 | serving_unit | 1.0 medium (7" to 7-7/8" long) | 118 | high |
| Boiled eggs | 109 | serving_unit | 1.0 egg | 50 | high |
| Protein Lassi Rose flavour | 81 | volume | 200.0 ml | 200 | high |
| Almond Milk, Plain | 50 | volume | 250.0 ml | 250 | high |
| Nutrela - Soya Granules Dry Sabzi | 47 | serving_unit | 1.0 cup cooked | 150 | medium |
| Kaddu Ki Sabzi [Indian Pumpkin Vegetable] | 34 | serving_unit | 1.0 bowl | 150 | medium |
| Moong (Yellow) Dal | 30 | serving_unit | 1.0 Cup | 200 | medium |
| Punjabi Kadhi No Pakoras | 28 | serving_unit | 1.0 cup cooked | 240 | medium |
| Amul High Protein Blueberry Shake | 27 | volume | 200.0 ml | 200 | high |
| paneer parantha | 22 | serving_unit | 1.0 pcs | 100 | medium |
| Aloo beans | 18 | serving_unit | 1.0 cup cooked | 150 | medium |
| Four Fruits Fruit Spread | 18 | serving_unit | 1.0 tbsp | 20 | high |
| PRO Bowl - Grilled Barbeque Chicken | 18 | serving_unit | 1.0 bowl | 380 | low |
| Lauki With Chana Dal | 16 | serving_unit | 1.0 cup cooked | 200 | medium |
| Overnight Oats | 16 | serving_unit | 1.0 serving | 350 | low |
| Strawberry Fruit Spread | 16 | serving_unit | 1.0 tbsp | 20 | high |
| Masoor Dhal (Mysore Dal) | 14 | serving_unit | 1.0 cup | 200 | medium |
| Sabji | 13 | serving_unit | 1.0 cup | 150 | low |
| AS Protein Bread | 12 | serving_unit | 1.0 serving | 1 | medium |
| Aloo Parwal Ki Sabji | 9 | serving_unit | 1.0 Cup | 150 | medium |
| zucchini sabzi | 9 | serving_unit | 1.0 serving | 150 | medium |
| Aloo Matar | 8 | serving_unit | 0.5 cup | 100 | medium |
| Arhar Daal | 8 | serving_unit | 1.0 household bowl | 180 | medium |
| Egg, boiled | 8 | serving_unit | 1.0 egg | 50 | high |
| Apple | 7 | serving_unit | 1.0 medium | 182 | high |
| Lauki Kofta | 7 | serving_unit | 1.0 katori | 150 | medium |
| Maash Daal | 7 | serving_unit | 1.0 serving | 200 | low |
| Soy milk | 6 | volume | 1.0 mL | 1 | high |
| Sunny Side Up Egg | 6 | serving_unit | 1.0 large | 50 | high |
| Chicken Chettinad | 5 | serving_unit | 6.0 ounce | 170 | high |
| Omelette | 5 | serving_unit | 2.0 eggs | 100 | high |
| Arbi Ki Sabzi | 4 | serving_unit | 1.0 cup (250 gm) | 250 | high |
| Chicken Protein Bowl | 4 | serving_unit | 1.0 Bowl | 380 | low |
| Choco Pie  | 4 | serving_unit | 1.0 pie | 30 | medium |
| Gulab Jamun | 4 | serving_unit | 1.0 piece | 50 | medium |
| Plain hummus | 4 | serving_unit | 1.0 tbsp | 15 | high |
| Rasmalai | 4 | serving_unit | 1.0 piece | 90 | medium |
| Sambar | 4 | serving_unit | 1.0 cup or 100g | 100 | high |
| Soya Paneer Tikki | 4 | serving_unit | 1.0 serving | 1 | medium |
| aloo bhujiya sabzi | 4 | serving_unit | 1.0 bowl | 150 | medium |
| Corn Masala Subji | 3 | serving_unit | 1.0 cup | 150 | medium |
| Kheer | 3 | serving_unit | 1.0 cup | 240 | medium |
| Maggi 2 Minute Noodles | 3 | serving_unit | 1.0 package | 70 | medium |
| Mango | 3 | serving_unit | 1.0 cup, pieces | 165 | medium |
| Pastry | 3 | serving_unit | 1.0 pastry | 80 | low |
| Vegetables | 3 | serving_unit | 1.0 cup | 150 | low |
| stuffed karela ( bharwa karela) | 3 | serving_unit | 1.0 karela | 100 | medium |
| 48 gms protein bread | 2 | serving_unit | 2.0 slices | 48 | high |
| Afghani Chicken | 2 | serving_unit | 1.0 cup cooked | 180 | medium |
| Black Eye Pea Salad | 2 | serving_unit | 1.0 cup | 170 | medium |
| Chicken Burrito With Sour Cream | 2 | serving_unit | 1.0 Burrito | 250 | medium |
| Chicken Momos | 2 | serving_unit | 1.0 plate | 180 | low |
| Chicken Shawarma Wrap | 2 | serving_unit | 1.0 wrap | 220 | medium |
| Chicken Teriyaki | 2 | serving_unit | 6.0 " | 170 | high |
| Egg white | 2 | serving_unit | 1.0 large | 33 | high |
| Ferrero Rocher | 2 | serving_unit | 2.0 pieces | 25 | high |
| Garlic Naan | 2 | serving_unit | 1.0 cup | 60 | low |
| Indian Potato Curry | 2 | serving_unit | 1.0 cup | 150 | medium |
| Mixed Vegetable Cooked Without Potato | 2 | serving_unit | 1.0 serving | 150 | medium |
| PRO Salad - Mexican Paneer | 2 | serving_unit | 1.0 1 | 320 | low |
| Parwal Sabzi | 2 | serving_unit | 1.0 cup cooked | 150 | medium |
| Protein kulfi | 2 | serving_unit | 1.0 Piece | 60 | medium |
| Sauteed | 2 | serving_unit | 0.5 cup cooked | 75 | low |
| Shahi Paneer | 2 | serving_unit | 1.0 cup | 240 | medium |
| Stir Fried | 2 | serving_unit | 1.0 cup | 150 | low |
| Tempeh Fried Masala | 2 | serving_unit | 1.0 serving | 150 | low |
| Thekua | 2 | serving_unit | 1.0 pc | 35 | medium |
| barbeque grilled chicken salad | 2 | serving_unit | 1.0 serving | 300 | low |
| choco mint milkshake | 2 | serving_unit | 1.0 bottle | 250 | medium |
| protein buttermilk | 2 | volume | 200.0 ml | 200 | high |
| (Pint) | 1 | volume | 568.0 ml | 568 | high |
| 1 Egg Plain Omlette | 1 | serving_unit |  | 60 | medium |
| 2 Egg White Omlette | 1 | serving_unit | 2.0 egg whites | 66 | high |
| 3 Egg Bhurji | 1 | serving_unit | 3.0 eggs | 150 | high |
| Almond Raisin Dark Chocolate | 1 | serving_unit | 1.0 bar | 35 | medium |
| Aloo Gobi | 1 | serving_unit | 1.0 cup | 150 | medium |
| Aloo Matar Sabzi | 1 | serving_unit | 1.0 cup cooked | 150 | medium |
| Aloo Prantha | 1 | serving_unit | 1.0 piece | 100 | medium |
| B-Ready | 1 | serving_unit | 1.0 bar | 22 | medium |
| Barbeque Paneer Salad | 1 | serving_unit | 1.0 Bowl | 300 | low |
| Beer | 1 | serving_unit | 1.0 pint | 473 | medium |
| Belgian Waffle | 1 | serving_unit | 1.0 waffle | 75 | medium |
| Belgian Waffle With Nutella | 1 | serving_unit | 1.0 waffle | 120 | low |
| Besan (Gatte) Ki Sabzi/curry | 1 | serving_unit | 1.0 Cup | 200 | medium |
| Boiled Chickpeas | 1 | serving_unit | 1.0 cup | 165 | medium |
| Butter, unsalted | 1 | serving_unit | 1.0 tablespoon | 14 | high |
| Cappuccino | 1 | volume | 150.0 ml | 150 | high |
| Chana Dal Puri | 1 | serving_unit | 1.0 ración | 100 | low |
| Chicken Sausage | 1 | serving_unit | 1.0 sausage | 60 | medium |
| Chicken Shawarma | 1 | serving_unit | 1.0 wrap | 220 | medium |
| Chicken leg, cooked | 1 | serving_unit | 1.0 medium leg | 100 | medium |
| Chicken and veggies salad bowl | 1 | serving_unit | 1.0 bowl | 320 | low |
| Chicken poke bowl | 1 | serving_unit | 1.0 bowl | 350 | low |
| Chili Garlic Noodles  | 1 | serving_unit | 0.333 package | 25 | low |
| Chilli Chicken | 1 | serving_unit | 1.0 cup | 180 | medium |
| Chilli Garlic Noodles | 1 | serving_unit | 1.0 plate | 300 | low |
| Chole Bhature | 1 | serving_unit | 1.0 bhatura with chole | 350 | low |
| Classic Mutton Momos | 1 | serving_unit | 1.0 Piece | 35 | medium |
| Coke Zero | 1 | serving_unit | 1.0 Dose 0,33l | 330 | high |
| Corona Extra Can | 1 | serving_unit | 1.0 can | 330 | high |
| Cream | 1 | volume | 100.0 ml | 100 | high |
| Creamy Chicken With Vegies | 1 | serving_unit | 1.0 serving | 250 | low |
| Cup Noodles Chilli | 1 | serving_unit | 1.0 unit | 70 | medium |
| Egg | 1 | serving_unit | 1.0 large | 50 | high |
| Eggs | 1 | serving_unit | 1.0 large | 50 | high |
| Fried chicken wings | 1 | serving_unit | 1.0 wing | 35 | medium |
| Garlic Bread | 1 | serving_unit | 1.0 slice | 30 | medium |
| Garlic Toast | 1 | serving_unit | 2.0 slices | 60 | medium |
| Grilled Fish with Stir Fried Veggies | 1 | serving_unit | 1.0 meal | 350 | low |
| Honey Chilli Potato | 1 | serving_unit | 0.5 cup | 100 | medium |
| Horse Gram (Kulthi) | 1 | serving_unit | 1.0 Cup | 200 | medium |
| Hummus And Pita | 1 | serving_unit | 1.0 pita with hummus | 100 | low |
| Ice Cream | 1 | serving_unit | 1.0 bar | 60 | medium |
| Idli | 1 | serving_unit | 1.0 idli | 40 | high |
| Imli (Tamarind Chutney) (105959.0) | 1 | serving_unit | 1.0 ounce | 28 | high |
| Kaju Katli | 1 | serving_unit | 1.0 piece | 20 | medium |
| Kitkat Milk Chocolate Candy Bar | 1 | serving_unit | 1.0 finger bar | 21 | medium |
| Lactose free milk | 1 | volume | 250.0 ml | 250 | high |
| Litchi Juice | 1 | volume | 100.0 ml | 100 | high |
| Low Fat Milk UHT Sterilized Homogenised Double Toned | 1 | volume | 100.0 ml | 100 | high |
| Lychee | 1 | serving_unit | 1.0 cup | 190 | medium |
| Masala cup noodles | 1 | serving_unit | 1.0 Cups | 70 | medium |
| Methi Paratha | 1 | serving_unit | 1.0 paratha (about 55g) | 55 | high |
| Mirchi Thecha | 1 | serving_unit | 1.0 tbs | 15 | medium |
| Mixed Vegetable Raita | 1 | serving_unit | 1.0 Serving | 200 | medium |
| Non alcoholic | 1 | volume | 100.0 ml | 100 | high |
| Non-alcoholic 0.0 Beer (Green Apple) | 1 | volume | 100.0 ml | 100 | high |
| Paneer Sandwich | 1 | serving_unit | 1.0 sandwich | 180 | medium |
| Panini Chicken Sandwich | 1 | serving_unit | 4.0 oz | 113 | high |
| Paul Sandwich Sesame Camembert | 1 | serving_unit | 1.0 sandwich (200g) | 200 | high |
| Potato Chips, India's Magic Masala | 1 | serving_unit | 1.05 oz | 30 | high |
| Potato Wedges | 1 | serving_unit | 1.0 piece | 20 | low |
| Protein Lassi | 1 | volume | 200.0 ml | 200 | high |
| Protein shake | 1 | volume | 250.0 ml | 250 | high |
| Ragda (Vatana) | 1 | serving_unit | 1.0 cup cooked | 180 | medium |
| Regular | 1 | serving_unit | 1.0 cup cooked | 150 | low |
| Rice Roti | 1 | serving_unit | 1.0 Roti | 40 | medium |
| Soyabean Curry | 1 | serving_unit | 1.0 cup cooked | 180 | medium |
| Spring Onion Subzi | 1 | serving_unit | 1.0 bowl | 150 | medium |
| Vitamin B12 | 1 | serving_unit | 1.0 capsule | 1 | high |
| Vitamins D3 + K2 | 1 | serving_unit | 1.0 Tablet | 1 | high |
| White bread | 1 | serving_unit | 1.0 slice | 25 | medium |
| Whole wheat bread | 1 | serving_unit | 1.0 slice | 28 | medium |
| aam panna | 1 | volume | 40.0 ml | 40 | high |
| mocktail | 1 | volume | 100.0 ml | 100 | high |
| Øl | 1 | volume | 330.0 ml | 330 | high |
