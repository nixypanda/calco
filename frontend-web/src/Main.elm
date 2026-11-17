port module Main exposing
    ( BootstrapState
    , Flags
    , Model
    , Msg
    , PageModel
    , ViewConfig
    , classifyDevice
    , drawerFocusTarget
    , envForModel
    , logoutStillApplies
    , main
    , normalizeChromeNavigation
    , reclassifyDevice
    , reclassifyViewport
    , rendersOnePane
    , themeMenuFocusTarget
    , themeMenuImplicitFocusTarget
    )

import Access
import Api.Auth
import Api.Client as Client
import Browser
import Browser.Dom
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
import I18n
import Json.Decode as Decode
import Lib.Date as LocalDate exposing (LocalDate)
import Page
import Process
import Task
import Translations.Util exposing (Language, parseLanguage)
import Ui.Common as UiCommon exposing (uiClass)
import Ui.Css as Css
import Ui.Env as Env exposing (Env)
import Ui.Theme as Theme exposing (Theme)
import Ui.ThemeChoice as ThemeChoice
import Ui.Workspace as Workspace
import Url exposing (Url)
import Version
import View.Chrome



-- MODEL


type alias Flags =
    { windowWidth : Int
    , windowHeight : Int
    , themeMode : String
    , systemPrefersDark : Bool
    , language : String
    }


type alias Model =
    { key : Nav.Key
    , route : Route
    , bootstrap : BootstrapState
    , today : Maybe LocalDate
    , page : PageModel
    , chrome : Chrome.Model
    , loggingOut : Bool
    , logoutGeneration : Int
    , themeState : Theme.State
    , viewConfig : ViewConfig
    , version : Version.Model
    }


