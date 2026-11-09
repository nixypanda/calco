module Page.PanePlanTest exposing (tests)

{-| The route plan is the single source of truth for pane count, order and
keys. These tests assert the invariant between the plan and the initialized
workspace, and pin the documented date-query 1→2 pane transition through the
real `Page.init`/`initPreserving` path.
-}

import Data.MealSlot as MealSlot
import Data.Route exposing (Route(..))
import Expect
import Lib.Date exposing (LocalDate)
import Page
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)


type alias ContextualShape =
    { mealShow : List String
    , customFoodShow : List String
    , foodShow : List String
    , nutritionDetails : List String
    }


tests : Test
tests =
    describe "Page pane plan"
        [ test "plan keys match initialized pane keys for representative routes" <|
            \_ ->
                let
                    context : Route -> Page.InitCtx
                    context route =
                        { route = route, today = Just Fixtures.today }

                    plannedKeys : Route -> List String
                    plannedKeys route =
                        plansFor (context route) [] |> List.map .key

                    initializedKeys : Route -> List String
                    initializedKeys route =
                        Page.init (context route)
                            |> Fixtures.tupleFirst
                            |> Page.paneKeys

                    routes : List Route
                    routes =
                        [ DiaryDay Nothing Nothing
                        , DiaryDay Nothing (Just month)
                        , DiaryCalendar (Just month)
                        , NutritionDetails (Just date)
                        , GoalSettings
                        , FoodShow "food-1" (Just date) (Just MealSlot.Lunch) Nothing
                        , FoodSearch (Just date) (Just MealSlot.Lunch)
                        , FoodLogEntry "log-1" (Just date) Nothing
                        , AdHocLogCreate (Just date) (Just MealSlot.Lunch)
                        , AiLogCreate (Just date) (Just MealSlot.Lunch)
                        , CustomFoodShow "food-1"
                        , MealShow "meal-1"
                        , AdminDashboard
                        , AdminEditUser "user-1"
                        , AuthLogin
                        , BootstrapSetup
                        , DiarySettings
                        , SettingsApiKeys
                        , SettingsApiKeyCreate
                        , CustomFoodList
                        , CustomFoodCreate
                        , CustomFoodCreateWithAi
                        , CustomFoodEdit "food-1"
                        , MealList
                        , MealCreate
                        , MealEdit "meal-1"
                        ]
                in
                routes
                    |> List.map
                        (\route ->
                            { planned = plannedKeys route
                            , initialized = initializedKeys route
                            }
                        )
                    |> List.filter (\entry -> entry.planned /= entry.initialized)
                    |> Expect.equal []
        , test "dated food routes keep one pane before today, then add the diary" <|
            \_ ->
                let
                    foodShow : Route
                    foodShow =
                        FoodShow "food-1" (Just date) (Just MealSlot.Lunch) Nothing

                    foodSearch : Route
                    foodSearch =
                        FoodSearch (Just date) (Just MealSlot.Lunch)

                    observe : Route -> Transition
                    observe route =
                        let
                            before : Page.Model
                            before =
                                initModel route Nothing

                            after : Page.Model
                            after =
                                resume route before
                        in
                        { before = Page.paneKeys before
                        , beforeLoading = Page.isLoading before
                        , after = Page.paneKeys after
                        , afterLoading = Page.isLoading after
                        }
                in
                Expect.equal
                    { foodShow = observe foodShow
                    , foodSearch = observe foodSearch
                    }
                    { foodShow =
                        { before = [ "food-detail:food-1:2026-07-20:lunch" ]
                        , beforeLoading = False
                        , after =
                            [ "diary:2026-07-20:none"
                            , "food-detail:food-1:2026-07-20:lunch"
                            ]
                        , afterLoading = False
                        }
                    , foodSearch =
                        { before = [ "food-search" ]
                        , beforeLoading = False
                        , after = [ "diary:2026-07-20:none", "food-search" ]
                        , afterLoading = False
                        }
                    }
        , test "date-gated routes wait for today, then recover" <|
            \_ ->
                let
                    gated : List ( Route, List String )
                    gated =
                        [ ( DiaryDay Nothing Nothing, [ "diary:2026-08-18:none" ] )
                        , ( DiaryDay (Just date) (Just month)
                          , [ "calendar:2026-07", "diary:2026-07-20:2026-07" ]
                          )
                        , ( DiaryCalendar (Just month), [ "calendar:2026-07" ] )
                        , ( NutritionDetails (Just date)
                          , [ "diary:2026-07-20:none", "nutrition-details:2026-07-20" ]
                          )
                        , ( GoalSettings, [ "goals-settings:2026-08-18" ] )
                        ]
                in
                Expect.all
                    (List.map
                        (\( route, expectedKeys ) _ ->
                            let
                                waiting : Page.Model
                                waiting =
                                    initModel route Nothing

                                resumed : Page.Model
                                resumed =
                                    resume route waiting
                            in
                            Expect.equal
                                { waitingKeys = Page.paneKeys waiting
                                , waitingForToday = Page.isLoading waiting
                                , resumedKeys = Page.paneKeys resumed
                                , resumedForToday = Page.isLoading resumed
                                }
                                { waitingKeys = []
                                , waitingForToday = True
                                , resumedKeys = expectedKeys
                                , resumedForToday = False
                                }
                        )
                        gated
                    )
                    ()
        , test "Root and NotFound resolve to the placeholder pane" <|
            \_ ->
                let
                    observe : Route -> Placeholder
                    observe route =
                        let
                            model : Page.Model
                            model =
                                initModel route (Just Fixtures.today)

                            context : Page.InitCtx
                            context =
                                { route = route, today = Just Fixtures.today }
                        in
                        { plan = plansFor context [] |> List.map .key
                        , rendered = Page.paneKeys model
                        , loading = Page.isLoading model
                        }
                in
                Expect.equal
                    { root = observe Root
                    , notFound = observe NotFound
                    }
                    { root =
                        { plan = [ "placeholder:unmigrated" ]
                        , rendered = [ "placeholder:This route is not migrated yet." ]
                        , loading = False
                        }
                    , notFound =
                        { plan = [ "placeholder:unmigrated" ]
                        , rendered = [ "placeholder:This route is not migrated yet." ]
                        , loading = False
                        }
                    }
        , test "contextual plans preserve a main pane and fall back otherwise" <|
            \_ ->
                let
                    existingMain : List Page.Pane
                    existingMain =
                        initModel (DiaryDay (Just date) Nothing) (Just Fixtures.today)
                            |> .panes

                    existingOther : List Page.Pane
                    existingOther =
                        initModel DiarySettings (Just Fixtures.today) |> .panes

                    shape : List Page.Pane -> ContextualShape
                    shape existing =
                        let
                            keys : Route -> List String
                            keys route =
                                plansFor { route = route, today = Just Fixtures.today } existing
                                    |> List.map .key
                        in
                        { mealShow = keys (MealShow "meal-1")
                        , customFoodShow = keys (CustomFoodShow "food-1")
                        , foodShow =
                            keys
                                (FoodShow "food-1" (Just date) (Just MealSlot.Lunch) Nothing)
                        , nutritionDetails = keys (NutritionDetails (Just date))
                        }

                    fallback : ContextualShape
                    fallback =
                        { mealShow = [ "meal-list", "meal-detail:meal-1" ]
                        , customFoodShow = [ "custom-food-list", "custom-food-detail:food-1" ]
                        , foodShow =
                            [ "diary:2026-07-20:none"
                            , "food-detail:food-1:2026-07-20:lunch"
                            ]
                        , nutritionDetails =
                            [ "diary:2026-07-20:none"
                            , "nutrition-details:2026-07-20"
                            ]
                        }
                in
                Expect.equal
                    { main = shape existingMain
                    , other = shape existingOther
                    , none = shape []
                    }
                    { main =
                        { mealShow = [ "diary:2026-07-20:none", "meal-detail:meal-1" ]
                        , customFoodShow =
                            [ "diary:2026-07-20:none", "custom-food-detail:food-1" ]
                        , foodShow =
                            [ "diary:2026-07-20:none"
                            , "food-detail:food-1:2026-07-20:lunch"
                            ]
                        , nutritionDetails =
                            [ "diary:2026-07-20:none"
                            , "nutrition-details:2026-07-20"
                            ]
                        }
                    , other = fallback
                    , none = fallback
                    }
        ]


type alias Transition =
    { before : List String
    , beforeLoading : Bool
    , after : List String
    , afterLoading : Bool
    }


type alias Placeholder =
    { plan : List String
    , rendered : List String
    , loading : Bool
    }


initModel : Route -> Maybe LocalDate -> Page.Model
initModel route today =
    Page.init { route = route, today = today } |> Fixtures.tupleFirst


resume : Route -> Page.Model -> Page.Model
resume route model =
    Page.initPreserving { route = route, today = Just Fixtures.today } model
        |> Fixtures.tupleFirst


plansFor : Page.InitCtx -> List Page.Pane -> List Page.PanePlan
plansFor context existing =
    Page.panePlanForRoute context existing


date : LocalDate
date =
    Fixtures.date "2026-07-20"


month : String
month =
    "2026-07"
