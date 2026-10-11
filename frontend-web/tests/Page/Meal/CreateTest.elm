module Page.Meal.CreateTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (SearchResult, SearchScope(..))
import Api.Meals exposing (Meal)
import Component.Meal.Form as Common
import Data.ItemRef as ItemRef
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Data.Search as Search
import Expect
import Lib.Loadable exposing (Loadable(..))
import Lib.Ticket as Ticket exposing (Ticket)
import Page.Meal.Create as MealCreate
import Test exposing (Test, describe, test)


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


unauthorized : Client.ApiError
unauthorized =
    Client.BadStatus 401 "unauthorized" "Sign in again"


submitErrorMessage : Common.SubmitState -> Maybe String
submitErrorMessage state =
    case state of
        Common.SubmitFailed message ->
            Just message

        _ ->
            Nothing


tests : Test
tests =
    describe "Page.Meal.Create"
        [ test "submitting a valid meal requests creation with a trimmed name and defaults" <|
            \_ ->
                let
                    row : Common.ComponentRow
                    row =
                        Common.emptyComponentRow 1

                    form : Common.FormFields
                    form =
                        { emptyFormFields
                            | name = "  Lunch  "
                            , components =
                                [ { row | productId = "food-1", quantity = "", unit = "" } ]
                        }

                    submitting : MealCreate.Model
                    submitting =
                        step MealCreate.SubmitClicked form
                in
                { request = out MealCreate.SubmitClicked form
                , submit = submitting.submit
                , success = out (MealCreate.SaveCompleted (Ok meal)) submitting
                }
                    |> Expect.equal
                        { request =
                            MealCreate.RequestCreateMeal
                                { name = "Lunch"
                                , notes = Nothing
                                , totalQuantity = Nothing
                                , components =
                                    [ { item = { itemType = ItemRef.Product, id = "food-1" }
                                      , quantity = { amount = "100", unit = "g" }
                                      }
                                    ]
                                }
                        , submit = Common.Submitting
                        , success = MealCreate.Navigate (MealShow "meal-1")
                        }
        , test "submitting without a name or component surfaces validation errors" <|
            \_ ->
                let
                    noName : MealCreate.Model
                    noName =
                        step MealCreate.SubmitClicked emptyFormFields

                    noComponentForm : Common.FormFields
                    noComponentForm =
                        { emptyFormFields | name = "Lunch" }

                    noComponent : MealCreate.Model
                    noComponent =
                        step MealCreate.SubmitClicked noComponentForm
                in
                { noNameRequest = out MealCreate.SubmitClicked emptyFormFields
                , noNameError = noName.submit |> submitErrorMessage
                , noComponentRequest = out MealCreate.SubmitClicked noComponentForm
                , noComponentError = noComponent.submit |> submitErrorMessage
                }
                    |> Expect.equal
                        { noNameRequest = MealCreate.NoOp
                        , noNameError = Just "Name is required"
                        , noComponentRequest = MealCreate.NoOp
                        , noComponentError =
                            Just "At least one component with a selected product is required"
                        }
        , test "a stale row search response is ignored" <|
            \_ ->
                let
                    row : Common.ComponentRow
                    row =
                        Common.emptyComponentRow 1

                    form : Common.FormFields
                    form =
                        { emptyFormFields
                            | components =
                                [ { row | search = Search.withSearchToken (ticket 2) row.search } ]
                        }
                in
                step
                    (MealCreate.FormMsg
                        (Common.ComponentSearchCompleted 1 (ticket 1) (Ok { items = [ result ] }))
                    )
                    form
                    |> .components
                    |> List.head
                    |> Maybe.map .searchResults
                    |> Expect.equal (Just NotAsked)
        , test "searching a category requests both product and category suggestions" <|
            \_ ->
                out
                    (MealCreate.FormMsg (Common.ComponentSearchChanged 1 "category:foo"))
                    (Tuple.first MealCreate.init)
                    |> Expect.equal
                        (MealCreate.FormOutMsg
                            (Common.RequestProductAndCats
                                { rowId = 1
                                , searchToken = ticket 1
                                , searchRequest =
                                    { query = "category:foo", scope = SearchAll }
                                , categoryToken = ticket 2
                                , categoryRequest = { query = "foo", limit = 8 }
                                }
                            )
                        )
        , test "a save failure surfaces the request error and a 401 expires the session" <|
            \_ ->
                let
                    submitting : MealCreate.Model
                    submitting =
                        step MealCreate.SubmitClicked validForm

                    afterFailure : MealCreate.Model
                    afterFailure =
                        step (MealCreate.SaveCompleted (Err Client.NetworkError)) submitting
                in
                { error = afterFailure.submit |> submitErrorMessage
                , failureRequest =
                    out (MealCreate.SaveCompleted (Err Client.NetworkError)) submitting
                , unauthorized =
                    out (MealCreate.SaveCompleted (Err unauthorized)) submitting
                }
                    |> Expect.equal
                        { error = Just networkErrorMessage
                        , failureRequest = MealCreate.NoOp
                        , unauthorized = MealCreate.SessionExpired
                        }
        ]



-- HELPERS


validForm : Common.FormFields
validForm =
    let
        row : Common.ComponentRow
        row =
            Common.emptyComponentRow 1
    in
    { emptyFormFields
        | name = "Lunch"
        , components = [ { row | productId = "food-1" } ]
    }


emptyFormFields : Common.FormFields
emptyFormFields =
    Common.emptyFormFields


step : MealCreate.Msg -> MealCreate.Model -> MealCreate.Model
step msg model =
    first (MealCreate.update msg model)


out : MealCreate.Msg -> MealCreate.Model -> MealCreate.OutMsg
out msg model =
    third (MealCreate.update msg model)


result : SearchResult
result =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , barcode = Nothing
    , name = "Rice"
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
          , quantity = { amount = "2", unit = "serving" }
          , nutritionSummary = Nothing
          }
        ]
    , createdAt = "now"
    , updatedAt = "now"
    }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value


ticket : Int -> Ticket
ticket count =
    List.foldl (\_ value -> Ticket.next value) Ticket.initial (List.range 1 count)
