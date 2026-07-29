module Page exposing
    ( InitContext
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , barcodeScannerEventReceived
    , init
    , initPreserving
    , isLoading
    , localContextReceived
    , modalView
    , update
    , view
    )

import Api.Admin
import Api.Auth
import Api.DiaryPreferences
import Api.Foods
import Api.Goals
import Api.Logs
import Api.Meals
import Data.Auth as Auth
import Data.ItemRef as ItemRef
import Data.MealSlot as MealSlot exposing (MealSlot)
import Data.Nutrition exposing (defaultCode)
import Data.Route exposing (Route(..))
import Element exposing (Device, Element)
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
import Page.FoodLog.Entry as FoodLogEntry
import Page.Goals.Settings as GoalsSettings
import Page.Meal.Create as MealCreate
import Page.Meal.Edit as MealEdit
import Page.Meal.Form as MealForm
import Page.Meal.List as MealList
import Page.Meal.Show as MealShow
import Page.Users.BootstrapSetup as BootstrapSetup
import Page.Users.CreateUser as AdminCreateUser
import Page.Users.Dashboard as AdminDashboard
import Page.Users.EditUser as AdminEditUser
import Page.Users.Login as AuthLogin
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Theme exposing (Theme)
import Ui.Workspace as Workspace



-- MODEL


type Model
    = LoadingPage
    | LoginPage AuthLogin.Model
    | SetupPage BootstrapSetup.Model
    | AdminPage AdminDashboard.Model
    | AdminCreateUserWorkspace AdminDashboard.Model AdminCreateUser.Model
    | AdminEditUserWorkspace AdminDashboard.Model AdminEditUser.Model
    | DiaryPage DiaryDay.Model
    | DiaryCalendarPage DiaryCalendar.Model
    | DiaryCalendarWorkspace DiaryCalendar.Model DiaryDay.Model
    | GoalsSettingsPage GoalsSettings.Model
    | DiarySettingsPage DiarySettings.Model
    | FoodSearchPage FoodSearch.Model
    | DiarySearchWorkspace DiaryDay.Model FoodSearch.Model
    | FoodDetailPage FoodShow.Model
    | SearchFoodWorkspace FoodSearch.Model FoodShow.Model
    | DiarySearchFoodWorkspace DiaryDay.Model FoodSearch.Model FoodShow.Model
    | SearchCreateFoodWorkspace FoodSearch.Model CustomFoodCreate.Model
    | DiarySearchCreateFoodWorkspace DiaryDay.Model FoodSearch.Model CustomFoodCreate.Model
    | FoodLogDetailPage FoodLogEntry.Model
    | DiaryLogWorkspace DiaryDay.Model FoodLogEntry.Model
    | CalendarDiaryLogWorkspace DiaryCalendar.Model DiaryDay.Model FoodLogEntry.Model
    | CustomFoodCreateWorkspace CustomFoodList.Model CustomFoodCreate.Model
    | CustomFoodEditWorkspace CustomFoodList.Model CustomFoodEdit.Model
    | CustomFoodShowWorkspace CustomFoodList.Model CustomFoodShow.Model
    | CustomFoodsPage CustomFoodList.Model
    | MealsPage MealList.Model
    | MealCreateWorkspace MealList.Model MealCreate.Model
    | MealEditWorkspace MealList.Model MealEdit.Model
    | MealDetailWorkspace MealList.Model MealShow.Model
    | PlaceholderPage String


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
    model == LoadingPage


init : InitContext -> ( Model, Cmd Msg, OutMsg )
init context =
    case context.route of
        AuthLogin ->
            ( LoginPage AuthLogin.init, Cmd.none, NoOutMsg )

        BootstrapSetup ->
            ( SetupPage BootstrapSetup.init, Cmd.none, NoOutMsg )

        AdminDashboard ->
            initPage context AdminPage applyAdminOutMsg AdminDashboard.init

        AdminCreateUser ->
            initAdminCreateWorkspace context

        AdminEditUser userId ->
            initAdminEditWorkspace context userId

        DiaryDay dateParam calendarMonth ->
            case context.today of
                Just today ->
                    case calendarMonth of
                        Just month ->
                            initCalendarDiaryWorkspace context today dateParam month

                        Nothing ->
                            initPage context
                                DiaryPage
                                applyDiaryOutMsg
                                (DiaryDay.init
                                    { dateParam = dateParam
                                    , calendarMonth = Nothing
                                    , today = today
                                    }
                                )

                Nothing ->
                    ( LoadingPage, Cmd.none, NoOutMsg )

        DiaryCalendar monthParam ->
            case context.today of
                Just today ->
                    initPage context
                        DiaryCalendarPage
                        applyDiaryCalendarOutMsg
                        (DiaryCalendar.init
                            { monthParam = monthParam
                            , today = today
                            }
                        )

                Nothing ->
                    ( LoadingPage, Cmd.none, NoOutMsg )

        GoalSettings ->
            case context.today of
                Just today ->
                    initPage context
                        GoalsSettingsPage
                        applyGoalsSettingsOutMsg
                        (GoalsSettings.init today)

                Nothing ->
                    ( LoadingPage, Cmd.none, NoOutMsg )

        DiarySettings ->
            initPage context
                DiarySettingsPage
                applyDiarySettingsOutMsg
                DiarySettings.init

        FoodSearch dateParam mealSlot ->
            initDiarySearchWorkspace context dateParam mealSlot

        FoodShow productId dateParam mealSlot ->
            initDiarySearchFoodWorkspace context productId dateParam mealSlot

        FoodLogEntry logId dateParam calendarMonth ->
            initDiaryLogWorkspace context logId dateParam calendarMonth

        CustomFoodCreate ->
            initCustomFoodCreateWorkspace context

        CustomFoodEdit productId ->
            initCustomFoodEditWorkspace context productId

        CustomFoodShow productId ->
            initCustomFoodShowWorkspace context productId

        CustomFoodList ->
            initPage context CustomFoodsPage applyCustomFoodsOutMsg CustomFoodList.init

        MealList ->
            initPage context MealsPage applyMealsOutMsg MealList.init

        MealCreate ->
            initMealCreateWorkspace context

        MealEdit mealId ->
            initMealEditWorkspace context mealId

        MealShow mealId ->
            initMealDetailWorkspace context mealId

        _ ->
            ( PlaceholderPage "This route is not migrated yet.", Cmd.none, NoOutMsg )


