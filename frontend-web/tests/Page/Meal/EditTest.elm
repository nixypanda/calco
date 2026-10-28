module Page.Meal.EditTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (SearchResult)
import Api.Meals exposing (Meal, MealNutritionResponse)
import Component.Meal.Form as Common
import Data.ItemRef as ItemRef
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Data.Route exposing (Route(..))
import Expect
import I18n
import Lib.Ticket exposing (Ticket)
import Page.Meal.Edit as MealEdit
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))
import View.Nutrients exposing (NutritionState(..))


tests : Test
tests =
    describe "Page.Meal.Edit"
        [ test "load retry, stale meals ignored, nutrition previews, then a failed save retried" <|
            \_ ->
                let
                    started : MealEdit.Model
                    started =
                        Tuple.first (MealEdit.init "meal-1")

                    loadFailed : MealEdit.Model
                    loadFailed =
                        step
                            (MealEdit.MealLoaded "meal-1" (Err Client.NetworkError))
                            started

                    retriedLoad : MealEdit.Model
                    retriedLoad =
                        step MealEdit.RetryClicked loadFailed

                    loaded : MealEdit.Model
                    loaded =
                        step (MealEdit.MealLoaded "meal-1" (Ok meal)) retriedLoad

                    staleMeal : MealEdit.Model
                    staleMeal =
                        step (MealEdit.MealLoaded "other" (Ok otherMeal)) loaded

                    nutritionFailed : MealEdit.Model
                    nutritionFailed =
                        step
                            (MealEdit.NutrientPreviewLoaded "meal-1" (Err Client.NetworkError))
                            loaded

                    withNutrition : MealEdit.Model
                    withNutrition =
                        step
                            (MealEdit.NutrientPreviewLoaded
                                "meal-1"
                                (Ok (previewFor [ nutrient ]))
                            )
                            nutritionFailed

                    renamed : MealEdit.Model
                    renamed =
                        step
                            (MealEdit.FormMsg (Common.NameChanged "Lunch bowl"))
                            withNutrition

                    requantified : MealEdit.Model
                    requantified =
                        step
                            (MealEdit.FormMsg (Common.ComponentQuantityChanged 1 "3"))
                            renamed

                    ( submitting, updateOut ) =
                        stepWithOut MealEdit.SubmitClicked requantified

                    ( failed, _ ) =
                        stepWithOut
                            (MealEdit.SaveCompleted (Err Client.NetworkError))
                            submitting

                    ( retrying, retryOut ) =
                        stepWithOut MealEdit.SubmitClicked failed

                    ( saved, completionOut ) =
                        stepWithOut (MealEdit.SaveCompleted (Ok updatedMeal)) retrying
                in
                { loadRetryRequest = out MealEdit.RetryClicked loadFailed
                , staleName = (toScreen staleMeal).name
                , nutritionError = (toScreen nutritionFailed).nutritionError
                , nutrition = (toScreen withNutrition).nutrients
                , request = updateRequest updateOut
                , failure = (toScreen failed).submitError
                , retryRequest = updateRequest retryOut
                , screen = toScreen saved
                , finalOut = completionOut
                }
                    |> Expect.equal
                        { loadRetryRequest = MealEdit.RequestMeal "meal-1"
                        , staleName = "Lunch"
                        , nutritionError = Just Fixtures.networkErrorMessage
                        , nutrition = [ "ENERGY_KCAL:120" ]
                        , request = Just lunchBowlRequest
                        , failure = Just Fixtures.networkErrorMessage
                        , retryRequest = Just lunchBowlRequest
                        , screen =
                            { name = "Lunch bowl"
                            , components = [ ( "food-1", "3", "serving" ) ]
                            , disabled = False
                            , submitError = Nothing
                            , nutrients = [ "ENERGY_KCAL:120" ]
                            , nutritionError = Nothing
                            }
                        , finalOut = MealEdit.Navigate (MealShow "meal-1")
                        }
        , test "name and component validation block save, then a fixed save gets a 401" <|
            \_ ->
                let
                    loaded : MealEdit.Model
                    loaded =
                        Tuple.first (MealEdit.init "meal-1")
                            |> step (MealEdit.MealLoaded "meal-1" (Ok emptyMeal))

                    blanked : MealEdit.Model
                    blanked =
                        step (MealEdit.FormMsg (Common.NameChanged "")) loaded

                    nameInvalid : MealEdit.Model
                    nameInvalid =
                        step MealEdit.SubmitClicked blanked

                    named : MealEdit.Model
                    named =
                        step (MealEdit.FormMsg (Common.NameChanged "Lunch")) nameInvalid

                    componentInvalid : MealEdit.Model
                    componentInvalid =
                        step MealEdit.SubmitClicked named

                    ( searching, searchOut ) =
                        stepWithOut
                            (MealEdit.FormMsg (Common.ComponentSearchChanged 1 "apple"))
                            componentInvalid
                in
                case productSearch searchOut of
                    Just searchRequest ->
                        let
                            selected : MealEdit.Model
                            selected =
                                searching
                                    |> step
                                        (MealEdit.FormMsg
                                            (Common.ComponentSearchCompleted
                                                1
                                                searchRequest.token
                                                (Ok { items = [ appleResult ] })
                                            )
                                        )
                                    |> step
                                        (MealEdit.FormMsg (Common.SelectProduct 1 appleResult))

                            ( submitting, updateOut ) =
                                stepWithOut MealEdit.SubmitClicked selected

                            ( final, completionOut ) =
                                stepWithOut
                                    (MealEdit.SaveCompleted (Err Fixtures.unauthorized))
                                    submitting
                        in
                        { nameInvalid = (toScreen nameInvalid).submitError
                        , nameInvalidOut = out MealEdit.SubmitClicked blanked
                        , componentInvalid = (toScreen componentInvalid).submitError
                        , componentInvalidOut = out MealEdit.SubmitClicked named
                        , searchRequest = searchRequest.query
                        , request = updateRequest updateOut
                        , screen = toScreen final
                        , finalOut = completionOut
                        }
                            |> Expect.equal
                                { nameInvalid = Just nameRequired
                                , nameInvalidOut = MealEdit.NoOp
                                , componentInvalid = Just componentRequired
                                , componentInvalidOut = MealEdit.NoOp
                                , searchRequest = "apple"
                                , request = Just singleRequest
                                , screen =
                                    { name = "Lunch"
                                    , components = [ ( "food-1", "100", "g" ) ]
                                    , disabled = False
                                    , submitError = Just "Sign in again"
                                    , nutrients = []
                                    , nutritionError = Nothing
                                    }
                                , finalOut = MealEdit.SessionExpired
                                }

                    Nothing ->
                        Expect.fail "the component search sent no request"
        ]


