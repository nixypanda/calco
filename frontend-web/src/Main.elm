port module Main exposing (Flags, Model, Msg, PageModel, main)

import Access
import Api.Auth
import Api.Client as Client
import Browser
import Browser.Events
import Browser.Navigation as Nav
import Data.Auth as Auth
import Data.Route exposing (Route(..))
import Element exposing (Element)
import Element.Region as Region
import Html
import Json.Decode as Decode
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Text as Text
import Page
import Session exposing (Session)
import Task
import Time
import Ui
import Ui.Theme as Theme exposing (Mode, Theme)
import Url exposing (Url)
import View.Chrome as Chrome



-- MODEL


type alias Flags =
    { windowWidth : Int
    , windowHeight : Int
    , themeMode : String
    }


type alias Model =
    { key : Nav.Key
    , route : Route
    , session : Session
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
    , currentVersion : Maybe String
    , updateAvailable : Bool
    , versionError : Maybe String
    }


type alias PageModel =
    Page.Model


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
      , page = Page.LoadingPage
      , drawerOpen = False
      , profileOpen = False
      , device =
            Element.classifyDevice
                { width = flags.windowWidth
                , height = flags.windowHeight
                }
      , themeMode = themeMode
      , theme = Theme.forMode themeMode
      , currentVersion = Nothing
      , updateAvailable = False
      , versionError = Nothing
      }
    , Cmd.batch
        [ Api.Auth.session GotSession
        , Api.Auth.bootstrapStatus GotBootstrapStatus
        , Task.perform GotLocalDate
            (Task.map2 LocalDate.fromPosix Time.here Time.now)
        , Task.perform GotVersionCheckTime Time.now
        ]
    )



-- UPDATE


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
    | GotPageMsg Page.Msg
    | GotLocalContext { date : String, timezone : String }
    | ThemeToggleClicked
    | GotVersionCheck (Result Client.ApiError String)
    | GotVersionCheckTime Time.Posix
    | ReloadPageClicked
    | CheckForUpdate
    | NoOp


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
            , Nav.replaceUrl model.key (Data.Route.routeToPath AuthLogin)
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

        GotVersionCheck result ->
            case result of
                Ok version ->
                    let
                        isNew : Bool
                        isNew =
                            case model.currentVersion of
                                Nothing ->
                                    False

                                Just current ->
                                    current /= version
                    in
                    ( { model
                        | currentVersion = Just version
                        , updateAvailable = isNew && model.currentVersion /= Nothing
                        , versionError = Nothing
                      }
                    , Cmd.none
                    )

                Err error ->
                    ( { model | versionError = Just (Client.displayError error) }
                    , Cmd.none
                    )

        ReloadPageClicked ->
            ( model, reloadPage () )

        CheckForUpdate ->
            ( model, Task.perform GotVersionCheckTime Time.now )

        GotVersionCheckTime posix ->
            ( model, fetchVersion (Time.posixToMillis posix) )

        NoOp ->
            ( model, Cmd.none )

        GotLocalContext context ->
            stepPageUpdate (Page.localContextReceived (pageContext model) context model.page) model

        GotPageMsg pageMsg ->
            stepPageUpdate (Page.update (pageContext model) pageMsg model.page) model


applyBootstrapProgress : Model -> ( Model, Cmd Msg )
applyBootstrapProgress model =
    case ( model.pendingSession, model.pendingBootstrap ) of
        ( Just sessionResult, Just bootstrapResult ) ->
            let
                nextSession : Session
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
    let
        ( page, pageCmd, outMsg ) =
            Page.init { route = route, today = model.today }
    in
    stepPageResult ( page, pageCmd, outMsg ) model


stepPageUpdate : Maybe ( Page.Model, Cmd Page.Msg, Page.OutMsg ) -> Model -> ( Model, Cmd Msg )
stepPageUpdate maybePageResult model =
    case maybePageResult of
        Just pageResult ->
            stepPageResult pageResult model

        Nothing ->
            ( model, Cmd.none )


stepPageResult : ( Page.Model, Cmd Page.Msg, Page.OutMsg ) -> Model -> ( Model, Cmd Msg )
stepPageResult ( page, pageCmd, outMsg ) model =
    let
        ( finalModel, outCmd ) =
            applyPageOutMsg outMsg { model | page = page }
    in
    ( finalModel, Cmd.batch [ Cmd.map GotPageMsg pageCmd, outCmd ] )


pageContext : Model -> Page.InitContext
pageContext model =
    { route = model.route, today = model.today }


applyPageOutMsg : Page.OutMsg -> Model -> ( Model, Cmd Msg )
applyPageOutMsg outMsg model =
    case outMsg of
        Page.NoOutMsg ->
            ( model, Cmd.none )

        Page.Navigate route ->
            ( model, Nav.pushUrl model.key (Data.Route.routeToPath route) )

        Page.SessionExpired ->
            ( { model | session = Session.clear model.session }
            , Nav.replaceUrl model.key (Data.Route.routeToPath AuthLogin)
            )

        Page.RequestLocalContext ->
            ( model, requestLocalContext () )

        Page.LoginSucceeded loginSession ->
            let
                nextSession : Session
                nextSession =
                    Session.applyAuthResult (Ok loginSession) model.session
            in
            ( { model | session = nextSession }
            , Nav.replaceUrl model.key (Data.Route.routeToPath Root)
            )

        Page.SetupSucceeded loginSession ->
            let
                nextSession : Session
                nextSession =
                    Session.applyAuthResult (Ok loginSession) model.session
            in
            ( { model | session = nextSession, adminExists = True }
            , Nav.replaceUrl model.key (Data.Route.routeToPath AdminDashboard)
            )



