module Page.FoodLog.EntryTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (UnitItem)
import Component.FoodLogForm as FoodLogForm
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Expect
import Lib.Date exposing (LocalDate)
import Page.FoodLog.Entry as FoodLogEntry
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.FoodLog.Entry"
        [ test "a user edits and saves a food log" <|
            \_ ->
                productLoaded
                    |> step (FoodLogEntry.FormMsg (FoodLogForm.AmountChanged "4"))
                    |> step (FoodLogEntry.FormMsg (FoodLogForm.NotesChanged "Updated"))
                    |> step FoodLogEntry.SubmitClicked
                    |> step (FoodLogEntry.UpdateCompleted (Err Client.NetworkError))
                    |> step FoodLogEntry.SubmitClicked
                    |> step (FoodLogEntry.UpdateCompleted (Ok updatedLog))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (FoodLogEntry.LogUpdated sampleDate)
                        )
        , test "a user deletes a food log" <|
            \_ ->
                mealLoaded
                    |> step FoodLogEntry.DeleteClicked
                    |> step FoodLogEntry.ConfirmDeleteClicked
                    |> step (FoodLogEntry.DeleteCompleted (Err Client.NetworkError))
                    |> step FoodLogEntry.ConfirmDeleteClicked
                    |> step (FoodLogEntry.DeleteCompleted (Ok ()))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal
                                    (FoodLogEntry.LogDeleted sampleDate
                                        (DiaryDay Nothing Nothing)
                                    )
                        )
        ]


stepWithOut :
    FoodLogEntry.Msg
    -> FoodLogEntry.Model
    -> ( FoodLogEntry.Model, FoodLogEntry.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            FoodLogEntry.update msg model
    in
    ( next, outMsg )



-- STORY PIPELINE


type alias Journey =
    Story.Journey FoodLogEntry.Model FoodLogEntry.OutMsg


step : FoodLogEntry.Msg -> Journey -> Journey
step =
    Story.step stepWithOut


finish :
    (( FoodLogEntry.Model, FoodLogEntry.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


productLoaded : Journey
productLoaded =
    Story.start
        ( FoodLogEntry.init "log-1"
            |> Tuple.first
            |> runSteps stepModel
                [ FoodLogEntry.UnitsLoaded (Ok { items = [ gram ] })
                , FoodLogEntry.LogLoaded "log-1" (Ok productLog)
                , FoodLogEntry.ProductDetailLoaded (Err Client.NetworkError)
                ]
        , FoodLogEntry.NoOp
        )


mealLoaded : Journey
mealLoaded =
    Story.start
        ( FoodLogEntry.init "log-2"
            |> Tuple.first
            |> runSteps stepModel
                [ FoodLogEntry.UnitsLoaded (Ok { items = [ gram ] })
                , FoodLogEntry.LogLoaded "log-2" (Ok mealLog)
                ]
        , FoodLogEntry.NoOp
        )


stepModel : FoodLogEntry.Msg -> FoodLogEntry.Model -> FoodLogEntry.Model
stepModel msg model =
    Fixtures.tupleFirst (FoodLogEntry.update msg model)


runSteps : (msg -> model -> model) -> List msg -> model -> model
runSteps =
    Story.runSteps


sampleDate : LocalDate
sampleDate =
    Fixtures.date "2026-06-04"


productLog : FoodLog
productLog =
    { id = "log-1"
    , logDate = sampleDate
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = Just Lunch
    , item =
        FoodLog.ProductLogItem
            { id = "food-1", name = "Apple", brand = Just "Local" }
    , quantity = { amount = "2", unit = "serving" }
    , nutrients =
        [ { code = "ENERGY_KCAL", amount = "120", unit = "kcal" } ]
    , notes = Just "Good"
    }


mealLog : FoodLog
mealLog =
    { productLog
        | id = "log-2"
        , item = FoodLog.MealLogItem { id = "meal-1", name = "Lunch meal" }
        , nutrients =
            [ { code = "ENERGY_KCAL", amount = "400", unit = "kcal" } ]
    }


updatedLog : FoodLog
updatedLog =
    { productLog
        | quantity = { amount = "4", unit = "serving" }
        , notes = Just "Updated"
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }
