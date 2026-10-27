port module Main exposing
    ( BootstrapState
    , Flags
    , Model
    , Msg
    , PageModel
    , classifyDevice
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
import Data.BarcodeScan exposing (ScannerEvent)
import Data.LocalCtx as LocalCtx exposing (LocalCtx, RawLocalCtx)
import Data.Route exposing (Route(..))
import Element exposing (Element)
import Element.Background as Background
import Element.Font as Font
import Html
import Html.Attributes
import Lib.Date as LocalDate exposing (LocalDate)
import Page
import Translations.Util exposing (Language(..))
import Ui.Common as UiCommon exposing (uiClass)
import Ui.Css as Css
import Ui.Env as Env exposing (Env)
import Ui.Skeleton as Skeleton
import Ui.Theme as Theme exposing (Theme)
import Url exposing (Url)
import Version
import View.Chrome



-- MODEL


type alias Flags =
    { windowWidth : Int, windowHeight : Int, themeMode : String }


type alias Model =
    { key : Nav.Key
    , route : Route
    , bootstrap : BootstrapState
    , today : Maybe LocalDate
    , page : PageModel
    , chrome : Chrome.Model
    , env : Env
    , version : Version.Model
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
    { session : Session, adminExists : Bool }


type alias CopyTextRequest =
    { generation : Int, requestId : Int, text : String }


type alias CopyTextResult =
    { generation : Int, requestId : Int, succeeded : Bool }


init : Flags -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        ( versionModel, versionCmd ) =
            Version.init
    in
    ( { key = key
      , route = Data.Route.fromUrl url
      , bootstrap =
            Bootstrapping { session = Nothing, status = Nothing }
      , today = Nothing
      , page = Page.loading
      , chrome = Chrome.init
      , env =
            { theme = Theme.forMode (Theme.modeFromString flags.themeMode)
            , device = classifyDevice flags.windowWidth flags.windowHeight
            , language = EN_US
            }
      , version = versionModel
      }
    , Cmd.batch
        [ Api.Auth.session GotSession
        , Api.Auth.bootstrapStatus GotBootstrapStatus
        , Cmd.map GotVersionMsg versionCmd
        ]
    )



-- UPDATE


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | GotSession (Result Client.ApiError Auth.LoginSession)
    | GotBootstrapStatus (Result Client.ApiError Auth.BootstrapStatus)
    | LogoutCompleted
    | WindowResized Int Int
    | GotPageMsg Page.Msg
    | GotLocalCtx RawLocalCtx
    | GotBarcodeScannerEvent ScannerEvent
    | GotCopyTextResult CopyTextResult
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
            updateBootstrapProgress (\progress -> { progress | session = Just result }) model

        GotBootstrapStatus result ->
            updateBootstrapProgress (\progress -> { progress | status = Just result }) model

        LogoutCompleted ->
            ( { model
                | bootstrap =
                    setSession (Auth.clearSession (currentSession model)) model.bootstrap
                , page = Page.clearStore model.page
              }
            , Nav.replaceUrl model.key (Data.Route.routeToPath AuthLogin)
            )

        WindowResized width height ->
            case reclassifyDevice width height model.env.device of
                Just device ->
                    ( { model | env = Env.withDevice model.env device }, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        GotVersionMsg versionMsg ->
            let
                ( newVersion, versionCmd, outMsg ) =
                    Version.update versionMsg model.version
            in
            case outMsg of
                Version.NoOutMsg ->
                    ( { model | version = newVersion }, Cmd.map GotVersionMsg versionCmd )

                Version.ReloadPage ->
                    ( { model | version = newVersion }, reloadPage () )

        GotLocalCtx raw ->
            case LocalCtx.fromRaw raw of
                Nothing ->
                    ( model, Cmd.none )

                Just context ->
                    let
                        ( dated, dateCmd ) =
                            adoptToday context model

                        ( final, contextCmd ) =
                            stepPageUpdate
                                (Page.localCtxReceived (pageCtx dated) context dated.page)
                                dated
                    in
                    ( final, Cmd.batch [ dateCmd, contextCmd ] )

        GotBarcodeScannerEvent event ->
            stepPageUpdate
                (Page.barcodeScannerEventReceived (pageCtx model) event model.page)
                model

        GotCopyTextResult result ->
            stepPageUpdate
                (Page.update
                    (pageCtx model)
                    (Page.CopyTextResult
                        result.generation
                        result.requestId
                        result.succeeded
                    )
                    model.page
                )
                model

        GotPageMsg pageMsg ->
            stepPageUpdate (Page.update (pageCtx model) pageMsg model.page) model

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
            classifyDevice width height
    in
    if next == current then
        Nothing

    else
        Just next


{-| Classify from width so changing viewport height cannot unexpectedly enable
the two-pane workspace. The desktop threshold leaves enough horizontal room
for two useful panes after workspace padding and spacing are applied.
-}
classifyDevice : Int -> Int -> Element.Device
classifyDevice width height =
    { class =
        if width < 600 then
            Element.Phone

        else if width < 1440 then
            Element.Tablet

        else if width <= 1920 then
            Element.Desktop

        else
            Element.BigDesktop
    , orientation =
        if width < height then
            Element.Portrait

        else
            Element.Landscape
    }


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
            ( { model | page = Page.clearStore model.page }
            , Cmd.batch
                [ Api.Auth.logout (\_ -> LogoutCompleted)
                , revokePhotoPreviewUrls (Page.photoPreviewUrls model.page)
                ]
            )

        Chrome.ToggleTheme ->
            let
                nextMode : Theme.Mode
                nextMode =
                    Theme.toggle model.env.theme.mode
            in
            ( { model | env = Env.withTheme model.env (Theme.forMode nextMode) }
            , persistThemeMode (Theme.modeToString nextMode)
            )

        Chrome.SetLanguage language ->
            ( { model | env = Env.withLanguage model.env language }, Cmd.none )


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
                        Bootstrapped { session = nextSession, adminExists = adminExists }
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
            Page.initPreserving { route = route, today = model.today } model.page
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

        removedPhotoUrls : List String
        removedPhotoUrls =
            Page.photoPreviewUrls model.page
                |> List.filter
                    (not
                        << (\url ->
                                List.member url (Page.photoPreviewUrls finalModel.page)
                           )
                    )
    in
    ( finalModel
    , Cmd.batch
        [ Cmd.map GotPageMsg pageCmd, outCmd, revokePhotoPreviewUrls removedPhotoUrls ]
    )


{-| Reconciling the route is what turns a rolled-over day into the right set of
panes: a diary route with no date param keys off `today`, so it becomes a new
pane for the new day, while an explicitly dated route keeps the one it has.
-}
adoptToday : LocalCtx -> Model -> ( Model, Cmd Msg )
adoptToday context model =
    case model.today of
        Just current ->
            if LocalDate.equals context.date current then
                ( model, Cmd.none )

            else
                changeRouteTo model.route { model | today = Just context.date }

        Nothing ->
            changeRouteTo model.route { model | today = Just context.date }


pageCtx : Model -> Page.InitCtx
pageCtx model =
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
                , page = Page.clearStore model.page
              }
            , Nav.replaceUrl model.key (Data.Route.routeToPath AuthLogin)
            )

        Page.RequestLocalCtx ->
            ( model, requestLocalCtx () )

        Page.RequestBarcodeScanStart ->
            ( model, requestBarcodeScanStart () )

        Page.RequestBarcodeScanStop ->
            ( model, requestBarcodeScanStop () )

        Page.RevokePhotoPreviewUrls urls ->
            ( model, revokePhotoPreviewUrls urls )

        Page.CopyText generation requestId text ->
            ( model
            , copyText
                { generation = generation
                , requestId = requestId
                , text = text
                }
            )

        Page.LoginSucceeded loginSession ->
            let
                nextSession : Session
                nextSession =
                    Auth.applyAuthResult (Ok loginSession) (currentSession model)
            in
            ( { model
                | bootstrap = setSession nextSession model.bootstrap
                , page = Page.clearStore model.page
              }
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
                    Bootstrapped { session = nextSession, adminExists = True }
                , page = Page.clearStore model.page
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

        modal : Maybe (Element Msg)
        modal =
            Page.modalView model.env model.page
                |> Maybe.map (Element.map GotPageMsg)

        updateBanner : Maybe (Element Msg)
        updateBanner =
            if model.version.updateAvailable then
                Just
                    (View.Chrome.updateBanner model.env (GotVersionMsg Version.ReloadPageRequested))

            else
                Nothing
    in
    { title = "CalCo"
    , body =
        [ Html.node "style"
            []
            [ Html.text
                ("html, body { background: "
                    ++ UiCommon.toCssColor model.env.theme.pageBg
                    ++ "; } :root { background: "
                    ++ UiCommon.toCssColor model.env.theme.pageBg
                    ++ "; "
                    ++ Css.themeCssVariables model.env.theme
                    ++ "; }"
                )
            ]
        , Element.layoutWith
            { options =
                [ Element.focusStyle
                    { borderColor = Nothing, backgroundColor = Nothing, shadow = Nothing }
                ]
            }
            (modalLayoutAttrs modal
                ++ bottomNavAttrs modal model session isLoadingPage
            )
          <|
            uiLayout model.env.theme
                (modalContentAttrs modal)
                (Chrome.viewFrame
                    model.env
                    model.chrome
                    session
                    model.route
                    isLoadingPage
                    updateBanner
                    (pageView model)
                    GotChromeMsg
                )
        ]
    }


{-| A page dialog is rendered as a root-level `inFront` sibling of the shell
content, so the shell content can be marked inert: keyboard focus and pointer
input cannot reach the chrome or page behind the dialog while it stays
interactive.
-}
modalContentAttrs : Maybe (Element Msg) -> List (Element.Attribute Msg)
modalContentAttrs modal =
    case modal of
        Just _ ->
            [ Element.htmlAttribute (Html.Attributes.attribute "inert" "") ]

        Nothing ->
            []


{-| The bottom nav is part of the shell, so it is omitted while a dialog is
open. `Chrome.viewFrame` still reserves the page's bottom padding from the same
nav visibility rule, so the page does not shift when the nav is hidden.
-}
bottomNavAttrs :
    Maybe (Element Msg)
    -> Model
    -> Session
    -> Bool
    -> List (Element.Attribute Msg)
bottomNavAttrs modal model session isLoadingPage =
    case modal of
        Just _ ->
            []

        Nothing ->
            Chrome.bottomNavLayoutAttrs
                model.env
                session
                model.route
                isLoadingPage
                GotChromeMsg


uiLayout : Theme -> List (Element.Attribute msg) -> Element msg -> Element msg
uiLayout theme extraAttrs content =
    Element.column
        [ Element.width Element.fill
        , Element.height Element.fill
        , Background.color theme.pageBg
        , Font.family [ Font.typeface "Inter", Font.sansSerif ]
        , Font.color theme.textPrimary
        , Font.size 16
        , uiClass "ui-theme-root"
        ]
        [ Element.el
            ([ Element.width Element.fill
             , Element.height Element.fill
             ]
                ++ extraAttrs
            )
            content
        ]


modalLayoutAttrs : Maybe (Element Msg) -> List (Element.Attribute Msg)
modalLayoutAttrs modal =
    case modal of
        Just modalCard ->
            [ Element.inFront modalCard ]

        Nothing ->
            []


pageView : Model -> Element Msg
pageView model =
    if not (isBootstrapped model.bootstrap) then
        Skeleton.loading model.env.theme

    else
        Element.map GotPageMsg (Page.view model.env model.page)


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
            Bootstrapped { session = session, adminExists = True }

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
        [ localCtxReceived GotLocalCtx
        , barcodeScannerEvent GotBarcodeScannerEvent
        , copyTextResult GotCopyTextResult
        , Browser.Events.onResize WindowResized
        , Sub.map GotVersionMsg Version.subscriptions
        ]



-- PORTS


port requestLocalCtx : () -> Cmd msg


port localCtxReceived : (RawLocalCtx -> msg) -> Sub msg


port requestBarcodeScanStart : () -> Cmd msg


port requestBarcodeScanStop : () -> Cmd msg


port barcodeScannerEvent : (ScannerEvent -> msg) -> Sub msg


port revokePhotoPreviewUrls : List String -> Cmd msg


port copyText : CopyTextRequest -> Cmd msg


port copyTextResult : (CopyTextResult -> msg) -> Sub msg


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
