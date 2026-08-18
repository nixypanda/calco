port module Main exposing
    ( BootstrapState
    , Flags
    , Model
    , Msg
    , PageModel
    , main
    , normalizeChromeNavigation
    , reclassifyDevice
    )

import Access
import Api.Auth
import Api.Client as Client
import Browser
import Browser.Events
import Browser.Navigation as Nav
import Chrome
import Data.Auth as Auth exposing (Session)
import Data.Route exposing (Route(..))
import Element exposing (Element)
import Html
import Lib.Date as LocalDate exposing (LocalDate)
import Page
import Task
import Time
import Ui
import Ui.Css as Css
import Ui.Theme as Theme exposing (Theme)
import Url exposing (Url)
import Version
import View.Chrome



-- MODEL


type alias Flags =
    { windowWidth : Int
    , windowHeight : Int
    , themeMode : String
    }


type alias Model =
    { key : Nav.Key
    , route : Route
    , bootstrap : BootstrapState
    , today : Maybe LocalDate
    , page : PageModel
    , chrome : Chrome.Model
    , device : Element.Device
    , theme : Theme
    , version : Version.Model
    }


type alias BarcodeScannerEvent =
    { event : String
    , barcode : Maybe String
    , message : Maybe String
    }


type alias PageModel =
    Page.Model


type BootstrapState
    = Bootstrapping BootstrapProgress
    | Bootstrapped BootstrapModel


type alias BootstrapProgress =
    { session : Maybe (Result Client.ApiError Auth.LoginSession)
    , status : Maybe (Result Client.ApiError Auth.BootstrapStatus)
    }


type alias BootstrapModel =
    { session : Session
    , adminExists : Bool
    }


init : Flags -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        ( versionModel, versionCmd ) =
            Version.init
    in
    ( { key = key
      , route = Data.Route.fromUrl url
      , bootstrap =
            Bootstrapping
                { session = Nothing
                , status = Nothing
                }
      , today = Nothing
      , page = Page.loading
      , chrome = Chrome.init
      , device =
            Element.classifyDevice
                { width = flags.windowWidth
                , height = flags.windowHeight
                }
      , theme = Theme.forMode (Theme.modeFromString flags.themeMode)
      , version = versionModel
      }
    , Cmd.batch
        [ Api.Auth.session GotSession
        , Api.Auth.bootstrapStatus GotBootstrapStatus
        , Task.perform GotLocalDate
            (Task.map2 LocalDate.fromPosix Time.here Time.now)
        , Cmd.map GotVersionMsg versionCmd
        ]
    )



