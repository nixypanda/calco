module View.SearchTest exposing (tests)

import Data.Food exposing (SearchResult)
import Data.Nutrition as Nutrition
import Element exposing (DeviceClass(..), Orientation(..))
import Expect
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Translations.Util as Util
import Ui.Theme as Theme
import View.Search as SearchView


tests : Test
tests =
    describe "View.Search.resultRow category tags"
        [ test "tags are omitted on phones" <|
            \_ ->
                resultRowFor Phone
                    |> Query.findAll [ Selector.class "ui-chip" ]
                    |> Query.count (Expect.equal 0)
        , test "desktop caps the tags at two rows of two" <|
            \_ ->
                resultRowFor Desktop
                    |> Query.findAll [ Selector.class "ui-chip" ]
                    |> Query.count (Expect.equal 4)
        , test "desktop labels the hidden categories with one overflow tag" <|
            \_ ->
                resultRowFor Desktop
                    |> Query.has [ Selector.text "+2 more" ]
        , test "desktop drops the categories beyond the cap" <|
            \_ ->
                resultRowFor Desktop
                    |> Query.hasNot [ Selector.text "cat-four" ]
        ]


resultRowFor : DeviceClass -> Query.Single String
resultRowFor deviceClass =
    SearchView.resultRow Theme.light
        Util.EN_US
        { class = deviceClass, orientation = Portrait }
        { query = "ferr"
        , item = searchResult
        , onSelect = identity
        }
        |> Element.layout []
        |> Query.fromHtml


searchResult : SearchResult
searchResult =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , barcode = Nothing
    , name = "Cookie"
    , brand = Just "Test"
    , categories =
        [ "cat-one", "cat-two", "cat-three", "cat-four", "cat-five" ]
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    }
