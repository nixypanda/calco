module PageTest exposing (tests)

import Data.ApiKey exposing (ApiKeyScope(..), CreatedApiKey)
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.MealSlot exposing (MealSlot(..))
import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page
import Page.Diary.Day as DiaryDayPage
import Page.Food.Search as FoodSearchPage
import Page.Settings.ApiKeyCreate as ApiKeyCreate
import Page.Settings.ApiKeys as ApiKeys
import Test exposing (Test, describe, test)
import Time


tests : Test
tests =
    describe "Page"
        [ workspaceTests
        , reconcileTests
        , routeFlowTests
        , apiKeysPaneTests
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
    , ( "API key settings is standalone"
      , SettingsApiKeys
      , [ "api-keys" ]
      )
    , ( "API key creation is standalone"
      , SettingsApiKeyCreate
      , [ "api-key-create" ]
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
                    context : Page.InitCtx
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
                    context : Page.InitCtx
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
                    context : Page.InitCtx
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
                    context : Page.InitCtx
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
                    |> Page.localCtxReceived context
                        { date = dateValue "2026-07-30", timezone = "Asia/Kolkata" }
                    |> Maybe.map first
                    |> Maybe.andThen nextDay
                )
                    |> Expect.equal
                        ( Just Page.NoOutMsg
                        , Just (Page.Navigate (DiaryDay (Just (dateValue "2026-07-30")) Nothing))
                        )
        ]


