module PageTest exposing (tests)

import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page
import Page.Diary.Day as DiaryDayPage
import Page.Food.Search as FoodSearchPage
import Test exposing (Test, describe, test)
import Time


tests : Test
tests =
    describe "Page"
        [ workspaceTests
        , reconcileTests
        , routeFlowTests
        ]


workspaceTests : Test
workspaceTests =
    describe "workspace pane keys"
        [ test "calendar-aware diary opens calendar and diary panes" <|
            \_ ->
                expectPaneKeys
                    (DiaryDay (Just date) (Just month))
                    [ "calendar:" ++ month, diaryKey date (Just month) ]
        , test "an unparseable diary date falls back to today" <|
            \_ ->
                expectPaneKeys
                    (DiaryDay (Just "not-a-date") Nothing)
                    [ diaryKey (LocalDate.format today) Nothing ]
        , test "a missing diary date falls back to today" <|
            \_ ->
                expectPaneKeys
                    (DiaryDay Nothing Nothing)
                    [ diaryKey (LocalDate.format today) Nothing ]
        , test "a future diary date is clamped to today" <|
            \_ ->
                expectPaneKeys
                    (DiaryDay (Just "2027-01-01") Nothing)
                    [ diaryKey (LocalDate.format today) Nothing ]
        , test "dated search opens diary and search panes" <|
            \_ ->
                expectPaneKeys
                    (FoodSearch (Just date) (Just Lunch))
                    [ diaryKey date Nothing, "food-search" ]
        , test "dated food opens diary and food detail panes" <|
            \_ ->
                expectPaneKeys
                    (FoodShow "food-1" (Just date) (Just Lunch) Nothing)
                    [ diaryKey date Nothing
                    , "food-detail:food-1:" ++ date ++ ":lunch"
                    ]
        , test "dated log editing is standalone" <|
            \_ ->
                expectPaneKeys
                    (FoodLogEntry "log-1" (Just date) Nothing)
                    [ "log-detail:log-1" ]
        , test "nutrition details retain the diary pane" <|
            \_ ->
                expectPaneKeys
                    (NutritionDetails (Just date))
                    [ diaryKey date Nothing, "nutrition-details:" ++ date ]
        , test "custom food detail retains its list pane" <|
            \_ ->
                expectPaneKeys
                    (CustomFoodShow "food-1")
                    [ "custom-food-list", "custom-food-detail:food-1" ]
        , test "meal detail retains its list pane" <|
            \_ ->
                expectPaneKeys
                    (MealShow "meal-1")
                    [ "meal-list", "meal-detail:meal-1" ]
        , test "user edit is standalone" <|
            \_ ->
                expectPaneKeys
                    (AdminEditUser "user-1")
                    [ "admin-edit-user:user-1" ]
        , test "custom food create and edit are standalone" <|
            \_ ->
                ( paneKeysForRoute CustomFoodCreate
                , paneKeysForRoute (CustomFoodEdit "food-1")
                )
                    |> Expect.equal
                        ( [ "custom-food-create" ]
                        , [ "custom-food-edit:food-1" ]
                        )
        , test "meal create and edit are standalone" <|
            \_ ->
                ( paneKeysForRoute MealCreate
                , paneKeysForRoute (MealEdit "meal-1")
                )
                    |> Expect.equal
                        ( [ "meal-create" ]
                        , [ "meal-edit:meal-1" ]
                        )
        , test "generic search stays standalone" <|
            \_ ->
                expectPaneKeys
                    (FoodSearch Nothing Nothing)
                    [ "food-search" ]
        , test "invalid dated search degrades to standalone search" <|
            \_ ->
                expectPaneKeys
                    (FoodSearch (Just "not-a-date") (Just Lunch))
                    [ "food-search" ]
        , test "undated food degrades to standalone detail on direct entry" <|
            \_ ->
                expectPaneKeys
                    (FoodShow "food-1" Nothing Nothing Nothing)
                    [ "food-detail:food-1:none:none" ]
        , test "undated log degrades to standalone detail" <|
            \_ ->
                expectPaneKeys
                    (FoodLogEntry "log-1" Nothing Nothing)
                    [ "log-detail:log-1" ]
        , test "a today-dependent route waits honestly for local context" <|
            \_ ->
                Page.init { route = DiaryDay Nothing Nothing, today = Nothing }
                    |> first
                    |> (\model -> ( Page.isLoading model, Page.paneKeys model ))
                    |> Expect.equal ( True, [] )
        , test "generic search retains its pane when a food is opened" <|
            \_ ->
                Page.init { route = FoodSearch Nothing Nothing, today = Just today }
                    |> first
                    |> Page.initPreserving
                        { route = FoodShow "food-1" Nothing Nothing Nothing
                        , today = Just today
                        }
                    |> first
                    |> Page.paneKeys
                    |> Expect.equal
                        [ "food-search", "food-detail:food-1:none:none" ]
        , test "custom food creation replaces its entire contextual workspace" <|
            \_ ->
                Page.init
                    { route = FoodSearch (Just date) (Just Lunch)
                    , today = Just today
                    }
                    |> first
                    |> Page.initPreserving
                        { route = CustomFoodCreate, today = Just today }
                    |> first
                    |> Page.paneKeys
                    |> Expect.equal [ "custom-food-create" ]
        , test "AI creation is also standalone" <|
            \_ ->
                Page.init
                    { route = FoodSearch (Just date) (Just Lunch)
                    , today = Just today
                    }
                    |> first
                    |> Page.initPreserving
                        { route = CustomFoodCreateWithAi, today = Just today }
                    |> first
                    |> Page.paneKeys
                    |> Expect.equal [ "custom-food-create" ]
        , test "AI ad-hoc logging is standalone" <|
            \_ ->
                expectPaneKeys
                    (AiLogCreate (Just date) (Just Lunch))
                    [ "create-ai-log" ]
        , test "calendar-aware log editing is standalone" <|
            \_ ->
                expectPaneKeys
                    (FoodLogEntry "log-1" (Just date) (Just month))
                    [ "log-detail:log-1" ]
        ]


