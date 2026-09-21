module Page exposing
    ( DiaryGoalResult
    , DiaryLogsResult
    , DiaryPaneId
    , InitContext
    , LatestSlotsResult
    , Model
    , Msg(..)
    , NutrientsResult
    , OutMsg(..)
    , Pane(..)
    , PreferencesResult
    , UnitsResult
    , barcodeScannerEventReceived
    , clearStore
    , init
    , initPreserving
    , isLoading
    , loading
    , localContextReceived
    , modalView
    , paneKeys
    , photoPreviewUrls
    , reconcile
    , update
    , view
    )

import Api.Admin
import Api.Auth
import Api.Client
import Api.DiaryPreferences
import Api.FoodAssistant
import Api.Foods
import Api.Goals
import Api.Logs
import Api.Meals
import Api.NutritionDetails
import Component.FoodAssistant as FoodAssistantUi
import Component.Meal.Form as MealForm
import Data.Auth as Auth
import Data.BarcodeScan exposing (ScannerEvent)
import Data.DiaryPreferences
import Data.FoodLog
import Data.Goals
import Data.ItemRef as ItemRef
import Data.LocalContext exposing (LocalContext)
import Data.LogSummary as LogSummary
import Data.MealSlot as MealSlot exposing (MealSlot)
import Data.Nutrition exposing (defaultCode)
import Data.Route exposing (Route(..))
import Element exposing (Element)
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Page.CustomFood.Create as CustomFoodCreate
import Page.CustomFood.Edit as CustomFoodEdit
import Page.CustomFood.List as CustomFoodList
import Page.CustomFood.Show as CustomFoodShow
import Page.Diary.Calendar as DiaryCalendar
import Page.Diary.Day as DiaryDay
import Page.Diary.Settings as DiarySettings
import Page.Food.Search as FoodSearch
import Page.Food.Show as FoodShow
import Page.FoodLog.CreateAdHoc as CreateAdHocLog
import Page.FoodLog.CreateWithAi as CreateWithAiLog
import Page.FoodLog.Entry as FoodLogEntry
import Page.Goals.Settings as GoalsSettings
import Page.Meal.Create as MealCreate
import Page.Meal.Edit as MealEdit
import Page.Meal.List as MealList
import Page.Meal.Show as MealShow
import Page.NutritionDetails as NutritionDetails
import Page.Users.BootstrapSetup as BootstrapSetup
import Page.Users.CreateUser as AdminCreateUser
import Page.Users.Dashboard as AdminDashboard
import Page.Users.EditUser as AdminEditUser
import Page.Users.Login as AuthLogin
import Set exposing (Set)
import Store exposing (Store)
import Translations.Ids exposing (TranslationId(..))
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
import Ui.Skeleton as Skeleton
import Ui.Workspace as Workspace



-- MODEL


type alias Model =
    { panes : List Pane
    , waitingForToday : Bool
    , store : Store
    }


type Pane
    = LoginPane AuthLogin.Model
    | SetupPane BootstrapSetup.Model
    | AdminPane AdminDashboard.Model
    | AdminCreateUserPane AdminCreateUser.Model
    | AdminEditUserPane String AdminEditUser.Model
    | DiaryPane DiaryPaneId DiaryDay.Model
    | DiaryCalendarPane String DiaryCalendar.Model
    | NutritionDetailsPane LocalDate NutritionDetails.Model
    | GoalsSettingsPane LocalDate GoalsSettings.Model
    | DiarySettingsPane DiarySettings.Model
    | FoodSearchPane FoodSearch.Model
    | FoodDetailPane String FoodShow.Model
    | FoodLogDetailPane String FoodLogEntry.Model
    | CreateAdHocLogPane CreateAdHocLog.Model
    | CreateWithAiLogPane CreateWithAiLog.Model
    | CustomFoodListPane CustomFoodList.Model
    | CustomFoodCreatePane CustomFoodCreate.Model
    | CustomFoodEditPane String CustomFoodEdit.Model
    | CustomFoodShowPane String CustomFoodShow.Model
    | MealListPane MealList.Model
    | MealCreatePane MealCreate.Model
    | MealEditPane String MealEdit.Model
    | MealDetailPane String MealShow.Model
    | PlaceholderPane String


type alias DiaryPaneId =
    { date : LocalDate
    , calendarMonth : Maybe String
    }


type DesiredPane
    = DesiredPane String (() -> ( Pane, Cmd Msg, OutMsg ))


type alias ReconcileResult pane effect =
    { panes : List pane
    , effects : List effect
    , initializedKeys : List String
    }


type alias InitContext =
    { route : Route
    , today : Maybe LocalDate
    }


type OutMsg
    = NoOutMsg
    | Navigate Route
    | SessionExpired
    | RequestLocalContext
    | RequestBarcodeScanStart
    | RequestBarcodeScanStop
    | RevokePhotoPreviewUrls (List String)
    | LoginSucceeded Auth.LoginSession
    | SetupSucceeded Auth.LoginSession


isLoading : Model -> Bool
isLoading model =
    model.waitingForToday


loading : Model
loading =
    { panes = [], waitingForToday = True, store = Store.empty }


clearStore : Model -> Model
clearStore model =
    { panes = []
    , waitingForToday = True
    , store = Store.reset model.store
    }


paneKeys : Model -> List String
paneKeys model =
    List.map paneKey model.panes


photoPreviewUrls : Model -> List String
photoPreviewUrls model =
    model.panes
        |> List.concatMap
            (\pane ->
                case pane of
                    CustomFoodCreatePane createModel ->
                        CustomFoodCreate.photoPreviewUrls createModel

                    CreateWithAiLogPane createModel ->
                        CreateWithAiLog.photoPreviewUrls createModel

                    _ ->
                        []
            )


paneKey : Pane -> String
paneKey pane =
    case pane of
        LoginPane _ ->
            "login"

        SetupPane _ ->
            "setup"

        AdminPane _ ->
            "admin-users"

        AdminCreateUserPane _ ->
            "admin-create-user"

        AdminEditUserPane userId _ ->
            "admin-edit-user:" ++ userId

        DiaryPane paneId _ ->
            diaryPaneKey paneId

        DiaryCalendarPane month _ ->
            "calendar:" ++ month

        NutritionDetailsPane date _ ->
            nutritionDetailsPaneKey date

        GoalsSettingsPane date _ ->
            goalsSettingsPaneKey date

        DiarySettingsPane _ ->
            "diary-settings"

        FoodSearchPane _ ->
            "food-search"

        FoodDetailPane key _ ->
            key

        FoodLogDetailPane logId _ ->
            "log-detail:" ++ logId

        CreateAdHocLogPane _ ->
            "create-ad-hoc-log"

        CreateWithAiLogPane _ ->
            "create-ai-log"

        CustomFoodListPane _ ->
            "custom-food-list"

        CustomFoodCreatePane _ ->
            "custom-food-create"

        CustomFoodEditPane productId _ ->
            "custom-food-edit:" ++ productId

        CustomFoodShowPane productId _ ->
            "custom-food-detail:" ++ productId

        MealListPane _ ->
            "meal-list"

        MealCreatePane _ ->
            "meal-create"

        MealEditPane mealId _ ->
            "meal-edit:" ++ mealId

        MealDetailPane mealId _ ->
            "meal-detail:" ++ mealId

        PlaceholderPane message ->
            "placeholder:" ++ message


diaryPaneKey : DiaryPaneId -> String
diaryPaneKey paneId =
    "diary:"
        ++ LocalDate.format paneId.date
        ++ ":"
        ++ Maybe.withDefault "none" paneId.calendarMonth


nutritionDetailsPaneKey : LocalDate -> String
nutritionDetailsPaneKey date =
    "nutrition-details:" ++ LocalDate.format date


goalsSettingsPaneKey : LocalDate -> String
goalsSettingsPaneKey date =
    "goals-settings:" ++ LocalDate.format date


init : InitContext -> ( Model, Cmd Msg, OutMsg )
init context =
    initPreserving context
        { panes = []
        , waitingForToday = False
        , store = Store.empty
        }


initPreserving : InitContext -> Model -> ( Model, Cmd Msg, OutMsg )
initPreserving context current =
    case panesForRoute context current.panes of
        Nothing ->
            ( { current | panes = [], waitingForToday = True }
            , Cmd.none
            , NoOutMsg
            )

        Just desiredPanes ->
            finishReconcile context
                current.store
                (reconcile paneKey desiredPaneKey initDesiredPane current.panes desiredPanes)


reconcile :
    (pane -> String)
    -> (desired -> String)
    -> (desired -> ( pane, effect ))
    -> List pane
    -> List desired
    -> ReconcileResult pane effect
reconcile existingKey desiredKey initialize existing desired =
    let
        step : desired -> ReconcileResult pane effect -> ReconcileResult pane effect
        step desiredPane result =
            case List.filter (\pane -> existingKey pane == desiredKey desiredPane) existing of
                pane :: _ ->
                    { result | panes = pane :: result.panes }

                [] ->
                    let
                        ( pane, effect ) =
                            initialize desiredPane
                    in
                    { panes = pane :: result.panes
                    , effects = effect :: result.effects
                    , initializedKeys = desiredKey desiredPane :: result.initializedKeys
                    }

        reversed : ReconcileResult pane effect
        reversed =
            List.foldl step
                { panes = [], effects = [], initializedKeys = [] }
                desired
    in
    { panes = List.reverse reversed.panes
    , effects = List.reverse reversed.effects
    , initializedKeys = List.reverse reversed.initializedKeys
    }


desiredPaneKey : DesiredPane -> String
desiredPaneKey (DesiredPane key _) =
    key


initDesiredPane : DesiredPane -> ( Pane, ( Cmd Msg, OutMsg ) )
initDesiredPane (DesiredPane _ initialize) =
    let
        ( pane, cmd, outMsg ) =
            initialize ()
    in
    ( pane, ( cmd, outMsg ) )


finishReconcile :
    InitContext
    -> Store
    -> ReconcileResult Pane ( Cmd Msg, OutMsg )
    -> ( Model, Cmd Msg, OutMsg )
finishReconcile context store result =
    let
        ( retargetedPanes, retargetCmd ) =
            retargetSearchForRoute context.route result.panes

        hydratedPanes : List Pane
        hydratedPanes =
            List.map
                (hydrateInitialized (Set.fromList result.initializedKeys) store)
                retargetedPanes

        ( nextStore, sharedCmd ) =
            ensureSharedData hydratedPanes store

        ( finalStore, dateCmd ) =
            ensureDateData hydratedPanes nextStore
    in
    ( { panes = hydratedPanes, waitingForToday = False, store = finalStore }
    , Cmd.batch
        [ result.effects |> List.map Tuple.first |> Cmd.batch
        , retargetCmd
        , sharedCmd
        , dateCmd
        ]
    , result.effects |> List.map Tuple.second |> List.foldl preferOutMsg NoOutMsg
    )



-- HYDRATION


{-| A pane the reconcile reused is already showing its data; only one it just
created needs the cache poured in.
-}
hydrateInitialized : Set String -> Store -> Pane -> Pane
hydrateInitialized initializedKeys store pane =
    if Set.member (paneKey pane) initializedKeys then
        pane
            |> hydrateShared store
            |> hydrateDated store

    else
        pane


hydrateShared : Store -> Pane -> Pane
hydrateShared store pane =
    pane
        |> hydrateWith hydrateUnits (Store.cached Store.units store)
        |> hydrateWith hydrateNutrients (Store.cached Store.nutrients store)
        |> hydrateWith hydratePreferences (Store.cached Store.preferences store)


hydrateWith :
    (Result Api.Client.ApiError a -> Pane -> Pane)
    -> Maybe (Result Api.Client.ApiError a)
    -> Pane
    -> Pane
hydrateWith hydrate cached pane =
    case cached of
        Just result ->
            hydrate result pane

        Nothing ->
            pane


