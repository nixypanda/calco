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
                        expectDrawerNavTarget drawer TidNavLibrary Library
                    , \_ ->
                        expectDrawerNavTarget drawer TidNavSettings Settings
                    ]
                    ()
        , test "bottom nav selects the semantic destination for contextual routes" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        expectActiveTab
                            (FoodSearch (Just date) (Just MealSlot.Lunch))
                            TidNavSearch
                    , \_ ->
                        expectActiveTab (FoodSearch (Just date) Nothing) TidNavSearch
                    , \_ ->
                        expectActiveTab
                            (FoodShow "food-1" (Just date) (Just MealSlot.Lunch) Nothing)
                            TidNavSearch
                    , \_ ->
                        expectActiveTab
                            (AdHocLogCreate (Just date) (Just MealSlot.Lunch))
                            TidNavSearch
                    , \_ ->
                        expectActiveTab
                            (AiLogCreate (Just date) (Just MealSlot.Lunch))
                            TidNavSearch
                    ]
                    ()
        , test "bottom nav keeps nested routes on their destination" <|
            \_ ->
                Expect.all
                    [ \_ -> expectActiveTab (DiaryCalendar (Just month)) TidNavDiary
                    , \_ -> expectActiveTab (GoalSettings (Just date) (Just month)) TidNavDiary
                    , \_ -> expectActiveTab DiarySettings TidNavDiary
                    , \_ -> expectActiveTab (FoodLogEntry "log-1" (Just date) Nothing) TidNavDiary
                    , \_ -> expectActiveTab (CustomFoodShow "food-1") TidNavLibrary
                    , \_ -> expectActiveTab (MealShow "meal-1") TidNavLibrary
                    , \_ -> expectActiveTab SettingsApiKeys TidNavSettings
                    , \_ -> expectActiveTab SettingsApiKeyCreate TidNavSettings
                    ]
                    ()
        , test "the drawer marks the current semantic destination" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        expectActiveDrawerItem
                            (FoodSearch (Just date) (Just MealSlot.Lunch))
                            TidNavSearch
                    , \_ ->
                        expectActiveDrawerItem (CustomFoodShow "food-1") TidNavLibrary
                    , \_ -> expectActiveDrawerItem SettingsApiKeys TidNavSettings
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
        , test "top-level search exposes the drawer menu on larger screens" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        expectMenuLeading
                            { class = Element.Tablet, orientation = Element.Portrait }
                            (FoodSearch (Just date) Nothing)
                    , \_ ->
                        expectMenuLeading
                            { class = Element.Desktop, orientation = Element.Landscape }
                            (FoodSearch Nothing Nothing)
                    ]
                    ()
        , test "contextual search keeps Back to the dated diary" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        expectBackTargetOn
                            { class = Element.Phone, orientation = Element.Portrait }
                            (DiaryDay (Just date) Nothing)
                            (FoodSearch (Just date) (Just MealSlot.Lunch))
                    , \_ ->
                        expectBackTargetOn
                            { class = Element.Desktop, orientation = Element.Landscape }
                            (DiaryDay (Just date) Nothing)
                            (FoodSearch (Just date) (Just MealSlot.Lunch))
                    ]
                    ()
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
        , test "normal app chrome has no topbar theme switch or profile button" <|
            \_ ->
                let
                    topbar : Query.Single ()
                    topbar =
                        topbarFor user (DiaryDay Nothing Nothing)
                in
                Expect.all
                    [ \_ -> topbar |> Query.hasNot [ themeSwitchSelector ]
                    , \_ -> topbar |> Query.hasNot [ profileButtonSelector ]
                    ]
                    ()
        , test "signed-out auth keeps an accessible topbar theme switch" <|
            \_ ->
                let
                    topbar : Query.Single ()
                    topbar =
                        topbarFor anonymous AuthLogin
                in
                Expect.all
                    [ \_ -> topbar |> Query.has [ themeSwitchSelector ]
                    , \_ -> topbar |> Query.hasNot [ profileButtonSelector ]
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
                    ]
                    ()
        , test "the admin profile menu only offers account-level actions" <|
            \_ ->
                let
                    menu : Query.Single ()
                    menu =
                        Chrome.profileMenu
                            (envFor { class = Element.Phone, orientation = Element.Portrait })
                            admin
                            ()
                            (always ())
                            |> Element.layout []
                            |> Query.fromHtml
                in
                Expect.all
                    [ \_ ->
                        menu
                            |> Query.has
                                [ Selector.text (I18n.en (TidCommonSignedInAs "admin")) ]
                    , \_ -> menu |> Query.has [ Selector.text "English" ]
                    , \_ -> menu |> Query.has [ Selector.text "हिन्दी" ]
                    , \_ ->
                        menu
                            |> Query.has [ Selector.exactText (I18n.en TidNavLogout) ]
                    , \_ ->
                        menu
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


expectDrawerNavTarget : Query.Single Route -> TranslationId -> Route -> Expect.Expectation
expectDrawerNavTarget drawer label target =
    drawer
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
        identity
        { profileLabel = "U", profileMenu = Nothing }
        |> Element.layout []
        |> Query.fromHtml


menuTrigger : Query.Single msg -> Query.Single msg
menuTrigger root =
    Query.find [ menuTriggerSelector ] root


phoneDevice : Device
phoneDevice =
    { class = Element.Phone, orientation = Element.Portrait }


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


themeSwitchSelector : Selector
themeSwitchSelector =
    Selector.all
        [ Selector.attribute (Attr.attribute "role" "button")
        , Selector.attribute (Attr.attribute "aria-label" (I18n.en TidCommonUseDarkTheme))
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


user : Session
user =
    Authenticated { id = "1", username = "user", role = Auth.User }


admin : Session
admin =
    Authenticated { id = "2", username = "admin", role = Auth.Admin }


anonymous : Session
anonymous =
    Unauthenticated
