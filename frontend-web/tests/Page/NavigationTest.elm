module Page.NavigationTest exposing (tests)

{-| Workspace navigation stories.

`Page.initPreserving` stands in for Main applying a `Navigate` route: each
story drives a real page message through `Page.update`, then reconciles the
workspace for the new route. Assertions use the final `Page.paneKeys` and the
one preserved diary summary; intermediate workspace/out-msg logs are not kept.

-}

import Api.Logs
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.Goals exposing (GoalSnapshot, GoalSource(..))
import Data.LocalCtx exposing (LocalCtx)
import Data.MealSlot as MealSlot
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page
import Page.Diary.Day as DiaryDay
import Page.Food.Search as FoodSearch
import Page.Meal.List as MealList
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page navigation"
        [ test "contextual search keeps the diary while detail replaces the right pane" <|
            \_ ->
                let
                    diaryLoaded : Journey
                    diaryLoaded =
                        start
                            (Page.init
                                { route = DiaryDay (Just date) Nothing
                                , today = Just today
                                }
                                |> Fixtures.tupleFirst
                            )
                            |> send
                                (Page.GotDiaryMsg
                                    (DiaryDay.LogsLoaded date (Ok diaryLogs))
                                )
                            |> send
                                (Page.GotDiaryMsg
                                    (DiaryDay.GoalLoaded date (Ok goalSnapshot))
                                )

                    afterAddFood : Journey
                    afterAddFood =
                        diaryLoaded
                            |> send (Page.GotDiaryMsg (DiaryDay.AddFoodClicked MealSlot.Lunch))
                            |> apply (FoodSearch (Just date) (Just MealSlot.Lunch))

                    afterContextualFood : Journey
                    afterContextualFood =
                        afterAddFood
                            |> send
                                (Page.GotFoodSearchMsg (FoodSearch.ResultClicked "food-1"))
                            |> apply (FoodShow "food-1" (Just date) (Just MealSlot.Lunch) Nothing)
                in
                { finalOut = afterContextualFood.lastOut
                , finalPanes = Page.paneKeys afterContextualFood.model
                , panesAfterAdd = Page.paneKeys afterAddFood.model
                , diaryAfter = diaryState afterAddFood.model
                , failure = afterContextualFood.failure
                }
                    |> Expect.equal
                        { finalOut =
                            Page.Navigate
                                (FoodShow "food-1" (Just date) (Just MealSlot.Lunch) Nothing)
                        , finalPanes =
                            [ "diary:2026-07-20:none"
                            , "food-detail:food-1:2026-07-20:lunch"
                            ]
                        , panesAfterAdd = [ "diary:2026-07-20:none", "food-search" ]
                        , diaryAfter = Just { date = "2026-07-20", logCount = 2 }
                        , failure = Nothing
                        }
        , test "calendar stays main while food and meal detail replace the right pane" <|
            \_ ->
                let
                    afterMeal : Journey
                    afterMeal =
                        start
                            (Page.init
                                { route = DiaryDay (Just date) (Just month)
                                , today = Just today
                                }
                                |> Fixtures.tupleFirst
                            )
                            |> apply (FoodSearch (Just date) (Just MealSlot.Lunch))
                            |> send
                                (Page.GotFoodSearchMsg (FoodSearch.ResultClicked "food-1"))
                            |> apply (FoodShow "food-1" (Just date) (Just MealSlot.Lunch) Nothing)
                            |> apply (FoodSearch (Just date) (Just MealSlot.Lunch))
                            |> send
                                (Page.GotFoodSearchMsg
                                    (FoodSearch.RecentItemClicked mealRecent)
                                )
                            |> apply (MealShow "meal-1")
                in
                { finalPanes = Page.paneKeys afterMeal.model
                , finalOut = afterMeal.lastOut
                , failure = afterMeal.failure
                }
                    |> Expect.equal
                        { finalPanes = [ "calendar:2026-07", "meal-detail:meal-1" ]
                        , finalOut = Page.Navigate (MealShow "meal-1")
                        , failure = Nothing
                        }
        , test "today gating waits, then standalone routes replace the workspace" <|
            \_ ->
                let
                    waiting : Journey
                    waiting =
                        start
                            (Page.init
                                { route = DiaryDay (Just date) (Just month)
                                , today = Nothing
                                }
                                |> Fixtures.tupleFirst
                            )

                    afterToday : Journey
                    afterToday =
                        adoptToday localCtx waiting

                    afterCreate : Journey
                    afterCreate =
                        afterToday
                            |> send (Page.GotDiaryMsg DiaryDay.MealsClicked)
                            |> apply MealList
                            |> send (Page.GotMealsMsg MealList.CreateMealClicked)
                            |> apply MealCreate
                in
                { waitingForToday = Page.isLoading waiting.model
                , waitingPanes = Page.paneKeys waiting.model
                , todayPanes = Page.paneKeys afterToday.model
                , finalPanes = Page.paneKeys afterCreate.model
                , finalOut = afterCreate.lastOut
                , failure = afterCreate.failure
                }
                    |> Expect.equal
                        { waitingForToday = True
                        , waitingPanes = []
                        , todayPanes = [ "calendar:2026-07", "diary:2026-07-20:2026-07" ]
                        , finalPanes = [ "meal-create" ]
                        , finalOut = Page.Navigate MealCreate
                        , failure = Nothing
                        }
        ]



