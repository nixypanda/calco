module Page.Food.SearchTest exposing (tests)

import Api.Client as Client
import Api.Foods as Foods exposing (SearchResult)
import Api.Logs as Logs
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.ItemRef as ItemRef
import Data.LocalCtx exposing (LocalCtx)
import Data.MealSlot as MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Data.Search as Search
import Element exposing (DeviceClass(..), Orientation(..))
import Expect
import Html.Attributes as Attr
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Lib.Loadable exposing (Loadable(..))
import Lib.Ticket as Ticket exposing (Ticket)
import Page.Food.Search as FoodSearch
import Support.Fixtures as Fixtures
import Support.Story exposing (runStepsResult)
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Translations.Ids exposing (TranslationId(..))
import Translations.Util as Util
import Ui.Theme as Theme


tests : Test
tests =
    describe "Page.Food.Search"
        [ test "searching ignores a stale result, opens a food, then surfaces errors and 401" <|
            \_ ->
                expectSteps
                    (runStepsResult stepWithOut
                        [ FoodSearch.QueryChanged "apple"
                        , FoodSearch.SearchCompleted (ticket 1) (Ok { items = [ apple ] })
                        ]
                        recentsModel
                    )
                    (\( searched, _ ) ->
                        let
                            stale : FoodSearch.Model
                            stale =
                                step
                                    (FoodSearch.SearchCompleted (ticket 0)
                                        (Ok { items = [ banana ] })
                                    )
                                    searched
                        in
                        Expect.all
                            [ \_ ->
                                searchRequest
                                    (out (FoodSearch.DebounceElapsed (ticket 1) "apple") searched)
                                    |> Expect.equal (Just { query = "apple", scope = "history" })
                            , \_ -> values .name stale.results |> Expect.equal [ "Apple" ]
                            , \_ ->
                                out (FoodSearch.ResultClicked "food-1") stale
                                    |> Expect.equal
                                        (FoodSearch.Navigate
                                            (FoodShow "food-1" (Just day) (Just Lunch) Nothing)
                                        )
                            , \_ ->
                                expectSteps
                                    (runStepsResult stepWithOut
                                        [ FoodSearch.QueryChanged "banana"
                                        , FoodSearch.SearchCompleted (ticket 2)
                                            (Err Client.NetworkError)
                                        ]
                                        searched
                                    )
                                    (\( failed, _ ) ->
                                        visibleError failed
                                            |> Expect.equal (Just Fixtures.networkErrorMessage)
                                    )
                            , \_ ->
                                expectSteps
                                    (runStepsResult stepWithOut
                                        [ FoodSearch.QueryChanged "apple"
                                        , FoodSearch.SearchCompleted (ticket 2)
                                            (Err Fixtures.unauthorized)
                                        ]
                                        searched
                                    )
                                    (\( _, expiryOuts ) ->
                                        (List.reverse expiryOuts |> List.head)
                                            |> Expect.equal (Just FoodSearch.SessionExpired)
                                    )
                            ]
                            ()
                    )
        , test "category completion by click or tab, stale suggestions, and 401" <|
            \_ ->
                expectSteps
                    (runStepsResult stepWithOut
                        [ FoodSearch.QueryChanged "category:foo" ]
                        (FoodSearch.init Nothing Nothing)
                    )
                    (\( typed, _ ) ->
                        let
                            suggested : FoodSearch.Model
                            suggested =
                                step
                                    (FoodSearch.CategorySuggestionsCompleted
                                        (categoryToken 1)
                                        (Ok
                                            { items =
                                                [ { value = "food and beverages", count = 4 } ]
                                            }
                                        )
                                    )
                                    typed

                            completion : Search.Completion
                            completion =
                                Search.CategoryCompletion categoryCompleted 4
                        in
                        Expect.all
                            [ \_ ->
                                categoryRequest
                                    (out
                                        (FoodSearch.CategoryDebounceElapsed
                                            (categoryToken 1)
                                            "foo"
                                        )
                                        typed
                                    )
                                    |> Expect.equal (Just { query = "foo", limit = 8 })
                            , \_ ->
                                expectSteps
                                    (runStepsResult stepWithOut
                                        [ FoodSearch.CompletionClicked completion ]
                                        suggested
                                    )
                                    (\( clicked, _ ) ->
                                        inputShows categoryCompleted clicked
                                    )
                            , \_ ->
                                expectSteps
                                    (runStepsResult stepWithOut
                                        [ FoodSearch.CompleteFirstSuggestion ]
                                        suggested
                                    )
                                    (\( tabbed, _ ) ->
                                        inputShows categoryCompleted tabbed
                                    )
                            , \_ ->
                                expectSteps
                                    (runStepsResult stepWithOut
                                        [ FoodSearch.CompletionClicked completion
                                        , FoodSearch.QueryChanged "category:bar"
                                        ]
                                        suggested
                                    )
                                    (\( retyped, _ ) ->
                                        Expect.all
                                            [ \_ ->
                                                let
                                                    stale : FoodSearch.Model
                                                    stale =
                                                        step
                                                            (FoodSearch.CategorySuggestionsCompleted
                                                                (categoryToken 1)
                                                                (Ok
                                                                    { items =
                                                                        [ { value =
                                                                                "stale category"
                                                                          , count = 1
                                                                          }
                                                                        ]
                                                                    }
                                                                )
                                                            )
                                                            retyped
                                                in
                                                contentFor stale
                                                    |> Query.has
                                                        [ Selector.text categoryCompleted ]
                                            , \_ ->
                                                expectSteps
                                                    (runStepsResult stepWithOut
                                                        [ FoodSearch.CategorySuggestionsCompleted
                                                            (categoryToken 3)
                                                            (Err Client.NetworkError)
                                                        ]
                                                        retyped
                                                    )
                                                    (\( failed, _ ) ->
                                                        contentFor failed
                                                            |> Query.hasNot
                                                                [ Selector.text categoryCompleted ]
                                                    )
                                            , \_ ->
                                                expectSteps
                                                    (runStepsResult stepWithOut
                                                        [ FoodSearch.QueryChanged "category:baz"
                                                        , FoodSearch.CategorySuggestionsCompleted
                                                            (categoryToken 4)
                                                            (Err Fixtures.unauthorized)
                                                        ]
                                                        retyped
                                                    )
                                                    (\( final, finalOuts ) ->
                                                        Expect.all
                                                            [ \_ ->
                                                                inputShows "category:baz" final
                                                            , \_ ->
                                                                lastOut finalOuts
                                                                    |> Expect.equal
                                                                        (Just
                                                                            sessionExpiredOut
                                                                        )
                                                            ]
                                                            ()
                                                    )
                                            ]
                                            ()
                                    )
                            ]
                            ()
                    )
        , test "a barcode miss exposes ad-hoc actions; cancel and leaving stop the scanner" <|
            \_ ->
                expectSteps
                    (runStepsResult stepWithOut
                        [ FoodSearch.ScopeSelected FoodSearch.Barcode ]
                        recentsModel
                    )
                    (\( barcodeScope, _ ) ->
                        let
                            scanning : FoodSearch.Model
                            scanning =
                                step FoodSearch.BarcodeScanClicked barcodeScope

                            started : FoodSearch.Model
                            started =
                                step (scannerEvent "started" Nothing) scanning

                            detected : FoodSearch.Model
                            detected =
                                step (scannerEvent "detected" (Just " 111 ")) started

                            manual : FoodSearch.Model
                            manual =
                                step (FoodSearch.BarcodeChanged " 999 ") barcodeScope

                            failedScan : FoodSearch.Model
                            failedScan =
                                step (scannerEvent "failed" Nothing) scanning

                            barcodeFailed : FoodSearch.Model
                            barcodeFailed =
                                step
                                    (FoodSearch.BarcodeLookupCompleted (ticket 3)
                                        (Err Client.NetworkError)
                                    )
                                    detected

                            miss : FoodSearch.Model
                            miss =
                                step
                                    (FoodSearch.BarcodeLookupCompleted (ticket 3)
                                        (Err barcodeNotFound)
                                    )
                                    detected

                            rescanned : FoodSearch.Model
                            rescanned =
                                miss
                                    |> step FoodSearch.BarcodeScanClicked
                                    |> step (scannerEvent "started" Nothing)
                                    |> step (scannerEvent "detected" (Just "222"))

                            detectedOut : FoodSearch.OutMsg
                            detectedOut =
                                out (scannerEvent "detected" (Just " 111 ")) started

                            staleBarcodeOut : FoodSearch.OutMsg
                            staleBarcodeOut =
                                out
                                    (FoodSearch.BarcodeLookupCompleted (ticket 3) (Ok hit))
                                    rescanned

                            currentBarcodeOut : FoodSearch.OutMsg
                            currentBarcodeOut =
                                out
                                    (FoodSearch.BarcodeLookupCompleted (ticket 5) (Ok hit))
                                    rescanned
                        in
                        Expect.all
                            [ \_ ->
                                out FoodSearch.BarcodeScanClicked barcodeScope
                                    |> Expect.equal FoodSearch.RequestBarcodeScanStart
                            , \_ ->
                                barcodeRequest detectedOut
                                    |> Expect.equal (Just "111")
                            , \_ ->
                                barcodeRequest (out FoodSearch.BarcodeSubmitted manual)
                                    |> Expect.equal (Just "999")
                            , \_ ->
                                contentFor failedScan
                                    |> Query.has
                                        [ Selector.text (I18n.en TidFoodSearchErrorScannerStart)
                                        ]
                            , \_ ->
                                contentFor miss
                                    |> Query.has
                                        [ Selector.text (I18n.en TidFoodSearchBarcodeNotFound)
                                        , Selector.text (I18n.en TidTitleCreateWithAi)
                                        , Selector.text (I18n.en TidFoodSearchEnterManually)
                                        ]
                            , \_ ->
                                contentFor detected
                                    |> Query.hasNot
                                        [ Selector.text (I18n.en TidFoodSearchEnterManually) ]
                            , \_ ->
                                contentFor barcodeFailed
                                    |> Query.has [ Selector.text Fixtures.networkErrorMessage ]
                            , \_ ->
                                out FoodSearch.CreateAdHocLogClicked miss
                                    |> Expect.equal
                                        (FoodSearch.Navigate
                                            (AdHocLogCreate (Just day) (Just Lunch))
                                        )
                            , \_ ->
                                out FoodSearch.CreateAiLogClicked miss
                                    |> Expect.equal
                                        (FoodSearch.Navigate
                                            (AiLogCreate (Just day) (Just Lunch))
                                        )
                            , \_ ->
                                out FoodSearch.BarcodeScanCancelClicked scanning
                                    |> Expect.equal FoodSearch.RequestBarcodeScanStop
                            , \_ ->
                                out (FoodSearch.ScopeSelected FoodSearch.History) miss
                                    |> Expect.equal FoodSearch.RequestBarcodeScanStop
                            , \_ ->
                                staleBarcodeOut
                                    |> Expect.equal FoodSearch.NoOp
                            , \_ ->
                                currentBarcodeOut
                                    |> Expect.equal
                                        (FoodSearch.Navigate
                                            (FoodShow "food-1"
                                                (Just day)
                                                (Just Lunch)
                                                (Just importNote)
                                            )
                                        )
                            ]
                            ()
                    )
        , test "recents open products and meals, and quick add can fail, retry, and badge" <|
            \_ ->
                expectSteps
                    (runStepsResult stepWithOut
                        [ FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity
                        , FoodSearch.LocalCtxReceived context
                        ]
                        recentsModel
                    )
                    (\( submitting, outs ) ->
                        let
                            failed : FoodSearch.Model
                            failed =
                                step
                                    (FoodSearch.QuickAddCompleted (Err Client.NetworkError))
                                    submitting

                            retrying : FoodSearch.Model
                            retrying =
                                step quickAddRecent failed

                            completed : FoodSearch.Model
                            completed =
                                retrying
                                    |> step (FoodSearch.LocalCtxReceived context)
                                    |> step (FoodSearch.QuickAddCompleted (Ok productLog))

                            readded : FoodSearch.Model
                            readded =
                                completed
                                    |> step quickAddRecent
                                    |> step (FoodSearch.LocalCtxReceived context)
                                    |> step (FoodSearch.QuickAddCompleted (Ok productLog))

                            staleRecents : FoodSearch.Model
                            staleRecents =
                                step
                                    (FoodSearch.RecentItemsLoaded
                                        (Just (Fixtures.date "2026-05-30"))
                                        (Just Lunch)
                                        (Ok { items = [ recentMeal ] })
                                    )
                                    readded

                            oldClear : FoodSearch.Model
                            oldClear =
                                step (FoodSearch.ClearRecentAdded recentProductKey (ticket 1))
                                    readded

                            newClear : FoodSearch.Model
                            newClear =
                                step (FoodSearch.ClearRecentAdded recentProductKey (ticket 2))
                                    oldClear

                            quickAddExpired : FoodSearch.OutMsg
                            quickAddExpired =
                                out
                                    (FoodSearch.QuickAddCompleted (Err Fixtures.unauthorized))
                                    submitting
                        in
                        Expect.all
                            [ \_ ->
                                out (FoodSearch.RecentItemClicked recentProduct) recentsModel
                                    |> Expect.equal
                                        (FoodSearch.Navigate
                                            (FoodShow "food-1" (Just day) (Just Lunch) Nothing)
                                        )
                            , \_ ->
                                out (FoodSearch.RecentItemClicked recentMeal) recentsModel
                                    |> Expect.equal (FoodSearch.Navigate (MealShow "meal-1"))
                            , \_ ->
                                List.head outs
                                    |> Expect.equal (Just FoodSearch.RequestLocalCtx)
                            , \_ ->
                                Maybe.andThen createLog (List.drop 1 outs |> List.head)
                                    |> Expect.equal
                                        (Just
                                            { date = "2026-05-29"
                                            , timezone = Just "Asia/Kolkata"
                                            , meal = Just "lunch"
                                            , item = "product:food-1"
                                            , amount = "2"
                                            , unit = "serving"
                                            , notes = Nothing
                                            }
                                        )
                            , \_ ->
                                contentFor submitting
                                    |> Query.has [ Selector.text (I18n.en TidFoodSearchAdding) ]
                            , \_ ->
                                contentFor submitting
                                    |> Query.findAll [ Selector.disabled True ]
                                    |> Query.count (Expect.equal 3)
                            , \_ ->
                                contentFor failed
                                    |> Query.has [ Selector.text Fixtures.networkErrorMessage ]
                            , \_ ->
                                out quickAddRecent failed
                                    |> Expect.equal FoodSearch.RequestLocalCtx
                            , \_ ->
                                contentFor completed
                                    |> Query.findAll [ Selector.disabled True ]
                                    |> Query.count (Expect.equal 1)
                            , \_ ->
                                values (FoodLog.itemName << .item) completed.recentItems
                                    |> Expect.equal [ "Apple", "Lunch meal" ]
                            , \_ ->
                                out (FoodSearch.QuickAddCompleted (Ok productLog)) retrying
                                    |> Expect.equal (FoodSearch.LogCreated productLog)
                            , \_ ->
                                contentFor readded
                                    |> Query.findAll [ Selector.disabled True ]
                                    |> Query.count (Expect.equal 1)
                            , \_ ->
                                contentFor oldClear
                                    |> Query.findAll [ Selector.disabled True ]
                                    |> Query.count (Expect.equal 1)
                            , \_ ->
                                contentFor newClear
                                    |> Query.findAll [ Selector.disabled True ]
                                    |> Query.count (Expect.equal 0)
                            , \_ ->
                                values (FoodLog.itemName << .item) staleRecents.recentItems
                                    |> Expect.equal [ "Apple", "Lunch meal" ]
                            , \_ ->
                                quickAddExpired
                                    |> Expect.equal sessionExpiredOut
                            , \_ ->
                                out
                                    (FoodSearch.RecentItemsLoaded (Just day)
                                        (Just Lunch)
                                        (Err Fixtures.unauthorized)
                                    )
                                    completed
                                    |> Expect.equal FoodSearch.SessionExpired
                            ]
                            ()
                    )
        ]



