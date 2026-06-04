module FoodSearchTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (SearchResult)
import Data.MealSlot exposing (MealSlot(..))
import Expect
import Loadable exposing (Loadable(..))
import Page.FoodSearch as FoodSearch
import Route exposing (Route(..))
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.FoodSearch"
        [ test "empty query clears results, loading, and error" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.QueryChanged "   ")
                    { loadedModel | results = Failure Client.NetworkError }
                    |> first
                    |> (\model -> ( model.query, model.results ))
                    |> Expect.equal ( "   ", NotAsked )
        , test "non-empty query increments search token" <|
            \_ ->
                FoodSearch.update (FoodSearch.QueryChanged "apple") emptyModel
                    |> first
                    |> .searchToken
                    |> Expect.equal 1
        , test "tab completion expands include category operator" <|
            \_ ->
                FoodSearch.update FoodSearch.CompleteFirstSuggestion { emptyModel | query = "c" }
                    |> first
                    |> .query
                    |> Expect.equal "category:"
        , test "tab completion preserves the gap before the current token" <|
            \_ ->
                FoodSearch.update
                    FoodSearch.CompleteFirstSuggestion
                    { emptyModel | query = "apple c" }
                    |> first
                    |> .query
                    |> Expect.equal "apple category:"
        , test "tab completion preserves repeated gaps before the current token" <|
            \_ ->
                FoodSearch.update
                    FoodSearch.CompleteFirstSuggestion
                    { emptyModel | query = "apple  c" }
                    |> first
                    |> .query
                    |> Expect.equal "apple  category:"
        , test "tab completion expands exclude category operator" <|
            \_ ->
                FoodSearch.update FoodSearch.CompleteFirstSuggestion { emptyModel | query = "-c" }
                    |> first
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
                    { emptyModel | categoryToken = 1 }
                    |> first
                    |> .categorySuggestions
                    |> Expect.equal [ { value = "food and beverages", count = 4 } ]
        , test "tab completion applies first category suggestion with quotes when needed" <|
            \_ ->
                FoodSearch.update
                    FoodSearch.CompleteFirstSuggestion
                    { emptyModel
                        | query = "category:foo"
                        , categorySuggestions = [ { value = "food and beverages", count = 4 } ]
                    }
                    |> first
                    |> .query
                    |> Expect.equal "category:\"food and beverages\""
        , test "search started sets loading" <|
            \_ ->
                FoodSearch.update (FoodSearch.QueryChanged "apple") emptyModel
                    |> first
                    |> .results
                    |> Expect.equal Loading
        , test "debounce for current token requests search" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.DebounceElapsed 2 "apple")
                    { emptyModel | searchToken = 2 }
                    |> third
                    |> Expect.equal (FoodSearch.RequestSearch 2 { query = "apple" })
        , test "matching search result stores items and clears loading" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted 2 (Ok { items = [ apple ] }))
                    { emptyModel | searchToken = 2, results = Loading }
                    |> first
                    |> .results
                    |> Expect.equal (Success [ apple ])
        , test "stale search result is ignored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted 1 (Ok { items = [ apple ] }))
                    { emptyModel | searchToken = 2, results = Loading }
                    |> first
                    |> .results
                    |> Expect.equal Loading
        , test "search failure stores error and clears results" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted 2 (Err Client.NetworkError))
                    { loadedModel | searchToken = 2, results = Loading }
                    |> first
                    |> .results
                    |> Expect.equal (Failure Client.NetworkError)
        , test "search failure from stale token is ignored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted 1 (Err Client.NetworkError))
                    { loadedModel | searchToken = 2 }
                    |> first
                    |> .results
                    |> Expect.equal (Success [ apple ])
        , test "select result navigates to food detail with meal slot query context" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.ResultClicked "food-1")
                    { emptyModel | mealSlot = Just Lunch }
                    |> third
                    |> Expect.equal (FoodSearch.Navigate (FoodDetail "food-1" (Just Lunch)))
        , test "create custom food navigates to custom food create" <|
            \_ ->
                FoodSearch.update FoodSearch.CreateCustomFoodClicked emptyModel
                    |> third
                    |> Expect.equal (FoodSearch.Navigate CustomFoodCreate)
        , test "numeric query marks barcode visibility for matching rows" <|
            \_ ->
                ( FoodSearch.isBarcodeVisible "12345" apple
                , FoodSearch.isBarcodeVisible "apple" apple
                , FoodSearch.isBarcodeVisible "12345" { apple | barcode = Nothing }
                )
                    |> Expect.equal ( True, False, False )
        ]


emptyModel : FoodSearch.Model
emptyModel =
    FoodSearch.init Nothing


loadedModel : FoodSearch.Model
loadedModel =
    { emptyModel | results = Success [ apple ], searchToken = 1 }


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
    , energyKcalPer100g = Just "52"
    , energyKcalPerServing = Nothing
    }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
