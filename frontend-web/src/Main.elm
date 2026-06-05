port module Main exposing (Flags, Model, Msg, PageModel, main)

import Access
import Api.Admin
import Api.Auth
import Api.Client as Client
import Api.Foods
import Api.Logs
import Api.Meals
import Browser
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
import Lib.Date as LocalDate exposing (LocalDate)
import Page.Admin.BootstrapSetup as Setup
import Page.Admin.CreateUser as AdminCreateUser
import Page.Admin.Dashboard as AdminDashboard
import Page.Admin.EditUser as AdminEditUser
import Page.Auth.Login as Login
import Page.CustomFood.Create as CustomFoodCreate
import Page.CustomFood.Edit as CustomFoodEdit
import Page.Diary.Index as Diary
import Page.Food.Detail as FoodDetail
import Page.Food.Search as FoodSearch
import Page.FoodLog.Detail as FoodLogDetail
import Page.Meal.Detail as MealDetail
import Page.Meal.Form as MealForm
import Page.Meal.Index as Meals
import Session
import Task
import Time
import Ui
import Url exposing (Url)


type alias Flags =
    {}


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
    }


type PageModel
    = LoadingPage
    | LoginPage Login.Model
    | SetupPage Setup.Model
    | AdminPage AdminDashboard.Model
    | AdminCreateUserPage AdminCreateUser.Model
    | AdminEditUserPage AdminEditUser.Model
    | DiaryPage Diary.Model
    | FoodSearchPage FoodSearch.Model
    | FoodDetailPage FoodDetail.Model
    | FoodLogDetailPage FoodLogDetail.Model
    | CustomFoodCreatePage CustomFoodCreate.Model
    | CustomFoodEditPage CustomFoodEdit.Model
    | MealsPage Meals.Model
    | MealFormPage MealForm.Model
    | MealDetailPage MealDetail.Model
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
    | GotLoginMsg Login.Msg
    | GotSetupMsg Setup.Msg
    | GotAdminMsg AdminDashboard.Msg
    | GotAdminCreateUserMsg AdminCreateUser.Msg
    | GotAdminEditUserMsg AdminEditUser.Msg
    | GotDiaryMsg Diary.Msg
    | GotFoodSearchMsg FoodSearch.Msg
    | GotFoodDetailMsg FoodDetail.Msg
    | GotFoodLogDetailMsg FoodLogDetail.Msg
    | GotCustomFoodCreateMsg CustomFoodCreate.Msg
    | GotCustomFoodEditMsg CustomFoodEdit.Msg
    | GotMealsMsg Meals.Msg
    | GotMealFormMsg MealForm.Msg
    | GotMealDetailMsg MealDetail.Msg
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
    localContextReceived GotLocalContext