-- USER-VISIBLE PROJECTIONS


inputShows : String -> FoodSearch.Model -> Expect.Expectation
inputShows value model =
    contentFor model
        |> Query.has [ Selector.attribute (Attr.value value) ]


visibleError : FoodSearch.Model -> Maybe String
visibleError model =
    case model.results of
        Failure Client.NetworkError ->
            Just Fixtures.networkErrorMessage

        Failure (Client.BadStatus _ _ message) ->
            Just message

        _ ->
            Nothing


values : (a -> b) -> Loadable error (List a) -> List b
values transform loadable =
    case loadable of
        Success items ->
            List.map transform items

        _ ->
            []


searchRequest : FoodSearch.OutMsg -> Maybe { query : String, scope : String }
searchRequest outMsg =
    case outMsg of
        FoodSearch.RequestSearch _ request ->
            Just { query = request.query, scope = scopeLabel request.scope }

        _ ->
            Nothing


categoryRequest : FoodSearch.OutMsg -> Maybe { query : String, limit : Int }
categoryRequest outMsg =
    case outMsg of
        FoodSearch.RequestCategorySuggestions _ request ->
            Just { query = request.query, limit = request.limit }

        _ ->
            Nothing


barcodeRequest : FoodSearch.OutMsg -> Maybe String
barcodeRequest outMsg =
    case outMsg of
        FoodSearch.RequestBarcodeLookup _ barcode ->
            Just barcode

        _ ->
            Nothing


