module Page.FoodLog.CreateWithAiTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (UnitItem)
import Component.FoodAssistant as Assistant
import Component.FoodEditor as Editor
import Data.FoodAssistant exposing (FoodDraftTurn(..))
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.LocalCtx exposing (LocalCtx)
import Data.MealSlot exposing (MealSlot(..))
import Expect
import Lib.Date exposing (LocalDate)
import Page.FoodLog.CreateAdHoc as Review
import Page.FoodLog.CreateWithAi as CreateWithAi
import Page.FoodLog.ReviewStory as ReviewStory
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.FoodLog.CreateWithAi"
        [ test "a draft without a date asks for local context, then logs" <|
            \_ ->
                Story.start ( draftedModel, CreateWithAi.NoOp )
                    |> step
                        (CreateWithAi.ReviewMsg
                            (Review.FormMsg (Editor.LogQuantityChanged "2"))
                        )
                    |> step (CreateWithAi.ReviewMsg Review.SubmitClicked)
                    |> step (CreateWithAi.ReviewMsg (Review.LocalCtxReceived context))
                    |> step (CreateWithAi.ReviewMsg (Review.AdHocLogCompleted (Ok localAdHocLog)))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (CreateWithAi.LogCreated localAdHocLog)
                        )
        , test "save-on creates the food once and retries the failed product log" <|
            \_ ->
                Story.start ( estimatedModel, CreateWithAi.NoOp )
                    |> step (CreateWithAi.ReviewMsg (Review.FormMsg Editor.LogPersistenceToggled))
                    |> step
                        (CreateWithAi.ReviewMsg
                            (Review.FormMsg (Editor.PortionWeightChanged "240"))
                        )
                    |> step (CreateWithAi.ReviewMsg Review.SubmitClicked)
                    |> step
                        (CreateWithAi.ReviewMsg
                            (Review.CustomFoodCompleted (Ok { id = "food-1" }))
                        )
                    |> step
                        (CreateWithAi.ReviewMsg
                            (Review.ProductLogCompleted (Err Client.NetworkError))
                        )
                    |> step (CreateWithAi.ReviewMsg Review.SubmitClicked)
                    |> step (CreateWithAi.ReviewMsg (Review.ProductLogCompleted (Ok productLog)))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (CreateWithAi.LogCreated productLog)
                        )
        ]



-- STORY PIPELINE


type alias Journey =
    Story.Journey CreateWithAi.Model CreateWithAi.OutMsg


step : CreateWithAi.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd CreateWithAi.update)


finish :
    (( CreateWithAi.Model, CreateWithAi.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


draftedModel : CreateWithAi.Model
draftedModel =
    draftModel Nothing Nothing


estimatedModel : CreateWithAi.Model
estimatedModel =
    draftModel (Just ReviewStory.day) (Just Lunch)


draftModel :
    Maybe LocalDate
    -> Maybe MealSlot
    -> CreateWithAi.Model
draftModel date mealSlot =
    Story.runSteps stepModel
        [ CreateWithAi.NutrientsLoaded (Ok { items = ReviewStory.catalog })
        , CreateWithAi.UnitsLoaded (Ok { items = unitOptions })
        , CreateWithAi.AssistantMsg
            (Assistant.StatusLoaded (Ok { enabled = True, supportsImages = True }))
        , CreateWithAi.AssistantMsg
            (Assistant.DescriptionChanged "Paneer wrap with paneer and spices")
        , CreateWithAi.AssistantMsg Assistant.SendClicked
        , CreateWithAi.AssistantMsg (Assistant.DraftCompleted (Ok readyTurn))
        , CreateWithAi.AssistantMsg (Assistant.ApplyDraftClicked False)
        ]
        (CreateWithAi.init date mealSlot |> Tuple.first)


stepModel : CreateWithAi.Msg -> CreateWithAi.Model -> CreateWithAi.Model
stepModel =
    Story.modelFromUpdate CreateWithAi.update


context : LocalCtx
context =
    { date = Fixtures.date "2026-06-04", timezone = "Asia/Kolkata" }


unitOptions : List UnitItem
unitOptions =
    [ ReviewStory.gram, ReviewStory.serving, piece ]


piece : UnitItem
piece =
    { code = "piece", name = "Piece", kind = "serving" }


readyTurn : FoodDraftTurn
readyTurn =
    DraftReady
        { assistantMessage = "Review this estimate."
        , draft =
            { name = "Paneer wrap"
            , brand = Nothing
            , categories = [ "wrap" ]
            , defaultQuantity = Just "1"
            , defaultUnit = Just "serving"
            , nutrients =
                [ { code = "ENERGY_KCAL", amountPer100g = "200" }
                , { code = "PROTEIN_G", amountPer100g = "10" }
                , { code = "CARBS_G", amountPer100g = "20" }
                , { code = "FAT_G", amountPer100g = "12" }
                , { code = "FIBER_G", amountPer100g = "5" }
                ]
            , servings =
                [ { unit = "serving", gramsPerUnit = "250" }
                , { unit = "piece", gramsPerUnit = "125" }
                ]
            }
        , suggestedLog =
            Just { amount = "1", unit = "serving", totalWeightGrams = "250" }
        , warnings = [ "Estimated from description" ]
        }


localAdHocLog : FoodLog
localAdHocLog =
    { adHocLog
        | logDate = context.date
        , deviceTimezone = Just context.timezone
    }


adHocLog : FoodLog
adHocLog =
    { id = "log-1"
    , logDate = ReviewStory.day
    , deviceTimezone = Nothing
    , mealSlot = Just Lunch
    , item = FoodLog.AdHocLogItem { name = "Paneer wrap", brand = Nothing }
    , quantity = { amount = "2", unit = "serving" }
    , nutrients =
        [ { code = "ENERGY_KCAL", amount = "1000", unit = "kcal" }
        , { code = "PROTEIN_G", amount = "50", unit = "g" }
        , { code = "CARBS_G", amount = "100", unit = "g" }
        , { code = "FAT_G", amount = "60", unit = "g" }
        , { code = "FIBER_G", amount = "25", unit = "g" }
        ]
    , notes = Nothing
    }


productLog : FoodLog
productLog =
    { adHocLog
        | id = "log-2"
        , item =
            FoodLog.ProductLogItem { id = "food-1", name = "Paneer wrap", brand = Nothing }
        , quantity = { amount = "1", unit = "serving" }
        , nutrients =
            [ { code = "ENERGY_KCAL", amount = "500", unit = "kcal" }
            , { code = "PROTEIN_G", amount = "25", unit = "g" }
            , { code = "CARBS_G", amount = "50", unit = "g" }
            , { code = "FAT_G", amount = "30", unit = "g" }
            , { code = "FIBER_G", amount = "12.5", unit = "g" }
            ]
    }
