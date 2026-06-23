module Page.Food.SearchTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (SearchResult)
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Data.Search as Search
import Expect
import Lib.Loadable exposing (Loadable(..))
import Page.Food.Search as FoodSearch
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Food.Search"
        [ test "empty query clears results, loading, and error" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.QueryChanged "   ")
                    { loadedModel | results = Failure Client.NetworkError }
                    |> first
                    |> (\model -> ( model.search.query, model.results ))
                    |> Expect.equal ( "   ", NotAsked )
        , test "non-empty query increments search token" <|
            \_ ->
                FoodSearch.update (FoodSearch.QueryChanged "apple") emptyModel
                    |> first
                    |> .search
                    |> .searchToken
                    |> Expect.equal 1
        , test "tab completion expands include category operator" <|
            \_ ->
                FoodSearch.update
                    FoodSearch.CompleteFirstSuggestion
                    { emptyModel | search = Search.withQuery "c" emptyModel.search }
                    |> first
                    |> .search
                    |> .query
                    |> Expect.equal "category:"
        , test "tab completion preserves the gap before the current token" <|
            \_ ->
                FoodSearch.update
                    FoodSearch.CompleteFirstSuggestion
                    { emptyModel | search = Search.withQuery "apple c" emptyModel.search }
                    |> first
                    |> .search
                    |> .query
                    |> Expect.equal "apple category:"
        , test "tab completion preserves repeated gaps before the current token" <|
            \_ ->
                FoodSearch.update
                    FoodSearch.CompleteFirstSuggestion
                    { emptyModel | search = Search.withQuery "apple  c" emptyModel.search }
                    |> first
                    |> .search
                    |> .query
                    |> Expect.equal "apple  category:"
        , test "tab completion expands exclude category operator" <|
            \_ ->
                FoodSearch.update
                    FoodSearch.CompleteFirstSuggestion
                    { emptyModel | search = Search.withQuery "-c" emptyModel.search }
                    |> first
                    |> .search
                    |> .query
                    |> Expect.equal "-category:"
        , test "typing a category value requests suggestions" <|
            \_ ->
                FoodSearch.update (FoodSearch.QueryChanged "category:foo") emptyModel
                    |> third
                    |> Expect.equal
                        (FoodSearch.RequestCategorySuggestions 1
                            { query = "foo", limit = 8 }
                        )
        , test "matching category suggestions are stored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.CategorySuggestionsCompleted 1
                        (Ok
                            { items =
                                [ { value = "food and beverages", count = 4 } ]
                            }
                        )
                    )
                    { emptyModel
                        | search =
                            Search.withCategoryToken 1
                                emptyModel.search
                    }
                    |> first
                    |> .search
                    |> .categorySuggestions
                    |> Expect.equal [ { value = "food and beverages", count = 4 } ]
        , test "tab completion applies first category suggestion with quotes when needed" <|
            \_ ->
                FoodSearch.update
                    FoodSearch.CompleteFirstSuggestion
                    { emptyModel
                        | search =
                            { query = "category:foo"
                            , searchToken = 0
                            , categoryToken = 0
                            , categorySuggestions = [ { value = "food and beverages", count = 4 } ]
                            }
                    }
                    |> first
                    |> .search
                    |> .query
                    |> Expect.equal "category:\"food and beverages\""
        , test "search started sets loading" <|
            \_ ->
                FoodSearch.update (FoodSearch.QueryChanged "apple") emptyModel
                    |> first
                    |> .results
                    |> Expect.equal Loading
        , test "search started keeps recent items state available" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.QueryChanged "apple")
                    { emptyModel | recentItems = Success [] }
                    |> first
                    |> .recentItems
                    |> Expect.equal (Success [])
        , test "debounce for current token requests search" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.DebounceElapsed 2 "apple")
                    { emptyModel
                        | search =
                            Search.withSearchToken 2
                                emptyModel.search
                    }
                    |> third
                    |> Expect.equal (FoodSearch.RequestSearch 2 { query = "apple" })
        , test "matching search result stores items and clears loading" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted 2 (Ok { items = [ apple ] }))
                    { emptyModel
                        | search =
                            Search.withSearchToken 2
                                emptyModel.search
                        , results = Loading
                    }
                    |> first
                    |> .results
                    |> Expect.equal (Success [ apple ])
        , test "stale search result is ignored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted 1 (Ok { items = [ apple ] }))
                    { emptyModel
                        | search =
                            Search.withSearchToken 2
                                emptyModel.search
                        , results = Loading
                    }
                    |> first
                    |> .results
                    |> Expect.equal Loading
        , test "search failure stores error and clears results" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted 2 (Err Client.NetworkError))
                    { loadedModel
                        | search =
                            Search.withSearchToken 2
                                loadedModel.search
                        , results = Loading
                    }
                    |> first
                    |> .results
                    |> Expect.equal (Failure Client.NetworkError)
        , test "search failure from stale token is ignored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted 1 (Err Client.NetworkError))
                    { loadedModel
                        | search =
                            Search.withSearchToken 2
                                loadedModel.search
                    }
                    |> first
                    |> .results
                    |> Expect.equal (Success [ apple ])
        , test "select result navigates to food detail with meal slot query context" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.ResultClicked "food-1")
                    { emptyModel
                        | date = Just "2026-05-29"
                        , mealSlot = Just Lunch
                    }
                    |> third
                    |> Expect.equal
                        (FoodSearch.Navigate
                            (FoodShow "food-1" (Just "2026-05-29") (Just Lunch))
                        )
        , test "create custom food navigates to custom food create" <|
            \_ ->
                FoodSearch.update FoodSearch.CreateCustomFoodClicked emptyModel
                    |> third
                    |> Expect.equal (FoodSearch.Navigate CustomFoodCreate)
        , test "clear recent added removes matching added item" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.ClearRecentAdded "product:food-1" 1)
                    { emptyModel
                        | addedItems = [ { key = "product:food-1", token = 1 } ]
                    }
                    |> first
                    |> .addedItems
                    |> Expect.equal []
        , test "clear recent added ignores stale token" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.ClearRecentAdded "product:food-1" 1)
                    { emptyModel
                        | addedItems = [ { key = "product:food-1", token = 2 } ]
                    }
                    |> first
                    |> .addedItems
                    |> Expect.equal [ { key = "product:food-1", token = 2 } ]
        ]


emptyModel : FoodSearch.Model
emptyModel =
    FoodSearch.init Nothing Nothing


loadedModel : FoodSearch.Model
loadedModel =
    { emptyModel
        | results = Success [ apple ]
        , search = Search.withSearchToken 1 emptyModel.search
    }


apple : SearchResult
apple =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , barcode = Just "12345"
    , name = "Apple"
    , brand = Just "Local"
    , categories = [ "fruit" ]
    , servingSizeG = Just "100"
    , nutritionSummary = { per100g = Nutrition.emptySummary, perServing = Nothing }
    , energyKcalPer100g = Just "52"
    , energyKcalPerServing = Nothing
    }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
