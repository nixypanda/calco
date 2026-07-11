module View.Chrome exposing
    ( LeadingAction(..)
    , ScreenMeta
    , bottomNavBar
    , drawerOverlay
    , profileMenu
    , showBottomNav
    , showsAppChrome
    , topBarView
    , updateBanner
    )

import Data.Auth as Auth exposing (Session)
import Data.MealSlot as MealSlot
import Data.Route exposing (Route(..), primaryRoute)
import Element exposing (Device, Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Html.Attributes
import Ui
import Ui.DesignTokens as DesignTokens
import Ui.Icon as Icon exposing (Icon)
import Ui.Theme as Theme exposing (Theme)
import Ui.Typography as Typography



-- TYPES


type LeadingAction
    = OpenMenu
    | GoBack Route
    | NoLeadingAction
    | ShowAppIcon


type alias ScreenMeta =
    { title : String
    , leading : LeadingAction
    }



-- CHROME VISIBILITY


showsAppChrome : Session -> Bool -> Route -> Bool
showsAppChrome session isLoadingPage route =
    Auth.isAuthenticated session
        && not isLoadingPage
        && (case route of
                AuthLogin ->
                    False

                BootstrapSetup ->
                    False

                _ ->
                    True
           )


showBottomNav : Device -> Session -> Bool -> Route -> Bool
showBottomNav device session isLoadingPage route =
    Ui.isSmall device
        && showsAppChrome session isLoadingPage route
        && not (Auth.isAdmin session)



-- TOP BAR


topBarView :
    { device : Device
    , theme : Theme
    , session : Session
    , route : Route
    , profileOpen : Bool
    , isLoadingPage : Bool
    , onMenuClick : msg
    , onProfileClick : msg
    , onThemeToggle : msg
    , onNavigate : Route -> msg
    }
    -> { profileLabel : String, profileMenu : Maybe (Element msg) }
    -> Element msg
topBarView config profile =
    let
        chromeShown : Bool
        chromeShown =
            showsAppChrome config.session config.isLoadingPage config.route

        meta : ScreenMeta
        meta =
            screenMeta config.device config.session config.route
    in
    Element.row
        [ Element.width Element.fill
        , Element.height (Element.px 58)
        , Element.paddingXY DesignTokens.space16 0
        , Element.spacing DesignTokens.space12
        , Background.color config.theme.cardBg
        , Font.color config.theme.textPrimary
        ]
        (if chromeShown then
            [ leadingButton config.device
                config.theme
                meta.leading
                config.onMenuClick
                config.onNavigate
            , Element.el
                [ Element.width Element.fill
                , Element.clip
                ]
                (Typography.subsectionTitle config.theme meta.title)
            , Element.el
                [ Element.paddingEach
                    { top = 0
                    , right = DesignTokens.space8
                    , bottom = 0
                    , left = 0
                    }
                ]
                (themeToggle config.theme config.onThemeToggle)
            , profileButton config.onProfileClick config.theme profile
            ]

         else
            [ Element.row
                [ Element.spacing DesignTokens.space8
                , Element.centerY
                ]
                [ Element.image
                    [ Element.width (Element.px 28)
                    , Element.height (Element.px 28)
                    ]
                    { src = "/android-chrome-192x192.png"
                    , description = "CalCo"
                    }
                , Typography.pageTitle config.theme "CalCo"
                ]
            , Element.el [ Element.width Element.fill ] Element.none
            , themeToggle config.theme config.onThemeToggle
            ]
        )


themeToggle : Theme -> msg -> Element msg
themeToggle theme onToggle =
    Ui.toggleSwitch theme
        { isActive = theme.mode == Theme.Dark
        , onToggle = onToggle
        }


leadingButton : Device -> Theme -> LeadingAction -> msg -> (Route -> msg) -> Element msg
leadingButton device theme leading onMenuClick onNavigate =
    case leading of
        OpenMenu ->
            Ui.iconButton device theme { icon = Icon.Menu, title = "Menu", onPress = onMenuClick }

        GoBack route ->
            Ui.iconButton device
                theme
                { icon = Icon.ChevronLeft, title = "Back", onPress = onNavigate route }

        NoLeadingAction ->
            Element.el [ Element.width (Element.px 40) ] Element.none

        ShowAppIcon ->
            Element.image
                [ Element.width (Element.px 28)
                , Element.height (Element.px 28)
                ]
                { src = "/android-chrome-192x192.png"
                , description = "CalCo"
                }


profileButton :
    msg
    -> Theme
    -> { profileLabel : String, profileMenu : Maybe (Element msg) }
    -> Element msg
profileButton onPress theme profile =
    let
        anchor : List (Element.Attribute msg)
        anchor =
            case profile.profileMenu of
                Just menu ->
                    [ Element.below menu ]

                Nothing ->
                    []
    in
    Element.el anchor
        (profileInitialButton onPress theme profile.profileLabel)


profileInitialButton : msg -> Theme -> String -> Element msg
profileInitialButton onPress theme label =
    Input.button
        [ Element.width (Element.px 44)
        , Element.height (Element.px 44)
        , Background.color theme.cardBg
        , Font.color theme.textPrimary
        , Font.center
        , Border.rounded DesignTokens.radiusPill
        , Border.width 1
        , Border.color theme.divider
        , Element.htmlAttribute (Html.Attributes.title "Profile")
        , Element.htmlAttribute (Html.Attributes.attribute "aria-label" "Profile")
        ]
        { onPress = Just onPress
        , label = Element.text label
        }



-- UPDATE BANNER


updateBanner : Theme -> msg -> Element msg
updateBanner theme onPress =
    Input.button
        [ Element.width Element.fill
        , Element.paddingXY DesignTokens.space16 DesignTokens.space12
        , Background.color theme.brandBlueSoft
        , Font.color theme.brandBlue
        , Font.size 18
        ]
        { onPress = Just onPress
        , label =
            Element.row
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space8
                ]
                [ Element.el [ Element.centerY ] (Element.text "New version available")
                , Element.el
                    [ Element.alignRight
                    , Element.centerY
                    , Font.bold
                    ]
                    (Element.text "Tap to refresh")
                ]
        }