apiKeysPaneTests : Test
apiKeysPaneTests =
    describe "api key pane lifetimes"
        [ test "a list load from a previous api-keys pane cannot replace the new pane" <|
            \_ ->
                let
                    context : Page.InitCtx
                    context =
                        { route = SettingsApiKeys, today = Just today }

                    started : Page.Model
                    started =
                        Page.init context |> first

                    generationA : Int
                    generationA =
                        apiKeysGeneration started |> Maybe.withDefault 0

                    returned : Page.Model
                    returned =
                        started
                            |> Page.initPreserving
                                { route = DiarySettings, today = Just today }
                            |> first
                            |> Page.initPreserving context
                            |> first

                    generationB : Int
                    generationB =
                        apiKeysGeneration returned |> Maybe.withDefault 0

                    loadedB : Page.Model
                    loadedB =
                        pageStep context
                            (Page.GotApiKeysMsg generationB
                                (ApiKeys.ApiKeysLoaded (Ok [ createdKeyB.apiKey ]))
                            )
                            returned

                    afterStaleA : Page.Model
                    afterStaleA =
                        pageStep context
                            (Page.GotApiKeysMsg generationA
                                (ApiKeys.ApiKeysLoaded (Ok [ createdKeyA.apiKey ]))
                            )
                            loadedB
                in
                { generationsDiffer = generationA /= generationB
                , names = apiKeysNames afterStaleA
                }
                    |> Expect.equal
                        { generationsDiffer = True
                        , names = [ "Second script" ]
                        }
        , test "a create completion from an old api-key-create pane is ignored" <|
            \_ ->
                let
                    context : Page.InitCtx
                    context =
                        { route = SettingsApiKeyCreate, today = Just today }

                    started : Page.Model
                    started =
                        Page.init context |> first

                    generationA : Int
                    generationA =
                        apiKeyCreateGeneration started |> Maybe.withDefault 0

                    submittedA : Page.Model
                    submittedA =
                        startApiKeyCreate context generationA "First script" started

                    requestA : Int
                    requestA =
                        apiKeyCreatePendingRequestId submittedA |> Maybe.withDefault 0

                    returned : Page.Model
                    returned =
                        submittedA
                            |> Page.initPreserving
                                { route = DiarySettings, today = Just today }
                            |> first
                            |> Page.initPreserving context
                            |> first

                    generationB : Int
                    generationB =
                        apiKeyCreateGeneration returned |> Maybe.withDefault 0

                    submittedB : Page.Model
                    submittedB =
                        startApiKeyCreate context generationB "Second script" returned

                    requestB : Int
                    requestB =
                        apiKeyCreatePendingRequestId submittedB |> Maybe.withDefault 0

                    afterStaleA : Page.Model
                    afterStaleA =
                        pageStep context
                            (Page.GotApiKeyCreateMsg generationA
                                (ApiKeyCreate.CreateCompleted requestA (Ok createdKeyA))
                            )
                            submittedB

                    afterB : Page.Model
                    afterB =
                        pageStep context
                            (Page.GotApiKeyCreateMsg generationB
                                (ApiKeyCreate.CreateCompleted requestB (Ok createdKeyB))
                            )
                            afterStaleA
                in
                { generationsDiffer = generationA /= generationB
                , sameRequestId = requestA == requestB
                , stale =
                    ( apiKeyCreatePendingRequestId afterStaleA
                    , apiKeyCreateCreatedToken afterStaleA
                    )
                , final = apiKeyCreateCreatedToken afterB
                }
                    |> Expect.equal
                        { generationsDiffer = True
                        , sameRequestId = True
                        , stale = ( Just requestB, Nothing )
                        , final = Just "token-b"
                        }
        , test "Done on the created api-key pane returns to the api-keys list" <|
            \_ ->
                let
                    context : Page.InitCtx
                    context =
                        { route = SettingsApiKeyCreate, today = Just today }

                    started : Page.Model
                    started =
                        Page.init context |> first

                    generation : Int
                    generation =
                        apiKeyCreateGeneration started |> Maybe.withDefault 0

                    created : Page.Model
                    created =
                        completeApiKeyCreate context generation "First script" createdKeyA started
                in
                { token = apiKeyCreateCreatedToken created
                , out =
                    pageOut context
                        (Page.GotApiKeyCreateMsg generation ApiKeyCreate.DoneClicked)
                        created
                }
                    |> Expect.equal
                        { token = Just "token-a"
                        , out = Just (Page.Navigate SettingsApiKeys)
                        }
        , test "Copy on the created api-key pane sends the copy port request" <|
            \_ ->
                let
                    context : Page.InitCtx
                    context =
                        { route = SettingsApiKeyCreate, today = Just today }

                    started : Page.Model
                    started =
                        Page.init context |> first

                    generation : Int
                    generation =
                        apiKeyCreateGeneration started |> Maybe.withDefault 0

                    created : Page.Model
                    created =
                        completeApiKeyCreate context generation "First script" createdKeyA started

                    copied : Page.Model
                    copied =
                        pageStep context
                            (Page.GotApiKeyCreateMsg generation ApiKeyCreate.CopyClicked)
                            created
                in
                { out =
                    pageOut context
                        (Page.GotApiKeyCreateMsg generation ApiKeyCreate.CopyClicked)
                        created
                        |> Maybe.andThen pageCopySummary
                , copyId = apiKeyCreateCopyPendingId copied
                , token = apiKeyCreateCreatedToken copied
                }
                    |> Expect.equal
                        { out = Just ( generation, 2, "token-a" )
                        , copyId = Just 2
                        , token = Just "token-a"
                        }
        , test "navigating to api keys after creation drops the create pane and token" <|
            \_ ->
                let
                    context : Page.InitCtx
                    context =
                        { route = SettingsApiKeyCreate, today = Just today }

                    started : Page.Model
                    started =
                        Page.init context |> first

                    generation : Int
                    generation =
                        apiKeyCreateGeneration started |> Maybe.withDefault 0

                    created : Page.Model
                    created =
                        completeApiKeyCreate context generation "First script" createdKeyA started

                    navigated : Page.Model
                    navigated =
                        created
                            |> Page.initPreserving
                                { route = SettingsApiKeys, today = Just today }
                            |> first
                in
                { keys = Page.paneKeys navigated
                , token = apiKeyCreateCreatedToken navigated
                }
                    |> Expect.equal
                        { keys = [ "api-keys" ]
                        , token = Nothing
                        }
        , test "a stale copy result from an old api-key-create pane generation is ignored" <|
            \_ ->
                let
                    context : Page.InitCtx
                    context =
                        { route = SettingsApiKeyCreate, today = Just today }

                    started : Page.Model
                    started =
                        Page.init context |> first

                    generationA : Int
                    generationA =
                        apiKeyCreateGeneration started |> Maybe.withDefault 0

                    submittedA : Page.Model
                    submittedA =
                        startApiKeyCreate context generationA "First script" started

                    requestA : Int
                    requestA =
                        apiKeyCreatePendingRequestId submittedA |> Maybe.withDefault 0

                    copyA : Page.Model
                    copyA =
                        submittedA
                            |> pageStep context
                                (Page.GotApiKeyCreateMsg generationA
                                    (ApiKeyCreate.CreateCompleted requestA (Ok createdKeyA))
                                )
                            |> pageStep context
                                (Page.GotApiKeyCreateMsg generationA
                                    ApiKeyCreate.CopyClicked
                                )

                    oldCopyId : Int
                    oldCopyId =
                        apiKeyCreateCopyPendingId copyA |> Maybe.withDefault 0

                    returned : Page.Model
                    returned =
                        copyA
                            |> Page.initPreserving
                                { route = DiarySettings, today = Just today }
                            |> first
                            |> Page.initPreserving context
                            |> first

                    generationB : Int
                    generationB =
                        apiKeyCreateGeneration returned |> Maybe.withDefault 0

                    submittedB : Page.Model
                    submittedB =
                        startApiKeyCreate context generationB "Second script" returned

                    requestB : Int
                    requestB =
                        apiKeyCreatePendingRequestId submittedB |> Maybe.withDefault 0

                    copyB : Page.Model
                    copyB =
                        submittedB
                            |> pageStep context
                                (Page.GotApiKeyCreateMsg generationB
                                    (ApiKeyCreate.CreateCompleted requestB (Ok createdKeyB))
                                )
                            |> pageStep context
                                (Page.GotApiKeyCreateMsg generationB
                                    ApiKeyCreate.CopyClicked
                                )

                    newCopyId : Int
                    newCopyId =
                        apiKeyCreateCopyPendingId copyB |> Maybe.withDefault 0

                    afterOldCopy : Page.Model
                    afterOldCopy =
                        pageStep context
                            (Page.CopyTextResult generationA oldCopyId False)
                            copyB

                    afterNewCopy : Page.Model
                    afterNewCopy =
                        pageStep context
                            (Page.CopyTextResult generationB newCopyId True)
                            afterOldCopy
                in
                { generationsDiffer = generationA /= generationB
                , sameCopyId = oldCopyId == newCopyId
                , stale =
                    ( apiKeyCreateCreatedToken afterOldCopy
                    , apiKeyCreateCopyStateName afterOldCopy
                    )
                , final = apiKeyCreateCopyStateName afterNewCopy
                }
                    |> Expect.equal
                        { generationsDiffer = True
                        , sameCopyId = True
                        , stale = ( Just "token-b", "pending" )
                        , final = "succeeded"
                        }
        , test "clearStore keeps the api-key-create generation across re-entry" <|
            \_ ->
                let
                    context : Page.InitCtx
                    context =
                        { route = SettingsApiKeyCreate, today = Just today }

                    started : Page.Model
                    started =
                        Page.init context |> first

                    generationA : Int
                    generationA =
                        apiKeyCreateGeneration started |> Maybe.withDefault 0

                    submittedA : Page.Model
                    submittedA =
                        startApiKeyCreate context generationA "First script" started

                    requestA : Int
                    requestA =
                        apiKeyCreatePendingRequestId submittedA |> Maybe.withDefault 0

                    reentered : Page.Model
                    reentered =
                        submittedA
                            |> Page.clearStore
                            |> Page.initPreserving context
                            |> first

                    generationB : Int
                    generationB =
                        apiKeyCreateGeneration reentered |> Maybe.withDefault 0

                    submittedB : Page.Model
                    submittedB =
                        startApiKeyCreate context generationB "Second script" reentered

                    requestB : Int
                    requestB =
                        apiKeyCreatePendingRequestId submittedB |> Maybe.withDefault 0

                    afterStaleA : Page.Model
                    afterStaleA =
                        pageStep context
                            (Page.GotApiKeyCreateMsg generationA
                                (ApiKeyCreate.CreateCompleted requestA (Ok createdKeyA))
                            )
                            submittedB

                    afterB : Page.Model
                    afterB =
                        pageStep context
                            (Page.GotApiKeyCreateMsg generationB
                                (ApiKeyCreate.CreateCompleted requestB (Ok createdKeyB))
                            )
                            afterStaleA
                in
                { generationsDiffer = generationA /= generationB
                , stale =
                    ( apiKeyCreatePendingRequestId afterStaleA
                    , apiKeyCreateCreatedToken afterStaleA
                    )
                , final = apiKeyCreateCreatedToken afterB
                }
                    |> Expect.equal
                        { generationsDiffer = True
                        , stale = ( Just requestB, Nothing )
                        , final = Just "token-b"
                        }
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


pageStep : Page.InitCtx -> Page.Msg -> Page.Model -> Page.Model
pageStep context msg model =
    Page.update context msg model
        |> Maybe.map first
        |> Maybe.withDefault model


pageOut : Page.InitCtx -> Page.Msg -> Page.Model -> Maybe Page.OutMsg
pageOut context msg model =
    Page.update context msg model
        |> Maybe.map third


startApiKeyCreate : Page.InitCtx -> Int -> String -> Page.Model -> Page.Model
startApiKeyCreate context generation name model =
    model
        |> pageStep context
            (Page.GotApiKeyCreateMsg generation (ApiKeyCreate.NameChanged name))
        |> pageStep context
            (Page.GotApiKeyCreateMsg generation ApiKeyCreate.Submitted)


completeApiKeyCreate :
    Page.InitCtx
    -> Int
    -> String
    -> CreatedApiKey
    -> Page.Model
    -> Page.Model
completeApiKeyCreate context generation name created model =
    let
        submitted : Page.Model
        submitted =
            startApiKeyCreate context generation name model

        requestId : Int
        requestId =
            apiKeyCreatePendingRequestId submitted |> Maybe.withDefault 0
    in
    pageStep context
        (Page.GotApiKeyCreateMsg generation
            (ApiKeyCreate.CreateCompleted requestId (Ok created))
        )
        submitted


apiKeysGeneration : Page.Model -> Maybe Int
apiKeysGeneration model =
    apiKeysPane model |> Maybe.map Tuple.first


apiKeysPane : Page.Model -> Maybe ( Int, ApiKeys.Model )
apiKeysPane model =
    model.panes
        |> List.filterMap
            (\pane ->
                case pane of
                    Page.ApiKeysPane generation sub ->
                        Just ( generation, sub )

                    _ ->
                        Nothing
            )
        |> List.head


apiKeyCreateGeneration : Page.Model -> Maybe Int
apiKeyCreateGeneration model =
    apiKeyCreatePane model |> Maybe.map Tuple.first


apiKeyCreatePane : Page.Model -> Maybe ( Int, ApiKeyCreate.Model )
apiKeyCreatePane model =
    model.panes
        |> List.filterMap
            (\pane ->
                case pane of
                    Page.ApiKeyCreatePane generation sub ->
                        Just ( generation, sub )

                    _ ->
                        Nothing
            )
        |> List.head


apiKeyCreateForm : Page.Model -> Maybe ApiKeyCreate.CreateForm
apiKeyCreateForm model =
    apiKeyCreatePane model
        |> Maybe.andThen
            (\( _, sub ) ->
                case sub of
                    ApiKeyCreate.Form formModel ->
                        Just formModel.form

                    ApiKeyCreate.Created _ ->
                        Nothing
            )


apiKeyCreatePendingRequestId : Page.Model -> Maybe Int
apiKeyCreatePendingRequestId model =
    apiKeyCreateForm model
        |> Maybe.andThen
            (\createForm ->
                case createForm.state of
                    ApiKeyCreate.Submitting requestId ->
                        Just requestId

                    _ ->
                        Nothing
            )


apiKeyCreateCreatedToken : Page.Model -> Maybe String
apiKeyCreateCreatedToken model =
    apiKeyCreatePane model
        |> Maybe.andThen
            (\( _, sub ) ->
                case sub of
                    ApiKeyCreate.Created createdModel ->
                        Just createdModel.created.token

                    ApiKeyCreate.Form _ ->
                        Nothing
            )


apiKeyCreateCopyPendingId : Page.Model -> Maybe Int
apiKeyCreateCopyPendingId model =
    apiKeyCreatePane model
        |> Maybe.andThen
            (\( _, sub ) ->
                case sub of
                    ApiKeyCreate.Created createdModel ->
                        case createdModel.copyState of
                            ApiKeyCreate.CopyPending copyId ->
                                Just copyId

                            _ ->
                                Nothing

                    ApiKeyCreate.Form _ ->
                        Nothing
            )


apiKeyCreateCopyStateName : Page.Model -> String
apiKeyCreateCopyStateName model =
    apiKeyCreatePane model
        |> Maybe.map
            (\( _, sub ) ->
                case sub of
                    ApiKeyCreate.Created createdModel ->
                        case createdModel.copyState of
                            ApiKeyCreate.CopyIdle ->
                                "idle"

                            ApiKeyCreate.CopyPending _ ->
                                "pending"

                            ApiKeyCreate.CopySucceeded ->
                                "succeeded"

                            ApiKeyCreate.CopyFailed ->
                                "failed"

                    ApiKeyCreate.Form _ ->
                        "none"
            )
        |> Maybe.withDefault "none"


pageCopySummary : Page.OutMsg -> Maybe ( Int, Int, String )
pageCopySummary outMsg =
    case outMsg of
        Page.CopyText generation copyId token ->
            Just ( generation, copyId, token )

        _ ->
            Nothing


apiKeysNames : Page.Model -> List String
apiKeysNames model =
    apiKeysPane model
        |> Maybe.map
            (\( _, sub ) ->
                case sub of
                    ApiKeys.Loaded loaded ->
                        List.map .name loaded.keys

                    _ ->
                        []
            )
        |> Maybe.withDefault []


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


createdKeyA : CreatedApiKey
createdKeyA =
    { apiKey =
        { id = "key-a"
        , name = "First script"
        , tokenHint = "calco_pat_aaaaaaaa"
        , scope = Read
        , createdAt = "2026-07-29T10:00:00Z"
        , lastUsedAt = Nothing
        , expiresAt = Nothing
        }
    , token = "token-a"
    }


createdKeyB : CreatedApiKey
createdKeyB =
    { apiKey =
        { id = "key-b"
        , name = "Second script"
        , tokenHint = "calco_pat_bbbbbbbb"
        , scope = Read
        , createdAt = "2026-07-29T11:00:00Z"
        , lastUsedAt = Nothing
        , expiresAt = Nothing
        }
    , token = "token-b"
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