init : Flags -> Url -> Nav.Key -> ( Model, Cmd Msg )
init _ url key =
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

        GotLoginMsg subMsg ->
            case model.page of
                LoginPage subModel ->
                    let
                        ( newSubModel, subCmd, outMsg ) =
                            Login.update subMsg subModel

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
                            Diary.update subMsg subModel

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
                            Setup.update subMsg subModel

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
                    updateFoodDetail (FoodDetail.LocalContextReceived context) model

                _ ->
                    ( model, Cmd.none )

        GotCustomFoodCreateMsg subMsg ->
            updateCustomFoodCreate subMsg model

        GotCustomFoodEditMsg subMsg ->
            updateCustomFoodEdit subMsg model

        GotMealsMsg subMsg ->
            updateMeals subMsg model

        GotMealFormMsg subMsg ->
            updateMealForm subMsg model

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
        Login ->
            ( { model | page = LoginPage Login.init }, Cmd.none )

        Setup ->
            ( { model | page = SetupPage Setup.init }, Cmd.none )

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

        Diary dateParam ->
            case model.today of
                Just today ->
                    let
                        ( diaryModel, outMsg ) =
                            Diary.init { dateParam = dateParam, today = today }

                        ( nextModel, outCmd ) =
                            applyDiaryOutMsg outMsg { model | page = DiaryPage diaryModel }
                    in
                    ( nextModel, outCmd )

                Nothing ->
                    ( { model | page = LoadingPage }, Cmd.none )

        FoodSearch mealSlot ->
            ( { model | page = FoodSearchPage (FoodSearch.init mealSlot) }, Cmd.none )

        FoodDetail productId mealSlot ->
            let
                ( foodDetailModel, outMsg ) =
                    FoodDetail.init productId mealSlot

                ( nextModel, outCmd ) =
                    applyFoodDetailOutMsg outMsg { model | page = FoodDetailPage foodDetailModel }
            in
            ( nextModel, outCmd )

        FoodLogDetail logId ->
            let
                ( foodLogDetailModel, outMsg ) =
                    FoodLogDetail.init logId

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

        Meals ->
            let
                ( pageModel, outMsg ) =
                    Meals.init

                ( nextModel, outCmd ) =
                    applyMealsOutMsg outMsg { model | page = MealsPage pageModel }
            in
            ( nextModel, outCmd )

        MealCreate ->
            let
                ( pageModel, outMsg ) =
                    MealForm.initCreate

                ( nextModel, outCmd ) =
                    applyMealFormOutMsg outMsg { model | page = MealFormPage pageModel }
            in
            ( nextModel, outCmd )

        MealEdit mealId ->
            let
                ( pageModel, outMsg ) =
                    MealForm.initEdit mealId

                ( nextModel, outCmd ) =
                    applyMealFormOutMsg outMsg { model | page = MealFormPage pageModel }
            in
            ( nextModel, outCmd )

        MealDetail mealId ->
            let
                ( pageModel, outMsg ) =
                    MealDetail.init mealId

                ( nextModel, outCmd ) =
                    applyMealDetailOutMsg outMsg { model | page = MealDetailPage pageModel }
            in
            ( nextModel, outCmd )

        _ ->
            ( { model | page = PlaceholderPage "This route is not migrated yet." }, Cmd.none )


applyLoginOutMsg : Login.OutMsg -> Model -> ( Model, Cmd Msg )
applyLoginOutMsg outMsg model =
    case outMsg of
        Login.NoOp ->
            ( model, Cmd.none )

        Login.RequestLogin request ->
            ( model, Api.Auth.login request (GotLoginMsg << Login.LoginCompleted) )

        Login.LoginSucceeded loginSession ->
            let
                nextSession : Session.Session
                nextSession =
                    Session.applyAuthResult (Ok loginSession) model.session
            in
            ( { model | session = nextSession }, Nav.replaceUrl model.key "/" )


applySetupOutMsg : Setup.OutMsg -> Model -> ( Model, Cmd Msg )
applySetupOutMsg outMsg model =
    case outMsg of
        Setup.NoOp ->
            ( model, Cmd.none )

        Setup.RequestCreateAdmin request ->
            ( model, Api.Auth.createAdmin request (GotSetupMsg << Setup.CreateAdminCompleted) )

        Setup.CreateAdminSucceeded loginSession ->
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


applyDiaryOutMsg : Diary.OutMsg -> Model -> ( Model, Cmd Msg )
applyDiaryOutMsg outMsg model =
    case outMsg of
        Diary.NoOp ->
            ( model, Cmd.none )

        Diary.RequestDiaryData date ->
            ( model
            , Cmd.map GotDiaryMsg (Api.Logs.listLogs date (Diary.LogsLoaded date))
            )

        Diary.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        Diary.SessionExpired ->
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


updateFoodDetail : FoodDetail.Msg -> Model -> ( Model, Cmd Msg )
updateFoodDetail subMsg model =
    case model.page of
        FoodDetailPage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    FoodDetail.update subMsg subModel

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


