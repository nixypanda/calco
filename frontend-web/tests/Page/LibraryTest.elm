module Page.LibraryTest exposing (tests)

{-| Library route story: the visible rows are the navigation controls, and a
click crosses `Page.update` into the list pane Main would reconcile.
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
    describe "Page.Library"
        [ test "food and meal rows open their list panes" <|
            \_ ->
                let
                    afterFoods : Click
                    afterFoods =
                        clickRow TidTitleMyFoods Library (pageFor Library)

                    foods : Page.Model
                    foods =
                        apply CustomFoodList afterFoods.model

                    afterMeals : Click
                    afterMeals =
                        clickRow TidTitleMyMeals Library (apply Library foods)

                    meals : Page.Model
                    meals =
                        apply MealList afterMeals.model
                in
                { foodsOut = afterFoods.outMsg
                , foodsPanes = Page.paneKeys foods
                , mealsOut = afterMeals.outMsg
                , mealsPanes = Page.paneKeys meals
                , failures =
                    [ afterFoods.failure, afterMeals.failure ] |> List.filterMap identity
                }
                    |> Expect.equal
                        { foodsOut = Page.Navigate CustomFoodList
                        , foodsPanes = [ "custom-food-list" ]
                        , mealsOut = Page.Navigate MealList
                        , mealsPanes = [ "meal-list" ]
                        , failures = []
                        }
        ]



-- PAGE CLICK


type alias Click =
    { model : Page.Model
    , outMsg : Page.OutMsg
    , failure : Maybe String
    }


clickRow : TranslationId -> Route -> Page.Model -> Click
clickRow label route model =
    pageClick route
        (Selector.all
            [ Selector.attribute (Attr.attribute "role" "button")
            , Selector.containing [ Selector.text (I18n.t EN_US label) ]
            ]
        )
        model


pageClick : Route -> Selector -> Page.Model -> Click
pageClick route selector model =
    case
        Page.view env route model
            |> Element.layout []
            |> Query.fromHtml
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
                    , failure = Just "Page.update ignored the library row click"
                    }


pageFor : Route -> Page.Model
pageFor route =
    Page.init { route = route, today = Just Fixtures.today }
        |> Fixtures.tupleFirst


apply : Route -> Page.Model -> Page.Model
apply route model =
    Page.initPreserving { route = route, today = Just Fixtures.today } model
        |> Fixtures.tupleFirst


env : Env
env =
    { theme = Theme.forMode Theme.Light
    , device = { class = Element.Phone, orientation = Element.Portrait }
    , viewport = RegularViewport
    , language = EN_US
    }
