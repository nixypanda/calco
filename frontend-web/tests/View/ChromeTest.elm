module View.ChromeTest exposing (tests)

{-| Shell chrome laws: bottom-nav visibility, chrome suppression, and the Back
destination carried by screen metadata. The Back case drives the rendered
control so the route context reaches the user action, not just a helper.
-}

import Chrome as ChromeState
import Data.Auth as Auth exposing (Session(..))
import Data.MealSlot as MealSlot
import Data.Route exposing (Route(..))
import Element exposing (Device)
import Expect
import Fuzz
import Html.Attributes as Attr
import I18n
import Lib.Date exposing (LocalDate)
import Support.Fixtures as Fixtures
import Support.Fuzz as SupportFuzz
import Test exposing (Test, describe, fuzz2, fuzz3, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector exposing (Selector)
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language(..))
import Ui.Env exposing (Env, Viewport(..))
import Ui.Theme as Theme
import View.Chrome as Chrome


tests : Test
tests =
    describe "View.Chrome"
        [ describe "shouldReserveBottomNav"
            [ fuzz2 SupportFuzz.device
                SupportFuzz.route
                "authenticated non-admins reserve only on Phone app routes"
                (\device route ->
                    Chrome.shouldReserveBottomNav (envFor device) user route
                        |> Expect.equal (reservesOnPhone device route)
                )
            , fuzz2 SupportFuzz.device
                SupportFuzz.route
                "admins never reserve"
                (\device route ->
                    Chrome.shouldReserveBottomNav (envFor device) admin route
                        |> Expect.equal False
                )
            , fuzz2 SupportFuzz.device
                SupportFuzz.route
                "anonymous users never reserve"
                (\device route ->
                    Chrome.shouldReserveBottomNav (envFor device) anonymous route
                        |> Expect.equal False
                )
            ]
        , describe "showBottomNav"
            [ fuzz3 SupportFuzz.device
                SupportFuzz.route
                Fuzz.bool
                "renders exactly when reserved and chrome is not suppressed"
                (\device route suppressed ->
                    Chrome.showBottomNav (envFor device) user suppressed route
                        |> Expect.equal (reservesOnPhone device route && not suppressed)
                )
            ]
        , describe "showsAppChrome"
            [ fuzz2 SupportFuzz.route
                Fuzz.bool
                "authenticated app routes show chrome unless suppressed"
                (\route suppressed ->
                    Chrome.showsAppChrome user suppressed route
                        |> Expect.equal (isAppRoute route && not suppressed)
                )
            , fuzz2 SupportFuzz.route
                Fuzz.bool
                "anonymous sessions never show app chrome"
                (\route suppressed ->
                    Chrome.showsAppChrome anonymous suppressed route
                        |> Expect.equal False
                )
            ]
        , test "Phone bottom nav offers diary, search, library, and settings" <|
            \_ ->
                let
                    nav : Query.Single Route
                    nav =
                        Chrome.bottomNavBar
                            (envFor { class = Element.Phone, orientation = Element.Portrait })
                            (DiaryDay Nothing Nothing)
                            identity
                            |> Element.layout []
                            |> Query.fromHtml
                in
                Expect.all
                    [ \_ ->
                        nav
                            |> Query.has
                                [ Selector.text (I18n.t EN_US TidNavDiary) ]
                    , \_ ->
                        nav
                            |> Query.has
                                [ Selector.text (I18n.t EN_US TidNavSearch) ]
                    , \_ ->
                        nav
                            |> Query.has
                                [ Selector.text (I18n.t EN_US TidNavLibrary) ]
                    , \_ ->
                        nav
                            |> Query.has
                                [ Selector.text (I18n.t EN_US TidNavSettings) ]
                    , \_ ->
                        nav
                            |> Query.hasNot
                                [ Selector.text (I18n.t EN_US TidNavFoods) ]
                    , \_ ->
                        nav
                            |> Query.hasNot
                                [ Selector.text (I18n.t EN_US TidNavMeals) ]
                    , \_ ->
                        expectNavTarget nav
                            TidNavLibrary
                            Library
                    , \_ ->
                        expectNavTarget nav
                            TidNavSettings
                            Settings
                    ]
                    ()
        , test "the drawer offers the same four flat destinations" <|
            \_ ->
                let
                    drawer : Query.Single Route
                    drawer =
                        drawerFor user (DiaryDay Nothing Nothing)
                in
                Expect.all
                    [ \_ ->
                        drawer
                            |> Query.has [ Selector.text (I18n.t EN_US TidNavDiary) ]
                    , \_ ->
                        drawer
                            |> Query.has [ Selector.text (I18n.t EN_US TidNavSearch) ]
                    , \_ ->
                        drawer
                            |> Query.has [ Selector.text (I18n.t EN_US TidNavLibrary) ]
                    , \_ ->
                        drawer
                            |> Query.has [ Selector.text (I18n.t EN_US TidNavSettings) ]
                    , \_ ->
                        drawer
                            |> Query.hasNot [ Selector.text (I18n.t EN_US TidNavMyFoods) ]
                    , \_ ->
                        drawer
                            |> Query.hasNot [ Selector.text (I18n.t EN_US TidNavMyMeals) ]
                    , \_ ->
                        expectNavTarget drawer TidNavLibrary Library
                    , \_ ->
                        expectNavTarget drawer TidNavSettings Settings
                    ]
                    ()
        , test "bottom nav and drawer mark the semantic destination" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        expectActiveTab
                            (FoodSearch (Just date) (Just MealSlot.Lunch))
                            TidNavSearch
                    , \_ -> expectActiveTab SettingsApiKeys TidNavSettings
                    , \_ ->
                        expectActiveDrawerItem (CustomFoodShow "food-1") TidNavLibrary
                    , \_ -> expectActiveDrawerItem (DiaryDay (Just date) Nothing) TidNavDiary
                    ]
                    ()
        , test "an admin drawer only offers the admin destination" <|
            \_ ->
                let
                    drawer : Query.Single Route
                    drawer =
                        drawerFor admin AdminDashboard
                in
                Expect.all
                    [ \_ ->
                        drawer
                            |> Query.has [ Selector.text (I18n.t EN_US TidNavAdmin) ]
                    , \_ ->
                        drawer
                            |> Query.hasNot [ Selector.text (I18n.t EN_US TidNavDiary) ]
                    , \_ ->
                        drawer
                            |> Query.hasNot [ Selector.text (I18n.t EN_US TidNavSearch) ]
                    , \_ ->
                        drawer
                            |> Query.hasNot [ Selector.text (I18n.t EN_US TidNavLibrary) ]
                    , \_ ->
                        drawer
                            |> Query.hasNot [ Selector.text (I18n.t EN_US TidNavSettings) ]
                    ]
                    ()
        , test "goals Back keeps the diary date and calendar context" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        expectBackTarget (DiaryDay (Just date) (Just month))
                            (GoalSettings (Just date) (Just month))
                    , \_ ->
                        expectBackTarget (DiaryDay Nothing Nothing)
                            (GoalSettings Nothing Nothing)
                    ]
                    ()
        , test "library and settings child pages return to their landing pages" <|
            \_ ->
                Expect.all
                    [ \_ -> expectBackTarget Library CustomFoodList
                    , \_ -> expectBackTarget Library MealList
                    , \_ -> expectBackTarget Settings SettingsApiKeys
                    ]
                    ()
        , test "top-level search exposes the drawer menu on non-phone layouts" <|
            \_ ->
                expectMenuLeading
                    tabletDevice
                    (FoodSearch (Just date) Nothing)
        , test "contextual search keeps Back to the dated diary" <|
            \_ ->
                expectBackTargetOn
                    phoneDevice
                    (DiaryDay (Just date) Nothing)
                    (FoodSearch (Just date) (Just MealSlot.Lunch))
        , test "the drawer trigger exposes its expanded state" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        topbarForWith
                            { device = { class = Element.Tablet, orientation = Element.Portrait }
                            , menuExpanded = False
                            }
                            user
                            Library
                            |> menuTrigger
                            |> Query.has
                                [ Selector.attribute (Attr.attribute "aria-expanded" "false") ]
                    , \_ ->
                        topbarForWith
                            { device = { class = Element.Tablet, orientation = Element.Portrait }
                            , menuExpanded = True
                            }
                            user
                            Library
                            |> menuTrigger
                            |> Query.has
                                [ Selector.attribute (Attr.attribute "aria-expanded" "true") ]
                    , \_ ->
                        topbarForWith
                            { device = { class = Element.Tablet, orientation = Element.Portrait }
                            , menuExpanded = False
                            }
                            user
                            Library
                            |> menuTrigger
                            |> Query.has
                                [ Selector.attribute (Attr.attribute "aria-controls" "app-drawer") ]
                    ]
                    ()
        , test "the drawer scrim has an accessible close label" <|
            \_ ->
                drawerFor user (DiaryDay Nothing Nothing)
                    |> Query.find
                        [ Selector.attribute
                            (Attr.attribute "data-testid" "app-drawer-scrim")
                        ]
                    |> Query.has
                        [ Selector.attribute
                            (Attr.attribute "aria-label" (I18n.en TidCommonClose))
                        ]
        , test "an open drawer makes the shell content inert" <|
            \_ ->
                let
                    opened : ChromeState.Model
                    opened =
                        ChromeState.update ChromeState.MenuClicked ChromeState.init
                            |> Tuple.first
                in
                Expect.all
                    [ \_ ->
                        frameFor ChromeState.init
                            |> Query.find [ shellContentSelector ]
                            |> Query.hasNot [ inertSelector ]
                    , \_ ->
                        frameFor opened
                            |> Query.find [ shellContentSelector ]
                            |> Query.has [ inertSelector ]
                    , \_ ->
                        frameFor opened
                            |> Query.find [ drawerSelector ]
                            |> Query.hasNot [ inertSelector ]
                    ]
                    ()
        , fuzz2 SupportFuzz.device
            SupportFuzz.device
            "an open drawer survives layout changes only within the same nav mode"
          <|
            \previous next ->
                let
                    opened : ChromeState.Model
                    opened =
                        ChromeState.update ChromeState.MenuClicked ChromeState.init
                            |> Tuple.first

                    sameNavMode : Bool
                    sameNavMode =
                        (previous.class == Element.Phone) == (next.class == Element.Phone)
                in
                ChromeState.closeOnLayoutChange previous next opened
                    |> ChromeState.isDrawerOpen
                    |> Expect.equal sameNavMode
        , test "Escape removes an open drawer" <|
            \_ ->
                let
                    opened : ChromeState.Model
                    opened =
                        ChromeState.update ChromeState.MenuClicked ChromeState.init
                            |> Tuple.first

                    openedAfterEscape : ChromeState.Model
                    openedAfterEscape =
                        ChromeState.update ChromeState.EscapePressed opened |> Tuple.first

                    drawerVisible : ChromeState.Model -> Query.Single Route
                    drawerVisible model =
                        Element.el
                            (Chrome.drawerOverlay
                                (envFor { class = Element.Phone, orientation = Element.Portrait })
                                user
                                (DiaryDay Nothing Nothing)
                                False
                                (ChromeState.isDrawerOpen model)
                                (DiaryDay Nothing Nothing)
                                identity
                            )
                            Element.none
                            |> Element.layout []
                            |> Query.fromHtml
                in
                Expect.all
                    [ \_ ->
                        drawerVisible opened
                            |> Query.has [ Selector.text (I18n.en TidNavDiary) ]
                    , \_ ->
                        drawerVisible openedAfterEscape
                            |> Query.hasNot [ Selector.text (I18n.en TidNavDiary) ]
                    ]
                    ()
        , test "normal app chrome has no topbar theme, language, or profile controls" <|
            \_ ->
                let
                    topbar : Query.Single ()
                    topbar =
                        topbarFor user (DiaryDay Nothing Nothing)
                in
                Expect.all
                    [ \_ -> topbar |> Query.hasNot [ themeSwitchSelector ]
                    , \_ -> topbar |> Query.hasNot [ languageToggleSelector EN_US HI_IN ]
                    , \_ -> topbar |> Query.hasNot [ profileButtonSelector ]
                    ]
                    ()
        , test "signed-out login and setup offer theme and language controls but no profile" <|
            \_ ->
                Expect.all
                    [ \_ -> topbarFor anonymous AuthLogin |> Query.has [ themeSwitchSelector ]
                    , \_ -> topbarFor anonymous BootstrapSetup |> Query.has [ themeSwitchSelector ]
                    , \_ ->
                        topbarFor anonymous AuthLogin
                            |> Query.has [ languageToggleSelector EN_US HI_IN ]
                    , \_ ->
                        topbarFor anonymous BootstrapSetup
                            |> Query.has [ languageToggleSelector EN_US HI_IN ]
                    , \_ ->
                        topbarFor anonymous AuthLogin
                            |> Query.hasNot [ profileButtonSelector ]
                    ]
                    ()
        , test "signed-out language control switches to the other language" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        topbarMessages (envForLanguage EN_US)
                            anonymous
                            AuthLogin
                            |> Query.find [ languageToggleSelector EN_US HI_IN ]
                            |> Event.simulate Event.click
                            |> Event.expect (ChromeState.LanguageClicked HI_IN)
                    , \_ ->
                        topbarMessages (envForLanguage HI_IN)
                            anonymous
                            BootstrapSetup
                            |> Query.find [ languageToggleSelector HI_IN EN_US ]
                            |> Event.simulate Event.click
                            |> Event.expect (ChromeState.LanguageClicked EN_US)
                    ]
                    ()
        , test "the theme switch reflects the current mode and toggles" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        topbarMessages (envForMode Theme.Light) anonymous AuthLogin
                            |> Query.find [ themeSwitchSelector ]
                            |> Query.has [ ariaPressed False ]
                    , \_ ->
                        topbarMessages (envForMode Theme.Dark) anonymous AuthLogin
                            |> Query.find [ themeSwitchSelector ]
                            |> Query.has [ ariaPressed True ]
                    , \_ ->
                        topbarMessages (envForMode Theme.Light) anonymous AuthLogin
                            |> Query.find [ themeSwitchSelector ]
                            |> Event.simulate Event.click
                            |> Event.expect ChromeState.ThemeToggleClicked
                    ]
                    ()
        , test "admins keep the theme switch and profile control" <|
            \_ ->
                let
                    topbar : Query.Single ()
                    topbar =
                        topbarFor admin AdminDashboard
                in
                Expect.all
                    [ \_ -> topbar |> Query.has [ themeSwitchSelector ]
                    , \_ -> topbar |> Query.has [ profileButtonSelector ]
                    , \_ ->
                        topbar
                            |> Query.hasNot [ languageToggleSelector EN_US HI_IN ]
                    ]
                    ()
        , test "the admin profile menu exposes language choices and distinct actions" <|
            \_ ->
                let
                    english : Query.Single ChromeState.Msg
                    english =
                        profileMenuFor EN_US

                    hindi : Query.Single ChromeState.Msg
                    hindi =
                        profileMenuFor HI_IN
                in
                Expect.all
                    [ \_ ->
                        english
                            |> Query.has
                                [ Selector.text (I18n.en (TidCommonSignedInAs "admin")) ]
                    , \_ ->
                        english
                            |> Query.find [ buttonContaining "English" ]
                            |> Query.has [ ariaPressed True ]
                    , \_ ->
                        english
                            |> Query.find [ buttonContaining "हिन्दी" ]
                            |> Query.has [ ariaPressed False ]
                    , \_ ->
                        english
                            |> Query.find [ buttonContaining "हिन्दी" ]
                            |> Event.simulate Event.click
                            |> Event.expect (ChromeState.LanguageClicked HI_IN)
                    , \_ ->
                        hindi
                            |> Query.find [ buttonContaining "English" ]
                            |> Query.has [ ariaPressed False ]
                    , \_ ->
                        hindi
                            |> Query.find [ buttonContaining "English" ]
                            |> Event.simulate Event.click
                            |> Event.expect (ChromeState.LanguageClicked EN_US)
                    , \_ ->
                        english
                            |> Query.find [ buttonContaining (I18n.en TidNavLogout) ]
                            |> Event.simulate Event.click
                            |> Event.expect ChromeState.LogoutClicked
                    , \_ ->
                        english
                            |> Query.hasNot [ Selector.exactText (I18n.en TidNavApiKeys) ]
                    ]
                    ()
        ]


