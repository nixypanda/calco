module Page exposing
    ( DiaryGoalResult
    , DiaryLogsResult
    , InitContext
    , LatestSlotsResult
    , Model
    , Msg(..)
    , OutMsg(..)
    , Pane(..)
    , PreferencesResult
    , barcodeScannerEventReceived
    , clearStore
    , init
    , initPreserving
    , isLoading
    , loading
    , localContextReceived
    , modalView
    , paneKeys
    , reconcile
    , update
    , view
    )

import Api.Admin
import Api.Auth
import Api.Client
import Api.DiaryPreferences
import Api.Foods
import Api.Goals
import Api.Logs
import Api.Meals
import Api.NutritionDetails
import Data.Auth as Auth
import Data.DiaryPreferences
import Data.FoodLog
import Data.Goals
import Data.ItemRef as ItemRef
import Data.MealSlot as MealSlot exposing (MealSlot)
import Data.Nutrition exposing (defaultCode)
import Data.Route exposing (Route(..))
import Dict exposing (Dict)
import Element exposing (Device, Element)
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Loadable exposing (Loadable(..))
import Page.CustomFood.Create as CustomFoodCreate
import Page.CustomFood.Edit as CustomFoodEdit
import Page.CustomFood.List as CustomFoodList
import Page.CustomFood.Show as CustomFoodShow
import Page.Diary.Calendar as DiaryCalendar
import Page.Diary.Day as DiaryDay
import Page.Diary.Settings as DiarySettings
import Page.Food.Search as FoodSearch
import Page.Food.Show as FoodShow
import Page.FoodLog.Entry as FoodLogEntry
import Page.Goals.Settings as GoalsSettings
import Page.Meal.Create as MealCreate
import Page.Meal.Edit as MealEdit
import Page.Meal.Form as MealForm
import Page.Meal.List as MealList
import Page.Meal.Show as MealShow
import Page.NutritionDetails as NutritionDetails
import Page.Users.BootstrapSetup as BootstrapSetup
import Page.Users.CreateUser as AdminCreateUser
import Page.Users.Dashboard as AdminDashboard
import Page.Users.EditUser as AdminEditUser
import Page.Users.Login as AuthLogin
import Store exposing (Store)
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Theme exposing (Theme)
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
    | DiaryPane String DiaryDay.Model
    | DiaryCalendarPane String DiaryCalendar.Model
    | NutritionDetailsPane String NutritionDetails.Model
    | GoalsSettingsPane String GoalsSettings.Model
    | DiarySettingsPane DiarySettings.Model
    | FoodSearchPane FoodSearch.Model
    | FoodDetailPane String FoodShow.Model
    | FoodLogDetailPane String FoodLogEntry.Model
    | CustomFoodListPane CustomFoodList.Model
    | CustomFoodCreatePane CustomFoodCreate.Model
    | CustomFoodEditPane String CustomFoodEdit.Model
    | CustomFoodShowPane String CustomFoodShow.Model
    | MealListPane MealList.Model
    | MealCreatePane MealCreate.Model
    | MealEditPane String MealEdit.Model
    | MealDetailPane String MealShow.Model
    | PlaceholderPane String


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

        DiaryPane key _ ->
            key

        DiaryCalendarPane month _ ->
            "calendar:" ++ month

        NutritionDetailsPane date _ ->
            "nutrition-details:" ++ date

        GoalsSettingsPane date _ ->
            "goals-settings:" ++ date

        DiarySettingsPane _ ->
            "diary-settings"

        FoodSearchPane _ ->
            "food-search"

        FoodDetailPane key _ ->
            key

        FoodLogDetailPane logId _ ->
            "log-detail:" ++ logId

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
            retargetedPanes
                |> hydrateSharedPanes store result.initializedKeys
                |> hydrateDatePanes store result.initializedKeys

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


hydrateSharedPanes : Store -> List String -> List Pane -> List Pane
hydrateSharedPanes store initializedKeys panes =
    List.map
        (\pane ->
            if List.member (paneKey pane) initializedKeys then
                hydrateSharedPane store pane

            else
                pane
        )
        panes


hydrateDatePanes : Store -> List String -> List Pane -> List Pane
hydrateDatePanes store initializedKeys panes =
    List.map
        (\pane ->
            if List.member (paneKey pane) initializedKeys then
                hydrateDatePane store pane

            else
                pane
        )
        panes


hydrateDatePane : Store -> Pane -> Pane
hydrateDatePane store pane =
    case pane of
        DiaryPane key model ->
            let
                date : LocalDate
                date =
                    model.currentDate
            in
            DiaryPane key
                (model
                    |> applyDiaryResult (DiaryDay.LogsLoaded date)
                        (Dict.get (LocalDate.format date) store.diaryLogs)
                    |> applyDiaryResult (DiaryDay.GoalLoaded date)
                        (Dict.get (LocalDate.format date) store.diaryGoals)
                    |> applyDiaryResult (DiaryDay.LatestSlotsReceived date)
                        (Dict.get (LocalDate.format date) store.latestSlots)
                )

        GoalsSettingsPane date model ->
            GoalsSettingsPane date
                (applyGoalSettingsResult
                    (Dict.get date store.diaryGoals)
                    model
                )

        _ ->
            pane


applyDiaryResult :
    (Result error value -> DiaryDay.Msg)
    -> Maybe (Loadable error value)
    -> DiaryDay.Model
    -> DiaryDay.Model
applyDiaryResult toMsg loadable model =
    loadable
        |> Maybe.andThen loadableResult
        |> Maybe.map (\result -> firstOfThree (DiaryDay.update (toMsg result) model))
        |> Maybe.withDefault model


