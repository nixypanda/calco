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
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Admin.BootstrapSetup as BootstrapSetup
import Page.Admin.CreateUser as AdminCreateUser
import Page.Admin.Dashboard as AdminDashboard
import Page.Admin.EditUser as AdminEditUser
import Page.Auth.Login as AuthLogin
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
import Session
import Task
import Time
import Ui
import Url exposing (Url)


type alias Flags =
    { windowWidth : Int
    , windowHeight : Int
    }


type alias Model =
    { key : Nav.Key
    , route : Route
    , session : Session.Session
    , adminExists : Bool
    , pendingSession : Maybe (Result Client.ApiError Auth.LoginSession)
    , pendingBootstrap : Maybe (Result Client.ApiError Auth.BootstrapStatus)
    , timeZone : Maybe Time.Zone
    , today : Maybe LocalDate
    , page : PageModel
    , drawerOpen : Bool
    , profileOpen : Bool
    , device : Element.Device
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
    | GotTimeZone Time.Zone
    | GotNow Time.Posix
    | LogoutClicked
    | LogoutCompleted (Result Client.ApiError ())
    | MenuClicked
    | DrawerClosed
    | ProfileClicked
    | AppBackClicked Route
    | AppNavigationClicked Route
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


port requestLocalContext : () -> Cmd msg


port localContextReceived : ({ date : String, timezone : String } -> msg) -> Sub msg


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
    ( { key = key
      , route = Data.Route.fromUrl url
      , session = Session.init
      , adminExists = True
      , pendingSession = Nothing
      , pendingBootstrap = Nothing
      , timeZone = Nothing
      , today = Nothing
      , page = LoadingPage
      , drawerOpen = False
      , profileOpen = False
      , device =
            Element.classifyDevice
                { width = flags.windowWidth
                , height = flags.windowHeight
                }
      }
    , Cmd.batch
        [ Api.Auth.session GotSession
        , Api.Auth.bootstrapStatus GotBootstrapStatus
        , Task.perform GotTimeZone Time.here
        ]
    )


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

        GotTimeZone zone ->
            ( { model | timeZone = Just zone }, Task.perform GotNow Time.now )

        GotNow posix ->
            case model.timeZone of
                Just zone ->
                    changeRouteTo
                        model.route
                        { model | today = Just (LocalDate.fromPosix zone posix) }

                Nothing ->
                    ( model, Cmd.none )

        LogoutClicked ->
            ( closeChrome model, Api.Auth.logout LogoutCompleted )

        LogoutCompleted result ->
            let
                nextModel : Model
                nextModel =
                    { model | session = Session.clear model.session }
            in
            case result of
                Ok _ ->
                    ( nextModel, Nav.replaceUrl model.key "/login" )

                Err _ ->
                    ( nextModel, Nav.replaceUrl model.key "/login" )

        MenuClicked ->
            ( { model | drawerOpen = not model.drawerOpen, profileOpen = False }, Cmd.none )

        DrawerClosed ->
            ( { model | drawerOpen = False }, Cmd.none )

        ProfileClicked ->
            ( { model | profileOpen = not model.profileOpen, drawerOpen = False }, Cmd.none )

        AppBackClicked route ->
            ( closeChrome model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        AppNavigationClicked route ->
            ( closeChrome model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        WindowResized width height ->
            ( { model
                | device = Element.classifyDevice { width = width, height = height }
              }
            , Cmd.none
            )

        GotLoginMsg subMsg ->
            case model.page of
                LoginPage subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            AuthLogin.update subMsg subModel

                        nextModel : Model
                        nextModel =
                            { model | page = LoginPage newSubModel }

                        ( finalModel, outCmd ) =
                            applyLoginOutMsg outMsg nextModel
                    in
                    ( finalModel
                    , Cmd.batch [ Cmd.map GotLoginMsg subCmd, outCmd ]
                    )

                _ ->
                    ( model, Cmd.none )

        GotDiaryMsg subMsg ->
            case model.page of
                DiaryPage subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            DiaryDay.update subMsg subModel

                        nextModel : Model
                        nextModel =
                            { model | page = DiaryPage newSubModel }

                        ( finalModel, outCmd ) =
                            applyDiaryOutMsg outMsg nextModel
                    in
                    ( finalModel
                    , Cmd.batch [ Cmd.map GotDiaryMsg subCmd, outCmd ]
                    )

                _ ->
                    ( model, Cmd.none )

        GotSetupMsg subMsg ->
            case model.page of
                SetupPage subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            BootstrapSetup.update subMsg subModel

                        nextModel : Model
                        nextModel =
                            { model | page = SetupPage newSubModel }

                        ( finalModel, outCmd ) =
                            applySetupOutMsg outMsg nextModel
                    in
                    ( finalModel
                    , Cmd.batch [ Cmd.map GotSetupMsg subCmd, outCmd ]
                    )

                _ ->
                    ( model, Cmd.none )

        GotAdminMsg subMsg ->
            case model.page of
                AdminPage subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            AdminDashboard.update subMsg subModel

                        nextModel : Model
                        nextModel =
                            { model | page = AdminPage newSubModel }

                        ( finalModel, outCmd ) =
                            applyAdminOutMsg outMsg nextModel
                    in
                    ( finalModel
                    , Cmd.batch [ Cmd.map GotAdminMsg subCmd, outCmd ]
                    )

                _ ->
                    ( model, Cmd.none )

        GotAdminCreateUserMsg subMsg ->
            case model.page of
                AdminCreateUserPage subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            AdminCreateUser.update subMsg subModel

                        nextModel : Model
                        nextModel =
                            { model | page = AdminCreateUserPage newSubModel }

                        ( finalModel, outCmd ) =
                            applyAdminCreateUserOutMsg outMsg nextModel
                    in
                    ( finalModel
                    , Cmd.batch [ Cmd.map GotAdminCreateUserMsg subCmd, outCmd ]
                    )

                _ ->
                    ( model, Cmd.none )

        GotAdminEditUserMsg subMsg ->
            case model.page of
                AdminEditUserPage subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            AdminEditUser.update subMsg subModel

                        nextModel : Model
                        nextModel =
                            { model | page = AdminEditUserPage newSubModel }

                        ( finalModel, outCmd ) =
                            applyAdminEditUserOutMsg outMsg nextModel
                    in
                    ( finalModel
                    , Cmd.batch [ Cmd.map GotAdminEditUserMsg subCmd, outCmd ]
                    )

                _ ->
                    ( model, Cmd.none )

        GotFoodSearchMsg subMsg ->
            case model.page of
                FoodSearchPage subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            FoodSearch.update subMsg subModel

                        nextModel : Model
                        nextModel =
                            { model | page = FoodSearchPage newSubModel }

                        ( finalModel, outCmd ) =
                            applyFoodSearchOutMsg outMsg nextModel
                    in
                    ( finalModel
                    , Cmd.batch [ Cmd.map GotFoodSearchMsg subCmd, outCmd ]
                    )

                _ ->
                    ( model, Cmd.none )

        GotFoodDetailMsg subMsg ->
            updateFoodDetail subMsg model

        GotFoodLogDetailMsg subMsg ->
            updateFoodLogDetail subMsg model

        GotLocalContext context ->
            case model.page of
                FoodDetailPage _ ->
                    updateFoodDetail (FoodShow.LocalContextReceived context) model

                _ ->
                    ( model, Cmd.none )

        GotCustomFoodCreateMsg subMsg ->
            updateCustomFoodCreate subMsg model

        GotCustomFoodEditMsg subMsg ->
            updateCustomFoodEdit subMsg model

        GotCustomFoodsMsg subMsg ->
            updateCustomFoods subMsg model

        GotMealsMsg subMsg ->
            updateMeals subMsg model

        GotMealCreateMsg subMsg ->
            updateMealCreate subMsg model

        GotMealEditMsg subMsg ->
            updateMealEdit subMsg model

        GotMealDetailMsg subMsg ->
            updateMealDetail subMsg model


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
            let
                ( adminModel, outMsg ) =
                    AdminDashboard.init

                ( nextModel, outCmd ) =
                    applyAdminOutMsg outMsg { model | page = AdminPage adminModel }
            in
            ( nextModel, outCmd )

        AdminCreateUser ->
            let
                ( createUserModel, outMsg ) =
                    AdminCreateUser.init

                ( nextModel, outCmd ) =
                    applyAdminCreateUserOutMsg
                        outMsg
                        { model | page = AdminCreateUserPage createUserModel }
            in
            ( nextModel, outCmd )

        AdminEditUser userId ->
            let
                ( editUserModel, outMsg ) =
                    AdminEditUser.init userId

                ( nextModel, outCmd ) =
                    applyAdminEditUserOutMsg outMsg
                        { model | page = AdminEditUserPage editUserModel }
            in
            ( nextModel, outCmd )

        DiaryDay dateParam ->
            case model.today of
                Just today ->
                    let
                        ( diaryModel, outMsg ) =
                            DiaryDay.init { dateParam = dateParam, today = today }

                        ( nextModel, outCmd ) =
                            applyDiaryOutMsg outMsg { model | page = DiaryPage diaryModel }
                    in
                    ( nextModel, outCmd )

                Nothing ->
                    ( { model | page = LoadingPage }, Cmd.none )

        FoodSearch mealSlot ->
            ( { model | page = FoodSearchPage (FoodSearch.init mealSlot) }, Cmd.none )

        FoodShow productId mealSlot ->
            let
                ( foodDetailModel, outMsg ) =
                    FoodShow.init productId mealSlot

                ( nextModel, outCmd ) =
                    applyFoodDetailOutMsg outMsg { model | page = FoodDetailPage foodDetailModel }
            in
            ( nextModel, outCmd )

        FoodLogEntry logId ->
            let
                ( foodLogDetailModel, outMsg ) =
                    FoodLogEntry.init logId

                ( nextModel, outCmd ) =
                    applyFoodLogDetailOutMsg
                        outMsg
                        { model | page = FoodLogDetailPage foodLogDetailModel }
            in
            ( nextModel, outCmd )

        CustomFoodCreate ->
            let
                ( pageModel, outMsg ) =
                    CustomFoodCreate.init

                ( nextModel, outCmd ) =
                    applyCustomFoodCreateOutMsg
                        outMsg
                        { model | page = CustomFoodCreatePage pageModel }
            in
            ( nextModel, outCmd )

        CustomFoodEdit productId ->
            let
                ( pageModel, outMsg ) =
                    CustomFoodEdit.init productId

                ( nextModel, outCmd ) =
                    applyCustomFoodEditOutMsg outMsg { model | page = CustomFoodEditPage pageModel }
            in
            ( nextModel, outCmd )

        CustomFoodList ->
            let
                ( pageModel, outMsg ) =
                    CustomFoodList.init

                ( nextModel, outCmd ) =
                    applyCustomFoodsOutMsg
                        outMsg
                        { model | page = CustomFoodsPage pageModel }
            in
            ( nextModel, outCmd )

        MealList ->
            let
                ( pageModel, outMsg ) =
                    MealList.init

                ( nextModel, outCmd ) =
                    applyMealsOutMsg outMsg { model | page = MealsPage pageModel }
            in
            ( nextModel, outCmd )

        MealCreate ->
            let
                ( pageModel, outMsg ) =
                    MealCreate.init

                ( nextModel, outCmd ) =
                    applyMealCreateOutMsg outMsg { model | page = MealCreatePage pageModel }
            in
            ( nextModel, outCmd )

        MealEdit mealId ->
            let
                ( pageModel, outMsg ) =
                    MealEdit.init mealId

                ( nextModel, outCmd ) =
                    applyMealEditOutMsg outMsg { model | page = MealEditPage pageModel }
            in
            ( nextModel, outCmd )

        MealShow mealId ->
            let
                ( pageModel, outMsg ) =
                    MealShow.init mealId

                ( nextModel, outCmd ) =
                    applyMealDetailOutMsg outMsg { model | page = MealDetailPage pageModel }
            in
            ( nextModel, outCmd )

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


updateFoodDetail : FoodShow.Msg -> Model -> ( Model, Cmd Msg )
updateFoodDetail subMsg model =
    case model.page of
        FoodDetailPage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    FoodShow.update subMsg subModel

                nextModel : Model
                nextModel =
                    { model | page = FoodDetailPage newSubModel }

                ( finalModel, outCmd ) =
                    applyFoodDetailOutMsg outMsg nextModel
            in
            ( finalModel
            , Cmd.batch [ Cmd.map GotFoodDetailMsg subCmd, outCmd ]
            )

        _ ->
            ( model, Cmd.none )


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


updateFoodLogDetail : FoodLogEntry.Msg -> Model -> ( Model, Cmd Msg )
updateFoodLogDetail subMsg model =
    case model.page of
        FoodLogDetailPage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    FoodLogEntry.update subMsg subModel

                nextModel : Model
                nextModel =
                    { model | page = FoodLogDetailPage newSubModel }

                ( finalModel, outCmd ) =
                    applyFoodLogDetailOutMsg outMsg nextModel
            in
            ( finalModel
            , Cmd.batch [ Cmd.map GotFoodLogDetailMsg subCmd, outCmd ]
            )

        _ ->
            ( model, Cmd.none )


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


updateCustomFoodCreate : CustomFoodCreate.Msg -> Model -> ( Model, Cmd Msg )
updateCustomFoodCreate subMsg model =
    case model.page of
        CustomFoodCreatePage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    CustomFoodCreate.update subMsg subModel

                ( finalModel, outCmd ) =
                    applyCustomFoodCreateOutMsg
                        outMsg
                        { model | page = CustomFoodCreatePage newSubModel }
            in
            ( finalModel, Cmd.batch [ Cmd.map GotCustomFoodCreateMsg subCmd, outCmd ] )

        _ ->
            ( model, Cmd.none )


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


updateCustomFoodEdit : CustomFoodEdit.Msg -> Model -> ( Model, Cmd Msg )
updateCustomFoodEdit subMsg model =
    case model.page of
        CustomFoodEditPage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    CustomFoodEdit.update subMsg subModel

                ( finalModel, outCmd ) =
                    applyCustomFoodEditOutMsg
                        outMsg
                        { model | page = CustomFoodEditPage newSubModel }
            in
            ( finalModel, Cmd.batch [ Cmd.map GotCustomFoodEditMsg subCmd, outCmd ] )

        _ ->
            ( model, Cmd.none )


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


updateCustomFoods : CustomFoodList.Msg -> Model -> ( Model, Cmd Msg )
updateCustomFoods subMsg model =
    case model.page of
        CustomFoodsPage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    CustomFoodList.update subMsg subModel

                ( finalModel, outCmd ) =
                    applyCustomFoodsOutMsg outMsg { model | page = CustomFoodsPage newSubModel }
            in
            ( finalModel, Cmd.batch [ Cmd.map GotCustomFoodsMsg subCmd, outCmd ] )

        _ ->
            ( model, Cmd.none )


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


updateMeals : MealList.Msg -> Model -> ( Model, Cmd Msg )
updateMeals subMsg model =
    case model.page of
        MealsPage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    MealList.update subMsg subModel

                ( finalModel, outCmd ) =
                    applyMealsOutMsg outMsg { model | page = MealsPage newSubModel }
            in
            ( finalModel, Cmd.batch [ Cmd.map GotMealsMsg subCmd, outCmd ] )

        _ ->
            ( model, Cmd.none )


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


updateMealCreate : MealCreate.Msg -> Model -> ( Model, Cmd Msg )
updateMealCreate subMsg model =
    case model.page of
        MealCreatePage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    MealCreate.update subMsg subModel

                ( finalModel, outCmd ) =
                    applyMealCreateOutMsg outMsg { model | page = MealCreatePage newSubModel }
            in
            ( finalModel, Cmd.batch [ Cmd.map GotMealCreateMsg subCmd, outCmd ] )

        _ ->
            ( model, Cmd.none )


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


updateMealEdit : MealEdit.Msg -> Model -> ( Model, Cmd Msg )
updateMealEdit subMsg model =
    case model.page of
        MealEditPage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    MealEdit.update subMsg subModel

                ( finalModel, outCmd ) =
                    applyMealEditOutMsg outMsg { model | page = MealEditPage newSubModel }
            in
            ( finalModel, Cmd.batch [ Cmd.map GotMealEditMsg subCmd, outCmd ] )

        _ ->
            ( model, Cmd.none )


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
                    mealId
                    "100"
                    defaultCode
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


updateMealDetail : MealShow.Msg -> Model -> ( Model, Cmd Msg )
updateMealDetail subMsg model =
    case model.page of
        MealDetailPage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    MealShow.update subMsg subModel

                ( finalModel, outCmd ) =
                    applyMealDetailOutMsg outMsg { model | page = MealDetailPage newSubModel }
            in
            ( finalModel, Cmd.batch [ Cmd.map GotMealDetailMsg subCmd, outCmd ] )

        _ ->
            ( model, Cmd.none )


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
                    mealId
                    "100"
                    defaultCode
                    (GotMealDetailMsg << MealShow.NutrientPreviewLoaded)
                ]
            )

        MealShow.RequestNutrientPreview mealId amount unit ->
            ( model
            , Api.Meals.getMealNutrients
                mealId
                amount
                unit
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
        [ Element.layoutWith
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
            Ui.layout <|
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
        (if showsAppChrome model then
            [ topBarView model
            , Element.el
                [ Element.width Element.fill
                , Element.height Element.fill
                , Region.mainContent
                ]
                (pageView model)
            ]

         else
            [ Element.el
                [ Element.width Element.fill
                , Element.height Element.fill
                , Region.mainContent
                ]
                (pageView model)
            ]
        )


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
        meta : ScreenMeta
        meta =
            screenMeta model.route
    in
    Element.row
        [ Element.width Element.fill
        , Element.height (Element.px 58)
        , Element.paddingXY Ui.space16 0
        , Element.spacing Ui.space12
        , Background.color Ui.cardBg
        , Font.color Ui.darkColor
        ]
        [ leadingButton meta.leading
        , Element.el
            [ Element.width Element.fill
            , Element.clip
            , Ui.heading3
            , Font.bold
            , Region.heading 1
            ]
            (Element.text meta.title)
        , profileButton model
        ]


leadingButton : LeadingAction -> Element.Element Msg
leadingButton leading =
    case leading of
        OpenMenu ->
            Ui.iconButton { label = "☰", title = "Menu", onPress = MenuClicked }

        GoBack route ->
            Ui.iconButton { label = "←", title = "Back", onPress = AppBackClicked route }

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
        (Ui.iconButton { label = letter, title = "Profile", onPress = ProfileClicked })


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
        , Background.color Ui.cardBg
        , Border.rounded 20
        , Ui.cardShadow
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
        , Background.color Ui.cardBg
        , Ui.cardShadow
        , Region.navigation
        ]
        (Element.row [ Element.spacing Ui.space8 ]
            [ Ui.iconButton { label = "☰", title = "Close", onPress = DrawerClosed }
            , Element.el [ Ui.heading2, Font.bold ] (Element.text "CalCo")
            ]
            :: Ui.hairline
            :: drawerItems model
        )


drawerItems : Model -> List (Element.Element Msg)
drawerItems model =
    if Session.isAdmin model.session then
        [ drawerItem model.route "Admin" AdminDashboard ]

    else
        [ drawerItem model.route "Diary" (DiaryDay Nothing)
        , drawerItem model.route "Search Foods" (FoodSearch Nothing)
        , drawerItem model.route "My Foods" CustomFoodList
        , drawerItem model.route "My Meals" MealList
        ]


drawerItem : Route -> String -> Route -> Element.Element Msg
drawerItem current label target =
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
                Ui.drawerSelectionBg

             else
                Ui.cardBg
            )
        , Font.color
            (if selected then
                Ui.primaryTeal

             else
                Ui.darkColor
            )
        , Font.medium
        ]
        { onPress = Just (AppNavigationClicked target)
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
    [ Element.el
        [ Ui.caption
        , Font.color Ui.mutedColor
        ]
        (Element.text
            (case model.session of
                Session.Authenticated identity ->
                    "Signed in as " ++ identity.username

                _ ->
                    "Signed in"
            )
        )
    , Ui.button "Logout" LogoutClicked
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
        Element.el [ Element.centerX, Element.centerY ] (Ui.loading "Loading...")

    else
        let
            device : Element.Device
            device =
                model.device
        in
        case model.page of
            LoadingPage ->
                Element.el [ Element.centerX, Element.centerY ] (Ui.loading "Loading...")

            LoginPage loginModel ->
                Element.map GotLoginMsg (AuthLogin.view { model = loginModel, device = device })

            SetupPage setupModel ->
                Element.map GotSetupMsg
                    (BootstrapSetup.view { model = setupModel, device = device })

            AdminPage adminModel ->
                Element.map GotAdminMsg
                    (AdminDashboard.view { model = adminModel, device = device })

            AdminCreateUserPage createUserModel ->
                Element.map GotAdminCreateUserMsg
                    (AdminCreateUser.view { model = createUserModel, device = device })

            AdminEditUserPage editUserModel ->
                Element.map GotAdminEditUserMsg
                    (AdminEditUser.view { model = editUserModel, device = device })

            DiaryPage diaryModel ->
                Element.map GotDiaryMsg (DiaryDay.view { model = diaryModel, device = device })

            FoodSearchPage foodSearchModel ->
                Element.map GotFoodSearchMsg
                    (FoodSearch.view { model = foodSearchModel, device = device })

            FoodDetailPage foodDetailModel ->
                Element.map GotFoodDetailMsg
                    (FoodShow.view { model = foodDetailModel, device = device })

            FoodLogDetailPage foodLogDetailModel ->
                Element.map GotFoodLogDetailMsg
                    (FoodLogEntry.view { model = foodLogDetailModel, device = device })

            CustomFoodCreatePage customFoodCreateModel ->
                Element.map GotCustomFoodCreateMsg
                    (CustomFoodCreate.view { model = customFoodCreateModel, device = device })

            CustomFoodEditPage customFoodEditModel ->
                Element.map GotCustomFoodEditMsg
                    (CustomFoodEdit.view { model = customFoodEditModel, device = device })

            CustomFoodsPage customFoodsModel ->
                Element.map GotCustomFoodsMsg
                    (CustomFoodList.view { model = customFoodsModel, device = device })

            MealsPage mealsModel ->
                Element.map GotMealsMsg (MealList.view { model = mealsModel, device = device })

            MealCreatePage mealCreateModel ->
                Element.map GotMealCreateMsg
                    (MealCreate.view { model = mealCreateModel, device = device })

            MealEditPage mealEditModel ->
                Element.map GotMealEditMsg
                    (MealEdit.view { model = mealEditModel, device = device })

            MealDetailPage mealDetailModel ->
                Element.map GotMealDetailMsg
                    (MealShow.view { model = mealDetailModel, device = device })

            PlaceholderPage message ->
                Element.el [ Element.padding Ui.space24 ] (Element.text message)
