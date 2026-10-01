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
        [ test "each route maps to its expected pane keys" <|
            \_ ->
                routePaneCases
                    |> List.map
                        (\( label, route, expected ) ->
                            Expect.equal expected (paneKeysForRoute route)
                                |> Expect.onFail label
                        )
                    |> expectAll
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
        , test "standalone creation routes replace the entire contextual workspace" <|
            \_ ->
                let
                    replacedBy : Route -> List String
                    replacedBy route =
                        Page.init
                            { route = FoodSearch (Just date) (Just Lunch)
                            , today = Just today
                            }
                            |> first
                            |> Page.initPreserving
                                { route = route, today = Just today }
                            |> first
                            |> Page.paneKeys
                in
                Expect.all
                    [ \_ ->
                        replacedBy CustomFoodCreate
                            |> Expect.equal [ "custom-food-create" ]
                    , \_ ->
                        replacedBy CustomFoodCreateWithAi
                            |> Expect.equal [ "custom-food-create" ]
                    ]
                    ()
        ]


routePaneCases : List ( String, Route, List String )
routePaneCases =
    [ ( "calendar-aware diary opens calendar and diary panes"
      , DiaryDay (Just date) (Just month)
      , [ "calendar:" ++ month, diaryKey date (Just month) ]
      )
    , ( "an absent or unparseable diary date falls back to today"
      , DiaryDay Nothing Nothing
      , [ diaryKey today Nothing ]
      )
    , ( "a missing diary date falls back to today"
      , DiaryDay Nothing Nothing
      , [ diaryKey today Nothing ]
      )
    , ( "a future diary date is clamped to today"
      , DiaryDay (Just (dateValue "2027-01-01")) Nothing
      , [ diaryKey today Nothing ]
      )
    , ( "dated search opens diary and search panes"
      , FoodSearch (Just date) (Just Lunch)
      , [ diaryKey date Nothing, "food-search" ]
      )
    , ( "dated food opens diary and food detail panes"
      , FoodShow "food-1" (Just date) (Just Lunch) Nothing
      , [ diaryKey date Nothing, "food-detail:food-1:" ++ LocalDate.format date ++ ":lunch" ]
      )
    , ( "dated log editing is standalone"
      , FoodLogEntry "log-1" (Just date) Nothing
      , [ "log-detail:log-1" ]
      )
    , ( "nutrition details retain the diary pane"
      , NutritionDetails (Just date)
      , [ diaryKey date Nothing, "nutrition-details:" ++ LocalDate.format date ]
      )
    , ( "custom food detail retains its list pane"
      , CustomFoodShow "food-1"
      , [ "custom-food-list", "custom-food-detail:food-1" ]
      )
    , ( "meal detail retains its list pane"
      , MealShow "meal-1"
      , [ "meal-list", "meal-detail:meal-1" ]
      )
    , ( "user edit is standalone"
      , AdminEditUser "user-1"
      , [ "admin-edit-user:user-1" ]
      )
    , ( "custom food create is standalone"
      , CustomFoodCreate
      , [ "custom-food-create" ]
      )
    , ( "custom food edit is standalone"
      , CustomFoodEdit "food-1"
      , [ "custom-food-edit:food-1" ]
      )
    , ( "meal create is standalone"
      , MealCreate
      , [ "meal-create" ]
      )
    , ( "meal edit is standalone"
      , MealEdit "meal-1"
      , [ "meal-edit:meal-1" ]
      )
    , ( "generic search stays standalone"
      , FoodSearch Nothing Nothing
      , [ "food-search" ]
      )
    , ( "undated search degrades to standalone search"
      , FoodSearch Nothing (Just Lunch)
      , [ "food-search" ]
      )
    , ( "undated food degrades to standalone detail on direct entry"
      , FoodShow "food-1" Nothing Nothing Nothing
      , [ "food-detail:food-1:none:none" ]
      )
    , ( "undated log degrades to standalone detail"
      , FoodLogEntry "log-1" Nothing Nothing
      , [ "log-detail:log-1" ]
      )
    , ( "AI creation is also standalone"
      , CustomFoodCreateWithAi
      , [ "custom-food-create" ]
      )
    , ( "AI ad-hoc logging is standalone"
      , AiLogCreate (Just date) (Just Lunch)
      , [ "create-ai-log" ]
      )
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
                        , "food-detail:food-1:" ++ LocalDate.format date ++ ":lunch"
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
                        , "food-detail:food-1:" ++ LocalDate.format date ++ ":lunch"
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
                        ( [ diaryKey (dateValue "2026-07-30") Nothing ]
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
                        , Just (Page.Navigate (DiaryDay (Just (dateValue "2026-07-30")) Nothing))
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


expectAll : List Expect.Expectation -> Expect.Expectation
expectAll expectations =
    Expect.all (List.map always expectations) ()


paneKeysForRoute : Route -> List String
paneKeysForRoute route =
    Page.init { route = route, today = Just today }
        |> first
        |> Page.paneKeys


diaryKey : LocalDate -> Maybe String -> String
diaryKey selectedDate calendarMonth =
    "diary:"
        ++ LocalDate.format selectedDate
        ++ ":"
        ++ Maybe.withDefault "none" calendarMonth


date : LocalDate
date =
    dateValue "2026-07-20"


previousDate : LocalDate
previousDate =
    dateValue "2026-07-19"


productLog : FoodLog
productLog =
    { id = "log-1"
    , logDate = date
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
