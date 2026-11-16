module Page.Settings.LandingTest exposing (tests)

{-| Settings landing behavior: API keys are reachable from Settings, and the
future theme/language area is only a placeholder.
-}

import Data.Route exposing (Route(..))
import Element
import Expect
import I18n
import Page.Settings.Landing as Landing
import Support.Story as Story
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language(..))
import Ui.Env exposing (Env, Viewport(..))
import Ui.Theme as Theme


tests : Test
tests =
    describe "Page.Settings.Landing"
        [ test "shows API keys and the future preferences placeholder" <|
            \_ ->
                let
                    html : Query.Single Landing.Msg
                    html =
                        Landing.view env Landing.init
                            |> Element.layout []
                            |> Query.fromHtml
                in
                Expect.all
                    [ \_ -> html |> Query.has [ Selector.text (I18n.t EN_US TidTitleApiKeys) ]
                    , \_ ->
                        html
                            |> Query.has
                                [ Selector.text
                                    (I18n.t EN_US TidSettingsPreferencesComingSoon)
                                ]
                    ]
                    ()
        , test "the API keys entry navigates to API key management" <|
            \_ ->
                Story.start ( Landing.init, Landing.NoOp )
                    |> step Landing.ApiKeysClicked
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (Landing.Navigate SettingsApiKeys)
                        )
        ]



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
