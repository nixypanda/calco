module Page.Settings.LandingTest exposing (tests)

{-| Settings landing route: the preference and account controls cross
`Page.update` into app effects, the language menu opens, closes, changes
language, exposes listbox ARIA state for pointer and keyboard users, and picks
above/below placement from the trigger's viewport geometry.
-}

import Data.Route exposing (Route(..))
import Element
import Expect
import Fuzz
import Html.Attributes as Attr
import I18n
import Json.Encode as Encode
import Page
import Page.Settings.Landing as SettingsLanding
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, fuzz2, fuzz3, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector exposing (Selector)
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language(..))
import Ui.Env exposing (Env, Viewport(..))
import Ui.Input as UiInput
import Ui.Theme as Theme


tests : Test
tests =
    describe "Page.Settings.Landing"
        [ test "preference and account controls reach the app layer" <|
            \_ ->
                let
                    afterTheme : Click
                    afterTheme =
                        pageClick Settings (themeToggle EN_US) (pageFor Settings)

                    afterLanguageOpen : Click
                    afterLanguageOpen =
                        pageClick Settings (languageTrigger EN_US) afterTheme.model

                    afterLanguage : Click
                    afterLanguage =
                        pageClick Settings
                            (languageOption (I18n.languageName HI_IN))
                            afterLanguageOpen.model

                    afterLogout : Click
                    afterLogout =
                        pageClick Settings
                            (buttonContaining (I18n.t EN_US TidNavLogout))
                            afterLanguage.model

                    afterApiKeys : Click
                    afterApiKeys =
                        pageClick Settings
                            (buttonContaining (I18n.t EN_US TidTitleApiKeys))
                            afterLogout.model

                    apiKeys : Page.Model
                    apiKeys =
                        apply SettingsApiKeys afterApiKeys.model
                in
                { theme = afterTheme.outMsg
                , language = afterLanguage.outMsg
                , logout = afterLogout.outMsg
                , apiKeys = afterApiKeys.outMsg
                , panes = Page.paneKeys apiKeys
                , failures =
                    [ afterTheme.failure
                    , afterLanguageOpen.failure
                    , afterLanguage.failure
                    , afterLogout.failure
                    , afterApiKeys.failure
                    ]
                        |> List.filterMap identity
                }
                    |> Expect.equal
                        { theme = Page.ToggleTheme
                        , language = Page.SetLanguage HI_IN
                        , logout = Page.Logout
                        , apiKeys = Page.Navigate SettingsApiKeys
                        , panes = [ "api-keys" ]
                        , failures = []
                        }
        , test "a user opens, closes, and reopens the menu before choosing Hindi then English" <|
            \_ ->
                let
                    opened : Click
                    opened =
                        pageClick Settings (languageTrigger EN_US) (pageFor Settings)

                    openedView : Query.Single Page.Msg
                    openedView =
                        pageView env Settings opened.model

                    closed : Click
                    closed =
                        pageClick Settings (languageTrigger EN_US) opened.model

                    closedView : Query.Single Page.Msg
                    closedView =
                        pageView env Settings closed.model

                    reopened : Click
                    reopened =
                        pageClick Settings (languageTrigger EN_US) closed.model

                    reopenedView : Query.Single Page.Msg
                    reopenedView =
                        pageView env Settings reopened.model

                    chosenHindi : Click
                    chosenHindi =
                        pageClick Settings
                            (languageOption (I18n.languageName HI_IN))
                            reopened.model

                    hindiView : Query.Single Page.Msg
                    hindiView =
                        pageView hindiEnv Settings chosenHindi.model

                    reopenedForEnglish : Click
                    reopenedForEnglish =
                        pageClickWith hindiEnv
                            Settings
                            (languageTrigger HI_IN)
                            chosenHindi.model

                    chosenEnglish : Click
                    chosenEnglish =
                        pageClickWith hindiEnv
                            Settings
                            (languageOption (I18n.languageName EN_US))
                            reopenedForEnglish.model

                    englishView : Query.Single Page.Msg
                    englishView =
                        pageView env Settings chosenEnglish.model
                in
                Expect.all
                    [ \_ -> opened.failure |> Expect.equal Nothing
                    , \_ -> opened.outMsg |> Expect.equal Page.NoOutMsg
                    , \_ ->
                        openedView
                            |> Query.find [ languageTrigger EN_US ]
                            |> Query.has [ expanded True ]
                    , \_ ->
                        openedView
                            |> Query.find [ languageOption (I18n.languageName EN_US) ]
                            |> Query.has [ selectedChoice True ]
                    , \_ ->
                        openedView
                            |> Query.find [ languageOption (I18n.languageName HI_IN) ]
                            |> Query.has [ selectedChoice False ]
                    , \_ ->
                        closed
                            |> .failure
                            |> Expect.equal Nothing
                    , \_ ->
                        closedView
                            |> Query.find [ languageTrigger EN_US ]
                            |> Query.has [ expanded False ]
                    , \_ ->
                        closedView
                            |> Query.hasNot [ languageOption (I18n.languageName HI_IN) ]
                    , \_ ->
                        reopenedView
                            |> Query.find [ languageTrigger EN_US ]
                            |> Query.has [ expanded True ]
                    , \_ -> chosenHindi.failure |> Expect.equal Nothing
                    , \_ -> chosenHindi.outMsg |> Expect.equal (Page.SetLanguage HI_IN)
                    , \_ ->
                        hindiView
                            |> Query.find [ languageTrigger HI_IN ]
                            |> Query.has
                                [ expanded False
                                , Selector.text (I18n.languageName HI_IN)
                                ]
                    , \_ ->
                        hindiView
                            |> Query.hasNot [ languageOption (I18n.languageName EN_US) ]
                    , \_ ->
                        reopenedForEnglish
                            |> .failure
                            |> Expect.equal Nothing
                    , \_ ->
                        chosenEnglish
                            |> .failure
                            |> Expect.equal Nothing
                    , \_ -> chosenEnglish.outMsg |> Expect.equal (Page.SetLanguage EN_US)
                    , \_ ->
                        englishView
                            |> Query.find [ languageTrigger EN_US ]
                            |> Query.has
                                [ expanded False
                                , Selector.text (I18n.languageName EN_US)
                                ]
                    ]
                    ()
        , test "keyboard and outside dismissal keep the menu accessible" <|
            \_ ->
                let
                    opened : Click
                    opened =
                        pageClick Settings (languageTrigger EN_US) (pageFor Settings)

                    moved : Click
                    moved =
                        pageKeyDown "ArrowDown"
                            (languageTrigger EN_US)
                            opened.model

                    movedView : Query.Single Page.Msg
                    movedView =
                        pageView env Settings moved.model

                    escaped : Click
                    escaped =
                        pageKeyDown "Escape"
                            (languageTrigger EN_US)
                            moved.model

                    escapedView : Query.Single Page.Msg
                    escapedView =
                        pageView env Settings escaped.model

                    reopened : Click
                    reopened =
                        pageClick Settings (languageTrigger EN_US) escaped.model

                    dismissed : Click
                    dismissed =
                        pageClick Settings languageBackdrop reopened.model

                    dismissedView : Query.Single Page.Msg
                    dismissedView =
                        pageView env Settings dismissed.model

                    reopenedForKeyboard : Click
                    reopenedForKeyboard =
                        pageClick Settings (languageTrigger EN_US) dismissed.model

                    movedAgain : Click
                    movedAgain =
                        pageKeyDown "ArrowDown"
                            (languageTrigger EN_US)
                            reopenedForKeyboard.model

                    chosen : Click
                    chosen =
                        pageKeyDown "Enter"
                            (languageTrigger EN_US)
                            movedAgain.model

                    chosenView : Query.Single Page.Msg
                    chosenView =
                        pageView hindiEnv Settings chosen.model
                in
                Expect.all
                    [ \_ -> moved.failure |> Expect.equal Nothing
                    , \_ -> moved.outMsg |> Expect.equal Page.NoOutMsg
                    , \_ ->
                        movedView
                            |> Query.find [ languageTrigger EN_US ]
                            |> Query.has [ expanded True ]
                    , \_ ->
                        movedView
                            |> Query.find [ languageTrigger EN_US ]
                            |> Query.has
                                [ activeDescendant
                                    (UiInput.selectOptionId "settings-language" 1)
                                ]
                    , \_ ->
                        movedView
                            |> Query.find
                                [ Selector.id
                                    (UiInput.selectOptionId "settings-language" 1)
                                ]
                            |> Query.has [ Selector.text (I18n.languageName HI_IN) ]
                    , \_ ->
                        movedView
                            |> Query.find
                                [ Selector.id
                                    (UiInput.selectOptionId "settings-language" 1)
                                ]
                            |> Query.has [ selectedChoice False ]
                    , \_ ->
                        movedView
                            |> Query.find [ languageOption (I18n.languageName EN_US) ]
                            |> Query.has [ selectedChoice True ]
                    , \_ -> escaped.failure |> Expect.equal Nothing
                    , \_ -> escaped.outMsg |> Expect.equal Page.NoOutMsg
                    , \_ ->
                        escapedView
                            |> Query.find [ languageTrigger EN_US ]
                            |> Query.has [ expanded False ]
                    , \_ ->
                        escapedView
                            |> Query.hasNot [ languageOption (I18n.languageName EN_US) ]
                    , \_ -> dismissed.failure |> Expect.equal Nothing
                    , \_ -> dismissed.outMsg |> Expect.equal Page.NoOutMsg
                    , \_ ->
                        dismissedView
                            |> Query.find [ languageTrigger EN_US ]
                            |> Query.has [ expanded False ]
                    , \_ -> chosen.failure |> Expect.equal Nothing
                    , \_ -> chosen.outMsg |> Expect.equal (Page.SetLanguage HI_IN)
                    , \_ ->
                        chosenView
                            |> Query.find [ languageTrigger HI_IN ]
                            |> Query.has [ expanded False ]
                    ]
                    ()
        , test "preferences reflect the active theme and language with one visible title" <|
            \_ ->
                let
                    lightEnglish : Query.Single Page.Msg
                    lightEnglish =
                        pageView env Settings (pageFor Settings)

                    darkEnglish : Query.Single Page.Msg
                    darkEnglish =
                        pageView
                            { env | theme = Theme.forMode Theme.Dark }
                            Settings
                            (pageFor Settings)

                    hindi : Query.Single Page.Msg
                    hindi =
                        pageView hindiEnv Settings (pageFor Settings)

                    desktop : Query.Single Page.Msg
                    desktop =
                        pageView desktopEnv Settings (pageFor Settings)
                in
                Expect.all
                    [ \_ ->
                        lightEnglish
                            |> Query.find [ themeToggle EN_US ]
                            |> Query.has [ pressedChoice False ]
                    , \_ ->
                        darkEnglish
                            |> Query.find [ themeToggle EN_US ]
                            |> Query.has [ pressedChoice True ]
                    , \_ ->
                        lightEnglish
                            |> Query.find [ languageTrigger EN_US ]
                            |> Query.has [ expanded False, Selector.text "English" ]
                    , \_ ->
                        hindi
                            |> Query.find [ languageTrigger HI_IN ]
                            |> Query.has
                                [ expanded False
                                , Selector.text (I18n.languageName HI_IN)
                                ]
                    , \_ ->
                        lightEnglish
                            |> Query.findAll
                                [ Selector.exactText
                                    (I18n.t EN_US TidSettingsLanguageTitle)
                                ]
                            |> Query.count (Expect.equal 1)
                    , \_ ->
                        desktop
                            |> Query.find [ languageTrigger EN_US ]
                            |> Query.has
                                [ expanded False
                                , Selector.text (I18n.languageName EN_US)
                                ]
                    ]
                    ()
        , fuzz2 (Fuzz.intRange 320 1400)
            (Fuzz.intRange 400 5000)
            "scrolling the document does not change which side the menu opens on"
          <|
            \viewportHeight scrollY ->
                let
                    triggerTopInViewport : Float
                    triggerTopInViewport =
                        120

                    placementFor : Float -> Float -> UiInput.SelectMenuPlacement
                    placementFor scrollOffset triggerTop =
                        SettingsLanding.menuPlacementFor
                            { viewportHeight = toFloat viewportHeight
                            , viewportScrollY = scrollOffset
                            , triggerTop = triggerTop
                            , triggerHeight = 44
                            }

                    scrollTop : Float
                    scrollTop =
                        toFloat scrollY
                in
                placementFor 0 triggerTopInViewport
                    |> Expect.equal
                        (placementFor scrollTop (triggerTopInViewport + scrollTop))
        , fuzz3
            (Fuzz.intRange 100 800)
            (Fuzz.intRange 0 155)
            (Fuzz.intRange 24 80)
            "a menu that cannot clear the bottom nav opens above when it fits"
          <|
            \spaceAbove spaceBelow triggerHeight ->
                SettingsLanding.menuPlacementFor
                    { viewportHeight =
                        toFloat (spaceAbove + spaceBelow + triggerHeight)
                    , viewportScrollY = 0
                    , triggerTop = toFloat spaceAbove
                    , triggerHeight = toFloat triggerHeight
                    }
                    |> Expect.equal UiInput.MenuAbove
        , test "a trigger just inside a scrolled phone viewport keeps the menu downward" <|
            \_ ->
                SettingsLanding.menuPlacementFor
                    { viewportHeight = 300
                    , viewportScrollY = 514
                    , triggerTop = 534
                    , triggerHeight = 44
                    }
                    |> Expect.equal UiInput.MenuBelow
        ]



