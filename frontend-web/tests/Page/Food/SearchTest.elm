module Page.Food.SearchTest exposing (tests)

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, SearchResult)
import Api.Logs as Logs
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Data.Search as Search
import Element exposing (DeviceClass(..), Orientation(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Loadable exposing (Loadable(..))
import Lib.Ticket as Ticket exposing (Ticket)
import Page.Food.Search as FoodSearch
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Time
import Ui.Theme as Theme


tests : Test
tests =
    describe "Page.Food.Search"
        [ test "manual ad-hoc navigation keeps date and meal slot" <|
            \_ ->
                FoodSearch.update FoodSearch.CreateAdHocLogClicked
                    (FoodSearch.init (Just "2026-06-01") (Just Lunch))
                    |> third
                    |> Expect.equal
                        (FoodSearch.Navigate
                            (AdHocLogCreate (Just "2026-06-01") (Just Lunch))
                        )
        , test "AI ad-hoc navigation keeps date and meal slot" <|
            \_ ->
                FoodSearch.update FoodSearch.CreateAiLogClicked
                    (FoodSearch.init (Just "2026-06-01") (Just Lunch))
                    |> third
                    |> Expect.equal
                        (FoodSearch.Navigate
                            (AiLogCreate (Just "2026-06-01") (Just Lunch))
                        )
        , test "ad-hoc actions show manual and AI choices" <|
            \_ ->
                FoodSearch.contentView
                    { model = FoodSearch.init Nothing Nothing
                    , device = { class = Phone, orientation = Portrait }
                    , theme = Theme.light
                    }
                    |> Element.layout []
                    |> Query.fromHtml
                    |> Query.has
                        [ Selector.text "Manually"
                        , Selector.text "With AI"
                        ]
        , test "empty query clears results, loading, and error" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.QueryChanged "   ")
                    { loadedModel | results = Failure Client.NetworkError }
                    |> first
                    |> (\model -> ( model.search.query, model.results ))
                    |> Expect.equal ( "   ", NotAsked )
        , test "retarget preserves the query while changing logging context" <|
            \_ ->
                FoodSearch.init (Just "2026-06-01") (Just Lunch)
                    |> (\model ->
                            { model
                                | search = Search.withQuery "apple" model.search
                            }
                       )
                    |> FoodSearch.retarget (Just "2026-06-01") (Just Dinner)
                    |> (\( model, changed ) ->
                            { query = model.search.query
                            , date = model.date
                            , mealSlot = model.mealSlot
                            , changed = changed
                            }
                       )
                    |> Expect.equal
                        { query = "apple"
                        , date = Just "2026-06-01"
                        , mealSlot = Just Dinner
                        , changed = True
                        }
        , test "retarget is inert when the logging context is unchanged" <|
            \_ ->
                FoodSearch.init (Just "2026-06-01") (Just Lunch)
                    |> FoodSearch.retarget (Just "2026-06-01") (Just Lunch)
                    |> Tuple.second
                    |> Expect.equal False
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
        , test "typing a category value does not request suggestions yet" <|
            \_ ->
                FoodSearch.update (FoodSearch.QueryChanged "category:foo") emptyModel
                    |> third
                    |> Expect.equal FoodSearch.NoOp
        , test "settled category debounce requests suggestions" <|
            \_ ->
                FoodSearch.update (FoodSearch.QueryChanged "category:foo") emptyModel
                    |> first
                    |> FoodSearch.update (FoodSearch.CategoryDebounceElapsed (ticket 1) "foo")
                    |> third
                    |> Expect.equal
                        (FoodSearch.RequestCategorySuggestions (ticket 1)
                            { query = "foo", limit = 8 }
                        )
        , test "a burst of keystrokes only requests suggestions for the settled query" <|
            \_ ->
                let
                    typed : FoodSearch.Model
                    typed =
                        List.foldl
                            (\query model ->
                                FoodSearch.update (FoodSearch.QueryChanged query) model
                                    |> first
                            )
                            emptyModel
                            [ "category:c", "category:ch", "category:cho" ]
                in
                ( FoodSearch.update (FoodSearch.CategoryDebounceElapsed (ticket 1) "c") typed
                    |> third
                , FoodSearch.update (FoodSearch.CategoryDebounceElapsed (ticket 2) "ch") typed
                    |> third
                , FoodSearch.update (FoodSearch.CategoryDebounceElapsed (ticket 3) "cho") typed
                    |> third
                )
                    |> Expect.equal
                        ( FoodSearch.NoOp
                        , FoodSearch.NoOp
                        , FoodSearch.RequestCategorySuggestions (ticket 3)
                            { query = "cho", limit = 8 }
                        )
        , test "scope change cancels a pending category debounce" <|
            \_ ->
                FoodSearch.update (FoodSearch.QueryChanged "category:foo") emptyModel
                    |> first
                    |> FoodSearch.update (FoodSearch.ScopeSelected FoodSearch.Custom)
                    |> first
                    |> FoodSearch.update (FoodSearch.CategoryDebounceElapsed (ticket 1) "foo")
                    |> third
                    |> Expect.equal FoodSearch.NoOp
        , test "scope change drops an in-flight category response" <|
            \_ ->
                FoodSearch.update (FoodSearch.QueryChanged "category:foo") emptyModel
                    |> first
                    |> FoodSearch.update (FoodSearch.ScopeSelected FoodSearch.Custom)
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.CategorySuggestionsCompleted (ticket 1)
                            (Ok { items = [ { value = "food", count = 4 } ] })
                        )
                    |> first
                    |> .search
                    |> .categorySuggestions
                    |> Expect.equal []
        , test "blank category query does not request suggestions" <|
            \_ ->
                FoodSearch.update (FoodSearch.QueryChanged "   ") emptyModel
                    |> third
                    |> Expect.equal FoodSearch.NoOp
        , test "matching category suggestions are stored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.CategorySuggestionsCompleted (ticket 1)
                        (Ok
                            { items =
                                [ { value = "food and beverages", count = 4 } ]
                            }
                        )
                    )
                    { emptyModel
                        | search =
                            Search.withCategoryToken (ticket 1)
                                emptyModel.search
                    }
                    |> first
                    |> .search
                    |> .categorySuggestions
                    |> Expect.equal [ { value = "food and beverages", count = 4 } ]
        , test "stale category suggestions are ignored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.CategorySuggestionsCompleted (ticket 1)
                        (Ok { items = [ { value = "food", count = 4 } ] })
                    )
                    { emptyModel
                        | search = Search.withCategoryToken (ticket 2) emptyModel.search
                    }
                    |> first
                    |> .search
                    |> .categorySuggestions
                    |> Expect.equal []
        , test "category suggestion failure clears suggestions" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.CategorySuggestionsCompleted (ticket 1) (Err Client.NetworkError))
                    { emptyModel
                        | search =
                            { query = ""
                            , searchToken = ticket 0
                            , categoryToken = ticket 1
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
                    (FoodSearch.CategorySuggestionsCompleted (ticket 1)
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    { emptyModel
                        | search = Search.withCategoryToken (ticket 1) emptyModel.search
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
                            , searchToken = ticket 0
                            , categoryToken = ticket 0
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
                    (FoodSearch.DebounceElapsed (ticket 2) "apple")
                    { emptyModel
                        | scope = FoodSearch.All
                        , search =
                            Search.withSearchToken (ticket 2)
                                emptyModel.search
                    }
                    |> third
                    |> Expect.equal
                        (FoodSearch.RequestSearch (ticket 2)
                            { query = "apple", scope = Foods.SearchAll }
                        )
        , test "history scope change immediately searches existing query" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.ScopeSelected FoodSearch.History)
                    { emptyModel
                        | scope = FoodSearch.All
                        , search = Search.withQuery "apple" emptyModel.search
                    }
                    |> third
                    |> Expect.equal
                        (FoodSearch.RequestSearch (ticket 1)
                            { query = "apple", scope = Foods.SearchHistory }
                        )
        , test "custom scope debounce uses custom scope" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.DebounceElapsed (ticket 2) "apple")
                    { emptyModel
                        | scope = FoodSearch.Custom
                        , search = Search.withSearchToken (ticket 2) emptyModel.search
                    }
                    |> third
                    |> Expect.equal
                        (FoodSearch.RequestSearch (ticket 2)
                            { query = "apple", scope = Foods.SearchCustom }
                        )
        , test "barcode input change does not request lookup" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.BarcodeChanged "12345")
                    { emptyModel | scope = FoodSearch.Barcode }
                    |> third
                    |> Expect.equal FoodSearch.NoOp
        , test "barcode submit requests lookup without debounce" <|
            \_ ->
                FoodSearch.update
                    FoodSearch.BarcodeSubmitted
                    { emptyModel
                        | scope = FoodSearch.Barcode
                        , barcodeQuery = " 12345 "
                    }
                    |> third
                    |> Expect.equal (FoodSearch.RequestBarcodeLookup (ticket 1) "12345")
        , test "barcode scan click requests scanner start" <|
            \_ ->
                FoodSearch.update
                    FoodSearch.BarcodeScanClicked
                    { emptyModel | scope = FoodSearch.Barcode }
                    |> (\( updated, _, outMsg ) ->
                            ( updated.barcodeScanner, outMsg )
                       )
                    |> Expect.equal
                        ( FoodSearch.ScannerStarting
                        , FoodSearch.RequestBarcodeScanStart
                        )
        , test "barcode scan cancel requests scanner stop" <|
            \_ ->
                FoodSearch.update
                    FoodSearch.BarcodeScanCancelClicked
                    { emptyModel
                        | scope = FoodSearch.Barcode
                        , barcodeScanner = FoodSearch.ScannerActive
                    }
                    |> (\( updated, _, outMsg ) ->
                            ( updated.barcodeScanner, outMsg )
                       )
                    |> Expect.equal
                        ( FoodSearch.ScannerIdle
                        , FoodSearch.RequestBarcodeScanStop
                        )
        , test "barcode scanner started event marks scanner active" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.BarcodeScannerEventReceived
                        { event = "started", barcode = Nothing, message = Nothing }
                    )
                    { emptyModel
                        | scope = FoodSearch.Barcode
                        , barcodeScanner = FoodSearch.ScannerStarting
                    }
                    |> first
                    |> .barcodeScanner
                    |> Expect.equal FoodSearch.ScannerActive
        , test "barcode scanner failed event stores error" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.BarcodeScannerEventReceived
                        { event = "failed"
                        , barcode = Nothing
                        , message = Just "Camera permission was denied."
                        }
                    )
                    { emptyModel
                        | scope = FoodSearch.Barcode
                        , barcodeScanner = FoodSearch.ScannerStarting
                    }
                    |> first
                    |> .barcodeScanner
                    |> Expect.equal
                        (FoodSearch.ScannerFailed "Camera permission was denied.")
        , test "barcode scanner detected event submits detected barcode" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.BarcodeScannerEventReceived
                        { event = "detected"
                        , barcode = Just " 12345 "
                        , message = Nothing
                        }
                    )
                    { emptyModel
                        | scope = FoodSearch.Barcode
                        , barcodeScanner = FoodSearch.ScannerActive
                    }
                    |> (\( updated, _, outMsg ) ->
                            { barcodeQuery = updated.barcodeQuery
                            , scanner = updated.barcodeScanner
                            , lookup = updated.barcodeLookup
                            , outMsg = outMsg
                            }
                       )
                    |> Expect.equal
                        { barcodeQuery = "12345"
                        , scanner = FoodSearch.ScannerIdle
                        , lookup = Loading
                        , outMsg = FoodSearch.RequestBarcodeLookup (ticket 1) "12345"
                        }
        , test "switching away from barcode scope requests scanner stop" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.ScopeSelected FoodSearch.All)
                    { emptyModel
                        | scope = FoodSearch.Barcode
                        , barcodeScanner = FoodSearch.ScannerActive
                    }
                    |> (\( updated, _, outMsg ) ->
                            ( updated.scope, updated.barcodeScanner, outMsg )
                       )
                    |> Expect.equal
                        ( FoodSearch.All
                        , FoodSearch.ScannerIdle
                        , FoodSearch.RequestBarcodeScanStop
                        )
        , test "empty barcode submit is ignored" <|
            \_ ->
                FoodSearch.update
                    FoodSearch.BarcodeSubmitted
                    { emptyModel | scope = FoodSearch.Barcode, barcodeQuery = "   " }
                    |> third
                    |> Expect.equal FoodSearch.NoOp
        , test "barcode lookup success navigates to food detail with context" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.BarcodeLookupCompleted
                        (ticket 1)
                        (Ok
                            { product = appleDetail
                            , lookup = { origin = Foods.Local, note = Nothing }
                            }
                        )
                    )
                    { emptyModel
                        | scope = FoodSearch.Barcode
                        , barcodeToken = ticket 1
                        , date = Just "2026-05-29"
                        , mealSlot = Just Lunch
                    }
                    |> third
                    |> Expect.equal
                        (FoodSearch.Navigate
                            (FoodShow "food-1" (Just "2026-05-29") (Just Lunch) Nothing)
                        )
        , test "fresh Open Food Facts lookup carries its note to food detail" <|
            \_ ->
                let
                    note : String
                    note =
                        "Food was not found locally and was imported from Open Food Facts."
                in
                FoodSearch.update
                    (FoodSearch.BarcodeLookupCompleted
                        (ticket 1)
                        (Ok
                            { product = appleDetail
                            , lookup =
                                { origin = Foods.OpenFoodFacts
                                , note = Just note
                                }
                            }
                        )
                    )
                    { emptyModel
                        | scope = FoodSearch.Barcode
                        , barcodeToken = ticket 1
                    }
                    |> third
                    |> Expect.equal
                        (FoodSearch.Navigate
                            (FoodShow "food-1" Nothing Nothing (Just note))
                        )
        , test "barcode lookup failure keeps error on page" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.BarcodeLookupCompleted (ticket 1) (Err Client.NetworkError))
                    { emptyModel
                        | scope = FoodSearch.Barcode
                        , barcodeToken = ticket 1
                    }
                    |> (\( updated, _, outMsg ) -> ( updated.barcodeLookup, outMsg ))
                    |> Expect.equal ( Failure Client.NetworkError, FoodSearch.NoOp )
        , test "barcode lookup unauthorized expires session" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.BarcodeLookupCompleted (ticket 1)
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    { emptyModel
                        | scope = FoodSearch.Barcode
                        , barcodeToken = ticket 1
                    }
                    |> third
                    |> Expect.equal FoodSearch.SessionExpired
        , test "stale barcode lookup is ignored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.BarcodeLookupCompleted
                        (ticket 1)
                        (Ok
                            { product = appleDetail
                            , lookup = { origin = Foods.Local, note = Nothing }
                            }
                        )
                    )
                    { emptyModel
                        | scope = FoodSearch.Barcode
                        , barcodeToken = ticket 2
                    }
                    |> third
                    |> Expect.equal FoodSearch.NoOp
        , test "debounce for stale token is ignored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.DebounceElapsed (ticket 1) "apple")
                    { emptyModel | search = Search.withSearchToken (ticket 2) emptyModel.search }
                    |> third
                    |> Expect.equal FoodSearch.NoOp
        , test "matching search result stores items and clears loading" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted (ticket 2) (Ok { items = [ apple ] }))
                    { emptyModel
                        | search =
                            Search.withSearchToken (ticket 2)
                                emptyModel.search
                        , results = Loading
                    }
                    |> first
                    |> .results
                    |> Expect.equal (Success [ apple ])
        , test "stale search result is ignored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted (ticket 1) (Ok { items = [ apple ] }))
                    { emptyModel
                        | search =
                            Search.withSearchToken (ticket 2)
                                emptyModel.search
                        , results = Loading
                    }
                    |> first
                    |> .results
                    |> Expect.equal Loading
        , test "search failure stores error and clears results" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted (ticket 2) (Err Client.NetworkError))
                    { loadedModel
                        | search =
                            Search.withSearchToken (ticket 2)
                                loadedModel.search
                        , results = Loading
                    }
                    |> first
                    |> .results
                    |> Expect.equal (Failure Client.NetworkError)
        , test "search failure from stale token is ignored" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted (ticket 1) (Err Client.NetworkError))
                    { loadedModel
                        | search =
                            Search.withSearchToken (ticket 2)
                                loadedModel.search
                    }
                    |> first
                    |> .results
                    |> Expect.equal (Success [ apple ])
        , test "search unauthorized expires session" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.SearchCompleted (ticket 2)
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    { emptyModel | search = Search.withSearchToken (ticket 2) emptyModel.search }
                    |> third
                    |> Expect.equal FoodSearch.SessionExpired
        , test "recent items load success stores items" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentItemsLoaded
                        Nothing
                        Nothing
                        (Ok { items = [ recentProduct ] })
                    )
                    emptyModel
                    |> first
                    |> .recentItems
                    |> Expect.equal (Success [ recentProduct ])
        , test "recent items failure stores error" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentItemsLoaded Nothing Nothing (Err Client.NetworkError))
                    emptyModel
                    |> first
                    |> .recentItems
                    |> Expect.equal (Failure Client.NetworkError)
        , test "recent items unauthorized expires session" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentItemsLoaded
                        Nothing
                        Nothing
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    emptyModel
                    |> third
                    |> Expect.equal FoodSearch.SessionExpired
        , test "recent items ignore a response for an old logging context" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentItemsLoaded
                        (Just "2026-05-29")
                        (Just Lunch)
                        (Ok { items = [ recentProduct ] })
                    )
                    { emptyModel
                        | date = Just "2026-05-29"
                        , mealSlot = Just Dinner
                    }
                    |> first
                    |> .recentItems
                    |> Expect.equal emptyModel.recentItems
        , test "recent product click navigates to food detail with context" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentItemClicked recentProduct)
                    { emptyModel | date = Just "2026-05-29", mealSlot = Just Dinner }
                    |> third
                    |> Expect.equal
                        (FoodSearch.Navigate
                            (FoodShow "food-1" (Just "2026-05-29") (Just Dinner) Nothing)
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
                    (FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity)
                    emptyModel
                    |> third
                    |> Expect.equal FoodSearch.RequestLocalContext
        , test "second recent quick add is ignored while context is pending" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity)
                    emptyModel
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.RecentQuickAddClicked recentMeal recentMeal.quantity)
                    |> third
                    |> Expect.equal FoodSearch.NoOp
        , test "sibling quantity chip click is ignored while another add submits" <|
            \_ ->
                submittingQuickAddModel
                    |> FoodSearch.update
                        (FoodSearch.RecentQuickAddClicked recentProduct siblingQuantity)
                    |> third
                    |> Expect.equal FoodSearch.NoOp
        , test "sibling quantity chip is blocked while another add submits" <|
            \_ ->
                FoodSearch.quickAddChipState submittingQuickAddModel
                    recentProduct
                    siblingQuantity
                    |> Expect.equal FoodSearch.QuickAddBlocked
        , test "submitting quantity chip keeps its own adding state" <|
            \_ ->
                FoodSearch.quickAddChipState submittingQuickAddModel
                    recentProduct
                    recentProduct.quantity
                    |> Expect.equal FoodSearch.QuickAddAdding
        , test "quantity chips become pressable again after a failed quick add" <|
            \_ ->
                submittingQuickAddModel
                    |> FoodSearch.update
                        (FoodSearch.QuickAddCompleted (Err Client.NetworkError))
                    |> first
                    |> (\model ->
                            FoodSearch.quickAddChipState model recentProduct siblingQuantity
                       )
                    |> Expect.equal FoodSearch.QuickAddCanAdd
        , test "local context received creates log request for pending quick add" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity)
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
                    (FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity)
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
                    (FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity)
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
                    (FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity)
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
                        ( ticket 1, [ { key = "product:food-1:2 serving", token = ticket 1 } ] )
        , test "quick add success reports the created log" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity)
                    emptyModel
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.LocalContextReceived
                            { date = "2026-06-01", timezone = "Asia/Kolkata" }
                        )
                    |> first
                    |> FoodSearch.update (FoodSearch.QuickAddCompleted (Ok productLog))
                    |> third
                    |> Expect.equal (FoodSearch.LogCreated productLog)
        , test "quick add success replaces previous added token for same item" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity)
                    { emptyModel
                        | addedToken = ticket 1
                        , addedItems = [ { key = "product:food-1:2 serving", token = ticket 1 } ]
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
                    |> Expect.equal [ { key = "product:food-1:2 serving", token = ticket 2 } ]
        , test "quick add success with no pending item does not mark added" <|
            \_ ->
                FoodSearch.update (FoodSearch.QuickAddCompleted (Ok productLog)) emptyModel
                    |> first
                    |> .addedItems
                    |> Expect.equal []
        , test "quick add failure keeps no added item" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity)
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
                    (FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity)
                    emptyModel
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.LocalContextReceived
                            { date = "2026-06-01", timezone = "Asia/Kolkata" }
                        )
                    |> first
                    |> FoodSearch.update (FoodSearch.QuickAddCompleted (Err Client.NetworkError))
                    |> first
                    |> FoodSearch.update
                        (FoodSearch.RecentQuickAddClicked recentMeal recentMeal.quantity)
                    |> third
                    |> Expect.equal FoodSearch.RequestLocalContext
        , test "quick add unauthorized expires session" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity)
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
                            (FoodShow "food-1" (Just "2026-05-29") (Just Lunch) Nothing)
                        )
        , test "create custom food navigates to custom food create" <|
            \_ ->
                FoodSearch.update FoodSearch.CreateCustomFoodClicked emptyModel
                    |> third
                    |> Expect.equal (FoodSearch.Navigate CustomFoodCreate)
        , test "clear recent added removes matching added item" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.ClearRecentAdded "product:food-1:2 serving" (ticket 1))
                    { emptyModel
                        | addedItems = [ { key = "product:food-1:2 serving", token = ticket 1 } ]
                    }
                    |> first
                    |> .addedItems
                    |> Expect.equal []
        , test "clear recent added ignores stale token" <|
            \_ ->
                FoodSearch.update
                    (FoodSearch.ClearRecentAdded "product:food-1:2 serving" (ticket 1))
                    { emptyModel
                        | addedItems = [ { key = "product:food-1:2 serving", token = ticket 2 } ]
                    }
                    |> first
                    |> .addedItems
                    |> Expect.equal [ { key = "product:food-1:2 serving", token = ticket 2 } ]
        ]


