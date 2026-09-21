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


showBottomNav : Env -> Session -> Bool -> Route -> Bool
showBottomNav env session isLoadingPage route =
    UiCommon.isSmall env.device
        && showsAppChrome session isLoadingPage route
        && not (Auth.isAdmin session)



-- TOP BAR


topBarView :
    { env : Env
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
            screenMeta config.env config.session config.route
    in
    Element.row
        [ Element.width Element.fill
        , Element.height (Element.px 58)
        , Element.paddingXY DesignTokens.space16 0
        , Element.spacing DesignTokens.space12
        , Background.color config.env.theme.cardBg
        , Font.color config.env.theme.textPrimary
        ]
        (if chromeShown then
            [ leadingButton config.env
                meta.leading
                config.onMenuClick
                config.onNavigate
            , Element.el
                [ Element.width Element.fill
                , Element.clip
                ]
                (Typography.screenTitle config.env.theme meta.title)
            , Element.el
                [ Element.paddingEach
                    { top = 0
                    , right = DesignTokens.space8
                    , bottom = 0
                    , left = 0
                    }
                ]
                (themeToggle config.env config.onThemeToggle)
            , profileButton config.env
                config.onProfileClick
                profile
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
                , Typography.pageTitle config.env.theme "CalCo"
                ]
            , Element.el [ Element.width Element.fill ] Element.none
            , themeToggle config.env config.onThemeToggle
            ]
        )


themeToggle : Env -> msg -> Element msg
themeToggle env onToggle =
    UiInput.toggleSwitch env.theme
        { label = I18n.t env.language TidCommonUseDarkTheme
        , isActive = env.theme.mode == Theme.Dark
        , onToggle = onToggle
        }


leadingButton : Env -> LeadingAction -> msg -> (Route -> msg) -> Element msg
leadingButton env leading onMenuClick onNavigate =
    case leading of
        OpenMenu ->
            Button.iconButton env.device
                env.theme
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
            Element.image
                [ Element.width (Element.px 28)
                , Element.height (Element.px 28)
                ]
                { src = "/android-chrome-192x192.png"
                , description = "CalCo"
                }


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
    Element.el anchor
        (profileInitialButton env onPress profile.profileLabel)


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
        , Element.htmlAttribute
            (Html.Attributes.attribute "aria-label" (I18n.t env.language TidCommonProfile))
        ]
        { onPress = Just onPress
        , label = Element.text label
        }



-- UPDATE BANNER