hydrateDated : Store -> Pane -> Pane
hydrateDated store pane =
    case pane of
        DiaryPane paneId diary ->
            DiaryPane paneId
                (diary
                    |> applyCached DiaryDay.update
                        (DiaryDay.LogsLoaded paneId.date)
                        (Store.cached (Store.diaryLogsAt paneId.date) store)
                    |> applyCached DiaryDay.update
                        (DiaryDay.GoalLoaded paneId.date)
                        (Store.cached (Store.diaryGoalAt paneId.date) store)
                    |> applyCached DiaryDay.update
                        (DiaryDay.LatestSlotsReceived paneId.date)
                        (Store.cached (Store.latestSlotsAt paneId.date) store)
                )

        GoalsSettingsPane date goals ->
            GoalsSettingsPane date
                (applyCached GoalsSettings.update
                    GoalsSettings.GoalLoaded
                    (Store.cached (Store.diaryGoalAt date) store)
                    goals
                )

        _ ->
            pane


applyCached :
    (msg -> model -> ( model, cmd, outMsg ))
    -> (Result error value -> msg)
    -> Maybe (Result error value)
    -> model
    -> model
applyCached paneUpdate toMsg cached model =
    case cached of
        Just result ->
            modelOnly (paneUpdate (toMsg result) model)

        Nothing ->
            model


{-| Hydrating replays the very message the network path would have delivered, so
that every state transition still happens inside the pane's own `update`. There
is nowhere to send a `Cmd` or an `OutMsg` from inside a `List.map` over panes,
and dropping them is only safe for these loaded/failed messages: the one
`OutMsg` they can produce is `SessionExpired` on a 401, which the request that
cached the failure has already emitted. Do not reuse this to replay a message
that acts on the world.
-}
modelOnly : ( model, cmd, outMsg ) -> model
modelOnly ( model, _, _ ) =
    model


hydrateUnits : UnitsResult -> Pane -> Pane
hydrateUnits result pane =
    case pane of
        FoodDetailPane key model ->
            FoodDetailPane key
                (modelOnly (FoodShow.update (FoodShow.UnitsLoaded result) model))

        FoodLogDetailPane key model ->
            FoodLogDetailPane key
                (modelOnly (FoodLogEntry.update (FoodLogEntry.UnitsLoaded result) model))

        CreateAdHocLogPane model ->
            CreateAdHocLogPane
                (modelOnly (CreateAdHocLog.update (CreateAdHocLog.UnitsLoaded result) model))

        CreateWithAiLogPane model ->
            CreateWithAiLogPane
                (modelOnly (CreateWithAiLog.update (CreateWithAiLog.UnitsLoaded result) model))

        CustomFoodCreatePane model ->
            CustomFoodCreatePane
                (modelOnly (CustomFoodCreate.update (CustomFoodCreate.UnitsLoaded result) model))

        CustomFoodEditPane key model ->
            CustomFoodEditPane key
                (modelOnly (CustomFoodEdit.update (CustomFoodEdit.UnitsLoaded result) model))

        CustomFoodShowPane key model ->
            CustomFoodShowPane key
                (modelOnly (CustomFoodShow.update (CustomFoodShow.UnitsLoaded result) model))

        MealDetailPane key model ->
            MealDetailPane key
                (modelOnly (MealShow.update (MealShow.UnitsLoaded result) model))

        MealCreatePane model ->
            MealCreatePane
                (modelOnly (MealCreate.update (MealCreate.UnitsLoaded result) model))

        MealEditPane key model ->
            MealEditPane key
                (modelOnly (MealEdit.update (MealEdit.UnitsLoaded result) model))

        _ ->
            pane


hydrateNutrients : NutrientsResult -> Pane -> Pane
hydrateNutrients result pane =
    case pane of
        CreateAdHocLogPane model ->
            CreateAdHocLogPane
                (modelOnly (CreateAdHocLog.update (CreateAdHocLog.NutrientsLoaded result) model))

        CreateWithAiLogPane model ->
            CreateWithAiLogPane
                (modelOnly (CreateWithAiLog.update (CreateWithAiLog.NutrientsLoaded result) model))

        CustomFoodCreatePane model ->
            CustomFoodCreatePane
                (modelOnly
                    (CustomFoodCreate.update (CustomFoodCreate.NutrientsLoaded result) model)
                )

        CustomFoodEditPane key model ->
            CustomFoodEditPane key
                (modelOnly (CustomFoodEdit.update (CustomFoodEdit.NutrientsLoaded result) model))

        _ ->
            pane


hydratePreferences : PreferencesResult -> Pane -> Pane
hydratePreferences result pane =
    case pane of
        DiaryPane paneId model ->
            DiaryPane paneId
                (modelOnly (DiaryDay.update (DiaryDay.PreferencesLoaded result) model))

        DiarySettingsPane model ->
            DiarySettingsPane
                (modelOnly (DiarySettings.update (DiarySettings.PreferencesLoaded result) model))

        _ ->
            pane



-- CACHED RESOURCES


type alias SharedResource a =
    { access : Store.Access a
    , fetch : Store.RequestToken -> Cmd Msg
    , hydrate : Result Api.Client.ApiError a -> Pane -> Pane
    }


{-| `apply` reaches every pane showing the date, since a diary and a goals page
can be open on the same date at once.
-}
type alias DateResource a =
    { access : LocalDate -> Store.Access a
    , fetch : LocalDate -> Store.RequestToken -> Cmd Msg
    , apply : LocalDate -> Result Api.Client.ApiError a -> List Pane -> List Pane
    }


unitsResource : SharedResource Api.Foods.UnitListResponse
unitsResource =
    { access = Store.units
    , fetch = \token -> Api.Foods.listUnits (SharedUnitsLoaded token)
    , hydrate = hydrateUnits
    }


nutrientsResource : SharedResource Api.Foods.NutrientListResponse
nutrientsResource =
    { access = Store.nutrients
    , fetch = \token -> Api.Foods.listNutrients (SharedNutrientsLoaded token)
    , hydrate = hydrateNutrients
    }


preferencesResource : SharedResource Data.DiaryPreferences.DiaryPreferences
preferencesResource =
    { access = Store.preferences
    , fetch = \token -> Api.DiaryPreferences.get (SharedPreferencesLoaded token)
    , hydrate = hydratePreferences
    }


diaryLogsResource : DateResource (List Data.FoodLog.FoodLog)
diaryLogsResource =
    { access = Store.diaryLogsAt
    , fetch = \date token -> Api.Logs.listLogs date (DiaryLogsStoreLoaded token date)
    , apply =
        \date result ->
            updateDiaryPanes date (DiaryDay.LogsLoaded date result)
                >> (case result of
                        Ok logs ->
                            applyDayTotals date logs

                        Err _ ->
                            identity
                   )
    }


diaryGoalResource : DateResource Data.Goals.GoalSnapshot
diaryGoalResource =
    { access = Store.diaryGoalAt
    , fetch = \date token -> Api.Goals.getGoal date (DiaryGoalStoreLoaded token date)
    , apply =
        \date result ->
            updateDiaryPanes date (DiaryDay.GoalLoaded date result)
                >> updateGoalSettingsPanes date result
    }


latestSlotsResource : DateResource Api.Logs.LatestSlotsResponse
latestSlotsResource =
    { access = Store.latestSlotsAt
    , fetch =
        \date token ->
            Api.Logs.latestSlots
                { before = date, lookbackDays = latestSlotsLookbackDays }
                (LatestSlotsStoreLoaded token date)
    , apply = \date result -> updateDiaryPanes date (DiaryDay.LatestSlotsReceived date result)
    }


latestSlotsLookbackDays : Int
latestSlotsLookbackDays =
    30


ensureSharedData : List Pane -> Store -> ( Store, Cmd Msg )
ensureSharedData panes store =
    if List.any needsSessionData panes then
        let
            ( withUnits, unitsCmd ) =
                ensureShared unitsResource store

            ( withNutrients, nutrientsCmd ) =
                ensureShared nutrientsResource withUnits

            ( withPreferences, preferencesCmd ) =
                ensureShared preferencesResource withNutrients
        in
        ( withPreferences
        , Cmd.batch [ unitsCmd, nutrientsCmd, preferencesCmd ]
        )

    else
        ( store, Cmd.none )


ensureShared : SharedResource a -> Store -> ( Store, Cmd Msg )
ensureShared resource store =
    case Store.request resource.access store of
        Just ( nextStore, token ) ->
            ( nextStore, resource.fetch token )

        Nothing ->
            ( store, Cmd.none )


ensureDateData : List Pane -> Store -> ( Store, Cmd Msg )
ensureDateData panes store =
    let
        ensurePane : Pane -> ( Store, List (Cmd Msg) ) -> ( Store, List (Cmd Msg) )
        ensurePane pane ( currentStore, cmds ) =
            case pane of
                DiaryPane paneId _ ->
                    let
                        ( logsStore, logsCmd ) =
                            ensureDate diaryLogsResource paneId.date currentStore

                        ( goalStore, goalCmd ) =
                            ensureDate diaryGoalResource paneId.date logsStore

                        ( slotsStore, slotsCmd ) =
                            ensureDate latestSlotsResource paneId.date goalStore
                    in
                    ( slotsStore, slotsCmd :: goalCmd :: logsCmd :: cmds )

                GoalsSettingsPane date _ ->
                    let
                        ( nextStore, cmd ) =
                            ensureDate diaryGoalResource date currentStore
                    in
                    ( nextStore, cmd :: cmds )

                _ ->
                    ( currentStore, cmds )

        ( finalStore, reversedCmds ) =
            List.foldl ensurePane ( store, [] ) panes
    in
    ( finalStore, Cmd.batch (List.reverse reversedCmds) )


ensureDate : DateResource a -> LocalDate -> Store -> ( Store, Cmd Msg )
ensureDate resource date store =
    case Store.request (resource.access date) store of
        Just ( nextStore, token ) ->
            ( nextStore, resource.fetch date token )

        Nothing ->
            ( store, Cmd.none )


{-| Enumerated rather than defaulted, so that a pane added later has to be
classified instead of silently issuing authenticated requests from an
unauthenticated screen.
-}
needsSessionData : Pane -> Bool
needsSessionData pane =
    case pane of
        LoginPane _ ->
            False

        SetupPane _ ->
            False

        AdminPane _ ->
            False

        AdminCreateUserPane _ ->
            False

        AdminEditUserPane _ _ ->
            False

        PlaceholderPane _ ->
            False

        DiaryPane _ _ ->
            True

        DiaryCalendarPane _ _ ->
            True

        NutritionDetailsPane _ _ ->
            True

        GoalsSettingsPane _ _ ->
            True

        DiarySettingsPane _ ->
            True

        FoodSearchPane _ ->
            True

        FoodDetailPane _ _ ->
            True

        FoodLogDetailPane _ _ ->
            True

        CreateAdHocLogPane _ ->
            True

        CreateWithAiLogPane _ ->
            True

        CustomFoodListPane _ ->
            True

        CustomFoodCreatePane _ ->
            True

        CustomFoodEditPane _ _ ->
            True

        CustomFoodShowPane _ _ ->
            True

        MealListPane _ ->
            True

        MealCreatePane _ ->
            True

        MealEditPane _ _ ->
            True

        MealDetailPane _ _ ->
            True


retargetSearchForRoute : Route -> List Pane -> ( List Pane, Cmd Msg )
retargetSearchForRoute route panes =
    case route of
        FoodSearch dateParam mealSlot ->
            retargetSearch dateParam mealSlot panes

        FoodShow _ dateParam mealSlot _ ->
            retargetSearch dateParam mealSlot panes

        _ ->
            ( panes, Cmd.none )


retargetSearch : Maybe String -> Maybe MealSlot -> List Pane -> ( List Pane, Cmd Msg )
retargetSearch dateParam mealSlot panes =
    let
        retarget : Pane -> ( Pane, Cmd Msg )
        retarget pane =
            case pane of
                FoodSearchPane search ->
                    let
                        ( next, changed ) =
                            FoodSearch.retarget dateParam mealSlot search
                    in
                    ( FoodSearchPane next
                    , if changed then
                        initialFoodSearchCmd dateParam mealSlot

                      else
                        Cmd.none
                    )

                _ ->
                    ( pane, Cmd.none )

        results : List ( Pane, Cmd Msg )
        results =
            List.map retarget panes
    in
    ( List.map Tuple.first results, results |> List.map Tuple.second |> Cmd.batch )


