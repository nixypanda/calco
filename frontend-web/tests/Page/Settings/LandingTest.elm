module Page.Settings.LandingTest exposing (tests)

{-| Settings landing behavior: API keys stay reachable, theme and language
preferences live here, and the account action can sign the user out.
-}

import Data.Route exposing (Route(..))
import Element
import Expect
import Html.Attributes as Attr
import I18n
import Page.Settings.Landing as Landing
import Support.Story as Story
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
        [ test "shows access, preferences, and account controls" <|
            \_ ->
                let
                    html : Query.Single Landing.Msg
                    html =
                        pageView env
                in
                Expect.all
                    [ \_ -> html |> Query.has [ Selector.text (I18n.t EN_US TidTitleApiKeys) ]
                    , \_ ->
                        html
                            |> Query.has
                                [ Selector.text (I18n.t EN_US TidSettingsPreferencesTitle) ]
                    , \_ ->
                        html
                            |> Query.has [ Selector.text (I18n.t EN_US TidSettingsThemeTitle) ]
                    , \_ -> html |> Query.has [ Selector.text "English" ]
                    , \_ -> html |> Query.has [ Selector.text "हिन्दी" ]
                    , \_ ->
                        html
                            |> Query.has
                                [ Selector.text (I18n.t EN_US TidSettingsAccountTitle) ]
                    , \_ ->
                        html
                            |> Query.has [ Selector.text (I18n.t EN_US TidNavLogout) ]
                    ]
                    ()
        , test "the dark theme switch reflects the active theme" <|
            \_ ->
                let
                    html : Query.Single Landing.Msg
                    html =
                        pageView { env | theme = Theme.forMode Theme.Dark }
                in
                html
                    |> Query.find [ themeToggleButton ]
                    |> Query.has [ Selector.attribute (Attr.attribute "aria-pressed" "true") ]
        , test "the selected language is exposed as a pressed choice" <|
            \_ ->
                let
                    html : Query.Single Landing.Msg
                    html =
                        pageView env
                in
                Expect.all
                    [ \_ ->
                        html
                            |> Query.find [ buttonContaining "English" ]
                            |> Query.has [ pressedChoice True ]
                    , \_ ->
                        html
                            |> Query.find [ buttonContaining "हिन्दी" ]
                            |> Query.has [ pressedChoice False ]
                    ]
                    ()
        , test "the API keys row chevron sits inside its press target" <|
            \_ ->
                pageView env
                    |> Query.find [ buttonContaining (I18n.t EN_US TidTitleApiKeys) ]
                    |> Query.has [ Selector.tag "svg" ]
        , test "the API keys entry navigates to API key management" <|
            \_ ->
                Story.start ( Landing.init, Landing.NoOp )
                    |> step Landing.ApiKeysClicked
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (Landing.Navigate SettingsApiKeys)
                        )
        , test "preferences and account controls reach the app layer" <|
            \_ ->
                let
                    html : Query.Single Landing.Msg
                    html =
                        pageView env
                in
                Expect.all
                    [ \_ ->
                        outMsgAfterClick html themeToggleButton
                            |> Expect.equal Landing.ToggleTheme
                    , \_ ->
                        outMsgAfterClick html (buttonContaining "हिन्दी")
                            |> Expect.equal (Landing.SetLanguage HI_IN)
                    , \_ ->
                        outMsgAfterClick html
                            (buttonContaining (I18n.t EN_US TidNavLogout))
                            |> Expect.equal Landing.Logout
                    ]
                    ()
        ]


pageView : Env -> Query.Single Landing.Msg
pageView currentEnv =
    Landing.view currentEnv Landing.init
        |> Element.layout []
        |> Query.fromHtml


themeToggleButton : Selector
themeToggleButton =
    Selector.attribute (Attr.attribute "aria-label" (I18n.t EN_US TidCommonUseDarkTheme))


buttonContaining : String -> Selector
buttonContaining label =
    Selector.all
        [ Selector.attribute (Attr.attribute "role" "button")
        , Selector.containing [ Selector.text label ]
        ]


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


outMsgAfterClick : Query.Single Landing.Msg -> Selector -> Landing.OutMsg
outMsgAfterClick html selector =
    case html |> Query.find [ selector ] |> Event.simulate Event.click |> Event.toResult of
        Ok msg ->
            Landing.update msg Landing.init
                |> (\( _, _, outMsg ) -> outMsg)

        Err _ ->
            Landing.NoOp



-- STORY PIPELINE


type alias Journey =
    Story.Journey Landing.Model Landing.OutMsg


step : Landing.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd Landing.update)


finish :
    (( Landing.Model, Landing.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


env : Env
env =
    { theme = Theme.forMode Theme.Light
    , device = { class = Element.Phone, orientation = Element.Portrait }
    , viewport = RegularViewport
    , language = EN_US
    }
