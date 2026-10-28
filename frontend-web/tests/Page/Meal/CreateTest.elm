module Page.Meal.CreateTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (SearchResult, SearchScope(..))
import Api.Meals exposing (Meal)
import Component.Meal.Form as Common
import Data.ItemRef as ItemRef
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import I18n
import Lib.Loadable exposing (Loadable(..))
import Lib.Ticket exposing (Ticket)
import Page.Meal.Create as MealCreate
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.Meal.Create"
        [ test "validation, a plain search, a failed save, retry, then navigate" <|
            \_ ->
                let
                    started : MealCreate.Model
                    started =
                        initModel

                    invalid : MealCreate.Model
                    invalid =
                        step MealCreate.SubmitClicked started

                    named : MealCreate.Model
                    named =
                        step
                            (MealCreate.FormMsg (Common.NameChanged "  Lunch  "))
                            invalid

                    ( searching, searchOut ) =
                        stepWithOut
                            (MealCreate.FormMsg (Common.ComponentSearchChanged 1 "apple"))
                            named
                in
                case productSearch searchOut of
                    Just searchRequest ->
                        let
                            withResults : MealCreate.Model
                            withResults =
                                step
                                    (MealCreate.FormMsg
                                        (Common.ComponentSearchCompleted
                                            1
                                            searchRequest.token
                                            (Ok { items = [ appleResult ] })
                                        )
                                    )
                                    searching

                            selected : MealCreate.Model
                            selected =
                                step
                                    (MealCreate.FormMsg (Common.SelectProduct 1 appleResult))
                                    withResults

                            ( submitting, createOut ) =
                                stepWithOut MealCreate.SubmitClicked selected

                            ( failed, _ ) =
                                stepWithOut
                                    (MealCreate.SaveCompleted (Err Client.NetworkError))
                                    submitting

                            ( retrying, retryOut ) =
                                stepWithOut MealCreate.SubmitClicked failed

                            ( saved, completionOut ) =
                                stepWithOut
                                    (MealCreate.SaveCompleted (Ok meal))
                                    retrying
                        in
                        { validation = (toScreen invalid).error
                        , searchRequest =
                            { query = searchRequest.query, scope = searchRequest.scope }
                        , results = (toScreen withResults).results
                        , createRequest = createRequest createOut
                        , failure = (toScreen failed).error
                        , retryRequest = createRequest retryOut
                        , screen = toScreen saved
                        , finalOut = completionOut
                        }
                            |> Expect.equal
                                { validation = Just nameRequired
                                , searchRequest = { query = "apple", scope = SearchAll }
                                , results = [ "Apple" ]
                                , createRequest = Just lunchRequest
                                , failure = Just Fixtures.networkErrorMessage
                                , retryRequest = Just lunchRequest
                                , screen =
                                    { name = "  Lunch  "
                                    , rows = [ selectedRow "food-1" ]
                                    , results = []
                                    , suggestions = []
                                    , error = Nothing
                                    , disabled = False
                                    }
                                , finalOut = MealCreate.Navigate (MealShow "meal-1")
                                }

                    Nothing ->
                        Expect.fail "the search produced no product-search request"
        , test "category and product searches ignore stale tokens, then a save expires" <|
            \_ ->
                let
                    started : MealCreate.Model
                    started =
                        initModel

                    ( firstQuery, firstOut ) =
                        stepWithOut
                            (MealCreate.FormMsg
                                (Common.ComponentSearchChanged 1 "category:d")
                            )
                            started

                    ( secondQuery, secondOut ) =
                        stepWithOut
                            (MealCreate.FormMsg
                                (Common.ComponentSearchChanged 1 "category:dai")
                            )
                            firstQuery
                in
                case ( productAndCats firstOut, productAndCats secondOut ) of
                    ( Just firstRequest, Just secondRequest ) ->
                        let
                            stale : MealCreate.Model
                            stale =
                                step
                                    (MealCreate.FormMsg
                                        (Common.ComponentCategoriesCompleted
                                            1
                                            firstRequest.categoryToken
                                            (Ok { items = [ otherSuggestion ] })
                                        )
                                    )
                                    secondQuery

                            suggested : MealCreate.Model
                            suggested =
                                step
                                    (MealCreate.FormMsg
                                        (Common.ComponentCategoriesCompleted
                                            1
                                            secondRequest.categoryToken
                                            (Ok { items = [ dairySuggestion ] })
                                        )
                                    )
                                    stale

                            ( completing, completionOut ) =
                                stepWithOut
                                    (MealCreate.FormMsg
                                        (Common.CompleteFirstComponentSuggestion 1)
                                    )
                                    suggested
                        in
                        case productAndCats completionOut of
                            Just completionRequest ->
                                let
                                    withResults : MealCreate.Model
                                    withResults =
                                        step
                                            (MealCreate.FormMsg
                                                (Common.ComponentSearchCompleted
                                                    1
                                                    completionRequest.searchToken
                                                    (Ok { items = [ bananaResult ] })
                                                )
                                            )
                                            completing

                                    ( secondSearching, secondSearchOut ) =
                                        stepWithOut
                                            (MealCreate.FormMsg
                                                (Common.ComponentSearchChanged 1 "ban")
                                            )
                                            withResults
                                in
                                case productSearch secondSearchOut of
                                    Just secondSearch ->
                                        let
                                            currentResults : MealCreate.Model
                                            currentResults =
                                                step
                                                    (MealCreate.FormMsg
                                                        (Common.ComponentSearchCompleted
                                                            1
                                                            secondSearch.token
                                                            (Ok { items = [ bananaResult ] })
                                                        )
                                                    )
                                                    secondSearching

                                            staleResults : MealCreate.Model
                                            staleResults =
                                                step
                                                    (MealCreate.FormMsg
                                                        (Common.ComponentSearchCompleted
                                                            1
                                                            completionRequest.searchToken
                                                            (Ok { items = [ appleResult ] })
                                                        )
                                                    )
                                                    currentResults

                                            selected : MealCreate.Model
                                            selected =
                                                step
                                                    (MealCreate.FormMsg
                                                        (Common.SelectProduct 1 bananaResult)
                                                    )
                                                    staleResults

                                            named : MealCreate.Model
                                            named =
                                                step
                                                    (MealCreate.FormMsg
                                                        (Common.NameChanged "Lunch")
                                                    )
                                                    selected

                                            ( submitting, createOut ) =
                                                stepWithOut MealCreate.SubmitClicked named

                                            ( final, completionOut2 ) =
                                                stepWithOut
                                                    (MealCreate.SaveCompleted
                                                        (Err Fixtures.unauthorized)
                                                    )
                                                    submitting
                                        in
                                        { firstRequest = firstRequest.categoryQuery
                                        , secondRequest = secondRequest.categoryQuery
                                        , staleSuggestions = (toScreen stale).suggestions
                                        , suggestions = (toScreen suggested).suggestions
                                        , completionRequest = completionRequest.categoryQuery
                                        , results = (toScreen staleResults).results
                                        , createRequest = createRequest createOut
                                        , screen = toScreen final
                                        , finalOut = completionOut2
                                        }
                                            |> Expect.equal
                                                { firstRequest = "d"
                                                , secondRequest = "dai"
                                                , staleSuggestions = []
                                                , suggestions = [ "dairy" ]
                                                , completionRequest = "dairy"
                                                , results = [ "Banana" ]
                                                , createRequest =
                                                    Just
                                                        { lunchRequest
                                                            | components =
                                                                [ { item =
                                                                        { itemType = ItemRef.Product
                                                                        , id = "food-2"
                                                                        }
                                                                  , quantity =
                                                                        { amount = "100"
                                                                        , unit = "g"
                                                                        }
                                                                  }
                                                                ]
                                                        }
                                                , screen =
                                                    { name = "Lunch"
                                                    , rows = [ selectedRow "food-2" ]
                                                    , results = []
                                                    , suggestions = []
                                                    , error = Just "Sign in again"
                                                    , disabled = False
                                                    }
                                                , finalOut = MealCreate.SessionExpired
                                                }

                                    Nothing ->
                                        Expect.fail "the second product search sent no request"

                            Nothing ->
                                Expect.fail "the completed suggestion sent no request"

                    _ ->
                        Expect.fail "a category query did not produce a request"
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
            List.head fields.components
                |> Maybe.withDefault (Common.emptyComponentRow 0)
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


type alias ProductAndCats =
    { searchToken : Ticket
    , categoryToken : Ticket
    , categoryQuery : String
    }


productAndCats : MealCreate.OutMsg -> Maybe ProductAndCats
productAndCats outMsg =
    case outMsg of
        MealCreate.FormOutMsg (Common.RequestProductAndCats requests) ->
            Just
                { searchToken = requests.searchToken
                , categoryToken = requests.categoryToken
                , categoryQuery = requests.categoryRequest.query
                }

        _ ->
            Nothing


createRequest : MealCreate.OutMsg -> Maybe Api.Meals.CreateMealRequest
createRequest outMsg =
    case outMsg of
        MealCreate.RequestCreateMeal request ->
            Just request

        _ ->
            Nothing


initModel : MealCreate.Model
initModel =
    Tuple.first MealCreate.init


step : MealCreate.Msg -> MealCreate.Model -> MealCreate.Model
step msg model =
    Fixtures.tupleFirst (MealCreate.update msg model)


stepWithOut :
    MealCreate.Msg
    -> MealCreate.Model
    -> ( MealCreate.Model, MealCreate.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            MealCreate.update msg model
    in
    ( next, outMsg )


nameRequired : String
nameRequired =
    I18n.en TidCustomFoodNameRequired


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


bananaResult : SearchResult
bananaResult =
    searchResult "food-2" "Banana"


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


dairySuggestion : { value : String, count : Int }
dairySuggestion =
    { value = "dairy", count = 5 }


otherSuggestion : { value : String, count : Int }
otherSuggestion =
    { value = "other", count = 1 }


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