reconcileTests : Test
reconcileTests =
    describe "reconcile"
        [ test "same key reuses the existing pane without effects" <|
            \_ ->
                Page.reconcile identity
                    .key
                    initializeDesired
                    [ "kept" ]
                    [ desired "kept" "replacement" "initialized" ]
                    |> Expect.equal
                        { panes = [ "kept" ]
                        , effects = []
                        , initializedKeys = []
                        }
        , test "changed key initializes the desired pane" <|
            \_ ->
                Page.reconcile identity
                    .key
                    initializeDesired
                    [ "old" ]
                    [ desired "new" "new pane" "initialized new" ]
                    |> Expect.equal
                        { panes = [ "new pane" ]
                        , effects = [ "initialized new" ]
                        , initializedKeys = [ "new" ]
                        }
        , test "panes absent from the desired list are dropped" <|
            \_ ->
                Page.reconcile identity
                    .key
                    initializeDesired
                    [ "kept", "dropped" ]
                    [ desired "kept" "replacement" "unused" ]
                    |> .panes
                    |> Expect.equal [ "kept" ]
        , test "pane and effect order follow the desired list" <|
            \_ ->
                Page.reconcile identity
                    .key
                    initializeDesired
                    [ "second", "first" ]
                    [ desired "first" "unused first" "unused"
                    , desired "third" "third" "initialized third"
                    , desired "second" "unused second" "unused"
                    ]
                    |> Expect.equal
                        { panes = [ "first", "third", "second" ]
                        , effects = [ "initialized third" ]
                        , initializedKeys = [ "third" ]
                        }
        ]