panesForRoute : InitContext -> List Pane -> Maybe (List DesiredPane)
panesForRoute context existing =
    case context.route of
        AuthLogin ->
            Just [ simpleDesired "login" (LoginPane AuthLogin.init) ]

        BootstrapSetup ->
            Just [ simpleDesired "setup" (SetupPane BootstrapSetup.init) ]

        AdminDashboard ->
            Just [ adminDesired context ]

        AdminCreateUser ->
            Just
                [ simpleDesired
                    "admin-create-user"
                    (AdminCreateUserPane AdminCreateUser.init)
                ]

        AdminEditUser userId ->
            Just [ adminEditDesired context userId ]

        DiaryDay dateParam calendarMonth ->
            context.today
                |> Maybe.map
                    (\today ->
                        case calendarMonth of
                            Just month ->
                                contextualWorkspace
                                    existing
                                    [ calendarDesired context today (Just month) ]
                                    (diaryDesired context today dateParam calendarMonth)

                            Nothing ->
                                [ diaryDesired context today dateParam Nothing ]
                    )

        DiaryCalendar monthParam ->
            context.today
                |> Maybe.map (\today -> [ calendarDesired context today monthParam ])

        NutritionDetails dateParam ->
            context.today
                |> Maybe.map
                    (\today ->
                        contextualWorkspace
                            existing
                            [ diaryDesired context today dateParam Nothing ]
                            (nutritionDesired context today dateParam)
                    )

        GoalSettings ->
            context.today
                |> Maybe.map (\today -> [ goalsDesired context today ])

        DiarySettings ->
            Just [ diarySettingsDesired context ]

        FoodSearch dateParam mealSlot ->
            Just (searchWorkspaceDesired context existing dateParam mealSlot)

        FoodShow productId dateParam mealSlot lookupNote ->
            Just
                (foodWorkspaceDesired
                    context
                    existing
                    productId
                    dateParam
                    mealSlot
                    lookupNote
                )

        FoodLogEntry logId _ _ ->
            Just [ foodLogDetailDesired context logId ]

        AdHocLogCreate dateParam mealSlot ->
            Just [ createAdHocLogDesired context dateParam mealSlot ]

        AiLogCreate dateParam mealSlot ->
            Just [ createWithAiLogDesired context dateParam mealSlot ]

        CustomFoodCreate ->
            Just [ customFoodCreatePaneDesired context CustomFoodCreate.init ]

        CustomFoodCreateWithAi ->
            Just
                [ customFoodCreatePaneDesired
                    context
                    CustomFoodCreate.initWithAssistant
                ]

        CustomFoodEdit productId ->
            Just [ customFoodEditDesired context productId ]

        CustomFoodShow productId ->
            Just
                (contextualWorkspace
                    existing
                    [ customFoodListDesired context ]
                    (customFoodShowDesired context productId)
                )

        CustomFoodList ->
            Just [ customFoodListDesired context ]

        MealList ->
            Just [ mealListDesired context ]

        MealCreate ->
            Just [ mealCreateDesired context ]

        MealEdit mealId ->
            Just [ mealEditDesired context mealId ]

        MealShow mealId ->
            Just
                (contextualWorkspace
                    existing
                    [ mealListDesired context ]
                    (mealDetailDesired context mealId)
                )

        _ ->
            Just
                [ simpleDesired
                    "placeholder:unmigrated"
                    (PlaceholderPane (I18n.en TidCommonRouteNotMigrated))
                ]


simpleDesired : String -> Pane -> DesiredPane
simpleDesired key pane =
    DesiredPane key (\_ -> ( pane, Cmd.none, NoOutMsg ))


fromInit :
    InitContext
    -> String
    -> (subModel -> Pane)
    -> (InitContext -> outMsg -> ( Cmd Msg, OutMsg ))
    -> (() -> ( subModel, outMsg ))
    -> DesiredPane
fromInit context key toPane applyOut initialize =
    DesiredPane key
        (\_ ->
            let
                ( subModel, subOut ) =
                    initialize ()

                ( cmd, outMsg ) =
                    applyOut context subOut
            in
            ( toPane subModel, cmd, outMsg )
        )


adminDesired : InitContext -> DesiredPane
adminDesired context =
    fromInit context "admin-users" AdminPane applyAdminOutMsg (\_ -> AdminDashboard.init)


adminEditDesired : InitContext -> String -> DesiredPane
adminEditDesired context userId =
    fromInit context
        ("admin-edit-user:" ++ userId)
        (AdminEditUserPane userId)
        applyAdminEditUserOutMsg
        (\_ -> AdminEditUser.init userId)


diaryDesired : InitContext -> LocalDate -> Maybe String -> Maybe String -> DesiredPane
diaryDesired context today dateParam calendarMonth =
    let
        paneId : DiaryPaneId
        paneId =
            { date = dateFromParam today dateParam
            , calendarMonth = calendarMonth
            }
    in
    fromInit context
        (diaryPaneKey paneId)
        (DiaryPane paneId)
        applyDiaryOutMsg
        (\_ ->
            DiaryDay.init
                { date = paneId.date
                , calendarMonth = calendarMonth
                , today = today
                }
        )


dateFromParam : LocalDate -> Maybe String -> LocalDate
dateFromParam today dateParam =
    dateParam
        |> Maybe.andThen LocalDate.fromString
        |> Maybe.withDefault today
        |> LocalDate.clampTo today


calendarDesired : InitContext -> LocalDate -> Maybe String -> DesiredPane
calendarDesired context today monthParam =
    let
        key : String
        key =
            Maybe.withDefault (String.left 7 (LocalDate.format today)) monthParam
    in
    fromInit context
        ("calendar:" ++ key)
        (DiaryCalendarPane key)
        applyDiaryCalendarOutMsg
        (\_ -> DiaryCalendar.init { monthParam = monthParam, today = today })


nutritionDesired : InitContext -> LocalDate -> Maybe String -> DesiredPane
nutritionDesired context today dateParam =
    let
        date : LocalDate
        date =
            dateFromParam today dateParam
    in
    fromInit context
        (nutritionDetailsPaneKey date)
        (NutritionDetailsPane date)
        applyNutritionDetailsOutMsg
        (\_ -> NutritionDetails.init { date = date, today = today })


goalsDesired : InitContext -> LocalDate -> DesiredPane
goalsDesired context today =
    fromInit context
        (goalsSettingsPaneKey today)
        (GoalsSettingsPane today)
        applyGoalsSettingsOutMsg
        (\_ -> GoalsSettings.init)


diarySettingsDesired : InitContext -> DesiredPane
diarySettingsDesired context =
    fromInit context
        "diary-settings"
        DiarySettingsPane
        applyDiarySettingsOutMsg
        (\_ -> DiarySettings.init)


searchDesired : InitContext -> Maybe String -> Maybe MealSlot -> DesiredPane
searchDesired _ dateParam mealSlot =
    DesiredPane "food-search"
        (\_ ->
            ( FoodSearchPane (FoodSearch.init dateParam mealSlot)
            , initialFoodSearchCmd dateParam mealSlot
            , NoOutMsg
            )
        )


searchWorkspaceDesired :
    InitContext
    -> List Pane
    -> Maybe String
    -> Maybe MealSlot
    -> List DesiredPane
searchWorkspaceDesired context existing dateParam mealSlot =
    case ( context.today, dateParam |> Maybe.andThen LocalDate.fromString ) of
        ( Just today, Just _ ) ->
            contextualWorkspace
                existing
                [ diaryDesired context today dateParam Nothing ]
                (searchDesired context dateParam mealSlot)

        _ ->
            [ searchDesired context dateParam mealSlot ]


foodWorkspaceDesired :
    InitContext
    -> List Pane
    -> String
    -> Maybe String
    -> Maybe MealSlot
    -> Maybe String
    -> List DesiredPane
foodWorkspaceDesired context existing productId dateParam mealSlot lookupNote =
    let
        detail : DesiredPane
        detail =
            foodDetailDesired context productId dateParam mealSlot lookupNote
    in
    case ( context.today, dateParam |> Maybe.andThen LocalDate.fromString ) of
        ( Just today, Just _ ) ->
            contextualWorkspace
                existing
                [ diaryDesired context today dateParam Nothing ]
                detail

        _ ->
            contextualWorkspace existing [] detail


foodDetailDesired :
    InitContext
    -> String
    -> Maybe String
    -> Maybe MealSlot
    -> Maybe String
    -> DesiredPane
foodDetailDesired context productId dateParam mealSlot lookupNote =
    let
        contextKey : String
        contextKey =
            Maybe.withDefault "none" dateParam
                ++ ":"
                ++ Maybe.withDefault
                    "none"
                    (Maybe.map MealSlot.toString mealSlot)

        key : String
        key =
            "food-detail:"
                ++ productId
                ++ ":"
                ++ contextKey
                ++ Maybe.withDefault ""
                    (Maybe.map (\_ -> ":lookup") lookupNote)
    in
    fromInit context
        key
        (FoodDetailPane key)
        applyFoodDetailOutMsg
        (\_ -> FoodShow.init productId dateParam mealSlot lookupNote)


foodLogDetailDesired : InitContext -> String -> DesiredPane
foodLogDetailDesired context logId =
    fromInit context
        ("log-detail:" ++ logId)
        (FoodLogDetailPane logId)
        applyFoodLogDetailOutMsg
        (\_ -> FoodLogEntry.init logId)


createAdHocLogDesired : InitContext -> Maybe String -> Maybe MealSlot -> DesiredPane
createAdHocLogDesired _ dateParam mealSlot =
    simpleDesired
        "create-ad-hoc-log"
        (CreateAdHocLogPane (CreateAdHocLog.init dateParam mealSlot))


createWithAiLogDesired : InitContext -> Maybe String -> Maybe MealSlot -> DesiredPane
createWithAiLogDesired context dateParam mealSlot =
    fromInit context
        "create-ai-log"
        CreateWithAiLogPane
        applyCreateWithAiLogOutMsg
        (\_ -> CreateWithAiLog.init dateParam mealSlot)


preservePane : Pane -> DesiredPane
preservePane pane =
    simpleDesired (paneKey pane) pane


contextualWorkspace : List Pane -> List DesiredPane -> DesiredPane -> List DesiredPane
contextualWorkspace existing fallbackMain contextual =
    case List.head existing of
        Just pane ->
            if isMainPane pane then
                [ preservePane pane, contextual ]

            else
                fallbackMain ++ [ contextual ]

        Nothing ->
            fallbackMain ++ [ contextual ]


customFoodListDesired : InitContext -> DesiredPane
customFoodListDesired context =
    fromInit context
        "custom-food-list"
        CustomFoodListPane
        applyCustomFoodsOutMsg
        (\_ -> CustomFoodList.init)


customFoodCreatePaneDesired :
    InitContext
    -> ( CustomFoodCreate.Model, CustomFoodCreate.OutMsg )
    -> DesiredPane
customFoodCreatePaneDesired context createInit =
    fromInit context
        "custom-food-create"
        CustomFoodCreatePane
        applyCustomFoodCreateOutMsg
        (\_ -> createInit)


customFoodEditDesired : InitContext -> String -> DesiredPane
customFoodEditDesired context productId =
    fromInit context
        ("custom-food-edit:" ++ productId)
        (CustomFoodEditPane productId)
        applyCustomFoodEditOutMsg
        (\_ -> CustomFoodEdit.init productId)


customFoodShowDesired : InitContext -> String -> DesiredPane
customFoodShowDesired context productId =
    fromInit context
        ("custom-food-detail:" ++ productId)
        (CustomFoodShowPane productId)
        applyCustomFoodShowOutMsg
        (\_ -> CustomFoodShow.init productId)


mealListDesired : InitContext -> DesiredPane
mealListDesired context =
    fromInit context "meal-list" MealListPane applyMealsOutMsg (\_ -> MealList.init)


mealCreateDesired : InitContext -> DesiredPane
mealCreateDesired context =
    fromInit context "meal-create" MealCreatePane applyMealCreateOutMsg (\_ -> MealCreate.init)


mealEditDesired : InitContext -> String -> DesiredPane
mealEditDesired context mealId =
    fromInit context
        ("meal-edit:" ++ mealId)
        (MealEditPane mealId)
        applyMealEditOutMsg
        (\_ -> MealEdit.init mealId)


