module Page.Food.ShowTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Api.Logs as Logs
import Component.FoodLogForm as FoodLogForm
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.LocalCtx exposing (LocalCtx)
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Food.Show as FoodShow
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Food.Show"
        [ test "a user logs a food using the last-used portion" <|
            \_ ->
                loadedWithLastUsed
                    |> step FoodShow.SubmitClicked
                    |> step (FoodShow.LocalCtxReceived context)
                    |> step (FoodShow.LogCompleted (Ok log))
                    |> finish
                        (\( model, outMsg ) ->
                            { amount =
                                formField model (\form -> form.amount)
                                    |> Maybe.withDefault ""
                            , unit =
                                formField model (\form -> form.unit)
                                    |> Maybe.withDefault ""
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { amount = "250"
                                    , unit = "g"
                                    , finalOut =
                                        FoodShow.LogCreated log
                                            (FoodSearch (Just sampleDate) (Just Lunch))
                                    }
                        )
        , test "a user logs a food using a saved serving option" <|
            \_ ->
                baseLoaded
                    |> step (FoodShow.FormMsg (FoodLogForm.AmountChanged "1"))
                    |> step (FoodShow.FormMsg (FoodLogForm.UnitChanged "serving"))
                    |> step FoodShow.SubmitClicked
                    |> step (FoodShow.LocalCtxReceived context)
                    |> step (FoodShow.LogCompleted (Ok servingLog))
                    |> finish
                        (\( model, outMsg ) ->
                            { amount =
                                formField model (\form -> form.amount)
                                    |> Maybe.withDefault ""
                            , unit =
                                formField model (\form -> form.unit)
                                    |> Maybe.withDefault ""
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { amount = "1"
                                    , unit = "serving"
                                    , finalOut =
                                        FoodShow.LogCreated servingLog
                                            (FoodSearch (Just sampleDate) (Just Lunch))
                                    }
                        )
        , test "a failed save can be retried" <|
            \_ ->
                baseLoaded
                    |> step (FoodShow.FormMsg (FoodLogForm.AmountChanged "3"))
                    |> step (FoodShow.FormMsg (FoodLogForm.UnitChanged "g"))
                    |> step FoodShow.SubmitClicked
                    |> step (FoodShow.LogCompleted (Err Client.NetworkError))
                    |> step FoodShow.SubmitClicked
                    |> step (FoodShow.LocalCtxReceived context)
                    |> finish
                        (\( _, outMsg ) ->
                            createLog outMsg
                                |> Expect.equal
                                    (Just
                                        { date = "2026-05-29"
                                        , timezone = Just "Asia/Kolkata"
                                        , meal = Just "lunch"
                                        , item = "product:food-1"
                                        , amount = "3"
                                        , unit = "g"
                                        , notes = Nothing
                                        }
                                    )
                        )
        ]


formField : FoodShow.Model -> (FoodLogForm.Model -> a) -> Maybe a
formField model transform =
    case model of
        FoodShow.Loaded loaded ->
            Just (transform loaded.form)

        _ ->
            Nothing


type alias CreateLogProjection =
    { date : String
    , timezone : Maybe String
    , meal : Maybe String
    , item : String
    , amount : String
    , unit : String
    , notes : Maybe String
    }


createLog : FoodShow.OutMsg -> Maybe CreateLogProjection
createLog outMsg =
    case outMsg of
        FoodShow.RequestCreateLog request ->
            Just
                { date = LocalDate.format request.logDate
                , timezone = request.deviceTimezone
                , meal = Maybe.map MealSlot.toString request.mealSlot
                , item = ItemRef.itemTypeToString request.item.itemType ++ ":" ++ request.item.id
                , amount = request.quantity.amount
                , unit = request.quantity.unit
                , notes = request.notes
                }

        _ ->
            Nothing



-- STORY PIPELINE


type alias Journey =
    Story.Journey FoodShow.Model FoodShow.OutMsg


step : FoodShow.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd FoodShow.update)


finish :
    (( FoodShow.Model, FoodShow.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


loadedWithLastUsed : Journey
loadedWithLastUsed =
    FoodShow.init "food-1" (Just sampleDate) (Just Lunch) Nothing
        |> Story.start
        |> step (FoodShow.LastUsedLoaded "food-1" (Ok { items = [ recentItem ] }))
        |> step (FoodShow.FoodLoaded "food-1" (Ok food))
        |> step (FoodShow.UnitsLoaded (Ok { items = [ gram, serving ] }))


baseLoaded : Journey
baseLoaded =
    FoodShow.init "food-1" (Just sampleDate) (Just Lunch) Nothing
        |> Story.start
        |> step (FoodShow.FoodLoaded "food-1" (Ok food))
        |> step (FoodShow.UnitsLoaded (Ok { items = [ gram, serving ] }))


sampleDate : LocalDate
sampleDate =
    Fixtures.date "2026-05-29"


context : LocalCtx
context =
    { date = Fixtures.date "2026-06-04", timezone = "Asia/Kolkata" }


food : ProductDetail
food =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Apple"
    , brand = Just "Local"
    , categories = [ "fruit" ]
    , defaultQuantity = Just "2"
    , defaultUnit = Just "serving"
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    , nutrients =
        [ { code = "ENERGY_KCAL"
          , amountPer100g = "120"
          , unit = "kcal"
          , source = Nothing
          , confidence = Nothing
          }
        ]
    , servings = [ { unit = "serving", gramsPerUnit = "50" } ]
    , allowedUnits = [ gram, serving ]
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


serving : UnitItem
serving =
    { code = "serving", name = "Serving", kind = "serving" }


recentItem : Logs.RecentItem
recentItem =
    { item = FoodLog.ProductLogItem { id = "food-1", name = "Apple", brand = Just "Local" }
    , lastUsedDate = Fixtures.date "2026-05-28"
    , mealSlot = Just Lunch
    , quantity = { amount = "250", unit = "g" }
    , nutritionSummary = Nutrition.emptySummary
    , topQuantities = []
    }


log : FoodLog
log =
    { id = "log-1"
    , logDate = sampleDate
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = Just Lunch
    , item = FoodLog.ProductLogItem { id = "food-1", name = "Apple", brand = Just "Local" }
    , quantity = { amount = "3", unit = "g" }
    , nutrients = []
    , notes = Nothing
    }


servingLog : FoodLog
servingLog =
    { id = "log-serving-1"
    , logDate = sampleDate
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = Just Lunch
    , item = FoodLog.ProductLogItem { id = "food-1", name = "Apple", brand = Just "Local" }
    , quantity = { amount = "1", unit = "serving" }
    , nutrients = []
    , notes = Nothing
    }
