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
import Data.ItemRef exposing (ItemRef)
import Data.LocalDate as LocalDate exposing (LocalDate)
import Element
import Element.Background as Background
import Element.Font as Font
import Page.AdminDashboard as AdminDashboard
import Page.BootstrapAdminSetup as Setup
import Page.CustomFood.Create as CustomFoodCreate
import Page.CustomFood.Edit as CustomFoodEdit
import Page.Diary as Diary
import Page.FoodDetail as FoodDetail
import Page.FoodLogDetail as FoodLogDetail
import Page.FoodSearch as FoodSearch
import Page.Login as Login
import Page.MealDetail as MealDetail
import Page.MealForm as MealForm
import Page.Meals as Meals
import Route exposing (Route(..))
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
    , pendingSession : Maybe (Result Client.ApiError Auth.LoginSession)
    , pendingBootstrap : Maybe (Result Client.ApiError Auth.BootstrapStatus)
    , timeZone : Maybe Time.Zone
    , today : Maybe LocalDate
    , page : PageModel
    }


type PageModel
    = LoadingPage
    | LoginPage Login.Model
    | SetupPage Setup.Model
    | AdminPage AdminDashboard.Model
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
    | GotLoginMsg Login.Msg
    | GotSetupMsg Setup.Msg
    | GotAdminMsg AdminDashboard.Msg
    | GotDiaryMsg Diary.Msg
    | GotFoodSearchMsg FoodSearch.Msg
    | GotFoodDetailMsg FoodDetail.Msg
    | GotFoodLogDetailMsg FoodLogDetail.Msg
    | GotCustomFoodCreateMsg CustomFoodCreate.Msg
    | GotCustomFoodEditMsg CustomFoodEdit.Msg
    | GotMealsMsg Meals.Msg
    | GotMealFormMsg MealForm.Msg
    | GotMealDetailMsg MealDetail.Msg
    | GotLocalTimestamp String


port requestLocalTimestamp : () -> Cmd msg


port localTimestampReceived : (String -> msg) -> Sub msg


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
    localTimestampReceived GotLocalTimestamp