{-| The independent, non-theme inputs to `Ui.Env`. They are stored directly
instead of inside a resolved env so the effective palette exists only as a
derived value.
-}
type alias ViewConfig =
    { device : Element.Device
    , viewport : Env.Viewport
    , language : Language
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

        themeState : Theme.State
        themeState =
            Theme.fromFlags flags.themeMode flags.systemPrefersDark

        viewConfig : ViewConfig
        viewConfig =
            { device = classifyDevice flags.windowWidth flags.windowHeight
            , viewport = Env.viewportForWidth flags.windowWidth
            , language =
                parseLanguage flags.language
                    |> Result.withDefault I18n.defaultLanguage
            }
    in
    ( { key = key
      , route = Data.Route.fromUrl url
      , bootstrap =
            Bootstrapping { session = Nothing, status = Nothing }
      , today = Nothing
      , page = Page.loading
      , chrome = Chrome.init
      , loggingOut = False
      , logoutGeneration = 0
      , themeState = themeState
      , viewConfig = viewConfig
      , version = versionModel
      }
    , Cmd.batch
        [ Api.Auth.session GotSession
        , Api.Auth.bootstrapStatus GotBootstrapStatus
        , Cmd.map GotVersionMsg versionCmd
        ]
    )


{-| The single projection from canonical model state to the ambient view
context. `Theme.State` stays authoritative and the effective palette is
resolved here, so a stored env cannot drift from the saved preference or the
latest system scheme.
-}
envForModel : { model | themeState : Theme.State, viewConfig : ViewConfig } -> Env
envForModel model =
    { theme = Theme.forState model.themeState
    , device = model.viewConfig.device
    , viewport = model.viewConfig.viewport
    , language = model.viewConfig.language
    }



-- UPDATE


type Msg
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url
    | GotSession (Result Client.ApiError Auth.LoginSession)
    | GotBootstrapStatus (Result Client.ApiError Auth.BootstrapStatus)
    | LogoutCompleted Int
    | LogoutTimedOut Int
    | ScrollToTopCompleted
    | FocusCompleted
    | KeyPressed String
    | WindowResized Int Int
    | GotPageMsg Page.Msg
    | GotLocalCtx RawLocalCtx
    | GotBarcodeScannerEvent ScannerEvent
    | GotCopyTextResult CopyTextResult
    | GotSystemTheme Bool
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

                nextChrome : Chrome.Model
                nextChrome =
                    Chrome.close model.chrome

                ( nextModel, routeCmd ) =
                    changeRouteTo route { model | route = route, chrome = nextChrome }
            in
            ( nextModel
            , Cmd.batch
                [ routeCmd
                , drawerFocusCmd model.chrome nextChrome
                , themeMenuImplicitFocusCmd model.chrome nextChrome
                ]
            )

        GotSession result ->
            updateBootstrapProgress (\progress -> { progress | session = Just result }) model

        GotBootstrapStatus result ->
            updateBootstrapProgress (\progress -> { progress | status = Just result }) model

        LogoutCompleted generation ->
            if logoutStillApplies model.loggingOut generation model.logoutGeneration then
                clearLogoutState model

            else
                ( model, Cmd.none )

        LogoutTimedOut generation ->
            -- A hung logout must not suppress chrome or leave the local session
            -- authenticated. Generation matching makes a stale timer harmless
            -- after a newer logout or a fresh sign-in.
            if logoutStillApplies model.loggingOut generation model.logoutGeneration then
                clearLogoutState model

            else
                ( model, Cmd.none )

        ScrollToTopCompleted ->
            ( model, Cmd.none )

        FocusCompleted ->
            ( model, Cmd.none )

        KeyPressed key ->
            if key == "Escape" then
                stepChromeUpdate
                    Chrome.EscapePressed
                    (Chrome.update Chrome.EscapePressed model.chrome)
                    model

            else
                ( model, Cmd.none )

        WindowResized width height ->
            let
                nextViewConfig : ViewConfig
                nextViewConfig =
                    reclassifyViewConfig width height model.viewConfig

                nextChrome : Chrome.Model
                nextChrome =
                    Chrome.closeOnLayoutChange
                        model.viewConfig.device
                        nextViewConfig.device
                        model.chrome

                focusCmd : Cmd Msg
                focusCmd =
                    Cmd.batch
                        [ drawerFocusCmd model.chrome nextChrome
                        , themeMenuImplicitFocusCmd model.chrome nextChrome
                        ]
            in
            if nextViewConfig == model.viewConfig && nextChrome == model.chrome then
                ( model, Cmd.none )

            else
                ( { model | viewConfig = nextViewConfig, chrome = nextChrome }, focusCmd )

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
            stepPageUpdate (Page.barcodeScannerEventReceived (pageCtx model) event model.page) model

        GotCopyTextResult result ->
            stepPageUpdate
                (Page.update (pageCtx model)
                    (Page.CopyTextResult result.generation
                        result.requestId
                        result.succeeded
                    )
                    model.page
                )
                model

        GotSystemTheme systemPrefersDark ->
            let
                nextThemeState : Theme.State
                nextThemeState =
                    Theme.setSystemPrefersDark systemPrefersDark model.themeState
            in
            if nextThemeState == model.themeState then
                ( model, Cmd.none )

            else
                ( { model | themeState = nextThemeState }, Cmd.none )

        GotPageMsg pageMsg ->
            stepPageUpdate (Page.update (pageCtx model) pageMsg model.page) model

        GotChromeMsg chromeMsg ->
            stepChromeUpdate chromeMsg (Chrome.update chromeMsg model.chrome) model


{-| A completion or timer may only tear down the logout that started it:
`loggingOut` must still be set and its generation must still be current.
-}
logoutStillApplies : Bool -> Int -> Int -> Bool
logoutStillApplies loggingOut generation currentGeneration =
    loggingOut && generation == currentGeneration


{-| Shared local teardown for both a completed and a timed-out logout.
-}
clearLogoutState : Model -> ( Model, Cmd Msg )
clearLogoutState model =
    ( { model
        | bootstrap =
            setSession (Auth.clearSession (currentSession model)) model.bootstrap
        , page = Page.clearStore model.page
        , loggingOut = False
      }
    , Nav.replaceUrl model.key (Data.Route.routeToPath AuthLogin)
    )


{-| A drag emits resize events continuously, but the app only renders from the
classified device and viewport category. Returning `Nothing` when the
classification is unchanged leaves the model untouched so Elm can skip the
re-render.
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


{-| Same comparison for the coarse viewport category, so moving from 375px to
485px does not churn the model while crossing 359/360px still does.
-}
reclassifyViewport : Int -> Env.Viewport -> Maybe Env.Viewport
reclassifyViewport width current =
    let
        next : Env.Viewport
        next =
            Env.viewportForWidth width
    in
    if next == current then
        Nothing

    else
        Just next


reclassifyViewConfig : Int -> Int -> ViewConfig -> ViewConfig
reclassifyViewConfig width height viewConfig =
    { viewConfig
        | device =
            reclassifyDevice width height viewConfig.device
                |> Maybe.withDefault viewConfig.device
        , viewport =
            reclassifyViewport width viewConfig.viewport
                |> Maybe.withDefault viewConfig.viewport
    }


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


stepChromeUpdate : Chrome.Msg -> ( Chrome.Model, Chrome.OutMsg ) -> Model -> ( Model, Cmd Msg )
stepChromeUpdate chromeMsg ( chrome, outMsg ) model =
    let
        ( nextModel, outCmd ) =
            applyChromeOutMsg outMsg { model | chrome = chrome }

        focusCmd : Cmd Msg
        focusCmd =
            chromeFocusCmd chromeMsg model.chrome chrome
    in
    ( nextModel, Cmd.batch [ outCmd, focusCmd ] )


chromeFocusCmd : Chrome.Msg -> Chrome.Model -> Chrome.Model -> Cmd Msg
chromeFocusCmd chromeMsg previous next =
    case themeMenuFocusTarget chromeMsg previous next of
        Just id ->
            focusElement id

        Nothing ->
            drawerFocusCmd previous next


{-| Escape and choosing a preference remove the focused menu row, so focus
returns to the compact trigger. An outside click or navigation leaves focus
where the user put it instead of pulling it back into the top bar.
-}
themeMenuFocusTarget : Chrome.Msg -> Chrome.Model -> Chrome.Model -> Maybe String
themeMenuFocusTarget chromeMsg previous next =
    if
        Chrome.isThemeMenuOpen previous
            && not (Chrome.isThemeMenuOpen next)
            && closesThemeMenuWithFocus chromeMsg
    then
        Just ThemeChoice.compactTriggerId

    else
        Nothing


{-| Browser history and a Phone/large-layout switch close chrome without a
Chrome message. If either removes the open theme menu while it still owns
focus, put focus back on the compact trigger instead of dropping it on the
document body. Focus leaving the chooser closes it first, and outside clicks
arrive as `ThemeMenuClosed` after focus has moved, so neither uses this
recovery.
-}
themeMenuImplicitFocusTarget : Chrome.Model -> Chrome.Model -> Maybe String
themeMenuImplicitFocusTarget previous next =
    if Chrome.isThemeMenuOpen previous && not (Chrome.isThemeMenuOpen next) then
        Just ThemeChoice.compactTriggerId

    else
        Nothing


themeMenuImplicitFocusCmd : Chrome.Model -> Chrome.Model -> Cmd Msg
themeMenuImplicitFocusCmd previous next =
    case themeMenuImplicitFocusTarget previous next of
        Just id ->
            focusElement id

        Nothing ->
            Cmd.none


closesThemeMenuWithFocus : Chrome.Msg -> Bool
closesThemeMenuWithFocus chromeMsg =
    case chromeMsg of
        Chrome.EscapePressed ->
            True

        Chrome.ThemePreferenceClicked _ ->
            True

        _ ->
            False


{-| Focus enters a newly opened drawer and returns to its trigger when the
drawer closes. Browser Back and layout changes bypass Chrome messages, so every
drawer close uses this same transition rule.
-}
drawerFocusTarget : Chrome.Model -> Chrome.Model -> Maybe String
drawerFocusTarget previous next =
    if Chrome.isDrawerOpen next && not (Chrome.isDrawerOpen previous) then
        Just "app-drawer-close"

    else if Chrome.isDrawerOpen previous && not (Chrome.isDrawerOpen next) then
        Just "app-menu-trigger"

    else
        Nothing


drawerFocusCmd : Chrome.Model -> Chrome.Model -> Cmd Msg
drawerFocusCmd previous next =
    case drawerFocusTarget previous next of
        Just "app-menu-trigger" ->
            focusDrawerTrigger

        Just id ->
            focusElement id

        Nothing ->
            Cmd.none


{-| Phone layouts replace the drawer trigger with the bottom navigation. If a
layout change closes the drawer there, focus the current destination instead of
dropping it on the document body.
-}
focusDrawerTrigger : Cmd Msg
focusDrawerTrigger =
    Browser.Dom.focus "app-menu-trigger"
        |> Task.onError (\_ -> Browser.Dom.focus "app-bottom-nav-current")
        |> Task.attempt (\_ -> FocusCompleted)


focusElement : String -> Cmd Msg
focusElement id =
    Browser.Dom.focus id |> Task.attempt (\_ -> FocusCompleted)


applyChromeOutMsg : Chrome.OutMsg -> Model -> ( Model, Cmd Msg )
applyChromeOutMsg outMsg model =
    case outMsg of
        Chrome.NoOutMsg ->
            ( model, Cmd.none )

        Chrome.Navigate route ->
            ( { model | page = Page.dismissTransient model.page }
            , Nav.pushUrl model.key
                (Data.Route.routeToPath (normalizeChromeNavigation model.route route))
            )

        Chrome.Logout ->
            beginLogout model

        Chrome.SetThemePreference preference ->
            setThemePreference preference model

        Chrome.SetLanguage language ->
            setLanguage language model


beginLogout : Model -> ( Model, Cmd Msg )
beginLogout model =
    let
        generation : Int
        generation =
            model.logoutGeneration + 1
    in
    ( { model
        | page = Page.clearStore model.page
        , loggingOut = True
        , logoutGeneration = generation
      }
    , Cmd.batch
        [ Api.Auth.logout (\_ -> LogoutCompleted generation)
        , revokePhotoPreviewUrls (Page.photoPreviewUrls model.page)
        , Process.sleep 5000 |> Task.perform (\_ -> LogoutTimedOut generation)
        ]
    )


setThemePreference : Theme.Preference -> Model -> ( Model, Cmd Msg )
setThemePreference preference model =
    if preference == Theme.savedPreference model.themeState then
        ( model, Cmd.none )

    else
        let
            nextThemeState : Theme.State
            nextThemeState =
                Theme.selectPreference preference model.themeState
        in
        ( { model | themeState = nextThemeState }
        , persistThemeMode (Theme.preferenceToString preference)
        )


setLanguage : Language -> Model -> ( Model, Cmd Msg )
setLanguage language model =
    let
        viewConfig : ViewConfig
        viewConfig =
            model.viewConfig
    in
    ( { model | viewConfig = { viewConfig | language = language } }
    , persistLanguage (I18n.languageCode language)
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
                        Bootstrapped { session = nextSession, adminExists = adminExists }
                }

        _ ->
            ( model, Cmd.none )


changeRouteTo : Route -> Model -> ( Model, Cmd Msg )
changeRouteTo route model =
    changeRouteToWithScroll True route model


{-| The local-date rollover re-renders the current route, so it must not pull
the user to the top of a pane they are already reading.
-}
changeRouteToKeepingScroll : Route -> Model -> ( Model, Cmd Msg )
changeRouteToKeepingScroll route model =
    changeRouteToWithScroll False route model


changeRouteToWithScroll : Bool -> Route -> Model -> ( Model, Cmd Msg )
changeRouteToWithScroll resetScroll route model =
    case Access.resolveRoute (currentSession model) (currentAdminExists model) route of
        Access.Hold ->
            ( model, Cmd.none )

        Access.Render renderRoute ->
            loadPage resetScroll renderRoute model

        Access.Navigate target ->
            ( model, Nav.replaceUrl model.key (Data.Route.routeToPath target) )


{-| A rendered layout with exactly one visible pane scrolls the document, so a
route change starts it at the top. Phone and Tablet contextual routes build two
model panes but show only the detail pane; desktop two-pane layouts keep each
pane's own scroll. This runs on popstate too, so back/forward follows the same
top-reset policy as browser restoration is disabled in `index.js`.
-}
loadPage : Bool -> Route -> Model -> ( Model, Cmd Msg )
loadPage resetScroll route model =
    let
        ( page, pageCmd, outMsg ) =
            Page.initPreserving { route = route, today = model.today } model.page

        scrollCmd : Cmd Msg
        scrollCmd =
            if resetScroll && rendersOnePane (envForModel model) route page then
                Task.attempt (\_ -> ScrollToTopCompleted) (Browser.Dom.setViewport 0 0)

            else
                Cmd.none

        ( finalModel, pageEffects ) =
            stepPageResult ( page, pageCmd, outMsg ) model
    in
    ( finalModel, Cmd.batch [ pageEffects, scrollCmd ] )


{-| The scroll decision uses the pane visibility rule the workspace actually
renders, not the model pane count. A Phone/Tablet contextual route can hold two
model panes while showing only one of them. While the local date is still
missing, the boot body renders route-plan panes even though the model pane list
is empty, so use the boot keys then.
-}
rendersOnePane : Env -> Route -> Page.Model -> Bool
rendersOnePane env route page =
    let
        paneKeys : List String
        paneKeys =
            if Page.isLoading page then
                Page.bootPaneKeys route

            else
                Page.paneKeys page
    in
    Workspace.paneVisibility env.device paneKeys
        |> List.filter Tuple.second
        |> List.length
        |> (==) 1


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
    , Cmd.batch [ Cmd.map GotPageMsg pageCmd, outCmd, revokePhotoPreviewUrls removedPhotoUrls ]
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
                changeRouteToKeepingScroll model.route { model | today = Just context.date }

        Nothing ->
            changeRouteToKeepingScroll model.route { model | today = Just context.date }


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

        Page.SetThemePreference preference ->
            setThemePreference preference model

        Page.SetLanguage language ->
            setLanguage language model

        Page.Logout ->
            beginLogout model

        Page.SessionExpired ->
            ( { model
                | bootstrap =
                    setSession (Auth.clearSession (currentSession model)) model.bootstrap
                , page = Page.clearStore model.page
                , loggingOut = False
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
            , copyText { generation = generation, requestId = requestId, text = text }
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
                , loggingOut = False
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
                , loggingOut = False
              }
            , Nav.replaceUrl model.key (Data.Route.routeToPath AdminDashboard)
            )



-- VIEW


view : Model -> Browser.Document Msg
view model =
    let
        env : Env
        env =
            envForModel model

        session : Session
        session =
            currentSession model

        chromeSuppressed : Bool
        chromeSuppressed =
            not (isBootstrapped model.bootstrap) || model.loggingOut

        pageBusy : Bool
        pageBusy =
            not (isBootstrapped model.bootstrap) || Page.isBusy model.page

        modal : Maybe (Element Msg)
        modal =
            Page.modalView env model.page |> Maybe.map (Element.map GotPageMsg)

        updateBanner : Maybe (Element Msg)
        updateBanner =
            if model.version.updateAvailable then
                Just
                    (View.Chrome.updateBanner env (GotVersionMsg Version.ReloadPageRequested))

            else
                Nothing
    in
    { title = "CalCo"
    , body =
        [ Html.node "style"
            []
            [ Html.text
                ("html, body { background: "
                    ++ UiCommon.toCssColor env.theme.pageBg
                    ++ "; } :root { background: "
                    ++ UiCommon.toCssColor env.theme.pageBg
                    ++ "; "
                    ++ Css.themeCssVariables env.theme
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
                ++ bottomNavAttrs modal env model.route session chromeSuppressed
            )
          <|
            uiLayout env.theme
                (modalContentAttrs modal)
                (Chrome.viewFrame env
                    model.chrome
                    session
                    model.route
                    chromeSuppressed
                    pageBusy
                    updateBanner
                    (pageView env model)
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
open. The page's 56px reservation comes from the separate "where the nav can
appear" predicate in `Chrome.viewFrame`, so hiding the nav for a dialog does
not shift the page.
-}
bottomNavAttrs :
    Maybe (Element Msg)
    -> Env
    -> Route
    -> Session
    -> Bool
    -> List (Element.Attribute Msg)
bottomNavAttrs modal env route session chromeSuppressed =
    case modal of
        Just _ ->
            []

        Nothing ->
            Chrome.bottomNavLayoutAttrs env session route chromeSuppressed GotChromeMsg


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
        [ Element.el ([ Element.width Element.fill, Element.height Element.fill ] ++ extraAttrs)
            content
        ]


modalLayoutAttrs : Maybe (Element Msg) -> List (Element.Attribute Msg)
modalLayoutAttrs modal =
    case modal of
        Just modalCard ->
            [ Element.inFront modalCard ]

        Nothing ->
            []


pageView : Env -> Model -> Element Msg
pageView env model =
    if not (isBootstrapped model.bootstrap) then
        Page.bootShell env

    else
        Element.map GotPageMsg (Page.view env model.route model.page)


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
subscriptions model =
    Sub.batch
        [ localCtxReceived GotLocalCtx
        , barcodeScannerEvent GotBarcodeScannerEvent
        , copyTextResult GotCopyTextResult
        , systemThemeChanged GotSystemTheme
        , Browser.Events.onResize WindowResized
        , Browser.Events.onKeyDown (Decode.map KeyPressed (Decode.field "key" Decode.string))
        , themeMenuClickAway model.chrome
        , Sub.map GotVersionMsg Version.subscriptions
        , Sub.map GotPageMsg (Page.paneSubscriptions model.page)
        ]


{-| The compact theme menu is a non-modal popover, so a full-screen scrim
would make the first outside click only dismiss the menu. Listen on the
document instead: the click still reaches the page action under the pointer,
then closes the menu without moving focus. The decoder rejects clicks inside
the trigger or menu, including the opening click that is still bubbling when
this conditional subscription is installed.
-}
themeMenuClickAway : Chrome.Model -> Sub Msg
themeMenuClickAway chrome =
    if Chrome.isThemeMenuOpen chrome then
        Browser.Events.onClick
            (ThemeChoice.clickAwayDecoder (GotChromeMsg Chrome.ThemeMenuClosed))

    else
        Sub.none



-- PORTS


port requestLocalCtx : () -> Cmd msg


port localCtxReceived : (RawLocalCtx -> msg) -> Sub msg


port requestBarcodeScanStart : () -> Cmd msg


port requestBarcodeScanStop : () -> Cmd msg


port barcodeScannerEvent : (ScannerEvent -> msg) -> Sub msg


port revokePhotoPreviewUrls : List String -> Cmd msg


port copyText : CopyTextRequest -> Cmd msg


port copyTextResult : (CopyTextResult -> msg) -> Sub msg


port systemThemeChanged : (Bool -> msg) -> Sub msg


port persistThemeMode : String -> Cmd msg


port persistLanguage : String -> Cmd msg


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