type alias CreateLogProjection =
    { date : String
    , timezone : Maybe String
    , meal : Maybe String
    , item : String
    , amount : String
    , unit : String
    , notes : Maybe String
    }


createLog : FoodSearch.OutMsg -> Maybe CreateLogProjection
createLog outMsg =
    case outMsg of
        FoodSearch.RequestCreateLog request ->
            Just
                { date = LocalDate.format request.logDate
                , timezone = request.deviceTimezone
                , meal = Maybe.map MealSlot.toString request.mealSlot
                , item = ItemRef.itemTypeToString request.item.itemType ++ ":" ++ request.item.id
                , amount = request.quantity.amount
                , unit = request.quantity.unit
                , notes = request.notes
                }

        _ ->
            Nothing


scopeLabel : Foods.SearchScope -> String
scopeLabel scope =
    case scope of
        Foods.SearchAll ->
            "all"

        Foods.SearchHistory ->
            "history"

        Foods.SearchCustom ->
            "custom"



-- VIEW HELPER


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



-- FIXTURES AND HELPERS


expectSteps :
    Result String ( model, List out )
    -> (( model, List out ) -> Expect.Expectation)
    -> Expect.Expectation
expectSteps result assertion =
    case result of
        Ok pair ->
            assertion pair

        Err message ->
            Expect.fail message


