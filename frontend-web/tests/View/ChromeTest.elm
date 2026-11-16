module View.ChromeTest exposing (tests)

{-| Shell chrome laws: bottom-nav visibility, chrome suppression, and the Back
destination carried by screen metadata. The Back case drives the rendered
control so the route context reaches the user action, not just a helper.
-}

import Data.Auth as Auth exposing (Session(..))
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
import Test.Html.Selector as Selector
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
                        drawerFor user
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
        , test "an admin drawer only offers the admin destination" <|
            \_ ->
                let
                    drawer : Query.Single Route
                    drawer =
                        drawerFor admin
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
        , test "profile menu leaves diary entry points on the diary" <|
            \_ ->
                let
                    menu : Query.Single ()
                    menu =
                        Chrome.profileMenu
                            (envFor { class = Element.Phone, orientation = Element.Portrait })
                            user
                            (always ())
                            ()
                            (always ())
                            |> Element.layout []
                            |> Query.fromHtml
                in
                Expect.all
                    [ \_ ->
                        menu
                            |> Query.hasNot
                                [ Selector.exactText (I18n.en TidDiaryOpenCalendar) ]
                    , \_ ->
                        menu
                            |> Query.hasNot
                                [ Selector.exactText (I18n.en TidDiaryEditGoals) ]
                    , \_ ->
                        menu
                            |> Query.hasNot
                                [ Selector.exactText (I18n.en TidDiaryManageMealSlots) ]
                    , \_ ->
                        menu
                            |> Query.has [ Selector.exactText (I18n.en TidNavApiKeys) ]
                    , \_ ->
                        menu
                            |> Query.has [ Selector.exactText (I18n.en TidNavLogout) ]
                    ]
                    ()
        ]


reservesOnPhone : Device -> Route -> Bool
reservesOnPhone device route =
    device.class == Element.Phone && isAppRoute route


expectBackTarget : Route -> Route -> Expect.Expectation
expectBackTarget target route =
    Chrome.topBarView
        { theme = Theme.forMode Theme.Light
        , device = { class = Element.Phone, orientation = Element.Portrait }
        , viewport = RegularViewport
        , language = EN_US
        }
        user
        route
        False
        (DiaryDay Nothing Nothing)
        (DiaryDay Nothing Nothing)
        (DiaryDay Nothing Nothing)
        identity
        { profileLabel = "U", profileMenu = Nothing }
        |> Element.layout []
        |> Query.fromHtml
        |> Query.find
            [ Selector.attribute (Attr.attribute "role" "button")
            , Selector.attribute (Attr.attribute "aria-label" (I18n.en TidNavBack))
            ]
        |> Event.simulate Event.click
        |> Event.expect target


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


drawerFor : Session -> Query.Single Route
drawerFor session =
    Element.el
        (Chrome.drawerOverlay
            (envFor { class = Element.Phone, orientation = Element.Portrait })
            session
            (DiaryDay Nothing Nothing)
            False
            True
            (DiaryDay Nothing Nothing)
            identity
        )
        Element.none
        |> Element.layout []
        |> Query.fromHtml


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
