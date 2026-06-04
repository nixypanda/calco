module Data.Nutrition exposing
    ( MacroTotals
    , NutrientAmount
    , Per100gNutrient
    , Serving
    , caloriesFrom
    , decoder
    , macroTotals
    , nutrientAmount
    , nutrientsForQuantity
    , oneDecimal
    , safeAmount
    , scalePer100g
    , scaledSnapshotForQuantity
    , servingGrams
    , summaryValue
    )

import Json.Decode as Decode exposing (Decoder)
import Lib.Number as Number


type alias NutrientAmount =
    { code : String
    , amount : String
    , unit : String
    }


type alias Per100gNutrient =
    { code : String
    , amountPer100g : String
    , unit : String
    }


type alias Serving =
    { label : String
    , quantity : String
    , unit : String
    , grams : String
    }


type alias MacroTotals =
    { protein : Float
    , carbs : Float
    , fat : Float
    , proteinPct : Float
    , carbsPct : Float
    , fatPct : Float
    }


decoder : Decoder NutrientAmount
decoder =
    Decode.map3 NutrientAmount
        (Decode.field "code" Decode.string)
        (Decode.field "amount" Decode.string)
        (Decode.field "unit" Decode.string)


safeAmount : String -> Float
safeAmount raw =
    case String.toFloat raw of
        Just amount ->
            if amount < 0 then
                0

            else
                amount

        Nothing ->
            0


summaryValue : String -> List NutrientAmount -> Maybe NutrientAmount
summaryValue code entries =
    List.filter (\entry -> entry.code == code) entries
        |> List.head


caloriesFrom : List NutrientAmount -> Float
caloriesFrom nutrients =
    nutrientAmount "ENERGY_KCAL" nutrients


macroTotals : List { item | nutrients : List NutrientAmount } -> MacroTotals
macroTotals logs =
    let
        protein : Float
        protein =
            sumNutrient "PROTEIN_G" logs

        carbs : Float
        carbs =
            sumNutrient "CARBS_G" logs

        fat : Float
        fat =
            sumNutrient "FAT_G" logs

        totalKcal : Float
        totalKcal =
            protein * 4 + carbs * 4 + fat * 9

        percent : Float -> Float
        percent kcal =
            if totalKcal > 0 then
                kcal / totalKcal * 100

            else
                0
    in
    { protein = protein
    , carbs = carbs
    , fat = fat
    , proteinPct = percent (protein * 4)
    , carbsPct = percent (carbs * 4)
    , fatPct = percent (fat * 9)
    }


sumNutrient : String -> List { item | nutrients : List NutrientAmount } -> Float
sumNutrient code logs =
    logs
        |> List.map (\log -> nutrientAmount code log.nutrients)
        |> List.sum


nutrientAmount : String -> List NutrientAmount -> Float
nutrientAmount code nutrients =
    summaryValue code nutrients
        |> Maybe.map (.amount >> safeAmount)
        |> Maybe.withDefault 0


servingGrams :
    { quantity | amount : String, unit : String }
    -> List { serving | quantity : String, unit : String, grams : String }
    -> Maybe Float
servingGrams quantity servings =
    let
        maybeAmount : Maybe Float
        maybeAmount =
            positiveAmount quantity.amount
    in
    case maybeAmount of
        Just amount ->
            if quantity.unit == "g" then
                Just amount

            else
                servings
                    |> List.filter (\serving -> serving.unit == quantity.unit)
                    |> List.head
                    |> Maybe.andThen (gramsFromServing amount)

        Nothing ->
            Nothing


scalePer100g :
    Float
    -> List { nutrient | code : String, amountPer100g : String, unit : String }
    -> List NutrientAmount
scalePer100g grams nutrients =
    let
        factor : Float
        factor =
            grams / 100
    in
    List.map
        (\nutrient ->
            { code = nutrient.code
            , amount = String.fromFloat (safeAmount nutrient.amountPer100g * factor)
            , unit = nutrient.unit
            }
        )
        nutrients


nutrientsForQuantity :
    { quantity | amount : String, unit : String }
    -> List { serving | quantity : String, unit : String, grams : String }
    -> List { nutrient | code : String, amountPer100g : String, unit : String }
    -> Maybe (List NutrientAmount)
nutrientsForQuantity quantity servings nutrients =
    servingGrams quantity servings
        |> Maybe.map (\grams -> scalePer100g grams nutrients)


scaledSnapshotForQuantity :
    { savedQuantity | amount : String, unit : String }
    -> { currentQuantity | amount : String, unit : String }
    -> List NutrientAmount
    -> Maybe (List NutrientAmount)
scaledSnapshotForQuantity saved current nutrients =
    if saved.unit == current.unit then
        case ( positiveAmount saved.amount, positiveAmount current.amount ) of
            ( Just savedAmount, Just currentAmount ) ->
                Just (scaleNutrients (currentAmount / savedAmount) nutrients)

            _ ->
                Nothing

    else
        Nothing


scaleNutrients : Float -> List NutrientAmount -> List NutrientAmount
scaleNutrients factor nutrients =
    List.map
        (\nutrient ->
            { nutrient
                | amount = String.fromFloat (safeAmount nutrient.amount * factor)
            }
        )
        nutrients


oneDecimal : Float -> String
oneDecimal value =
    Number.toFixed 1 value


positiveAmount : String -> Maybe Float
positiveAmount raw =
    case String.toFloat raw of
        Just amount ->
            if amount > 0 then
                Just amount

            else
                Nothing

        Nothing ->
            Nothing


gramsFromServing : Float -> { serving | quantity : String, grams : String } -> Maybe Float
gramsFromServing amount serving =
    let
        servingQuantity : Float
        servingQuantity =
            safeAmount serving.quantity

        grams : Float
        grams =
            safeAmount serving.grams
    in
    if servingQuantity > 0 then
        Just (amount * grams / servingQuantity)

    else
        Nothing
