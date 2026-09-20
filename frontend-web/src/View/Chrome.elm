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
import Element.Region as Region
import Html.Attributes
import Ui.Button as Button
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
import Ui.Icon as Icon exposing (Icon)
import Ui.Input as UiInput
import Ui.Surface as Surface
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
    UiCommon.isSmall device
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
        , Element.height (Element.px DesignTokens.topBarHeight)
        , Element.paddingXY DesignTokens.space16 0
        , Element.spacing DesignTokens.space16
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
                    [ Element.width (Element.px DesignTokens.avatarSize)
                    , Element.height (Element.px DesignTokens.avatarSize)
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
    UiInput.toggleSwitch theme
        { isActive = theme.mode == Theme.Dark
        , onToggle = onToggle
        }


leadingButton : Device -> Theme -> LeadingAction -> msg -> (Route -> msg) -> Element msg
leadingButton device theme leading onMenuClick onNavigate =
    case leading of
        OpenMenu ->
            Button.iconButton device
                theme
                { icon = Icon.Menu
                , title = "Menu"
                , onPress = Just onMenuClick
                , tone = Button.Primary
                }

        GoBack route ->
            Button.iconButton device
                theme
                { icon = Icon.ChevronLeft
                , title = "Back"
                , onPress = Just (onNavigate route)
                , tone = Button.Primary
                }

        NoLeadingAction ->
            Element.el [ Element.width (Element.px DesignTokens.iconPlaceholder) ] Element.none

        ShowAppIcon ->
            Element.image
                [ Element.width (Element.px DesignTokens.avatarSize)
                , Element.height (Element.px DesignTokens.avatarSize)
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
        [ Element.width (Element.px DesignTokens.controlHeight)
        , Element.height (Element.px DesignTokens.controlHeight)
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
        , Element.paddingXY DesignTokens.space16 DesignTokens.space8
        , Background.color theme.brandBlueSoft
        , Font.color theme.brandBlue
        , Typography.banner
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
            UiCommon.isSmall device && not (Auth.isAdmin session)
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

        DiaryDay _ maybeCalendarMonth ->
            { title = "Diary"
            , leading =
                case maybeCalendarMonth of
                    Just month ->
                        GoBack (DiaryCalendar (Just month))

                    Nothing ->
                        if phoneNonAdmin then
                            ShowAppIcon

                        else
                            OpenMenu
            }

        DiaryCalendar _ ->
            { title = "Calendar"
            , leading = GoBack (DiaryDay Nothing Nothing)
            }

        NutritionDetails maybeDate ->
            { title = "Nutrition details"
            , leading = GoBack (DiaryDay maybeDate Nothing)
            }

        AdminDashboard ->
            { title = "Admin", leading = OpenMenu }

        AdminCreateUser ->
            { title = "Create User", leading = GoBack AdminDashboard }

        AdminEditUser _ ->
            { title = "Edit User", leading = GoBack AdminDashboard }

        GoalSettings ->
            { title = "Goals", leading = GoBack (DiaryDay Nothing Nothing) }

        DiarySettings ->
            { title = "Diary settings", leading = GoBack (DiaryDay Nothing Nothing) }

        FoodSearch maybeDate maybeSlot ->
            { title =
                case maybeSlot of
                    Just slot ->
                        "Add to " ++ MealSlot.label slot

                    Nothing ->
                        "Search Foods"
            , leading = GoBack (DiaryDay maybeDate Nothing)
            }

        FoodShow _ maybeDate maybeSlot _ ->
            { title = "Log Food", leading = GoBack (FoodSearch maybeDate maybeSlot) }

        FoodLogEntry _ maybeDate maybeCalendarMonth ->
            { title = "Edit Log"
            , leading = GoBack (DiaryDay maybeDate maybeCalendarMonth)
            }

        AdHocLogCreate maybeDate maybeSlot ->
            { title = "Manual Food Log"
            , leading = GoBack (FoodSearch maybeDate maybeSlot)
            }

        AiLogCreate maybeDate maybeSlot ->
            { title = "Log with AI"
            , leading = GoBack (FoodSearch maybeDate maybeSlot)
            }

        CustomFoodCreate ->
            { title = "Create Food", leading = GoBack CustomFoodList }

        CustomFoodCreateWithAi ->
            { title = "Create with AI", leading = GoBack CustomFoodList }

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
                    GoBack (DiaryDay Nothing Nothing)
            }

        MealList ->
            { title = "My Meals"
            , leading =
                if phoneNonAdmin then
                    NoLeadingAction

                else
                    GoBack (DiaryDay Nothing Nothing)
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
    bottomNavContainer config.theme
        [ tabButton config "Diary" (DiaryDay Nothing Nothing) Icon.Home
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
    bottomNavTab config.theme
        { icon = icon
        , label = label
        , active = active
        , onPress = config.onNavigate target
        }


bottomNavContainer : Theme -> List (Element msg) -> Element msg
bottomNavContainer theme items =
    Element.row
        [ Element.width Element.fill
        , Element.height (Element.px DesignTokens.bottomNavHeight)
        , Background.color theme.cardBg
        , Border.widthEach { top = 1, bottom = 0, left = 0, right = 0 }
        , Border.color theme.divider
        , Region.navigation

        -- Keep viewport positioning inline.
        -- elm-ui's generated position rules can override class-based CSS here.
        , Element.htmlAttribute (Html.Attributes.style "position" "fixed")
        , Element.htmlAttribute (Html.Attributes.style "right" "0")
        , Element.htmlAttribute (Html.Attributes.style "bottom" "0")
        , Element.htmlAttribute (Html.Attributes.style "left" "0")
        , Element.htmlAttribute (Html.Attributes.style "z-index" "10")
        ]
        items


bottomNavTab :
    Theme
    -> { icon : Icon, label : String, active : Bool, onPress : msg }
    -> Element msg
bottomNavTab theme config =
    let
        iconColor : Element.Color
        iconColor =
            if config.active then
                theme.brandBlue

            else
                theme.textMuted
    in
    Input.button
        [ Element.width (Element.fillPortion 1)
        , Element.height Element.fill
        , Element.paddingEach
            { top = DesignTokens.space8
            , right = 0
            , bottom = DesignTokens.space4
            , left = 0
            }
        , Font.color iconColor
        , Border.widthEach
            { top =
                if config.active then
                    2

                else
                    0
            , bottom = 0
            , left = 0
            , right = 0
            }
        , Border.color theme.brandBlue
        ]
        { onPress = Just config.onPress
        , label =
            Element.column
                [ Element.centerX
                , Element.centerY
                , Element.spacing DesignTokens.space2
                ]
                [ Element.el [ Element.centerX ]
                    (Icon.view
                        { icon = config.icon
                        , size = 22
                        , color = iconColor
                        }
                    )
                , Element.el
                    [ Element.centerX
                    , Typography.caption
                    ]
                    (Element.text config.label)
                ]
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
                , scrimOverlay config.theme (Just config.onClose)
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
    drawerPanel config.theme
        (Element.row [ Element.spacing DesignTokens.space8 ]
            [ Button.iconButton config.device
                config.theme
                { icon = Icon.Menu
                , title = "Close"
                , onPress = Just config.onClose
                , tone = Button.Primary
                }
            , Typography.sectionTitle config.theme "CalCo"
            ]
            :: Surface.hairline config.theme
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
            (DiaryDay Nothing Nothing)
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
    drawerItemButton theme
        { icon = icon
        , label = label
        , selected = selected
        , onPress = onNavigate target
        }


scrimOverlay : Theme -> Maybe msg -> Element msg
scrimOverlay theme onPress =
    Input.button
        [ Element.width Element.fill
        , Element.height Element.fill
        , Background.color theme.scrim
        ]
        { onPress = onPress
        , label = Element.none
        }


drawerPanel : Theme -> List (Element msg) -> Element msg
drawerPanel theme children =
    Element.column
        [ Element.width (Element.fill |> Element.maximum 320)
        , Element.height Element.fill
        , Element.paddingXY DesignTokens.space16 DesignTokens.space8
        , Element.spacing DesignTokens.space16
        , Background.color theme.cardBg
        , UiCommon.uiClass "ui-card-shadow"
        , Region.navigation
        ]
        children


drawerItemButton :
    Theme
    -> { icon : Maybe Icon, label : String, selected : Bool, onPress : msg }
    -> Element msg
drawerItemButton theme config =
    let
        itemColor : Element.Color
        itemColor =
            if config.selected then
                theme.brandBlue

            else
                theme.textPrimary

        iconEl : Element msg
        iconEl =
            case config.icon of
                Just icon ->
                    Icon.view
                        { icon = icon
                        , size = 20
                        , color = itemColor
                        }

                Nothing ->
                    Element.none
    in
    Input.button
        [ Element.width Element.fill
        , Element.paddingXY DesignTokens.space16 DesignTokens.space16
        , Border.rounded DesignTokens.radiusControl
        , Background.color
            (if config.selected then
                theme.drawerSelectionBg

             else
                theme.cardBg
            )
        , Font.color itemColor
        , Font.medium
        ]
        { onPress = Just config.onPress
        , label =
            Element.row
                [ Element.spacing DesignTokens.space8
                , Element.centerY
                ]
                [ iconEl
                , Element.text config.label
                ]
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
    menuCard config.theme
        { width = DesignTokens.profileMenuWidth
        , children = profileMenuContent config
        }


menuCard :
    Theme
    -> { width : Int, children : List (Element msg) }
    -> Element msg
menuCard theme config =
    Element.column
        [ Element.alignRight
        , Element.moveDown 4
        , Element.width (Element.px config.width)
        , Element.padding DesignTokens.space16
        , Element.spacing DesignTokens.space8
        , Background.color theme.cardBg
        , Border.rounded DesignTokens.radiusCard
        , UiCommon.uiClass "ui-card-shadow"
        ]
        config.children


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
    , Button.textButton config.device
        config.theme
        { tone = Button.Ghost
        , width = Button.FullWidth
        , label = "Calendar"
        , onPress = config.onNavigate (DiaryCalendar Nothing)
        , submitState = Nothing
        , submittingLabel = Nothing
        , trailing = Nothing
        }
    , Button.textButton config.device
        config.theme
        { tone = Button.Ghost
        , width = Button.FullWidth
        , label = "Goals"
        , onPress = config.onNavigate GoalSettings
        , submitState = Nothing
        , submittingLabel = Nothing
        , trailing = Nothing
        }
    , Button.textButton config.device
        config.theme
        { tone = Button.Ghost
        , width = Button.FullWidth
        , label = "Meal slots"
        , onPress = config.onNavigate DiarySettings
        , submitState = Nothing
        , submittingLabel = Nothing
        , trailing = Nothing
        }
    , Button.textButton config.device
        config.theme
        { tone = Button.Danger
        , width = Button.FullWidth
        , label = "Logout"
        , onPress = config.onLogout
        , submitState = Nothing
        , submittingLabel = Nothing
        , trailing = Nothing
        }
    ]