mealDetailDesired : InitContext -> String -> DesiredPane
mealDetailDesired context mealId =
    fromInit context
        ("meal-detail:" ++ mealId)
        (MealDetailPane mealId)
        applyMealDetailOutMsg
        (\_ -> MealShow.init mealId)


isMainPane : Pane -> Bool
isMainPane pane =
    case pane of
        DiaryPane _ _ ->
            True

        DiaryCalendarPane _ _ ->
            True

        FoodSearchPane _ ->
            True

        CustomFoodListPane _ ->
            True

        MealListPane _ ->
            True

        _ ->
            False


initialFoodSearchCmd : Maybe String -> Maybe MealSlot -> Cmd Msg
initialFoodSearchCmd dateParam mealSlot =
    case recentItemsRequest dateParam mealSlot of
        Just request ->
            Api.Logs.recentItems
                request
                (GotFoodSearchMsg
                    << FoodSearch.RecentItemsLoaded dateParam mealSlot
                )

        Nothing ->
            Cmd.none


preferOutMsg : OutMsg -> OutMsg -> OutMsg
preferOutMsg candidate current =
    case candidate of
        NoOutMsg ->
            current

        _ ->
            candidate



-- UPDATE


type alias UnitsResult =
    Result Api.Client.ApiError Api.Foods.UnitListResponse


type alias NutrientsResult =
    Result Api.Client.ApiError Api.Foods.NutrientListResponse


type alias PreferencesResult =
    Result Api.Client.ApiError Data.DiaryPreferences.DiaryPreferences


type alias DiaryLogsResult =
    Result Api.Client.ApiError (List Data.FoodLog.FoodLog)


type alias DiaryGoalResult =
    Result Api.Client.ApiError Data.Goals.GoalSnapshot


type alias LatestSlotsResult =
    Result Api.Client.ApiError Api.Logs.LatestSlotsResponse


type Msg
    = SharedUnitsLoaded Store.RequestToken UnitsResult
    | SharedNutrientsLoaded Store.RequestToken NutrientsResult
    | SharedPreferencesLoaded Store.RequestToken PreferencesResult
    | DiaryLogsStoreLoaded Store.RequestToken LocalDate DiaryLogsResult
    | DiaryGoalStoreLoaded Store.RequestToken LocalDate DiaryGoalResult
    | LatestSlotsStoreLoaded Store.RequestToken LocalDate LatestSlotsResult
    | GotLoginMsg AuthLogin.Msg
    | GotSetupMsg BootstrapSetup.Msg
    | GotAdminMsg AdminDashboard.Msg
    | GotAdminCreateUserMsg AdminCreateUser.Msg
    | GotAdminEditUserMsg AdminEditUser.Msg
    | GotDiaryMsg DiaryDay.Msg
    | GotDiaryCalendarMsg DiaryCalendar.Msg
    | GotNutritionDetailsMsg NutritionDetails.Msg
    | GotGoalsSettingsMsg GoalsSettings.Msg
    | GotDiarySettingsMsg DiarySettings.Msg
    | GotFoodSearchMsg FoodSearch.Msg
    | GotFoodDetailMsg FoodShow.Msg
    | GotFoodLogDetailMsg FoodLogEntry.Msg
    | GotCreateAdHocLogMsg CreateAdHocLog.Msg
    | GotCreateWithAiLogMsg CreateWithAiLog.Msg
    | GotCustomFoodCreateMsg CustomFoodCreate.Msg
    | GotCustomFoodEditMsg CustomFoodEdit.Msg
    | GotCustomFoodShowMsg CustomFoodShow.Msg
    | GotCustomFoodsMsg CustomFoodList.Msg
    | GotMealsMsg MealList.Msg
    | GotMealCreateMsg MealCreate.Msg
    | GotMealEditMsg MealEdit.Msg
    | GotMealDetailMsg MealShow.Msg


update : InitContext -> Msg -> Model -> Maybe ( Model, Cmd Msg, OutMsg )
update context msg model =
    let
        activeModel : Model
        activeModel =
            promoteContextualDiary msg model
    in
    case updateSharedMessage msg activeModel of
        Just result ->
            Just result

        Nothing ->
            updateFirst (updatePane activeModel.panes context msg) activeModel.panes
                |> Maybe.map
                    (\result ->
                        let
                            ( refreshedPanes, nextStore, refreshCmd ) =
                                applyMutation result.mutation result.pane activeModel.store
                        in
                        ( { activeModel
                            | panes = refreshedPanes
                            , store = nextStore
                          }
                        , Cmd.batch [ result.cmd, refreshCmd ]
                        , result.outMsg
                        )
                    )


promoteContextualDiary : Msg -> Model -> Model
promoteContextualDiary msg model =
    case ( isDiaryOperation msg, model.panes ) of
        ( True, (DiaryCalendarPane _ _) :: (DiaryPane paneId diary) :: _ ) ->
            { model
                | panes =
                    [ DiaryPane
                        { paneId | calendarMonth = Nothing }
                        (DiaryDay.asMain diary)
                    ]
            }

        _ ->
            model


isDiaryOperation : Msg -> Bool
isDiaryOperation msg =
    case msg of
        GotDiaryMsg subMsg ->
            case subMsg of
                DiaryDay.LogsLoaded _ _ ->
                    False

                DiaryDay.GoalLoaded _ _ ->
                    False

                DiaryDay.PreferencesLoaded _ ->
                    False

                DiaryDay.LatestSlotsReceived _ _ ->
                    False

                DiaryDay.CopyLatestCompleted _ _ ->
                    False

                DiaryDay.TodayChanged _ ->
                    False

                _ ->
                    True

        _ ->
            False


updateSharedMessage : Msg -> Model -> Maybe ( Model, Cmd Msg, OutMsg )
updateSharedMessage msg model =
    case msg of
        SharedUnitsLoaded token result ->
            Just (settleShared unitsResource token result model)

        SharedNutrientsLoaded token result ->
            Just (settleShared nutrientsResource token result model)

        SharedPreferencesLoaded token result ->
            Just (settleShared preferencesResource token result model)

        DiaryLogsStoreLoaded token date result ->
            Just (settleDate diaryLogsResource token date result model)

        DiaryGoalStoreLoaded token date result ->
            Just (settleDate diaryGoalResource token date result model)

        LatestSlotsStoreLoaded token date result ->
            Just (settleDate latestSlotsResource token date result model)

        _ ->
            Nothing


settleShared :
    SharedResource a
    -> Store.RequestToken
    -> Result Api.Client.ApiError a
    -> Model
    -> ( Model, Cmd Msg, OutMsg )
settleShared resource token result model =
    case Store.settle resource.access token result model.store of
        Nothing ->
            ( model, Cmd.none, NoOutMsg )

        Just store ->
            ( { model
                | store = store
                , panes = List.map (resource.hydrate result) model.panes
              }
            , Cmd.none
            , outMsgForResult result
            )


settleDate :
    DateResource a
    -> Store.RequestToken
    -> LocalDate
    -> Result Api.Client.ApiError a
    -> Model
    -> ( Model, Cmd Msg, OutMsg )
settleDate resource token date result model =
    case Store.settle (resource.access date) token result model.store of
        Nothing ->
            ( model, Cmd.none, NoOutMsg )

        Just store ->
            ( { model
                | store = store
                , panes = resource.apply date result model.panes
              }
            , Cmd.none
            , outMsgForResult result
            )


outMsgForResult : Result Api.Client.ApiError value -> OutMsg
outMsgForResult result =
    case result of
        Err error ->
            if Api.Client.isUnauthorized error then
                SessionExpired

            else
                NoOutMsg

        Ok _ ->
            NoOutMsg


updateDiaryPanes : LocalDate -> DiaryDay.Msg -> List Pane -> List Pane
updateDiaryPanes date msg panes =
    List.map
        (\pane ->
            case pane of
                DiaryPane paneId diary ->
                    if LocalDate.equals paneId.date date then
                        DiaryPane paneId (modelOnly (DiaryDay.update msg diary))

                    else
                        pane

                _ ->
                    pane
        )
        panes


updateGoalSettingsPanes : LocalDate -> DiaryGoalResult -> List Pane -> List Pane
updateGoalSettingsPanes date result panes =
    List.map
        (\pane ->
            case pane of
                GoalsSettingsPane paneDate goals ->
                    if LocalDate.equals paneDate date then
                        GoalsSettingsPane paneDate
                            (modelOnly
                                (GoalsSettings.update (GoalsSettings.GoalLoaded result) goals)
                            )

                    else
                        pane

                _ ->
                    pane
        )
        panes


type Mutation
    = NoMutation
    | RefreshDiaryAndCalendar LocalDate
    | RefreshCalendar LocalDate
    | RefreshGoals
    | PreferencesSaved Data.DiaryPreferences.DiaryPreferences


type alias PaneUpdate pane =
    { pane : pane
    , cmd : Cmd Msg
    , outMsg : OutMsg
    , mutation : Mutation
    }


messageMatchesPane : Maybe String -> Maybe String -> Bool
messageMatchesPane incoming current =
    case incoming of
        Nothing ->
            True

        Just incomingId ->
            current == Just incomingId


updateFirst :
    (pane -> Maybe (PaneUpdate pane))
    -> List pane
    -> Maybe (PaneUpdate (List pane))
updateFirst updateOne panes =
    case panes of
        [] ->
            Nothing

        pane :: rest ->
            case updateOne pane of
                Just result ->
                    Just
                        { pane = result.pane :: rest
                        , cmd = result.cmd
                        , outMsg = result.outMsg
                        , mutation = result.mutation
                        }

                Nothing ->
                    updateFirst updateOne rest
                        |> Maybe.map
                            (\result ->
                                { pane = pane :: result.pane
                                , cmd = result.cmd
                                , outMsg = result.outMsg
                                , mutation = result.mutation
                                }
                            )