init : Flags -> Url -> Nav.Key -> ( Model, Cmd Msg )
init _ url key =
    ( { key = key
      , route = Route.fromUrl url
      , session = Session.init
      , pendingSession = Nothing
      , pendingBootstrap = Nothing
      , timeZone = Nothing
      , today = Nothing
      , page = LoadingPage
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
                    ( model, Nav.pushUrl model.key (Url.toString url) )

                Browser.External href ->
                    ( model, Nav.load href )

        UrlChanged url ->
            let
                route : Route
                route =
                    Route.fromUrl url
            in
            changeRouteTo route { model | route = route }

        GotSession result ->
            applyBootstrapProgress { model | pendingSession = Just result }

        GotBootstrapStatus result ->
            applyBootstrapProgress { model | pendingBootstrap = Just result }

        GotTimeZone zone ->
            ( { model | timeZone = Just zone }, Task.perform GotNow Time.now )

        GotNow posix ->
            case model.timeZone of
                Just zone ->
                    changeRouteTo model.route { model | today = Just (LocalDate.fromPosix zone posix) }

                Nothing ->
                    ( model, Cmd.none )

        LogoutClicked ->
            ( model, Api.Auth.logout LogoutCompleted )

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

        GotLocalTimestamp loggedAt ->
            case model.page of
                FoodDetailPage _ ->
                    updateFoodDetail (FoodDetail.LocalTimestampReceived loggedAt) model

                MealDetailPage _ ->
                    updateMealDetail (MealDetail.LocalTimestampReceived loggedAt) model

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
                sessionWithAuth : Session.Session
                sessionWithAuth =
                    Session.applyAuthResult sessionResult model.session

                nextSession : Session.Session
                nextSession =
                    case bootstrapResult of
                        Ok status ->
                            Session.setAdminExists status.adminExists sessionWithAuth

                        Err _ ->
                            Session.setAdminExists True sessionWithAuth

                nextModel : Model
                nextModel =
                    { model | session = nextSession }
            in
            changeRouteTo nextModel.route nextModel

        _ ->
            ( model, Cmd.none )


changeRouteTo : Route -> Model -> ( Model, Cmd Msg )
changeRouteTo route model =
    case Access.resolveRoute model.session route of
        Access.Render renderRoute ->
            loadPage renderRoute model

        Access.Navigate target ->
            ( model, Nav.replaceUrl model.key (Route.routeToPath target) )


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
                    applyFoodLogDetailOutMsg outMsg { model | page = FoodLogDetailPage foodLogDetailModel }
            in
            ( nextModel, outCmd )

        CustomFoodCreate ->
            let
                ( pageModel, outMsg ) =
                    CustomFoodCreate.init

                ( nextModel, outCmd ) =
                    applyCustomFoodCreateOutMsg outMsg { model | page = CustomFoodCreatePage pageModel }
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
                    model.session
                        |> Session.applyAuthResult (Ok loginSession)
                        |> Session.setAdminExists True
            in
            ( { model | session = nextSession }, Nav.replaceUrl model.key "/admin" )


applyAdminOutMsg : AdminDashboard.OutMsg -> Model -> ( Model, Cmd Msg )
applyAdminOutMsg outMsg model =
    case outMsg of
        AdminDashboard.NoOp ->
            ( model, Cmd.none )

        AdminDashboard.RequestUsers ->
            ( model, Api.Admin.listUsers (GotAdminMsg << AdminDashboard.UsersLoaded) )

        AdminDashboard.RequestCreateUser request ->
            ( model, Api.Admin.createUser request (GotAdminMsg << AdminDashboard.CreateCompleted) )

        AdminDashboard.RequestResetPassword userId request ->
            ( model, Api.Admin.resetPassword userId request (GotAdminMsg << AdminDashboard.ResetCompleted) )

        AdminDashboard.RequestDisableUser userId ->
            ( model, Api.Admin.disableUser userId (GotAdminMsg << AdminDashboard.DisableCompleted) )

        AdminDashboard.RequestEnableUser userId ->
            ( model, Api.Admin.enableUser userId (GotAdminMsg << AdminDashboard.EnableCompleted) )

        AdminDashboard.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyDiaryOutMsg : Diary.OutMsg -> Model -> ( Model, Cmd Msg )
applyDiaryOutMsg outMsg model =
    case outMsg of
        Diary.NoOp ->
            ( model, Cmd.none )

        Diary.RequestDiaryData date ->
            ( model
            , Cmd.batch
                [ Cmd.map GotDiaryMsg (Api.Logs.listLogs date Diary.LogsLoaded)
                , Cmd.map GotDiaryMsg (Api.Logs.getSummary date Diary.SummaryLoaded)
                ]
            )

        Diary.RequestItemNames items ->
            ( model, Cmd.batch (List.map itemNameCommand items) )

        Diary.Navigate route ->
            ( model, Nav.pushUrl model.key (Route.routeToPath route) )

        Diary.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


applyFoodSearchOutMsg : FoodSearch.OutMsg -> Model -> ( Model, Cmd Msg )
applyFoodSearchOutMsg outMsg model =
    case outMsg of
        FoodSearch.NoOp ->
            ( model, Cmd.none )

        FoodSearch.RequestSearch token request ->
            ( model, Api.Foods.searchFoods request (GotFoodSearchMsg << FoodSearch.SearchCompleted token) )

        FoodSearch.Navigate route ->
            ( model, Nav.pushUrl model.key (Route.routeToPath route) )

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

        FoodDetail.RequestLocalTimestamp ->
            ( model, requestLocalTimestamp () )

        FoodDetail.RequestCreateLog request ->
            ( model, Api.Logs.createLog request (GotFoodDetailMsg << FoodDetail.LogCompleted) )

        FoodDetail.Navigate route ->
            ( model, Nav.pushUrl model.key (Route.routeToPath route) )

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
            ( model, Api.Foods.getFoodDetail productId (GotFoodLogDetailMsg << FoodLogDetail.ProductDetailLoaded) )

        FoodLogDetail.RequestMealName mealId ->
            ( model, Api.Meals.getMealName mealId (GotFoodLogDetailMsg << FoodLogDetail.MealNameLoaded) )

        FoodLogDetail.RequestUpdateLog logId request ->
            ( model, Api.Logs.updateLog logId request (GotFoodLogDetailMsg << FoodLogDetail.UpdateCompleted) )

        FoodLogDetail.RequestDeleteLog logId ->
            ( model, Api.Logs.deleteLog logId (GotFoodLogDetailMsg << FoodLogDetail.DeleteCompleted) )

        FoodLogDetail.Navigate route ->
            ( model, Nav.pushUrl model.key (Route.routeToPath route) )

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
                    applyCustomFoodCreateOutMsg outMsg { model | page = CustomFoodCreatePage newSubModel }
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
                [ Api.Foods.listNutrients (GotCustomFoodCreateMsg << CustomFoodCreate.NutrientsLoaded)
                , Api.Foods.listUnits (GotCustomFoodCreateMsg << CustomFoodCreate.UnitsLoaded)
                ]
            )

        CustomFoodCreate.RequestCreateFood request ->
            ( model, Api.Foods.createCustomFood request (GotCustomFoodCreateMsg << CustomFoodCreate.SaveCompleted) )

        CustomFoodCreate.Navigate route ->
            ( model, Nav.pushUrl model.key (Route.routeToPath route) )

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
                    applyCustomFoodEditOutMsg outMsg { model | page = CustomFoodEditPage newSubModel }
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
                [ Api.Foods.getFoodDetail productId (GotCustomFoodEditMsg << CustomFoodEdit.FoodLoaded)
                , Api.Foods.listNutrients (GotCustomFoodEditMsg << CustomFoodEdit.NutrientsLoaded)
                , Api.Foods.listUnits (GotCustomFoodEditMsg << CustomFoodEdit.UnitsLoaded)
                ]
            )

        CustomFoodEdit.RequestUpdateFood productId request ->
            ( model, Api.Foods.updateCustomFood productId request (GotCustomFoodEditMsg << CustomFoodEdit.SaveCompleted) )

        CustomFoodEdit.Navigate route ->
            ( model, Nav.pushUrl model.key (Route.routeToPath route) )

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

        Meals.Navigate route ->
            ( model, Nav.pushUrl model.key (Route.routeToPath route) )

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
            ( model, Api.Meals.getMeal mealId (GotMealFormMsg << MealForm.MealLoaded) )

        MealForm.RequestProductName productId ->
            ( model, Api.Foods.getFoodDetail productId (GotMealFormMsg << MealForm.ProductNameLoaded productId) )

        MealForm.RequestProductSearch rowId token request ->
            ( model, Api.Foods.searchFoods request (GotMealFormMsg << MealForm.ComponentSearchCompleted rowId token) )

        MealForm.RequestCreateMeal request ->
            ( model, Api.Meals.createMeal request (GotMealFormMsg << MealForm.SaveCompleted) )

        MealForm.RequestUpdateMeal mealId request ->
            ( model, Api.Meals.updateMeal mealId request (GotMealFormMsg << MealForm.SaveCompleted) )

        MealForm.Navigate route ->
            ( model, Nav.pushUrl model.key (Route.routeToPath route) )

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
                ]
            )

        MealDetail.RequestProductDetail productId ->
            ( model, Api.Foods.getFoodDetail productId (GotMealDetailMsg << MealDetail.ProductDetailLoaded productId) )

        MealDetail.RequestNutrientPreview mealId amount unit token ->
            ( model, Api.Meals.getMealNutrients mealId amount unit (GotMealDetailMsg << MealDetail.NutrientPreviewLoaded token) )

        MealDetail.RequestLocalTimestamp ->
            ( model, requestLocalTimestamp () )

        MealDetail.RequestCreateLog request ->
            ( model, Api.Logs.createLog request (GotMealDetailMsg << MealDetail.LogCompleted) )

        MealDetail.RequestDeleteMeal mealId ->
            ( model, Api.Meals.deleteMeal mealId (GotMealDetailMsg << MealDetail.DeleteCompleted) )

        MealDetail.Navigate route ->
            ( model, Nav.pushUrl model.key (Route.routeToPath route) )

        MealDetail.SessionExpired ->
            ( { model | session = Session.clear model.session }, Nav.replaceUrl model.key "/login" )


