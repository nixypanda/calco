module Data.MealSlot exposing
    ( MealSlot(..)
    , fromString
    , label
    , matches
    , regularSlots
    , toString
    )


type MealSlot
    = Breakfast
    | Lunch
    | Dinner
    | Snack
    | Other


regularSlots : List MealSlot
regularSlots =
    [ Breakfast, Lunch, Dinner, Snack ]


fromString : String -> Maybe MealSlot
fromString raw =
    case raw of
        "breakfast" ->
            Just Breakfast

        "lunch" ->
            Just Lunch

        "dinner" ->
            Just Dinner

        "snack" ->
            Just Snack

        "other" ->
            Just Other

        _ ->
            Nothing


toString : MealSlot -> String
toString slot =
    case slot of
        Breakfast ->
            "breakfast"

        Lunch ->
            "lunch"

        Dinner ->
            "dinner"

        Snack ->
            "snack"

        Other ->
            "other"


label : MealSlot -> String
label slot =
    case slot of
        Breakfast ->
            "Breakfast"

        Lunch ->
            "Lunch"

        Dinner ->
            "Dinner"

        Snack ->
            "Snack"

        Other ->
            "Other"


matches : MealSlot -> Maybe String -> Bool
matches slot maybeRaw =
    case slot of
        Other ->
            maybeRaw
                |> Maybe.andThen fromString
                |> Maybe.map (\parsed -> parsed == Other)
                |> Maybe.withDefault True

        _ ->
            maybeRaw == Just (toString slot)
