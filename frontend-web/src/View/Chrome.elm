module View.Chrome exposing
    ( LeadingAction(..)
    , ScreenMeta
    , bottomNavBar
    , drawerOverlay
    , drawerVisible
    , profileMenu
    , shouldReserveBottomNav
    , showBottomNav
    , showsAppChrome
    , topBarView
    , updateBanner
    )

import Data.Auth as Auth exposing (Session)
import Data.MealSlot as MealSlot
import Data.Route exposing (Route(..), primaryRoute)
import Element exposing (Element)
import Element.Background as Background
import Element.Border as Border
import Element.Font as Font
import Element.Input as Input
import Element.Region as Region
import Html.Attributes
import I18n
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language(..))
import Ui.Button as Button
import Ui.Common as UiCommon
import Ui.DesignTokens as DesignTokens
import Ui.Env exposing (Env)
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
    { title : String, leading : LeadingAction }



-- CHROME VISIBILITY


{-| The app chrome is hidden only during an auth transition (boot or logout),
not while a page is fetching data.
-}
showsAppChrome : Session -> Bool -> Route -> Bool
showsAppChrome session chromeSuppressed route =
    Auth.isAuthenticated session
        && not chromeSuppressed
        && (case route of
                AuthLogin ->
                    False

                BootstrapSetup ->
                    False

                _ ->
                    True
           )


{-| Where the 56px bottom nav can appear at all: authenticated non-admin Phone
routes outside login and setup. This is the shared placement predicate; the
page padding is retained while the nav is temporarily hidden by chrome
suppression or a modal.
-}
shouldReserveBottomNav : Env -> Session -> Route -> Bool
shouldReserveBottomNav env session route =
    UiCommon.isSmall env.device
        && Auth.isAuthenticated session
        && not (Auth.isAdmin session)
        && route
        /= AuthLogin
        && route
        /= BootstrapSetup


showBottomNav : Env -> Session -> Bool -> Route -> Bool
showBottomNav env session chromeSuppressed route =
    shouldReserveBottomNav env session route && not chromeSuppressed



-- TOP BAR


topBarView :
    Env
    -> Session
    -> Route
    -> Bool
    -> Bool
    -> msg
    -> msg
    -> msg
    -> (Language -> msg)
    -> (Route -> msg)
    -> { profileLabel : String, profileMenu : Maybe (Element msg) }
    -> Element msg
topBarView env session route hidden menuOpen onMenu onProfile onTheme onSetLang onNavigate profile =
    let
        chromeShown : Bool
        chromeShown =
            showsAppChrome session hidden route

        meta : ScreenMeta
        meta =
            screenMeta env session route

        themeControl : List (Element msg)
        themeControl =
            if offersThemeSwitch session then
                [ Element.el
                    [ Element.paddingEach
                        { top = 0, right = DesignTokens.space8, bottom = 0, left = 0 }
                    ]
                    (themeToggle env onTheme)
                ]

            else
                []

        languageControl : List (Element msg)
        languageControl =
            if offersLanguageSwitch session then
                [ languageToggle env onSetLang ]

            else
                []

        profileControl : List (Element msg)
        profileControl =
            if Auth.isAdmin session then
                [ profileButton env onProfile profile ]

            else
                []
    in
    Element.row
        [ Element.width Element.fill
        , Element.height (Element.px 58)
        , Element.paddingXY DesignTokens.space16 0
        , Element.spacing DesignTokens.space12
        , Background.color env.theme.cardBg
        , Font.color env.theme.textPrimary
        , UiCommon.testId "app-topbar"
        ]
        (if chromeShown then
            [ leadingButton env menuOpen meta.leading onMenu onNavigate
            , Element.el [ Element.width Element.fill, Element.clip ]
                (Typography.screenTitle env.theme meta.title)
            ]
                ++ themeControl
                ++ profileControl

         else
            [ Element.row [ Element.spacing DesignTokens.space8, Element.centerY ]
                [ Element.image
                    [ Element.width (Element.px 28), Element.height (Element.px 28) ]
                    { src = "/android-chrome-192x192.png", description = "CalCo" }
                , Typography.pageTitle env.theme "CalCo"
                ]
            , Element.el [ Element.width Element.fill ] Element.none
            ]
                ++ languageControl
                ++ themeControl
        )