itemNameCommand : ItemRef -> Cmd Msg
itemNameCommand item =
    case item.itemType of
        "meal" ->
            Api.Meals.getMealName item.id
                (\result ->
                    Diary.NameLookupCompleted item (Result.map .name result)
                        |> GotDiaryMsg
                )

        _ ->
            Api.Foods.getProductName item.id
                (\result ->
                    Diary.NameLookupCompleted item (Result.map .name result)
                        |> GotDiaryMsg
                )


view : Model -> Browser.Document Msg
view model =
    { title = "CalCo"
    , body =
        [ Element.layout [] <|
            Ui.layout <|
                Element.column
                    [ Element.width Element.fill
                    , Element.height Element.fill
                    ]
                    [ headerView model
                    , pageView model
                    ]
        ]
    }


headerView : Model -> Element.Element Msg
headerView model =
    Element.row
        [ Element.width Element.fill
        , Element.paddingXY 24 14
        , Element.spacing 16
        , Background.color (Element.rgb255 255 255 255)
        , Font.color (Element.rgb255 31 41 55)
        ]
        (Element.el [ Font.size 20, Font.bold, Element.width Element.fill ] (Element.text "CalCo")
            :: identityView model
        )


identityView : Model -> List (Element.Element Msg)
identityView model =
    case model.session.identity of
        Just identity ->
            [ Element.el [ Font.size 14, Font.color (Element.rgb255 75 85 99) ] (Element.text ("Logged in as " ++ identity.username))
            , Ui.button "Logout" LogoutClicked
            ]

        Nothing ->
            []


pageView : Model -> Element.Element Msg
pageView model =
    case model.page of
        LoadingPage ->
            Element.el [ Element.centerX, Element.centerY, Font.medium ] (Element.text "Loading...")

        LoginPage loginModel ->
            Element.map GotLoginMsg (Login.view loginModel)

        SetupPage setupModel ->
            Element.map GotSetupMsg (Setup.view setupModel)

        AdminPage adminModel ->
            Element.map GotAdminMsg (AdminDashboard.view adminModel)

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