-- UPDATE


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | GotSession (Result Client.ApiError Auth.LoginSession)
    | GotBootstrapStatus (Result Client.ApiError Auth.BootstrapStatus)
    | GotLocalDate LocalDate
    | LogoutCompleted
    | WindowResized Int Int
    | GotPageMsg Page.Msg
    | GotLocalContext { date : String, timezone : String }
    | GotBarcodeScannerEvent BarcodeScannerEvent
    | GotChromeMsg Chrome.Msg
    | GotVersionMsg Version.Msg


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        LinkClicked request ->
            case request of
                Browser.Internal url ->
                    ( { model | chrome = Chrome.close model.chrome }
                    , Nav.pushUrl model.key (Url.toString url)
                    )

                Browser.External href ->
                    ( model, Nav.load href )

        UrlChanged url ->
            let
                route : Route
                route =
                    Data.Route.fromUrl url
            in
            changeRouteTo route { model | route = route, chrome = Chrome.close model.chrome }

        GotSession result ->
            updateBootstrapProgress
                (\progress -> { progress | session = Just result })
                model

        GotBootstrapStatus result ->
            updateBootstrapProgress
                (\progress -> { progress | status = Just result })
                model

        GotLocalDate today ->
            changeRouteTo model.route { model | today = Just today }

        LogoutCompleted ->
            ( { model
                | bootstrap =
                    setSession (Auth.clearSession (currentSession model)) model.bootstrap
              }
            , Nav.replaceUrl model.key (Data.Route.routeToPath AuthLogin)
            )

        WindowResized width height ->
            case reclassifyDevice width height model.device of
                Just device ->
                    ( { model | device = device }, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        GotVersionMsg versionMsg ->
            let
                ( newVersion, versionCmd, outMsg ) =
                    Version.update versionMsg model.version
            in
            case outMsg of
                Version.NoOutMsg ->
                    ( { model | version = newVersion }
                    , Cmd.map GotVersionMsg versionCmd
                    )

                Version.ReloadPage ->
                    ( { model | version = newVersion }
                    , reloadPage ()
                    )

        GotLocalContext context ->
            stepPageUpdate (Page.localContextReceived (pageContext model) context model.page) model

        GotBarcodeScannerEvent event ->
            stepPageUpdate
                (Page.barcodeScannerEventReceived (pageContext model) event model.page)
                model

        GotPageMsg pageMsg ->
            stepPageUpdate (Page.update (pageContext model) pageMsg model.page) model

        GotChromeMsg chromeMsg ->
            stepChromeUpdate (Chrome.update chromeMsg model.chrome) model


{-| A drag emits resize events continuously, but the app only renders from the
classified device. Returning `Nothing` when the classification is unchanged
leaves the model untouched so Elm can skip the re-render.
-}
reclassifyDevice : Int -> Int -> Element.Device -> Maybe Element.Device
reclassifyDevice width height current =
    let
        next : Element.Device
        next =
            Element.classifyDevice { width = width, height = height }
    in
    if next == current then
        Nothing

    else
        Just next


stepChromeUpdate : ( Chrome.Model, Chrome.OutMsg ) -> Model -> ( Model, Cmd Msg )
stepChromeUpdate ( chrome, outMsg ) model =
    applyChromeOutMsg outMsg { model | chrome = chrome }


applyChromeOutMsg : Chrome.OutMsg -> Model -> ( Model, Cmd Msg )
applyChromeOutMsg outMsg model =
    case outMsg of
        Chrome.NoOutMsg ->
            ( model, Cmd.none )

        Chrome.Navigate route ->
            ( model
            , Nav.pushUrl model.key
                (Data.Route.routeToPath (normalizeChromeNavigation model.route route))
            )

        Chrome.Logout ->
            ( model, Api.Auth.logout (\_ -> LogoutCompleted) )

        Chrome.ToggleTheme ->
            let
                nextMode : Theme.Mode
                nextMode =
                    Theme.toggle model.theme.mode
            in
            ( { model | theme = Theme.forMode nextMode }
            , persistThemeMode (Theme.modeToString nextMode)
            )


normalizeChromeNavigation : Route -> Route -> Route
normalizeChromeNavigation current target =
    case ( current, target ) of
        ( DiaryDay (Just date) _, FoodSearch Nothing Nothing ) ->
            FoodSearch (Just date) Nothing

        _ ->
            target


updateBootstrapProgress : (BootstrapProgress -> BootstrapProgress) -> Model -> ( Model, Cmd Msg )
updateBootstrapProgress apply model =
    case model.bootstrap of
        Bootstrapping progress ->
            resolveBootstrapProgress { model | bootstrap = Bootstrapping (apply progress) }

        Bootstrapped _ ->
            ( model, Cmd.none )


resolveBootstrapProgress : Model -> ( Model, Cmd Msg )
resolveBootstrapProgress model =
    case model.bootstrap of
        Bootstrapping { session, status } ->
            resolveBootstrapResults model session status

        Bootstrapped _ ->
            ( model, Cmd.none )


resolveBootstrapResults :
    Model
    -> Maybe (Result Client.ApiError Auth.LoginSession)
    -> Maybe (Result Client.ApiError Auth.BootstrapStatus)
    -> ( Model, Cmd Msg )
resolveBootstrapResults model maybeSessionResult maybeStatusResult =
    case ( maybeSessionResult, maybeStatusResult ) of
        ( Just sessionResult, Just statusResult ) ->
            let
                nextSession : Session
                nextSession =
                    Auth.applyAuthResult sessionResult Auth.initSession

                adminExists : Bool
                adminExists =
                    case statusResult of
                        Ok status ->
                            status.adminExists

                        Err _ ->
                            True
            in
            changeRouteTo model.route
                { model
                    | bootstrap =
                        Bootstrapped
                            { session = nextSession
                            , adminExists = adminExists
                            }
                }

        _ ->
            ( model, Cmd.none )


changeRouteTo : Route -> Model -> ( Model, Cmd Msg )
changeRouteTo route model =
    case Access.resolveRoute (currentSession model) (currentAdminExists model) route of
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
            Page.initPreserving
                { route = route, today = model.today }
                model.page
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
            ( { model
                | bootstrap =
                    setSession (Auth.clearSession (currentSession model)) model.bootstrap
              }
            , Nav.replaceUrl model.key (Data.Route.routeToPath AuthLogin)
            )

        Page.RequestLocalContext ->
            ( model, requestLocalContext () )

        Page.RequestBarcodeScanStart ->
            ( model, requestBarcodeScanStart () )

        Page.RequestBarcodeScanStop ->
            ( model, requestBarcodeScanStop () )

        Page.LoginSucceeded loginSession ->
            let
                nextSession : Session
                nextSession =
                    Auth.applyAuthResult (Ok loginSession) (currentSession model)
            in
            ( { model | bootstrap = setSession nextSession model.bootstrap }
            , Nav.replaceUrl model.key (Data.Route.routeToPath Root)
            )

        Page.SetupSucceeded loginSession ->
            let
                nextSession : Session
                nextSession =
                    Auth.applyAuthResult (Ok loginSession) (currentSession model)
            in
            ( { model
                | bootstrap =
                    Bootstrapped
                        { session = nextSession
                        , adminExists = True
                        }
              }
            , Nav.replaceUrl model.key (Data.Route.routeToPath AdminDashboard)
            )



-- VIEW


view : Model -> Browser.Document Msg
view model =
    let
        session : Session
        session =
            currentSession model

        isLoadingPage : Bool
        isLoadingPage =
            Page.isLoading model.page
    in
    { title = "CalCo"
    , body =
        [ Html.node "style"
            []
            [ Html.text
                ("html, body { background: "
                    ++ Css.toCssColor model.theme.pageBg
                    ++ "; } :root { background: "
                    ++ Css.toCssColor model.theme.pageBg
                    ++ "; "
                    ++ Css.themeCssVariables model.theme
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
            (layoutAttrs model
                ++ Chrome.bottomNavLayoutAttrs
                    { model = model.chrome
                    , device = model.device
                    , theme = model.theme
                    , session = session
                    , route = model.route
                    , isLoadingPage = isLoadingPage
                    , toMsg = GotChromeMsg
                    }
            )
          <|
            Ui.layout model.theme <|
                Chrome.viewFrame
                    { model = model.chrome
                    , device = model.device
                    , theme = model.theme
                    , session = session
                    , route = model.route
                    , isLoadingPage = isLoadingPage
                    , updateBanner =
                        if model.version.updateAvailable then
                            Just
                                (View.Chrome.updateBanner
                                    model.theme
                                    (GotVersionMsg Version.ReloadPageRequested)
                                )

                        else
                            Nothing
                    , page = pageView model
                    , toMsg = GotChromeMsg
                    }
        ]
    }


layoutAttrs : Model -> List (Element.Attribute Msg)
layoutAttrs model =
    case Page.modalView (pageProps model) of
        Just modal ->
            [ Element.inFront (Element.map GotPageMsg modal) ]

        Nothing ->
            []


pageView : Model -> Element Msg
pageView model =
    if not (isBootstrapped model.bootstrap) then
        Ui.skeletonLoading model.theme

    else
        Element.map GotPageMsg (Page.view (pageProps model))


pageProps : Model -> { model : Page.Model, device : Element.Device, theme : Theme }
pageProps model =
    { model = model.page
    , device = model.device
    , theme = model.theme
    }


currentSession : Model -> Session
currentSession model =
    case model.bootstrap of
        Bootstrapping _ ->
            Auth.Loading

        Bootstrapped bootstrap ->
            bootstrap.session


currentAdminExists : Model -> Bool
currentAdminExists model =
    case model.bootstrap of
        Bootstrapping _ ->
            True

        Bootstrapped bootstrap ->
            bootstrap.adminExists


setSession : Session -> BootstrapState -> BootstrapState
setSession session bootstrap =
    case bootstrap of
        Bootstrapping _ ->
            Bootstrapped
                { session = session
                , adminExists = True
                }

        Bootstrapped model ->
            Bootstrapped { model | session = session }


isBootstrapped : BootstrapState -> Bool
isBootstrapped bootstrap =
    case bootstrap of
        Bootstrapping _ ->
            False

        Bootstrapped _ ->
            True



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ localContextReceived GotLocalContext
        , barcodeScannerEvent GotBarcodeScannerEvent
        , Browser.Events.onResize WindowResized
        , Sub.map GotVersionMsg Version.subscriptions
        ]



-- PORTS


port requestLocalContext : () -> Cmd msg


port localContextReceived : ({ date : String, timezone : String } -> msg) -> Sub msg


port requestBarcodeScanStart : () -> Cmd msg


port requestBarcodeScanStop : () -> Cmd msg


port barcodeScannerEvent : (BarcodeScannerEvent -> msg) -> Sub msg


port persistThemeMode : String -> Cmd msg


port reloadPage : () -> Cmd msg



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