initPreserving : InitContext -> Model -> ( Model, Cmd Msg, OutMsg )
initPreserving context current =
    case ( context.route, context.today, current ) of
        ( DiaryDay dateParam (Just month), Just today, DiaryCalendarPage calendar ) ->
            initDiaryWithCalendar context today dateParam month calendar

        ( DiaryDay dateParam (Just month), Just today, DiaryCalendarWorkspace calendar _ ) ->
            initDiaryWithCalendar context today dateParam month calendar

        ( FoodSearch dateParam mealSlot, Just today, DiarySearchFoodWorkspace _ search _ ) ->
            initDiarySearchWithModels context today dateParam mealSlot search

        ( FoodSearch _ _, _, SearchFoodWorkspace search _ ) ->
            ( FoodSearchPage search, Cmd.none, NoOutMsg )

        ( FoodSearch dateParam mealSlot, _, DiaryPage diary ) ->
            ( DiarySearchWorkspace diary (FoodSearch.init dateParam mealSlot)
            , initialFoodSearchCmd dateParam mealSlot
            , NoOutMsg
            )

        ( FoodSearch dateParam mealSlot, _, DiaryCalendarWorkspace _ diary ) ->
            ( DiarySearchWorkspace diary (FoodSearch.init dateParam mealSlot)
            , initialFoodSearchCmd dateParam mealSlot
            , NoOutMsg
            )

        ( FoodLogEntry logId _ _, _, DiaryPage diary ) ->
            initLogWithDiary context logId diary

        ( FoodLogEntry logId _ _, _, DiaryCalendarWorkspace calendar diary ) ->
            initLogWithCalendarDiary context logId calendar diary

        ( FoodShow productId dateParam mealSlot, _, DiarySearchWorkspace diary search ) ->
            let
                ( detail, detailOut ) =
                    FoodShow.init productId dateParam mealSlot
            in
            finishInitial
                (DiarySearchFoodWorkspace diary search detail)
                [ applyFoodDetailOutMsg context detailOut ]

        ( FoodShow productId dateParam mealSlot, _, FoodSearchPage search ) ->
            initSearchFood context productId dateParam mealSlot search

        ( FoodShow productId dateParam mealSlot, _, SearchCreateFoodWorkspace search _ ) ->
            initSearchFood context productId dateParam mealSlot search

        ( FoodShow id date slot, _, DiarySearchCreateFoodWorkspace diary search _ ) ->
            let
                ( detail, detailOut ) =
                    FoodShow.init id date slot
            in
            finishInitial
                (DiarySearchFoodWorkspace diary search detail)
                [ applyFoodDetailOutMsg context detailOut ]

        ( FoodShow productId dateParam mealSlot, _, DiarySearchFoodWorkspace diary search _ ) ->
            let
                ( detail, detailOut ) =
                    FoodShow.init productId dateParam mealSlot
            in
            finishInitial
                (DiarySearchFoodWorkspace diary search detail)
                [ applyFoodDetailOutMsg context detailOut ]

        ( CustomFoodCreate, _, FoodSearchPage search ) ->
            initSearchCreateFood context search

        ( CustomFoodCreate, _, DiarySearchWorkspace diary search ) ->
            initDiarySearchCreateFood context diary search

        ( CustomFoodCreate, _, DiarySearchFoodWorkspace diary search _ ) ->
            initDiarySearchCreateFood context diary search

        ( CustomFoodShow productId, _, CustomFoodsPage list ) ->
            initCustomFoodShowWithList context productId list

        ( CustomFoodShow productId, _, CustomFoodShowWorkspace list _ ) ->
            initCustomFoodShowWithList context productId list

        ( CustomFoodEdit productId, _, CustomFoodShowWorkspace list _ ) ->
            initCustomFoodEditWithList context productId list

        ( CustomFoodEdit productId, _, CustomFoodEditWorkspace list _ ) ->
            initCustomFoodEditWithList context productId list

        ( CustomFoodCreate, _, CustomFoodsPage list ) ->
            initCustomFoodCreateWithList context list

        ( MealShow mealId, _, MealsPage list ) ->
            initMealDetailWithList context mealId list

        ( MealShow mealId, _, MealDetailWorkspace list _ ) ->
            initMealDetailWithList context mealId list

        ( MealEdit mealId, _, MealDetailWorkspace list _ ) ->
            initMealEditWithList context mealId list

        ( MealEdit mealId, _, MealEditWorkspace list _ ) ->
            initMealEditWithList context mealId list

        ( MealCreate, _, MealsPage list ) ->
            initMealCreateWithList context list

        ( AdminEditUser userId, _, AdminPage list ) ->
            initAdminEditWithList context userId list

        ( AdminEditUser userId, _, AdminEditUserWorkspace list _ ) ->
            initAdminEditWithList context userId list

        ( AdminCreateUser, _, AdminPage list ) ->
            ( AdminCreateUserWorkspace list AdminCreateUser.init, Cmd.none, NoOutMsg )

        _ ->
            init context


initSearchCreateFood :
    InitContext
    -> FoodSearch.Model
    -> ( Model, Cmd Msg, OutMsg )
initSearchCreateFood context search =
    let
        ( detail, detailOut ) =
            CustomFoodCreate.init
    in
    finishInitial
        (SearchCreateFoodWorkspace search detail)
        [ applyCustomFoodCreateOutMsg context detailOut ]


initSearchFood :
    InitContext
    -> String
    -> Maybe String
    -> Maybe MealSlot
    -> FoodSearch.Model
    -> ( Model, Cmd Msg, OutMsg )
initSearchFood context productId dateParam mealSlot search =
    let
        ( detail, detailOut ) =
            FoodShow.init productId dateParam mealSlot
    in
    finishInitial
        (SearchFoodWorkspace search detail)
        [ applyFoodDetailOutMsg context detailOut ]


initDiarySearchCreateFood :
    InitContext
    -> DiaryDay.Model
    -> FoodSearch.Model
    -> ( Model, Cmd Msg, OutMsg )
initDiarySearchCreateFood context diary search =
    let
        ( detail, detailOut ) =
            CustomFoodCreate.init
    in
    finishInitial
        (DiarySearchCreateFoodWorkspace diary search detail)
        [ applyCustomFoodCreateOutMsg context detailOut ]


initDiarySearchWithModels :
    InitContext
    -> LocalDate
    -> Maybe String
    -> Maybe MealSlot
    -> FoodSearch.Model
    -> ( Model, Cmd Msg, OutMsg )
initDiarySearchWithModels context today dateParam _ search =
    let
        ( diary, diaryOut ) =
            DiaryDay.init
                { dateParam = dateParam
                , calendarMonth = Nothing
                , today = today
                }
    in
    finishInitial
        (DiarySearchWorkspace diary search)
        [ applyDiaryOutMsg context diaryOut ]


initLogWithDiary :
    InitContext
    -> String
    -> DiaryDay.Model
    -> ( Model, Cmd Msg, OutMsg )
initLogWithDiary context logId diary =
    let
        ( detail, detailOut ) =
            FoodLogEntry.init logId
    in
    finishInitial
        (DiaryLogWorkspace diary detail)
        [ applyFoodLogDetailOutMsg context detailOut ]


initLogWithCalendarDiary :
    InitContext
    -> String
    -> DiaryCalendar.Model
    -> DiaryDay.Model
    -> ( Model, Cmd Msg, OutMsg )
initLogWithCalendarDiary context logId calendar diary =
    let
        ( detail, detailOut ) =
            FoodLogEntry.init logId
    in
    finishInitial
        (CalendarDiaryLogWorkspace calendar diary detail)
        [ applyFoodLogDetailOutMsg context detailOut ]


initDiaryWithCalendar :
    InitContext
    -> LocalDate
    -> Maybe String
    -> String
    -> DiaryCalendar.Model
    -> ( Model, Cmd Msg, OutMsg )
initDiaryWithCalendar context today dateParam month calendar =
    let
        ( diary, diaryOut ) =
            DiaryDay.init
                { dateParam = dateParam
                , calendarMonth = Just month
                , today = today
                }
    in
    finishInitial
        (DiaryCalendarWorkspace calendar diary)
        [ applyDiaryOutMsg context diaryOut ]


initCalendarDiaryWorkspace :
    InitContext
    -> LocalDate
    -> Maybe String
    -> String
    -> ( Model, Cmd Msg, OutMsg )
initCalendarDiaryWorkspace context today dateParam month =
    let
        ( calendar, calendarOut ) =
            DiaryCalendar.init { monthParam = Just month, today = today }

        ( diary, diaryOut ) =
            DiaryDay.init
                { dateParam = dateParam
                , calendarMonth = Just month
                , today = today
                }
    in
    finishInitial
        (DiaryCalendarWorkspace calendar diary)
        [ applyDiaryCalendarOutMsg context calendarOut
        , applyDiaryOutMsg context diaryOut
        ]