-- HELPERS


screenMeta : Device -> Session -> Route -> ScreenMeta
screenMeta device session route =
    let
        phoneNonAdmin : Bool
        phoneNonAdmin =
            Ui.isSmall device && not (Auth.isAdmin session)
    in
    case route of
        Root ->
            { title = "Diary"
            , leading =
                if phoneNonAdmin then
                    ShowAppIcon

                else
                    OpenMenu
            }

        DiaryDay _ ->
            { title = "Diary"
            , leading =
                if phoneNonAdmin then
                    ShowAppIcon

                else
                    OpenMenu
            }

        AdminDashboard ->
            { title = "Admin", leading = OpenMenu }

        AdminCreateUser ->
            { title = "Create User", leading = GoBack AdminDashboard }

        AdminEditUser _ ->
            { title = "Edit User", leading = GoBack AdminDashboard }

        GoalSettings ->
            { title = "Goals", leading = GoBack (DiaryDay Nothing) }

        DiarySettings ->
            { title = "Diary settings", leading = GoBack (DiaryDay Nothing) }

        FoodSearch maybeDate maybeSlot ->
            { title =
                case maybeSlot of
                    Just slot ->
                        "Add to " ++ MealSlot.label slot

                    Nothing ->
                        "Search Foods"
            , leading = GoBack (DiaryDay maybeDate)
            }

        FoodShow _ maybeDate maybeSlot ->
            { title = "Log Food", leading = GoBack (FoodSearch maybeDate maybeSlot) }

        FoodLogEntry _ ->
            { title = "Edit Log", leading = GoBack (DiaryDay Nothing) }

        CustomFoodCreate ->
            { title = "Create Food", leading = GoBack CustomFoodList }

        CustomFoodEdit _ ->
            { title = "Edit Food", leading = GoBack CustomFoodList }

        CustomFoodShow _ ->
            { title = "Food", leading = GoBack CustomFoodList }

        CustomFoodList ->
            { title = "My Foods"
            , leading =
                if phoneNonAdmin then
                    NoLeadingAction

                else
                    GoBack (DiaryDay Nothing)
            }

        MealList ->
            { title = "My Meals"
            , leading =
                if phoneNonAdmin then
                    NoLeadingAction

                else
                    GoBack (DiaryDay Nothing)
            }

        MealCreate ->
            { title = "Create Meal", leading = GoBack MealList }

        MealShow _ ->
            { title = "Meal", leading = GoBack MealList }

        MealEdit _ ->
            { title = "Edit Meal", leading = GoBack MealList }

        AuthLogin ->
            { title = "Login", leading = NoLeadingAction }

        BootstrapSetup ->
            { title = "Setup", leading = NoLeadingAction }

        NotFound ->
            { title = "Diary", leading = OpenMenu }



-- BOTTOM NAV


bottomNavBar :
    { theme : Theme
    , session : Session
    , route : Route
    , onNavigate : Route -> msg
    }
    -> Element msg
bottomNavBar config =
    Ui.bottomNavBar config.theme
        [ tabButton config "Diary" (DiaryDay Nothing) Icon.Home
        , tabButton config "Search" (FoodSearch Nothing Nothing) Icon.Search
        , tabButton config "Foods" CustomFoodList Icon.Box
        , tabButton config "Meals" MealList Icon.Utensils
        ]