type alias Screen =
    { name : String
    , components : List ( String, String, String )
    , disabled : Bool
    , submitError : Maybe String
    , nutrients : List String
    , nutritionError : Maybe String
    }


toScreen : MealEdit.Model -> Screen
toScreen model =
    case model of
        MealEdit.Editing loaded ->
            { name = loaded.fields.name
            , components =
                List.map
                    (\row -> ( row.productId, row.quantity, row.unit ))
                    loaded.fields.components
            , disabled = Common.isSubmitting loaded.fields.submit
            , submitError = submitError loaded.fields.submit
            , nutrients = nutritionAmounts loaded.nutrition
            , nutritionError = nutritionFailure loaded.nutrition
            }

        MealEdit.EditLoadFailed _ ->
            { name = ""
            , components = []
            , disabled = False
            , submitError = Nothing
            , nutrients = []
            , nutritionError = Nothing
            }

        MealEdit.LoadingEdit _ ->
            { name = ""
            , components = []
            , disabled = False
            , submitError = Nothing
            , nutrients = []
            , nutritionError = Nothing
            }


submitError : Common.SubmitState -> Maybe String
submitError state =
    case state of
        Common.SubmitFailed message ->
            Just message

        _ ->
            Nothing


nutritionAmounts : NutritionState -> List String
nutritionAmounts nutrition =
    case nutrition of
        NutritionLoaded _ nutrients ->
            List.map (\item -> item.code ++ ":" ++ item.amount) nutrients

        _ ->
            []


nutritionFailure : NutritionState -> Maybe String
nutritionFailure nutrition =
    case nutrition of
        NutritionFailed _ message ->
            Just message

        _ ->
            Nothing


updateRequest : MealEdit.OutMsg -> Maybe Api.Meals.CreateMealRequest
updateRequest outMsg =
    case outMsg of
        MealEdit.RequestUpdateMeal "meal-1" request ->
            Just request

        _ ->
            Nothing


type alias ProductSearch =
    { token : Ticket, query : String }


productSearch : MealEdit.OutMsg -> Maybe ProductSearch
productSearch outMsg =
    case outMsg of
        MealEdit.FormOutMsg (Common.RequestProductSearch _ token request) ->
            Just { token = token, query = request.query }

        _ ->
            Nothing


step : MealEdit.Msg -> MealEdit.Model -> MealEdit.Model
step msg model =
    Fixtures.tupleFirst (MealEdit.update msg model)


stepWithOut :
    MealEdit.Msg
    -> MealEdit.Model
    -> ( MealEdit.Model, MealEdit.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            MealEdit.update msg model
    in
    ( next, outMsg )


out : MealEdit.Msg -> MealEdit.Model -> MealEdit.OutMsg
out msg model =
    Fixtures.tupleThird (MealEdit.update msg model)


nameRequired : String
nameRequired =
    I18n.en TidCustomFoodNameRequired


componentRequired : String
componentRequired =
    I18n.en TidMealComponentRequired


lunchBowlRequest : Api.Meals.CreateMealRequest
lunchBowlRequest =
    { name = "Lunch bowl"
    , notes = Nothing
    , totalQuantity = Nothing
    , components =
        [ { item = { itemType = ItemRef.Product, id = "food-1" }
          , quantity = { amount = "3", unit = "serving" }
          }
        ]
    }


singleRequest : Api.Meals.CreateMealRequest
singleRequest =
    { name = "Lunch"
    , notes = Nothing
    , totalQuantity = Nothing
    , components =
        [ { item = { itemType = ItemRef.Product, id = "food-1" }
          , quantity = { amount = "100", unit = "g" }
          }
        ]
    }


previewFor : List NutrientAmount -> MealNutritionResponse
previewFor nutrients =
    { mealId = "meal-1"
    , quantity = { amount = "100", unit = "g" }
    , nutritionSummary = Nutrition.emptySummary
    , nutrients = nutrients
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
    , createdAt = "2026-08-18T10:00:00Z"
    , updatedAt = "2026-08-18T10:00:00Z"
    }


emptyMeal : Meal
emptyMeal =
    { meal | components = [] }


otherMeal : Meal
otherMeal =
    { meal | id = "meal-2", name = "Dinner" }


updatedMeal : Meal
updatedMeal =
    { meal | name = "Lunch bowl" }


appleResult : SearchResult
appleResult =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , barcode = Nothing
    , name = "Apple"
    , brand = Nothing
    , categories = []
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    }


nutrient : NutrientAmount
nutrient =
    { code = "ENERGY_KCAL", amount = "120", unit = "kcal" }