reservesOnPhone : Device -> Route -> Bool
reservesOnPhone device route =
    device.class == Element.Phone && isAppRoute route


expectBackTarget : Route -> Route -> Expect.Expectation
expectBackTarget target route =
    expectBackTargetOn phoneDevice target route


expectBackTargetOn : Device -> Route -> Route -> Expect.Expectation
expectBackTargetOn device target route =
    topbarRoutes { device = device, menuExpanded = False } user route
        |> Query.find [ backButtonSelector ]
        |> Event.simulate Event.click
        |> Event.expect target


expectMenuLeading : Device -> Route -> Expect.Expectation
expectMenuLeading device route =
    let
        topbar : Query.Single Route
        topbar =
            topbarRoutes { device = device, menuExpanded = False } user route
    in
    Expect.all
        [ \_ -> topbar |> Query.has [ menuTriggerSelector ]
        , \_ -> topbar |> Query.hasNot [ backButtonSelector ]
        ]
        ()


expectActiveTab : Route -> TranslationId -> Expect.Expectation
expectActiveTab route expected =
    let
        nav : Query.Single Route
        nav =
            bottomNavFor route
    in
    activeDestination nav expected


expectActiveDrawerItem : Route -> TranslationId -> Expect.Expectation
expectActiveDrawerItem route expected =
    let
        drawer : Query.Single Route
        drawer =
            drawerFor user route
    in
    activeDestination drawer expected


