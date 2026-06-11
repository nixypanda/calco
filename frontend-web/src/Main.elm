port module Main exposing (Flags, Model, Msg, PageModel, main)

import Access
import Api.Admin
import Api.Auth
import Api.Client as Client
import Api.Foods
import Api.Logs
import Api.Meals
import Browser
import Browser.Events
import Browser.Navigation as Nav
import Data.Auth as Auth
import Data.MealSlot as MealSlot
import Data.Nutrition exposing (defaultCode)
import Data.Route exposing (Route(..))
import Element
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Element.Region as Region
import Html
import Lib.Date as LocalDate exposing (LocalDate)
import Page.CustomFood.Create as CustomFoodCreate
import Page.CustomFood.Edit as CustomFoodEdit
import Page.CustomFood.List as CustomFoodList
import Page.Diary.Day as DiaryDay
import Page.Food.Search as FoodSearch
import Page.Food.Show as FoodShow
import Page.FoodLog.Entry as FoodLogEntry
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
import Session
import Task
import Time
import Ui
import Ui.Theme as Theme exposing (Mode, Theme)
import Url exposing (Url)


type alias Flags =
    { windowWidth : Int
    , windowHeight : Int
    , themeMode : String
    }


type alias Model =
    { key : Nav.Key
    , route : Route
    , session : Session.Session
    , adminExists : Bool
    , pendingSession : Maybe (Result Client.ApiError Auth.LoginSession)
    , pendingBootstrap : Maybe (Result Client.ApiError Auth.BootstrapStatus)
    , today : Maybe LocalDate
    , page : PageModel
    , drawerOpen : Bool
    , profileOpen : Bool
    , device : Element.Device
    , themeMode : Mode
    , theme : Theme
    }


type PageModel
    = LoadingPage
    | LoginPage AuthLogin.Model
    | SetupPage BootstrapSetup.Model
    | AdminPage AdminDashboard.Model
    | AdminCreateUserPage AdminCreateUser.Model
    | AdminEditUserPage AdminEditUser.Model
    | DiaryPage DiaryDay.Model
    | FoodSearchPage FoodSearch.Model
    | FoodDetailPage FoodShow.Model
    | FoodLogDetailPage FoodLogEntry.Model
    | CustomFoodCreatePage CustomFoodCreate.Model
    | CustomFoodEditPage CustomFoodEdit.Model
    | CustomFoodsPage CustomFoodList.Model
    | MealsPage MealList.Model
    | MealCreatePage MealCreate.Model
    | MealEditPage MealEdit.Model
    | MealDetailPage MealShow.Model
    | PlaceholderPage String


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | GotSession (Result Client.ApiError Auth.LoginSession)
    | GotBootstrapStatus (Result Client.ApiError Auth.BootstrapStatus)
    | GotLocalDate LocalDate
    | LogoutClicked
    | LogoutCompleted
    | MenuClicked
    | DrawerClosed
    | ProfileClicked
    | NavigateTo Route
    | WindowResized Int Int
    | GotLoginMsg AuthLogin.Msg
    | GotSetupMsg BootstrapSetup.Msg
    | GotAdminMsg AdminDashboard.Msg
    | GotAdminCreateUserMsg AdminCreateUser.Msg
    | GotAdminEditUserMsg AdminEditUser.Msg
    | GotDiaryMsg DiaryDay.Msg
    | GotFoodSearchMsg FoodSearch.Msg
    | GotFoodDetailMsg FoodShow.Msg
    | GotFoodLogDetailMsg FoodLogEntry.Msg
    | GotCustomFoodCreateMsg CustomFoodCreate.Msg
    | GotCustomFoodEditMsg CustomFoodEdit.Msg
    | GotCustomFoodsMsg CustomFoodList.Msg
    | GotMealsMsg MealList.Msg
    | GotMealCreateMsg MealCreate.Msg
    | GotMealEditMsg MealEdit.Msg
    | GotMealDetailMsg MealShow.Msg
    | GotLocalContext { date : String, timezone : String }
    | ThemeToggleClicked


port requestLocalContext : () -> Cmd msg


port localContextReceived : ({ date : String, timezone : String } -> msg) -> Sub msg


port persistThemeMode : String -> Cmd msg


main : Program Flags Model Msg
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlRequest = LinkClicked
        , onUrlChange = UrlChanged
        }


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ localContextReceived GotLocalContext
        , Browser.Events.onResize WindowResized
        ]


init : Flags -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        themeMode : Mode
        themeMode =
            Theme.modeFromString flags.themeMode
    in
    ( { key = key
      , route = Data.Route.fromUrl url
      , session = Session.init
      , adminExists = True
      , pendingSession = Nothing
      , pendingBootstrap = Nothing
      , today = Nothing
      , page = LoadingPage
      , drawerOpen = False
      , profileOpen = False
      , device =
            Element.classifyDevice
                { width = flags.windowWidth
                , height = flags.windowHeight
                }
      , themeMode = themeMode
      , theme = Theme.forMode themeMode
      }
    , Cmd.batch
        [ Api.Auth.session GotSession
        , Api.Auth.bootstrapStatus GotBootstrapStatus
        , Task.perform GotLocalDate
            (Task.map2 LocalDate.fromPosix Time.here Time.now)
        ]
    )



-- Generic page-lifting helpers. Each page's `update` returns
-- (subModel, Cmd subMsg, outMsg) and its `init` returns (subModel, outMsg).
-- These lift those into Main's Model / Msg, removing per-page boilerplate.