applyGoalSettingsResult :
    Maybe (Loadable Api.Client.ApiError Data.Goals.GoalSnapshot)
    -> GoalsSettings.Model
    -> GoalsSettings.Model
applyGoalSettingsResult loadable model =
    loadable
        |> Maybe.andThen loadableResult
        |> Maybe.map
            (\result -> firstOfThree (GoalsSettings.update (GoalsSettings.GoalLoaded result) model))
        |> Maybe.withDefault model


hydrateSharedPane : Store -> Pane -> Pane
hydrateSharedPane store pane =
    pane
        |> hydrateUnits store.units
        |> hydrateNutrients store.nutrients
        |> hydratePreferences store.preferences


hydrateUnits : Loadable Api.Client.ApiError Api.Foods.UnitListResponse -> Pane -> Pane
hydrateUnits units pane =
    case loadableResult units of
        Just result ->
            case pane of
                FoodDetailPane key model ->
                    FoodDetailPane key
                        (firstOfThree
                            (FoodShow.update (FoodShow.UnitsLoaded result) model)
                        )

                FoodLogDetailPane key model ->
                    FoodLogDetailPane key
                        (firstOfThree (FoodLogEntry.update (FoodLogEntry.UnitsLoaded result) model))

                CustomFoodCreatePane model ->
                    CustomFoodCreatePane
                        (firstOfThree
                            (CustomFoodCreate.update (CustomFoodCreate.UnitsLoaded result) model)
                        )

                CustomFoodEditPane key model ->
                    CustomFoodEditPane key
                        (firstOfThree
                            (CustomFoodEdit.update (CustomFoodEdit.UnitsLoaded result) model)
                        )

                CustomFoodShowPane key model ->
                    CustomFoodShowPane key
                        (firstOfThree
                            (CustomFoodShow.update (CustomFoodShow.UnitsLoaded result) model)
                        )

                MealDetailPane key model ->
                    MealDetailPane key
                        (firstOfThree (MealShow.update (MealShow.UnitsLoaded result) model))

                _ ->
                    pane

        Nothing ->
            pane


hydrateNutrients :
    Loadable Api.Client.ApiError Api.Foods.NutrientListResponse
    -> Pane
    -> Pane
hydrateNutrients nutrients pane =
    case loadableResult nutrients of
        Just result ->
            case pane of
                CustomFoodCreatePane model ->
                    CustomFoodCreatePane
                        (firstOfThree
                            (CustomFoodCreate.update
                                (CustomFoodCreate.NutrientsLoaded result)
                                model
                            )
                        )

                CustomFoodEditPane key model ->
                    CustomFoodEditPane key
                        (firstOfThree
                            (CustomFoodEdit.update
                                (CustomFoodEdit.NutrientsLoaded result)
                                model
                            )
                        )

                _ ->
                    pane

        Nothing ->
            pane


hydratePreferences :
    Loadable Api.Client.ApiError Data.DiaryPreferences.DiaryPreferences
    -> Pane
    -> Pane
hydratePreferences preferences pane =
    case loadableResult preferences of
        Just result ->
            case pane of
                DiaryPane key model ->
                    DiaryPane key
                        (firstOfThree
                            (DiaryDay.update (DiaryDay.PreferencesLoaded result) model)
                        )

                DiarySettingsPane model ->
                    DiarySettingsPane
                        (firstOfThree
                            (DiarySettings.update
                                (DiarySettings.PreferencesLoaded result)
                                model
                            )
                        )

                _ ->
                    pane

        Nothing ->
            pane


loadableResult : Loadable error value -> Maybe (Result error value)
loadableResult loadable =
    case loadable of
        Success value ->
            Just (Ok value)

        Failure error ->
            Just (Err error)

        _ ->
            Nothing


ensureSharedData : List Pane -> Store -> ( Store, Cmd Msg )
ensureSharedData panes store =
    if List.any isUserPane panes then
        let
            generation : Int
            generation =
                store.generation

            ( withUnits, unitsCmd ) =
                case store.units of
                    NotAsked ->
                        ( { store | units = Loading }
                        , Api.Foods.listUnits (SharedUnitsLoaded generation)
                        )

                    _ ->
                        ( store, Cmd.none )

            ( withNutrients, nutrientsCmd ) =
                case withUnits.nutrients of
                    NotAsked ->
                        ( { withUnits | nutrients = Loading }
                        , Api.Foods.listNutrients (SharedNutrientsLoaded generation)
                        )

                    _ ->
                        ( withUnits, Cmd.none )

            ( withPreferences, preferencesCmd ) =
                case withNutrients.preferences of
                    NotAsked ->
                        ( { withNutrients | preferences = Loading }
                        , Api.DiaryPreferences.get
                            (SharedPreferencesLoaded generation)
                        )

                    _ ->
                        ( withNutrients, Cmd.none )
        in
        ( withPreferences
        , Cmd.batch [ unitsCmd, nutrientsCmd, preferencesCmd ]
        )

    else
        ( store, Cmd.none )


ensureDateData : List Pane -> Store -> ( Store, Cmd Msg )
ensureDateData panes store =
    let
        ensurePane : Pane -> ( Store, List (Cmd Msg) ) -> ( Store, List (Cmd Msg) )
        ensurePane pane ( currentStore, cmds ) =
            case pane of
                DiaryPane _ diary ->
                    let
                        ( logsStore, logsCmd ) =
                            ensureDiaryLogs diary.currentDate currentStore

                        ( goalStore, goalCmd ) =
                            ensureDiaryGoal diary.currentDate logsStore

                        ( slotsStore, slotsCmd ) =
                            ensureLatestSlots diary.currentDate goalStore
                    in
                    ( slotsStore, slotsCmd :: goalCmd :: logsCmd :: cmds )

                GoalsSettingsPane rawDate _ ->
                    case LocalDate.fromString rawDate of
                        Just date ->
                            let
                                ( nextStore, cmd ) =
                                    ensureDiaryGoal date currentStore
                            in
                            ( nextStore, cmd :: cmds )

                        Nothing ->
                            ( currentStore, cmds )

                _ ->
                    ( currentStore, cmds )

        ( finalStore, reversedCmds ) =
            List.foldl ensurePane ( store, [] ) panes
    in
    ( finalStore, Cmd.batch (List.reverse reversedCmds) )


