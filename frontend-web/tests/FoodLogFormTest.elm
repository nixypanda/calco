module FoodLogFormTest exposing (tests)

import Api.Foods exposing (ProductDetail)
import Data.FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot(..))
import Expect
import Test exposing (Test, describe, test)
import View.FoodLogForm as FoodLogForm


tests : Test
tests =
    describe "View.FoodLogForm"
        [ test "default amount uses default_quantity" <|
            \_ ->
                FoodLogForm.initLogFormFromFood Nothing { food | defaultQuantity = Just "2.5" }
                    |> .amount
                    |> Expect.equal "2.5"
        , test "default unit uses default_unit" <|
            \_ ->
                FoodLogForm.initLogFormFromFood Nothing { food | defaultUnit = Just "serving" }
                    |> .unit
                    |> Expect.equal "serving"
        , test "missing defaults initialize 1 g" <|
            \_ ->
                FoodLogForm.initLogFormFromFood Nothing
                    { food | defaultQuantity = Nothing, defaultUnit = Nothing }
                    |> (\current -> ( current.amount, current.unit ))
                    |> Expect.equal ( "1", "g" )
        , test "amount is required" <|
            \_ ->
                FoodLogForm.createProductLogRequest loggedAt
                    "food-1"
                    { form | amount = " " }
                    |> Expect.equal (Err FoodLogForm.AmountRequired)
        , test "create-log payload uses product item" <|
            \_ ->
                FoodLogForm.createProductLogRequest loggedAt "food-1" form
                    |> Result.map .item
                    |> Expect.equal (Ok { itemType = "product", id = "food-1" })
        , test "selected meal slot is included" <|
            \_ ->
                FoodLogForm.createProductLogRequest loggedAt
                    "food-1"
                    { form | mealSlot = Just Lunch }
                    |> Result.map .mealSlot
                    |> Expect.equal (Ok (Just "lunch"))
        , test "no meal slot is omitted from request model" <|
            \_ ->
                FoodLogForm.createProductLogRequest loggedAt
                    "food-1"
                    { form | mealSlot = Nothing }
                    |> Result.map .mealSlot
                    |> Expect.equal (Ok Nothing)
        , test "blank notes become null request value" <|
            \_ ->
                FoodLogForm.createProductLogRequest loggedAt
                    "food-1"
                    { form | notes = "   " }
                    |> Result.map .notes
                    |> Expect.equal (Ok Nothing)
        , test "load-log success form uses existing quantity, unit, meal slot, and notes" <|
            \_ ->
                FoodLogForm.initLogFormFromLog log
                    |> (\current ->
                            { amount = current.amount
                            , unit = current.unit
                            , mealSlot = current.mealSlot
                            , notes = current.notes
                            }
                       )
                    |> Expect.equal
                        { amount = "2"
                        , unit = "serving"
                        , mealSlot = Just Lunch
                        , notes = "Good"
                        }
        , test "update payload includes quantity, meal slot, and notes" <|
            \_ ->
                FoodLogForm.createUpdateLogRequest { form | mealSlot = Just Lunch, notes = "Saved" }
                    |> Expect.equal
                        (Ok
                            { mealSlot = Just "lunch"
                            , quantity = { amount = "1", unit = "g" }
                            , notes = Just "Saved"
                            }
                        )
        , test "update no-slot and blank notes encode as null request values" <|
            \_ ->
                FoodLogForm.createUpdateLogRequest { form | mealSlot = Nothing, notes = "   " }
                    |> Result.map (\request -> ( request.mealSlot, request.notes ))
                    |> Expect.equal (Ok ( Nothing, Nothing ))
        ]


form : FoodLogForm.Model
form =
    { amount = "1"
    , unit = "g"
    , mealSlot = Nothing
    , notes = ""
    , mealSlotOpen = False
    , unitOpen = False
    , error = Nothing
    , submitting = False
    }


loggedAt : String
loggedAt =
    "2026-06-04T10:00:00+05:30"


food : ProductDetail
food =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Apple"
    , brand = Nothing
    , categories = []
    , defaultQuantity = Just "1"
    , defaultUnit = Just "g"
    , servingSizeG = Just "100"
    , nutrients = []
    , servings = []
    , allowedUnits = []
    }


log : FoodLog
log =
    { id = "log-1"
    , loggedAt = "2026-06-04T10:00:00+05:30"
    , mealSlot = Just "lunch"
    , item = { itemType = "product", id = "food-1" }
    , quantity = { amount = "2", unit = "serving" }
    , nutrients = []
    , notes = Just "Good"
    }