-- VIEW


view : Model -> Browser.Document Msg
view model =
    let
        isLoadingPage : Bool
        isLoadingPage =
            Page.isLoading model.page

        useBottomNav : Bool
        useBottomNav =
            Chrome.showBottomNav model.device model.session isLoadingPage model.route

        bottomNavEl : List (Element.Attribute Msg)
        bottomNavEl =
            if useBottomNav then
                [ Element.inFront
                    (Element.el
                        [ Element.width Element.fill
                        , Element.alignBottom
                        ]
                        (Chrome.bottomNavBar
                            { theme = model.theme
                            , session = model.session
                            , route = model.route
                            , onNavigate = NavigateTo
                            }
                        )
                    )
                ]

            else
                []
    in
    { title = "CalCo"
    , body =
        [ Html.node "style"
            []
            [ Html.text
                ("html, body { background: "
                    ++ Ui.toCssColor model.theme.pageBg
                    ++ "; } :root { background: "
                    ++ Ui.toCssColor model.theme.pageBg
                    ++ "; "
                    ++ Ui.themeCssVariables model.theme
                    ++ "; }"
                )
            ]
        , Element.layoutWith
            { options =
                [ Element.focusStyle
                    { borderColor = Nothing
                    , backgroundColor = Nothing
                    , shadow = Nothing
                    }
                ]
            }
            (layoutAttrs model ++ bottomNavEl)
          <|
            Ui.layout model.theme <|
                appFrame model
        ]
    }


layoutAttrs : Model -> List (Element.Attribute Msg)
layoutAttrs model =
    case Page.modalView (pageProps model) of
        Just modal ->
            [ Element.inFront (Element.map GotPageMsg modal) ]

        Nothing ->
            []


appFrame : Model -> Element Msg
appFrame model =
    let
        isLoadingPage : Bool
        isLoadingPage =
            Page.isLoading model.page

        useBottomNav : Bool
        useBottomNav =
            Chrome.showBottomNav model.device model.session isLoadingPage model.route

        bottomNavClearance : Int
        bottomNavClearance =
            56

        chromeAttrs : List (Element.Attribute Msg)
        chromeAttrs =
            if useBottomNav then
                []

            else
                Chrome.drawerOverlay
                    { device = model.device
                    , theme = model.theme
                    , session = model.session
                    , route = model.route
                    , drawerOpen = model.drawerOpen
                    , onClose = DrawerClosed
                    , onNavigate = NavigateTo
                    }

        pageAttrs : List (Element.Attribute Msg)
        pageAttrs =
            [ Element.width Element.fill
            , Element.height Element.fill
            , Region.mainContent
            ]
                ++ (if useBottomNav then
                        [ Element.paddingEach
                            { bottom = bottomNavClearance, top = 0, left = 0, right = 0 }
                        ]

                    else
                        []
                   )

        profileLetter : String
        profileLetter =
            case model.session of
                Session.Authenticated identity ->
                    Text.initial identity.username

                _ ->
                    "?"

        profileMenuEl : Maybe (Element Msg)
        profileMenuEl =
            if
                model.profileOpen
                    && Chrome.showsAppChrome model.session isLoadingPage model.route
            then
                Just
                    (Chrome.profileMenu
                        { device = model.device
                        , theme = model.theme
                        , session = model.session
                        , onNavigate = NavigateTo
                        , onLogout = LogoutClicked
                        }
                    )

            else
                Nothing
    in
    Element.column
        ([ Element.width Element.fill, Element.height Element.fill ] ++ chromeAttrs)
        (Chrome.topBarView
            { device = model.device
            , theme = model.theme
            , themeMode = model.themeMode
            , session = model.session
            , route = model.route
            , profileOpen = model.profileOpen
            , isLoadingPage = isLoadingPage
            , onMenuClick = MenuClicked
            , onProfileClick = ProfileClicked
            , onThemeToggle = ThemeToggleClicked
            , onNavigate = NavigateTo
            }
            { profileLabel = profileLetter
            , profileMenu = profileMenuEl
            }
            :: (if model.updateAvailable then
                    [ Chrome.updateBanner model.theme ReloadPageClicked ]

                else
                    []
               )
            ++ [ Element.el pageAttrs (pageView model) ]
        )


closeChrome : Model -> Model
closeChrome model =
    { model | drawerOpen = False, profileOpen = False }


pageView : Model -> Element Msg
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
        Element.map GotPageMsg (Page.view (pageProps model))


pageProps : Model -> { model : Page.Model, device : Element.Device, theme : Theme }
pageProps model =
    { model = model.page
    , device = model.device
    , theme = model.theme
    }



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ localContextReceived GotLocalContext
        , Browser.Events.onResize WindowResized
        , Browser.Events.onVisibilityChange
            (\visibility ->
                case visibility of
                    Browser.Events.Visible ->
                        CheckForUpdate

                    Browser.Events.Hidden ->
                        NoOp
            )
        ]



-- PORTS


port requestLocalContext : () -> Cmd msg


port localContextReceived : ({ date : String, timezone : String } -> msg) -> Sub msg


port persistThemeMode : String -> Cmd msg


port reloadPage : () -> Cmd msg



-- HELPERS


fetchVersion : Int -> Cmd Msg
fetchVersion timestamp =
    Client.get
        ("/version.json?v=" ++ String.fromInt timestamp)
        versionDecoder
        GotVersionCheck


versionDecoder : Decode.Decoder String
versionDecoder =
    Decode.field "version" Decode.string



-- MAIN


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