-- PAGE EVENT


type alias Click =
    { model : Page.Model
    , outMsg : Page.OutMsg
    , failure : Maybe String
    }


pageClick : Route -> Selector -> Page.Model -> Click
pageClick =
    pageClickWith env


pageClickWith : Env -> Route -> Selector -> Page.Model -> Click
pageClickWith currentEnv route selector model =
    pageEventWith currentEnv route Event.click selector model


pageKeyDown : String -> Selector -> Page.Model -> Click
pageKeyDown key selector model =
    pageEventWith env
        Settings
        (Event.custom "keydown" (Encode.object [ ( "key", Encode.string key ) ]))
        selector
        model


pageEventWith : Env -> Route -> ( String, Encode.Value ) -> Selector -> Page.Model -> Click
pageEventWith currentEnv route event selector model =
    case
        pageView currentEnv route model
            |> Query.find [ selector ]
            |> Event.simulate event
            |> Event.toResult
    of
        Err reason ->
            { model = model, outMsg = Page.NoOutMsg, failure = Just reason }

        Ok msg ->
            case Page.update { route = route, today = Just Fixtures.today } msg model of
                Just ( next, _, outMsg ) ->
                    { model = next, outMsg = outMsg, failure = Nothing }

                Nothing ->
                    { model = model
                    , outMsg = Page.NoOutMsg
                    , failure = Just "Page.update ignored the settings control event"
                    }