initDiarySearchWorkspace :
    InitContext
    -> Maybe String
    -> Maybe MealSlot
    -> ( Model, Cmd Msg, OutMsg )
initDiarySearchWorkspace context dateParam mealSlot =
    let
        search : FoodSearch.Model
        search =
            FoodSearch.init dateParam mealSlot
    in
    case ( context.today, dateParam |> Maybe.andThen LocalDate.fromString ) of
        ( Just today, Just _ ) ->
            let
                ( diary, diaryOut ) =
                    DiaryDay.init
                        { dateParam = dateParam
                        , calendarMonth = Nothing
                        , today = today
                        }
            in
            finishInitial
                (DiarySearchWorkspace diary search)
                [ applyDiaryOutMsg context diaryOut
                , ( initialFoodSearchCmd dateParam mealSlot, NoOutMsg )
                ]

        _ ->
            ( FoodSearchPage search
            , initialFoodSearchCmd dateParam mealSlot
            , NoOutMsg
            )


initDiarySearchFoodWorkspace :
    InitContext
    -> String
    -> Maybe String
    -> Maybe MealSlot
    -> ( Model, Cmd Msg, OutMsg )
initDiarySearchFoodWorkspace context productId dateParam mealSlot =
    let
        ( detail, detailOut ) =
            FoodShow.init productId dateParam mealSlot
    in
    case ( context.today, dateParam |> Maybe.andThen LocalDate.fromString ) of
        ( Just today, Just _ ) ->
            let
                ( diary, diaryOut ) =
                    DiaryDay.init
                        { dateParam = dateParam
                        , calendarMonth = Nothing
                        , today = today
                        }
            in
            finishInitial
                (DiarySearchFoodWorkspace
                    diary
                    (FoodSearch.init dateParam mealSlot)
                    detail
                )
                [ applyDiaryOutMsg context diaryOut
                , ( initialFoodSearchCmd dateParam mealSlot, NoOutMsg )
                , applyFoodDetailOutMsg context detailOut
                ]

        _ ->
            initPage context FoodDetailPage applyFoodDetailOutMsg ( detail, detailOut )


initDiaryLogWorkspace :
    InitContext
    -> String
    -> Maybe String
    -> Maybe String
    -> ( Model, Cmd Msg, OutMsg )
initDiaryLogWorkspace context logId dateParam calendarMonth =
    let
        ( detail, detailOut ) =
            FoodLogEntry.init logId
    in
    case ( context.today, dateParam |> Maybe.andThen LocalDate.fromString ) of
        ( Just today, Just _ ) ->
            let
                ( diary, diaryOut ) =
                    DiaryDay.init
                        { dateParam = dateParam
                        , calendarMonth = calendarMonth
                        , today = today
                        }
            in
            case calendarMonth of
                Just month ->
                    let
                        ( calendar, calendarOut ) =
                            DiaryCalendar.init
                                { monthParam = Just month
                                , today = today
                                }
                    in
                    finishInitial
                        (CalendarDiaryLogWorkspace calendar diary detail)
                        [ applyDiaryCalendarOutMsg context calendarOut
                        , applyDiaryOutMsg context diaryOut
                        , applyFoodLogDetailOutMsg context detailOut
                        ]

                Nothing ->
                    finishInitial
                        (DiaryLogWorkspace diary detail)
                        [ applyDiaryOutMsg context diaryOut
                        , applyFoodLogDetailOutMsg context detailOut
                        ]

        _ ->
            initPage context FoodLogDetailPage applyFoodLogDetailOutMsg ( detail, detailOut )


initCustomFoodCreateWorkspace : InitContext -> ( Model, Cmd Msg, OutMsg )
initCustomFoodCreateWorkspace context =
    let
        ( list, listOut ) =
            CustomFoodList.init

        ( detail, detailOut ) =
            CustomFoodCreate.init
    in
    finishInitial
        (CustomFoodCreateWorkspace list detail)
        [ applyCustomFoodsOutMsg context listOut
        , applyCustomFoodCreateOutMsg context detailOut
        ]


initCustomFoodCreateWithList :
    InitContext
    -> CustomFoodList.Model
    -> ( Model, Cmd Msg, OutMsg )
initCustomFoodCreateWithList context list =
    let
        ( detail, detailOut ) =
            CustomFoodCreate.init
    in
    finishInitial
        (CustomFoodCreateWorkspace list detail)
        [ applyCustomFoodCreateOutMsg context detailOut ]


initCustomFoodEditWorkspace : InitContext -> String -> ( Model, Cmd Msg, OutMsg )
initCustomFoodEditWorkspace context productId =
    let
        ( list, listOut ) =
            CustomFoodList.init

        ( detail, detailOut ) =
            CustomFoodEdit.init productId
    in
    finishInitial
        (CustomFoodEditWorkspace list detail)
        [ applyCustomFoodsOutMsg context listOut
        , applyCustomFoodEditOutMsg context detailOut
        ]


initCustomFoodEditWithList :
    InitContext
    -> String
    -> CustomFoodList.Model
    -> ( Model, Cmd Msg, OutMsg )
initCustomFoodEditWithList context productId list =
    let
        ( detail, detailOut ) =
            CustomFoodEdit.init productId
    in
    finishInitial
        (CustomFoodEditWorkspace list detail)
        [ applyCustomFoodEditOutMsg context detailOut ]


initCustomFoodShowWorkspace : InitContext -> String -> ( Model, Cmd Msg, OutMsg )
initCustomFoodShowWorkspace context productId =
    let
        ( list, listOut ) =
            CustomFoodList.init

        ( detail, detailOut ) =
            CustomFoodShow.init productId
    in
    finishInitial
        (CustomFoodShowWorkspace list detail)
        [ applyCustomFoodsOutMsg context listOut
        , applyCustomFoodShowOutMsg context detailOut
        ]


initCustomFoodShowWithList :
    InitContext
    -> String
    -> CustomFoodList.Model
    -> ( Model, Cmd Msg, OutMsg )
initCustomFoodShowWithList context productId list =
    let
        ( detail, detailOut ) =
            CustomFoodShow.init productId
    in
    finishInitial
        (CustomFoodShowWorkspace list detail)
        [ applyCustomFoodShowOutMsg context detailOut ]


initMealCreateWorkspace : InitContext -> ( Model, Cmd Msg, OutMsg )
initMealCreateWorkspace context =
    let
        ( list, listOut ) =
            MealList.init

        ( detail, detailOut ) =
            MealCreate.init
    in
    finishInitial
        (MealCreateWorkspace list detail)
        [ applyMealsOutMsg context listOut
        , applyMealCreateOutMsg context detailOut
        ]


initMealCreateWithList : InitContext -> MealList.Model -> ( Model, Cmd Msg, OutMsg )
initMealCreateWithList context list =
    let
        ( detail, detailOut ) =
            MealCreate.init
    in
    finishInitial
        (MealCreateWorkspace list detail)
        [ applyMealCreateOutMsg context detailOut ]


initMealEditWorkspace : InitContext -> String -> ( Model, Cmd Msg, OutMsg )
initMealEditWorkspace context mealId =
    let
        ( list, listOut ) =
            MealList.init

        ( detail, detailOut ) =
            MealEdit.init mealId
    in
    finishInitial
        (MealEditWorkspace list detail)
        [ applyMealsOutMsg context listOut
        , applyMealEditOutMsg context detailOut
        ]


initMealEditWithList :
    InitContext
    -> String
    -> MealList.Model
    -> ( Model, Cmd Msg, OutMsg )
initMealEditWithList context mealId list =
    let
        ( detail, detailOut ) =
            MealEdit.init mealId
    in
    finishInitial
        (MealEditWorkspace list detail)
        [ applyMealEditOutMsg context detailOut ]


