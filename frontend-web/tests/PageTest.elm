module PageTest exposing (tests)

import Data.FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page
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
        , test "dated search opens diary and search panes" <|
            \_ ->
                expectPaneKeys
                    (FoodSearch (Just date) (Just Lunch))
                    [ diaryKey date Nothing, "food-search" ]
        , test "dated food opens diary, search, and food detail panes" <|
            \_ ->
                expectPaneKeys
                    (FoodShow "food-1" (Just date) (Just Lunch))
                    [ diaryKey date Nothing
                    , "food-search"
                    , "food-detail:food-1:" ++ date ++ ":lunch"
                    ]
        , test "dated log opens diary and edit-log panes" <|
            \_ ->
                expectPaneKeys
                    (FoodLogEntry "log-1" (Just date) Nothing)
                    [ diaryKey date Nothing, "log-detail:log-1" ]
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
        , test "user edit retains the admin list pane" <|
            \_ ->
                expectPaneKeys
                    (AdminEditUser "user-1")
                    [ "admin-users", "admin-edit-user:user-1" ]
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
                    (FoodShow "food-1" Nothing Nothing)
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
                        { route = FoodShow "food-1" Nothing Nothing
                        , today = Just today
                        }
                    |> first
                    |> Page.paneKeys
                    |> Expect.equal
                        [ "food-search", "food-detail:food-1:none:none" ]
        , test "diary search retains both panes when custom food creation opens" <|
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
                    |> Expect.equal
                        [ diaryKey date Nothing
                        , "food-search"
                        , "custom-food-create"
                        ]
        , test "calendar-aware log opens all three contextual panes" <|
            \_ ->
                expectPaneKeys
                    (FoodLogEntry "log-1" (Just date) (Just month))
                    [ "calendar:" ++ month
                    , diaryKey date (Just month)
                    , "log-detail:log-1"
                    ]
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
        , test "opening a logged row from search retains the diary pane" <|
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
                    |> Expect.equal [ diaryKey date Nothing, "log-detail:log-1" ]
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
    Page.init { route = route, today = Just today }
        |> first
        |> Page.paneKeys
        |> Expect.equal expected


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
    , mealSlot = Just "lunch"
    , item =
        { itemType = ItemRef.Product
        , id = "food-1"
        , name = "Apple"
        , brand = Nothing
        }
    , quantity = { amount = "1", unit = "serving" }
    , nutritionSummary = Nutrition.emptySummary
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