{-| The top bar only offers the theme switch to signed-out auth screens and to
admins, who cannot open the normal-user Settings page where the preference now
lives.
-}
offersThemeSwitch : Session -> Bool
offersThemeSwitch session =
    not (Auth.isAuthenticated session) || Auth.isAdmin session


{-| Login and setup are the only signed-out screens, and they have no account
menu or Settings page to hold a language choice.
-}
offersLanguageSwitch : Session -> Bool
offersLanguageSwitch session =
    not (Auth.isAuthenticated session)


boolString : Bool -> String
boolString value =
    if value then
        "true"

    else
        "false"


themeToggle : Env -> msg -> Element msg
themeToggle env onToggle =
    UiInput.toggleSwitch env.theme
        { label = I18n.t env.language TidCommonUseDarkTheme
        , isActive = env.theme.mode == Theme.Dark
        , onToggle = onToggle
        }


{-| A compact auth-screen control that names the language it switches to. The
neutral fill and primary text keep the control legible in both themes without
reintroducing the normal-user profile menu.
-}
languageToggle : Env -> (Language -> msg) -> Element msg
languageToggle env onSetLanguage =
    let
        target : Language
        target =
            case env.language of
                EN_US ->
                    HI_IN

                HI_IN ->
                    EN_US

        targetName : String
        targetName =
            I18n.languageName target

        description : String
        description =
            I18n.t env.language TidSettingsLanguageTitle ++ ": " ++ targetName
    in
    Input.button
        [ Element.height (Element.px 44)
        , Element.paddingXY DesignTokens.space12 0
        , Border.rounded DesignTokens.radiusPill
        , Border.width 1
        , Border.color env.theme.divider
        , Background.color env.theme.cardBg
        , Font.color env.theme.textPrimary
        , Font.medium
        , Font.size 14
        , Region.description description
        , Element.htmlAttribute (Html.Attributes.title description)
        , UiCommon.testId "language-toggle"
        ]
        { onPress = Just (onSetLanguage target)
        , label = Element.text targetName
        }


leadingButton : Env -> Bool -> LeadingAction -> msg -> (Route -> msg) -> Element msg
leadingButton env menuExpanded leading onMenuClick onNavigate =
    case leading of
        OpenMenu ->
            Button.iconButtonWithAttributes env.device
                env.theme
                [ Element.htmlAttribute (Html.Attributes.id "app-menu-trigger")
                , Element.htmlAttribute
                    (Html.Attributes.attribute "aria-expanded" (boolString menuExpanded))
                , Element.htmlAttribute (Html.Attributes.attribute "aria-controls" "app-drawer")
                ]
                { icon = Icon.Menu
                , title = I18n.t env.language TidNavMenu
                , onPress = Just onMenuClick
                , tone = Button.Primary
                }

        GoBack route ->
            Button.iconButton env.device
                env.theme
                { icon = Icon.ChevronLeft
                , title = I18n.t env.language TidNavBack
                , onPress = Just (onNavigate route)
                , tone = Button.Primary
                }

        NoLeadingAction ->
            Element.el [ Element.width (Element.px 40) ] Element.none

        ShowAppIcon ->
            Element.image [ Element.width (Element.px 28), Element.height (Element.px 28) ]
                { src = "/android-chrome-192x192.png", description = "CalCo" }


profileButton :
    Env
    -> msg
    -> { profileLabel : String, profileMenu : Maybe (Element msg) }
    -> Element msg
profileButton env onPress profile =
    let
        anchor : List (Element.Attribute msg)
        anchor =
            case profile.profileMenu of
                Just menu ->
                    [ Element.below menu ]

                Nothing ->
                    []
    in
    Element.el anchor (profileInitialButton env onPress profile.profileLabel)


profileInitialButton : Env -> msg -> String -> Element msg
profileInitialButton env onPress label =
    Input.button
        [ Element.width (Element.px 44)
        , Element.height (Element.px 44)
        , Background.color env.theme.cardBg
        , Font.color env.theme.textPrimary
        , Font.center
        , Border.rounded DesignTokens.radiusPill
        , Border.width 1
        , Border.color env.theme.divider
        , Element.htmlAttribute (Html.Attributes.title (I18n.t env.language TidCommonProfile))
        , Region.description (I18n.t env.language TidCommonProfile)
        ]
        { onPress = Just onPress, label = Element.text label }



