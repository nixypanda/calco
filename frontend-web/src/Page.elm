module Page exposing
    ( InitContext
    , Model(..)
    , Msg(..)
    , OutMsg(..)
    , barcodeScannerEventReceived
    , init
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



-- MODEL


type Model
    = LoadingPage
    | LoginPage AuthLogin.Model
    | SetupPage BootstrapSetup.Model
    | AdminPage AdminDashboard.Model
    | AdminCreateUserPage AdminCreateUser.Model
    | AdminEditUserPage AdminEditUser.Model
    | DiaryPage DiaryDay.Model
    | GoalsSettingsPage GoalsSettings.Model
    | DiarySettingsPage DiarySettings.Model
    | FoodSearchPage FoodSearch.Model
    | FoodDetailPage FoodShow.Model
    | FoodLogDetailPage FoodLogEntry.Model
    | CustomFoodCreatePage CustomFoodCreate.Model
    | CustomFoodEditPage CustomFoodEdit.Model
    | CustomFoodShowPage CustomFoodShow.Model
    | CustomFoodsPage CustomFoodList.Model
    | MealsPage MealList.Model
    | MealCreatePage MealCreate.Model
    | MealEditPage MealEdit.Model
    | MealDetailPage MealShow.Model
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
            ( AdminCreateUserPage AdminCreateUser.init, Cmd.none, NoOutMsg )

        AdminEditUser userId ->
            initPage context
                AdminEditUserPage
                applyAdminEditUserOutMsg
                (AdminEditUser.init userId)

        DiaryDay dateParam ->
            case context.today of
                Just today ->
                    initPage context
                        DiaryPage
                        applyDiaryOutMsg
                        (DiaryDay.init { dateParam = dateParam, today = today })

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
            ( FoodSearchPage (FoodSearch.init dateParam mealSlot)
            , case recentItemsRequest dateParam mealSlot of
                Just request ->
                    Api.Logs.recentItems
                        request
                        (GotFoodSearchMsg << FoodSearch.RecentItemsLoaded)

                Nothing ->
                    Cmd.none
            , NoOutMsg
            )

        FoodShow productId dateParam mealSlot ->
            initPage context
                FoodDetailPage
                applyFoodDetailOutMsg
                (FoodShow.init productId dateParam mealSlot)

        FoodLogEntry logId _ ->
            initPage context
                FoodLogDetailPage
                applyFoodLogDetailOutMsg
                (FoodLogEntry.init logId)

        CustomFoodCreate ->
            initPage context
                CustomFoodCreatePage
                applyCustomFoodCreateOutMsg
                CustomFoodCreate.init

        CustomFoodEdit productId ->
            initPage context
                CustomFoodEditPage
                applyCustomFoodEditOutMsg
                (CustomFoodEdit.init productId)

        CustomFoodShow productId ->
            initPage context
                CustomFoodShowPage
                applyCustomFoodShowOutMsg
                (CustomFoodShow.init productId)

        CustomFoodList ->
            initPage context CustomFoodsPage applyCustomFoodsOutMsg CustomFoodList.init

        MealList ->
            initPage context MealsPage applyMealsOutMsg MealList.init

        MealCreate ->
            initPage context MealCreatePage applyMealCreateOutMsg MealCreate.init

        MealEdit mealId ->
            initPage context MealEditPage applyMealEditOutMsg (MealEdit.init mealId)

        MealShow mealId ->
            initPage context MealDetailPage applyMealDetailOutMsg (MealShow.init mealId)

        _ ->
            ( PlaceholderPage "This route is not migrated yet.", Cmd.none, NoOutMsg )



-- UPDATE


type Msg
    = GotLoginMsg AuthLogin.Msg
    | GotSetupMsg BootstrapSetup.Msg
    | GotAdminMsg AdminDashboard.Msg
    | GotAdminCreateUserMsg AdminCreateUser.Msg
    | GotAdminEditUserMsg AdminEditUser.Msg
    | GotDiaryMsg DiaryDay.Msg
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

                _ ->
                    Nothing

        GotAdminCreateUserMsg subMsg ->
            case model of
                AdminCreateUserPage sub ->
                    Just
                        (stepPage context
                            AdminCreateUserPage
                            GotAdminCreateUserMsg
                            applyAdminCreateUserOutMsg
                            (AdminCreateUser.update subMsg sub)
                        )

                _ ->
                    Nothing

        GotAdminEditUserMsg subMsg ->
            case model of
                AdminEditUserPage sub ->
                    Just
                        (stepPage context
                            AdminEditUserPage
                            GotAdminEditUserMsg
                            applyAdminEditUserOutMsg
                            (AdminEditUser.update subMsg sub)
                        )

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

                _ ->
                    Nothing

        GotCustomFoodCreateMsg subMsg ->
            case model of
                CustomFoodCreatePage sub ->
                    Just
                        (stepPage context
                            CustomFoodCreatePage
                            GotCustomFoodCreateMsg
                            applyCustomFoodCreateOutMsg
                            (CustomFoodCreate.update subMsg sub)
                        )

                _ ->
                    Nothing

        GotCustomFoodEditMsg subMsg ->
            case model of
                CustomFoodEditPage sub ->
                    Just
                        (stepPage context
                            CustomFoodEditPage
                            GotCustomFoodEditMsg
                            applyCustomFoodEditOutMsg
                            (CustomFoodEdit.update subMsg sub)
                        )

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

                _ ->
                    Nothing

        GotCustomFoodShowMsg subMsg ->
            case model of
                CustomFoodShowPage sub ->
                    Just
                        (stepPage context
                            CustomFoodShowPage
                            GotCustomFoodShowMsg
                            applyCustomFoodShowOutMsg
                            (CustomFoodShow.update subMsg sub)
                        )

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

                _ ->
                    Nothing

        GotMealCreateMsg subMsg ->
            case model of
                MealCreatePage sub ->
                    Just
                        (stepPage context
                            MealCreatePage
                            GotMealCreateMsg
                            applyMealCreateOutMsg
                            (MealCreate.update subMsg sub)
                        )

                _ ->
                    Nothing

        GotMealEditMsg subMsg ->
            case model of
                MealEditPage sub ->
                    Just
                        (stepPage context
                            MealEditPage
                            GotMealEditMsg
                            applyMealEditOutMsg
                            (MealEdit.update subMsg sub)
                        )

                _ ->
                    Nothing

        GotMealDetailMsg subMsg ->
            case model of
                MealDetailPage sub ->
                    Just
                        (stepPage context
                            MealDetailPage
                            GotMealDetailMsg
                            applyMealDetailOutMsg
                            (MealShow.update subMsg sub)
                        )

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

        FoodSearchPage sub ->
            Just
                (stepPage pageContext
                    FoodSearchPage
                    GotFoodSearchMsg
                    applyFoodSearchOutMsg
                    (FoodSearch.update (FoodSearch.LocalContextReceived context) sub)
                )

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

        _ ->
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

        AdminCreateUserPage createUserModel ->
            Element.map GotAdminCreateUserMsg
                (AdminCreateUser.view (pageProps props createUserModel))

        AdminEditUserPage editUserModel ->
            Element.map GotAdminEditUserMsg (AdminEditUser.view (pageProps props editUserModel))

        DiaryPage diaryModel ->
            Element.map GotDiaryMsg (DiaryDay.view (pageProps props diaryModel))

        GoalsSettingsPage goalsSettingsModel ->
            Element.map GotGoalsSettingsMsg
                (GoalsSettings.view (pageProps props goalsSettingsModel))

        DiarySettingsPage diarySettingsModel ->
            Element.map GotDiarySettingsMsg
                (DiarySettings.view (pageProps props diarySettingsModel))

        FoodSearchPage foodSearchModel ->
            Element.map GotFoodSearchMsg (FoodSearch.view (pageProps props foodSearchModel))

        FoodDetailPage foodDetailModel ->
            Element.map GotFoodDetailMsg (FoodShow.view (pageProps props foodDetailModel))

        FoodLogDetailPage foodLogDetailModel ->
            Element.map GotFoodLogDetailMsg (FoodLogEntry.view (pageProps props foodLogDetailModel))

        CustomFoodCreatePage customFoodCreateModel ->
            Element.map GotCustomFoodCreateMsg
                (CustomFoodCreate.view (pageProps props customFoodCreateModel))

        CustomFoodEditPage customFoodEditModel ->
            Element.map GotCustomFoodEditMsg
                (CustomFoodEdit.view (pageProps props customFoodEditModel))

        CustomFoodShowPage customFoodShowModel ->
            Element.map GotCustomFoodShowMsg
                (CustomFoodShow.view (pageProps props customFoodShowModel))

        CustomFoodsPage customFoodsModel ->
            Element.map GotCustomFoodsMsg (CustomFoodList.view (pageProps props customFoodsModel))

        MealsPage mealsModel ->
            Element.map GotMealsMsg (MealList.view (pageProps props mealsModel))

        MealCreatePage mealCreateModel ->
            Element.map GotMealCreateMsg (MealCreate.view (pageProps props mealCreateModel))

        MealEditPage mealEditModel ->
            Element.map GotMealEditMsg (MealEdit.view (pageProps props mealEditModel))

        MealDetailPage mealDetailModel ->
            Element.map GotMealDetailMsg (MealShow.view (pageProps props mealDetailModel))

        PlaceholderPage message ->
            Element.el [ Element.padding DesignTokens.space24 ] (Element.text message)


modalView : { model : Model, device : Device, theme : Theme } -> Maybe (Element Msg)
modalView props =
    case props.model of
        FoodLogDetailPage foodLogDetailModel ->
            FoodLogEntry.modalView (pageProps props foodLogDetailModel)
                |> Maybe.map (Element.map GotFoodLogDetailMsg)

        CustomFoodShowPage customFoodShowModel ->
            CustomFoodShow.modalView (pageProps props customFoodShowModel)
                |> Maybe.map (Element.map GotCustomFoodShowMsg)

        MealDetailPage mealDetailModel ->
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