routeFlowTests : Test
routeFlowTests =
    describe "route flows"
        [ test "changing meal slot preserves diary and search pane keys" <|
            \_ ->
                Page.init
                    { route = FoodSearch (Just date) (Just Lunch)
                    , today = Just today
                    }
                    |> first
                    |> Page.initPreserving
                        { route = FoodSearch (Just date) (Just Dinner)
                        , today = Just today
                        }
                    |> first
                    |> Page.paneKeys
                    |> Expect.equal [ diaryKey date Nothing, "food-search" ]
        , test "opening a logged row from search opens standalone editing" <|
            \_ ->
                Page.init
                    { route = FoodSearch (Just date) (Just Lunch)
                    , today = Just today
                    }
                    |> first
                    |> Page.initPreserving
                        { route = FoodLogEntry "log-1" (Just date) Nothing
                        , today = Just today
                        }
                    |> first
                    |> Page.paneKeys
                    |> Expect.equal [ "log-detail:log-1" ]
        , test "food detail replaces search without replacing the diary" <|
            \_ ->
                Page.init
                    { route = FoodSearch (Just date) (Just Lunch)
                    , today = Just today
                    }
                    |> first
                    |> Page.initPreserving
                        { route = FoodShow "food-1" (Just date) (Just Lunch) Nothing
                        , today = Just today
                        }
                    |> first
                    |> Page.paneKeys
                    |> Expect.equal
                        [ diaryKey date Nothing
                        , "food-detail:food-1:" ++ date ++ ":lunch"
                        ]
        , test "meal detail replaces search without replacing the diary" <|
            \_ ->
                Page.init
                    { route = FoodSearch (Just date) (Just Lunch)
                    , today = Just today
                    }
                    |> first
                    |> Page.initPreserving
                        { route = MealShow "meal-1", today = Just today }
                    |> first
                    |> Page.paneKeys
                    |> Expect.equal
                        [ diaryKey date Nothing, "meal-detail:meal-1" ]
        , test "another food detail replaces the current right pane" <|
            \_ ->
                Page.init
                    { route = CustomFoodShow "food-1", today = Just today }
                    |> first
                    |> Page.initPreserving
                        { route = CustomFoodShow "food-2", today = Just today }
                    |> first
                    |> Page.paneKeys
                    |> Expect.equal
                        [ "custom-food-list", "custom-food-detail:food-2" ]
        , test "calendar stays main while contextual panes are replaced" <|
            \_ ->
                Page.init
                    { route = DiaryCalendar (Just month), today = Just today }
                    |> first
                    |> Page.initPreserving
                        { route = DiaryDay (Just date) (Just month)
                        , today = Just today
                        }
                    |> first
                    |> Page.initPreserving
                        { route = FoodSearch (Just date) (Just Lunch)
                        , today = Just today
                        }
                    |> first
                    |> Page.initPreserving
                        { route = FoodShow "food-1" (Just date) (Just Lunch) Nothing
                        , today = Just today
                        }
                    |> first
                    |> Page.paneKeys
                    |> Expect.equal
                        [ "calendar:" ++ month
                        , "food-detail:food-1:" ++ date ++ ":lunch"
                        ]
        , test "using a contextual diary promotes it to the main pane" <|
            \_ ->
                let
                    context : Page.InitContext
                    context =
                        { route = DiaryDay (Just date) (Just month)
                        , today = Just today
                        }
                in
                Page.init context
                    |> first
                    |> Page.update context
                        (Page.GotDiaryMsg DiaryDayPage.MacroModeToggled)
                    |> Maybe.map first
                    |> Maybe.map Page.paneKeys
                    |> Expect.equal (Just [ diaryKey date Nothing ])
        , test "promoted diary navigation drops its calendar lineage" <|
            \_ ->
                let
                    context : Page.InitContext
                    context =
                        { route = DiaryDay (Just date) (Just month)
                        , today = Just today
                        }
                in
                Page.init context
                    |> first
                    |> Page.update context
                        (Page.GotDiaryMsg DiaryDayPage.PreviousDayClicked)
                    |> Maybe.map
                        (\( model, _, outMsg ) ->
                            ( Page.paneKeys model, outMsg )
                        )
                    |> Expect.equal
                        (Just
                            ( [ diaryKey date Nothing ]
                            , Page.Navigate
                                (DiaryDay (Just previousDate) Nothing)
                            )
                        )
        , test "moving to another day changes the diary key" <|
            \_ ->
                Page.init
                    { route = DiaryDay (Just date) Nothing
                    , today = Just today
                    }
                    |> first
                    |> Page.initPreserving
                        { route = DiaryDay (Just previousDate) Nothing
                        , today = Just today
                        }
                    |> first
                    |> Page.paneKeys
                    |> Expect.equal [ diaryKey previousDate Nothing ]
        , test "quick-add success keeps the matching diary mounted for refresh" <|
            \_ ->
                let
                    context : Page.InitContext
                    context =
                        { route = FoodSearch (Just date) (Just Lunch)
                        , today = Just today
                        }

                    model : Page.Model
                    model =
                        Page.init context |> first
                in
                Page.update
                    context
                    (Page.GotFoodSearchMsg
                        (FoodSearchPage.QuickAddCompleted (Ok productLog))
                    )
                    model
                    |> Maybe.map first
                    |> Maybe.map Page.paneKeys
                    |> Expect.equal
                        (Just [ diaryKey date Nothing, "food-search" ])
        , test "an undated diary route follows the day over, a dated one stays put" <|
            \_ ->
                let
                    tomorrow : Maybe LocalDate
                    tomorrow =
                        LocalDate.fromString "2026-07-30"

                    afterRollover : Route -> List String
                    afterRollover route =
                        Page.init { route = route, today = Just today }
                            |> first
                            |> Page.initPreserving { route = route, today = tomorrow }
                            |> first
                            |> Page.paneKeys
                in
                ( afterRollover (DiaryDay Nothing Nothing)
                , afterRollover (DiaryDay (Just date) Nothing)
                )
                    |> Expect.equal
                        ( [ diaryKey "2026-07-30" Nothing ]
                        , [ diaryKey date Nothing ]
                        )
        , test "a rolled-over day reaches the diary pane already open on it" <|
            \_ ->
                let
                    context : Page.InitContext
                    context =
                        { route = DiaryDay Nothing Nothing, today = Just today }

                    mounted : Page.Model
                    mounted =
                        Page.init context |> first

                    nextDay : Page.Model -> Maybe Page.OutMsg
                    nextDay model =
                        Page.update context
                            (Page.GotDiaryMsg DiaryDayPage.NextDayClicked)
                            model
                            |> Maybe.map third
                in
                ( nextDay mounted
                , mounted
                    |> Page.localContextReceived context
                        { date = "2026-07-30", timezone = "Asia/Kolkata" }
                    |> Maybe.map first
                    |> Maybe.andThen nextDay
                )
                    |> Expect.equal
                        ( Just Page.NoOutMsg
                        , Just (Page.Navigate (DiaryDay (Just "2026-07-30") Nothing))
                        )
        ]


