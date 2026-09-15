module Page.FoodLog.AdHocForm exposing
    ( Model
    , NutrientRow
    , Validated
    , empty
    , toAdHocRequest
    , toCustomFoodRequest
    , toProductLogRequest
    , validate
    , withNutrientCatalog
    )

import Api.Foods exposing (CreateFoodRequest, NutrientItem)
import Api.Logs exposing (CreateAdHocLogRequest, CreateLogRequest)
import Data.ItemRef exposing (ItemType(..))
import Data.MealSlot as MealSlot exposing (MealSlot)
import Data.Nutrition as Nutrition
import Lib.Date exposing (LocalDate)
import Lib.Text as Text
import View.Nutrients


type alias Model =
    { date : String
    , mealSlot : Maybe MealSlot
    , name : String
    , brand : String
    , amount : String
    , unit : String
    , nutrients : List NutrientRow
    , notes : String
    , saveToMyFoods : Bool
    , portionWeight : String
    }


type alias NutrientRow =
    { code : String
    , amount : String
    , unit : String
    }


type alias Validated =
    { name : String
    , brand : Maybe String
    , quantity : Nutrition.Quantity
    , quantityAmount : Float
    , mealSlot : Maybe MealSlot
    , nutrients : List Nutrition.NutrientAmount
    , nutrientTotals : List ( String, Float )
    , notes : Maybe String
    , portionWeight : Maybe Float
    }


empty : Maybe String -> Maybe MealSlot -> Model
empty date mealSlot =
    { date = Maybe.withDefault "" date
    , mealSlot = mealSlot
    , name = ""
    , brand = ""
    , amount = "1"
    , unit = "serving"
    , nutrients =
        [ { code = "ENERGY_KCAL", amount = "", unit = "kcal" }
        , { code = "PROTEIN_G", amount = "", unit = "g" }
        , { code = "CARBS_G", amount = "", unit = "g" }
        , { code = "FAT_G", amount = "", unit = "g" }
        ]
    , notes = ""
    , saveToMyFoods = False
    , portionWeight = ""
    }


withNutrientCatalog : List NutrientItem -> Model -> Model
withNutrientCatalog catalog form =
    { form
        | nutrients =
            List.map
                (\row ->
                    catalog
                        |> List.filter (\item -> item.code == row.code)
                        |> List.head
                        |> Maybe.map (\item -> { row | unit = item.unit })
                        |> Maybe.withDefault row
                )
                form.nutrients
    }


validate : Model -> Result String Validated
validate form =
    let
        name : String
        name =
            String.trim form.name

        nutrientRows : List NutrientRow
        nutrientRows =
            List.filter hasNutrientInput form.nutrients

        duplicate : Maybe String
        duplicate =
            firstDuplicate (List.map (.code >> String.trim) nutrientRows)

        missingRequired : Maybe String
        missingRequired =
            [ "ENERGY_KCAL", "PROTEIN_G", "CARBS_G", "FAT_G" ]
                |> List.filter (\code -> not (List.any (\row -> row.code == code) nutrientRows))
                |> List.head

        parsedNutrients : Result String (List ( NutrientRow, Float ))
        parsedNutrients =
            nutrientRows
                |> List.map
                    (\row ->
                        if String.isEmpty (String.trim row.code) then
                            Err "Select a nutrient for every entered amount."

                        else
                            nonNegative (View.Nutrients.nutrientLabel row.code) row.amount
                                |> Result.map (Tuple.pair row)
                    )
                |> combine
    in
    if String.isEmpty name then
        Err "Food name is required."

    else if duplicate /= Nothing then
        Err "Each nutrient can only be added once."

    else if missingRequired /= Nothing then
        Err
            (missingRequired
                |> Maybe.map View.Nutrients.nutrientLabel
                |> Maybe.withDefault "Required nutrient"
                |> (\label -> label ++ " is required.")
            )

    else
        Result.map3
            (\quantityAmount parsed portionWeight ->
                { name = name
                , brand = Text.blankToMaybe form.brand
                , quantity =
                    { amount = String.trim form.amount
                    , unit = String.trim form.unit
                    }
                , quantityAmount = quantityAmount
                , mealSlot = form.mealSlot
                , nutrients =
                    List.map
                        (\( row, _ ) ->
                            { code = String.trim row.code
                            , amount = String.trim row.amount
                            , unit = row.unit
                            }
                        )
                        parsed
                , nutrientTotals =
                    List.map (\( row, value ) -> ( String.trim row.code, value )) parsed
                , notes = Text.blankToMaybe form.notes
                , portionWeight = portionWeight
                }
            )
            (positive "Amount" form.amount)
            parsedNutrients
            (if form.saveToMyFoods then
                positive "Weight of this logged portion" form.portionWeight
                    |> Result.map Just

             else
                Ok Nothing
            )