tabButton :
    { theme : Theme
    , session : Session
    , route : Route
    , onNavigate : Route -> msg
    }
    -> String
    -> Route
    -> Icon
    -> Element msg
tabButton config label target icon =
    let
        active : Bool
        active =
            primaryRoute config.route == primaryRoute target
    in
    Ui.bottomNavTab config.theme
        { icon = icon
        , label = label
        , active = active
        , onPress = config.onNavigate target
        }



-- DRAWER


drawerOverlay :
    { device : Device
    , theme : Theme
    , session : Session
    , route : Route
    , drawerOpen : Bool
    , onClose : msg
    , onNavigate : Route -> msg
    }
    -> List (Element.Attribute msg)
drawerOverlay config =
    let
        isLoadingPage : Bool
        isLoadingPage =
            False

        viewConfig :
            { device : Device
            , theme : Theme
            , session : Session
            , route : Route
            , onClose : msg
            , onNavigate : Route -> msg
            }
        viewConfig =
            { device = config.device
            , theme = config.theme
            , session = config.session
            , route = config.route
            , onClose = config.onClose
            , onNavigate = config.onNavigate
            }
    in
    if config.drawerOpen && showsAppChrome config.session isLoadingPage config.route then
        [ Element.inFront
            (Element.row
                [ Element.width Element.fill
                , Element.height Element.fill
                ]
                [ drawerView viewConfig
                , Ui.scrimOverlay (Just config.onClose)
                ]
            )
        ]

    else
        []


drawerView :
    { device : Device
    , theme : Theme
    , session : Session
    , route : Route
    , onClose : msg
    , onNavigate : Route -> msg
    }
    -> Element msg
drawerView config =
    let
        itemsConfig : { theme : Theme, session : Session, route : Route, onNavigate : Route -> msg }
        itemsConfig =
            { theme = config.theme
            , session = config.session
            , route = config.route
            , onNavigate = config.onNavigate
            }
    in
    Ui.drawerPanel config.theme
        (Element.row [ Element.spacing DesignTokens.space8 ]
            [ Ui.iconButton config.device
                config.theme
                { icon = Icon.Menu, title = "Close", onPress = config.onClose }
            , Typography.sectionTitle config.theme "CalCo"
            ]
            :: Ui.hairline config.theme
            :: drawerItems itemsConfig
        )


drawerItems :
    { theme : Theme
    , session : Session
    , route : Route
    , onNavigate : Route -> msg
    }
    -> List (Element msg)
drawerItems config =
    if Auth.isAdmin config.session then
        [ drawerItem config.theme config.route config.onNavigate Nothing "Admin" AdminDashboard ]

    else
        [ drawerItem config.theme
            config.route
            config.onNavigate
            (Just Icon.Home)
            "Diary"
            (DiaryDay Nothing)
        , drawerItem config.theme
            config.route
            config.onNavigate
            (Just Icon.Search)
            "Search Foods"
            (FoodSearch Nothing Nothing)
        , drawerItem config.theme
            config.route
            config.onNavigate
            (Just Icon.Box)
            "My Foods"
            CustomFoodList
        , drawerItem config.theme
            config.route
            config.onNavigate
            (Just Icon.Utensils)
            "My Meals"
            MealList
        ]


drawerItem : Theme -> Route -> (Route -> msg) -> Maybe Icon -> String -> Route -> Element msg
drawerItem theme current onNavigate icon label target =
    let
        selected : Bool
        selected =
            primaryRoute current == primaryRoute target
    in
    Ui.drawerItem theme
        { icon = icon
        , label = label
        , selected = selected
        , onPress = onNavigate target
        }



-- PROFILE MENU


profileMenu :
    { device : Device
    , theme : Theme
    , session : Session
    , onNavigate : Route -> msg
    , onLogout : msg
    }
    -> Element msg
profileMenu config =
    Ui.menuCard config.theme
        { width = 240
        , children = profileMenuContent config
        }


profileMenuContent :
    { device : Device
    , theme : Theme
    , session : Session
    , onNavigate : Route -> msg
    , onLogout : msg
    }
    -> List (Element msg)
profileMenuContent config =
    [ Typography.mutedCaption config.theme
        (case config.session of
            Auth.Authenticated identity ->
                "Signed in as " ++ identity.username

            _ ->
                "Signed in"
        )
    , Ui.fullWidthGhostButton config.device config.theme "Goals" (config.onNavigate GoalSettings)
    , Ui.fullWidthGhostButton config.device
        config.theme
        "Meal slots"
        (config.onNavigate DiarySettings)
    , Ui.fullWidthDangerButton config.device config.theme "Logout" config.onLogout
    ]