type alias Desired =
    { key : String
    , pane : String
    , effect : String
    }


desired : String -> String -> String -> Desired
desired key pane effect =
    { key = key, pane = pane, effect = effect }


initializeDesired : Desired -> ( String, String )
initializeDesired item =
    ( item.pane, item.effect )


expectPaneKeys : Route -> List String -> Expect.Expectation
expectPaneKeys route expected =
    paneKeysForRoute route
        |> Expect.equal expected


paneKeysForRoute : Route -> List String
paneKeysForRoute route =
    Page.init { route = route, today = Just today }
        |> first
        |> Page.paneKeys


diaryKey : String -> Maybe String -> String
diaryKey selectedDate calendarMonth =
    "diary:"
        ++ selectedDate
        ++ ":"
        ++ Maybe.withDefault "none" calendarMonth


date : String
date =
    "2026-07-20"


previousDate : String
previousDate =
    "2026-07-19"


productLog : FoodLog
productLog =
    { id = "log-1"
    , logDate = dateValue date
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = Just Lunch
    , item =
        FoodLog.ProductLogItem
            { id = "food-1", name = "Apple", brand = Nothing }
    , quantity = { amount = "1", unit = "serving" }
    , nutrients = []
    , notes = Nothing
    }


dateValue : String -> LocalDate
dateValue raw =
    LocalDate.fromString raw |> Maybe.withDefault today


month : String
month =
    "2026-07"


today : LocalDate
today =
    case LocalDate.fromString "2026-07-29" of
        Just value ->
            value

        Nothing ->
            LocalDate.fromPosix Time.utc (Time.millisToPosix 0)


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