initMealDetailWorkspace : InitContext -> String -> ( Model, Cmd Msg, OutMsg )
initMealDetailWorkspace context mealId =
    let
        ( list, listOut ) =
            MealList.init

        ( detail, detailOut ) =
            MealShow.init mealId
    in
    finishInitial
        (MealDetailWorkspace list detail)
        [ applyMealsOutMsg context listOut
        , applyMealDetailOutMsg context detailOut
        ]


initMealDetailWithList :
    InitContext
    -> String
    -> MealList.Model
    -> ( Model, Cmd Msg, OutMsg )
initMealDetailWithList context mealId list =
    let
        ( detail, detailOut ) =
            MealShow.init mealId
    in
    finishInitial
        (MealDetailWorkspace list detail)
        [ applyMealDetailOutMsg context detailOut ]


initAdminCreateWorkspace : InitContext -> ( Model, Cmd Msg, OutMsg )
initAdminCreateWorkspace context =
    let
        ( list, listOut ) =
            AdminDashboard.init
    in
    finishInitial
        (AdminCreateUserWorkspace list AdminCreateUser.init)
        [ applyAdminOutMsg context listOut ]


initAdminEditWorkspace : InitContext -> String -> ( Model, Cmd Msg, OutMsg )
initAdminEditWorkspace context userId =
    let
        ( list, listOut ) =
            AdminDashboard.init

        ( detail, detailOut ) =
            AdminEditUser.init userId
    in
    finishInitial
        (AdminEditUserWorkspace list detail)
        [ applyAdminOutMsg context listOut
        , applyAdminEditUserOutMsg context detailOut
        ]


initAdminEditWithList :
    InitContext
    -> String
    -> AdminDashboard.Model
    -> ( Model, Cmd Msg, OutMsg )
initAdminEditWithList context userId list =
    let
        ( detail, detailOut ) =
            AdminEditUser.init userId
    in
    finishInitial
        (AdminEditUserWorkspace list detail)
        [ applyAdminEditUserOutMsg context detailOut ]


initialFoodSearchCmd : Maybe String -> Maybe MealSlot -> Cmd Msg
initialFoodSearchCmd dateParam mealSlot =
    case recentItemsRequest dateParam mealSlot of
        Just request ->
            Api.Logs.recentItems
                request
                (GotFoodSearchMsg << FoodSearch.RecentItemsLoaded)

        Nothing ->
            Cmd.none


finishInitial : Model -> List ( Cmd Msg, OutMsg ) -> ( Model, Cmd Msg, OutMsg )
finishInitial model results =
    ( model
    , results |> List.map Tuple.first |> Cmd.batch
    , results
        |> List.map Tuple.second
        |> List.foldl preferOutMsg NoOutMsg
    )


preferOutMsg : OutMsg -> OutMsg -> OutMsg
preferOutMsg candidate current =
    case candidate of
        NoOutMsg ->
            current

        _ ->
            candidate



-- UPDATE


