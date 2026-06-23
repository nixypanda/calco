module Page.Food.SearchTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (SearchResult)
import Api.Logs as Logs
import Data.FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Data.Search as Search
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Loadable exposing (Loadable(..))
import Page.Food.Search as FoodSearch
import Test exposing (Test, describe, test)
import Time


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
        , test "blank category query does not request suggestions" <|
            \_ ->
                FoodSearch.update (FoodSearch.QueryChanged "   ") emptyModel
                    |> third
                    |> Expect.equal FoodSearch.NoOp
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
        , test "stale category suggestions are ignored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.CategorySuggestionsCompleted 1
                        (Ok { items = [ { value = "food", count = 4 } ] })
                    )
                    { emptyModel
                        | search = Search.withCategoryToken 2 emptyModel.search
                    }
                    |> first
                    |> .search
                    |> .categorySuggestions
                    |> Expect.equal []
        , test "category suggestion failure clears suggestions" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.CategorySuggestionsCompleted 1 (Err Client.NetworkError))
                    { emptyModel
                        | search =
                            { query = ""
                            , searchToken = 0
                            , categoryToken = 1
                            , categorySuggestions = [ { value = "old", count = 1 } ]
                            }
                    }
                    |> first
                    |> .search
                    |> .categorySuggestions
                    |> Expect.equal []
        , test "category suggestion unauthorized expires session" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.CategorySuggestionsCompleted 1
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    { emptyModel
                        | search = Search.withCategoryToken 1 emptyModel.search
                    }
                    |> third
                    |> Expect.equal FoodSearch.SessionExpired
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
        , test "completion click applies selected suggestion" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.CompletionClicked
                        (Search.CategoryCompletion "fruit" 1)
                    )
                    { emptyModel | search = Search.withQuery "c" emptyModel.search }
                    |> first
                    |> .search
                    |> .query
                    |> Expect.equal "fruit"
        , test "complete first suggestion with no suggestion is no-op" <|
            \_ ->
                FoodSearch.update
                    FoodSearch.CompleteFirstSuggestion
                    { emptyModel | search = Search.withQuery "apple" emptyModel.search }
                    |> first
                    |> .search
                    |> .query
                    |> Expect.equal "apple"
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
        , test "debounce for stale token is ignored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.DebounceElapsed 1 "apple")
                    { emptyModel | search = Search.withSearchToken 2 emptyModel.search }
                    |> third
                    |> Expect.equal FoodSearch.NoOp
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
        , test "search unauthorized expires session" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted 2
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    { emptyModel | search = Search.withSearchToken 2 emptyModel.search }
                    |> third
                    |> Expect.equal FoodSearch.SessionExpired
        , test "recent items load success stores items" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentItemsLoaded (Ok { items = [ recentProduct ] }))
                    emptyModel
                    |> first
                    |> .recentItems
                    |> Expect.equal (Success [ recentProduct ])
        , test "recent items failure stores error" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentItemsLoaded (Err Client.NetworkError))
                    emptyModel
                    |> first
                    |> .recentItems
                    |> Expect.equal (Failure Client.NetworkError)
        , test "recent items unauthorized expires session" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentItemsLoaded
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    emptyModel
                    |> third
                    |> Expect.equal FoodSearch.SessionExpired
        , test "recent product click navigates to food detail with context" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentItemClicked recentProduct)
                    { emptyModel | date = Just "2026-05-29", mealSlot = Just Dinner }
                    |> third
                    |> Expect.equal
                        (FoodSearch.Navigate
                            (FoodShow "food-1" (Just "2026-05-29") (Just Dinner))
                        )
        , test "recent meal click navigates to meal detail" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentItemClicked recentMeal)
                    emptyModel
                    |> third
                    |> Expect.equal (FoodSearch.Navigate (MealShow "meal-1"))
        , test "recent quick add requests local context" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct)
                    emptyModel
                    |> third
                    |> Expect.equal FoodSearch.RequestLocalContext
        , test "second recent quick add is ignored while context is pending" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct)
                    emptyModel
                    |> first
                    |> FoodSearch.update (FoodSearch.RecentQuickAddClicked recentMeal)
                    |> third
                    |> Expect.equal FoodSearch.NoOp
        , test "local context received creates log request for pending quick add" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct)
                    { emptyModel | date = Just "2026-05-29", mealSlot = Just Lunch }
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.LocalContextReceived
                            { date = "2026-06-01", timezone = "Asia/Kolkata" }
                        )
                    |> third
                    |> Expect.equal
                        (FoodSearch.RequestCreateLog
                            { logDate = date "2026-05-29"
                            , deviceTimezone = Just "Asia/Kolkata"
                            , mealSlot = Just "lunch"
                            , item = { itemType = ItemRef.Product, id = "food-1" }
                            , quantity = { amount = "2", unit = "serving" }
                            , notes = Nothing
                            }
                        )
        , test "local context falls back to context date" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct)
                    emptyModel
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.LocalContextReceived
                            { date = "2026-06-01", timezone = "Asia/Kolkata" }
                        )
                    |> third
                    |> Expect.equal
                        (FoodSearch.RequestCreateLog
                            { logDate = date "2026-06-01"
                            , deviceTimezone = Just "Asia/Kolkata"
                            , mealSlot = Nothing
                            , item = { itemType = ItemRef.Product, id = "food-1" }
                            , quantity = { amount = "2", unit = "serving" }
                            , notes = Nothing
                            }
                        )
        , test "invalid selected quick add date does not create request" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct)
                    { emptyModel | date = Just "bad-date" }
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.LocalContextReceived
                            { date = "2026-06-01", timezone = "Asia/Kolkata" }
                        )
                    |> third
                    |> Expect.equal FoodSearch.NoOp
        , test "local context with no pending quick add is ignored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.LocalContextReceived
                        { date = "2026-06-01", timezone = "Asia/Kolkata" }
                    )
                    emptyModel
                    |> third
                    |> Expect.equal FoodSearch.NoOp
        , test "quick add success marks item as recently added" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct)
                    emptyModel
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.LocalContextReceived
                            { date = "2026-06-01", timezone = "Asia/Kolkata" }
                        )
                    |> first
                    |> FoodSearch.update (FoodSearch.QuickAddCompleted (Ok productLog))
                    |> first
                    |> (\model -> ( model.addedToken, model.addedItems ))
                    |> Expect.equal
                        ( 1, [ { key = "product:food-1", token = 1 } ] )
        , test "quick add success replaces previous added token for same item" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct)
                    { emptyModel
                        | addedToken = 1
                        , addedItems = [ { key = "product:food-1", token = 1 } ]
                    }
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.LocalContextReceived
                            { date = "2026-06-01", timezone = "Asia/Kolkata" }
                        )
                    |> first
                    |> FoodSearch.update (FoodSearch.QuickAddCompleted (Ok productLog))
                    |> first
                    |> .addedItems
                    |> Expect.equal [ { key = "product:food-1", token = 2 } ]
        , test "quick add success with no pending item does not mark added" <|
            \_ ->
                FoodSearch.update (FoodSearch.QuickAddCompleted (Ok productLog)) emptyModel
                    |> first
                    |> .addedItems
                    |> Expect.equal []
        , test "quick add failure keeps no added item" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct)
                    emptyModel
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.LocalContextReceived
                            { date = "2026-06-01", timezone = "Asia/Kolkata" }
                        )
                    |> first
                    |> FoodSearch.update (FoodSearch.QuickAddCompleted (Err Client.NetworkError))
                    |> first
                    |> .addedItems
                    |> Expect.equal []
        , test "quick add failure allows another quick add" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct)
                    emptyModel
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.LocalContextReceived
                            { date = "2026-06-01", timezone = "Asia/Kolkata" }
                        )
                    |> first
                    |> FoodSearch.update (FoodSearch.QuickAddCompleted (Err Client.NetworkError))
                    |> first
                    |> FoodSearch.update (FoodSearch.RecentQuickAddClicked recentMeal)
                    |> third
                    |> Expect.equal FoodSearch.RequestLocalContext
        , test "quick add unauthorized expires session" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct)
                    emptyModel
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.LocalContextReceived
                            { date = "2026-06-01", timezone = "Asia/Kolkata" }
                        )
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.QuickAddCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                    |> third
                    |> Expect.equal FoodSearch.SessionExpired
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


recentProduct : Logs.RecentItem
recentProduct =
    { item =
        { itemType = ItemRef.Product
        , id = "food-1"
        , name = "Apple"
        , brand = Just "Local"
        }
    , lastUsedDate = date "2026-05-28"
    , mealSlot = Just "lunch"
    , quantity = { amount = "2", unit = "serving" }
    , nutritionSummary = Nutrition.emptySummary
    }


recentMeal : Logs.RecentItem
recentMeal =
    { recentProduct
        | item =
            { itemType = ItemRef.Meal
            , id = "meal-1"
            , name = "Lunch meal"
            , brand = Nothing
            }
    }


productLog : FoodLog
productLog =
    { id = "log-1"
    , logDate = date "2026-06-01"
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = Just "lunch"
    , item = recentProduct.item
    , quantity = recentProduct.quantity
    , nutritionSummary = Nutrition.emptySummary
    , nutrients = []
    , notes = Nothing
    }


date : String -> LocalDate
date raw =
    case LocalDate.fromString raw of
        Just parsed ->
            parsed

        Nothing ->
            fallbackDate


fallbackDate : LocalDate
fallbackDate =
    LocalDate.fromPosix Time.utc (Time.millisToPosix 0)


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
