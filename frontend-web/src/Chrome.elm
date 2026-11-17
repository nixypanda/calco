module Chrome exposing
    ( Model
    , Msg(..)
    , OutMsg(..)
    , bottomNavLayoutAttrs
    , close
    , closeOnLayoutChange
    , init
    , isDrawerOpen
    , isThemeMenuOpen
    , update
    , viewFrame
    )

import Data.Auth as Auth exposing (Session)
import Data.Route exposing (Route)
import Element exposing (Device, Element)
import Element.Region as Region
import Html.Attributes
import Lib.Text as Text
import Translations.Util exposing (Language)
import Ui.Common as UiCommon
import Ui.Env exposing (Env)
import Ui.Theme as Theme
import View.Chrome



-- MODEL


type Model
    = NoMenu
    | DrawerMenu
    | ProfileMenu
    | ThemeMenu


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
    | EscapePressed
    | ProfileClicked
    | NavigateClicked Route
    | LogoutClicked
    | ThemeMenuClicked
    | ThemeMenuClosed
    | ThemePreferenceClicked Theme.Preference
    | LanguageClicked Language


type OutMsg
    = NoOutMsg
    | Navigate Route
    | Logout
    | SetThemePreference Theme.Preference
    | SetLanguage Language


update : Msg -> Model -> ( Model, OutMsg )
update msg model =
    case msg of
        MenuClicked ->
            ( toggleMenu DrawerMenu model, NoOutMsg )

        DrawerClosed ->
            ( NoMenu, NoOutMsg )

        EscapePressed ->
            ( NoMenu, NoOutMsg )

        ProfileClicked ->
            ( toggleMenu ProfileMenu model, NoOutMsg )

        NavigateClicked route ->
            ( NoMenu, Navigate route )

        LogoutClicked ->
            ( NoMenu, Logout )

        ThemeMenuClicked ->
            ( toggleMenu ThemeMenu model, NoOutMsg )

        ThemeMenuClosed ->
            -- A click-away queued for the old theme menu can arrive after
            -- another click opened the profile or drawer menu.
            if isThemeMenuOpen model then
                ( NoMenu, NoOutMsg )

            else
                ( model, NoOutMsg )

        ThemePreferenceClicked preference ->
            ( NoMenu, SetThemePreference preference )

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


isDrawerOpen : Model -> Bool
isDrawerOpen model =
    isMenuOpen DrawerMenu model


isThemeMenuOpen : Model -> Bool
isThemeMenuOpen model =
    isMenuOpen ThemeMenu model


{-| Phone and non-phone layouts use different navigation, so a menu opened in
one must not remain latent in the other and reappear when the layout returns.
-}
closeOnLayoutChange : Device -> Device -> Model -> Model
closeOnLayoutChange previous next model =
    if UiCommon.isSmall previous /= UiCommon.isSmall next then
        NoMenu

    else
        model



-- VIEW


bottomNavLayoutAttrs :
    Env
    -> Session
    -> Route
    -> Bool
    -> (Msg -> msg)
    -> List (Element.Attribute msg)
bottomNavLayoutAttrs env session route chromeSuppressed toMsg =
    if showBottomNav env session chromeSuppressed route then
        [ Element.inFront
            (Element.el [ Element.width Element.fill, Element.alignBottom ]
                (View.Chrome.bottomNavBar env route (toMsg << NavigateClicked))
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
    -> Bool
    -> Maybe (Element msg)
    -> Element msg
    -> (Msg -> msg)
    -> Element msg
viewFrame env model session route chromeSuppressed pageBusy updateBanner page toMsg =
    let
        useBottomNav : Bool
        useBottomNav =
            showBottomNav env session chromeSuppressed route

        reserveBottomNav : Bool
        reserveBottomNav =
            View.Chrome.shouldReserveBottomNav env session route

        drawerIsVisible : Bool
        drawerIsVisible =
            not useBottomNav
                && View.Chrome.drawerVisible
                    session
                    chromeSuppressed
                    route
                    (isMenuOpen DrawerMenu model)

        shellAttrs : List (Element.Attribute msg)
        shellAttrs =
            if drawerIsVisible then
                [ Element.htmlAttribute (Html.Attributes.attribute "inert" "") ]

            else
                []

        chromeAttrs : List (Element.Attribute msg)
        chromeAttrs =
            if useBottomNav then
                []

            else
                View.Chrome.drawerOverlay env
                    session
                    route
                    chromeSuppressed
                    (isMenuOpen DrawerMenu model)
                    (toMsg DrawerClosed)
                    (toMsg << NavigateClicked)

        profileMenuEl : Maybe (Element msg)
        profileMenuEl =
            if
                isMenuOpen ProfileMenu model
                    && Auth.isAdmin session
                    && View.Chrome.showsAppChrome session chromeSuppressed route
            then
                Just
                    (View.Chrome.profileMenu env
                        session
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
    Element.column ([ Element.width Element.fill, Element.height Element.fill ] ++ chromeAttrs)
        [ Element.column
            ([ Element.width Element.fill
             , Element.height Element.fill
             , UiCommon.testId "app-shell-content"
             ]
                ++ shellAttrs
            )
            (View.Chrome.topBarView env
                session
                route
                chromeSuppressed
                (isMenuOpen DrawerMenu model)
                { open = isMenuOpen ThemeMenu model
                , onToggle = toMsg ThemeMenuClicked
                , onSelect = toMsg << ThemePreferenceClicked
                , onClose = toMsg ThemeMenuClosed
                }
                (toMsg MenuClicked)
                (toMsg ProfileClicked)
                (toMsg << LanguageClicked)
                (toMsg << NavigateClicked)
                { profileLabel = profileLetter session, profileMenu = profileMenuEl }
                :: updateBannerItems
                ++ [ Element.el (pageAttrs reserveBottomNav pageBusy) page ]
            )
        ]


showBottomNav : Env -> Session -> Bool -> Route -> Bool
showBottomNav env session chromeSuppressed route =
    View.Chrome.showBottomNav env session chromeSuppressed route


pageAttrs : Bool -> Bool -> List (Element.Attribute msg)
pageAttrs reserveBottomNav pageBusy =
    [ Element.width Element.fill
    , Element.height Element.fill
    , Region.mainContent
    , UiCommon.testId "page-root"
    ]
        ++ (if reserveBottomNav then
                [ Element.paddingEach { bottom = bottomNavClearance, top = 0, left = 0, right = 0 }
                ]

            else
                []
           )
        ++ [ if pageBusy then
                UiCommon.dataAttribute "data-page-state" "loading"

             else
                UiCommon.dataAttribute "data-page-loaded" "true"
           , UiCommon.dataAttribute "aria-busy"
                (if pageBusy then
                    "true"

                 else
                    "false"
                )
           ]


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