emptyModel : FoodSearch.Model
emptyModel =
    FoodSearch.init Nothing Nothing


loadedModel : FoodSearch.Model
loadedModel =
    { emptyModel
        | results = Success [ apple ]
        , search = Search.withSearchToken (ticket 1) emptyModel.search
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
    , nutritionSummary = { per100g = applePer100g }
    }


applePer100g : Nutrition.NutritionSummary
applePer100g =
    let
        empty : Nutrition.NutritionSummary
        empty =
            Nutrition.emptySummary
    in
    { empty | energyKcal = Just "52" }


appleDetail : ProductDetail
appleDetail =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Just "12345"
    , name = "Apple"
    , brand = Just "Local"
    , categories = [ "fruit" ]
    , defaultQuantity = Just "1"
    , defaultUnit = Just "g"
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    , nutrients = []
    , servings = []
    , allowedUnits = []
    }


recentProduct : Logs.RecentItem
recentProduct =
    { item =
        FoodLog.ProductLogItem
            { id = "food-1", name = "Apple", brand = Just "Local" }
    , lastUsedDate = date "2026-05-28"
    , mealSlot = Just "lunch"
    , quantity = { amount = "2", unit = "serving" }
    , nutritionSummary = Nutrition.emptySummary
    , topQuantities =
        [ { quantity = { amount = "2", unit = "serving" }, logCount = 3 }
        , { quantity = { amount = "1", unit = "serving" }, logCount = 1 }
        ]
    }


siblingQuantity : Nutrition.Quantity
siblingQuantity =
    { amount = "1", unit = "serving" }


submittingQuickAddModel : FoodSearch.Model
submittingQuickAddModel =
    FoodSearch.update
        (FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity)
        emptyModel
        |> first
        |> FoodSearch.update
            (FoodSearch.LocalContextReceived
                { date = "2026-06-01", timezone = "Asia/Kolkata" }
            )
        |> first


recentMeal : Logs.RecentItem
recentMeal =
    { recentProduct
        | item =
            FoodLog.MealLogItem { id = "meal-1", name = "Lunch meal" }
    }


productLog : FoodLog
productLog =
    { id = "log-1"
    , logDate = date "2026-06-01"
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = Just Lunch
    , item = recentProduct.item
    , quantity = recentProduct.quantity
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


ticket : Int -> Ticket
ticket count =
    List.foldl (\_ value -> Ticket.next value) Ticket.initial (List.range 1 count)