updatePane : List Pane -> InitContext -> Msg -> Pane -> Maybe (PaneUpdate Pane)
updatePane allPanes context msg pane =
    case ( msg, pane ) of
        ( GotLoginMsg subMsg, LoginPane sub ) ->
            stepPane context
                LoginPane
                GotLoginMsg
                applyLoginOutMsg
                NoMutation
                (AuthLogin.update subMsg sub)

        ( GotSetupMsg subMsg, SetupPane sub ) ->
            stepPane context
                SetupPane
                GotSetupMsg
                applySetupOutMsg
                NoMutation
                (BootstrapSetup.update subMsg sub)

        ( GotAdminMsg subMsg, AdminPane sub ) ->
            stepPane context
                AdminPane
                GotAdminMsg
                applyAdminOutMsg
                NoMutation
                (AdminDashboard.update subMsg sub)

        ( GotAdminCreateUserMsg subMsg, AdminCreateUserPane sub ) ->
            stepPane context
                AdminCreateUserPane
                GotAdminCreateUserMsg
                applyAdminCreateUserOutMsg
                NoMutation
                (AdminCreateUser.update subMsg sub)

        ( GotAdminEditUserMsg subMsg, AdminEditUserPane userId sub ) ->
            stepPane context
                (AdminEditUserPane userId)
                GotAdminEditUserMsg
                applyAdminEditUserOutMsg
                NoMutation
                (AdminEditUser.update subMsg sub)

        ( GotDiaryMsg subMsg, DiaryPane paneId sub ) ->
            let
                result : ( DiaryDay.Model, Cmd DiaryDay.Msg, DiaryDay.OutMsg )
                result =
                    DiaryDay.update subMsg sub

                mutation : Mutation
                mutation =
                    case third result of
                        DiaryDay.LogsCopied date DiaryDay.DiaryUpdated ->
                            RefreshCalendar date

                        DiaryDay.LogsCopied date DiaryDay.DiaryNeedsReload ->
                            RefreshDiaryAndCalendar date

                        _ ->
                            NoMutation
            in
            stepPane context (DiaryPane paneId) GotDiaryMsg applyDiaryOutMsg mutation result

        ( GotDiaryCalendarMsg subMsg, DiaryCalendarPane month sub ) ->
            stepPane context
                (DiaryCalendarPane month)
                GotDiaryCalendarMsg
                applyDiaryCalendarOutMsg
                NoMutation
                (DiaryCalendar.update subMsg sub)

        ( GotNutritionDetailsMsg subMsg, NutritionDetailsPane date sub ) ->
            stepPane context
                (NutritionDetailsPane date)
                GotNutritionDetailsMsg
                applyNutritionDetailsOutMsg
                NoMutation
                (NutritionDetails.update subMsg sub)

        ( GotGoalsSettingsMsg subMsg, GoalsSettingsPane date sub ) ->
            let
                mutation : Mutation
                mutation =
                    case subMsg of
                        GoalsSettings.SaveCompleted (Ok _) ->
                            RefreshGoals

                        _ ->
                            NoMutation
            in
            stepPane context
                (GoalsSettingsPane date)
                GotGoalsSettingsMsg
                applyGoalsSettingsOutMsg
                mutation
                (GoalsSettings.update subMsg sub)

        ( GotDiarySettingsMsg subMsg, DiarySettingsPane sub ) ->
            let
                mutation : Mutation
                mutation =
                    case subMsg of
                        DiarySettings.SaveCompleted (Ok preferences) ->
                            PreferencesSaved preferences

                        _ ->
                            NoMutation
            in
            stepPane context
                DiarySettingsPane
                GotDiarySettingsMsg
                applyDiarySettingsOutMsg
                mutation
                (DiarySettings.update subMsg sub)

        ( GotFoodSearchMsg subMsg, FoodSearchPane sub ) ->
            let
                result : ( FoodSearch.Model, Cmd FoodSearch.Msg, FoodSearch.OutMsg )
                result =
                    FoodSearch.update subMsg sub

                mutation : Mutation
                mutation =
                    case third result of
                        FoodSearch.LogCreated log ->
                            RefreshDiaryAndCalendar log.logDate

                        _ ->
                            NoMutation
            in
            stepPane context FoodSearchPane GotFoodSearchMsg applyFoodSearchOutMsg mutation result

        ( GotFoodDetailMsg subMsg, FoodDetailPane key sub ) ->
            if not (messageMatchesPane (FoodShow.loadId subMsg) (FoodShow.modelId sub)) then
                Nothing

            else
                let
                    result : ( FoodShow.Model, Cmd FoodShow.Msg, FoodShow.OutMsg )
                    result =
                        FoodShow.update subMsg sub

                    mutation : Mutation
                    mutation =
                        case third result of
                            FoodShow.LogCreated log _ ->
                                RefreshDiaryAndCalendar log.logDate

                            _ ->
                                NoMutation
                in
                stepPane context
                    (FoodDetailPane key)
                    GotFoodDetailMsg
                    applyFoodDetailOutMsg
                    mutation
                    result

        ( GotFoodLogDetailMsg subMsg, FoodLogDetailPane logId sub ) ->
            if not (messageMatchesPane (FoodLogEntry.loadId subMsg) (FoodLogEntry.modelId sub)) then
                Nothing

            else
                let
                    result : ( FoodLogEntry.Model, Cmd FoodLogEntry.Msg, FoodLogEntry.OutMsg )
                    result =
                        FoodLogEntry.update subMsg sub

                    mutation : Mutation
                    mutation =
                        case third result of
                            FoodLogEntry.LogUpdated date ->
                                RefreshDiaryAndCalendar date

                            FoodLogEntry.LogDeleted date _ ->
                                RefreshDiaryAndCalendar date

                            _ ->
                                NoMutation
                in
                stepPane context
                    (FoodLogDetailPane logId)
                    GotFoodLogDetailMsg
                    applyFoodLogDetailOutMsg
                    mutation
                    result

        ( GotCreateAdHocLogMsg subMsg, CreateAdHocLogPane sub ) ->
            let
                result : ( CreateAdHocLog.Model, Cmd CreateAdHocLog.Msg, CreateAdHocLog.OutMsg )
                result =
                    CreateAdHocLog.update subMsg sub

                mutation : Mutation
                mutation =
                    case third result of
                        CreateAdHocLog.LogCreated log ->
                            RefreshDiaryAndCalendar log.logDate

                        _ ->
                            NoMutation
            in
            stepPane context
                CreateAdHocLogPane
                GotCreateAdHocLogMsg
                applyCreateAdHocLogOutMsg
                mutation
                result

        ( GotCreateWithAiLogMsg subMsg, CreateWithAiLogPane sub ) ->
            let
                result :
                    ( CreateWithAiLog.Model
                    , Cmd CreateWithAiLog.Msg
                    , CreateWithAiLog.OutMsg
                    )
                result =
                    CreateWithAiLog.update subMsg sub

                mutation : Mutation
                mutation =
                    case third result of
                        CreateWithAiLog.LogCreated log ->
                            RefreshDiaryAndCalendar log.logDate

                        _ ->
                            NoMutation
            in
            stepPane context
                CreateWithAiLogPane
                GotCreateWithAiLogMsg
                applyCreateWithAiLogOutMsg
                mutation
                result

        ( GotCustomFoodCreateMsg subMsg, CustomFoodCreatePane sub ) ->
            stepPane context
                CustomFoodCreatePane
                GotCustomFoodCreateMsg
                (applyCustomFoodCreateOutMsgForPanes allPanes)
                NoMutation
                (CustomFoodCreate.update subMsg sub)

        ( GotCustomFoodEditMsg subMsg, CustomFoodEditPane productId sub ) ->
            let
                matches : Bool
                matches =
                    messageMatchesPane
                        (CustomFoodEdit.loadId subMsg)
                        (CustomFoodEdit.modelId sub)
            in
            if not matches then
                Nothing

            else
                stepPane context
                    (CustomFoodEditPane productId)
                    GotCustomFoodEditMsg
                    applyCustomFoodEditOutMsg
                    NoMutation
                    (CustomFoodEdit.update subMsg sub)

        ( GotCustomFoodShowMsg subMsg, CustomFoodShowPane productId sub ) ->
            let
                matches : Bool
                matches =
                    messageMatchesPane
                        (CustomFoodShow.loadId subMsg)
                        (CustomFoodShow.modelId sub)
            in
            if not matches then
                Nothing

            else
                stepPane context
                    (CustomFoodShowPane productId)
                    GotCustomFoodShowMsg
                    applyCustomFoodShowOutMsg
                    NoMutation
                    (CustomFoodShow.update subMsg sub)

        ( GotCustomFoodsMsg subMsg, CustomFoodListPane sub ) ->
            stepPane context
                CustomFoodListPane
                GotCustomFoodsMsg
                applyCustomFoodsOutMsg
                NoMutation
                (CustomFoodList.update subMsg sub)

        ( GotMealsMsg subMsg, MealListPane sub ) ->
            stepPane context
                MealListPane
                GotMealsMsg
                applyMealsOutMsg
                NoMutation
                (MealList.update subMsg sub)

        ( GotMealCreateMsg subMsg, MealCreatePane sub ) ->
            stepPane context
                MealCreatePane
                GotMealCreateMsg
                applyMealCreateOutMsg
                NoMutation
                (MealCreate.update subMsg sub)

        ( GotMealEditMsg subMsg, MealEditPane mealId sub ) ->
            if not (messageMatchesPane (MealEdit.loadId subMsg) (MealEdit.modelId sub)) then
                Nothing

            else
                stepPane context
                    (MealEditPane mealId)
                    GotMealEditMsg
                    applyMealEditOutMsg
                    NoMutation
                    (MealEdit.update subMsg sub)

        ( GotMealDetailMsg subMsg, MealDetailPane mealId sub ) ->
            if not (messageMatchesPane (MealShow.loadId subMsg) (MealShow.modelId sub)) then
                Nothing

            else
                stepPane context
                    (MealDetailPane mealId)
                    GotMealDetailMsg
                    applyMealDetailOutMsg
                    NoMutation
                    (MealShow.update subMsg sub)

        _ ->
            Nothing


stepPane :
    InitContext
    -> (subModel -> Pane)
    -> (subMsg -> Msg)
    -> (InitContext -> outMsg -> ( Cmd Msg, OutMsg ))
    -> Mutation
    -> ( subModel, Cmd subMsg, outMsg )
    -> Maybe (PaneUpdate Pane)
stepPane context toPane toMsg applyOut mutation ( subModel, subCmd, subOut ) =
    let
        ( outCmd, outMsg ) =
            applyOut context subOut
    in
    Just
        { pane = toPane subModel
        , cmd = Cmd.batch [ Cmd.map toMsg subCmd, outCmd ]
        , outMsg = outMsg
        , mutation = mutation
        }


applyMutation : Mutation -> List Pane -> Store -> ( List Pane, Store, Cmd Msg )
applyMutation mutation panes store =
    case mutation of
        NoMutation ->
            ( panes, store, Cmd.none )

        RefreshDiaryAndCalendar date ->
            refreshAfterLogMutation True date panes store

        RefreshCalendar date ->
            refreshAfterLogMutation False date panes store

        PreferencesSaved preferences ->
            ( panes, Store.seed Store.preferences preferences store, Cmd.none )

        RefreshGoals ->
            let
                ( nextStore, cmd ) =
                    ensureDateData panes (Store.clearGoals store)
            in
            ( panes, nextStore, cmd )


{-| Suggestions for every date are dropped, not just this one: the lookback
window reaches back `latestSlotsLookbackDays`, so the changed date may be the
source of any date's suggestions.
-}
refreshAfterLogMutation :
    Bool
    -> LocalDate
    -> List Pane
    -> Store
    -> ( List Pane, Store, Cmd Msg )
refreshAfterLogMutation reloadDiary date panes store =
    let
        access : Store.Access (List Data.FoodLog.FoodLog)
        access =
            Store.diaryLogsAt date

        appliedLogs : Maybe (List Data.FoodLog.FoodLog)
        appliedLogs =
            if reloadDiary then
                Nothing

            else
                diaryPaneLogs date panes

        invalidated : Store
        invalidated =
            Store.clearLatestSlots
                (case appliedLogs of
                    Just logs ->
                        Store.seed access logs store

                    Nothing ->
                        Store.invalidate access store
                )

        refreshedPanes : List Pane
        refreshedPanes =
            case appliedLogs of
                Just logs ->
                    applyDayTotals date logs panes

                Nothing ->
                    panes

        ( nextStore, dateCmd ) =
            ensureDateData refreshedPanes invalidated
    in
    ( refreshedPanes, nextStore, dateCmd )


diaryPaneLogs : LocalDate -> List Pane -> Maybe (List Data.FoodLog.FoodLog)
diaryPaneLogs date panes =
    panes
        |> List.filterMap
            (\pane ->
                case pane of
                    DiaryPane paneId diary ->
                        if LocalDate.equals paneId.date date then
                            DiaryDay.currentLogs diary

                        else
                            Nothing

                    _ ->
                        Nothing
            )
        |> List.head


applyDayTotals : LocalDate -> List Data.FoodLog.FoodLog -> List Pane -> List Pane
applyDayTotals date logs panes =
    let
        msg : DiaryCalendar.Msg
        msg =
            DiaryCalendar.DayTotalsKnown date (LogSummary.fromLogs date logs)
    in
    List.map
        (\pane ->
            case pane of
                DiaryCalendarPane month calendar ->
                    DiaryCalendarPane month (modelOnly (DiaryCalendar.update msg calendar))

                _ ->
                    pane
        )
        panes


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value


localContextReceived :
    InitContext
    -> LocalContext
    -> Model
    -> Maybe ( Model, Cmd Msg, OutMsg )