ensureDiaryLogs : LocalDate -> Store -> ( Store, Cmd Msg )
ensureDiaryLogs date store =
    let
        key : String
        key =
            LocalDate.format date
    in
    case Dict.get key store.diaryLogs |> Maybe.withDefault NotAsked of
        NotAsked ->
            let
                requestId : Int
                requestId =
                    store.nextRequestId + 1
            in
            ( { store
                | nextRequestId = requestId
                , diaryLogs = Dict.insert key Loading store.diaryLogs
                , diaryLogRequestIds = Dict.insert key requestId store.diaryLogRequestIds
              }
            , Api.Logs.listLogs date
                (DiaryLogsStoreLoaded store.generation requestId date)
            )

        _ ->
            ( store, Cmd.none )


ensureDiaryGoal : LocalDate -> Store -> ( Store, Cmd Msg )
ensureDiaryGoal date store =
    let
        key : String
        key =
            LocalDate.format date
    in
    case Dict.get key store.diaryGoals |> Maybe.withDefault NotAsked of
        NotAsked ->
            let
                requestId : Int
                requestId =
                    store.nextRequestId + 1
            in
            ( { store
                | nextRequestId = requestId
                , diaryGoals = Dict.insert key Loading store.diaryGoals
                , diaryGoalRequestIds = Dict.insert key requestId store.diaryGoalRequestIds
              }
            , Api.Goals.getGoal date
                (DiaryGoalStoreLoaded store.generation requestId date)
            )

        _ ->
            ( store, Cmd.none )


ensureLatestSlots : LocalDate -> Store -> ( Store, Cmd Msg )
ensureLatestSlots date store =
    let
        key : String
        key =
            LocalDate.format date
    in
    case Dict.get key store.latestSlots |> Maybe.withDefault NotAsked of
        NotAsked ->
            let
                requestId : Int
                requestId =
                    store.nextRequestId + 1
            in
            ( { store
                | nextRequestId = requestId
                , latestSlots = Dict.insert key Loading store.latestSlots
                , latestSlotRequestIds = Dict.insert key requestId store.latestSlotRequestIds
              }
            , Api.Logs.latestSlots
                { before = date, lookbackDays = 30 }
                (LatestSlotsStoreLoaded store.generation requestId date)
            )

        _ ->
            ( store, Cmd.none )


isUserPane : Pane -> Bool
isUserPane pane =
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

        _ ->
            True


firstOfThree : ( a, b, c ) -> a
firstOfThree ( value, _, _ ) =
    value