toAdHocRequest : LocalDate -> Maybe String -> Validated -> CreateAdHocLogRequest
toAdHocRequest date timezone validated =
    { logDate = date
    , deviceTimezone = timezone
    , mealSlot = Maybe.map MealSlot.toString validated.mealSlot
    , name = validated.name
    , brand = validated.brand
    , quantity = validated.quantity
    , nutrients = validated.nutrients
    , notes = validated.notes
    }


toCustomFoodRequest : Validated -> Result String CreateFoodRequest
toCustomFoodRequest validated =
    case validated.portionWeight of
        Nothing ->
            Err "Weight of this logged portion is required."

        Just weight ->
            let
                per100g : List Api.Foods.CreateFoodNutrientRequest
                per100g =
                    List.map
                        (\( code, amount ) ->
                            { code = code, amountPer100g = amount * 100 / weight }
                        )
                        validated.nutrientTotals

                gramsPerUnit : Float
                gramsPerUnit =
                    weight / validated.quantityAmount

                finite : Float -> Bool
                finite value =
                    not (isNaN value) && not (isInfinite value)
            in
            if not (List.all (.amountPer100g >> finite) per100g) || not (finite gramsPerUnit) then
                Err "The portion values are too large to calculate safely."

            else
                Ok
                    { name = validated.name
                    , brand = validated.brand
                    , categories = []
                    , defaultQuantity = Just validated.quantity.amount
                    , defaultUnit = Just validated.quantity.unit
                    , nutrients = per100g
                    , servings =
                        if isMassUnit validated.quantity.unit then
                            []

                        else
                            [ { unit = validated.quantity.unit
                              , gramsPerUnit = gramsPerUnit
                              }
                            ]
                    }


toProductLogRequest :
    LocalDate
    -> Maybe String
    -> String
    -> Validated
    -> CreateLogRequest
toProductLogRequest date timezone productId validated =
    { logDate = date
    , deviceTimezone = timezone
    , mealSlot = Maybe.map MealSlot.toString validated.mealSlot
    , item = { itemType = Product, id = productId }
    , quantity = validated.quantity
    , notes = validated.notes
    }


positive : String -> String -> Result String Float
positive label raw =
    case String.toFloat (String.trim raw) of
        Just value ->
            if value > 0 && not (isNaN value) && not (isInfinite value) then
                Ok value

            else
                Err (label ++ " must be greater than zero.")

        Nothing ->
            Err (label ++ " must be a number greater than zero.")


nonNegative : String -> String -> Result String Float
nonNegative label raw =
    case String.toFloat (String.trim raw) of
        Just value ->
            if value >= 0 && not (isNaN value) && not (isInfinite value) then
                Ok value

            else
                Err (label ++ " must be zero or greater.")

        Nothing ->
            Err (label ++ " is required and must be a number.")


combine : List (Result error value) -> Result error (List value)
combine results =
    List.foldr (Result.map2 (::)) (Ok []) results


hasNutrientInput : NutrientRow -> Bool
hasNutrientInput row =
    not (String.isEmpty (String.trim row.code))
        || not (String.isEmpty (String.trim row.amount))


firstDuplicate : List String -> Maybe String
firstDuplicate values =
    case values of
        [] ->
            Nothing

        value :: rest ->
            if List.member value rest then
                Just value

            else
                firstDuplicate rest


isMassUnit : String -> Bool
isMassUnit unit =
    List.member unit [ "mg", "g", "kg" ]
