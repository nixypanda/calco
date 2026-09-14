module Page.FoodLog.AdHocForm exposing
    ( Model
    , Validated
    , empty
    , toAdHocRequest
    , toCustomFoodRequest
    , toProductLogRequest
    , validate
    )

import Api.Foods exposing (CreateFoodRequest)
import Api.Logs exposing (CreateAdHocLogRequest, CreateLogRequest)
import Data.ItemRef exposing (ItemType(..))
import Data.MealSlot as MealSlot exposing (MealSlot)
import Data.Nutrition as Nutrition
import Lib.Date exposing (LocalDate)
import Lib.Text as Text


type alias Model =
    { date : String
    , mealSlot : Maybe MealSlot
    , name : String
    , brand : String
    , amount : String
    , unit : String
    , calories : String
    , protein : String
    , carbohydrates : String
    , fat : String
    , notes : String
    , saveToMyFoods : Bool
    , portionWeight : String
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
    , calories = ""
    , protein = ""
    , carbohydrates = ""
    , fat = ""
    , notes = ""
    , saveToMyFoods = False
    , portionWeight = ""
    }


validate : Model -> Result String Validated
validate form =
    let
        name : String
        name =
            String.trim form.name

        nutrients : List ( String, String, String )
        nutrients =
            [ ( "ENERGY_KCAL", form.calories, "kcal" )
            , ( "PROTEIN_G", form.protein, "g" )
            , ( "CARBS_G", form.carbohydrates, "g" )
            , ( "FAT_G", form.fat, "g" )
            ]
    in
    if String.isEmpty name then
        Err "Food name is required."

    else
        Result.map3
            (\quantityAmount parsedNutrients portionWeight ->
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
                        (\( code, raw, unit ) ->
                            { code = code, amount = String.trim raw, unit = unit }
                        )
                        nutrients
                , nutrientTotals =
                    List.map2
                        (\( code, _, _ ) value -> ( code, value ))
                        nutrients
                        parsedNutrients
                , notes = Text.blankToMaybe form.notes
                , portionWeight = portionWeight
                }
            )
            (positive "Amount" form.amount)
            (nutrients
                |> List.map (\( code, raw, _ ) -> nonNegative (nutrientLabel code) raw)
                |> combine
            )
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


nutrientLabel : String -> String
nutrientLabel code =
    case code of
        "ENERGY_KCAL" ->
            "Calories"

        "PROTEIN_G" ->
            "Protein"

        "CARBS_G" ->
            "Carbohydrates"

        _ ->
            "Fat"


isMassUnit : String -> Bool
isMassUnit unit =
    List.member unit [ "mg", "g", "kg" ]
