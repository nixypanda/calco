module Main exposing (Flags, Model, Msg, PageModel, main)

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
import Page.Diary as Diary
import Page.FoodSearch as FoodSearch
import Page.Login as Login
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


main : Program Flags Model Msg
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = \_ -> Sub.none
        , onUrlRequest = LinkClicked
        , onUrlChange = UrlChanged
        }


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

        PlaceholderPage message ->
            Element.el [ Element.padding 24 ] (Element.text message)
