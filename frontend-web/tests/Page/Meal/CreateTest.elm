module Page.Meal.CreateTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (SearchResult, SearchScope)
import Api.Meals exposing (Meal)
import Component.Meal.Form as Common
import Data.ItemRef as ItemRef
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Lib.Loadable exposing (Loadable(..))
import Lib.Ticket exposing (Ticket)
import Page.Meal.Create as MealCreate
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.Meal.Create"
        [ test "a user creates a meal from search results" <|
            \_ ->
                MealCreate.init
                    |> Story.start
                    |> step (MealCreate.FormMsg (Common.NameChanged "Lunch"))
                    |> step (MealCreate.FormMsg (Common.ComponentSearchChanged 1 "apple"))
                    |> bind
                        (\out ->
                            productSearch out
                                |> Maybe.map
                                    (\searchRequest ->
                                        MealCreate.FormMsg
                                            (Common.ComponentSearchCompleted 1
                                                searchRequest.token
                                                (Ok { items = [ appleResult ] })
                                            )
                                    )
                                |> Result.fromMaybe "the search produced no product-search request"
                        )
                    |> step (MealCreate.FormMsg (Common.SelectProduct 1 appleResult))
                    |> step MealCreate.SubmitClicked
                    |> step (MealCreate.SaveCompleted (Ok meal))
                    |> finish
                        (\( saved, completionOut ) ->
                            { screen = toScreen saved
                            , finalOut = completionOut
                            }
                                |> Expect.equal
                                    { screen =
                                        { name = "Lunch"
                                        , rows = [ selectedRow "food-1" ]
                                        , results = []
                                        , suggestions = []
                                        , error = Nothing
                                        , disabled = False
                                        }
                                    , finalOut =
                                        MealCreate.Navigate (MealShow "meal-1")
                                    }
                        )
        , test "a failed save can be retried" <|
            \_ ->
                preparedMeal
                    |> step MealCreate.SubmitClicked
                    |> step
                        (MealCreate.SaveCompleted (Err Client.NetworkError))
                    |> step MealCreate.SubmitClicked
                    |> finish
                        (\( model, outMsg ) ->
                            { request = createRequest outMsg
                            , disabled = (toScreen model).disabled
                            }
                                |> Expect.equal { request = Just lunchRequest, disabled = True }
                        )
        , test "a save with an expired session reports session expiry" <|
            \_ ->
                preparedMeal
                    |> step MealCreate.SubmitClicked
                    |> step
                        (MealCreate.SaveCompleted (Err Fixtures.unauthorized))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal MealCreate.SessionExpired
                        )
        ]


type alias Screen =
    { name : String
    , rows : List Row
    , results : List String
    , suggestions : List String
    , error : Maybe String
    , disabled : Bool
    }


type alias Row =
    { productId : String, quantity : String, unit : String }


toScreen : MealCreate.Model -> Screen
toScreen fields =
    let
        row : Common.ComponentRow
        row =
            List.head fields.components |> Maybe.withDefault (Common.emptyComponentRow 0)
    in
    { name = fields.name
    , rows = List.map rowProjection fields.components
    , results = resultsText row.searchResults
    , suggestions = List.map .value row.search.categorySuggestions
    , error = submitError fields.submit
    , disabled = Common.isSubmitting fields.submit
    }


rowProjection : Common.ComponentRow -> Row
rowProjection row =
    { productId = row.productId, quantity = row.quantity, unit = row.unit }


resultsText : Loadable () (List SearchResult) -> List String
resultsText results =
    case results of
        Success items ->
            List.map .name items

        _ ->
            []


submitError : Common.SubmitState -> Maybe String
submitError state =
    case state of
        Common.SubmitFailed message ->
            Just message

        _ ->
            Nothing


type alias ProductSearch =
    { token : Ticket, query : String, scope : SearchScope }


productSearch : MealCreate.OutMsg -> Maybe ProductSearch
productSearch outMsg =
    case outMsg of
        MealCreate.FormOutMsg (Common.RequestProductSearch _ token request) ->
            Just { token = token, query = request.query, scope = request.scope }

        _ ->
            Nothing


createRequest : MealCreate.OutMsg -> Maybe Api.Meals.CreateMealRequest
createRequest outMsg =
    case outMsg of
        MealCreate.RequestCreateMeal request ->
            Just request

        _ ->
            Nothing



-- STORY PIPELINE


type alias Journey =
    Story.Journey MealCreate.Model MealCreate.OutMsg


step : MealCreate.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd MealCreate.update)


bind :
    (MealCreate.OutMsg -> Result String MealCreate.Msg)
    -> Journey
    -> Journey
bind =
    Story.bind (Story.ignoreCmd MealCreate.update)


finish :
    (( MealCreate.Model, MealCreate.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


preparedMeal : Journey
preparedMeal =
    MealCreate.init
        |> Story.start
        |> step (MealCreate.FormMsg (Common.NameChanged "Lunch"))
        |> step
            (MealCreate.FormMsg (Common.ComponentSearchChanged 1 "apple"))
        |> bind
            (\out ->
                productSearch out
                    |> Maybe.map
                        (\searchRequest ->
                            MealCreate.FormMsg
                                (Common.ComponentSearchCompleted 1
                                    searchRequest.token
                                    (Ok { items = [ appleResult ] })
                                )
                        )
                    |> Result.fromMaybe "the search produced no product-search request"
            )
        |> step (MealCreate.FormMsg (Common.SelectProduct 1 appleResult))


lunchRequest : Api.Meals.CreateMealRequest
lunchRequest =
    { name = "Lunch"
    , notes = Nothing
    , totalQuantity = Nothing
    , components =
        [ { item = { itemType = ItemRef.Product, id = "food-1" }
          , quantity = { amount = "100", unit = "g" }
          }
        ]
    }


selectedRow : String -> Row
selectedRow productId =
    { productId = productId, quantity = "100", unit = "g" }


appleResult : SearchResult
appleResult =
    searchResult "food-1" "Apple"


searchResult : String -> String -> SearchResult
searchResult id name =
    { id = id
    , source = "USER"
    , sourceId = Nothing
    , barcode = Nothing
    , name = name
    , brand = Nothing
    , categories = []
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    }


meal : Meal
meal =
    { id = "meal-1"
    , name = "Lunch"
    , notes = Nothing
    , totalQuantity = Nothing
    , nutritionSummary = Nothing
    , components =
        [ { id = "component-1"
          , item = { itemType = ItemRef.Product, id = "food-1" }
          , quantity = { amount = "100", unit = "g" }
          , nutritionSummary = Nothing
          }
        ]
    , createdAt = "2026-08-18T10:00:00Z"
    , updatedAt = "2026-08-18T10:00:00Z"
    }