type Msg
    = GotLoginMsg AuthLogin.Msg
    | GotSetupMsg BootstrapSetup.Msg
    | GotAdminMsg AdminDashboard.Msg
    | GotAdminCreateUserMsg AdminCreateUser.Msg
    | GotAdminEditUserMsg AdminEditUser.Msg
    | GotDiaryMsg DiaryDay.Msg
    | GotDiaryCalendarMsg DiaryCalendar.Msg
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
    case msg of
        GotLoginMsg subMsg ->
            case model of
                LoginPage sub ->
                    Just
                        (stepPage context
                            LoginPage
                            GotLoginMsg
                            applyLoginOutMsg
                            (AuthLogin.update subMsg sub)
                        )

                _ ->
                    Nothing

        GotSetupMsg subMsg ->
            case model of
                SetupPage sub ->
                    Just
                        (stepPage context
                            SetupPage
                            GotSetupMsg
                            applySetupOutMsg
                            (BootstrapSetup.update subMsg sub)
                        )

                _ ->
                    Nothing

        GotAdminMsg subMsg ->
            case model of
                AdminPage sub ->
                    Just
                        (stepPage context
                            AdminPage
                            GotAdminMsg
                            applyAdminOutMsg
                            (AdminDashboard.update subMsg sub)
                        )

                AdminCreateUserWorkspace list detail ->
                    embeddedStep
                        context
                        GotAdminMsg
                        applyAdminOutMsg
                        (AdminDashboard.update subMsg list)
                        |> mapEmbedded (\next -> AdminCreateUserWorkspace next detail)

                AdminEditUserWorkspace list detail ->
                    embeddedStep
                        context
                        GotAdminMsg
                        applyAdminOutMsg
                        (AdminDashboard.update subMsg list)
                        |> mapEmbedded (\next -> AdminEditUserWorkspace next detail)

                _ ->
                    Nothing

        GotAdminCreateUserMsg subMsg ->
            case model of
                AdminCreateUserWorkspace list detail ->
                    embeddedStep
                        context
                        GotAdminCreateUserMsg
                        applyAdminCreateUserOutMsg
                        (AdminCreateUser.update subMsg detail)
                        |> mapEmbedded (AdminCreateUserWorkspace list)

                _ ->
                    Nothing

        GotAdminEditUserMsg subMsg ->
            case model of
                AdminEditUserWorkspace list detail ->
                    embeddedStep
                        context
                        GotAdminEditUserMsg
                        applyAdminEditUserOutMsg
                        (AdminEditUser.update subMsg detail)
                        |> mapEmbedded (AdminEditUserWorkspace list)

                _ ->
                    Nothing

        GotDiaryMsg subMsg ->
            case model of
                DiaryPage sub ->
                    Just
                        (stepPage context
                            DiaryPage
                            GotDiaryMsg
                            applyDiaryOutMsg
                            (DiaryDay.update subMsg sub)
                        )

                DiaryCalendarWorkspace calendar diary ->
                    embeddedStep
                        context
                        GotDiaryMsg
                        applyDiaryOutMsg
                        (DiaryDay.update subMsg diary)
                        |> mapEmbedded (DiaryCalendarWorkspace calendar)

                DiarySearchWorkspace diary search ->
                    embeddedStep
                        context
                        GotDiaryMsg
                        applyDiaryOutMsg
                        (DiaryDay.update subMsg diary)
                        |> mapEmbedded (\next -> DiarySearchWorkspace next search)

                DiarySearchFoodWorkspace diary search detail ->
                    embeddedStep
                        context
                        GotDiaryMsg
                        applyDiaryOutMsg
                        (DiaryDay.update subMsg diary)
                        |> mapEmbedded (\next -> DiarySearchFoodWorkspace next search detail)

                DiarySearchCreateFoodWorkspace diary search detail ->
                    embeddedStep
                        context
                        GotDiaryMsg
                        applyDiaryOutMsg
                        (DiaryDay.update subMsg diary)
                        |> mapEmbedded
                            (\next -> DiarySearchCreateFoodWorkspace next search detail)

                DiaryLogWorkspace diary detail ->
                    embeddedStep
                        context
                        GotDiaryMsg
                        applyDiaryOutMsg
                        (DiaryDay.update subMsg diary)
                        |> mapEmbedded (\next -> DiaryLogWorkspace next detail)

                CalendarDiaryLogWorkspace calendar diary detail ->
                    embeddedStep
                        context
                        GotDiaryMsg
                        applyDiaryOutMsg
                        (DiaryDay.update subMsg diary)
                        |> mapEmbedded
                            (\next -> CalendarDiaryLogWorkspace calendar next detail)

                _ ->
                    Nothing

        GotDiaryCalendarMsg subMsg ->
            case model of
                DiaryCalendarPage sub ->
                    Just
                        (stepPage context
                            DiaryCalendarPage
                            GotDiaryCalendarMsg
                            applyDiaryCalendarOutMsg
                            (DiaryCalendar.update subMsg sub)
                        )

                DiaryCalendarWorkspace calendar diary ->
                    embeddedStep
                        context
                        GotDiaryCalendarMsg
                        applyDiaryCalendarOutMsg
                        (DiaryCalendar.update subMsg calendar)
                        |> mapEmbedded (\next -> DiaryCalendarWorkspace next diary)

                CalendarDiaryLogWorkspace calendar diary detail ->
                    embeddedStep
                        context
                        GotDiaryCalendarMsg
                        applyDiaryCalendarOutMsg
                        (DiaryCalendar.update subMsg calendar)
                        |> mapEmbedded
                            (\next -> CalendarDiaryLogWorkspace next diary detail)

                _ ->
                    Nothing

        GotGoalsSettingsMsg subMsg ->
            case model of
                GoalsSettingsPage sub ->
                    Just
                        (stepPage context
                            GoalsSettingsPage
                            GotGoalsSettingsMsg
                            applyGoalsSettingsOutMsg
                            (GoalsSettings.update subMsg sub)
                        )

                _ ->
                    Nothing

        GotDiarySettingsMsg subMsg ->
            case model of
                DiarySettingsPage sub ->
                    Just
                        (stepPage context
                            DiarySettingsPage
                            GotDiarySettingsMsg
                            applyDiarySettingsOutMsg
                            (DiarySettings.update subMsg sub)
                        )

                _ ->
                    Nothing

        GotFoodSearchMsg subMsg ->
            case model of
                FoodSearchPage sub ->
                    Just
                        (stepPage context
                            FoodSearchPage
                            GotFoodSearchMsg
                            applyFoodSearchOutMsg
                            (FoodSearch.update subMsg sub)
                        )

                DiarySearchWorkspace diary search ->
                    stepDiarySearch
                        context
                        subMsg
                        diary
                        search
                        DiarySearchWorkspace

                SearchFoodWorkspace search detail ->
                    embeddedStep
                        context
                        GotFoodSearchMsg
                        applyFoodSearchOutMsg
                        (FoodSearch.update subMsg search)
                        |> mapEmbedded (\next -> SearchFoodWorkspace next detail)

                DiarySearchFoodWorkspace diary search detail ->
                    stepDiarySearch
                        context
                        subMsg
                        diary
                        search
                        (\nextDiary nextSearch ->
                            DiarySearchFoodWorkspace nextDiary nextSearch detail
                        )

                SearchCreateFoodWorkspace search detail ->
                    embeddedStep
                        context
                        GotFoodSearchMsg
                        applyFoodSearchOutMsg
                        (FoodSearch.update subMsg search)
                        |> mapEmbedded (\next -> SearchCreateFoodWorkspace next detail)

                DiarySearchCreateFoodWorkspace diary search detail ->
                    stepDiarySearch
                        context
                        subMsg
                        diary
                        search
                        (\nextDiary nextSearch ->
                            DiarySearchCreateFoodWorkspace nextDiary nextSearch detail
                        )

                _ ->
                    Nothing

        GotFoodDetailMsg subMsg ->
            stepFoodDetail context subMsg model

        GotFoodLogDetailMsg subMsg ->
            case model of
                FoodLogDetailPage sub ->
                    Just
                        (stepPage context
                            FoodLogDetailPage
                            GotFoodLogDetailMsg
                            applyFoodLogDetailOutMsg
                            (FoodLogEntry.update subMsg sub)
                        )

                DiaryLogWorkspace diary detail ->
                    embeddedStep
                        context
                        GotFoodLogDetailMsg
                        applyFoodLogDetailOutMsg
                        (FoodLogEntry.update subMsg detail)
                        |> mapEmbedded (DiaryLogWorkspace diary)

                CalendarDiaryLogWorkspace calendar diary detail ->
                    embeddedStep
                        context
                        GotFoodLogDetailMsg
                        applyFoodLogDetailOutMsg
                        (FoodLogEntry.update subMsg detail)
                        |> mapEmbedded (CalendarDiaryLogWorkspace calendar diary)

                _ ->
                    Nothing

        GotCustomFoodCreateMsg subMsg ->
            case model of
                CustomFoodCreateWorkspace list detail ->
                    embeddedStep
                        context
                        GotCustomFoodCreateMsg
                        applyCustomFoodCreateOutMsg
                        (CustomFoodCreate.update subMsg detail)
                        |> mapEmbedded (CustomFoodCreateWorkspace list)

                SearchCreateFoodWorkspace search detail ->
                    embeddedStep
                        context
                        GotCustomFoodCreateMsg
                        (applySearchCreateFoodOutMsg search)
                        (CustomFoodCreate.update subMsg detail)
                        |> mapEmbedded (SearchCreateFoodWorkspace search)

                DiarySearchCreateFoodWorkspace diary search detail ->
                    embeddedStep
                        context
                        GotCustomFoodCreateMsg
                        (applySearchCreateFoodOutMsg search)
                        (CustomFoodCreate.update subMsg detail)
                        |> mapEmbedded (DiarySearchCreateFoodWorkspace diary search)

                _ ->
                    Nothing

        GotCustomFoodEditMsg subMsg ->
            case model of
                CustomFoodEditWorkspace list detail ->
                    embeddedStep
                        context
                        GotCustomFoodEditMsg
                        applyCustomFoodEditOutMsg
                        (CustomFoodEdit.update subMsg detail)
                        |> mapEmbedded (CustomFoodEditWorkspace list)

                _ ->
                    Nothing

        GotCustomFoodsMsg subMsg ->
            case model of
                CustomFoodsPage sub ->
                    Just
                        (stepPage context
                            CustomFoodsPage
                            GotCustomFoodsMsg
                            applyCustomFoodsOutMsg
                            (CustomFoodList.update subMsg sub)
                        )

                CustomFoodCreateWorkspace list detail ->
                    embeddedStep
                        context
                        GotCustomFoodsMsg
                        applyCustomFoodsOutMsg
                        (CustomFoodList.update subMsg list)
                        |> mapEmbedded (\next -> CustomFoodCreateWorkspace next detail)

                CustomFoodEditWorkspace list detail ->
                    embeddedStep
                        context
                        GotCustomFoodsMsg
                        applyCustomFoodsOutMsg
                        (CustomFoodList.update subMsg list)
                        |> mapEmbedded (\next -> CustomFoodEditWorkspace next detail)

                CustomFoodShowWorkspace list detail ->
                    embeddedStep
                        context
                        GotCustomFoodsMsg
                        applyCustomFoodsOutMsg
                        (CustomFoodList.update subMsg list)
                        |> mapEmbedded (\next -> CustomFoodShowWorkspace next detail)

                _ ->
                    Nothing

        GotCustomFoodShowMsg subMsg ->
            case model of
                CustomFoodShowWorkspace list detail ->
                    embeddedStep
                        context
                        GotCustomFoodShowMsg
                        applyCustomFoodShowOutMsg
                        (CustomFoodShow.update subMsg detail)
                        |> mapEmbedded (CustomFoodShowWorkspace list)

                _ ->
                    Nothing

        GotMealsMsg subMsg ->
            case model of
                MealsPage sub ->
                    Just
                        (stepPage context
                            MealsPage
                            GotMealsMsg
                            applyMealsOutMsg
                            (MealList.update subMsg sub)
                        )

                MealCreateWorkspace list detail ->
                    embeddedStep
                        context
                        GotMealsMsg
                        applyMealsOutMsg
                        (MealList.update subMsg list)
                        |> mapEmbedded (\next -> MealCreateWorkspace next detail)

                MealEditWorkspace list detail ->
                    embeddedStep
                        context
                        GotMealsMsg
                        applyMealsOutMsg
                        (MealList.update subMsg list)
                        |> mapEmbedded (\next -> MealEditWorkspace next detail)

                MealDetailWorkspace list detail ->
                    embeddedStep
                        context
                        GotMealsMsg
                        applyMealsOutMsg
                        (MealList.update subMsg list)
                        |> mapEmbedded (\next -> MealDetailWorkspace next detail)

                _ ->
                    Nothing

        GotMealCreateMsg subMsg ->
            case model of
                MealCreateWorkspace list detail ->
                    embeddedStep
                        context
                        GotMealCreateMsg
                        applyMealCreateOutMsg
                        (MealCreate.update subMsg detail)
                        |> mapEmbedded (MealCreateWorkspace list)

                _ ->
                    Nothing

        GotMealEditMsg subMsg ->
            case model of
                MealEditWorkspace list detail ->
                    embeddedStep
                        context
                        GotMealEditMsg
                        applyMealEditOutMsg
                        (MealEdit.update subMsg detail)
                        |> mapEmbedded (MealEditWorkspace list)

                _ ->
                    Nothing

        GotMealDetailMsg subMsg ->
            case model of
                MealDetailWorkspace list detail ->
                    embeddedStep
                        context
                        GotMealDetailMsg
                        applyMealDetailOutMsg
                        (MealShow.update subMsg detail)
                        |> mapEmbedded (MealDetailWorkspace list)

                _ ->
                    Nothing


