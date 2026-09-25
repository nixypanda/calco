module Component.FoodLogFormTest exposing (tests)

import Api.Foods exposing (ProductDetail)
import Component.FoodLogForm as FoodLogForm
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Component.FoodLogForm"
        [ test "missing defaults use the first configured serving" <|
            \_ ->
                FoodLogForm.initLogFormFromFood Nothing
                    { food
                        | defaultQuantity = Nothing
                        , defaultUnit = Nothing
                        , servings =
                            [ { unit = "cup", gramsPerUnit = "240" }
                            ]
                    }
                    |> (\current -> ( current.amount, current.unit ))
                    |> Expect.equal ( "1", "cup" )
        , test "meal dropdown toggle opens only meal dropdown" <|
            \_ ->
                FoodLogForm.update FoodLogForm.ToggleMealSlotDropdown form
                    |> .openDropdown
                    |> Expect.equal FoodLogForm.MealSlotDropdownOpen
        , test "unit dropdown toggle closes meal dropdown" <|
            \_ ->
                FoodLogForm.update FoodLogForm.ToggleMealSlotDropdown form
                    |> FoodLogForm.update FoodLogForm.ToggleUnitDropdown
                    |> .openDropdown
                    |> Expect.equal FoodLogForm.UnitDropdownOpen
        , test "editing clears submit failure" <|
            \_ ->
                FoodLogForm.update
                    (FoodLogForm.AmountChanged "2")
                    { form
                        | submitState =
                            FoodLogForm.SubmitFailed
                                FoodLogForm.AmountRequiredMessage
                    }
                    |> .submitState
                    |> Expect.equal FoodLogForm.SubmitIdle
        , test "amount is required" <|
            \_ ->
                FoodLogForm.createProductLogRequest rawDate
                    deviceTimezone
                    "food-1"
                    { form | amount = " " }
                    |> Expect.equal (Err FoodLogForm.AmountRequired)
        , test "create-log payload uses product item" <|
            \_ ->
                FoodLogForm.createProductLogRequest rawDate deviceTimezone "food-1" form
                    |> Result.map .item
                    |> Expect.equal (Ok { itemType = ItemRef.Product, id = "food-1" })
        , test "selected meal slot is included" <|
            \_ ->
                FoodLogForm.createProductLogRequest rawDate
                    deviceTimezone
                    "food-1"
                    { form | mealSlot = Just Lunch }
                    |> Result.map .mealSlot
                    |> Expect.equal (Ok (Just "lunch"))
        , test "no meal slot is omitted from request model" <|
            \_ ->
                FoodLogForm.createProductLogRequest rawDate
                    deviceTimezone
                    "food-1"
                    { form | mealSlot = Nothing }
                    |> Result.map .mealSlot
                    |> Expect.equal (Ok Nothing)
        , test "blank notes become null request value" <|
            \_ ->
                FoodLogForm.createProductLogRequest rawDate
                    deviceTimezone
                    "food-1"
                    { form | notes = "   " }
                    |> Result.map .notes
                    |> Expect.equal (Ok Nothing)
        , test "create-log payload rejects malformed date strings" <|
            \_ ->
                FoodLogForm.createProductLogRequest "not-a-date"
                    deviceTimezone
                    "food-1"
                    form
                    |> Expect.equal (Err FoodLogForm.InvalidDate)
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
        , test "ToggleMealSlotDropdown closes when already open" <|
            \_ ->
                FoodLogForm.update
                    FoodLogForm.ToggleMealSlotDropdown
                    { form | openDropdown = FoodLogForm.MealSlotDropdownOpen }
                    |> .openDropdown
                    |> Expect.equal FoodLogForm.NoDropdownOpen
        ]


form : FoodLogForm.Model
form =
    { amount = "1"
    , unit = "g"
    , mealSlot = Nothing
    , notes = ""
    , openDropdown = FoodLogForm.NoDropdownOpen
    , submitState = FoodLogForm.SubmitIdle
    }


rawDate : String
rawDate =
    "2026-06-04"


sampleDate : LocalDate
sampleDate =
    sampleDateFromString rawDate


sampleDateFromString : String -> LocalDate
sampleDateFromString raw =
    case LocalDate.fromString raw of
        Just d ->
            d

        Nothing ->
            todayFallback


todayFallback : LocalDate
todayFallback =
    case LocalDate.fromParts 1970 1 1 of
        Just d ->
            d

        Nothing ->
            -- Unreachable: 1970-01-01 is always valid.
            sampleDate


deviceTimezone : Maybe String
deviceTimezone =
    Just "Asia/Kolkata"


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
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    , nutrients = []
    , servings = []
    , allowedUnits = []
    }


log : FoodLog
log =
    { id = "log-1"
    , logDate = sampleDate
    , deviceTimezone = deviceTimezone
    , mealSlot = Just Lunch
    , item =
        FoodLog.ProductLogItem
            { id = "food-1", name = "Apple", brand = Just "Local" }
    , quantity = { amount = "2", unit = "serving" }
    , nutrients = []
    , notes = Just "Good"
    }
