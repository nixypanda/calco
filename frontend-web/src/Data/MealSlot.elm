module Data.MealSlot exposing
    ( MealSlot(..)
    , all
    , fromString
    , label
    , toString
    )

import I18n
import Translations.Ids exposing (TranslationId(..))


type MealSlot
    = Breakfast
    | Lunch
    | Dinner
    | Snack
    | LateNightSnack


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


label : MealSlot -> String
label slot =
    case slot of
        Breakfast ->
            I18n.t TidMealSlotBreakfast

        Lunch ->
            I18n.t TidMealSlotLunch

        Dinner ->
            I18n.t TidMealSlotDinner

        Snack ->
            I18n.t TidMealSlotSnack

        LateNightSnack ->
            I18n.t TidMealSlotLateNightSnack
