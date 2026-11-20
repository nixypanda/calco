-- Defense in depth for meal quantities. The application validates every new
-- meal before persistence; these constraints keep direct or future writers
-- from reintroducing structurally unreadable rows.
--
-- Known-invalid structural values are not repaired, deleted, or preserved.
-- Abort before mutating the schema and list every affected row so an operator
-- can repair the source data explicitly. Dynamic degradation from catalog
-- changes (for example, a removed serving) is different: those quantities are
-- structurally valid and remain readable as unavailable.
DO $$
DECLARE
    bad_meals TEXT;
    bad_components TEXT;
    empty_meals TEXT;
BEGIN
    SELECT string_agg(id::text, ', ' ORDER BY id)
    INTO bad_meals
    FROM meals
    WHERE (total_quantity_amount IS NULL) <> (total_quantity_unit IS NULL)
       OR (total_quantity_amount IS NOT NULL AND total_quantity_amount <= 0)
       OR (
           total_quantity_unit IS NOT NULL
           AND btrim(total_quantity_unit, U&'\0009\000A\000B\000C\000D\0020\0085\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000') = ''
       );

    SELECT string_agg(id::text, ', ' ORDER BY id)
    INTO bad_components
    FROM meal_components
    WHERE quantity <= 0
       OR btrim(unit, U&'\0009\000A\000B\000C\000D\0020\0085\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000') = '';

    SELECT string_agg(meal.id::text, ', ' ORDER BY meal.id)
    INTO empty_meals
    FROM meals AS meal
    WHERE NOT EXISTS (
        SELECT 1
        FROM meal_components AS component
        WHERE component.meal_id = meal.id
    );

    IF bad_meals IS NOT NULL OR bad_components IS NOT NULL OR empty_meals IS NOT NULL THEN
        RAISE EXCEPTION
            'cannot add meal structural constraints; repair these rows first (invalid meals: %; invalid components: %; meals without components: %)',
            COALESCE(bad_meals, 'none'),
            COALESCE(bad_components, 'none'),
            COALESCE(empty_meals, 'none');
    END IF;
END $$;

ALTER TABLE meals
    ADD CONSTRAINT meals_total_quantity_paired_check
    CHECK ((total_quantity_amount IS NULL) = (total_quantity_unit IS NULL));

ALTER TABLE meals
    ADD CONSTRAINT meals_total_quantity_positive_check
    CHECK (total_quantity_amount IS NULL OR total_quantity_amount > 0);

ALTER TABLE meals
    ADD CONSTRAINT meals_total_quantity_unit_nonblank_check
    CHECK (
        total_quantity_unit IS NULL
        OR btrim(total_quantity_unit, U&'\0009\000A\000B\000C\000D\0020\0085\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000') <> ''
    );

ALTER TABLE meal_components
    ADD CONSTRAINT meal_components_quantity_positive_check
    CHECK (quantity > 0);

ALTER TABLE meal_components
    ADD CONSTRAINT meal_components_unit_nonblank_check
    CHECK (
        btrim(unit, U&'\0009\000A\000B\000C\000D\0020\0085\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000') <> ''
    );