-- UPDATE BANNER


updateBanner : Env -> msg -> Element msg
updateBanner env onPress =
    Input.button
        [ Element.width Element.fill
        , Element.paddingXY DesignTokens.space16 DesignTokens.space12
        , Background.color env.theme.brandBlueSoft
        , Font.color env.theme.brandBlue
        , Typography.body
        , UiCommon.testId "update-banner"
        ]
        { onPress = Just onPress
        , label =
            Element.row [ Element.width Element.fill, Element.spacing DesignTokens.space8 ]
                [ Element.el [ Element.centerY ]
                    (Element.text (I18n.t env.language TidCommonNewVersionAvailable))
                , Element.el [ Element.alignRight, Element.centerY, Font.bold ]
                    (Element.text (I18n.t env.language TidCommonTapToRefresh))
                ]
        }



-- HELPERS


screenMeta : Env -> Session -> Route -> ScreenMeta
screenMeta env session route =
    let
        phoneNonAdmin : Bool
        phoneNonAdmin =
            UiCommon.isSmall env.device && not (Auth.isAdmin session)
    in
    case route of
        Root ->
            { title = I18n.t env.language TidTitleDiary
            , leading =
                if phoneNonAdmin then
                    ShowAppIcon

                else
                    OpenMenu
            }

        DiaryDay _ maybeCalendarMonth ->
            { title = I18n.t env.language TidTitleDiary
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
            { title = I18n.t env.language TidTitleCalendar
            , leading = GoBack (DiaryDay Nothing Nothing)
            }

        NutritionDetails maybeDate ->
            { title = I18n.t env.language TidTitleNutritionDetails
            , leading = GoBack (DiaryDay maybeDate Nothing)
            }

        AdminDashboard ->
            { title = I18n.t env.language TidTitleAdmin, leading = OpenMenu }

        AdminCreateUser ->
            { title = I18n.t env.language TidTitleCreateUser, leading = GoBack AdminDashboard }

        AdminEditUser _ ->
            { title = I18n.t env.language TidTitleEditUser, leading = GoBack AdminDashboard }

        GoalSettings maybeDate maybeCalendarMonth ->
            { title = I18n.t env.language TidTitleGoals
            , leading = GoBack (DiaryDay maybeDate maybeCalendarMonth)
            }

        DiarySettings ->
            { title = I18n.t env.language TidTitleDiarySettings
            , leading = GoBack (DiaryDay Nothing Nothing)
            }

        Library ->
            { title = I18n.t env.language TidTitleLibrary
            , leading =
                if phoneNonAdmin then
                    ShowAppIcon

                else
                    OpenMenu
            }

        Settings ->
            { title = I18n.t env.language TidTitleSettings
            , leading =
                if phoneNonAdmin then
                    ShowAppIcon

                else
                    OpenMenu
            }

        SettingsApiKeys ->
            { title = I18n.t env.language TidTitleApiKeys
            , leading = GoBack Settings
            }

        SettingsApiKeyCreate ->
            { title = I18n.t env.language TidApiKeysCreateTitle
            , leading = GoBack SettingsApiKeys
            }

        FoodSearch maybeDate maybeSlot ->
            { title =
                case maybeSlot of
                    Just slot ->
                        I18n.t env.language
                            (TidTitleAddToMealSlot (MealSlot.label env.language slot))

                    Nothing ->
                        I18n.t env.language TidTitleSearchFoods
            , leading =
                case maybeSlot of
                    Just _ ->
                        GoBack (DiaryDay maybeDate Nothing)

                    Nothing ->
                        if phoneNonAdmin then
                            ShowAppIcon

                        else
                            OpenMenu
            }

        FoodShow _ maybeDate maybeSlot _ ->
            { title = I18n.t env.language TidTitleLogFood
            , leading = GoBack (FoodSearch maybeDate maybeSlot)
            }

        FoodLogEntry _ maybeDate maybeCalendarMonth ->
            { title = I18n.t env.language TidTitleEditLog
            , leading = GoBack (DiaryDay maybeDate maybeCalendarMonth)
            }

        AdHocLogCreate maybeDate maybeSlot ->
            { title = I18n.t env.language TidTitleManualFoodLog
            , leading = GoBack (FoodSearch maybeDate maybeSlot)
            }

        AiLogCreate maybeDate maybeSlot ->
            { title = I18n.t env.language TidTitleLogWithAi
            , leading = GoBack (FoodSearch maybeDate maybeSlot)
            }

        CustomFoodCreate ->
            { title = I18n.t env.language TidTitleCreateFood, leading = GoBack CustomFoodList }

        CustomFoodCreateWithAi ->
            { title = I18n.t env.language TidTitleCreateWithAi, leading = GoBack CustomFoodList }

        CustomFoodEdit _ ->
            { title = I18n.t env.language TidTitleEditFood, leading = GoBack CustomFoodList }

        CustomFoodShow _ ->
            { title = I18n.t env.language TidTitleFood, leading = GoBack CustomFoodList }

        CustomFoodList ->
            { title = I18n.t env.language TidTitleMyFoods
            , leading = GoBack Library
            }

        MealList ->
            { title = I18n.t env.language TidTitleMyMeals
            , leading = GoBack Library
            }

        MealCreate ->
            { title = I18n.t env.language TidTitleCreateMeal, leading = GoBack MealList }

        MealShow _ ->
            { title = I18n.t env.language TidTitleMeal, leading = GoBack MealList }

        MealEdit _ ->
            { title = I18n.t env.language TidTitleEditMeal, leading = GoBack MealList }

        AuthLogin ->
            { title = I18n.t env.language TidTitleLogin, leading = NoLeadingAction }

        BootstrapSetup ->
            { title = I18n.t env.language TidTitleSetup, leading = NoLeadingAction }

        NotFound ->
            { title = I18n.t env.language TidTitleDiary, leading = OpenMenu }



-- BOTTOM NAV


bottomNavBar : Env -> Route -> (Route -> msg) -> Element msg
bottomNavBar env route onNavigate =
    bottomNavContainer env.theme
        [ tabButton env
            route
            onNavigate
            { label = I18n.t env.language TidNavDiary
            , target = DiaryDay Nothing Nothing
            , navTarget = "diary"
            , icon = Icon.Home
            }
        , tabButton env
            route
            onNavigate
            { label = I18n.t env.language TidNavSearch
            , target = FoodSearch Nothing Nothing
            , navTarget = "search"
            , icon = Icon.Search
            }
        , tabButton env
            route
            onNavigate
            { label = I18n.t env.language TidNavLibrary
            , target = Library
            , navTarget = "library"
            , icon = Icon.Library
            }
        , tabButton env
            route
            onNavigate
            { label = I18n.t env.language TidNavSettings
            , target = Settings
            , navTarget = "settings"
            , icon = Icon.Settings
            }
        ]


tabButton :
    Env
    -> Route
    -> (Route -> msg)
    -> { label : String, target : Route, navTarget : String, icon : Icon }
    -> Element msg
tabButton env route onNavigate config =
    let
        active : Bool
        active =
            primaryRoute route == primaryRoute config.target
    in
    bottomNavTab env.theme
        { icon = config.icon
        , label = config.label
        , active = active
        , navTarget = config.navTarget
        , onPress = onNavigate config.target
        }


bottomNavContainer : Theme -> List (Element msg) -> Element msg
bottomNavContainer theme items =
    Element.row
        [ Element.width Element.fill
        , Element.height (Element.px 56)
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
        , UiCommon.testId "app-bottom-nav"
        ]
        items


bottomNavTab :
    Theme
    -> { icon : Icon, label : String, active : Bool, navTarget : String, onPress : msg }
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
        ([ Element.width (Element.fillPortion 1)
         , Element.height Element.fill
         , Element.paddingEach
            { top = DesignTokens.space8, right = 0, bottom = DesignTokens.space4, left = 0 }
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
         , UiCommon.dataAttribute "data-nav-target" config.navTarget
         ]
            ++ (if config.active then
                    [ Element.htmlAttribute (Html.Attributes.id "app-bottom-nav-current")
                    , Element.htmlAttribute (Html.Attributes.attribute "aria-current" "page")
                    ]

                else
                    []
               )
        )
        { onPress = Just config.onPress
        , label =
            Element.column [ Element.centerX, Element.centerY, Element.spacing DesignTokens.space2 ]
                [ Element.el [ Element.centerX ]
                    (Icon.view { icon = config.icon, size = 22, color = iconColor })
                , Element.el
                    ([ Element.centerX, Typography.caption ]
                        ++ (if config.active then
                                [ Font.semiBold ]

                            else
                                []
                           )
                    )
                    (Element.text config.label)
                ]
        }



-- DRAWER


drawerOverlay :
    Env
    -> Session
    -> Route
    -> Bool
    -> Bool
    -> msg
    -> (Route -> msg)
    -> List (Element.Attribute msg)
drawerOverlay env session route chromeSuppressed drawerOpen onClose onNavigate =
    if drawerVisible session chromeSuppressed route drawerOpen then
        [ Element.inFront
            (Element.row [ Element.width Element.fill, Element.height Element.fill ]
                [ drawerView env session route onClose onNavigate
                , scrimOverlay env.theme (I18n.t env.language TidCommonClose) (Just onClose)
                ]
            )
        ]

    else
        []


{-| The drawer is an overlay, so the rest of the shell must be inert while it
renders. Both the overlay and the inert state follow this one predicate.
-}
drawerVisible : Session -> Bool -> Route -> Bool -> Bool
drawerVisible session chromeSuppressed route drawerOpen =
    drawerOpen && showsAppChrome session chromeSuppressed route


drawerView : Env -> Session -> Route -> msg -> (Route -> msg) -> Element msg
drawerView env session route onClose onNavigate =
    drawerPanel env.theme
        (Element.row [ Element.spacing DesignTokens.space8 ]
            [ Button.iconButtonWithAttributes env.device
                env.theme
                [ Element.htmlAttribute (Html.Attributes.id "app-drawer-close") ]
                { icon = Icon.Menu
                , title = I18n.t env.language TidCommonClose
                , onPress = Just onClose
                , tone = Button.Primary
                }
            , Typography.sectionTitle env.theme "CalCo"
            ]
            :: Surface.hairline env.theme
            :: drawerItems env session route onNavigate
        )


drawerItems : Env -> Session -> Route -> (Route -> msg) -> List (Element msg)
drawerItems env session route onNavigate =
    if Auth.isAdmin session then
        [ drawerItem env.theme
            route
            onNavigate
            { icon = Nothing
            , label = I18n.t env.language TidNavAdmin
            , navTarget = "admin"
            , target = AdminDashboard
            }
        ]

    else
        [ drawerItem env.theme
            route
            onNavigate
            { icon = Just Icon.Home
            , label = I18n.t env.language TidNavDiary
            , navTarget = "diary"
            , target = DiaryDay Nothing Nothing
            }
        , drawerItem env.theme
            route
            onNavigate
            { icon = Just Icon.Search
            , label = I18n.t env.language TidNavSearch
            , navTarget = "search"
            , target = FoodSearch Nothing Nothing
            }
        , drawerItem env.theme
            route
            onNavigate
            { icon = Just Icon.Library
            , label = I18n.t env.language TidNavLibrary
            , navTarget = "library"
            , target = Library
            }
        , drawerItem env.theme
            route
            onNavigate
            { icon = Just Icon.Settings
            , label = I18n.t env.language TidNavSettings
            , navTarget = "settings"
            , target = Settings
            }
        ]


drawerItem :
    Theme
    -> Route
    -> (Route -> msg)
    -> { icon : Maybe Icon, label : String, navTarget : String, target : Route }
    -> Element msg
drawerItem theme current onNavigate config =
    let
        selected : Bool
        selected =
            primaryRoute current == primaryRoute config.target
    in
    drawerItemButton theme
        { icon = config.icon
        , label = config.label
        , selected = selected
        , navTarget = config.navTarget
        , onPress = onNavigate config.target
        }


scrimOverlay : Theme -> String -> Maybe msg -> Element msg
scrimOverlay theme label onPress =
    Input.button
        [ Element.width Element.fill
        , Element.height Element.fill
        , Background.color theme.scrim
        , Element.htmlAttribute (Html.Attributes.attribute "aria-label" label)
        , UiCommon.testId "app-drawer-scrim"
        ]
        { onPress = onPress, label = Element.none }


drawerPanel : Theme -> List (Element msg) -> Element msg
drawerPanel theme children =
    Element.column
        [ Element.width (Element.fill |> Element.maximum 320)
        , Element.height Element.fill
        , Element.paddingXY DesignTokens.space16 DesignTokens.space8
        , Element.spacing DesignTokens.space12
        , Background.color theme.cardSurfaceBg
        , UiCommon.uiClass "ui-card-shadow"
        , Region.navigation
        , Element.htmlAttribute (Html.Attributes.id "app-drawer")
        , UiCommon.testId "app-drawer"
        ]
        children


drawerItemButton :
    Theme
    -> { icon : Maybe Icon, label : String, selected : Bool, navTarget : String, onPress : msg }
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
                    Icon.view { icon = icon, size = 20, color = itemColor }

                Nothing ->
                    Element.none

        labelAttrs : List (Element.Attribute msg)
        labelAttrs =
            if config.selected then
                [ Font.semiBold ]

            else
                []
    in
    Input.button
        ([ Element.width Element.fill
         , Element.paddingXY DesignTokens.space16 DesignTokens.space12
         , Border.rounded DesignTokens.radiusControl
         , Background.color
            (if config.selected then
                theme.drawerSelectionBg

             else
                theme.cardBg
            )
         , Font.color itemColor
         , Font.medium
         , UiCommon.dataAttribute "data-nav-target" config.navTarget
         ]
            ++ (if config.selected then
                    [ Element.htmlAttribute (Html.Attributes.attribute "aria-current" "page") ]

                else
                    []
               )
        )
        { onPress = Just config.onPress
        , label =
            Element.row [ Element.spacing DesignTokens.space12, Element.centerY ]
                [ iconEl, Element.el labelAttrs (Element.text config.label) ]
        }



-- PROFILE MENU


profileMenu : Env -> Session -> msg -> (Language -> msg) -> Element msg
profileMenu env session onLogout onSetLanguage =
    menuCard env.theme
        { width = 240, children = profileMenuContent env session onLogout onSetLanguage }


menuCard : Theme -> { width : Int, children : List (Element msg) } -> Element msg
menuCard theme config =
    Element.column
        [ Element.alignRight
        , Element.moveDown (toFloat DesignTokens.space4)
        , Element.width (Element.px config.width)
        , Element.padding DesignTokens.space12
        , Element.spacing DesignTokens.space12
        , Background.color theme.cardSurfaceBg
        , Border.rounded DesignTokens.radiusCard
        , UiCommon.uiClass "ui-card-shadow"
        ]
        config.children


profileMenuContent :
    Env
    -> Session
    -> msg
    -> (Language -> msg)
    -> List (Element msg)
profileMenuContent env session onLogout onSetLanguage =
    [ Typography.mutedCaption env.theme
        (case session of
            Auth.Authenticated identity ->
                I18n.t env.language (TidCommonSignedInAs identity.username)

            _ ->
                I18n.t env.language TidCommonSignedIn
        )
    , Element.column [ Element.width Element.fill, Element.spacing DesignTokens.space4 ]
        [ languageOption env onSetLanguage EN_US
        , languageOption env onSetLanguage HI_IN
        ]
    , Button.textButton env.device
        env.theme
        { tone = Button.DangerOutline
        , width = Button.FullWidth
        , label = I18n.t env.language TidNavLogout
        , onPress = onLogout
        , submitState = Nothing
        , submittingLabel = Nothing
        , trailing = Nothing
        }
    ]


languageOption : Env -> (Language -> msg) -> Language -> Element msg
languageOption env onSetLanguage language =
    UiInput.optionRowWithState env.theme
        { label = I18n.languageName language
        , selected = env.language == language
        , onPress = onSetLanguage language
        , disabled = False
        , trailing = Nothing
        }