updateBanner : Env -> msg -> Element msg
updateBanner env onPress =
    Input.button
        [ Element.width Element.fill
        , Element.paddingXY DesignTokens.space16 DesignTokens.space12
        , Background.color env.theme.brandBlueSoft
        , Font.color env.theme.brandBlue
        , Typography.body
        ]
        { onPress = Just onPress
        , label =
            Element.row
                [ Element.width Element.fill
                , Element.spacing DesignTokens.space8
                ]
                [ Element.el [ Element.centerY ]
                    (Element.text (I18n.t env.language TidCommonNewVersionAvailable))
                , Element.el
                    [ Element.alignRight
                    , Element.centerY
                    , Font.bold
                    ]
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

        GoalSettings ->
            { title = I18n.t env.language TidTitleGoals
            , leading = GoBack (DiaryDay Nothing Nothing)
            }

        DiarySettings ->
            { title = I18n.t env.language TidTitleDiarySettings
            , leading = GoBack (DiaryDay Nothing Nothing)
            }

        FoodSearch maybeDate maybeSlot ->
            { title =
                case maybeSlot of
                    Just slot ->
                        I18n.t env.language
                            (TidTitleAddToMealSlot (MealSlot.label env.language slot))

                    Nothing ->
                        I18n.t env.language TidTitleSearchFoods
            , leading = GoBack (DiaryDay maybeDate Nothing)
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
            , leading =
                if phoneNonAdmin then
                    NoLeadingAction

                else
                    GoBack (DiaryDay Nothing Nothing)
            }

        MealList ->
            { title = I18n.t env.language TidTitleMyMeals
            , leading =
                if phoneNonAdmin then
                    NoLeadingAction

                else
                    GoBack (DiaryDay Nothing Nothing)
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


bottomNavBar :
    { env : Env
    , session : Session
    , route : Route
    , onNavigate : Route -> msg
    }
    -> Element msg
bottomNavBar config =
    bottomNavContainer config.env.theme
        [ tabButton config
            (I18n.t config.env.language TidNavDiary)
            (DiaryDay Nothing Nothing)
            Icon.Home
        , tabButton config
            (I18n.t config.env.language TidNavSearch)
            (FoodSearch Nothing Nothing)
            Icon.Search
        , tabButton config (I18n.t config.env.language TidNavFoods) CustomFoodList Icon.Box
        , tabButton config (I18n.t config.env.language TidNavMeals) MealList Icon.Utensils
        ]


tabButton :
    { env : Env
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
    bottomNavTab config.env.theme
        { icon = icon
        , label = label
        , active = active
        , onPress = config.onNavigate target
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
    { env : Env
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
            { env : Env
            , session : Session
            , route : Route
            , onClose : msg
            , onNavigate : Route -> msg
            }
        viewConfig =
            { env = config.env
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
                , scrimOverlay config.env.theme (Just config.onClose)
                ]
            )
        ]

    else
        []


drawerView :
    { env : Env
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
            { theme = config.env.theme
            , session = config.session
            , route = config.route
            , onNavigate = config.onNavigate
            }
    in
    drawerPanel config.env.theme
        (Element.row [ Element.spacing DesignTokens.space8 ]
            [ Button.iconButton config.env.device
                config.env.theme
                { icon = Icon.Menu
                , title = I18n.t config.env.language TidCommonClose
                , onPress = Just config.onClose
                , tone = Button.Primary
                }
            , Typography.sectionTitle config.env.theme "CalCo"
            ]
            :: Surface.hairline config.env.theme
            :: drawerItems config.env.language itemsConfig
        )


drawerItems :
    Language
    -> { theme : Theme, session : Session, route : Route, onNavigate : Route -> msg }
    -> List (Element msg)
drawerItems language config =
    if Auth.isAdmin config.session then
        [ drawerItem
            config.theme
            config.route
            config.onNavigate
            Nothing
            (I18n.t language TidNavAdmin)
            AdminDashboard
        ]

    else
        [ drawerItem config.theme
            config.route
            config.onNavigate
            (Just Icon.Home)
            (I18n.t language TidNavDiary)
            (DiaryDay Nothing Nothing)
        , drawerItem config.theme
            config.route
            config.onNavigate
            (Just Icon.Search)
            (I18n.t language TidNavSearchFoods)
            (FoodSearch Nothing Nothing)
        , drawerItem config.theme
            config.route
            config.onNavigate
            (Just Icon.Box)
            (I18n.t language TidNavMyFoods)
            CustomFoodList
        , drawerItem config.theme
            config.route
            config.onNavigate
            (Just Icon.Utensils)
            (I18n.t language TidNavMyMeals)
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
        , Element.spacing DesignTokens.space12
        , Background.color theme.cardSurfaceBg
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
        ]
        { onPress = Just config.onPress
        , label =
            Element.row
                [ Element.spacing DesignTokens.space12
                , Element.centerY
                ]
                [ iconEl
                , Element.text config.label
                ]
        }



-- PROFILE MENU


profileMenu :
    { env : Env
    , session : Session
    , onNavigate : Route -> msg
    , onLogout : msg
    , onSetLanguage : Language -> msg
    }
    -> Element msg
profileMenu config =
    menuCard config.env.theme
        { width = 240
        , children = profileMenuContent config
        }


menuCard :
    Theme
    -> { width : Int, children : List (Element msg) }
    -> Element msg
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
    { env : Env
    , session : Session
    , onNavigate : Route -> msg
    , onLogout : msg
    , onSetLanguage : Language -> msg
    }
    -> List (Element msg)
profileMenuContent config =
    [ Typography.mutedCaption config.env.theme
        (case config.session of
            Auth.Authenticated identity ->
                I18n.t config.env.language (TidCommonSignedInAs identity.username)

            _ ->
                I18n.t config.env.language TidCommonSignedIn
        )
    , Button.textButton config.env.device
        config.env.theme
        { tone = Button.Ghost
        , width = Button.FullWidth
        , label = I18n.t config.env.language TidNavCalendar
        , onPress = config.onNavigate (DiaryCalendar Nothing)
        , submitState = Nothing
        , submittingLabel = Nothing
        , trailing = Nothing
        }
    , Button.textButton config.env.device
        config.env.theme
        { tone = Button.Ghost
        , width = Button.FullWidth
        , label = I18n.t config.env.language TidNavGoals
        , onPress = config.onNavigate GoalSettings
        , submitState = Nothing
        , submittingLabel = Nothing
        , trailing = Nothing
        }
    , Button.textButton config.env.device
        config.env.theme
        { tone = Button.Ghost
        , width = Button.FullWidth
        , label = I18n.t config.env.language TidNavMealSlots
        , onPress = config.onNavigate DiarySettings
        , submitState = Nothing
        , submittingLabel = Nothing
        , trailing = Nothing
        }
    , Element.row
        [ Element.width Element.fill
        , Element.spacing DesignTokens.space8
        ]
        [ Button.textButton config.env.device
            config.env.theme
            { tone =
                if config.env.language == EN_US then
                    Button.Primary

                else
                    Button.Ghost
            , width = Button.FullWidth
            , label = "English"
            , onPress = config.onSetLanguage EN_US
            , submitState = Nothing
            , submittingLabel = Nothing
            , trailing = Nothing
            }
        , Button.textButton config.env.device
            config.env.theme
            { tone =
                if config.env.language == HI_IN then
                    Button.Primary

                else
                    Button.Ghost
            , width = Button.FullWidth
            , label = "हिन्दी"
            , onPress = config.onSetLanguage HI_IN
            , submitState = Nothing
            , submittingLabel = Nothing
            , trailing = Nothing
            }
        ]
    , Button.textButton config.env.device
        config.env.theme
        { tone = Button.Danger
        , width = Button.FullWidth
        , label = I18n.t config.env.language TidNavLogout
        , onPress = config.onLogout
        , submitState = Nothing
        , submittingLabel = Nothing
        , trailing = Nothing
        }
    ]