applyFoodDetailOutMsg : FoodDetail.OutMsg -> Model -> ( Model, Cmd Msg )
applyFoodDetailOutMsg outMsg model =
    case outMsg of
        FoodDetail.NoOp ->
            ( model, Cmd.none )

        FoodDetail.RequestInitialData productId ->
            ( model
            , Cmd.batch
                [ Api.Foods.getFoodDetail productId (GotFoodDetailMsg << FoodDetail.FoodLoaded)
                , Api.Foods.listUnits (GotFoodDetailMsg << FoodDetail.UnitsLoaded)
                ]
            )

        FoodDetail.RequestLocalContext ->
            ( model, requestLocalContext () )

        FoodDetail.RequestCreateLog request ->
            ( model, Api.Logs.createLog request (GotFoodDetailMsg << FoodDetail.LogCompleted) )

        FoodDetail.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        FoodDetail.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


updateFoodLogDetail : FoodLogDetail.Msg -> Model -> ( Model, Cmd Msg )
updateFoodLogDetail subMsg model =
    case model.page of
        FoodLogDetailPage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    FoodLogDetail.update subMsg subModel

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


applyFoodLogDetailOutMsg : FoodLogDetail.OutMsg -> Model -> ( Model, Cmd Msg )
applyFoodLogDetailOutMsg outMsg model =
    case outMsg of
        FoodLogDetail.NoOp ->
            ( model, Cmd.none )

        FoodLogDetail.RequestInitialData logId ->
            ( model
            , Cmd.batch
                [ Api.Logs.getLog logId (GotFoodLogDetailMsg << FoodLogDetail.LogLoaded)
                , Api.Foods.listUnits (GotFoodLogDetailMsg << FoodLogDetail.UnitsLoaded)
                ]
            )

        FoodLogDetail.RequestProductDetail productId ->
            ( model
            , Api.Foods.getFoodDetail
                productId
                (GotFoodLogDetailMsg << FoodLogDetail.ProductDetailLoaded)
            )

        FoodLogDetail.RequestMealName mealId ->
            ( model
            , Api.Meals.getMealName
                mealId
                (GotFoodLogDetailMsg << FoodLogDetail.MealNameLoaded)
            )

        FoodLogDetail.RequestUpdateLog logId request ->
            ( model
            , Api.Logs.updateLog
                logId
                request
                (GotFoodLogDetailMsg << FoodLogDetail.UpdateCompleted)
            )

        FoodLogDetail.RequestDeleteLog logId ->
            ( model
            , Api.Logs.deleteLog
                logId
                (GotFoodLogDetailMsg << FoodLogDetail.DeleteCompleted)
            )

        FoodLogDetail.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        FoodLogDetail.SessionExpired ->
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

        CustomFoodEdit.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        CustomFoodEdit.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


updateMeals : Meals.Msg -> Model -> ( Model, Cmd Msg )
updateMeals subMsg model =
    case model.page of
        MealsPage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    Meals.update subMsg subModel

                ( finalModel, outCmd ) =
                    applyMealsOutMsg outMsg { model | page = MealsPage newSubModel }
            in
            ( finalModel, Cmd.batch [ Cmd.map GotMealsMsg subCmd, outCmd ] )

        _ ->
            ( model, Cmd.none )


applyMealsOutMsg : Meals.OutMsg -> Model -> ( Model, Cmd Msg )
applyMealsOutMsg outMsg model =
    case outMsg of
        Meals.NoOp ->
            ( model, Cmd.none )

        Meals.RequestMeals ->
            ( model, Api.Meals.listMeals (GotMealsMsg << Meals.MealsLoaded) )

        Meals.RequestDeleteMeal mealId ->
            ( model, Api.Meals.deleteMeal mealId (GotMealsMsg << Meals.DeleteCompleted mealId) )

        Meals.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        Meals.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


updateMealForm : MealForm.Msg -> Model -> ( Model, Cmd Msg )
updateMealForm subMsg model =
    case model.page of
        MealFormPage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    MealForm.update subMsg subModel

                ( finalModel, outCmd ) =
                    applyMealFormOutMsg outMsg { model | page = MealFormPage newSubModel }
            in
            ( finalModel, Cmd.batch [ Cmd.map GotMealFormMsg subCmd, outCmd ] )

        _ ->
            ( model, Cmd.none )