localContextReceived :
    InitContext
    -> { date : String, timezone : String }
    -> Model
    -> Maybe ( Model, Cmd Msg, OutMsg )
localContextReceived pageContext context model =
    case model of
        FoodDetailPage _ ->
            stepFoodDetail pageContext (FoodShow.LocalContextReceived context) model

        SearchFoodWorkspace _ _ ->
            stepFoodDetail pageContext (FoodShow.LocalContextReceived context) model

        DiarySearchFoodWorkspace _ _ _ ->
            stepFoodDetail pageContext (FoodShow.LocalContextReceived context) model

        FoodSearchPage sub ->
            Just
                (stepPage pageContext
                    FoodSearchPage
                    GotFoodSearchMsg
                    applyFoodSearchOutMsg
                    (FoodSearch.update (FoodSearch.LocalContextReceived context) sub)
                )

        DiarySearchWorkspace diary search ->
            embeddedStep
                pageContext
                GotFoodSearchMsg
                applyFoodSearchOutMsg
                (FoodSearch.update (FoodSearch.LocalContextReceived context) search)
                |> mapEmbedded (DiarySearchWorkspace diary)

        GoalsSettingsPage sub ->
            Just
                (stepPage pageContext
                    GoalsSettingsPage
                    GotGoalsSettingsMsg
                    applyGoalsSettingsOutMsg
                    (GoalsSettings.update (GoalsSettings.LocalContextReceived context) sub)
                )

        _ ->
            Nothing


barcodeScannerEventReceived :
    InitContext
    -> { event : String, barcode : Maybe String, message : Maybe String }
    -> Model
    -> Maybe ( Model, Cmd Msg, OutMsg )
barcodeScannerEventReceived pageContext event model =
    case model of
        FoodSearchPage sub ->
            Just
                (stepPage pageContext
                    FoodSearchPage
                    GotFoodSearchMsg
                    applyFoodSearchOutMsg
                    (FoodSearch.update (FoodSearch.BarcodeScannerEventReceived event) sub)
                )

        DiarySearchWorkspace diary search ->
            embeddedStep
                pageContext
                GotFoodSearchMsg
                applyFoodSearchOutMsg
                (FoodSearch.update (FoodSearch.BarcodeScannerEventReceived event) search)
                |> mapEmbedded (DiarySearchWorkspace diary)

        DiarySearchFoodWorkspace diary search detail ->
            embeddedStep
                pageContext
                GotFoodSearchMsg
                applyFoodSearchOutMsg
                (FoodSearch.update (FoodSearch.BarcodeScannerEventReceived event) search)
                |> mapEmbedded (\next -> DiarySearchFoodWorkspace diary next detail)

        _ ->
            Nothing


stepFoodDetail : InitContext -> FoodShow.Msg -> Model -> Maybe ( Model, Cmd Msg, OutMsg )
stepFoodDetail context subMsg model =
    case model of
        FoodDetailPage sub ->
            Just
                (stepPage context
                    FoodDetailPage
                    GotFoodDetailMsg
                    applyFoodDetailOutMsg
                    (FoodShow.update subMsg sub)
                )

        SearchFoodWorkspace search detail ->
            embeddedStep
                context
                GotFoodDetailMsg
                applyFoodDetailOutMsg
                (FoodShow.update subMsg detail)
                |> mapEmbedded (SearchFoodWorkspace search)

        DiarySearchFoodWorkspace diary search detail ->
            embeddedStep
                context
                GotFoodDetailMsg
                applyFoodDetailOutMsg
                (FoodShow.update subMsg detail)
                |> mapEmbedded (DiarySearchFoodWorkspace diary search)

        _ ->
            Nothing


stepDiarySearch :
    InitContext
    -> FoodSearch.Msg
    -> DiaryDay.Model
    -> FoodSearch.Model
    -> (DiaryDay.Model -> FoodSearch.Model -> Model)
    -> Maybe ( Model, Cmd Msg, OutMsg )
stepDiarySearch context subMsg diary search toPage =
    let
        ( nextSearch, searchSubCmd, searchOut ) =
            FoodSearch.update subMsg search

        ( searchCmd, searchAppOut ) =
            applyFoodSearchOutMsg context searchOut
    in
    case subMsg of
        FoodSearch.QuickAddCompleted (Ok _) ->
            let
                ( nextDiary, diaryOut ) =
                    DiaryDay.init
                        { dateParam = Just (LocalDate.format diary.currentDate)
                        , calendarMonth = diary.calendarMonth
                        , today = diary.today
                        }

                ( diaryCmd, diaryAppOut ) =
                    applyDiaryOutMsg context diaryOut
            in
            Just
                ( toPage nextDiary nextSearch
                , Cmd.batch
                    [ Cmd.map GotFoodSearchMsg searchSubCmd
                    , searchCmd
                    , diaryCmd
                    ]
                , preferOutMsg diaryAppOut searchAppOut
                )

        _ ->
            Just
                ( toPage diary nextSearch
                , Cmd.batch [ Cmd.map GotFoodSearchMsg searchSubCmd, searchCmd ]
                , searchAppOut
                )


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

        DiaryDay.RequestDiaryData date ->
            ( Cmd.batch
                (Cmd.map GotDiaryMsg
                    (Api.Logs.listLogs date (DiaryDay.LogsLoaded date))
                    :: Cmd.map GotDiaryMsg
                        (Api.Goals.getGoal date (DiaryDay.GoalLoaded date))
                    :: Cmd.map GotDiaryMsg
                        (Api.DiaryPreferences.get DiaryDay.PreferencesLoaded)
                    :: latestSlotRequests date
                )
            , NoOutMsg
            )

        DiaryDay.RequestCopyLatestSlot date requests ->
            ( Api.Logs.createLogsBatch
                requests
                (GotDiaryMsg << DiaryDay.CopyLatestCompleted date)
            , NoOutMsg
            )

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

        DiaryCalendar.Navigate route ->
            ( Cmd.none, Navigate route )

        DiaryCalendar.SessionExpired ->
            ( Cmd.none, SessionExpired )