stepPage :
    (subModel -> PageModel)
    -> (subMsg -> Msg)
    -> (outMsg -> Model -> ( Model, Cmd Msg ))
    -> ( subModel, Cmd subMsg, outMsg )
    -> Model
    -> ( Model, Cmd Msg )
stepPage toPage toMsg applyOut ( newSubModel, subCmd, outMsg ) model =
    let
        ( finalModel, outCmd ) =
            applyOut outMsg { model | page = toPage newSubModel }
    in
    ( finalModel, Cmd.batch [ Cmd.map toMsg subCmd, outCmd ] )


initPage :
    (subModel -> PageModel)
    -> (outMsg -> Model -> ( Model, Cmd Msg ))
    -> ( subModel, outMsg )
    -> Model
    -> ( Model, Cmd Msg )
initPage toPage applyOut ( subModel, outMsg ) model =
    applyOut outMsg { model | page = toPage subModel }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        LinkClicked request ->
            case request of
                Browser.Internal url ->
                    ( closeChrome model, Nav.pushUrl model.key (Url.toString url) )

                Browser.External href ->
                    ( model, Nav.load href )

        UrlChanged url ->
            let
                route : Route
                route =
                    Data.Route.fromUrl url
            in
            changeRouteTo route { model | route = route, drawerOpen = False, profileOpen = False }

        GotSession result ->
            applyBootstrapProgress { model | pendingSession = Just result }

        GotBootstrapStatus result ->
            applyBootstrapProgress { model | pendingBootstrap = Just result }

        GotLocalDate today ->
            changeRouteTo model.route { model | today = Just today }

        LogoutClicked ->
            ( closeChrome model, Api.Auth.logout (\_ -> LogoutCompleted) )

        LogoutCompleted ->
            ( { model | session = Session.clear model.session }
            , Nav.replaceUrl model.key "/login"
            )

        MenuClicked ->
            ( { model | drawerOpen = not model.drawerOpen, profileOpen = False }, Cmd.none )

        DrawerClosed ->
            ( { model | drawerOpen = False }, Cmd.none )

        ProfileClicked ->
            ( { model | profileOpen = not model.profileOpen, drawerOpen = False }, Cmd.none )

        NavigateTo route ->
            ( closeChrome model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        WindowResized width height ->
            ( { model | device = Element.classifyDevice { width = width, height = height } }
            , Cmd.none
            )

        ThemeToggleClicked ->
            let
                nextMode : Mode
                nextMode =
                    Theme.toggle model.themeMode
            in
            ( { model | themeMode = nextMode, theme = Theme.forMode nextMode }
            , persistThemeMode (Theme.modeToString nextMode)
            )

        GotLoginMsg subMsg ->
            case model.page of
                LoginPage sub ->
                    stepPage LoginPage
                        GotLoginMsg
                        applyLoginOutMsg
                        (AuthLogin.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotSetupMsg subMsg ->
            case model.page of
                SetupPage sub ->
                    stepPage SetupPage
                        GotSetupMsg
                        applySetupOutMsg
                        (BootstrapSetup.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotAdminMsg subMsg ->
            case model.page of
                AdminPage sub ->
                    stepPage AdminPage
                        GotAdminMsg
                        applyAdminOutMsg
                        (AdminDashboard.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotAdminCreateUserMsg subMsg ->
            case model.page of
                AdminCreateUserPage sub ->
                    stepPage AdminCreateUserPage
                        GotAdminCreateUserMsg
                        applyAdminCreateUserOutMsg
                        (AdminCreateUser.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotAdminEditUserMsg subMsg ->
            case model.page of
                AdminEditUserPage sub ->
                    stepPage AdminEditUserPage
                        GotAdminEditUserMsg
                        applyAdminEditUserOutMsg
                        (AdminEditUser.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotDiaryMsg subMsg ->
            case model.page of
                DiaryPage sub ->
                    stepPage DiaryPage
                        GotDiaryMsg
                        applyDiaryOutMsg
                        (DiaryDay.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotFoodSearchMsg subMsg ->
            case model.page of
                FoodSearchPage sub ->
                    stepPage FoodSearchPage
                        GotFoodSearchMsg
                        applyFoodSearchOutMsg
                        (FoodSearch.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotFoodDetailMsg subMsg ->
            stepFoodDetail subMsg model

        GotFoodLogDetailMsg subMsg ->
            case model.page of
                FoodLogDetailPage sub ->
                    stepPage FoodLogDetailPage
                        GotFoodLogDetailMsg
                        applyFoodLogDetailOutMsg
                        (FoodLogEntry.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotLocalContext context ->
            stepFoodDetail (FoodShow.LocalContextReceived context) model

        GotCustomFoodCreateMsg subMsg ->
            case model.page of
                CustomFoodCreatePage sub ->
                    stepPage CustomFoodCreatePage
                        GotCustomFoodCreateMsg
                        applyCustomFoodCreateOutMsg
                        (CustomFoodCreate.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotCustomFoodEditMsg subMsg ->
            case model.page of
                CustomFoodEditPage sub ->
                    stepPage CustomFoodEditPage
                        GotCustomFoodEditMsg
                        applyCustomFoodEditOutMsg
                        (CustomFoodEdit.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotCustomFoodsMsg subMsg ->
            case model.page of
                CustomFoodsPage sub ->
                    stepPage CustomFoodsPage
                        GotCustomFoodsMsg
                        applyCustomFoodsOutMsg
                        (CustomFoodList.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotMealsMsg subMsg ->
            case model.page of
                MealsPage sub ->
                    stepPage MealsPage
                        GotMealsMsg
                        applyMealsOutMsg
                        (MealList.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotMealCreateMsg subMsg ->
            case model.page of
                MealCreatePage sub ->
                    stepPage MealCreatePage
                        GotMealCreateMsg
                        applyMealCreateOutMsg
                        (MealCreate.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotMealEditMsg subMsg ->
            case model.page of
                MealEditPage sub ->
                    stepPage MealEditPage
                        GotMealEditMsg
                        applyMealEditOutMsg
                        (MealEdit.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )

        GotMealDetailMsg subMsg ->
            case model.page of
                MealDetailPage sub ->
                    stepPage MealDetailPage
                        GotMealDetailMsg
                        applyMealDetailOutMsg
                        (MealShow.update subMsg sub)
                        model

                _ ->
                    ( model, Cmd.none )


stepFoodDetail : FoodShow.Msg -> Model -> ( Model, Cmd Msg )
stepFoodDetail subMsg model =
    case model.page of
        FoodDetailPage sub ->
            stepPage FoodDetailPage
                GotFoodDetailMsg
                applyFoodDetailOutMsg
                (FoodShow.update subMsg sub)
                model

        _ ->
            ( model, Cmd.none )


applyBootstrapProgress : Model -> ( Model, Cmd Msg )
applyBootstrapProgress model =
    case ( model.pendingSession, model.pendingBootstrap ) of
        ( Just sessionResult, Just bootstrapResult ) ->
            let
                nextSession : Session.Session
                nextSession =
                    Session.applyAuthResult sessionResult model.session

                adminExists : Bool
                adminExists =
                    case bootstrapResult of
                        Ok status ->
                            status.adminExists

                        Err _ ->
                            True
            in
            changeRouteTo model.route
                { model | session = nextSession, adminExists = adminExists }

        _ ->
            ( model, Cmd.none )


changeRouteTo : Route -> Model -> ( Model, Cmd Msg )
changeRouteTo route model =
    case Access.resolveRoute model.session model.adminExists route of
        Access.Hold ->
            ( model, Cmd.none )

        Access.Render renderRoute ->
            loadPage renderRoute model

        Access.Navigate target ->
            ( model, Nav.replaceUrl model.key (Data.Route.routeToPath target) )


loadPage : Route -> Model -> ( Model, Cmd Msg )
loadPage route model =
    case route of
        AuthLogin ->
            ( { model | page = LoginPage AuthLogin.init }, Cmd.none )

        BootstrapSetup ->
            ( { model | page = SetupPage BootstrapSetup.init }, Cmd.none )

        AdminDashboard ->
            initPage AdminPage applyAdminOutMsg AdminDashboard.init model

        AdminCreateUser ->
            ( { model | page = AdminCreateUserPage AdminCreateUser.init }, Cmd.none )

        AdminEditUser userId ->
            initPage AdminEditUserPage applyAdminEditUserOutMsg (AdminEditUser.init userId) model

        DiaryDay dateParam ->
            case model.today of
                Just today ->
                    initPage DiaryPage
                        applyDiaryOutMsg
                        (DiaryDay.init { dateParam = dateParam, today = today })
                        model

                Nothing ->
                    ( { model | page = LoadingPage }, Cmd.none )

        FoodSearch mealSlot ->
            ( { model | page = FoodSearchPage (FoodSearch.init mealSlot) }, Cmd.none )

        FoodShow productId mealSlot ->
            initPage FoodDetailPage applyFoodDetailOutMsg (FoodShow.init productId mealSlot) model

        FoodLogEntry logId ->
            initPage FoodLogDetailPage applyFoodLogDetailOutMsg (FoodLogEntry.init logId) model

        CustomFoodCreate ->
            initPage CustomFoodCreatePage applyCustomFoodCreateOutMsg CustomFoodCreate.init model

        CustomFoodEdit productId ->
            initPage CustomFoodEditPage
                applyCustomFoodEditOutMsg
                (CustomFoodEdit.init productId)
                model

        CustomFoodList ->
            initPage CustomFoodsPage applyCustomFoodsOutMsg CustomFoodList.init model

        MealList ->
            initPage MealsPage applyMealsOutMsg MealList.init model

        MealCreate ->
            initPage MealCreatePage applyMealCreateOutMsg MealCreate.init model

        MealEdit mealId ->
            initPage MealEditPage applyMealEditOutMsg (MealEdit.init mealId) model

        MealShow mealId ->
            initPage MealDetailPage applyMealDetailOutMsg (MealShow.init mealId) model

        _ ->
            ( { model | page = PlaceholderPage "This route is not migrated yet." }, Cmd.none )


applyLoginOutMsg : AuthLogin.OutMsg -> Model -> ( Model, Cmd Msg )
applyLoginOutMsg outMsg model =
    case outMsg of
        AuthLogin.NoOp ->
            ( model, Cmd.none )

        AuthLogin.RequestLogin request ->
            ( model, Api.Auth.login request (GotLoginMsg << AuthLogin.LoginCompleted) )

        AuthLogin.LoginSucceeded loginSession ->
            let
                nextSession : Session.Session
                nextSession =
                    Session.applyAuthResult (Ok loginSession) model.session
            in
            ( { model | session = nextSession }, Nav.replaceUrl model.key "/" )


applySetupOutMsg : BootstrapSetup.OutMsg -> Model -> ( Model, Cmd Msg )
applySetupOutMsg outMsg model =
    case outMsg of
        BootstrapSetup.NoOp ->
            ( model, Cmd.none )

        BootstrapSetup.RequestCreateAdmin request ->
            ( model
            , Api.Auth.createAdmin request (GotSetupMsg << BootstrapSetup.CreateAdminCompleted)
            )

        BootstrapSetup.CreateAdminSucceeded loginSession ->
            let
                nextSession : Session.Session
                nextSession =
                    Session.applyAuthResult (Ok loginSession) model.session
            in
            ( { model | session = nextSession, adminExists = True }
            , Nav.replaceUrl model.key "/admin"
            )


applyAdminOutMsg : AdminDashboard.OutMsg -> Model -> ( Model, Cmd Msg )
applyAdminOutMsg outMsg model =
    case outMsg of
        AdminDashboard.NoOp ->
            ( model, Cmd.none )

        AdminDashboard.RequestUsers ->
            ( model, Api.Admin.listUsers (GotAdminMsg << AdminDashboard.UsersLoaded) )

        AdminDashboard.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        AdminDashboard.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyAdminCreateUserOutMsg : AdminCreateUser.OutMsg -> Model -> ( Model, Cmd Msg )
applyAdminCreateUserOutMsg outMsg model =
    case outMsg of
        AdminCreateUser.NoOp ->
            ( model, Cmd.none )

        AdminCreateUser.RequestCreateUser request ->
            ( model
            , Api.Admin.createUser request (GotAdminCreateUserMsg << AdminCreateUser.Completed)
            )

        AdminCreateUser.CreateSucceeded ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath AdminDashboard) )

        AdminCreateUser.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyAdminEditUserOutMsg : AdminEditUser.OutMsg -> Model -> ( Model, Cmd Msg )
applyAdminEditUserOutMsg outMsg model =
    case outMsg of
        AdminEditUser.NoOp ->
            ( model, Cmd.none )

        AdminEditUser.RequestUser userId ->
            ( model, Api.Admin.getUser userId (GotAdminEditUserMsg << AdminEditUser.UserLoaded) )

        AdminEditUser.RequestResetPassword userId request ->
            ( model
            , Api.Admin.resetPassword
                userId
                request
                (GotAdminEditUserMsg << AdminEditUser.ResetCompleted)
            )

        AdminEditUser.RequestDisableUser userId ->
            ( model
            , Api.Admin.disableUser userId (GotAdminEditUserMsg << AdminEditUser.DisableCompleted)
            )

        AdminEditUser.RequestEnableUser userId ->
            ( model
            , Api.Admin.enableUser userId (GotAdminEditUserMsg << AdminEditUser.EnableCompleted)
            )

        AdminEditUser.UpdateSucceeded ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath AdminDashboard) )

        AdminEditUser.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyDiaryOutMsg : DiaryDay.OutMsg -> Model -> ( Model, Cmd Msg )
applyDiaryOutMsg outMsg model =
    case outMsg of
        DiaryDay.NoOp ->
            ( model, Cmd.none )

        DiaryDay.RequestDiaryData date ->
            ( model
            , Cmd.map GotDiaryMsg (Api.Logs.listLogs date (DiaryDay.LogsLoaded date))
            )

        DiaryDay.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        DiaryDay.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyFoodSearchOutMsg : FoodSearch.OutMsg -> Model -> ( Model, Cmd Msg )
applyFoodSearchOutMsg outMsg model =
    case outMsg of
        FoodSearch.NoOp ->
            ( model, Cmd.none )

        FoodSearch.RequestSearch token request ->
            ( model
            , Api.Foods.searchFoods
                request
                (GotFoodSearchMsg << FoodSearch.SearchCompleted token)
            )

        FoodSearch.RequestCategorySuggestions token request ->
            ( model
            , Api.Foods.listCategorySuggestions
                request
                (GotFoodSearchMsg << FoodSearch.CategorySuggestionsCompleted token)
            )

        FoodSearch.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        FoodSearch.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyFoodDetailOutMsg : FoodShow.OutMsg -> Model -> ( Model, Cmd Msg )
applyFoodDetailOutMsg outMsg model =
    case outMsg of
        FoodShow.NoOp ->
            ( model, Cmd.none )

        FoodShow.RequestInitialData productId ->
            ( model
            , Cmd.batch
                [ Api.Foods.getFoodDetail productId (GotFoodDetailMsg << FoodShow.FoodLoaded)
                , Api.Foods.listUnits (GotFoodDetailMsg << FoodShow.UnitsLoaded)
                ]
            )

        FoodShow.RequestLocalContext ->
            ( model, requestLocalContext () )

        FoodShow.RequestCreateLog request ->
            ( model, Api.Logs.createLog request (GotFoodDetailMsg << FoodShow.LogCompleted) )

        FoodShow.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        FoodShow.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyFoodLogDetailOutMsg : FoodLogEntry.OutMsg -> Model -> ( Model, Cmd Msg )
applyFoodLogDetailOutMsg outMsg model =
    case outMsg of
        FoodLogEntry.NoOp ->
            ( model, Cmd.none )

        FoodLogEntry.RequestInitialData logId ->
            ( model
            , Cmd.batch
                [ Api.Logs.getLog logId (GotFoodLogDetailMsg << FoodLogEntry.LogLoaded)
                , Api.Foods.listUnits (GotFoodLogDetailMsg << FoodLogEntry.UnitsLoaded)
                ]
            )

        FoodLogEntry.RequestProductDetail productId ->
            ( model
            , Api.Foods.getFoodDetail
                productId
                (GotFoodLogDetailMsg << FoodLogEntry.ProductDetailLoaded)
            )

        FoodLogEntry.RequestMealName mealId ->
            ( model
            , Api.Meals.getMealName
                mealId
                (GotFoodLogDetailMsg << FoodLogEntry.MealNameLoaded)
            )

        FoodLogEntry.RequestUpdateLog logId request ->
            ( model
            , Api.Logs.updateLog
                logId
                request
                (GotFoodLogDetailMsg << FoodLogEntry.UpdateCompleted)
            )

        FoodLogEntry.RequestDeleteLog logId ->
            ( model
            , Api.Logs.deleteLog
                logId
                (GotFoodLogDetailMsg << FoodLogEntry.DeleteCompleted)
            )

        FoodLogEntry.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        FoodLogEntry.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyCustomFoodCreateOutMsg : CustomFoodCreate.OutMsg -> Model -> ( Model, Cmd Msg )
applyCustomFoodCreateOutMsg outMsg model =
    case outMsg of
        CustomFoodCreate.NoOp ->
            ( model, Cmd.none )

        CustomFoodCreate.RequestInitialData ->
            ( model
            , Cmd.batch
                [ Api.Foods.listNutrients
                    (GotCustomFoodCreateMsg << CustomFoodCreate.NutrientsLoaded)
                , Api.Foods.listUnits (GotCustomFoodCreateMsg << CustomFoodCreate.UnitsLoaded)
                ]
            )

        CustomFoodCreate.RequestCreateFood request ->
            ( model
            , Api.Foods.createCustomFood
                request
                (GotCustomFoodCreateMsg << CustomFoodCreate.SaveCompleted)
            )

        CustomFoodCreate.RequestCategorySuggestions token request ->
            ( model
            , Api.Foods.listCategorySuggestions
                request
                (GotCustomFoodCreateMsg << CustomFoodCreate.CategorySuggestionsLoaded token)
            )

        CustomFoodCreate.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        CustomFoodCreate.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyCustomFoodEditOutMsg : CustomFoodEdit.OutMsg -> Model -> ( Model, Cmd Msg )
applyCustomFoodEditOutMsg outMsg model =
    case outMsg of
        CustomFoodEdit.NoOp ->
            ( model, Cmd.none )

        CustomFoodEdit.RequestInitialData productId ->
            ( model
            , Cmd.batch
                [ Api.Foods.getFoodDetail
                    productId
                    (GotCustomFoodEditMsg << CustomFoodEdit.FoodLoaded)
                , Api.Foods.listNutrients (GotCustomFoodEditMsg << CustomFoodEdit.NutrientsLoaded)
                , Api.Foods.listUnits (GotCustomFoodEditMsg << CustomFoodEdit.UnitsLoaded)
                ]
            )

        CustomFoodEdit.RequestUpdateFood productId request ->
            ( model
            , Api.Foods.updateCustomFood
                productId
                request
                (GotCustomFoodEditMsg << CustomFoodEdit.SaveCompleted)
            )

        CustomFoodEdit.RequestCategorySuggestions token request ->
            ( model
            , Api.Foods.listCategorySuggestions
                request
                (GotCustomFoodEditMsg << CustomFoodEdit.CategorySuggestionsLoaded token)
            )

        CustomFoodEdit.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        CustomFoodEdit.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyCustomFoodsOutMsg : CustomFoodList.OutMsg -> Model -> ( Model, Cmd Msg )
applyCustomFoodsOutMsg outMsg model =
    case outMsg of
        CustomFoodList.NoOp ->
            ( model, Cmd.none )

        CustomFoodList.RequestFoods ->
            ( model
            , Api.Foods.listCustomFoods (GotCustomFoodsMsg << CustomFoodList.FoodsLoaded)
            )

        CustomFoodList.RequestDeleteFood foodId ->
            ( model
            , Api.Foods.deleteCustomFood
                foodId
                (GotCustomFoodsMsg << CustomFoodList.DeleteCompleted foodId)
            )

        CustomFoodList.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        CustomFoodList.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyMealsOutMsg : MealList.OutMsg -> Model -> ( Model, Cmd Msg )
applyMealsOutMsg outMsg model =
    case outMsg of
        MealList.NoOp ->
            ( model, Cmd.none )

        MealList.RequestMeals ->
            ( model, Api.Meals.listMeals (GotMealsMsg << MealList.MealsLoaded) )

        MealList.RequestDeleteMeal mealId ->
            ( model, Api.Meals.deleteMeal mealId (GotMealsMsg << MealList.DeleteCompleted mealId) )

        MealList.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        MealList.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyMealCreateOutMsg : MealCreate.OutMsg -> Model -> ( Model, Cmd Msg )
applyMealCreateOutMsg outMsg model =
    case outMsg of
        MealCreate.NoOp ->
            ( model, Cmd.none )

        MealCreate.FormOutMsg formOutMsg ->
            applyMealFormOutMsg
                { toPageMsg = GotMealCreateMsg << MealCreate.FormMsg }
                formOutMsg
                model

        MealCreate.RequestCreateMeal request ->
            ( model, Api.Meals.createMeal request (GotMealCreateMsg << MealCreate.SaveCompleted) )

        MealCreate.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        MealCreate.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyMealEditOutMsg : MealEdit.OutMsg -> Model -> ( Model, Cmd Msg )
applyMealEditOutMsg outMsg model =
    case outMsg of
        MealEdit.NoOp ->
            ( model, Cmd.none )

        MealEdit.FormOutMsg formOutMsg ->
            applyMealFormOutMsg
                { toPageMsg = GotMealEditMsg << MealEdit.FormMsg }
                formOutMsg
                model

        MealEdit.RequestMeal mealId ->
            ( model
            , Cmd.batch
                [ Api.Meals.getMeal mealId (GotMealEditMsg << MealEdit.MealLoaded)
                , Api.Meals.getMealNutrients
                    { mealId = mealId, amount = "100", unit = defaultCode }
                    (GotMealEditMsg << MealEdit.NutrientPreviewLoaded)
                ]
            )

        MealEdit.RequestUpdateMeal mealId request ->
            ( model
            , Api.Meals.updateMeal
                mealId
                request
                (GotMealEditMsg << MealEdit.SaveCompleted)
            )

        MealEdit.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        MealEdit.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyMealFormOutMsg :
    { toPageMsg : MealForm.FormFieldMsg -> Msg }
    -> MealForm.FormFieldOutMsg
    -> Model
    -> ( Model, Cmd Msg )
applyMealFormOutMsg { toPageMsg } outMsg model =
    case outMsg of
        MealForm.RequestProductName productId ->
            ( model
            , Api.Foods.getFoodDetail
                productId
                (toPageMsg << MealForm.ProductNameLoaded productId)
            )

        MealForm.RequestProductSearch rowId token request ->
            ( model
            , Api.Foods.searchFoods
                request
                (toPageMsg
                    << MealForm.ComponentSearchCompleted
                        rowId
                        token
                )
            )

        MealForm.RequestCategorySuggestions rowId token request ->
            ( model
            , Api.Foods.listCategorySuggestions
                request
                (toPageMsg
                    << MealForm.ComponentCategoriesCompleted
                        rowId
                        token
                )
            )

        MealForm.RequestProductAndCats requests ->
            ( model
            , Cmd.batch
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
            )

        MealForm.FormSessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyMealDetailOutMsg : MealShow.OutMsg -> Model -> ( Model, Cmd Msg )
applyMealDetailOutMsg outMsg model =
    case outMsg of
        MealShow.NoOp ->
            ( model, Cmd.none )

        MealShow.RequestInitialData mealId ->
            ( model
            , Cmd.batch
                [ Api.Meals.getMeal mealId (GotMealDetailMsg << MealShow.MealLoaded)
                , Api.Foods.listUnits (GotMealDetailMsg << MealShow.UnitsLoaded)
                , Api.Meals.getMealNutrients
                    { mealId = mealId, amount = "100", unit = defaultCode }
                    (GotMealDetailMsg << MealShow.NutrientPreviewLoaded)
                ]
            )

        MealShow.RequestNutrientPreview mealId amount unit ->
            ( model
            , Api.Meals.getMealNutrients
                { mealId = mealId, amount = amount, unit = unit }
                (GotMealDetailMsg << MealShow.NutrientPreviewLoaded)
            )

        MealShow.RequestProductDetail productId ->
            ( model
            , Api.Foods.getFoodDetail
                productId
                (GotMealDetailMsg << MealShow.ProductDetailLoaded productId)
            )

        MealShow.RequestDeleteMeal mealId ->
            ( model, Api.Meals.deleteMeal mealId (GotMealDetailMsg << MealShow.DeleteCompleted) )

        MealShow.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        MealShow.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


type LeadingAction
    = OpenMenu
    | GoBack Route
    | NoLeadingAction


type alias ScreenMeta =
    { title : String
    , leading : LeadingAction
    }


view : Model -> Browser.Document Msg
view model =
    { title = "CalCo"
    , body =
        [ Html.node "style"
            []
            [ Html.text (":root { background: " ++ Ui.toCssColor model.theme.pageBg ++ "; }") ]
        , Element.layoutWith
            { options =
                [ Element.focusStyle
                    { borderColor = Nothing
                    , backgroundColor = Nothing
                    , shadow = Nothing
                    }
                ]
            }
            []
          <|
            Ui.layout model.theme <|
                appFrame model
        ]
    }


appFrame : Model -> Element.Element Msg
appFrame model =
    Element.column
        ([ Element.width Element.fill
         , Element.height Element.fill
         ]
            ++ drawerOverlay model
        )
        [ topBarView model
        , Element.el
            [ Element.width Element.fill
            , Element.height Element.fill
            , Region.mainContent
            ]
            (pageView model)
        ]


showsAppChrome : Model -> Bool
showsAppChrome model =
    Session.isAuthenticated model.session
        && model.page
        /= LoadingPage
        && (case model.route of
                AuthLogin ->
                    False

                BootstrapSetup ->
                    False

                _ ->
                    True
           )


topBarView : Model -> Element.Element Msg
topBarView model =
    let
        chromeShown : Bool
        chromeShown =
            showsAppChrome model

        meta : ScreenMeta
        meta =
            screenMeta model.route
    in
    Element.row
        [ Element.width Element.fill
        , Element.height (Element.px 58)
        , Element.paddingXY Ui.space16 0
        , Element.spacing Ui.space12
        , Background.color model.theme.cardBg
        , Font.color model.theme.textPrimary
        ]
        (if chromeShown then
            [ leadingButton model.theme meta.leading
            , Element.el
                [ Element.width Element.fill
                , Element.clip
                ]
                (Ui.subsectionTitle model.theme meta.title)
            , Element.el
                [ Element.paddingEach { top = 0, right = 8, bottom = 0, left = 0 } ]
                (themeToggle model)
            , profileButton model
            ]

         else
            [ Element.el [ Element.width Element.fill ] Element.none
            , themeToggle model
            ]
        )


themeToggle : Model -> Element.Element Msg
themeToggle model =
    Ui.toggleSwitch model.theme
        { isActive = model.themeMode == Theme.Dark
        , onToggle = ThemeToggleClicked
        }


leadingButton : Theme -> LeadingAction -> Element.Element Msg
leadingButton theme leading =
    case leading of
        OpenMenu ->
            Ui.iconButton theme { label = "☰", title = "Menu", onPress = MenuClicked }

        GoBack route ->
            Ui.iconButton theme { label = "←", title = "Back", onPress = NavigateTo route }

        NoLeadingAction ->
            Element.el [ Element.width (Element.px 40) ] Element.none


profileButton : Model -> Element.Element Msg
profileButton model =
    let
        letter : String
        letter =
            case model.session of
                Session.Authenticated identity ->
                    initial identity.username

                _ ->
                    "?"
    in
    Element.el
        (profileMenuAnchor model)
        (Ui.iconButton model.theme { label = letter, title = "Profile", onPress = ProfileClicked })


profileMenuAnchor : Model -> List (Element.Attribute Msg)
profileMenuAnchor model =
    if model.profileOpen && showsAppChrome model then
        [ Element.below (profileMenu model) ]

    else
        []


profileMenu : Model -> Element.Element Msg
profileMenu model =
    Element.column
        [ Element.alignRight
        , Element.moveDown 4
        , Element.width (Element.px 240)
        , Element.padding Ui.space12
        , Element.spacing 10
        , Background.color model.theme.cardBg
        , Border.rounded 20
        , Ui.cardShadow model.theme
        ]
        (profileMenuContent model)


initial : String -> String
initial value =
    value
        |> String.uncons
        |> Maybe.map (\( c, _ ) -> String.fromChar c |> String.toUpper)
        |> Maybe.withDefault "?"


screenMeta : Route -> ScreenMeta
screenMeta route =
    case route of
        Root ->
            { title = "Diary", leading = OpenMenu }

        DiaryDay _ ->
            { title = "Diary", leading = OpenMenu }

        AdminDashboard ->
            { title = "Admin", leading = OpenMenu }

        AdminCreateUser ->
            { title = "Create User", leading = GoBack AdminDashboard }

        AdminEditUser _ ->
            { title = "Edit User", leading = GoBack AdminDashboard }

        FoodSearch maybeSlot ->
            { title =
                case maybeSlot of
                    Just slot ->
                        "Add to " ++ MealSlot.label slot

                    Nothing ->
                        "Search Foods"
            , leading = GoBack (DiaryDay Nothing)
            }

        FoodShow _ maybeSlot ->
            { title = "Log Food", leading = GoBack (FoodSearch maybeSlot) }

        FoodLogEntry _ ->
            { title = "Edit Log", leading = GoBack (DiaryDay Nothing) }

        CustomFoodCreate ->
            { title = "Create Food", leading = GoBack CustomFoodList }

        CustomFoodEdit _ ->
            { title = "Edit Food", leading = GoBack CustomFoodList }

        CustomFoodList ->
            { title = "My Foods", leading = GoBack (DiaryDay Nothing) }

        MealList ->
            { title = "My Meals", leading = GoBack (DiaryDay Nothing) }

        MealCreate ->
            { title = "Create Meal", leading = GoBack MealList }

        MealShow _ ->
            { title = "Meal", leading = GoBack MealList }

        MealEdit _ ->
            { title = "Edit Meal", leading = GoBack MealList }

        AuthLogin ->
            { title = "Login", leading = NoLeadingAction }

        BootstrapSetup ->
            { title = "Setup", leading = NoLeadingAction }

        NotFound ->
            { title = "Diary", leading = OpenMenu }


drawerOverlay : Model -> List (Element.Attribute Msg)
drawerOverlay model =
    if model.drawerOpen && showsAppChrome model then
        [ Element.inFront
            (Element.row
                [ Element.width Element.fill
                , Element.height Element.fill
                ]
                [ drawerView model
                , Input.button
                    [ Element.width Element.fill
                    , Element.height Element.fill
                    , Background.color (Element.rgba255 0 0 0 0.28)
                    ]
                    { onPress = Just DrawerClosed
                    , label = Element.none
                    }
                ]
            )
        ]

    else
        []


drawerView : Model -> Element.Element Msg
drawerView model =
    Element.column
        [ Element.width (Element.fill |> Element.maximum 320)
        , Element.height Element.fill
        , Element.paddingXY 16 9
        , Element.spacing Ui.space12
        , Background.color model.theme.cardBg
        , Ui.cardShadow model.theme
        , Region.navigation
        ]
        (Element.row [ Element.spacing Ui.space8 ]
            [ Ui.iconButton model.theme { label = "☰", title = "Close", onPress = DrawerClosed }
            , Ui.sectionTitle model.theme "CalCo"
            ]
            :: Ui.hairline model.theme
            :: drawerItems model
        )


drawerItems : Model -> List (Element.Element Msg)
drawerItems model =
    if Session.isAdmin model.session then
        [ drawerItem model.theme model.route "Admin" AdminDashboard ]

    else
        [ drawerItem model.theme model.route "Diary" (DiaryDay Nothing)
        , drawerItem model.theme model.route "Search Foods" (FoodSearch Nothing)
        , drawerItem model.theme model.route "My Foods" CustomFoodList
        , drawerItem model.theme model.route "My Meals" MealList
        ]


drawerItem : Theme -> Route -> String -> Route -> Element.Element Msg
drawerItem theme current label target =
    let
        selected : Bool
        selected =
            primaryRoute current == primaryRoute target
    in
    Input.button
        [ Element.width Element.fill
        , Element.paddingXY 16 14
        , Border.rounded 12
        , Background.color
            (if selected then
                theme.drawerSelectionBg

             else
                theme.cardBg
            )
        , Font.color
            (if selected then
                theme.brandBlue

             else
                theme.textPrimary
            )
        , Font.medium
        ]
        { onPress = Just (NavigateTo target)
        , label = Element.text label
        }


primaryRoute : Route -> Route
primaryRoute route =
    case route of
        FoodShow _ _ ->
            FoodSearch Nothing

        CustomFoodCreate ->
            CustomFoodList

        CustomFoodEdit _ ->
            CustomFoodList

        AdminCreateUser ->
            AdminDashboard

        AdminEditUser _ ->
            AdminDashboard

        MealCreate ->
            MealList

        MealShow _ ->
            MealList

        MealEdit _ ->
            MealList

        FoodLogEntry _ ->
            DiaryDay Nothing

        DiaryDay _ ->
            DiaryDay Nothing

        FoodSearch _ ->
            FoodSearch Nothing

        other ->
            other


profileMenuContent : Model -> List (Element.Element Msg)
profileMenuContent model =
    [ Ui.mutedCaption model.theme
        (case model.session of
            Session.Authenticated identity ->
                "Signed in as " ++ identity.username

            _ ->
                "Signed in"
        )
    , Ui.button model.theme "Logout" LogoutClicked
    ]


closeChrome : Model -> Model
closeChrome model =
    { model | drawerOpen = False, profileOpen = False }


pageView : Model -> Element.Element Msg
pageView model =
    if
        model.session
            == Session.Loading
            || model.pendingSession
            == Nothing
            || model.pendingBootstrap
            == Nothing
    then
        Ui.skeletonLoading model.theme

    else
        let
            device : Element.Device
            device =
                model.device

            theme : Theme
            theme =
                model.theme

            props : subModel -> { model : subModel, device : Element.Device, theme : Theme }
            props subModel =
                { model = subModel, device = device, theme = theme }
        in
        case model.page of
            LoadingPage ->
                Ui.skeletonLoading theme

            LoginPage loginModel ->
                Element.map GotLoginMsg (AuthLogin.view (props loginModel))

            SetupPage setupModel ->
                Element.map GotSetupMsg (BootstrapSetup.view (props setupModel))

            AdminPage adminModel ->
                Element.map GotAdminMsg (AdminDashboard.view (props adminModel))

            AdminCreateUserPage createUserModel ->
                Element.map GotAdminCreateUserMsg (AdminCreateUser.view (props createUserModel))

            AdminEditUserPage editUserModel ->
                Element.map GotAdminEditUserMsg (AdminEditUser.view (props editUserModel))

            DiaryPage diaryModel ->
                Element.map GotDiaryMsg (DiaryDay.view (props diaryModel))

            FoodSearchPage foodSearchModel ->
                Element.map GotFoodSearchMsg (FoodSearch.view (props foodSearchModel))

            FoodDetailPage foodDetailModel ->
                Element.map GotFoodDetailMsg (FoodShow.view (props foodDetailModel))

            FoodLogDetailPage foodLogDetailModel ->
                Element.map GotFoodLogDetailMsg (FoodLogEntry.view (props foodLogDetailModel))

            CustomFoodCreatePage customFoodCreateModel ->
                Element.map GotCustomFoodCreateMsg
                    (CustomFoodCreate.view (props customFoodCreateModel))

            CustomFoodEditPage customFoodEditModel ->
                Element.map GotCustomFoodEditMsg (CustomFoodEdit.view (props customFoodEditModel))

            CustomFoodsPage customFoodsModel ->
                Element.map GotCustomFoodsMsg (CustomFoodList.view (props customFoodsModel))

            MealsPage mealsModel ->
                Element.map GotMealsMsg (MealList.view (props mealsModel))

            MealCreatePage mealCreateModel ->
                Element.map GotMealCreateMsg (MealCreate.view (props mealCreateModel))

            MealEditPage mealEditModel ->
                Element.map GotMealEditMsg (MealEdit.view (props mealEditModel))

            MealDetailPage mealDetailModel ->
                Element.map GotMealDetailMsg (MealShow.view (props mealDetailModel))

            PlaceholderPage message ->
                Element.el [ Element.padding Ui.space24 ] (Element.text message)