applyMealFormOutMsg : MealForm.OutMsg -> Model -> ( Model, Cmd Msg )
applyMealFormOutMsg outMsg model =
    case outMsg of
        MealForm.NoOp ->
            ( model, Cmd.none )

        MealForm.RequestMeal mealId ->
            ( model
            , Cmd.batch
                [ Api.Meals.getMeal mealId (GotMealFormMsg << MealForm.MealLoaded)
                , Api.Meals.getMealNutrients
                    mealId
                    "100"
                    defaultCode
                    (GotMealFormMsg << MealForm.NutrientPreviewLoaded)
                ]
            )

        MealForm.RequestProductName productId ->
            ( model
            , Api.Foods.getFoodDetail
                productId
                (GotMealFormMsg << MealForm.ProductNameLoaded productId)
            )

        MealForm.RequestProductSearch rowId token request ->
            ( model
            , Api.Foods.searchFoods
                request
                (GotMealFormMsg << MealForm.ComponentSearchCompleted rowId token)
            )

        MealForm.RequestCategorySuggestions rowId token request ->
            ( model
            , Api.Foods.listCategorySuggestions
                request
                (GotMealFormMsg << MealForm.ComponentCategoriesCompleted rowId token)
            )

        MealForm.RequestProductAndCats requests ->
            ( model
            , Cmd.batch
                [ Api.Foods.searchFoods
                    requests.searchRequest
                    (GotMealFormMsg
                        << MealForm.ComponentSearchCompleted
                            requests.rowId
                            requests.searchToken
                    )
                , Api.Foods.listCategorySuggestions
                    requests.categoryRequest
                    (GotMealFormMsg
                        << MealForm.ComponentCategoriesCompleted
                            requests.rowId
                            requests.categoryToken
                    )
                ]
            )

        MealForm.RequestCreateMeal request ->
            ( model, Api.Meals.createMeal request (GotMealFormMsg << MealForm.SaveCompleted) )

        MealForm.RequestUpdateMeal mealId request ->
            ( model
            , Api.Meals.updateMeal
                mealId
                request
                (GotMealFormMsg << MealForm.SaveCompleted)
            )

        MealForm.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        MealForm.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


updateMealDetail : MealDetail.Msg -> Model -> ( Model, Cmd Msg )
updateMealDetail subMsg model =
    case model.page of
        MealDetailPage subModel ->
            let
                ( newSubModel, subCmd, outMsg ) =
                    MealDetail.update subMsg subModel

                ( finalModel, outCmd ) =
                    applyMealDetailOutMsg outMsg { model | page = MealDetailPage newSubModel }
            in
            ( finalModel, Cmd.batch [ Cmd.map GotMealDetailMsg subCmd, outCmd ] )

        _ ->
            ( model, Cmd.none )


applyMealDetailOutMsg : MealDetail.OutMsg -> Model -> ( Model, Cmd Msg )
applyMealDetailOutMsg outMsg model =
    case outMsg of
        MealDetail.NoOp ->
            ( model, Cmd.none )

        MealDetail.RequestInitialData mealId ->
            ( model
            , Cmd.batch
                [ Api.Meals.getMeal mealId (GotMealDetailMsg << MealDetail.MealLoaded)
                , Api.Foods.listUnits (GotMealDetailMsg << MealDetail.UnitsLoaded)
                , Api.Meals.getMealNutrients
                    mealId
                    "100"
                    defaultCode
                    (GotMealDetailMsg << MealDetail.NutrientPreviewLoaded)
                ]
            )

        MealDetail.RequestNutrientPreview mealId amount unit ->
            ( model
            , Api.Meals.getMealNutrients
                mealId
                amount
                unit
                (GotMealDetailMsg << MealDetail.NutrientPreviewLoaded)
            )

        MealDetail.RequestProductDetail productId ->
            ( model
            , Api.Foods.getFoodDetail
                productId
                (GotMealDetailMsg << MealDetail.ProductDetailLoaded productId)
            )

        MealDetail.RequestDeleteMeal mealId ->
            ( model, Api.Meals.deleteMeal mealId (GotMealDetailMsg << MealDetail.DeleteCompleted) )

        MealDetail.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        MealDetail.SessionExpired ->
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
        [ Element.layout [] <|
            Ui.layout <|
                appFrame model
        ]
    }