localContextReceived pageContext context model =
    updateAll
        (\pane ->
            case pane of
                FoodDetailPane _ _ ->
                    updatePane model.panes
                        pageContext
                        (GotFoodDetailMsg (FoodShow.LocalContextReceived context))
                        pane

                FoodSearchPane _ ->
                    updatePane model.panes
                        pageContext
                        (GotFoodSearchMsg (FoodSearch.LocalContextReceived context))
                        pane

                CreateAdHocLogPane _ ->
                    updatePane model.panes
                        pageContext
                        (GotCreateAdHocLogMsg (CreateAdHocLog.LocalContextReceived context))
                        pane

                CreateWithAiLogPane _ ->
                    updatePane model.panes
                        pageContext
                        (GotCreateWithAiLogMsg
                            (CreateWithAiLog.ReviewMsg
                                (CreateAdHocLog.LocalContextReceived context)
                            )
                        )
                        pane

                GoalsSettingsPane _ _ ->
                    updatePane model.panes
                        pageContext
                        (GotGoalsSettingsMsg (GoalsSettings.LocalContextReceived context))
                        pane

                DiaryPane _ _ ->
                    todayChangedIn pageContext
                        model
                        context
                        pane
                        (GotDiaryMsg << DiaryDay.TodayChanged)

                DiaryCalendarPane _ _ ->
                    todayChangedIn pageContext
                        model
                        context
                        pane
                        (GotDiaryCalendarMsg << DiaryCalendar.TodayChanged)

                NutritionDetailsPane _ _ ->
                    todayChangedIn pageContext
                        model
                        context
                        pane
                        (GotNutritionDetailsMsg << NutritionDetails.TodayChanged)

                _ ->
                    Nothing
        )
        model


{-| The browser is the only thing that knows the day has rolled over under a tab
left open overnight, so the panes that clamp navigation against "today" take it
from the same context the save paths already ask for.
-}
todayChangedIn :
    InitContext
    -> Model
    -> LocalContext
    -> Pane
    -> (LocalDate -> Msg)
    -> Maybe (PaneUpdate Pane)
todayChangedIn pageContext model context pane toMsg =
    LocalDate.fromString context.date
        |> Maybe.andThen (\today -> updatePane model.panes pageContext (toMsg today) pane)


barcodeScannerEventReceived :
    InitContext
    -> ScannerEvent
    -> Model
    -> Maybe ( Model, Cmd Msg, OutMsg )
barcodeScannerEventReceived pageContext event model =
    updateAll
        (\pane ->
            case pane of
                FoodSearchPane _ ->
                    updatePane model.panes
                        pageContext
                        (GotFoodSearchMsg (FoodSearch.BarcodeScannerEventReceived event))
                        pane

                _ ->
                    Nothing
        )
        model


type alias UpdateAllResult =
    { panes : List Pane
    , cmds : List (Cmd Msg)
    , outMsg : OutMsg
    , didUpdate : Bool
    , store : Store
    }


updateAll :
    (Pane -> Maybe (PaneUpdate Pane))
    -> Model
    -> Maybe ( Model, Cmd Msg, OutMsg )
updateAll updateOne model =
    let
        step : Pane -> UpdateAllResult -> UpdateAllResult
        step pane result =
            case updateOne pane of
                Just paneResult ->
                    let
                        ( refreshed, nextStore, refreshCmd ) =
                            applyMutation paneResult.mutation
                                [ paneResult.pane ]
                                result.store
                    in
                    { panes = refreshed ++ result.panes
                    , cmds = Cmd.batch [ paneResult.cmd, refreshCmd ] :: result.cmds
                    , outMsg = preferOutMsg paneResult.outMsg result.outMsg
                    , didUpdate = True
                    , store = nextStore
                    }

                Nothing ->
                    { result | panes = pane :: result.panes }

        final : UpdateAllResult
        final =
            List.foldl step
                { panes = []
                , cmds = []
                , outMsg = NoOutMsg
                , didUpdate = False
                , store = model.store
                }
                model.panes
    in
    if final.didUpdate then
        Just
            ( { model
                | panes = List.reverse final.panes
                , store = final.store
              }
            , Cmd.batch (List.reverse final.cmds)
            , final.outMsg
            )

    else
        Nothing


applyLoginOutMsg : InitContext -> AuthLogin.OutMsg -> ( Cmd Msg, OutMsg )
applyLoginOutMsg _ outMsg =
    case outMsg of
        AuthLogin.NoOp ->
            ( Cmd.none, NoOutMsg )

        AuthLogin.RequestLogin request ->
            ( Api.Auth.login request (GotLoginMsg << AuthLogin.LoginCompleted)
            , NoOutMsg
            )

        AuthLogin.LoginSucceeded loginSession ->
            ( Cmd.none, LoginSucceeded loginSession )


applySetupOutMsg : InitContext -> BootstrapSetup.OutMsg -> ( Cmd Msg, OutMsg )
applySetupOutMsg _ outMsg =
    case outMsg of
        BootstrapSetup.NoOp ->
            ( Cmd.none, NoOutMsg )

        BootstrapSetup.RequestCreateAdmin request ->
            ( Api.Auth.createAdmin request
                (GotSetupMsg << BootstrapSetup.CreateAdminCompleted)
            , NoOutMsg
            )

        BootstrapSetup.CreateAdminSucceeded loginSession ->
            ( Cmd.none, SetupSucceeded loginSession )


applyAdminOutMsg : InitContext -> AdminDashboard.OutMsg -> ( Cmd Msg, OutMsg )
applyAdminOutMsg _ outMsg =
    case outMsg of
        AdminDashboard.NoOp ->
            ( Cmd.none, NoOutMsg )

        AdminDashboard.RequestUsers ->
            ( Api.Admin.listUsers (GotAdminMsg << AdminDashboard.UsersLoaded)
            , NoOutMsg
            )

        AdminDashboard.Navigate route ->
            ( Cmd.none, Navigate route )

        AdminDashboard.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyAdminCreateUserOutMsg : InitContext -> AdminCreateUser.OutMsg -> ( Cmd Msg, OutMsg )
applyAdminCreateUserOutMsg _ outMsg =
    case outMsg of
        AdminCreateUser.NoOp ->
            ( Cmd.none, NoOutMsg )

        AdminCreateUser.RequestCreateUser request ->
            ( Api.Admin.createUser request
                (GotAdminCreateUserMsg << AdminCreateUser.Completed)
            , NoOutMsg
            )

        AdminCreateUser.CreateSucceeded ->
            ( Cmd.none, Navigate AdminDashboard )

        AdminCreateUser.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyAdminEditUserOutMsg : InitContext -> AdminEditUser.OutMsg -> ( Cmd Msg, OutMsg )
applyAdminEditUserOutMsg _ outMsg =
    case outMsg of
        AdminEditUser.NoOp ->
            ( Cmd.none, NoOutMsg )

        AdminEditUser.RequestUser userId ->
            ( Api.Admin.getUser userId (GotAdminEditUserMsg << AdminEditUser.UserLoaded)
            , NoOutMsg
            )

        AdminEditUser.RequestResetPassword userId request ->
            ( Api.Admin.resetPassword
                userId
                request
                (GotAdminEditUserMsg << AdminEditUser.ResetCompleted)
            , NoOutMsg
            )

        AdminEditUser.RequestDisableUser userId ->
            ( Api.Admin.disableUser userId
                (GotAdminEditUserMsg << AdminEditUser.DisableCompleted)
            , NoOutMsg
            )

        AdminEditUser.RequestEnableUser userId ->
            ( Api.Admin.enableUser userId
                (GotAdminEditUserMsg << AdminEditUser.EnableCompleted)
            , NoOutMsg
            )

        AdminEditUser.UpdateSucceeded ->
            ( Cmd.none, Navigate AdminDashboard )

        AdminEditUser.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyDiaryOutMsg : InitContext -> DiaryDay.OutMsg -> ( Cmd Msg, OutMsg )
applyDiaryOutMsg _ outMsg =
    case outMsg of
        DiaryDay.NoOp ->
            ( Cmd.none, NoOutMsg )

        DiaryDay.RequestDiaryData ->
            ( Cmd.none, NoOutMsg )

        DiaryDay.RequestCopyLatestSlot date requests ->
            ( Api.Logs.createLogsBatch
                requests
                (GotDiaryMsg << DiaryDay.CopyLatestCompleted date)
            , NoOutMsg
            )

        DiaryDay.LogsCopied _ refresh ->
            case refresh of
                DiaryDay.DiaryUpdated ->
                    ( Cmd.none, NoOutMsg )

                DiaryDay.DiaryNeedsReload ->
                    ( Cmd.none, NoOutMsg )

        DiaryDay.Navigate route ->
            ( Cmd.none, Navigate route )

        DiaryDay.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyDiaryCalendarOutMsg :
    InitContext
    -> DiaryCalendar.OutMsg
    -> ( Cmd Msg, OutMsg )
applyDiaryCalendarOutMsg _ outMsg =
    case outMsg of
        DiaryCalendar.NoOp ->
            ( Cmd.none, NoOutMsg )

        DiaryCalendar.RequestSummary token fromDate toDate ->
            ( Api.Logs.summary
                { fromDate = fromDate
                , toDate = toDate
                }
                (GotDiaryCalendarMsg << DiaryCalendar.SummaryLoaded token)
            , NoOutMsg
            )

        DiaryCalendar.RequestEarlierSummary token fromDate toDate ->
            ( Api.Logs.summary
                { fromDate = fromDate
                , toDate = toDate
                }
                (GotDiaryCalendarMsg << DiaryCalendar.EarlierSummaryLoaded token)
            , NoOutMsg
            )

        DiaryCalendar.Navigate route ->
            ( Cmd.none, Navigate route )

        DiaryCalendar.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyNutritionDetailsOutMsg : InitContext -> NutritionDetails.OutMsg -> ( Cmd Msg, OutMsg )
applyNutritionDetailsOutMsg _ outMsg =
    case outMsg of
        NutritionDetails.NoOp ->
            ( Cmd.none, NoOutMsg )

        NutritionDetails.RequestNutritionDetails date ->
            ( Api.NutritionDetails.get
                date
                (GotNutritionDetailsMsg << NutritionDetails.NutritionDetailsLoaded date)
            , NoOutMsg
            )

        NutritionDetails.Navigate route ->
            ( Cmd.none, Navigate route )

        NutritionDetails.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyDiarySettingsOutMsg : InitContext -> DiarySettings.OutMsg -> ( Cmd Msg, OutMsg )
applyDiarySettingsOutMsg _ outMsg =
    case outMsg of
        DiarySettings.NoOp ->
            ( Cmd.none, NoOutMsg )

        DiarySettings.RequestPreferences ->
            ( Cmd.none, NoOutMsg )

        DiarySettings.RequestSave preferences ->
            ( Api.DiaryPreferences.put preferences
                (GotDiarySettingsMsg << DiarySettings.SaveCompleted)
            , NoOutMsg
            )

        DiarySettings.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyGoalsSettingsOutMsg : InitContext -> GoalsSettings.OutMsg -> ( Cmd Msg, OutMsg )
applyGoalsSettingsOutMsg _ outMsg =
    case outMsg of
        GoalsSettings.NoOp ->
            ( Cmd.none, NoOutMsg )

        GoalsSettings.RequestGoal ->
            ( Cmd.none, NoOutMsg )

        GoalsSettings.RequestLocalContext ->
            ( Cmd.none, RequestLocalContext )

        GoalsSettings.RequestSaveGoal request ->
            ( Api.Goals.saveGoal request
                (GotGoalsSettingsMsg << GoalsSettings.SaveCompleted)
            , NoOutMsg
            )

        GoalsSettings.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyFoodSearchOutMsg : InitContext -> FoodSearch.OutMsg -> ( Cmd Msg, OutMsg )
applyFoodSearchOutMsg _ outMsg =
    case outMsg of
        FoodSearch.NoOp ->
            ( Cmd.none, NoOutMsg )

        FoodSearch.RequestSearch token request ->
            ( Api.Foods.searchFoods request
                (GotFoodSearchMsg << FoodSearch.SearchCompleted token)
            , NoOutMsg
            )

        FoodSearch.RequestBarcodeScanStopAndSearch token request ->
            ( Api.Foods.searchFoods request
                (GotFoodSearchMsg << FoodSearch.SearchCompleted token)
            , RequestBarcodeScanStop
            )

        FoodSearch.RequestBarcodeLookup token barcode ->
            ( Api.Foods.lookupBarcode barcode
                (GotFoodSearchMsg << FoodSearch.BarcodeLookupCompleted token)
            , NoOutMsg
            )

        FoodSearch.RequestCategorySuggestions token request ->
            ( Api.Foods.listCategorySuggestions request
                (GotFoodSearchMsg << FoodSearch.CategorySuggestionsCompleted token)
            , NoOutMsg
            )

        FoodSearch.RequestLocalContext ->
            ( Cmd.none, RequestLocalContext )

        FoodSearch.RequestBarcodeScanStart ->
            ( Cmd.none, RequestBarcodeScanStart )

        FoodSearch.RequestBarcodeScanStop ->
            ( Cmd.none, RequestBarcodeScanStop )

        FoodSearch.RequestCreateLog request ->
            ( Api.Logs.createLog request
                (GotFoodSearchMsg << FoodSearch.QuickAddCompleted)
            , NoOutMsg
            )

        FoodSearch.LogCreated _ ->
            ( Cmd.none, NoOutMsg )

        FoodSearch.Navigate route ->
            ( Cmd.none, Navigate route )

        FoodSearch.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyFoodDetailOutMsg : InitContext -> FoodShow.OutMsg -> ( Cmd Msg, OutMsg )
