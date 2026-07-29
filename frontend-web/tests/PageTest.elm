module PageTest exposing (tests)

import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page
import Test exposing (Test, describe, test)
import Time


tests : Test
tests =
    describe "Page workspaces"
        [ test "calendar-aware diary opens calendar and diary panes" <|
            \_ ->
                Page.init
                    { route = DiaryDay (Just "2026-07-20") (Just "2026-07")
                    , today = Just today
                    }
                    |> first
                    |> isCalendarDiary
                    |> Expect.equal True
        , test "dated search opens diary and search panes" <|
            \_ ->
                Page.init
                    { route = FoodSearch (Just "2026-07-20") (Just Lunch)
                    , today = Just today
                    }
                    |> first
                    |> isDiarySearch
                    |> Expect.equal True
        , test "dated food opens diary, search, and log-food panes" <|
            \_ ->
                Page.init
                    { route = FoodShow "food-1" (Just "2026-07-20") (Just Lunch)
                    , today = Just today
                    }
                    |> first
                    |> isDiarySearchFood
                    |> Expect.equal True
        , test "dated log opens diary and edit-log panes" <|
            \_ ->
                Page.init
                    { route = FoodLogEntry "log-1" (Just "2026-07-20") Nothing
                    , today = Just today
                    }
                    |> first
                    |> isDiaryLog
                    |> Expect.equal True
        , test "custom food detail retains its list pane" <|
            \_ ->
                Page.init
                    { route = CustomFoodShow "food-1", today = Just today }
                    |> first
                    |> isCustomFoodShow
                    |> Expect.equal True
        , test "meal detail retains its list pane" <|
            \_ ->
                Page.init
                    { route = MealShow "meal-1", today = Just today }
                    |> first
                    |> isMealDetail
                    |> Expect.equal True
        , test "user edit retains the admin list pane" <|
            \_ ->
                Page.init
                    { route = AdminEditUser "user-1", today = Just today }
                    |> first
                    |> isAdminEdit
                    |> Expect.equal True
        , test "generic search stays standalone" <|
            \_ ->
                Page.init
                    { route = FoodSearch Nothing Nothing, today = Just today }
                    |> first
                    |> isStandaloneSearch
                    |> Expect.equal True
        , test "generic search retains its pane when a food is opened" <|
            \_ ->
                Page.init
                    { route = FoodSearch Nothing Nothing, today = Just today }
                    |> first
                    |> Page.initPreserving
                        { route = FoodShow "food-1" Nothing Nothing
                        , today = Just today
                        }
                    |> first
                    |> isSearchFood
                    |> Expect.equal True
        , test "diary search retains both panes when custom food creation opens" <|
            \_ ->
                Page.init
                    { route = FoodSearch (Just "2026-07-20") (Just Lunch)
                    , today = Just today
                    }
                    |> first
                    |> Page.initPreserving
                        { route = CustomFoodCreate, today = Just today }
                    |> first
                    |> isDiarySearchCreateFood
                    |> Expect.equal True
        , test "calendar-aware log opens all three contextual panes" <|
            \_ ->
                Page.init
                    { route =
                        FoodLogEntry
                            "log-1"
                            (Just "2026-07-20")
                            (Just "2026-07")
                    , today = Just today
                    }
                    |> first
                    |> isCalendarDiaryLog
                    |> Expect.equal True
        ]


isCalendarDiary : Page.Model -> Bool
isCalendarDiary model =
    case model of
        Page.DiaryCalendarWorkspace _ _ ->
            True

        _ ->
            False


isDiarySearch : Page.Model -> Bool
isDiarySearch model =
    case model of
        Page.DiarySearchWorkspace _ _ ->
            True

        _ ->
            False


isDiarySearchFood : Page.Model -> Bool
isDiarySearchFood model =
    case model of
        Page.DiarySearchFoodWorkspace _ _ _ ->
            True

        _ ->
            False


isDiaryLog : Page.Model -> Bool
isDiaryLog model =
    case model of
        Page.DiaryLogWorkspace _ _ ->
            True

        _ ->
            False


isCustomFoodShow : Page.Model -> Bool
isCustomFoodShow model =
    case model of
        Page.CustomFoodShowWorkspace _ _ ->
            True

        _ ->
            False


isMealDetail : Page.Model -> Bool
isMealDetail model =
    case model of
        Page.MealDetailWorkspace _ _ ->
            True

        _ ->
            False


isAdminEdit : Page.Model -> Bool
isAdminEdit model =
    case model of
        Page.AdminEditUserWorkspace _ _ ->
            True

        _ ->
            False


isStandaloneSearch : Page.Model -> Bool
isStandaloneSearch model =
    case model of
        Page.FoodSearchPage _ ->
            True

        _ ->
            False


isSearchFood : Page.Model -> Bool
isSearchFood model =
    case model of
        Page.SearchFoodWorkspace _ _ ->
            True

        _ ->
            False


isDiarySearchCreateFood : Page.Model -> Bool
isDiarySearchCreateFood model =
    case model of
        Page.DiarySearchCreateFoodWorkspace _ _ _ ->
            True

        _ ->
            False


isCalendarDiaryLog : Page.Model -> Bool
isCalendarDiaryLog model =
    case model of
        Page.CalendarDiaryLogWorkspace _ _ _ ->
            True

        _ ->
            False


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