step : FoodSearch.Msg -> FoodSearch.Model -> FoodSearch.Model
step msg model =
    Fixtures.tupleFirst (FoodSearch.update msg model)


stepWithOut :
    FoodSearch.Msg
    -> FoodSearch.Model
    -> Maybe ( FoodSearch.Model, FoodSearch.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            FoodSearch.update msg model
    in
    if next == model && outMsg == FoodSearch.NoOp then
        Nothing

    else
        Just ( next, outMsg )


out : FoodSearch.Msg -> FoodSearch.Model -> FoodSearch.OutMsg
out msg model =
    Fixtures.tupleThird (FoodSearch.update msg model)


quickAddRecent : FoodSearch.Msg
quickAddRecent =
    FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity


scannerEvent : String -> Maybe String -> FoodSearch.Msg
scannerEvent event barcode =
    FoodSearch.BarcodeScannerEventReceived
        { event = event, barcode = barcode, message = Nothing }


recentsModel : FoodSearch.Model
recentsModel =
    FoodSearch.init (Just day) (Just Lunch)
        |> step
            (FoodSearch.RecentItemsLoaded (Just day)
                (Just Lunch)
                (Ok { items = [ recentProduct, recentMeal ] })
            )


day : LocalDate
day =
    Fixtures.date "2026-05-29"


context : LocalCtx
context =
    { date = Fixtures.date "2026-06-01", timezone = "Asia/Kolkata" }


importNote : String
importNote =
    "Food was not found locally and was imported from Open Food Facts."


barcodeNotFound : Client.ApiError
barcodeNotFound =
    Client.BadStatus 404 "not_found" "No food matched that barcode."


sessionExpiredOut : FoodSearch.OutMsg
sessionExpiredOut =
    FoodSearch.SessionExpired


categoryCompleted : String
categoryCompleted =
    "category:\"food and beverages\""


apple : SearchResult
apple =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , barcode = Just "12345"
    , name = "Apple"
    , brand = Just "Local"
    , categories = [ "fruit" ]
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    }


