module Data.MealSlot exposing
    ( MealSlot(..)
    , all
    , fromString
    , label
    , matches
    , toString
    )


type MealSlot
    = Breakfast
    | Lunch
    | Dinner
    | Snack
    | LateNightSnack
    | Other


all : List MealSlot
all =
    [ Breakfast, Lunch, Dinner, Snack, LateNightSnack ]


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

        "late_night_snack" ->
            Just LateNightSnack

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

        LateNightSnack ->
            "late_night_snack"

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

        LateNightSnack ->
            "Late-night Snack"

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
