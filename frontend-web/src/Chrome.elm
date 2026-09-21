module Chrome exposing
    ( Model
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
import Element exposing (Element)
import Element.Region as Region
import Lib.Text as Text
import Translations.Util exposing (Language)
import Ui.Env exposing (Env)
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
    | LanguageClicked Language


type OutMsg
    = NoOutMsg
    | Navigate Route
    | Logout
    | ToggleTheme
    | SetLanguage Language


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

        LanguageClicked language ->
            ( NoMenu, SetLanguage language )


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


bottomNavLayoutAttrs :
    Env
    -> Session
    -> Route
    -> Bool
    -> (Msg -> msg)
    -> List (Element.Attribute msg)
bottomNavLayoutAttrs env session route isLoadingPage toMsg =
    if showBottomNav env session isLoadingPage route then
        [ Element.inFront
            (Element.el
                [ Element.width Element.fill
                , Element.alignBottom
                ]
                (View.Chrome.bottomNavBar
                    env
                    route
                    (toMsg << NavigateClicked)
                )
            )
        ]

    else
        []


viewFrame :
    Env
    -> Model
    -> Session
    -> Route
    -> Bool
    -> Maybe (Element msg)
    -> Element msg
    -> (Msg -> msg)
    -> Element msg
viewFrame env model session route isLoadingPage updateBanner page toMsg =
    let
        useBottomNav : Bool
        useBottomNav =
            showBottomNav env session isLoadingPage route

        chromeAttrs : List (Element.Attribute msg)
        chromeAttrs =
            if useBottomNav then
                []

            else
                View.Chrome.drawerOverlay
                    env
                    session
                    route
                    (isMenuOpen DrawerMenu model)
                    (toMsg DrawerClosed)
                    (toMsg << NavigateClicked)

        profileMenuEl : Maybe (Element msg)
        profileMenuEl =
            if
                isMenuOpen ProfileMenu model
                    && View.Chrome.showsAppChrome session isLoadingPage route
            then
                Just
                    (View.Chrome.profileMenu
                        env
                        session
                        (toMsg << NavigateClicked)
                        (toMsg LogoutClicked)
                        (toMsg << LanguageClicked)
                    )

            else
                Nothing

        updateBannerItems : List (Element msg)
        updateBannerItems =
            case updateBanner of
                Just banner ->
                    [ banner ]

                Nothing ->
                    []
    in
    Element.column
        ([ Element.width Element.fill, Element.height Element.fill ] ++ chromeAttrs)
        (View.Chrome.topBarView
            env
            session
            route
            isLoadingPage
            (toMsg MenuClicked)
            (toMsg ProfileClicked)
            (toMsg ThemeToggleClicked)
            (toMsg << NavigateClicked)
            { profileLabel = profileLetter session
            , profileMenu = profileMenuEl
            }
            :: updateBannerItems
            ++ [ Element.el (pageAttrs useBottomNav) page ]
        )


showBottomNav : Env -> Session -> Bool -> Route -> Bool
showBottomNav env session isLoadingPage route =
    View.Chrome.showBottomNav env session isLoadingPage route


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
