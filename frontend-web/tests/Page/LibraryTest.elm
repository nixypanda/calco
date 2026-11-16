module Page.LibraryTest exposing (tests)

{-| Library landing behavior: both saved-item destinations are visible and
open their existing list routes.
-}

import Data.Route exposing (Route(..))
import Element
import Expect
import Html.Attributes as Attr
import I18n
import Page.Library as Library
import Support.Story as Story
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector exposing (Selector)
import Translations.Ids exposing (TranslationId(..))
import Translations.Util exposing (Language(..))
import Ui.Env exposing (Env, Viewport(..))
import Ui.Theme as Theme


tests : Test
tests =
    describe "Page.Library"
        [ test "shows the saved foods and meals destinations" <|
            \_ ->
                let
                    html : Query.Single Library.Msg
                    html =
                        Library.view env Library.init
                            |> Element.layout []
                            |> Query.fromHtml
                in
                Expect.all
                    [ \_ -> html |> Query.has [ Selector.text (I18n.t EN_US TidTitleMyFoods) ]
                    , \_ -> html |> Query.has [ Selector.text (I18n.t EN_US TidTitleMyMeals) ]
                    ]
                    ()
        , test "each destination keeps its chevron inside the press target" <|
            \_ ->
                let
                    html : Query.Single Library.Msg
                    html =
                        Library.view env Library.init
                            |> Element.layout []
                            |> Query.fromHtml
                in
                Expect.all
                    [ \_ ->
                        html
                            |> Query.find [ rowContaining (I18n.t EN_US TidTitleMyFoods) ]
                            |> Query.has [ Selector.tag "svg" ]
                    , \_ ->
                        html
                            |> Query.find [ rowContaining (I18n.t EN_US TidTitleMyMeals) ]
                            |> Query.has [ Selector.tag "svg" ]
                    ]
                    ()
        , test "food and meal entries navigate to their lists" <|
            \_ ->
                Expect.all
                    [ \_ ->
                        Story.start ( Library.init, Library.NoOp )
                            |> step Library.MyFoodsClicked
                            |> finish
                                (\( _, outMsg ) ->
                                    outMsg |> Expect.equal (Library.Navigate CustomFoodList)
                                )
                    , \_ ->
                        Story.start ( Library.init, Library.NoOp )
                            |> step Library.MyMealsClicked
                            |> finish
                                (\( _, outMsg ) ->
                                    outMsg |> Expect.equal (Library.Navigate MealList)
                                )
                    ]
                    ()
        ]



-- STORY PIPELINE


type alias Journey =
    Story.Journey Library.Model Library.OutMsg


step : Library.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd Library.update)


finish :
    (( Library.Model, Library.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


rowContaining : String -> Selector
rowContaining label =
    Selector.all
        [ Selector.attribute (Attr.attribute "role" "button")
        , Selector.containing [ Selector.text label ]
        ]


env : Env
env =
    { theme = Theme.forMode Theme.Light
    , device = { class = Element.Phone, orientation = Element.Portrait }
    , viewport = RegularViewport
    , language = EN_US
    }