activeDestination : Query.Single Route -> TranslationId -> Expect.Expectation
activeDestination root expected =
    Expect.all
        ((\_ -> navButton expected root |> Query.has [ ariaCurrentPage ])
            :: List.map
                (\label _ ->
                    navButton label root |> Query.hasNot [ ariaCurrentPage ]
                )
                (List.filter (\label -> label /= expected) navLabels)
        )
        ()


expectNavTarget : Query.Single Route -> TranslationId -> Route -> Expect.Expectation
expectNavTarget nav label target =
    nav
        |> navButton label
        |> Event.simulate Event.click
        |> Event.expect target


navButton : TranslationId -> Query.Single msg -> Query.Single msg
navButton label root =
    Query.find
        [ Selector.attribute (Attr.attribute "role" "button")
        , Selector.containing [ Selector.text (I18n.t EN_US label) ]
        ]
        root


navLabels : List TranslationId
navLabels =
    [ TidNavDiary, TidNavSearch, TidNavLibrary, TidNavSettings ]


bottomNavFor : Route -> Query.Single Route
bottomNavFor route =
    Chrome.bottomNavBar (envFor phoneDevice) route identity
        |> Element.layout []
        |> Query.fromHtml


drawerFor : Session -> Route -> Query.Single Route
drawerFor session route =
    Element.el
        (Chrome.drawerOverlay
            (envFor phoneDevice)
            session
            route
            False
            True
            (DiaryDay Nothing Nothing)
            identity
        )
        Element.none
        |> Element.layout []
        |> Query.fromHtml