pageView : Env -> Route -> Page.Model -> Query.Single Page.Msg
pageView currentEnv route model =
    Page.view currentEnv route model
        |> Element.layout []
        |> Query.fromHtml


pageFor : Route -> Page.Model
pageFor route =
    Page.init { route = route, today = Just Fixtures.today }
        |> Fixtures.tupleFirst


apply : Route -> Page.Model -> Page.Model
apply route model =
    Page.initPreserving { route = route, today = Just Fixtures.today } model
        |> Fixtures.tupleFirst



-- SELECTORS


themeToggle : Language -> Selector
themeToggle language =
    Selector.attribute
        (Attr.attribute "aria-label" (I18n.t language TidCommonUseDarkTheme))


languageTrigger : Language -> Selector
languageTrigger language =
    Selector.all
        [ Selector.attribute (Attr.attribute "role" "combobox")
        , Selector.attribute
            (Attr.attribute "aria-label"
                (I18n.t language TidSettingsLanguageTitle
                    ++ ": "
                    ++ I18n.languageName language
                )
            )
        ]


languageOption : String -> Selector
languageOption label =
    Selector.all
        [ Selector.attribute (Attr.attribute "role" "option")
        , Selector.containing [ Selector.text label ]
        ]


languageBackdrop : Selector
languageBackdrop =
    Selector.attribute (Attr.attribute "data-testid" "settings-language-backdrop")


