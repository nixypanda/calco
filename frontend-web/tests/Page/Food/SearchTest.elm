module Page.Food.SearchTest exposing (tests)

import Api.Client as Client
import Api.Foods as Foods
import Api.Logs as Logs
import Data.FoodLog as FoodLog exposing (FoodLog)
import Data.LocalCtx exposing (LocalCtx)
import Data.MealSlot exposing (MealSlot(..))
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Lib.Date exposing (LocalDate)
import Lib.Loadable exposing (Loadable(..))
import Lib.Ticket as Ticket exposing (Ticket)
import Page.Food.Search as FoodSearch
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Food.Search"
        [ test "a user searches and opens a food" <|
            \_ ->
                page
                    |> step (FoodSearch.QueryChanged "apple")
                    |> step (FoodSearch.DebounceElapsed (ticket 1) "apple")
                    |> step (FoodSearch.SearchCompleted (ticket 1) (Ok { items = [ apple ] }))
                    |> step (FoodSearch.ResultClicked "food-1")
                    |> finish
                        (\( model, outMsg ) ->
                            { results = values .name model.results
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { results = [ "Apple" ]
                                    , finalOut =
                                        FoodSearch.Navigate
                                            (FoodShow "food-1" (Just day) (Just Lunch) Nothing)
                                    }
                        )
        , test "a user scans an unknown barcode and creates an ad-hoc log" <|
            \_ ->
                page
                    |> step (FoodSearch.ScopeSelected FoodSearch.Barcode)
                    |> step FoodSearch.BarcodeScanClicked
                    |> step (scannerEvent "started" Nothing)
                    |> step (scannerEvent "detected" (Just " 111 "))
                    |> bind
                        (\outMsg ->
                            case outMsg of
                                FoodSearch.RequestBarcodeLookup token _ ->
                                    Ok
                                        (FoodSearch.BarcodeLookupCompleted token
                                            (Err barcodeNotFound)
                                        )

                                _ ->
                                    Err "expected a barcode lookup request"
                        )
                    |> step FoodSearch.CreateAdHocLogClicked
                    |> finish
                        (\( model, outMsg ) ->
                            { barcode = model.barcodeQuery
                            , notFound = barcodeNotFoundShown model.barcodeLookup
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { barcode = "111"
                                    , notFound = True
                                    , finalOut =
                                        FoodSearch.Navigate
                                            (AdHocLogCreate (Just day) (Just Lunch))
                                    }
                        )
        , test "a user quick-adds a recent food" <|
            \_ ->
                recentsPage
                    |> step (FoodSearch.RecentQuickAddClicked recentProduct recentProduct.quantity)
                    |> step (FoodSearch.LocalCtxReceived context)
                    |> step (FoodSearch.QuickAddCompleted (Ok productLog))
                    |> finish
                        (\( model, outMsg ) ->
                            { recentNames = values (FoodLog.itemName << .item) model.recentItems
                            , added = List.map .key model.addedItems
                            , finalOut = outMsg
                            }
                                |> Expect.equal
                                    { recentNames = [ "Apple", "Lunch meal" ]
                                    , added = [ recentProductKey ]
                                    , finalOut = FoodSearch.LogCreated productLog
                                    }
                        )
        ]


values : (a -> b) -> Loadable error (List a) -> List b
values transform loadable =
    case loadable of
        Success items ->
            List.map transform items

        _ ->
            []


barcodeNotFoundShown : Loadable Client.ApiError Foods.ProductDetail -> Bool
barcodeNotFoundShown lookup =
    case lookup of
        Failure (Client.BadStatus 404 _ _) ->
            True

        _ ->
            False


stepWithOut :
    FoodSearch.Msg
    -> FoodSearch.Model
    -> ( FoodSearch.Model, FoodSearch.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            FoodSearch.update msg model
    in
    ( next, outMsg )



-- STORY PIPELINE


type alias Journey =
    Story.Journey FoodSearch.Model FoodSearch.OutMsg


step : FoodSearch.Msg -> Journey -> Journey
step =
    Story.step stepWithOut


bind :
    (FoodSearch.OutMsg -> Result String FoodSearch.Msg)
    -> Journey
    -> Journey
bind =
    Story.bind stepWithOut


finish :
    (( FoodSearch.Model, FoodSearch.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


page : Journey
page =
    Story.start ( FoodSearch.init (Just day) (Just Lunch), FoodSearch.NoOp )


recentsPage : Journey
recentsPage =
    page
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


scannerEvent : String -> Maybe String -> FoodSearch.Msg
scannerEvent event barcode =
    FoodSearch.BarcodeScannerEventReceived
        { event = event, barcode = barcode, message = Nothing }


barcodeNotFound : Client.ApiError
barcodeNotFound =
    Client.BadStatus 404 "not_found" "No food matched that barcode."


apple : Foods.SearchResult
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


recentProductKey : String
recentProductKey =
    "product:food-1:2 serving"


ticket : Int -> Ticket
ticket count =
    List.foldl (\_ value -> Ticket.next value) Ticket.initial (List.range 1 count)
