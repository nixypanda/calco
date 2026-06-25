module Chrome exposing
    ( FrameConfig
    , LayoutConfig
    , Model
    , Msg
    , OutMsg(..)
    , bottomNavLayoutAttrs
    , close
    , init
    , update
    , viewFrame
    )

import Data.Auth as Auth exposing (Session)
import Data.Route exposing (Route)
import Element exposing (Device, Element)
import Element.Region as Region
import Lib.Text as Text
import Ui.Theme exposing (Theme)
import View.Chrome



-- MODEL


type Model
    = NoMenu
    | DrawerMenu
    | ProfileMenu


init : Model
init =
    NoMenu


close : Model -> Model
close _ =
    NoMenu



-- UPDATE


type Msg
    = MenuClicked
    | DrawerClosed
    | ProfileClicked
    | NavigateClicked Route
    | LogoutClicked
    | ThemeToggleClicked


type OutMsg
    = NoOutMsg
    | Navigate Route
    | Logout
    | ToggleTheme


update : Msg -> Model -> ( Model, OutMsg )
update msg model =
    case msg of
        MenuClicked ->
            ( toggleMenu DrawerMenu model, NoOutMsg )

        DrawerClosed ->
            ( NoMenu, NoOutMsg )

        ProfileClicked ->
            ( toggleMenu ProfileMenu model, NoOutMsg )

        NavigateClicked route ->
            ( NoMenu, Navigate route )

        LogoutClicked ->
            ( NoMenu, Logout )

        ThemeToggleClicked ->
            ( model, ToggleTheme )


toggleMenu : Model -> Model -> Model
toggleMenu target current =
    if current == target then
        NoMenu

    else
        target


isMenuOpen : Model -> Model -> Bool
isMenuOpen target current =
    current == target



-- VIEW


type alias LayoutConfig msg =
    { model : Model
    , device : Device
    , theme : Theme
    , session : Session
    , route : Route
    , isLoadingPage : Bool
    , toMsg : Msg -> msg
    }


bottomNavLayoutAttrs : LayoutConfig msg -> List (Element.Attribute msg)
bottomNavLayoutAttrs config =
    if showBottomNav config then
        [ Element.inFront
            (Element.el
                [ Element.width Element.fill
                , Element.alignBottom
                ]
                (View.Chrome.bottomNavBar
                    { theme = config.theme
                    , session = config.session
                    , route = config.route
                    , onNavigate = config.toMsg << NavigateClicked
                    }
                )
            )
        ]

    else
        []


type alias FrameConfig msg =
    { model : Model
    , device : Device
    , theme : Theme
    , session : Session
    , route : Route
    , isLoadingPage : Bool
    , updateBanner : Maybe (Element msg)
    , page : Element msg
    , toMsg : Msg -> msg
    }


viewFrame : FrameConfig msg -> Element msg
viewFrame config =
    let
        useBottomNav : Bool
        useBottomNav =
            showBottomNav config

        chromeAttrs : List (Element.Attribute msg)
        chromeAttrs =
            if useBottomNav then
                []

            else
                View.Chrome.drawerOverlay
                    { device = config.device
                    , theme = config.theme
                    , session = config.session
                    , route = config.route
                    , drawerOpen = isMenuOpen DrawerMenu config.model
                    , onClose = config.toMsg DrawerClosed
                    , onNavigate = config.toMsg << NavigateClicked
                    }

        profileMenuEl : Maybe (Element msg)
        profileMenuEl =
            if
                isMenuOpen ProfileMenu config.model
                    && View.Chrome.showsAppChrome config.session config.isLoadingPage config.route
            then
                Just
                    (View.Chrome.profileMenu
                        { device = config.device
                        , theme = config.theme
                        , session = config.session
                        , onNavigate = config.toMsg << NavigateClicked
                        , onLogout = config.toMsg LogoutClicked
                        }
                    )

            else
                Nothing

        updateBannerItems : List (Element msg)
        updateBannerItems =
            case config.updateBanner of
                Just banner ->
                    [ banner ]

                Nothing ->
                    []
    in
    Element.column
        ([ Element.width Element.fill, Element.height Element.fill ] ++ chromeAttrs)
        (View.Chrome.topBarView
            { device = config.device
            , theme = config.theme
            , session = config.session
            , route = config.route
            , profileOpen = isMenuOpen ProfileMenu config.model
            , isLoadingPage = config.isLoadingPage
            , onMenuClick = config.toMsg MenuClicked
            , onProfileClick = config.toMsg ProfileClicked
            , onThemeToggle = config.toMsg ThemeToggleClicked
            , onNavigate = config.toMsg << NavigateClicked
            }
            { profileLabel = profileLetter config.session
            , profileMenu = profileMenuEl
            }
            :: updateBannerItems
            ++ [ Element.el (pageAttrs useBottomNav) config.page ]
        )


showBottomNav :
    { config
        | device : Device
        , session : Session
        , isLoadingPage : Bool
        , route : Route
    }
    -> Bool
showBottomNav config =
    View.Chrome.showBottomNav config.device config.session config.isLoadingPage config.route


pageAttrs : Bool -> List (Element.Attribute msg)
pageAttrs useBottomNav =
    [ Element.width Element.fill
    , Element.height Element.fill
    , Region.mainContent
    ]
        ++ (if useBottomNav then
                [ Element.paddingEach
                    { bottom = bottomNavClearance
                    , top = 0
                    , left = 0
                    , right = 0
                    }
                ]

            else
                []
           )


bottomNavClearance : Int
bottomNavClearance =
    56


profileLetter : Session -> String
profileLetter session =
    case session of
        Auth.Authenticated identity ->
            Text.initial identity.username

        _ ->
            "?"