buttonContaining : String -> Selector
buttonContaining label =
    Selector.all
        [ Selector.attribute (Attr.attribute "role" "button")
        , Selector.containing [ Selector.text label ]
        ]


expanded : Bool -> Selector
expanded isOpen =
    Selector.attribute
        (Attr.attribute "aria-expanded"
            (if isOpen then
                "true"

             else
                "false"
            )
        )


selectedChoice : Bool -> Selector
selectedChoice selected =
    Selector.attribute
        (Attr.attribute "aria-selected"
            (if selected then
                "true"

             else
                "false"
            )
        )


activeDescendant : String -> Selector
activeDescendant id =
    Selector.attribute (Attr.attribute "aria-activedescendant" id)


pressedChoice : Bool -> Selector
pressedChoice selected =
    Selector.attribute
        (Attr.attribute "aria-pressed"
            (if selected then
                "true"

             else
                "false"
            )
        )



-- ENV


env : Env
env =
    { theme = Theme.forMode Theme.Light
    , device = { class = Element.Phone, orientation = Element.Portrait }
    , viewport = RegularViewport
    , language = EN_US
    }


hindiEnv : Env
hindiEnv =
    { env | language = HI_IN }


desktopEnv : Env
desktopEnv =
    { env | device = { class = Element.Desktop, orientation = Element.Landscape } }