banana : SearchResult
banana =
    { apple | id = "food-2", name = "Banana" }


hit : Foods.BarcodeLookupResponse
hit =
    { product =
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
    , lookup = { origin = Foods.OpenFoodFacts, note = Just importNote }
    }


recentProduct : Logs.RecentItem
recentProduct =
    { item =
        FoodLog.ProductLogItem
            { id = "food-1", name = "Apple", brand = Just "Local" }
    , lastUsedDate = Fixtures.date "2026-05-28"
    , mealSlot = Just Lunch
    , quantity = { amount = "2", unit = "serving" }
    , nutritionSummary = Nutrition.emptySummary
    , topQuantities =
        [ { quantity = { amount = "2", unit = "serving" }, logCount = 3 }
        , { quantity = { amount = "1", unit = "serving" }, logCount = 1 }
        ]
    }


recentMeal : Logs.RecentItem
recentMeal =
    { recentProduct
        | item = FoodLog.MealLogItem { id = "meal-1", name = "Lunch meal" }
        , quantity = { amount = "1", unit = "bowl" }
        , topQuantities =
            [ { quantity = { amount = "1", unit = "bowl" }, logCount = 1 } ]
    }


recentProductKey : String
recentProductKey =
    "product:food-1:2 serving"


productLog : FoodLog
productLog =
    { id = "log-1"
    , logDate = day
    , deviceTimezone = Just "Asia/Kolkata"
    , mealSlot = Just Lunch
    , item = recentProduct.item
    , quantity = recentProduct.quantity
    , nutrients = []
    , notes = Nothing
    }


ticket : Int -> Ticket
ticket count =
    List.foldl (\_ value -> Ticket.next value) Ticket.initial (List.range 1 count)


{-| Category responses are accepted only when they echo the current query's
category token.
-}
categoryToken : Int -> Ticket
categoryToken count =
    Search.withCategoryToken (ticket count) Search.empty
        |> .categoryToken


lastOut : List a -> Maybe a
lastOut items =
    List.reverse items |> List.head