retargetSearchForRoute : Route -> List Pane -> ( List Pane, Cmd Msg )
retargetSearchForRoute route panes =
    case route of
        FoodSearch dateParam mealSlot ->
            retargetSearch dateParam mealSlot panes

        FoodShow _ dateParam mealSlot ->
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
                [ adminDesired context
                , simpleDesired
                    "admin-create-user"
                    (AdminCreateUserPane AdminCreateUser.init)
                ]

        AdminEditUser userId ->
            Just [ adminDesired context, adminEditDesired context userId ]

        DiaryDay dateParam calendarMonth ->
            context.today
                |> Maybe.map
                    (\today ->
                        case calendarMonth of
                            Just month ->
                                [ calendarDesired context today (Just month)
                                , diaryDesired context today dateParam calendarMonth
                                ]

                            Nothing ->
                                [ diaryDesired context today dateParam Nothing ]
                    )

        DiaryCalendar monthParam ->
            context.today
                |> Maybe.map (\today -> [ calendarDesired context today monthParam ])

        NutritionDetails dateParam ->
            context.today
                |> Maybe.map (\today -> [ nutritionDesired context today dateParam ])

        GoalSettings ->
            context.today
                |> Maybe.map (\today -> [ goalsDesired context today ])

        DiarySettings ->
            Just [ diarySettingsDesired context ]

        FoodSearch dateParam mealSlot ->
            Just (searchWorkspaceDesired context dateParam mealSlot)

        FoodShow productId dateParam mealSlot ->
            Just (foodWorkspaceDesired context existing productId dateParam mealSlot)

        FoodLogEntry logId dateParam calendarMonth ->
            Just (logWorkspaceDesired context logId dateParam calendarMonth)

        CustomFoodCreate ->
            Just (customFoodCreateDesired context existing)

        CustomFoodEdit productId ->
            Just [ customFoodListDesired context, customFoodEditDesired context productId ]

        CustomFoodShow productId ->
            Just [ customFoodListDesired context, customFoodShowDesired context productId ]

        CustomFoodList ->
            Just [ customFoodListDesired context ]

        MealList ->
            Just [ mealListDesired context ]

        MealCreate ->
            Just [ mealListDesired context, mealCreateDesired context ]

        MealEdit mealId ->
            Just [ mealListDesired context, mealEditDesired context mealId ]

        MealShow mealId ->
            Just [ mealListDesired context, mealDetailDesired context mealId ]

        _ ->
            Just
                [ simpleDesired
                    "placeholder:unmigrated"
                    (PlaceholderPane "This route is not migrated yet.")
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
        date : LocalDate
        date =
            dateParam
                |> Maybe.andThen LocalDate.fromString
                |> Maybe.withDefault today
                |> LocalDate.clampTo today

        key : String
        key =
            "diary:" ++ LocalDate.format date ++ ":" ++ Maybe.withDefault "none" calendarMonth
    in
    fromInit context
        key
        (DiaryPane key)
        applyDiaryOutMsg
        (\_ ->
            DiaryDay.init
                { dateParam = dateParam
                , calendarMonth = calendarMonth
                , today = today
                }
        )


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
            dateParam
                |> Maybe.andThen LocalDate.fromString
                |> Maybe.withDefault today
                |> LocalDate.clampTo today

        key : String
        key =
            LocalDate.format date
    in
    fromInit context
        ("nutrition-details:" ++ key)
        (NutritionDetailsPane key)
        applyNutritionDetailsOutMsg
        (\_ -> NutritionDetails.init { dateParam = dateParam, today = today })


goalsDesired : InitContext -> LocalDate -> DesiredPane
goalsDesired context today =
    let
        key : String
        key =
            LocalDate.format today
    in
    fromInit context
        ("goals-settings:" ++ key)
        (GoalsSettingsPane key)
        applyGoalsSettingsOutMsg
        (\_ -> GoalsSettings.init today)


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


searchWorkspaceDesired : InitContext -> Maybe String -> Maybe MealSlot -> List DesiredPane
searchWorkspaceDesired context dateParam mealSlot =
    case ( context.today, dateParam |> Maybe.andThen LocalDate.fromString ) of
        ( Just today, Just _ ) ->
            [ diaryDesired context today dateParam Nothing
            , searchDesired context dateParam mealSlot
            ]

        _ ->
            [ searchDesired context dateParam mealSlot ]


foodWorkspaceDesired :
    InitContext
    -> List Pane
    -> String
    -> Maybe String
    -> Maybe MealSlot
    -> List DesiredPane
foodWorkspaceDesired context existing productId dateParam mealSlot =
    let
        detail : DesiredPane
        detail =
            foodDetailDesired context productId dateParam mealSlot
    in
    case ( context.today, dateParam |> Maybe.andThen LocalDate.fromString ) of
        ( Just today, Just _ ) ->
            [ diaryDesired context today dateParam Nothing
            , searchDesired context dateParam mealSlot
            , detail
            ]

        _ ->
            if List.any isFoodSearchPane existing then
                [ searchDesired context dateParam mealSlot, detail ]

            else
                [ detail ]


foodDetailDesired : InitContext -> String -> Maybe String -> Maybe MealSlot -> DesiredPane
foodDetailDesired context productId dateParam mealSlot =
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
            "food-detail:" ++ productId ++ ":" ++ contextKey
    in
    fromInit context
        key
        (FoodDetailPane key)
        applyFoodDetailOutMsg
        (\_ -> FoodShow.init productId dateParam mealSlot)


logWorkspaceDesired : InitContext -> String -> Maybe String -> Maybe String -> List DesiredPane
logWorkspaceDesired context logId dateParam calendarMonth =
    let
        detail : DesiredPane
        detail =
            foodLogDetailDesired context logId
    in
    case ( context.today, dateParam |> Maybe.andThen LocalDate.fromString ) of
        ( Just today, Just _ ) ->
            case calendarMonth of
                Just month ->
                    [ calendarDesired context today (Just month)
                    , diaryDesired context today dateParam calendarMonth
                    , detail
                    ]

                Nothing ->
                    [ diaryDesired context today dateParam Nothing, detail ]

        _ ->
            [ detail ]


foodLogDetailDesired : InitContext -> String -> DesiredPane
foodLogDetailDesired context logId =
    fromInit context
        ("log-detail:" ++ logId)
        (FoodLogDetailPane logId)
        applyFoodLogDetailOutMsg
        (\_ -> FoodLogEntry.init logId)


customFoodCreateDesired : InitContext -> List Pane -> List DesiredPane
customFoodCreateDesired context existing =
    if List.any isFoodSearchPane existing then
        existing
            |> List.filter (\pane -> isDiaryPane pane || isFoodSearchPane pane)
            |> List.map preservePane
            |> (\prefix -> prefix ++ [ customFoodCreatePaneDesired context ])

    else
        [ customFoodListDesired context, customFoodCreatePaneDesired context ]


preservePane : Pane -> DesiredPane
preservePane pane =
    simpleDesired (paneKey pane) pane


customFoodListDesired : InitContext -> DesiredPane
customFoodListDesired context =
    fromInit context
        "custom-food-list"
        CustomFoodListPane
        applyCustomFoodsOutMsg
        (\_ -> CustomFoodList.init)


customFoodCreatePaneDesired : InitContext -> DesiredPane
customFoodCreatePaneDesired context =
    fromInit context
        "custom-food-create"
        CustomFoodCreatePane
        applyCustomFoodCreateOutMsg
        (\_ -> CustomFoodCreate.init)


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


isDiaryPane : Pane -> Bool
isDiaryPane pane =
    case pane of
        DiaryPane _ _ ->
            True

        _ ->
            False


isFoodSearchPane : Pane -> Bool
isFoodSearchPane pane =
    case pane of
        FoodSearchPane _ ->
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


type alias PreferencesResult =
    Result Api.Client.ApiError Data.DiaryPreferences.DiaryPreferences


type alias DiaryLogsResult =
    Result Api.Client.ApiError (List Data.FoodLog.FoodLog)


type alias DiaryGoalResult =
    Result Api.Client.ApiError Data.Goals.GoalSnapshot


type alias LatestSlotsResult =
    Result Api.Client.ApiError Api.Logs.LatestSlotsResponse


type Msg
    = SharedUnitsLoaded Int (Result Api.Client.ApiError Api.Foods.UnitListResponse)
    | SharedNutrientsLoaded Int (Result Api.Client.ApiError Api.Foods.NutrientListResponse)
    | SharedPreferencesLoaded Int PreferencesResult
    | DiaryLogsStoreLoaded Int Int LocalDate DiaryLogsResult
    | DiaryGoalStoreLoaded Int Int LocalDate DiaryGoalResult
    | LatestSlotsStoreLoaded Int Int LocalDate LatestSlotsResult
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
    case updateSharedMessage msg model of
        Just result ->
            Just result

        Nothing ->
            updateFirst (updatePane model.panes context msg) model.panes
                |> Maybe.map
                    (\result ->
                        let
                            paneStore : Store
                            paneStore =
                                updateStoreFromPaneMessage msg model.store

                            ( refreshedPanes, nextStore, refreshCmd ) =
                                applyMutation context result.mutation result.pane paneStore
                        in
                        ( { model
                            | panes = refreshedPanes
                            , store = nextStore
                          }
                        , Cmd.batch [ result.cmd, refreshCmd ]
                        , result.outMsg
                        )
                    )


updateSharedMessage : Msg -> Model -> Maybe ( Model, Cmd Msg, OutMsg )
updateSharedMessage msg model =
    let
        finish :
            Int
            -> (Loadable Api.Client.ApiError value -> Store -> Store)
            -> (Loadable Api.Client.ApiError value -> Pane -> Pane)
            -> Result Api.Client.ApiError value
            -> Maybe ( Model, Cmd Msg, OutMsg )
        finish generation applyStore hydrate result =
            if generation /= model.store.generation then
                Just ( model, Cmd.none, NoOutMsg )

            else
                let
                    store : Store
                    store =
                        applyStore (resultToLoadable result) model.store

                    panes : List Pane
                    panes =
                        List.map (hydrate (resultToLoadable result)) model.panes

                    outMsg : OutMsg
                    outMsg =
                        case result of
                            Err error ->
                                if Api.Client.isUnauthorized error then
                                    SessionExpired

                                else
                                    NoOutMsg

                            Ok _ ->
                                NoOutMsg
                in
                Just ( { model | panes = panes, store = store }, Cmd.none, outMsg )
    in
    case msg of
        SharedUnitsLoaded generation result ->
            finish generation
                (\value store -> { store | units = value })
                hydrateUnits
                result

        SharedNutrientsLoaded generation result ->
            finish generation
                (\value store -> { store | nutrients = value })
                hydrateNutrients
                result

        SharedPreferencesLoaded generation result ->
            finish generation
                (\value store -> { store | preferences = value })
                hydratePreferences
                result

        DiaryLogsStoreLoaded generation requestId date result ->
            Just (finishDiaryLogsResponse generation requestId date result model)

        DiaryGoalStoreLoaded generation requestId date result ->
            Just (finishDiaryGoalResponse generation requestId date result model)

        LatestSlotsStoreLoaded generation requestId date result ->
            Just (finishLatestSlotsResponse generation requestId date result model)

        _ ->
            Nothing


finishDiaryLogsResponse :
    Int
    -> Int
    -> LocalDate
    -> Result Api.Client.ApiError (List Data.FoodLog.FoodLog)
    -> Model
    -> ( Model, Cmd Msg, OutMsg )
finishDiaryLogsResponse generation requestId date result model =
    let
        key : String
        key =
            LocalDate.format date
    in
    if
        not
            (Store.isCurrentRequest generation
                requestId
                key
                model.store
                model.store.diaryLogRequestIds
            )
    then
        ( model, Cmd.none, NoOutMsg )

    else
        let
            currentStore : Store
            currentStore =
                model.store

            store : Store
            store =
                { currentStore
                    | diaryLogs = Dict.insert key (resultToLoadable result) currentStore.diaryLogs
                    , diaryLogRequestIds = Dict.remove key currentStore.diaryLogRequestIds
                }
        in
        finishDateResponse result
            store
            (updateDiaryPanes date (DiaryDay.LogsLoaded date result) model.panes)


finishDiaryGoalResponse :
    Int
    -> Int
    -> LocalDate
    -> Result Api.Client.ApiError Data.Goals.GoalSnapshot
    -> Model
    -> ( Model, Cmd Msg, OutMsg )
finishDiaryGoalResponse generation requestId date result model =
    let
        key : String
        key =
            LocalDate.format date
    in
    if
        not
            (Store.isCurrentRequest generation
                requestId
                key
                model.store
                model.store.diaryGoalRequestIds
            )
    then
        ( model, Cmd.none, NoOutMsg )

    else
        let
            currentStore : Store
            currentStore =
                model.store

            store : Store
            store =
                { currentStore
                    | diaryGoals = Dict.insert key (resultToLoadable result) currentStore.diaryGoals
                    , diaryGoalRequestIds = Dict.remove key currentStore.diaryGoalRequestIds
                }

            panes : List Pane
            panes =
                model.panes
                    |> updateDiaryPanes date (DiaryDay.GoalLoaded date result)
                    |> updateGoalSettingsPanes key result
        in
        finishDateResponse result store panes


finishLatestSlotsResponse :
    Int
    -> Int
    -> LocalDate
    -> Result Api.Client.ApiError Api.Logs.LatestSlotsResponse
    -> Model
    -> ( Model, Cmd Msg, OutMsg )
finishLatestSlotsResponse generation requestId date result model =
    let
        key : String
        key =
            LocalDate.format date
    in
    if
        not
            (Store.isCurrentRequest generation
                requestId
                key
                model.store
                model.store.latestSlotRequestIds
            )
    then
        ( model, Cmd.none, NoOutMsg )

    else
        let
            currentStore : Store
            currentStore =
                model.store

            store : Store
            store =
                { currentStore
                    | latestSlots =
                        Dict.insert key
                            (resultToLoadable result)
                            currentStore.latestSlots
                    , latestSlotRequestIds = Dict.remove key currentStore.latestSlotRequestIds
                }
        in
        finishDateResponse result
            store
            (updateDiaryPanes date (DiaryDay.LatestSlotsReceived date result) model.panes)


finishDateResponse :
    Result Api.Client.ApiError value
    -> Store
    -> List Pane
    -> ( Model, Cmd Msg, OutMsg )
finishDateResponse result store panes =
    ( { panes = panes, waitingForToday = False, store = store }
    , Cmd.none
    , case result of
        Err error ->
            if Api.Client.isUnauthorized error then
                SessionExpired

            else
                NoOutMsg

        Ok _ ->
            NoOutMsg
    )


updateDiaryPanes : LocalDate -> DiaryDay.Msg -> List Pane -> List Pane
updateDiaryPanes date msg panes =
    List.map
        (\pane ->
            case pane of
                DiaryPane key diary ->
                    if LocalDate.equals diary.currentDate date then
                        DiaryPane key (firstOfThree (DiaryDay.update msg diary))

                    else
                        pane

                _ ->
                    pane
        )
        panes


updateGoalSettingsPanes :
    String
    -> Result Api.Client.ApiError Data.Goals.GoalSnapshot
    -> List Pane
    -> List Pane
updateGoalSettingsPanes date result panes =
    List.map
        (\pane ->
            case pane of
                GoalsSettingsPane paneDate goals ->
                    if paneDate == date then
                        GoalsSettingsPane paneDate
                            (firstOfThree
                                (GoalsSettings.update
                                    (GoalsSettings.GoalLoaded result)
                                    goals
                                )
                            )

                    else
                        pane

                _ ->
                    pane
        )
        panes


resultToLoadable : Result error value -> Loadable error value
resultToLoadable result =
    case result of
        Ok value ->
            Success value

        Err error ->
            Failure error


updateStoreFromPaneMessage : Msg -> Store -> Store
updateStoreFromPaneMessage msg store =
    case msg of
        GotDiarySettingsMsg (DiarySettings.SaveCompleted (Ok preferences)) ->
            { store | preferences = Success preferences }

        _ ->
            store


type Mutation
    = NoMutation
    | RefreshDiaryAndCalendar LocalDate
    | RefreshCalendar LocalDate
    | RefreshGoals


type alias PaneUpdate pane =
    { pane : pane
    , cmd : Cmd Msg
    , outMsg : OutMsg
    , mutation : Mutation
    }


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

        ( GotDiaryMsg subMsg, DiaryPane key sub ) ->
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
            stepPane context (DiaryPane key) GotDiaryMsg applyDiaryOutMsg mutation result

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
            stepPane context
                DiarySettingsPane
                GotDiarySettingsMsg
                applyDiarySettingsOutMsg
                NoMutation
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

        ( GotCustomFoodCreateMsg subMsg, CustomFoodCreatePane sub ) ->
            stepPane context
                CustomFoodCreatePane
                GotCustomFoodCreateMsg
                (applyCustomFoodCreateOutMsgForPanes allPanes)
                NoMutation
                (CustomFoodCreate.update subMsg sub)

        ( GotCustomFoodEditMsg subMsg, CustomFoodEditPane productId sub ) ->
            stepPane context
                (CustomFoodEditPane productId)
                GotCustomFoodEditMsg
                applyCustomFoodEditOutMsg
                NoMutation
                (CustomFoodEdit.update subMsg sub)

        ( GotCustomFoodShowMsg subMsg, CustomFoodShowPane productId sub ) ->
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
            stepPane context
                (MealEditPane mealId)
                GotMealEditMsg
                applyMealEditOutMsg
                NoMutation
                (MealEdit.update subMsg sub)

        ( GotMealDetailMsg subMsg, MealDetailPane mealId sub ) ->
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


applyMutation : InitContext -> Mutation -> List Pane -> Store -> ( List Pane, Store, Cmd Msg )
applyMutation context mutation panes store =
    case mutation of
        NoMutation ->
            ( panes, store, Cmd.none )

        RefreshDiaryAndCalendar date ->
            refreshAfterLogMutation context True date panes store

        RefreshCalendar date ->
            refreshAfterLogMutation context False date panes store

        RefreshGoals ->
            let
                invalidated : Store
                invalidated =
                    { store
                        | diaryGoals = Dict.empty
                        , diaryGoalRequestIds = Dict.empty
                    }

                ( nextStore, cmd ) =
                    ensureDateData panes invalidated
            in
            ( panes, nextStore, cmd )


refreshAfterLogMutation :
    InitContext
    -> Bool
    -> LocalDate
    -> List Pane
    -> Store
    -> ( List Pane, Store, Cmd Msg )
refreshAfterLogMutation context reloadDiary date panes store =
    let
        key : String
        key =
            LocalDate.format date

        invalidated : Store
        invalidated =
            { store
                | diaryLogs =
                    if reloadDiary then
                        Dict.insert key NotAsked store.diaryLogs

                    else
                        syncDiaryLogs date panes store.diaryLogs
                , diaryLogRequestIds = Dict.remove key store.diaryLogRequestIds
                , latestSlots = Dict.empty
                , latestSlotRequestIds = Dict.empty
            }

        ( refreshedPanes, calendarCmd ) =
            refreshCalendars context date panes

        ( nextStore, dateCmd ) =
            ensureDateData refreshedPanes invalidated
    in
    ( refreshedPanes, nextStore, Cmd.batch [ calendarCmd, dateCmd ] )


syncDiaryLogs :
    LocalDate
    -> List Pane
    -> Dict String (Loadable Api.Client.ApiError (List Data.FoodLog.FoodLog))
    -> Dict String (Loadable Api.Client.ApiError (List Data.FoodLog.FoodLog))
syncDiaryLogs date panes cached =
    let
        logs : Maybe (List Data.FoodLog.FoodLog)
        logs =
            panes
                |> List.filterMap
                    (\pane ->
                        case pane of
                            DiaryPane _ diary ->
                                if LocalDate.equals diary.currentDate date then
                                    case diary.diary of
                                        DiaryDay.Loaded loaded ->
                                            Just loaded.logs

                                        DiaryDay.Loading loadingState ->
                                            loadingState.logs

                                        DiaryDay.Failed _ _ ->
                                            Nothing

                                else
                                    Nothing

                            _ ->
                                Nothing
                    )
                |> List.head
    in
    case logs of
        Just value ->
            Dict.insert (LocalDate.format date) (Success value) cached

        Nothing ->
            Dict.insert (LocalDate.format date) NotAsked cached


refreshCalendars : InitContext -> LocalDate -> List Pane -> ( List Pane, Cmd Msg )
refreshCalendars context date panes =
    let
        refresh : Pane -> ( Pane, Cmd Msg )
        refresh pane =
            case pane of
                DiaryCalendarPane month calendar ->
                    let
                        ( next, subCmd, subOut ) =
                            DiaryCalendar.update (DiaryCalendar.RefreshDay date) calendar

                        ( outCmd, _ ) =
                            applyDiaryCalendarOutMsg context subOut
                    in
                    ( DiaryCalendarPane month next
                    , Cmd.batch [ Cmd.map GotDiaryCalendarMsg subCmd, outCmd ]
                    )

                _ ->
                    ( pane, Cmd.none )

        results : List ( Pane, Cmd Msg )
        results =
            List.map refresh panes
    in
    ( List.map Tuple.first results, results |> List.map Tuple.second |> Cmd.batch )


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value


localContextReceived :
    InitContext
    -> { date : String, timezone : String }
    -> Model
    -> Maybe ( Model, Cmd Msg, OutMsg )
localContextReceived pageContext context model =
    updateAll
        pageContext
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

                GoalsSettingsPane _ _ ->
                    updatePane model.panes
                        pageContext
                        (GotGoalsSettingsMsg (GoalsSettings.LocalContextReceived context))
                        pane

                _ ->
                    Nothing
        )
        model