appFrame : Model -> Element.Element Msg
appFrame model =
    let
        overlays : List (Element.Attribute Msg)
        overlays =
            drawerOverlay model ++ profileOverlay model
    in
    Element.column
        ([ Element.width Element.fill
         , Element.height Element.fill
         ]
            ++ overlays
        )
        (if showsAppChrome model then
            [ topBarView model
            , Element.el
                [ Element.width Element.fill, Element.height Element.fill ]
                (pageView model)
            ]

         else
            [ Element.el
                [ Element.width Element.fill, Element.height Element.fill ]
                (pageView model)
            ]
        )


showsAppChrome : Model -> Bool
showsAppChrome model =
    Session.isAuthenticated model.session
        && model.page
        /= LoadingPage
        && (case model.route of
                Login ->
                    False

                Setup ->
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
        , Element.paddingXY 16 0
        , Element.spacing 12
        , Background.color Ui.cardBg
        , Border.widthEach { top = 0, right = 0, bottom = 1, left = 0 }
        , Border.color Ui.borderGray
        , Font.color Ui.darkColor
        ]
        [ leadingButton meta.leading
        , Element.el
            [ Element.width Element.fill
            , Element.clip
            , Ui.heading3
            , Font.bold
            ]
            (Element.text ("CalCo | " ++ meta.title))
        , profileButton model
        ]


leadingButton : LeadingAction -> Element.Element Msg
leadingButton leading =
    case leading of
        OpenMenu ->
            iconButton "Menu" MenuClicked

        GoBack route ->
            iconButton "Back" (AppBackClicked route)

        NoLeadingAction ->
            Element.el [ Element.width (Element.px 56) ] Element.none


iconButton : String -> Msg -> Element.Element Msg
iconButton label msg =
    Input.button
        [ Element.width (Element.px 56)
        , Element.height (Element.px 40)
        , Border.rounded 6
        , Border.width 1
        , Border.color Ui.borderGray
        , Font.color Ui.darkColor
        , Ui.caption
        , Font.medium
        ]
        { onPress = Just msg
        , label = Element.el [ Element.centerX, Element.centerY ] (Element.text label)
        }


profileButton : Model -> Element.Element Msg
profileButton model =
    let
        label : String
        label =
            case model.session of
                Session.Authenticated identity ->
                    identity.username

                _ ->
                    "Profile"
    in
    Input.button
        [ Element.height (Element.px 40)
        , Element.paddingXY 12 0
        , Border.rounded 6
        , Border.width 1
        , Border.color Ui.borderGray
        , Font.color Ui.darkColor
        , Ui.caption
        , Font.medium
        ]
        { onPress = Just ProfileClicked
        , label = Element.text label
        }


screenMeta : Route -> ScreenMeta
screenMeta route =
    case route of
        Root ->
            { title = "Diary", leading = OpenMenu }

        Diary _ ->
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
            , leading = GoBack (Diary Nothing)
            }

        FoodDetail _ maybeSlot ->
            { title = "Log Food", leading = GoBack (FoodSearch maybeSlot) }

        FoodLogDetail _ ->
            { title = "Edit Log", leading = GoBack (Diary Nothing) }

        CustomFoodCreate ->
            { title = "Create Food", leading = GoBack (FoodSearch Nothing) }

        CustomFoodEdit _ ->
            { title = "Edit Food", leading = GoBack (FoodSearch Nothing) }

        Meals ->
            { title = "My Meals", leading = GoBack (Diary Nothing) }

        MealCreate ->
            { title = "Create Meal", leading = GoBack Meals }

        MealDetail _ ->
            { title = "Meal", leading = GoBack Meals }

        MealEdit _ ->
            { title = "Edit Meal", leading = GoBack Meals }

        Login ->
            { title = "Login", leading = NoLeadingAction }

        Setup ->
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
        , Element.padding 20
        , Element.spacing 12
        , Background.color Ui.cardBg
        , Border.widthEach { top = 0, right = 1, bottom = 0, left = 0 }
        , Border.color Ui.borderGray
        ]
        (Element.el [ Ui.heading2, Font.bold ] (Element.text "CalCo")
            :: drawerItems model
        )


