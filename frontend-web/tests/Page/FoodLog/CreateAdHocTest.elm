module Page.FoodLog.CreateAdHocTest exposing (tests)

import Api.Client as Client
import Component.FoodEditor as Editor
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.LocalCtx exposing (LocalCtx)
import Data.MealSlot exposing (MealSlot(..))
import Expect
import Page.FoodLog.CreateAdHoc as CreateAdHoc
import Page.FoodLog.ReviewStory as ReviewStory
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.FoodLog.CreateAdHoc"
        [ test "a user logs an ad-hoc food" <|
            \_ ->
                prepared
                    |> step (CreateAdHoc.FormMsg (Editor.NameChanged "Paneer wrap"))
                    |> step CreateAdHoc.SubmitClicked
                    |> step (CreateAdHoc.AdHocLogCompleted (Ok adHocLog))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (CreateAdHoc.LogCreated adHocLog)
                        )
        , test "a user saves an ad-hoc food as a custom food and logs it" <|
            \_ ->
                prepared
                    |> step (CreateAdHoc.FormMsg (Editor.NameChanged "Paneer wrap"))
                    |> step (CreateAdHoc.FormMsg Editor.LogPersistenceToggled)
                    |> step (CreateAdHoc.FormMsg (Editor.PortionWeightChanged "160"))
                    |> step CreateAdHoc.SubmitClicked
                    |> step (CreateAdHoc.CustomFoodCompleted (Ok { id = "food-1" }))
                    |> step (CreateAdHoc.ProductLogCompleted (Err Client.NetworkError))
                    |> step CreateAdHoc.SubmitClicked
                    |> step (CreateAdHoc.ProductLogCompleted (Ok productLog))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (CreateAdHoc.LogCreated productLog)
                        )
        , test "a blank date waits for local context before logging" <|
            \_ ->
                blankDate
                    |> step (CreateAdHoc.FormMsg (Editor.NameChanged "Paneer wrap"))
                    |> step CreateAdHoc.SubmitClicked
                    |> step (CreateAdHoc.LocalCtxReceived context)
                    |> step (CreateAdHoc.AdHocLogCompleted (Ok adHocLog))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (CreateAdHoc.LogCreated adHocLog)
                        )
        ]



-- STORY PIPELINE


type alias Journey =
    Story.Journey CreateAdHoc.Model CreateAdHoc.OutMsg


step : CreateAdHoc.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd CreateAdHoc.update)


finish :
    (( CreateAdHoc.Model, CreateAdHoc.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


prepared : Journey
prepared =
    Story.start
        ( CreateAdHoc.init (Just ReviewStory.day) (Just Lunch)
            |> stepModel (CreateAdHoc.UnitsLoaded (Ok { items = ReviewStory.units }))
            |> stepModel (CreateAdHoc.NutrientsLoaded (Ok { items = ReviewStory.catalog }))
            |> Story.runSteps stepModel ReviewStory.fillNutrients
        , CreateAdHoc.NoOp
        )


blankDate : Journey
blankDate =
    Story.start
        ( CreateAdHoc.init Nothing Nothing
            |> stepModel (CreateAdHoc.UnitsLoaded (Ok { items = ReviewStory.units }))
            |> stepModel (CreateAdHoc.NutrientsLoaded (Ok { items = ReviewStory.catalog }))
            |> Story.runSteps stepModel ReviewStory.fillNutrients
        , CreateAdHoc.NoOp
        )


stepModel : CreateAdHoc.Msg -> CreateAdHoc.Model -> CreateAdHoc.Model
stepModel =
    Story.modelFromUpdate CreateAdHoc.update


context : LocalCtx
context =
    { date = Fixtures.date "2026-09-16", timezone = "Asia/Kolkata" }


adHocLog : FoodLog
adHocLog =
    { id = "log-1"
    , logDate = ReviewStory.day
    , deviceTimezone = Nothing
    , mealSlot = Just Lunch
    , item = FoodLog.AdHocLogItem { name = "Paneer wrap", brand = Nothing }
    , quantity = { amount = "1", unit = "serving" }
    , nutrients =
        [ { code = "ENERGY_KCAL", amount = "520", unit = "kcal" }
        , { code = "PROTEIN_G", amount = "24", unit = "g" }
        , { code = "CARBS_G", amount = "48", unit = "g" }
        , { code = "FAT_G", amount = "25", unit = "g" }
        ]
    , notes = Nothing
    }


productLog : FoodLog
productLog =
    { adHocLog
        | id = "log-2"
        , item =
            FoodLog.ProductLogItem
                { id = "food-1", name = "Paneer wrap", brand = Nothing }
    }