applyFoodDetailOutMsg context outMsg =
    case outMsg of
        FoodShow.NoOp ->
            ( Cmd.none, NoOutMsg )

        FoodShow.RequestInitialData productId ->
            ( Cmd.batch
                (Api.Foods.getFoodDetail productId
                    (GotFoodDetailMsg << FoodShow.FoodLoaded productId)
                    :: lastUsedProductDefaultCmd context.route productId
                )
            , NoOutMsg
            )

        FoodShow.RequestLocalContext ->
            ( Cmd.none, RequestLocalContext )

        FoodShow.RequestCreateLog request ->
            ( Api.Logs.createLog request (GotFoodDetailMsg << FoodShow.LogCompleted)
            , NoOutMsg
            )

        FoodShow.LogCreated _ route ->
            ( Cmd.none, Navigate route )

        FoodShow.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyCreateAdHocLogOutMsg :
    InitContext
    -> CreateAdHocLog.OutMsg
    -> ( Cmd Msg, OutMsg )
applyCreateAdHocLogOutMsg _ outMsg =
    case outMsg of
        CreateAdHocLog.NoOp ->
            ( Cmd.none, NoOutMsg )

        CreateAdHocLog.RequestLocalContext ->
            ( Cmd.none, RequestLocalContext )

        CreateAdHocLog.RequestAdHocLog request ->
            ( Api.Logs.createAdHocLog request
                (GotCreateAdHocLogMsg << CreateAdHocLog.AdHocLogCompleted)
            , NoOutMsg
            )

        CreateAdHocLog.RequestCreateFood request ->
            ( Api.Foods.createCustomFood request
                (GotCreateAdHocLogMsg << CreateAdHocLog.CustomFoodCompleted)
            , NoOutMsg
            )

        CreateAdHocLog.RequestCategorySuggestions token request ->
            ( Api.Foods.listCategorySuggestions request
                (GotCreateAdHocLogMsg
                    << CreateAdHocLog.CategorySuggestionsLoaded token
                )
            , NoOutMsg
            )

        CreateAdHocLog.RequestProductLog request ->
            ( Api.Logs.createLog request
                (GotCreateAdHocLogMsg << CreateAdHocLog.ProductLogCompleted)
            , NoOutMsg
            )

        CreateAdHocLog.LogCreated log ->
            ( Cmd.none
            , Navigate (DiaryDay (Just (LocalDate.format log.logDate)) Nothing)
            )

        CreateAdHocLog.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyCreateWithAiLogOutMsg :
    InitContext
    -> CreateWithAiLog.OutMsg
    -> ( Cmd Msg, OutMsg )
applyCreateWithAiLogOutMsg _ outMsg =
    case outMsg of
        CreateWithAiLog.NoOp ->
            ( Cmd.none, NoOutMsg )

        CreateWithAiLog.RequestAssistantStatus ->
            ( Api.FoodAssistant.getStatus
                (GotCreateWithAiLogMsg
                    << CreateWithAiLog.AssistantMsg
                    << FoodAssistantUi.StatusLoaded
                )
            , NoOutMsg
            )

        CreateWithAiLog.RequestFoodDraft purpose conversation photos ->
            ( Api.FoodAssistant.requestDraft purpose
                conversation
                photos
                (GotCreateWithAiLogMsg
                    << CreateWithAiLog.AssistantMsg
                    << FoodAssistantUi.DraftCompleted
                )
            , NoOutMsg
            )

        CreateWithAiLog.RevokePhotoPreviewUrls urls ->
            ( Cmd.none, RevokePhotoPreviewUrls urls )

        CreateWithAiLog.RequestLocalContext ->
            ( Cmd.none, RequestLocalContext )

        CreateWithAiLog.RequestAdHocLog request ->
            ( Api.Logs.createAdHocLog request
                (GotCreateWithAiLogMsg
                    << CreateWithAiLog.ReviewMsg
                    << CreateAdHocLog.AdHocLogCompleted
                )
            , NoOutMsg
            )

        CreateWithAiLog.RequestCreateFood request ->
            ( Api.Foods.createCustomFood request
                (GotCreateWithAiLogMsg
                    << CreateWithAiLog.ReviewMsg
                    << CreateAdHocLog.CustomFoodCompleted
                )
            , NoOutMsg
            )

        CreateWithAiLog.RequestCategorySuggestions token request ->
            ( Api.Foods.listCategorySuggestions request
                (GotCreateWithAiLogMsg
                    << CreateWithAiLog.ReviewMsg
                    << CreateAdHocLog.CategorySuggestionsLoaded token
                )
            , NoOutMsg
            )

        CreateWithAiLog.RequestProductLog request ->
            ( Api.Logs.createLog request
                (GotCreateWithAiLogMsg
                    << CreateWithAiLog.ReviewMsg
                    << CreateAdHocLog.ProductLogCompleted
                )
            , NoOutMsg
            )

        CreateWithAiLog.LogCreated log ->
            ( Cmd.none
            , Navigate (DiaryDay (Just (LocalDate.format log.logDate)) Nothing)
            )

        CreateWithAiLog.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyFoodLogDetailOutMsg : InitContext -> FoodLogEntry.OutMsg -> ( Cmd Msg, OutMsg )
applyFoodLogDetailOutMsg context outMsg =
    case outMsg of
        FoodLogEntry.NoOp ->
            ( Cmd.none, NoOutMsg )

        FoodLogEntry.RequestInitialData logId ->
            ( Api.Logs.getLog logId
                (GotFoodLogDetailMsg << FoodLogEntry.LogLoaded logId)
            , NoOutMsg
            )

        FoodLogEntry.RequestProductDetail productId ->
            ( Api.Foods.getFoodDetail productId
                (GotFoodLogDetailMsg << FoodLogEntry.ProductDetailLoaded)
            , NoOutMsg
            )

        FoodLogEntry.RequestUpdateLog logId request ->
            ( Api.Logs.updateLog logId
                request
                (GotFoodLogDetailMsg << FoodLogEntry.UpdateCompleted)
            , NoOutMsg
            )

        FoodLogEntry.RequestDeleteLog logId ->
            ( Api.Logs.deleteLog logId
                (GotFoodLogDetailMsg << FoodLogEntry.DeleteCompleted)
            , NoOutMsg
            )

        FoodLogEntry.LogUpdated _ ->
            ( Cmd.none, NoOutMsg )

        FoodLogEntry.LogDeleted date route ->
            ( Cmd.none
            , Navigate
                (case context.route of
                    FoodLogEntry _ _ calendarMonth ->
                        DiaryDay (Just (LocalDate.format date)) calendarMonth

                    _ ->
                        route
                )
            )

        FoodLogEntry.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyCustomFoodCreateOutMsg :
    InitContext
    -> CustomFoodCreate.OutMsg
    -> ( Cmd Msg, OutMsg )
applyCustomFoodCreateOutMsg _ outMsg =
    case outMsg of
        CustomFoodCreate.NoOp ->
            ( Cmd.none, NoOutMsg )

        CustomFoodCreate.RequestInitialData ->
            ( Api.FoodAssistant.getStatus
                (GotCustomFoodCreateMsg
                    << CustomFoodCreate.AssistantMsg
                    << FoodAssistantUi.StatusLoaded
                )
            , NoOutMsg
            )

        CustomFoodCreate.RequestCreateFood request ->
            ( Api.Foods.createCustomFood request
                (GotCustomFoodCreateMsg << CustomFoodCreate.SaveCompleted)
            , NoOutMsg
            )

        CustomFoodCreate.RequestCategorySuggestions token request ->
            ( Api.Foods.listCategorySuggestions request
                (GotCustomFoodCreateMsg << CustomFoodCreate.CategorySuggestionsLoaded token)
            , NoOutMsg
            )

        CustomFoodCreate.RequestAssistantStatus ->
            ( Api.FoodAssistant.getStatus
                (GotCustomFoodCreateMsg
                    << CustomFoodCreate.AssistantMsg
                    << FoodAssistantUi.StatusLoaded
                )
            , NoOutMsg
            )

        CustomFoodCreate.RequestFoodDraft purpose conversation photos ->
            ( Api.FoodAssistant.requestDraft purpose
                conversation
                photos
                (GotCustomFoodCreateMsg
                    << CustomFoodCreate.AssistantMsg
                    << FoodAssistantUi.DraftCompleted
                )
            , NoOutMsg
            )

        CustomFoodCreate.RevokePhotoPreviewUrls urls ->
            ( Cmd.none, RevokePhotoPreviewUrls urls )

        CustomFoodCreate.Navigate route ->
            ( Cmd.none, Navigate route )

        CustomFoodCreate.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyCustomFoodCreateOutMsgForPanes :
    List Pane
    -> InitContext
    -> CustomFoodCreate.OutMsg
    -> ( Cmd Msg, OutMsg )
applyCustomFoodCreateOutMsgForPanes panes context outMsg =
    case ( outMsg, foodSearchModel panes ) of
        ( CustomFoodCreate.Navigate (CustomFoodShow productId), Just search ) ->
            ( Cmd.none
            , Navigate (FoodShow productId search.date search.mealSlot Nothing)
            )

        _ ->
            applyCustomFoodCreateOutMsg context outMsg


foodSearchModel : List Pane -> Maybe FoodSearch.Model
foodSearchModel panes =
    panes
        |> List.filterMap
            (\pane ->
                case pane of
                    FoodSearchPane search ->
                        Just search

                    _ ->
                        Nothing
            )
        |> List.head


applyCustomFoodEditOutMsg : InitContext -> CustomFoodEdit.OutMsg -> ( Cmd Msg, OutMsg )
applyCustomFoodEditOutMsg _ outMsg =
    case outMsg of
        CustomFoodEdit.NoOp ->
            ( Cmd.none, NoOutMsg )

        CustomFoodEdit.RequestInitialData productId ->
            ( Api.Foods.getFoodDetail productId
                (GotCustomFoodEditMsg << CustomFoodEdit.FoodLoaded productId)
            , NoOutMsg
            )

        CustomFoodEdit.RequestUpdateFood productId request ->
            ( Api.Foods.updateCustomFood productId
                request
                (GotCustomFoodEditMsg << CustomFoodEdit.SaveCompleted)
            , NoOutMsg
            )

        CustomFoodEdit.RequestCategorySuggestions token request ->
            ( Api.Foods.listCategorySuggestions request
                (GotCustomFoodEditMsg << CustomFoodEdit.CategorySuggestionsLoaded token)
            , NoOutMsg
            )

        CustomFoodEdit.Navigate route ->
            ( Cmd.none, Navigate route )

        CustomFoodEdit.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyCustomFoodsOutMsg : InitContext -> CustomFoodList.OutMsg -> ( Cmd Msg, OutMsg )
applyCustomFoodsOutMsg _ outMsg =
    case outMsg of
        CustomFoodList.NoOp ->
            ( Cmd.none, NoOutMsg )

        CustomFoodList.RequestFoods ->
            ( Api.Foods.listCustomFoods
                (GotCustomFoodsMsg << CustomFoodList.FoodsLoaded)
            , NoOutMsg
            )

        CustomFoodList.Navigate route ->
            ( Cmd.none, Navigate route )

        CustomFoodList.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyCustomFoodShowOutMsg :
    InitContext
    -> CustomFoodShow.OutMsg
    -> ( Cmd Msg, OutMsg )
