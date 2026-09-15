module Page.FoodLog.AiReview exposing
    ( allowedUnitCodes
    , changeAmount
    , changeUnit
    , fromDraft
    )

import Api.Foods exposing (NutrientItem)
import Data.FoodAssistant exposing (FoodDraft, SuggestedLog)
import Page.FoodLog.AdHocForm as AdHocForm


fromDraft :
    List NutrientItem
    -> FoodDraft
    -> SuggestedLog
    -> AdHocForm.Model
    -> Result String AdHocForm.Model
fromDraft catalog draft suggested form =
    Result.map2
        (\_ rows ->
            { form
                | name = draft.name
                , brand = Maybe.withDefault "" draft.brand
                , amount = suggested.amount
                , unit = suggested.unit
                , nutrients = rows
                , portionWeight = suggested.totalWeightGrams
            }
        )
        (positive "Suggested portion weight" suggested.totalWeightGrams)
        (draft.nutrients
            |> List.map (nutrientRow catalog suggested.totalWeightGrams)
            |> combine
            |> Result.andThen requireCoreNutrients
        )


nutrientRow :
    List NutrientItem
    -> String
    -> Data.FoodAssistant.DraftNutrient
    -> Result String AdHocForm.NutrientRow
nutrientRow catalog rawWeight nutrient =
    case List.filter (\item -> item.code == nutrient.code) catalog |> List.head of
        Nothing ->
            Err ("The estimate contains an unsupported nutrient: " ++ nutrient.code)

        Just item ->
            Result.map2
                (\weight amountPer100g ->
                    { code = nutrient.code
                    , amount = String.fromFloat (amountPer100g * weight / 100)
                    , unit = item.unit
                    }
                )
                (positive "Suggested portion weight" rawWeight)
                (nonNegative "Estimated nutrient" nutrient.amountPer100g)


requireCoreNutrients :
    List AdHocForm.NutrientRow
    -> Result String (List AdHocForm.NutrientRow)
requireCoreNutrients rows =
    case
        [ "ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G" ]
            |> List.filter (\code -> not (List.any (\row -> row.code == code) rows))
            |> List.head
    of
        Just _ ->
            Err "The estimate is missing calories or a required macronutrient."

        Nothing ->
            Ok rows


changeAmount : String -> AdHocForm.Model -> AdHocForm.Model
changeAmount rawAmount form =
    case ( String.toFloat form.amount, String.toFloat rawAmount ) of
        ( Just oldAmount, Just newAmount ) ->
            if oldAmount > 0 && newAmount > 0 then
                scalePortion (newAmount / oldAmount) { form | amount = rawAmount }

            else
                { form | amount = rawAmount }

        _ ->
            { form | amount = rawAmount }


changeUnit : FoodDraft -> String -> AdHocForm.Model -> AdHocForm.Model
changeUnit draft unit form =
    case
        ( String.toFloat form.amount
        , gramsPerUnit draft unit
        , String.toFloat form.portionWeight
        )
    of
        ( Just amount, Just grams, Just oldWeight ) ->
            let
                newWeight : Float
                newWeight =
                    amount * grams
            in
            if amount > 0 && grams > 0 && oldWeight > 0 then
                scalePortion (newWeight / oldWeight) { form | unit = unit }

            else
                { form | unit = unit }

        _ ->
            { form | unit = unit }


scalePortion : Float -> AdHocForm.Model -> AdHocForm.Model
scalePortion ratio form =
    { form
        | portionWeight = scaleString ratio form.portionWeight
        , nutrients =
            List.map
                (\row -> { row | amount = scaleString ratio row.amount })
                form.nutrients
    }


scaleString : Float -> String -> String
scaleString ratio raw =
    String.toFloat raw
        |> Maybe.map ((*) ratio >> String.fromFloat)
        |> Maybe.withDefault raw


gramsPerUnit : FoodDraft -> String -> Maybe Float
gramsPerUnit draft unit =
    if unit == "g" then
        Just 1

    else
        draft.servings
            |> List.filter (\serving -> serving.unit == unit)
            |> List.head
            |> Maybe.andThen (.gramsPerUnit >> String.toFloat)


allowedUnitCodes : FoodDraft -> List String
allowedUnitCodes draft =
    "g" :: List.map .unit draft.servings


positive : String -> String -> Result String Float
positive label raw =
    case String.toFloat raw of
        Just value ->
            if value > 0 && not (isNaN value) && not (isInfinite value) then
                Ok value

            else
                Err (label ++ " must be greater than zero.")

        Nothing ->
            Err (label ++ " must be a number greater than zero.")


nonNegative : String -> String -> Result String Float
nonNegative label raw =
    case String.toFloat raw of
        Just value ->
            if value >= 0 && not (isNaN value) && not (isInfinite value) then
                Ok value

            else
                Err (label ++ " must be zero or greater.")

        Nothing ->
            Err (label ++ " must be a number.")


combine : List (Result error value) -> Result error (List value)
combine =
    List.foldr (Result.map2 (::)) (Ok [])
