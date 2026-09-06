module Page.FoodLog.FormTest exposing (tests)

import Api.Foods exposing (ProductDetail)
import Data.FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.FoodLog.Form as FoodLogForm
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.FoodLog.Form"
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
        , test "missing defaults initialize 100 g" <|
            \_ ->
                FoodLogForm.initLogFormFromFood Nothing
                    { food | defaultQuantity = Nothing, defaultUnit = Nothing }
                    |> (\current -> ( current.amount, current.unit ))
                    |> Expect.equal ( "100", "g" )
        , test "missing defaults use the first configured serving" <|
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
        , test "create-log payload passes through log date and timezone" <|
            \_ ->
                FoodLogForm.createProductLogRequest rawDate
                    deviceTimezone
                    "food-1"
                    form
                    |> Result.map (\request -> ( request.logDate, request.deviceTimezone ))
                    |> Expect.equal (Ok ( sampleDate, deviceTimezone ))
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
        , test "update no-slot and blank notes encode as null request values" <|
            \_ ->
                FoodLogForm.createUpdateLogRequest { form | mealSlot = Nothing, notes = "   " }
                    |> Result.map (\request -> ( request.mealSlot, request.notes ))
                    |> Expect.equal (Ok ( Nothing, Nothing ))
        , test "UnitChanged sets unit and closes dropdown" <|
            \_ ->
                FoodLogForm.update
                    (FoodLogForm.UnitChanged "serving")
                    { form
                        | openDropdown = FoodLogForm.UnitDropdownOpen
                        , submitState =
                            FoodLogForm.SubmitFailed FoodLogForm.AmountRequiredMessage
                    }
                    |> (\current ->
                            ( current.unit, current.openDropdown, current.submitState )
                       )
                    |> Expect.equal
                        ( "serving"
                        , FoodLogForm.NoDropdownOpen
                        , FoodLogForm.SubmitIdle
                        )
        , test "MealSlotChanged sets meal slot and closes dropdown" <|
            \_ ->
                FoodLogForm.update
                    (FoodLogForm.MealSlotChanged (Just Lunch))
                    { form
                        | openDropdown = FoodLogForm.MealSlotDropdownOpen
                        , submitState =
                            FoodLogForm.SubmitFailed FoodLogForm.AmountRequiredMessage
                    }
                    |> (\current ->
                            ( current.mealSlot, current.openDropdown, current.submitState )
                       )
                    |> Expect.equal
                        ( Just Lunch
                        , FoodLogForm.NoDropdownOpen
                        , FoodLogForm.SubmitIdle
                        )
        , test "NotesChanged sets notes and closes dropdown" <|
            \_ ->
                FoodLogForm.update
                    (FoodLogForm.NotesChanged "tasty")
                    { form
                        | openDropdown = FoodLogForm.UnitDropdownOpen
                        , submitState =
                            FoodLogForm.SubmitFailed FoodLogForm.AmountRequiredMessage
                    }
                    |> (\current ->
                            ( current.notes, current.openDropdown, current.submitState )
                       )
                    |> Expect.equal
                        ( "tasty"
                        , FoodLogForm.NoDropdownOpen
                        , FoodLogForm.SubmitIdle
                        )
        , test "AmountChanged updates amount field" <|
            \_ ->
                FoodLogForm.update
                    (FoodLogForm.AmountChanged "5")
                    { form
                        | openDropdown = FoodLogForm.MealSlotDropdownOpen
                        , submitState =
                            FoodLogForm.SubmitFailed FoodLogForm.AmountRequiredMessage
                    }
                    |> (\current ->
                            ( current.amount, current.openDropdown, current.submitState )
                       )
                    |> Expect.equal
                        ( "5"
                        , FoodLogForm.NoDropdownOpen
                        , FoodLogForm.SubmitIdle
                        )
        , test "ToggleMealSlotDropdown closes when already open" <|
            \_ ->
                FoodLogForm.update
                    FoodLogForm.ToggleMealSlotDropdown
                    { form | openDropdown = FoodLogForm.MealSlotDropdownOpen }
                    |> .openDropdown
                    |> Expect.equal FoodLogForm.NoDropdownOpen
        , test "ToggleUnitDropdown closes when already open" <|
            \_ ->
                FoodLogForm.update
                    FoodLogForm.ToggleUnitDropdown
                    { form | openDropdown = FoodLogForm.UnitDropdownOpen }
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
    , item = { itemType = ItemRef.Product, id = "food-1", name = "Apple", brand = Just "Local" }
    , quantity = { amount = "2", unit = "serving" }
    , nutrients = []
    , notes = Just "Good"
    }