drawerItems : Model -> List (Element.Element Msg)
drawerItems model =
    if Session.isAdmin model.session then
        [ drawerItem model.route "Admin" AdminDashboard ]

    else
        [ drawerItem model.route "Diary" (Diary Nothing)
        , drawerItem model.route "Search Foods" (FoodSearch Nothing)
        , drawerItem model.route "My Meals" Meals
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
        , Element.paddingXY 12 12
        , Border.rounded 6
        , Background.color
            (if selected then
                Element.rgb255 230 247 247

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
        FoodDetail _ _ ->
            FoodSearch Nothing

        CustomFoodCreate ->
            FoodSearch Nothing

        CustomFoodEdit _ ->
            FoodSearch Nothing

        AdminCreateUser ->
            AdminDashboard

        AdminEditUser _ ->
            AdminDashboard

        MealCreate ->
            Meals

        MealDetail _ ->
            Meals

        MealEdit _ ->
            Meals

        FoodLogDetail _ ->
            Diary Nothing

        Diary _ ->
            Diary Nothing

        FoodSearch _ ->
            FoodSearch Nothing

        other ->
            other


profileOverlay : Model -> List (Element.Attribute Msg)
profileOverlay model =
    if model.profileOpen && showsAppChrome model then
        [ Element.inFront
            (Element.column
                [ Element.alignRight
                , Element.moveDown 62
                , Element.moveLeft 16
                , Element.width (Element.px 240)
                , Element.padding 12
                , Element.spacing 10
                , Background.color Ui.cardBg
                , Border.rounded 8
                , Border.width 1
                , Border.color Ui.borderGray
                ]
                (profileMenuContent model)
            )
        ]

    else
        []


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
        case model.page of
            LoadingPage ->
                Element.el [ Element.centerX, Element.centerY ] (Ui.loading "Loading...")

            LoginPage loginModel ->
                Element.map GotLoginMsg (Login.view loginModel)

            SetupPage setupModel ->
                Element.map GotSetupMsg (Setup.view setupModel)

            AdminPage adminModel ->
                Element.map GotAdminMsg (AdminDashboard.view adminModel)

            AdminCreateUserPage createUserModel ->
                Element.map GotAdminCreateUserMsg (AdminCreateUser.view createUserModel)

            AdminEditUserPage editUserModel ->
                Element.map GotAdminEditUserMsg (AdminEditUser.view editUserModel)

            DiaryPage diaryModel ->
                Element.map GotDiaryMsg (Diary.view diaryModel)

            FoodSearchPage foodSearchModel ->
                Element.map GotFoodSearchMsg (FoodSearch.view foodSearchModel)

            FoodDetailPage foodDetailModel ->
                Element.map GotFoodDetailMsg (FoodDetail.view foodDetailModel)

            FoodLogDetailPage foodLogDetailModel ->
                Element.map GotFoodLogDetailMsg (FoodLogDetail.view foodLogDetailModel)

            CustomFoodCreatePage customFoodCreateModel ->
                Element.map GotCustomFoodCreateMsg (CustomFoodCreate.view customFoodCreateModel)

            CustomFoodEditPage customFoodEditModel ->
                Element.map GotCustomFoodEditMsg (CustomFoodEdit.view customFoodEditModel)

            MealsPage mealsModel ->
                Element.map GotMealsMsg (Meals.view mealsModel)

            MealFormPage mealFormModel ->
                Element.map GotMealFormMsg (MealForm.view mealFormModel)

            MealDetailPage mealDetailModel ->
                Element.map GotMealDetailMsg (MealDetail.view mealDetailModel)

            PlaceholderPage message ->
                Element.el [ Element.padding 24 ] (Element.text message)
