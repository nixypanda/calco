module Component.FoodLogFormTest exposing (tests)

import Component.FoodLogForm as FoodLogForm
import Data.ItemRef as ItemRef
import Data.MealSlot exposing (MealSlot)
import Expect
import Fuzz
import Support.Fixtures as Fixtures
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz, test)


tests : Test
tests =
    describe "Component.FoodLogForm"
        [ amountRequired
        , payloadBranches
        ]


amountRequired : Test
amountRequired =
    test "amount is required for create and update payloads" <|
        \_ ->
            Expect.all
                [ \_ ->
                    FoodLogForm.createProductLogRequest
                        Fixtures.today
                        Nothing
                        "food-1"
                        (model " " "g" Nothing "")
                        |> Expect.equal (Err FoodLogForm.AmountRequired)
                , \_ ->
                    FoodLogForm.createUpdateLogRequest
                        (model " " "g" Nothing "")
                        |> Expect.equal (Err FoodLogForm.AmountRequired)
                ]
                ()


{-| Request branch property: the create payload maps the item and typed portion;
the update payload maps the same portion without an item. Both trim notes and
blank notes become Nothing, while the update payload always carries the slot.
-}
payloadBranches : Test
payloadBranches =
    fuzz payloadInput
        "create and update payloads map the portion, meal slot, and notes"
    <|
        \input ->
            let
                formModel : FoodLogForm.Model
                formModel =
                    model input.portion input.unit input.mealSlot input.notes

                expectedQuantity : { amount : String, unit : String }
                expectedQuantity =
                    { amount = input.portion, unit = input.unit }
            in
            Expect.all
                [ \_ ->
                    FoodLogForm.createProductLogRequest
                        Fixtures.today
                        Nothing
                        "food-1"
                        formModel
                        |> Result.map
                            (\request ->
                                { item = request.item
                                , quantity = request.quantity
                                , mealSlot = request.mealSlot
                                , notes = request.notes
                                }
                            )
                        |> Expect.equal
                            (Ok
                                { item = { itemType = ItemRef.Product, id = "food-1" }
                                , quantity = expectedQuantity
                                , mealSlot = input.mealSlot
                                , notes = expectedNotes input.notes
                                }
                            )
                , \_ ->
                    FoodLogForm.createUpdateLogRequest formModel
                        |> Result.map
                            (\request ->
                                { mealSlot = request.mealSlot
                                , quantity = request.quantity
                                , notes = request.notes
                                }
                            )
                        |> Expect.equal
                            (Ok
                                { mealSlot = input.mealSlot
                                , quantity = expectedQuantity
                                , notes = expectedNotes input.notes
                                }
                            )
                ]
                ()



-- HELPERS


type alias PayloadInput =
    { mealSlot : Maybe MealSlot
    , portion : String
    , unit : String
    , notes : String
    }


payloadInput : Fuzz.Fuzzer PayloadInput
payloadInput =
    Fuzz.map4 PayloadInput
        SupportFuzz.maybeMealSlot
        amount
        unit
        Fuzz.string


model : String -> String -> Maybe MealSlot -> String -> FoodLogForm.Model
model amountValue unitValue mealSlot notes =
    { amount = amountValue
    , unit = unitValue
    , mealSlot = mealSlot
    , notes = notes
    , openDropdown = FoodLogForm.NoDropdownOpen
    , submitState = FoodLogForm.SubmitIdle
    }


amount : Fuzz.Fuzzer String
amount =
    Fuzz.oneOfValues [ "1", "2", "0.5", "100" ]


unit : Fuzz.Fuzzer String
unit =
    Fuzz.oneOfValues [ "g", "serving" ]


expectedNotes : String -> Maybe String
expectedNotes raw =
    let
        trimmed : String
        trimmed =
            String.trim raw
    in
    if String.isEmpty trimmed then
        Nothing

    else
        Just trimmed