latestSlotRequests : LocalDate -> List (Cmd Msg)
latestSlotRequests date =
    MealSlot.all
        |> List.map
            (\slot ->
                Cmd.map GotDiaryMsg
                    (Api.Logs.latestSlot
                        { mealSlot = MealSlot.toString slot
                        , before = date
                        , lookbackDays = 30
                        }
                        (DiaryDay.LatestSlotLoaded date slot)
                    )
            )


applyDiarySettingsOutMsg : InitContext -> DiarySettings.OutMsg -> ( Cmd Msg, OutMsg )
applyDiarySettingsOutMsg _ outMsg =
    case outMsg of
        DiarySettings.NoOp ->
            ( Cmd.none, NoOutMsg )

        DiarySettings.RequestPreferences ->
            ( Api.DiaryPreferences.get
                (GotDiarySettingsMsg << DiarySettings.PreferencesLoaded)
            , NoOutMsg
            )

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

        GoalsSettings.RequestGoal date ->
            ( Api.Goals.getGoal date
                (GotGoalsSettingsMsg << GoalsSettings.GoalLoaded)
            , NoOutMsg
            )

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
                ([ Api.Foods.getFoodDetail productId
                    (GotFoodDetailMsg << FoodShow.FoodLoaded)
                 , Api.Foods.listUnits (GotFoodDetailMsg << FoodShow.UnitsLoaded)
                 ]
                    ++ lastUsedProductDefaultCmd context.route productId
                )
            , NoOutMsg
            )

        FoodShow.RequestLocalContext ->
            ( Cmd.none, RequestLocalContext )

        FoodShow.RequestCreateLog request ->
            ( Api.Logs.createLog request (GotFoodDetailMsg << FoodShow.LogCompleted)
            , NoOutMsg
            )

        FoodShow.Navigate route ->
            ( Cmd.none, Navigate route )

        FoodShow.SessionExpired ->
            ( Cmd.none, SessionExpired )


