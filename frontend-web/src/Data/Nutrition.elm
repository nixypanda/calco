module Data.Nutrition exposing
    ( Macro(..)
    , MacroTotals
    , NutrientAmount
    , NutritionSummary
    , Per100gNutrient
    , Serving
    , decoder
    , defaultCode
    , dominantMacro
    , emptySummary
    , macroTotals
    , nutrientAmount
    , nutrientsForQuantity
    , safeAmount
    , scalePer100g
    , scaledSnapshotForQuantity
    , servingGrams
    , summaryDecoder
    , summaryToNutrients
    , summaryValue
    )

import Json.Decode as Decode exposing (Decoder)


type alias NutrientAmount =
    { code : String
    , amount : String
    , unit : String
    }


type alias NutritionSummary =
    { energyKcal : Maybe String
    , proteinG : Maybe String
    , carbsG : Maybe String
    , fatG : Maybe String
    , fiberG : Maybe String
    }


emptySummary : NutritionSummary
emptySummary =
    { energyKcal = Nothing
    , proteinG = Nothing
    , carbsG = Nothing
    , fatG = Nothing
    , fiberG = Nothing
    }


{-| Convert a `NutritionSummary` into a `List NutrientAmount` keyed by the
standard macro codes (`PROTEIN_G`, `CARBS_G`, `FAT_G`) so it can be
passed to `dominantMacro` (or `macroTotals` etc.). Missing or `Nothing`
fields become `"0"`.
-}
summaryToNutrients : NutritionSummary -> List NutrientAmount
summaryToNutrients summary =
    [ { code = "PROTEIN_G", amount = Maybe.withDefault "0" summary.proteinG, unit = "g" }
    , { code = "CARBS_G", amount = Maybe.withDefault "0" summary.carbsG, unit = "g" }
    , { code = "FAT_G", amount = Maybe.withDefault "0" summary.fatG, unit = "g" }
    ]


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


type Macro
    = Protein
    | Carbs
    | Fat


{-| Find the dominant macro (highest calorie share) in a list of nutrients.
Protein and Carbs contribute 4 kcal/g, Fat 9 kcal/g. Tie-break order:
Protein > Carbs > Fat. Returns Nothing when all are zero or absent.
-}
dominantMacro : List NutrientAmount -> Maybe Macro
dominantMacro nutrients =
    let
        proteinG : Float
        proteinG =
            nutrientAmount "PROTEIN_G" nutrients

        carbsG : Float
        carbsG =
            nutrientAmount "CARBS_G" nutrients

        fatG : Float
        fatG =
            nutrientAmount "FAT_G" nutrients

        proteinKcal : Float
        proteinKcal =
            proteinG * 4

        carbsKcal : Float
        carbsKcal =
            carbsG * 4

        fatKcal : Float
        fatKcal =
            fatG * 9
    in
    if proteinKcal + carbsKcal + fatKcal <= 0 then
        Nothing

    else if proteinKcal >= carbsKcal && proteinKcal >= fatKcal then
        Just Protein

    else if carbsKcal >= proteinKcal && carbsKcal >= fatKcal then
        Just Carbs

    else
        Just Fat


decoder : Decoder NutrientAmount
decoder =
    Decode.map3 NutrientAmount
        (Decode.field "code" Decode.string)
        (Decode.field "amount" Decode.string)
        (Decode.field "unit" Decode.string)


summaryDecoder : Decoder NutritionSummary
summaryDecoder =
    Decode.map5 NutritionSummary
        (Decode.field "energy_kcal" (Decode.nullable Decode.string))
        (Decode.field "protein_g" (Decode.nullable Decode.string))
        (Decode.field "carbs_g" (Decode.nullable Decode.string))
        (Decode.field "fat_g" (Decode.nullable Decode.string))
        (Decode.field "fiber_g" (Decode.nullable Decode.string))


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


defaultCode : String
defaultCode =
    "g"


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