barcodeScannerEventReceived :
    InitContext
    -> { event : String, barcode : Maybe String, message : Maybe String }
    -> Model
    -> Maybe ( Model, Cmd Msg, OutMsg )
barcodeScannerEventReceived pageContext event model =
    updateAll
        pageContext
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
    InitContext
    -> (Pane -> Maybe (PaneUpdate Pane))
    -> Model
    -> Maybe ( Model, Cmd Msg, OutMsg )
updateAll pageContext updateOne model =
    let
        step : Pane -> UpdateAllResult -> UpdateAllResult
        step pane result =
            case updateOne pane of
                Just paneResult ->
                    let
                        ( refreshed, nextStore, refreshCmd ) =
                            applyMutation pageContext
                                paneResult.mutation
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

        DiaryCalendar.RequestSummary fromDate toDate ->
            ( Api.Logs.summary
                { fromDate = fromDate
                , toDate = toDate
                }
                (GotDiaryCalendarMsg << DiaryCalendar.SummaryLoaded)
            , NoOutMsg
            )

        DiaryCalendar.RequestEarlierSummary fromDate toDate ->
            ( Api.Logs.summary
                { fromDate = fromDate
                , toDate = toDate
                }
                (GotDiaryCalendarMsg << DiaryCalendar.EarlierSummaryLoaded)
            , NoOutMsg
            )

        DiaryCalendar.RequestDaySummary date ->
            ( Api.Logs.summary
                { fromDate = date, toDate = date }
                (GotDiaryCalendarMsg << DiaryCalendar.DaySummaryRefreshed date)
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
                    (GotFoodDetailMsg << FoodShow.FoodLoaded)
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


applyFoodLogDetailOutMsg : InitContext -> FoodLogEntry.OutMsg -> ( Cmd Msg, OutMsg )
applyFoodLogDetailOutMsg context outMsg =
    case outMsg of
        FoodLogEntry.NoOp ->
            ( Cmd.none, NoOutMsg )

        FoodLogEntry.RequestInitialData logId ->
            ( Api.Logs.getLog logId
                (GotFoodLogDetailMsg << FoodLogEntry.LogLoaded)
            , NoOutMsg
            )

        FoodLogEntry.RequestProductDetail productId ->
            ( Api.Foods.getFoodDetail productId
                (GotFoodLogDetailMsg << FoodLogEntry.ProductDetailLoaded)
            , NoOutMsg
            )

        FoodLogEntry.RequestMealName mealId ->
            ( Api.Meals.getMealName mealId
                (GotFoodLogDetailMsg << FoodLogEntry.MealNameLoaded)
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
            ( Cmd.none, NoOutMsg )

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
            , Navigate (FoodShow productId search.date search.mealSlot)
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
                (GotCustomFoodEditMsg << CustomFoodEdit.FoodLoaded)
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
                (GotCustomFoodShowMsg << CustomFoodShow.FoodLoaded)
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
                [ Api.Meals.getMeal mealId (GotMealEditMsg << MealEdit.MealLoaded)
                , Api.Meals.getMealNutrients
                    { mealId = mealId, amount = "100", unit = defaultCode }
                    (GotMealEditMsg << MealEdit.NutrientPreviewLoaded)
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
                [ Api.Meals.getMeal mealId (GotMealDetailMsg << MealShow.MealLoaded)
                , Api.Meals.getMealNutrients
                    { mealId = mealId, amount = "100", unit = defaultCode }
                    (GotMealDetailMsg << MealShow.NutrientPreviewLoaded)
                ]
            , NoOutMsg
            )

        MealShow.RequestNutrientPreview mealId amount unit ->
            ( Api.Meals.getMealNutrients
                { mealId = mealId, amount = amount, unit = unit }
                (GotMealDetailMsg << MealShow.NutrientPreviewLoaded)
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


view : { model : Model, device : Device, theme : Theme } -> Element Msg
view props =
    if props.model.waitingForToday then
        Ui.skeletonLoading props.theme

    else
        Workspace.view props.device
            (List.map (paneView props (selectedDiaryDate props.model.panes)) props.model.panes)


selectedDiaryDate : List Pane -> Maybe String
selectedDiaryDate panes =
    panes
        |> List.filterMap
            (\pane ->
                case pane of
                    DiaryPane _ diary ->
                        Just (LocalDate.format diary.currentDate)

                    _ ->
                        Nothing
            )
        |> List.head


paneView :
    { model : Model, device : Device, theme : Theme }
    -> Maybe String
    -> Pane
    -> ( String, Element Msg )
paneView props selectedDate pane =
    ( paneKey pane
    , case pane of
        LoginPane sub ->
            Element.map GotLoginMsg (AuthLogin.view (pageProps props sub))

        SetupPane sub ->
            Element.map GotSetupMsg (BootstrapSetup.view (pageProps props sub))

        AdminPane sub ->
            Element.map GotAdminMsg (AdminDashboard.contentView (pageProps props sub))

        AdminCreateUserPane sub ->
            Element.map GotAdminCreateUserMsg (AdminCreateUser.view (pageProps props sub))

        AdminEditUserPane _ sub ->
            Element.map GotAdminEditUserMsg (AdminEditUser.view (pageProps props sub))

        DiaryPane _ sub ->
            Element.map GotDiaryMsg (DiaryDay.contentView (pageProps props sub))

        DiaryCalendarPane _ sub ->
            Element.map GotDiaryCalendarMsg
                (DiaryCalendar.contentViewWithSelection selectedDate (pageProps props sub))

        NutritionDetailsPane _ sub ->
            Element.map GotNutritionDetailsMsg (NutritionDetails.view (pageProps props sub))

        GoalsSettingsPane _ sub ->
            Element.map GotGoalsSettingsMsg (GoalsSettings.view (pageProps props sub))

        DiarySettingsPane sub ->
            Element.map GotDiarySettingsMsg (DiarySettings.view (pageProps props sub))

        FoodSearchPane sub ->
            Element.map GotFoodSearchMsg (FoodSearch.contentView (pageProps props sub))

        FoodDetailPane _ sub ->
            Element.map GotFoodDetailMsg (FoodShow.contentView (pageProps props sub))

        FoodLogDetailPane _ sub ->
            Element.map GotFoodLogDetailMsg (FoodLogEntry.contentView (pageProps props sub))

        CustomFoodListPane sub ->
            Element.map GotCustomFoodsMsg (CustomFoodList.contentView (pageProps props sub))

        CustomFoodCreatePane sub ->
            Element.map GotCustomFoodCreateMsg (CustomFoodCreate.view (pageProps props sub))

        CustomFoodEditPane _ sub ->
            Element.map GotCustomFoodEditMsg (CustomFoodEdit.view (pageProps props sub))

        CustomFoodShowPane _ sub ->
            Element.map GotCustomFoodShowMsg (CustomFoodShow.view (pageProps props sub))

        MealListPane sub ->
            Element.map GotMealsMsg (MealList.contentView (pageProps props sub))

        MealCreatePane sub ->
            Element.map GotMealCreateMsg (MealCreate.view (pageProps props sub))

        MealEditPane _ sub ->
            Element.map GotMealEditMsg (MealEdit.view (pageProps props sub))

        MealDetailPane _ sub ->
            Element.map GotMealDetailMsg (MealShow.view (pageProps props sub))

        PlaceholderPane message ->
            Element.el [ Element.padding DesignTokens.space24 ] (Element.text message)
    )


modalView : { model : Model, device : Device, theme : Theme } -> Maybe (Element Msg)
modalView props =
    props.model.panes
        |> List.filterMap (paneModalView props)
        |> List.head


paneModalView :
    { model : Model, device : Device, theme : Theme }
    -> Pane
    -> Maybe (Element Msg)
paneModalView props pane =
    case pane of
        FoodLogDetailPane _ sub ->
            FoodLogEntry.modalView (pageProps props sub)
                |> Maybe.map (Element.map GotFoodLogDetailMsg)

        CustomFoodShowPane _ sub ->
            CustomFoodShow.modalView (pageProps props sub)
                |> Maybe.map (Element.map GotCustomFoodShowMsg)

        MealDetailPane _ sub ->
            MealShow.modalView (pageProps props sub)
                |> Maybe.map (Element.map GotMealDetailMsg)

        _ ->
            Nothing


pageProps :
    { props | device : Device, theme : Theme }
    -> subModel
    -> { model : subModel, device : Device, theme : Theme }
pageProps props subModel =
    { model = subModel
    , device = props.device
    , theme = props.theme
    }



-- HELPERS


lastUsedProductDefaultCmd : Route -> String -> List (Cmd Msg)
lastUsedProductDefaultCmd route productId =
    case route of
        FoodShow _ maybeDate maybeSlot ->
            case recentItemsRequest maybeDate maybeSlot of
                Just request ->
                    [ Api.Logs.lastUsedItems
                        { fromDate = request.fromDate
                        , toDate = request.toDate
                        , mealSlot = request.mealSlot
                        , items = [ { itemType = ItemRef.Product, id = productId } ]
                        }
                        (GotFoodDetailMsg << FoodShow.LastUsedLoaded)
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
