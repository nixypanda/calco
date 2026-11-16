module Page.Settings.LandingTest exposing (tests)

{-| Settings landing route: the preference and account controls cross
`Page.update` into app effects, the language dropdown opens and closes around a
choice, and the rendered controls reflect the active theme and language.
-}

import Data.Route exposing (Route(..))
import Element
import Expect
import Html.Attributes as Attr
import I18n
import Page
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector exposing (Selector)
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language(..))
import Ui.Env exposing (Env, Viewport(..))
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
                            (languageOption "हिन्दी")
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
        , test "a user opens the language dropdown, chooses Hindi, and sees it selected" <|
            \_ ->
                let
                    opened : Click
                    opened =
                        pageClick Settings (languageTrigger EN_US) (pageFor Settings)

                    openedView : Query.Single Page.Msg
                    openedView =
                        pageView env Settings opened.model

                    chosen : Click
                    chosen =
                        pageClick Settings
                            (languageOption "हिन्दी")
                            opened.model

                    chosenView : Query.Single Page.Msg
                    chosenView =
                        pageView { env | language = HI_IN } Settings chosen.model
                in
                Expect.all
                    [ \_ -> opened.failure |> Expect.equal Nothing
                    , \_ -> opened.outMsg |> Expect.equal Page.NoOutMsg
                    , \_ ->
                        openedView
                            |> Query.find [ languageTrigger EN_US ]
                            |> Query.has [ expanded True ]
                    , \_ -> openedView |> Query.has [ languageOption "हिन्दी" ]
                    , \_ -> chosen.failure |> Expect.equal Nothing
                    , \_ -> chosen.outMsg |> Expect.equal (Page.SetLanguage HI_IN)
                    , \_ ->
                        chosenView
                            |> Query.find [ languageTrigger HI_IN ]
                            |> Query.has [ expanded False, Selector.text "हिन्दी" ]
                    , \_ -> chosenView |> Query.hasNot [ languageOption "English" ]
                    ]
                    ()
        , test "preferences reflect the active theme and language" <|
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
                        pageView { env | language = HI_IN } Settings (pageFor Settings)
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
                            |> Query.has [ expanded False, Selector.text "हिन्दी" ]
                    , \_ ->
                        lightEnglish
                            |> Query.findAll
                                [ Selector.exactText
                                    (I18n.t EN_US TidSettingsLanguageTitle)
                                ]
                            |> Query.count (Expect.equal 1)
                    ]
                    ()
        ]



-- PAGE CLICK


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
    case
        pageView currentEnv route model
            |> Query.find [ selector ]
            |> Event.simulate Event.click
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
                    , failure = Just "Page.update ignored the settings control click"
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


themeToggle : Language -> Selector
themeToggle language =
    Selector.attribute
        (Attr.attribute "aria-label" (I18n.t language TidCommonUseDarkTheme))


languageTrigger : Language -> Selector
languageTrigger language =
    Selector.all
        [ Selector.attribute (Attr.attribute "role" "button")
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
    buttonContaining label


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


env : Env
env =
    { theme = Theme.forMode Theme.Light
    , device = { class = Element.Phone, orientation = Element.Portrait }
    , viewport = RegularViewport
    , language = EN_US
    }