frameFor : ChromeState.Model -> Query.Single ChromeState.Msg
frameFor model =
    ChromeState.viewFrame
        (envFor tabletDevice)
        model
        user
        (DiaryDay Nothing Nothing)
        False
        False
        Nothing
        Element.none
        identity
        |> Element.layout []
        |> Query.fromHtml


topbarFor : Session -> Route -> Query.Single ()
topbarFor session route =
    topbarForWith { device = phoneDevice, menuExpanded = False } session route


topbarForWith :
    { device : Device, menuExpanded : Bool }
    -> Session
    -> Route
    -> Query.Single ()
topbarForWith options session route =
    Chrome.topBarView
        (envFor options.device)
        session
        route
        False
        options.menuExpanded
        ()
        ()
        ()
        (\_ -> ())
        (\_ -> ())
        { profileLabel = "U", profileMenu = Nothing }
        |> Element.layout []
        |> Query.fromHtml


topbarRoutes :
    { device : Device, menuExpanded : Bool }
    -> Session
    -> Route
    -> Query.Single Route
topbarRoutes options session route =
    Chrome.topBarView
        (envFor options.device)
        session
        route
        False
        options.menuExpanded
        (DiaryDay Nothing Nothing)
        (DiaryDay Nothing Nothing)
        (DiaryDay Nothing Nothing)
        (always (DiaryDay Nothing Nothing))
        identity
        { profileLabel = "U", profileMenu = Nothing }
        |> Element.layout []
        |> Query.fromHtml


