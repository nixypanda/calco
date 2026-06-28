UPDATE product_nutrients pn
SET amount_per_100g = round(pn.amount_per_100g, 6),
    updated_at = now()
FROM products p
WHERE p.id = pn.product_id
  AND p.user_id IS NOT NULL
  AND pn.amount_per_100g <> round(pn.amount_per_100g, 6);