-- WORKSPACE HELPERS


type alias Journey =
    { model : Page.Model
    , lastOut : Page.OutMsg
    , failure : Maybe String
    }


start : Page.Model -> Journey
start model =
    { model = model, lastOut = Page.NoOutMsg, failure = Nothing }


send : Page.Msg -> Journey -> Journey
send msg journey =
    case Page.update ctx msg journey.model of
        Just ( model, _, outMsg ) ->
            { journey | model = model, lastOut = outMsg }

        Nothing ->
            { journey | failure = Just "a required navigation message was ignored" }


apply : Route -> Journey -> Journey
apply route journey =
    { journey
        | model =
            Page.initPreserving { route = route, today = Just today } journey.model
                |> Fixtures.tupleFirst
    }


{-| Mirrors Main adopting the browser's clock: the route is re-rendered with the
new today, then the local-context message reaches each live pane.
-}
adoptToday : LocalCtx -> Journey -> Journey
adoptToday context journey =
    let
        pageCtx : Page.InitCtx
        pageCtx =
            { route = DiaryDay (Just date) (Just month), today = Just context.date }

        ( adopted, _, _ ) =
            Page.initPreserving pageCtx journey.model
    in
    case Page.localCtxReceived pageCtx context adopted of
        Just ( model, _, outMsg ) ->
            { journey | model = model, lastOut = outMsg }

        Nothing ->
            { journey | failure = Just "the local context did not reach the new panes" }


type alias DiaryState =
    { date : String, logCount : Int }


diaryState : Page.Model -> Maybe DiaryState
diaryState model =
    model.panes
        |> List.filterMap
            (\pane ->
                case pane of
                    Page.DiaryPane _ diary ->
                        Just
                            { date = LocalDate.format diary.currentDate
                            , logCount =
                                DiaryDay.currentLogs diary
                                    |> Maybe.withDefault []
                                    |> List.length
                            }

                    _ ->
                        Nothing
            )
        |> List.head


ctx : Page.InitCtx
ctx =
    { route = DiaryDay (Just date) Nothing, today = Just today }


localCtx : LocalCtx
localCtx =
    { date = today, timezone = "Asia/Kolkata" }



-- FIXTURES


mealRecent : Api.Logs.RecentItem
mealRecent =
    { item = FoodLog.MealLogItem { id = "meal-1", name = "Chicken bowl" }
    , lastUsedDate = date
    , mealSlot = Just MealSlot.Lunch
    , quantity = { amount = "1", unit = "serving" }
    , nutritionSummary =
        { energyKcal = Nothing
        , proteinG = Nothing
        , carbsG = Nothing
        , fatG = Nothing
        , fiberG = Nothing
        }
    , topQuantities = []
    }


diaryLogs : List FoodLog
diaryLogs =
    [ diaryLog "log-a", diaryLog "log-b" ]


diaryLog : String -> FoodLog
diaryLog id =
    { id = id
    , logDate = date
    , deviceTimezone = Nothing
    , mealSlot = Just MealSlot.Lunch
    , item = FoodLog.ProductLogItem { id = "food-1", name = "Chicken", brand = Nothing }
    , quantity = { amount = "1", unit = "serving" }
    , nutrients = []
    , notes = Nothing
    }


goalSnapshot : GoalSnapshot
goalSnapshot =
    { requestedDate = date
    , effectiveFrom = Nothing
    , source = Default
    , targets =
        { calorieTarget = 2100, proteinTargetG = 150, carbsTargetG = 240, fatTargetG = 60 }
    }


date : LocalDate
date =
    Fixtures.date "2026-07-20"


month : String
month =
    "2026-07"


today : LocalDate
today =
    Fixtures.today