topbarMessages : Env -> Session -> Route -> Query.Single ChromeState.Msg
topbarMessages currentEnv session route =
    Chrome.topBarView
        currentEnv
        session
        route
        False
        False
        ChromeState.MenuClicked
        ChromeState.ProfileClicked
        ChromeState.ThemeToggleClicked
        ChromeState.LanguageClicked
        ChromeState.NavigateClicked
        { profileLabel = "U", profileMenu = Nothing }
        |> Element.layout []
        |> Query.fromHtml


profileMenuFor : Language -> Query.Single ChromeState.Msg
profileMenuFor language =
    Chrome.profileMenu
        (envForLanguage language)
        admin
        ChromeState.LogoutClicked
        ChromeState.LanguageClicked
        |> Element.layout []
        |> Query.fromHtml


menuTrigger : Query.Single msg -> Query.Single msg
menuTrigger root =
    Query.find [ menuTriggerSelector ] root


buttonContaining : String -> Selector
buttonContaining label =
    Selector.all
        [ Selector.attribute (Attr.attribute "role" "button")
        , Selector.containing [ Selector.text label ]
        ]


phoneDevice : Device
phoneDevice =
    { class = Element.Phone, orientation = Element.Portrait }


tabletDevice : Device
tabletDevice =
    { class = Element.Tablet, orientation = Element.Portrait }


