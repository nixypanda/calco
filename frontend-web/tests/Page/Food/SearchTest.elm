module Page.Food.SearchTest exposing (tests)

import Api.Client as Client
import Api.Foods as Foods exposing (ProductDetail, SearchResult)
import Api.Logs as Logs
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.LocalContext exposing (LocalContext)
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
import Translations.Util as Util
import Ui.Theme as Theme


tests : Test
tests =
    describe "Page.Food.Search"
        [ test "the manual and AI log actions navigate with the current diary context" <|
            \_ ->
                let
                    model : FoodSearch.Model
                    model =
                        FoodSearch.init (Just "2026-06-01") (Just Lunch)
                in
                ( out FoodSearch.CreateAdHocLogClicked model
                , out FoodSearch.CreateAiLogClicked model
                )
                    |> Expect.equal
                        ( FoodSearch.Navigate (AdHocLogCreate (Just "2026-06-01") (Just Lunch))
                        , FoodSearch.Navigate (AiLogCreate (Just "2026-06-01") (Just Lunch))
                        )
        , test "retargeting a different diary context keeps the query and reloads recents" <|
            \_ ->
                let
                    model : FoodSearch.Model
                    model =
                        FoodSearch.init (Just "2026-06-01") (Just Lunch)
                            |> step (FoodSearch.QueryChanged "apple")
                            |> step
                                (FoodSearch.RecentItemsLoaded (Just "2026-06-01")
                                    (Just Lunch)
                                    (Ok { items = [ recentProduct ] })
                                )

                    ( retargeted, changed ) =
                        FoodSearch.retarget (Just "2026-06-02") (Just Dinner) model

                    ( _, changedAgain ) =
                        FoodSearch.retarget (Just "2026-06-02") (Just Dinner) retargeted
                in
                { query = toScreen retargeted |> .query
                , chrono = toScreen retargeted |> .chrono
                , recents = toScreen retargeted |> .recentItems
                , changed = changed
                , changedAgain = changedAgain
                }
                    |> Expect.equal
                        { query = "apple"
                        , chrono = "2026-06-02/dinner"
                        , recents = Loading
                        , changed = True
                        , changedAgain = False
                        }
        , test "typing debounces into a search result and selecting one opens the food" <|
            \_ ->
                let
                    model : FoodSearch.Model
                    model =
                        FoodSearch.init (Just "2026-05-29") (Just Lunch)

                    searched : FoodSearch.OutMsg
                    searched =
                        out (FoodSearch.DebounceElapsed (ticket 1) "apple")
                            (step (FoodSearch.QueryChanged "apple") model)

                    loaded : FoodSearch.Model
                    loaded =
                        step (FoodSearch.SearchCompleted (ticket 1) (Ok { items = [ apple ] }))
                            (step (FoodSearch.QueryChanged "apple") model)
                in
                ( searched
                , toScreen loaded |> .results
                , out (FoodSearch.ResultClicked "food-1") loaded
                )
                    |> Expect.equal
                        ( FoodSearch.RequestSearch (ticket 1)
                            { query = "apple", scope = Foods.SearchHistory }
                        , Success [ "Apple" ]
                        , FoodSearch.Navigate
                            (FoodShow "food-1" (Just "2026-05-29") (Just Lunch) Nothing)
                        )
        , test "clearing a search drops its results and returns to the recents view" <|
            \_ ->
                let
                    model : FoodSearch.Model
                    model =
                        FoodSearch.init (Just "2026-05-29") (Just Lunch)

                    failed : FoodSearch.Model
                    failed =
                        model
                            |> step (FoodSearch.QueryChanged "zzzz")
                            |> step (FoodSearch.DebounceElapsed (ticket 1) "zzzz")
                            |> step
                                (FoodSearch.SearchCompleted (ticket 1)
                                    (Err Client.NetworkError)
                                )

                    cleared : FoodSearch.Model
                    cleared =
                        step (FoodSearch.QueryChanged "   ") failed
                in
                ( toScreen failed |> .results
                , toScreen cleared |> .results
                , toScreen cleared |> .query
                )
                    |> Expect.equal ( Failure Client.NetworkError, NotAsked, "   " )
        , test "a burst of category keystrokes only requests suggestions for the settled query" <|
            \_ ->
                let
                    typed : FoodSearch.Model
                    typed =
                        List.foldl (\query model -> step (FoodSearch.QueryChanged query) model)
                            (FoodSearch.init Nothing Nothing)
                            [ "category:c", "category:ch", "category:cho" ]
                in
                ( out (FoodSearch.CategoryDebounceElapsed (ticket 1) "c") typed
                , out (FoodSearch.CategoryDebounceElapsed (ticket 2) "ch") typed
                , out (FoodSearch.CategoryDebounceElapsed (ticket 3) "cho") typed
                )
                    |> Expect.equal
                        ( FoodSearch.NoOp
                        , FoodSearch.NoOp
                        , FoodSearch.RequestCategorySuggestions (ticket 3)
                            { query = "cho", limit = 8 }
                        )
        , test "tab completion expands the category operators and preserves the gap" <|
            \_ ->
                let
                    complete : String -> String
                    complete query =
                        FoodSearch.init Nothing Nothing
                            |> step (FoodSearch.QueryChanged query)
                            |> step FoodSearch.CompleteFirstSuggestion
                            |> toScreen
                            |> .query
                in
                ( complete "c", complete "apple c", complete "-c" )
                    |> Expect.equal ( "category:", "apple category:", "-category:" )
        , test "a settled category query completes the first suggestion with quotes" <|
            \_ ->
                let
                    typed : FoodSearch.Model
                    typed =
                        step (FoodSearch.QueryChanged "category:foo")
                            (FoodSearch.init Nothing Nothing)

                    completed : FoodSearch.Model
                    completed =
                        typed
                            |> step (FoodSearch.CategoryDebounceElapsed (ticket 1) "foo")
                            |> step
                                (FoodSearch.CategorySuggestionsCompleted (ticket 1)
                                    (Ok { items = [ { value = "food and beverages", count = 4 } ] })
                                )
                            |> step FoodSearch.CompleteFirstSuggestion
                in
                { request = out (FoodSearch.CategoryDebounceElapsed (ticket 1) "foo") typed
                , query = toScreen completed |> .query
                }
                    |> Expect.equal
                        { request =
                            FoodSearch.RequestCategorySuggestions (ticket 1)
                                { query = "foo", limit = 8 }
                        , query = "category:\"food and beverages\""
                        }
        , test "changing scope cancels a pending debounce and drops an in-flight suggestion" <|
            \_ ->
                let
                    typed : FoodSearch.Model
                    typed =
                        step (FoodSearch.QueryChanged "category:foo")
                            (FoodSearch.init Nothing Nothing)

                    switched : FoodSearch.Model
                    switched =
                        step (FoodSearch.ScopeSelected FoodSearch.Custom) typed

                    afterResponse : FoodSearch.Model
                    afterResponse =
                        step
                            (FoodSearch.CategorySuggestionsCompleted (ticket 1)
                                (Ok { items = [ { value = "food", count = 4 } ] })
                            )
                            switched
                in
                ( out (FoodSearch.CategoryDebounceElapsed (ticket 1) "foo") switched
                , toScreen afterResponse |> .categorySuggestions
                , toScreen afterResponse |> .scope
                )
                    |> Expect.equal ( FoodSearch.NoOp, [], FoodSearch.Custom )
        , test "a category suggestion failure clears the list and unauthorized expires" <|
            \_ ->
                let
                    base : FoodSearch.Model
                    base =
                        FoodSearch.init Nothing Nothing

                    pending : FoodSearch.Model
                    pending =
                        { base
                            | search =
                                Search.empty
                                    |> Search.withCategoryToken (ticket 1)
                                    |> Search.setCategorySuggestions (ticket 1)
                                        [ { value = "old", count = 1 } ]
                        }

                    failed : FoodSearch.Model
                    failed =
                        step
                            (FoodSearch.CategorySuggestionsCompleted (ticket 1)
                                (Err Client.NetworkError)
                            )
                            pending
                in
                ( toScreen failed |> .categorySuggestions
                , out
                    (FoodSearch.CategorySuggestionsCompleted (ticket 1)
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    pending
                )
                    |> Expect.equal ( [], FoodSearch.SessionExpired )
        , test "scope switches re-search and debounce honors the selected scope" <|
            \_ ->
                let
                    typed : FoodSearch.Model
                    typed =
                        step (FoodSearch.QueryChanged "apple")
                            (FoodSearch.init Nothing Nothing)

                    toAll : FoodSearch.Model
                    toAll =
                        step (FoodSearch.ScopeSelected FoodSearch.All) typed

                    customModel : FoodSearch.Model
                    customModel =
                        step (FoodSearch.ScopeSelected FoodSearch.Custom) typed
                in
                ( out (FoodSearch.ScopeSelected FoodSearch.All) typed
                , out (FoodSearch.ScopeSelected FoodSearch.History) toAll
                , out (FoodSearch.DebounceElapsed (ticket 2) "apple") customModel
                )
                    |> Expect.equal
                        ( FoodSearch.RequestSearch (ticket 2)
                            { query = "apple", scope = Foods.SearchAll }
                        , FoodSearch.RequestSearch (ticket 3)
                            { query = "apple", scope = Foods.SearchHistory }
                        , FoodSearch.RequestSearch (ticket 2)
                            { query = "apple", scope = Foods.SearchCustom }
                        )
        , test "a stale search response is ignored and failures surface" <|
            \_ ->
                let
                    typed : FoodSearch.Model
                    typed =
                        step (FoodSearch.QueryChanged "apple")
                            (FoodSearch.init Nothing Nothing)

                    retyped : FoodSearch.Model
                    retyped =
                        step (FoodSearch.QueryChanged "apples") typed

                    stale : FoodSearch.Model
                    stale =
                        step (FoodSearch.SearchCompleted (ticket 1) (Ok { items = [ apple ] }))
                            retyped

                    failed : FoodSearch.Model
                    failed =
                        step (FoodSearch.SearchCompleted (ticket 2) (Err Client.NetworkError))
                            retyped
                in
                ( toScreen stale |> .results
                , toScreen failed |> .results
                , out
                    (FoodSearch.SearchCompleted (ticket 2)
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    retyped
                )
                    |> Expect.equal
                        ( Loading, Failure Client.NetworkError, FoodSearch.SessionExpired )
        , test "a barcode submit looks up the code and a hit opens the food with lookup context" <|
            \_ ->
                let
                    model : FoodSearch.Model
                    model =
                        FoodSearch.init (Just "2026-05-29") (Just Lunch)
                            |> step (FoodSearch.ScopeSelected FoodSearch.Barcode)
                            |> step (FoodSearch.BarcodeChanged " 12345 ")

                    note : String
                    note =
                        "Food was not found locally and was imported from Open Food Facts."

                    requested : FoodSearch.Model
                    requested =
                        step FoodSearch.BarcodeSubmitted model

                    completion : Foods.BarcodeLookupResponse -> FoodSearch.OutMsg
                    completion lookup =
                        out (FoodSearch.BarcodeLookupCompleted (ticket 2) (Ok lookup)) requested
                in
                ( out FoodSearch.BarcodeSubmitted model
                , completion
                    { product = appleDetail
                    , lookup = { origin = Foods.Local, note = Nothing }
                    }
                , completion
                    { product = appleDetail
                    , lookup = { origin = Foods.OpenFoodFacts, note = Just note }
                    }
                )
                    |> Expect.equal
                        ( FoodSearch.RequestBarcodeLookup (ticket 2) "12345"
                        , FoodSearch.Navigate
                            (FoodShow "food-1" (Just "2026-05-29") (Just Lunch) Nothing)
                        , FoodSearch.Navigate
                            (FoodShow "food-1" (Just "2026-05-29") (Just Lunch) (Just note))
                        )
        , test "a stale barcode lookup response is ignored" <|
            \_ ->
                let
                    model : FoodSearch.Model
                    model =
                        FoodSearch.init Nothing Nothing
                            |> step (FoodSearch.ScopeSelected FoodSearch.Barcode)
                            |> step (FoodSearch.BarcodeChanged "12345")
                            |> step FoodSearch.BarcodeSubmitted
                            |> step FoodSearch.BarcodeSubmitted

                    hit : FoodSearch.OutMsg
                    hit =
                        out
                            (FoodSearch.BarcodeLookupCompleted (ticket 1)
                                (Ok
                                    { product = appleDetail
                                    , lookup = { origin = Foods.Local, note = Nothing }
                                    }
                                )
                            )
                            model
                in
                ( hit, toScreen model |> .barcodeLookup )
                    |> Expect.equal ( FoodSearch.NoOp, Loading )
        , test "a barcode lookup failure stays on the page and unauthorized expires the session" <|
            \_ ->
                let
                    model : FoodSearch.Model
                    model =
                        FoodSearch.init Nothing Nothing
                            |> step (FoodSearch.ScopeSelected FoodSearch.Barcode)
                            |> step (FoodSearch.BarcodeChanged "12345")
                            |> step FoodSearch.BarcodeSubmitted

                    failed : FoodSearch.Model
                    failed =
                        step
                            (FoodSearch.BarcodeLookupCompleted (ticket 2) (Err Client.NetworkError))
                            model
                in
                ( toScreen failed |> .barcodeLookup
                , out
                    (FoodSearch.BarcodeLookupCompleted (ticket 2)
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    model
                )
                    |> Expect.equal ( Failure Client.NetworkError, FoodSearch.SessionExpired )
        , test "starting and cancelling the scanner toggles the camera and leaving stops it" <|
            \_ ->
                let
                    barcodeScope : FoodSearch.Model
                    barcodeScope =
                        step (FoodSearch.ScopeSelected FoodSearch.Barcode)
                            (FoodSearch.init Nothing Nothing)

                    started : FoodSearch.Model
                    started =
                        step
                            (FoodSearch.BarcodeScannerEventReceived
                                { event = "started", barcode = Nothing, message = Nothing }
                            )
                            (step FoodSearch.BarcodeScanClicked barcodeScope)

                    cancelled : FoodSearch.Model
                    cancelled =
                        step FoodSearch.BarcodeScanCancelClicked started
                in
                { enterScope =
                    out
                        (FoodSearch.ScopeSelected FoodSearch.Barcode)
                        (FoodSearch.init Nothing Nothing)
                , startRequest = out FoodSearch.BarcodeScanClicked barcodeScope
                , startedScanner = toScreen started |> .scanner
                , cancelRequest = out FoodSearch.BarcodeScanCancelClicked started
                , cancelledScanner = toScreen cancelled |> .scanner
                , leaveRequest = out (FoodSearch.ScopeSelected FoodSearch.All) started
                , leftScanner =
                    toScreen (step (FoodSearch.ScopeSelected FoodSearch.All) started) |> .scanner
                }
                    |> Expect.equal
                        { enterScope = FoodSearch.NoOp
                        , startRequest = FoodSearch.RequestBarcodeScanStart
                        , startedScanner = FoodSearch.ScannerActive
                        , cancelRequest = FoodSearch.RequestBarcodeScanStop
                        , cancelledScanner = FoodSearch.ScannerIdle
                        , leaveRequest = FoodSearch.RequestBarcodeScanStop
                        , leftScanner = FoodSearch.ScannerIdle
                        }
        , test "a detected barcode submits the lookup while a scanner failure is surfaced" <|
            \_ ->
                let
                    active : FoodSearch.Model
                    active =
                        FoodSearch.init Nothing Nothing
                            |> step (FoodSearch.ScopeSelected FoodSearch.Barcode)
                            |> step FoodSearch.BarcodeScanClicked
                            |> step
                                (FoodSearch.BarcodeScannerEventReceived
                                    { event = "started", barcode = Nothing, message = Nothing }
                                )

                    detected : FoodSearch.Model
                    detected =
                        step
                            (FoodSearch.BarcodeScannerEventReceived
                                { event = "detected", barcode = Just " 12345 ", message = Nothing }
                            )
                            active

                    failed : FoodSearch.Model
                    failed =
                        FoodSearch.init Nothing Nothing
                            |> step (FoodSearch.ScopeSelected FoodSearch.Barcode)
                            |> step FoodSearch.BarcodeScanClicked
                            |> step
                                (FoodSearch.BarcodeScannerEventReceived
                                    { event = "failed"
                                    , barcode = Nothing
                                    , message = Just "Camera permission was denied."
                                    }
                                )
                in
                { detectedRequest =
                    out
                        (FoodSearch.BarcodeScannerEventReceived
                            { event = "detected", barcode = Just " 12345 ", message = Nothing }
                        )
                        active
                , detectedQuery = toScreen detected |> .barcodeQuery
                , detectedScanner = toScreen detected |> .scanner
                , detectedLookup = toScreen detected |> .barcodeLookup
                , failedScanner = toScreen failed |> .scanner
                }
                    |> Expect.equal
                        { detectedRequest = FoodSearch.RequestBarcodeLookup (ticket 3) "12345"
                        , detectedQuery = "12345"
                        , detectedScanner = FoodSearch.ScannerIdle
                        , detectedLookup = Loading
                        , failedScanner =
                            FoodSearch.ScannerFailed "Camera permission was denied."
                        }
        , test "only a genuine barcode miss offers the ad-hoc log actions" <|
            \_ ->
                let
                    base : FoodSearch.Model
                    base =
                        FoodSearch.init Nothing Nothing
                            |> step (FoodSearch.ScopeSelected FoodSearch.Barcode)
                            |> step (FoodSearch.BarcodeChanged "12345")
                            |> step FoodSearch.BarcodeSubmitted

                    miss : FoodSearch.Model
                    miss =
                        step
                            (FoodSearch.BarcodeLookupCompleted (ticket 2)
                                (Err barcodeNotFound)
                            )
                            base

                    transport : FoodSearch.Model
                    transport =
                        step
                            (FoodSearch.BarcodeLookupCompleted (ticket 2)
                                (Err Client.NetworkError)
                            )
                            base

                    scanning : FoodSearch.Model
                    scanning =
                        step FoodSearch.BarcodeScanClicked miss
                in
                Expect.all
                    [ \_ -> contentFor miss |> Query.has [ Selector.text "Create with AI" ]
                    , \_ ->
                        contentFor transport
                            |> Query.hasNot [ Selector.text "Create with AI" ]
                    , \_ ->
                        contentFor scanning
                            |> Query.hasNot [ Selector.text "No food found for that barcode." ]
                    ]
                    ()
        , test "recent items are capped and stale, failed, or unauthorized loads are handled" <|
            \_ ->
                let
                    model : FoodSearch.Model
                    model =
                        FoodSearch.init (Just "2026-05-29") (Just Lunch)

                    loaded : FoodSearch.Model
                    loaded =
                        step
                            (FoodSearch.RecentItemsLoaded (Just "2026-05-29")
                                (Just Lunch)
                                (Ok { items = List.repeat 11 recentProduct })
                            )
                            model

                    stale : FoodSearch.Model
                    stale =
                        step
                            (FoodSearch.RecentItemsLoaded (Just "2026-05-29")
                                (Just Dinner)
                                (Ok { items = [ recentProduct ] })
                            )
                            loaded

                    failed : FoodSearch.Model
                    failed =
                        step
                            (FoodSearch.RecentItemsLoaded (Just "2026-05-29")
                                (Just Lunch)
                                (Err Client.NetworkError)
                            )
                            model
                in
                { capped = recentCount loaded
                , staleCapped = recentCount stale
                , failedRecents = toScreen failed |> .recentItems
                , unauthorized =
                    out
                        (FoodSearch.RecentItemsLoaded (Just "2026-05-29")
                            (Just Lunch)
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                        model
                }
                    |> Expect.equal
                        { capped = 10
                        , staleCapped = 10
                        , failedRecents = Failure Client.NetworkError
                        , unauthorized = FoodSearch.SessionExpired
                        }
        , test "clicking a recent item opens it while a quick add asks for the local context" <|
            \_ ->
                let
                    model : FoodSearch.Model
                    model =
                        FoodSearch.init (Just "2026-05-29") (Just Lunch)
                in
                ( out (FoodSearch.RecentItemClicked recentMeal) model
                , out quickAddRecent model
                )
                    |> Expect.equal
                        ( FoodSearch.Navigate (MealShow "meal-1")
                        , FoodSearch.RequestLocalContext
                        )
        , test "a quick add builds a create-log request from the diary date or the device date" <|
            \_ ->
                let
                    context : LocalContext
                    context =
                        { date = "2026-06-01", timezone = "Asia/Kolkata" }

                    requestFor : FoodSearch.Model -> FoodSearch.OutMsg
                    requestFor model =
                        out (FoodSearch.LocalContextReceived context)
                            (step
                                quickAddRecent
                                model
                            )
                in
                ( requestFor (FoodSearch.init (Just "2026-05-29") (Just Lunch))
                , requestFor (FoodSearch.init Nothing Nothing)
                )
                    |> Expect.equal
                        ( FoodSearch.RequestCreateLog
                            { logDate = date "2026-05-29"
                            , deviceTimezone = Just "Asia/Kolkata"
                            , mealSlot = Just Lunch
                            , item = { itemType = ItemRef.Product, id = "food-1" }
                            , quantity = { amount = "2", unit = "serving" }
                            , notes = Nothing
                            }
                        , FoodSearch.RequestCreateLog
                            { logDate = date "2026-06-01"
                            , deviceTimezone = Just "Asia/Kolkata"
                            , mealSlot = Nothing
                            , item = { itemType = ItemRef.Product, id = "food-1" }
                            , quantity = { amount = "2", unit = "serving" }
                            , notes = Nothing
                            }
                        )
        , test "a quick add with an unreadable diary date stops and shows an error" <|
            \_ ->
                let
                    afterContext : FoodSearch.Model
                    afterContext =
                        FoodSearch.init (Just "bad-date") (Just Lunch)
                            |> step
                                quickAddRecent
                            |> step
                                (FoodSearch.LocalContextReceived
                                    { date = "2026-06-01", timezone = "Asia/Kolkata" }
                                )
                in
                Expect.all
                    [ \_ ->
                        contentFor afterContext
                            |> Query.has [ Selector.text "Could not read selected date." ]
                    , \_ ->
                        out
                            (FoodSearch.LocalContextReceived
                                { date = "2026-06-01", timezone = "Asia/Kolkata" }
                            )
                            (step
                                (FoodSearch.RecentQuickAddClicked
                                    recentProduct
                                    recentProduct.quantity
                                )
                                (FoodSearch.init (Just "bad-date") (Just Lunch))
                            )
                            |> Expect.equal FoodSearch.NoOp
                    ]
                    ()
        , test "a quick add badges the item and reports the created log" <|
            \_ ->
                let
                    record : FoodSearch.Model -> FoodSearch.Model
                    record model =
                        model
                            |> step
                                quickAddRecent
                            |> step
                                (FoodSearch.LocalContextReceived
                                    { date = "2026-06-01", timezone = "Asia/Kolkata" }
                                )

                    once : FoodSearch.Model
                    once =
                        FoodSearch.init Nothing Nothing
                            |> record
                            |> step (FoodSearch.QuickAddCompleted (Ok productLog))

                    twice : FoodSearch.Model
                    twice =
                        once
                            |> record
                            |> step (FoodSearch.QuickAddCompleted (Ok productLog))
                in
                ( toScreen once |> .addedKeys
                , toScreen twice |> .addedKeys
                , out (FoodSearch.QuickAddCompleted (Ok productLog))
                    (record (FoodSearch.init Nothing Nothing))
                )
                    |> Expect.equal
                        ( [ "product:food-1:2 serving" ]
                        , [ "product:food-1:2 serving" ]
                        , FoodSearch.LogCreated productLog
                        )
        , test "a sibling chip is blocked during a quick add and both recover after failure" <|
            \_ ->
                let
                    submitting : FoodSearch.Model
                    submitting =
                        FoodSearch.init Nothing Nothing
                            |> step
                                quickAddRecent
                            |> step
                                (FoodSearch.LocalContextReceived
                                    { date = "2026-06-01", timezone = "Asia/Kolkata" }
                                )

                    recovered : FoodSearch.Model
                    recovered =
                        step (FoodSearch.QuickAddCompleted (Err Client.NetworkError)) submitting
                in
                { siblingRequest =
                    out (FoodSearch.RecentQuickAddClicked recentProduct siblingQuantity) submitting
                , ownChip =
                    FoodSearch.quickAddChipState submitting recentProduct recentProduct.quantity
                , siblingChip =
                    FoodSearch.quickAddChipState submitting recentProduct siblingQuantity
                , recoveredChip =
                    FoodSearch.quickAddChipState recovered recentProduct siblingQuantity
                }
                    |> Expect.equal
                        { siblingRequest = FoodSearch.NoOp
                        , ownChip = FoodSearch.QuickAddAdding
                        , siblingChip = FoodSearch.QuickAddBlocked
                        , recoveredChip = FoodSearch.QuickAddCanAdd
                        }
        , test "an unauthorized quick add expires the session" <|
            \_ ->
                FoodSearch.init Nothing Nothing
                    |> step quickAddRecent
                    |> step
                        (FoodSearch.LocalContextReceived
                            { date = "2026-06-01", timezone = "Asia/Kolkata" }
                        )
                    |> out
                        (FoodSearch.QuickAddCompleted
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                    |> Expect.equal FoodSearch.SessionExpired
        , test "clearing an added badge ignores a stale token and removes the live one" <|
            \_ ->
                let
                    key : String
                    key =
                        "product:food-1:2 serving"

                    model : FoodSearch.Model
                    model =
                        FoodSearch.init Nothing Nothing
                            |> step
                                quickAddRecent
                            |> step
                                (FoodSearch.LocalContextReceived
                                    { date = "2026-06-01", timezone = "Asia/Kolkata" }
                                )
                            |> step (FoodSearch.QuickAddCompleted (Ok productLog))

                    stale : FoodSearch.Model
                    stale =
                        step (FoodSearch.ClearRecentAdded key (ticket 0)) model

                    cleared : FoodSearch.Model
                    cleared =
                        step (FoodSearch.ClearRecentAdded key (ticket 1)) model
                in
                ( toScreen stale |> .addedKeys, toScreen cleared |> .addedKeys )
                    |> Expect.equal ( [ key ], [] )
        ]



-- SCREEN PROJECTION


type alias Screen =
    { scope : FoodSearch.SearchScope
    , chrono : String
    , query : String
    , results : Loadable Client.ApiError (List String)
    , barcodeQuery : String
    , barcodeLookup : Loadable Client.ApiError String
    , scanner : FoodSearch.BarcodeScannerState
    , recentItems : Loadable Client.ApiError (List String)
    , categorySuggestions : List String
    , addedKeys : List String
    }


toScreen : FoodSearch.Model -> Screen
toScreen model =
    { scope = model.scope
    , chrono =
        Maybe.withDefault "none" model.date
            ++ "/"
            ++ (model.mealSlot |> Maybe.map mealSlotLabel |> Maybe.withDefault "none")
    , query = model.search.query
    , results = mapLoadable (List.map .name) model.results
    , barcodeQuery = model.barcodeQuery
    , barcodeLookup = mapLoadable .name model.barcodeLookup
    , scanner = model.barcodeScanner
    , recentItems =
        mapLoadable (List.map (FoodLog.itemName << .item)) model.recentItems
    , categorySuggestions = List.map .value model.search.categorySuggestions
    , addedKeys = List.map .key model.addedItems
    }


mealSlotLabel : MealSlot -> String
mealSlotLabel slot =
    case slot of
        Breakfast ->
            "breakfast"

        Lunch ->
            "lunch"

        Dinner ->
            "dinner"

        Snack ->
            "snack"

        LateNightSnack ->
            "late_night_snack"


mapLoadable : (a -> b) -> Loadable error a -> Loadable error b
mapLoadable transform loadable =
    case loadable of
        NotAsked ->
            NotAsked

        Loading ->
            Loading

        Failure error ->
            Failure error

        Success value ->
            Success (transform value)


recentCount : FoodSearch.Model -> Int
recentCount model =
    case toScreen model |> .recentItems of
        Success items ->
            List.length items

        _ ->
            -1


contentFor : FoodSearch.Model -> Query.Single FoodSearch.Msg
contentFor model =
    FoodSearch.contentView
        { theme = Theme.light
        , device = { class = Phone, orientation = Portrait }
        , language = Util.EN_US
        }
        model
        |> Element.layout []
        |> Query.fromHtml


step : FoodSearch.Msg -> FoodSearch.Model -> FoodSearch.Model
step msg model =
    first (FoodSearch.update msg model)


quickAddRecent : FoodSearch.Msg
quickAddRecent =
    FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity


out : FoodSearch.Msg -> FoodSearch.Model -> FoodSearch.OutMsg
out msg model =
    third (FoodSearch.update msg model)


barcodeNotFound : Client.ApiError
barcodeNotFound =
    Client.BadStatus 404 "not_found" "No food matched that barcode."


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