applyFoodLogDetailOutMsg : InitContext -> FoodLogEntry.OutMsg -> ( Cmd Msg, OutMsg )
applyFoodLogDetailOutMsg _ outMsg =
    case outMsg of
        FoodLogEntry.NoOp ->
            ( Cmd.none, NoOutMsg )

        FoodLogEntry.RequestInitialData logId ->
            ( Cmd.batch
                [ Api.Logs.getLog logId
                    (GotFoodLogDetailMsg << FoodLogEntry.LogLoaded)
                , Api.Foods.listUnits
                    (GotFoodLogDetailMsg << FoodLogEntry.UnitsLoaded)
                ]
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

        FoodLogEntry.Navigate route ->
            ( Cmd.none, Navigate route )

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
            ( Cmd.batch
                [ Api.Foods.listNutrients
                    (GotCustomFoodCreateMsg << CustomFoodCreate.NutrientsLoaded)
                , Api.Foods.listUnits
                    (GotCustomFoodCreateMsg << CustomFoodCreate.UnitsLoaded)
                ]
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

        CustomFoodCreate.Navigate route ->
            ( Cmd.none, Navigate route )

        CustomFoodCreate.SessionExpired ->
            ( Cmd.none, SessionExpired )


applySearchCreateFoodOutMsg :
    FoodSearch.Model
    -> InitContext
    -> CustomFoodCreate.OutMsg
    -> ( Cmd Msg, OutMsg )
applySearchCreateFoodOutMsg search context outMsg =
    case outMsg of
        CustomFoodCreate.Navigate (CustomFoodShow productId) ->
            ( Cmd.none
            , Navigate (FoodShow productId search.date search.mealSlot)
            )

        _ ->
            applyCustomFoodCreateOutMsg context outMsg


applyCustomFoodEditOutMsg : InitContext -> CustomFoodEdit.OutMsg -> ( Cmd Msg, OutMsg )
applyCustomFoodEditOutMsg _ outMsg =
    case outMsg of
        CustomFoodEdit.NoOp ->
            ( Cmd.none, NoOutMsg )

        CustomFoodEdit.RequestInitialData productId ->
            ( Cmd.batch
                [ Api.Foods.getFoodDetail productId
                    (GotCustomFoodEditMsg << CustomFoodEdit.FoodLoaded)
                , Api.Foods.listNutrients
                    (GotCustomFoodEditMsg << CustomFoodEdit.NutrientsLoaded)
                , Api.Foods.listUnits
                    (GotCustomFoodEditMsg << CustomFoodEdit.UnitsLoaded)
                ]
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
            ( Cmd.batch
                [ Api.Foods.getFoodDetail productId
                    (GotCustomFoodShowMsg << CustomFoodShow.FoodLoaded)
                , Api.Foods.listUnits
                    (GotCustomFoodShowMsg << CustomFoodShow.UnitsLoaded)
                ]
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
                , Api.Foods.listUnits (GotMealDetailMsg << MealShow.UnitsLoaded)
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
    case props.model of
        LoadingPage ->
            Ui.skeletonLoading props.theme

        LoginPage loginModel ->
            Element.map GotLoginMsg (AuthLogin.view (pageProps props loginModel))

        SetupPage setupModel ->
            Element.map GotSetupMsg (BootstrapSetup.view (pageProps props setupModel))

        AdminPage adminModel ->
            Element.map GotAdminMsg (AdminDashboard.view (pageProps props adminModel))

        AdminCreateUserWorkspace adminModel createUserModel ->
            Workspace.view props.device
                [ Element.map GotAdminMsg (AdminDashboard.contentView (pageProps props adminModel))
                , Element.map GotAdminCreateUserMsg
                    (AdminCreateUser.view (pageProps props createUserModel))
                ]

        AdminEditUserWorkspace adminModel editUserModel ->
            Workspace.view props.device
                [ Element.map GotAdminMsg (AdminDashboard.contentView (pageProps props adminModel))
                , Element.map GotAdminEditUserMsg
                    (AdminEditUser.view (pageProps props editUserModel))
                ]

        DiaryPage diaryModel ->
            Element.map GotDiaryMsg (DiaryDay.view (pageProps props diaryModel))

        DiaryCalendarPage diaryCalendarModel ->
            Element.map GotDiaryCalendarMsg
                (DiaryCalendar.view (pageProps props diaryCalendarModel))

        DiaryCalendarWorkspace calendarModel diaryModel ->
            Workspace.view props.device
                [ Element.map GotDiaryCalendarMsg
                    (DiaryCalendar.contentViewWithSelection
                        (Just (LocalDate.format diaryModel.currentDate))
                        (pageProps props calendarModel)
                    )
                , Element.map GotDiaryMsg (DiaryDay.contentView (pageProps props diaryModel))
                ]

        GoalsSettingsPage goalsSettingsModel ->
            Element.map GotGoalsSettingsMsg
                (GoalsSettings.view (pageProps props goalsSettingsModel))

        DiarySettingsPage diarySettingsModel ->
            Element.map GotDiarySettingsMsg
                (DiarySettings.view (pageProps props diarySettingsModel))

        FoodSearchPage foodSearchModel ->
            Element.map GotFoodSearchMsg (FoodSearch.view (pageProps props foodSearchModel))

        DiarySearchWorkspace diaryModel searchModel ->
            Workspace.view props.device
                [ Element.map GotDiaryMsg (DiaryDay.contentView (pageProps props diaryModel))
                , Element.map GotFoodSearchMsg
                    (FoodSearch.contentView (pageProps props searchModel))
                ]

        FoodDetailPage foodDetailModel ->
            Element.map GotFoodDetailMsg (FoodShow.view (pageProps props foodDetailModel))

        SearchFoodWorkspace searchModel foodModel ->
            Workspace.view props.device
                [ Element.map GotFoodSearchMsg
                    (FoodSearch.contentView (pageProps props searchModel))
                , Element.map GotFoodDetailMsg (FoodShow.contentView (pageProps props foodModel))
                ]

        DiarySearchFoodWorkspace diaryModel searchModel foodModel ->
            Workspace.view props.device
                [ Element.map GotDiaryMsg (DiaryDay.contentView (pageProps props diaryModel))
                , Element.map GotFoodSearchMsg
                    (FoodSearch.contentView (pageProps props searchModel))
                , Element.map GotFoodDetailMsg (FoodShow.contentView (pageProps props foodModel))
                ]

        SearchCreateFoodWorkspace searchModel createModel ->
            Workspace.view props.device
                [ Element.map GotFoodSearchMsg
                    (FoodSearch.contentView (pageProps props searchModel))
                , Element.map GotCustomFoodCreateMsg
                    (CustomFoodCreate.view (pageProps props createModel))
                ]

        DiarySearchCreateFoodWorkspace diaryModel searchModel createModel ->
            Workspace.view props.device
                [ Element.map GotDiaryMsg (DiaryDay.contentView (pageProps props diaryModel))
                , Element.map GotFoodSearchMsg
                    (FoodSearch.contentView (pageProps props searchModel))
                , Element.map GotCustomFoodCreateMsg
                    (CustomFoodCreate.view (pageProps props createModel))
                ]

        FoodLogDetailPage foodLogDetailModel ->
            Element.map GotFoodLogDetailMsg (FoodLogEntry.view (pageProps props foodLogDetailModel))

        DiaryLogWorkspace diaryModel logModel ->
            Workspace.view props.device
                [ Element.map GotDiaryMsg (DiaryDay.contentView (pageProps props diaryModel))
                , Element.map GotFoodLogDetailMsg
                    (FoodLogEntry.contentView (pageProps props logModel))
                ]

        CalendarDiaryLogWorkspace calendarModel diaryModel logModel ->
            Workspace.view props.device
                [ Element.map GotDiaryCalendarMsg
                    (DiaryCalendar.contentViewWithSelection
                        (Just (LocalDate.format diaryModel.currentDate))
                        (pageProps props calendarModel)
                    )
                , Element.map GotDiaryMsg (DiaryDay.contentView (pageProps props diaryModel))
                , Element.map GotFoodLogDetailMsg
                    (FoodLogEntry.contentView (pageProps props logModel))
                ]

        CustomFoodCreateWorkspace listModel createModel ->
            Workspace.view props.device
                [ Element.map GotCustomFoodsMsg
                    (CustomFoodList.contentView (pageProps props listModel))
                , Element.map GotCustomFoodCreateMsg
                    (CustomFoodCreate.view (pageProps props createModel))
                ]

        CustomFoodEditWorkspace listModel editModel ->
            Workspace.view props.device
                [ Element.map GotCustomFoodsMsg
                    (CustomFoodList.contentView (pageProps props listModel))
                , Element.map GotCustomFoodEditMsg
                    (CustomFoodEdit.view (pageProps props editModel))
                ]

        CustomFoodShowWorkspace listModel showModel ->
            Workspace.view props.device
                [ Element.map GotCustomFoodsMsg
                    (CustomFoodList.contentView (pageProps props listModel))
                , Element.map GotCustomFoodShowMsg
                    (CustomFoodShow.view (pageProps props showModel))
                ]

        CustomFoodsPage customFoodsModel ->
            Element.map GotCustomFoodsMsg (CustomFoodList.view (pageProps props customFoodsModel))

        MealsPage mealsModel ->
            Element.map GotMealsMsg (MealList.view (pageProps props mealsModel))

        MealCreateWorkspace listModel createModel ->
            Workspace.view props.device
                [ Element.map GotMealsMsg (MealList.contentView (pageProps props listModel))
                , Element.map GotMealCreateMsg (MealCreate.view (pageProps props createModel))
                ]

        MealEditWorkspace listModel editModel ->
            Workspace.view props.device
                [ Element.map GotMealsMsg (MealList.contentView (pageProps props listModel))
                , Element.map GotMealEditMsg (MealEdit.view (pageProps props editModel))
                ]

        MealDetailWorkspace listModel detailModel ->
            Workspace.view props.device
                [ Element.map GotMealsMsg (MealList.contentView (pageProps props listModel))
                , Element.map GotMealDetailMsg (MealShow.view (pageProps props detailModel))
                ]

        PlaceholderPage message ->
            Element.el [ Element.padding DesignTokens.space24 ] (Element.text message)


modalView : { model : Model, device : Device, theme : Theme } -> Maybe (Element Msg)
modalView props =
    case props.model of
        FoodLogDetailPage foodLogDetailModel ->
            FoodLogEntry.modalView (pageProps props foodLogDetailModel)
                |> Maybe.map (Element.map GotFoodLogDetailMsg)

        DiaryLogWorkspace _ foodLogDetailModel ->
            FoodLogEntry.modalView (pageProps props foodLogDetailModel)
                |> Maybe.map (Element.map GotFoodLogDetailMsg)

        CalendarDiaryLogWorkspace _ _ foodLogDetailModel ->
            FoodLogEntry.modalView (pageProps props foodLogDetailModel)
                |> Maybe.map (Element.map GotFoodLogDetailMsg)

        CustomFoodShowWorkspace _ customFoodShowModel ->
            CustomFoodShow.modalView (pageProps props customFoodShowModel)
                |> Maybe.map (Element.map GotCustomFoodShowMsg)

        MealDetailWorkspace _ mealDetailModel ->
            MealShow.modalView (pageProps props mealDetailModel)
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


initPage :
    InitContext
    -> (subModel -> Model)
    -> (InitContext -> outMsg -> ( Cmd Msg, OutMsg ))
    -> ( subModel, outMsg )
    -> ( Model, Cmd Msg, OutMsg )
initPage context toPage applyOut ( subModel, outMsg ) =
    let
        ( cmd, appOutMsg ) =
            applyOut context outMsg
    in
    ( toPage subModel, cmd, appOutMsg )


stepPage :
    InitContext
    -> (subModel -> Model)
    -> (subMsg -> Msg)
    -> (InitContext -> outMsg -> ( Cmd Msg, OutMsg ))
    -> ( subModel, Cmd subMsg, outMsg )
    -> ( Model, Cmd Msg, OutMsg )
stepPage context toPage toMsg applyOut ( subModel, subCmd, outMsg ) =
    let
        ( outCmd, appOutMsg ) =
            applyOut context outMsg
    in
    ( toPage subModel, Cmd.batch [ Cmd.map toMsg subCmd, outCmd ], appOutMsg )


embeddedStep :
    InitContext
    -> (subMsg -> Msg)
    -> (InitContext -> outMsg -> ( Cmd Msg, OutMsg ))
    -> ( subModel, Cmd subMsg, outMsg )
    -> ( subModel, Cmd Msg, OutMsg )
embeddedStep context toMsg applyOut ( subModel, subCmd, outMsg ) =
    let
        ( outCmd, appOutMsg ) =
            applyOut context outMsg
    in
    ( subModel, Cmd.batch [ Cmd.map toMsg subCmd, outCmd ], appOutMsg )


mapEmbedded :
    (subModel -> Model)
    -> ( subModel, Cmd Msg, OutMsg )
    -> Maybe ( Model, Cmd Msg, OutMsg )
mapEmbedded toPage ( subModel, cmd, outMsg ) =
    Just ( toPage subModel, cmd, outMsg )


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