inertSelector : Selector
inertSelector =
    Selector.attribute (Attr.attribute "inert" "")


shellContentSelector : Selector
shellContentSelector =
    Selector.attribute (Attr.attribute "data-testid" "app-shell-content")


drawerSelector : Selector
drawerSelector =
    Selector.attribute (Attr.attribute "data-testid" "app-drawer")


backButtonSelector : Selector
backButtonSelector =
    Selector.all
        [ Selector.attribute (Attr.attribute "role" "button")
        , Selector.attribute (Attr.attribute "aria-label" (I18n.en TidNavBack))
        ]


menuTriggerSelector : Selector
menuTriggerSelector =
    Selector.all
        [ Selector.attribute (Attr.attribute "role" "button")
        , Selector.attribute (Attr.attribute "aria-label" (I18n.en TidNavMenu))
        ]


ariaCurrentPage : Selector
ariaCurrentPage =
    Selector.attribute (Attr.attribute "aria-current" "page")


ariaPressed : Bool -> Selector
ariaPressed active =
    Selector.attribute
        (Attr.attribute "aria-pressed"
            (if active then
                "true"

             else
                "false"
            )
        )


themeSwitchSelector : Selector
themeSwitchSelector =
    Selector.all
        [ Selector.attribute (Attr.attribute "role" "button")
        , Selector.attribute (Attr.attribute "aria-label" (I18n.en TidCommonUseDarkTheme))
        ]


languageToggleSelector : Language -> Language -> Selector
languageToggleSelector currentLanguage targetLanguage =
    Selector.all
        [ Selector.attribute (Attr.attribute "role" "button")
        , Selector.attribute
            (Attr.attribute "aria-label"
                (I18n.t currentLanguage TidSettingsLanguageTitle
                    ++ ": "
                    ++ I18n.languageName targetLanguage
                )
            )
        ]


profileButtonSelector : Selector
profileButtonSelector =
    Selector.all
        [ Selector.attribute (Attr.attribute "role" "button")
        , Selector.attribute (Attr.attribute "aria-label" (I18n.en TidCommonProfile))
        ]


date : LocalDate
date =
    Fixtures.date "2026-07-20"


month : String
month =
    "2026-07"


isAppRoute : Route -> Bool
isAppRoute route =
    route /= AuthLogin && route /= BootstrapSetup


envFor : Device -> Env
envFor device =
    { theme = Theme.forMode Theme.Light
    , device = device
    , viewport = RegularViewport
    , language = EN_US
    }


envForLanguage : Language -> Env
envForLanguage language =
    { envForPhone | language = language }


envForMode : Theme.Mode -> Env
envForMode mode =
    { envForPhone | theme = Theme.forMode mode }


envForPhone : Env
envForPhone =
    envFor phoneDevice


user : Session
user =
    Authenticated { id = "1", username = "user", role = Auth.User }


admin : Session
admin =
    Authenticated { id = "2", username = "admin", role = Auth.Admin }


anonymous : Session
anonymous =
    Unauthenticated