applyCustomFoodShowOutMsg _ outMsg =
    case outMsg of
        CustomFoodShow.NoOp ->
            ( Cmd.none, NoOutMsg )

        CustomFoodShow.RequestInitialData productId ->
            ( Api.Foods.getFoodDetail productId
                (GotCustomFoodShowMsg << CustomFoodShow.FoodLoaded productId)
            , NoOutMsg
            )

        CustomFoodShow.RequestDeleteCustomFood productId ->
            ( Api.Foods.deleteCustomFood productId
                (GotCustomFoodShowMsg << CustomFoodShow.DeleteCompleted)
            , NoOutMsg
            )

        CustomFoodShow.Navigate route ->
            ( Cmd.none, Navigate route )

        CustomFoodShow.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyMealsOutMsg : InitContext -> MealList.OutMsg -> ( Cmd Msg, OutMsg )
applyMealsOutMsg _ outMsg =
    case outMsg of
        MealList.NoOp ->
            ( Cmd.none, NoOutMsg )

        MealList.RequestMeals ->
            ( Api.Meals.listMeals (GotMealsMsg << MealList.MealsLoaded)
            , NoOutMsg
            )

        MealList.Navigate route ->
            ( Cmd.none, Navigate route )

        MealList.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyMealCreateOutMsg : InitContext -> MealCreate.OutMsg -> ( Cmd Msg, OutMsg )
applyMealCreateOutMsg _ outMsg =
    case outMsg of
        MealCreate.NoOp ->
            ( Cmd.none, NoOutMsg )

        MealCreate.FormOutMsg formOutMsg ->
            applyMealFormOutMsg
                { toPageMsg = GotMealCreateMsg << MealCreate.FormMsg }
                formOutMsg

        MealCreate.RequestCreateMeal request ->
            ( Api.Meals.createMeal request
                (GotMealCreateMsg << MealCreate.SaveCompleted)
            , NoOutMsg
            )

        MealCreate.Navigate route ->
            ( Cmd.none, Navigate route )

        MealCreate.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyMealEditOutMsg : InitContext -> MealEdit.OutMsg -> ( Cmd Msg, OutMsg )
applyMealEditOutMsg _ outMsg =
    case outMsg of
        MealEdit.NoOp ->
            ( Cmd.none, NoOutMsg )

        MealEdit.FormOutMsg formOutMsg ->
            applyMealFormOutMsg
                { toPageMsg = GotMealEditMsg << MealEdit.FormMsg }
                formOutMsg

        MealEdit.RequestMeal mealId ->
            ( Cmd.batch
                [ Api.Meals.getMeal mealId (GotMealEditMsg << MealEdit.MealLoaded mealId)
                , Api.Meals.getMealNutrients
                    { mealId = mealId, amount = "100", unit = defaultCode }
                    (GotMealEditMsg << MealEdit.NutrientPreviewLoaded mealId)
                ]
            , NoOutMsg
            )

        MealEdit.RequestUpdateMeal mealId request ->
            ( Api.Meals.updateMeal mealId
                request
                (GotMealEditMsg << MealEdit.SaveCompleted)
            , NoOutMsg
            )

        MealEdit.Navigate route ->
            ( Cmd.none, Navigate route )

        MealEdit.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyMealFormOutMsg :
    { toPageMsg : MealForm.FormFieldMsg -> Msg }
    -> MealForm.FormFieldOutMsg
    -> ( Cmd Msg, OutMsg )
applyMealFormOutMsg { toPageMsg } outMsg =
    case outMsg of
        MealForm.RequestProductName productId ->
            ( Api.Foods.getFoodDetail productId
                (toPageMsg << MealForm.ProductNameLoaded productId)
            , NoOutMsg
            )

        MealForm.RequestProductSearch rowId token request ->
            ( Api.Foods.searchFoods request
                (toPageMsg << MealForm.ComponentSearchCompleted rowId token)
            , NoOutMsg
            )

        MealForm.RequestCategorySuggestions rowId token request ->
            ( Api.Foods.listCategorySuggestions request
                (toPageMsg << MealForm.ComponentCategoriesCompleted rowId token)
            , NoOutMsg
            )

        MealForm.RequestProductAndCats requests ->
            ( Cmd.batch
                [ Api.Foods.searchFoods
                    requests.searchRequest
                    (toPageMsg
                        << MealForm.ComponentSearchCompleted
                            requests.rowId
                            requests.searchToken
                    )
                , Api.Foods.listCategorySuggestions
                    requests.categoryRequest
                    (toPageMsg
                        << MealForm.ComponentCategoriesCompleted
                            requests.rowId
                            requests.categoryToken
                    )
                ]
            , NoOutMsg
            )

        MealForm.FormSessionExpired ->
            ( Cmd.none, SessionExpired )


applyMealDetailOutMsg : InitContext -> MealShow.OutMsg -> ( Cmd Msg, OutMsg )
applyMealDetailOutMsg _ outMsg =
    case outMsg of
        MealShow.NoOp ->
            ( Cmd.none, NoOutMsg )

        MealShow.RequestInitialData mealId ->
            ( Cmd.batch
                [ Api.Meals.getMeal mealId (GotMealDetailMsg << MealShow.MealLoaded mealId)
                , Api.Meals.getMealNutrients
                    { mealId = mealId, amount = "100", unit = defaultCode }
                    (GotMealDetailMsg << MealShow.NutrientPreviewLoaded mealId)
                ]
            , NoOutMsg
            )

        MealShow.RequestNutrientPreview mealId amount unit ->
            ( Api.Meals.getMealNutrients
                { mealId = mealId, amount = amount, unit = unit }
                (GotMealDetailMsg << MealShow.NutrientPreviewLoaded mealId)
            , NoOutMsg
            )

        MealShow.RequestProductDetail productId ->
            ( Api.Foods.getFoodDetail productId
                (GotMealDetailMsg << MealShow.ProductDetailLoaded productId)
            , NoOutMsg
            )

        MealShow.RequestDeleteMeal mealId ->
            ( Api.Meals.deleteMeal mealId (GotMealDetailMsg << MealShow.DeleteCompleted)
            , NoOutMsg
            )

        MealShow.Navigate route ->
            ( Cmd.none, Navigate route )

        MealShow.SessionExpired ->
            ( Cmd.none, SessionExpired )



-- VIEW


view : Env -> Model -> Element Msg
view env model =
    if model.waitingForToday then
        Skeleton.loading env.theme

    else
        Workspace.view env.device
            (List.map (paneView env (selectedDiaryDate model.panes)) model.panes)


selectedDiaryDate : List Pane -> Maybe LocalDate
selectedDiaryDate panes =
    panes
        |> List.filterMap
            (\pane ->
                case pane of
                    DiaryPane paneId _ ->
                        Just paneId.date

                    _ ->
                        Nothing
            )
        |> List.head


paneView :
    Env
    -> Maybe LocalDate
    -> Pane
    -> ( String, Element Msg )
paneView env selectedDate pane =
    ( paneKey pane
    , case pane of
        LoginPane sub ->
            Element.map GotLoginMsg (AuthLogin.view env sub)

        SetupPane sub ->
            Element.map GotSetupMsg (BootstrapSetup.view env sub)

        AdminPane sub ->
            Element.map GotAdminMsg (AdminDashboard.contentView env sub)

        AdminCreateUserPane sub ->
            Element.map GotAdminCreateUserMsg (AdminCreateUser.view env sub)

        AdminEditUserPane _ sub ->
            Element.map GotAdminEditUserMsg (AdminEditUser.view env sub)

        DiaryPane _ sub ->
            Element.map GotDiaryMsg (DiaryDay.contentView env sub)

        DiaryCalendarPane _ sub ->
            Element.map GotDiaryCalendarMsg
                (DiaryCalendar.contentViewWithSelection env selectedDate sub)

        NutritionDetailsPane _ sub ->
            Element.map GotNutritionDetailsMsg (NutritionDetails.view env sub)

        GoalsSettingsPane _ sub ->
            Element.map GotGoalsSettingsMsg (GoalsSettings.view env sub)

        DiarySettingsPane sub ->
            Element.map GotDiarySettingsMsg (DiarySettings.view env sub)

        FoodSearchPane sub ->
            Element.map GotFoodSearchMsg (FoodSearch.contentView env sub)

        FoodDetailPane _ sub ->
            Element.map GotFoodDetailMsg (FoodShow.contentView env sub)

        FoodLogDetailPane _ sub ->
            Element.map GotFoodLogDetailMsg (FoodLogEntry.contentView env sub)

        CreateAdHocLogPane sub ->
            Element.map GotCreateAdHocLogMsg (CreateAdHocLog.view env sub)

        CreateWithAiLogPane sub ->
            Element.map GotCreateWithAiLogMsg (CreateWithAiLog.view env sub)

        CustomFoodListPane sub ->
            Element.map GotCustomFoodsMsg (CustomFoodList.contentView env sub)

        CustomFoodCreatePane sub ->
            Element.map GotCustomFoodCreateMsg (CustomFoodCreate.view env sub)

        CustomFoodEditPane _ sub ->
            Element.map GotCustomFoodEditMsg (CustomFoodEdit.view env sub)

        CustomFoodShowPane _ sub ->
            Element.map GotCustomFoodShowMsg (CustomFoodShow.view env sub)

        MealListPane sub ->
            Element.map GotMealsMsg (MealList.contentView env sub)

        MealCreatePane sub ->
            Element.map GotMealCreateMsg (MealCreate.view env sub)

        MealEditPane _ sub ->
            Element.map GotMealEditMsg (MealEdit.view env sub)

        MealDetailPane _ sub ->
            Element.map GotMealDetailMsg (MealShow.view env sub)

        PlaceholderPane message ->
            Element.el [ Element.padding DesignTokens.space24 ] (Element.text message)
    )


modalView :
    Env
    -> Model
    -> Maybe (Element Msg)
modalView env model =
    model.panes
        |> List.filterMap (paneModalView env)
        |> List.head


paneModalView :
    Env
    -> Pane
    -> Maybe (Element Msg)
paneModalView env pane =
    case pane of
        FoodLogDetailPane _ sub ->
            FoodLogEntry.modalView env sub
                |> Maybe.map (Element.map GotFoodLogDetailMsg)

        CustomFoodShowPane _ sub ->
            CustomFoodShow.modalView env sub
                |> Maybe.map (Element.map GotCustomFoodShowMsg)

        CustomFoodCreatePane sub ->
            CustomFoodCreate.modalView env sub
                |> Maybe.map (Element.map GotCustomFoodCreateMsg)

        CreateWithAiLogPane sub ->
            CreateWithAiLog.modalView env sub
                |> Maybe.map (Element.map GotCreateWithAiLogMsg)

        MealDetailPane _ sub ->
            MealShow.modalView env sub
                |> Maybe.map (Element.map GotMealDetailMsg)

        AdminEditUserPane _ sub ->
            AdminEditUser.modalView env sub
                |> Maybe.map (Element.map GotAdminEditUserMsg)

        _ ->
            Nothing



-- HELPERS


lastUsedProductDefaultCmd : Route -> String -> List (Cmd Msg)
lastUsedProductDefaultCmd route productId =
    case route of
        FoodShow _ maybeDate maybeSlot _ ->
            case recentItemsRequest maybeDate maybeSlot of
                Just request ->
                    [ Api.Logs.lastUsedItems
                        { fromDate = request.fromDate
                        , toDate = request.toDate
                        , mealSlot = request.mealSlot
                        , items = [ { itemType = ItemRef.Product, id = productId } ]
                        }
                        (GotFoodDetailMsg << FoodShow.LastUsedLoaded productId)
                    ]

                Nothing ->
                    []

        _ ->
            []


recentItemsRequest :
    Maybe String
    -> Maybe MealSlot
    -> Maybe Api.Logs.RecentItemsRequest
recentItemsRequest maybeDate maybeSlot =
    maybeDate
        |> Maybe.andThen LocalDate.fromString
        |> Maybe.map
            (\toDate ->
                { fromDate = LocalDate.addDays -30 toDate
                , toDate = toDate
                , mealSlot = Maybe.map MealSlot.toString maybeSlot
                }
            )
