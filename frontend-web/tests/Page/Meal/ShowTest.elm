module Page.Meal.ShowTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Api.Meals exposing (Meal, MealNutritionResponse)
import Data.ItemRef as ItemRef
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Data.Route exposing (Route(..))
import Element exposing (DeviceClass(..), Orientation(..))
import Expect
import Page.Meal.Show as MealShow
import Support.Fixtures as Fixtures
import Support.Story exposing (runSteps)
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Translations.Util as Util
import Ui.Theme as Theme
import View.DeleteModal exposing (DeleteState(..))
import View.Nutrients exposing (NutritionState(..))


tests : Test
tests =
    describe "Page.Meal.Show"
        [ test "fallback units, stale previews, component names, edit, then a 401 expires" <|
            \_ ->
                let
                    withFallbackUnits : MealShow.Model
                    withFallbackUnits =
                        Tuple.first (MealShow.init "meal-1")
                            |> step (MealShow.UnitsLoaded (Err Client.NetworkError))

                    ( loaded, productRequestOut ) =
                        stepWithOut
                            (MealShow.MealLoaded "meal-1" (Ok twoProductMeal))
                            withFallbackUnits

                    ( withFirstProduct, secondProductRequestOut ) =
                        stepWithOut
                            (MealShow.ProductDetailLoaded "food-1" (Ok appleProduct))
                            loaded

                    ( named, finalProductOut ) =
                        stepWithOut
                            (MealShow.ProductDetailLoaded "food-2" (Err Client.NetworkError))
                            withFirstProduct

                    zero : MealShow.Model
                    zero =
                        step (MealShow.AmountChanged "0") named

                    invalid : MealShow.Model
                    invalid =
                        step (MealShow.AmountChanged "nope") zero

                    ( changed, amountOut ) =
                        stepWithOut (MealShow.AmountChanged "150") invalid

                    stale : MealShow.Model
                    stale =
                        step
                            (MealShow.NutrientPreviewLoaded
                                "meal-1"
                                (Ok (previewFor "100" "g" [ nutrient ]))
                            )
                            changed

                    applied : MealShow.Model
                    applied =
                        step
                            (MealShow.NutrientPreviewLoaded
                                "meal-1"
                                (Ok (previewFor "150" "g" [ scaledNutrient ]))
                            )
                            stale

                    ( unitChanged, unitOut ) =
                        stepWithOut (MealShow.UnitChanged "serving") applied

                    unitApplied : MealShow.Model
                    unitApplied =
                        step
                            (MealShow.NutrientPreviewLoaded
                                "meal-1"
                                (Ok (previewFor "150" "serving" [ servingNutrient ]))
                            )
                            unitChanged

                    staleMeal : MealShow.Model
                    staleMeal =
                        step (MealShow.MealLoaded "other" (Ok otherMeal)) unitApplied

                    final : MealShow.Model
                    final =
                        step
                            (MealShow.NutrientPreviewLoaded "meal-1" (Err Fixtures.unauthorized))
                            staleMeal
                in
                Expect.all
                    [ \_ ->
                        { fallbackUnits = (nutritionScreen withFallbackUnits).units
                        , zero = ( (nutritionScreen zero).amount, (nutritionScreen zero).nutrients )
                        , zeroOut = out (MealShow.AmountChanged "0") named
                        , invalid =
                            ( (nutritionScreen invalid).amount
                            , (nutritionScreen invalid).nutrients
                            )
                        , invalidOut = out (MealShow.AmountChanged "nope") zero
                        , amountRequest = previewRequest amountOut
                        , staleNutrients = (nutritionScreen stale).nutrients
                        , amountNutrients = (nutritionScreen applied).nutrients
                        , unitRequest = previewRequest unitOut
                        , unitNutrients = (nutritionScreen unitApplied).nutrients
                        , staleMealName = (nutritionScreen staleMeal).name
                        , productRequest = productRequestOut
                        , secondProductRequest = secondProductRequestOut
                        , finalProductOut = finalProductOut
                        , editOut = out MealShow.EditClicked named
                        , screen = nutritionScreen final
                        , finalOut =
                            out
                                (MealShow.NutrientPreviewLoaded
                                    "meal-1"
                                    (Err Fixtures.unauthorized)
                                )
                                staleMeal
                        }
                            |> Expect.equal
                                { fallbackUnits = [ "g" ]
                                , zero = ( "0", [] )
                                , zeroOut = MealShow.NoOp
                                , invalid = ( "nope", [] )
                                , invalidOut = MealShow.NoOp
                                , amountRequest =
                                    Just ( "meal-1", "150", "g" )
                                , staleNutrients = []
                                , amountNutrients = [ "ENERGY_KCAL:180" ]
                                , unitRequest =
                                    Just ( "meal-1", "150", "serving" )
                                , unitNutrients = [ "ENERGY_KCAL:90" ]
                                , staleMealName = "Lunch"
                                , productRequest = MealShow.RequestProductDetail "food-1"
                                , secondProductRequest = MealShow.RequestProductDetail "food-2"
                                , finalProductOut = MealShow.NoOp
                                , editOut = MealShow.Navigate (MealEdit "meal-1")
                                , screen =
                                    { name = "Lunch"
                                    , units = [ "g" ]
                                    , amount = "150"
                                    , unit = "serving"
                                    , nutrients = []
                                    , error = Just "Sign in again"
                                    }
                                , finalOut = MealShow.SessionExpired
                                }
                    , \_ ->
                        contentFor named
                            |> Query.has [ Selector.text "Apple" ]
                    , \_ ->
                        contentFor named
                            |> Query.has [ Selector.text "Unknown food" ]
                    ]
                    ()
        , test "delete cancel, failure, a late success, and retry navigation" <|
            \_ ->
                let
                    loaded : MealShow.Model
                    loaded =
                        Tuple.first (MealShow.init "meal-1")
                            |> runSteps step
                                [ MealShow.UnitsLoaded (Ok { items = [ gram ] })
                                , MealShow.MealLoaded "meal-1" (Ok meal)
                                ]

                    confirming : MealShow.Model
                    confirming =
                        step MealShow.DeleteClicked loaded

                    cancelled : MealShow.Model
                    cancelled =
                        step MealShow.CancelDeleteClicked confirming

                    reconfirming : MealShow.Model
                    reconfirming =
                        step MealShow.DeleteClicked cancelled

                    ( deleting, deleteOut ) =
                        stepWithOut MealShow.ConfirmDeleteClicked reconfirming

                    failed : MealShow.Model
                    failed =
                        step
                            (MealShow.DeleteCompleted (Err Client.NetworkError))
                            deleting

                    lateOut : MealShow.OutMsg
                    lateOut =
                        out (MealShow.DeleteCompleted (Ok ())) failed

                    ( retrying, retryOut ) =
                        stepWithOut MealShow.ConfirmDeleteClicked failed

                    ( final, completionOut ) =
                        stepWithOut (MealShow.DeleteCompleted (Ok ())) retrying
                in
                { confirming = deleteScreen confirming
                , cancelled = deleteScreen cancelled
                , deleting = deleteScreen deleting
                , deleteRequest = deleteOut
                , failure = deleteScreen failed
                , lateOut = lateOut
                , retryRequest = retryOut
                , screen = deleteScreen final
                , finalOut = completionOut
                }
                    |> Expect.equal
                        { confirming = confirmingDelete
                        , cancelled = closed
                        , deleting = pendingDelete
                        , deleteRequest = MealShow.RequestDeleteMeal "meal-1"
                        , failure = failedDelete Fixtures.networkErrorMessage
                        , lateOut = MealShow.NoOp
                        , retryRequest = MealShow.RequestDeleteMeal "meal-1"
                        , screen = pendingDelete
                        , finalOut = MealShow.Navigate MealList
                        }
        ]


type alias NutritionProjection =
    { name : String
    , units : List String
    , amount : String
    , unit : String
    , nutrients : List String
    , error : Maybe String
    }


nutritionScreen : MealShow.Model -> NutritionProjection
nutritionScreen model =
    case model of
        MealShow.Loaded loaded ->
            let
                ( amount, unit ) =
                    nutritionFields loaded.nutrition
            in
            { name = loaded.meal.name
            , units = List.map .code loaded.units
            , amount = amount
            , unit = unit
            , nutrients = nutritionAmounts loaded.nutrition
            , error = nutritionFailure loaded.nutrition
            }

        MealShow.LoadFailed _ ->
            { name = ""
            , units = []
            , amount = ""
            , unit = ""
            , nutrients = []
            , error = Nothing
            }

        MealShow.Loading loading ->
            let
                ( amount, unit ) =
                    nutritionFields loading.nutrition
            in
            { name = ""
            , units = List.map .code loading.units
            , amount = amount
            , unit = unit
            , nutrients = nutritionAmounts loading.nutrition
            , error = nutritionFailure loading.nutrition
            }


nutritionFields : NutritionState -> ( String, String )
nutritionFields nutrition =
    case nutrition of
        NutritionLoading input ->
            ( input.amount, input.unit )

        NutritionLoaded input _ ->
            ( input.amount, input.unit )

        NutritionFailed input _ ->
            ( input.amount, input.unit )

        NutritionUnavailable input ->
            ( input.amount, input.unit )


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


type alias DeleteView =
    { open : Bool, pending : Bool, cancelDisabled : Bool, error : Maybe String }


deleteScreen : MealShow.Model -> DeleteView
deleteScreen model =
    case model of
        MealShow.Loaded loaded ->
            deleteView loaded.delete

        _ ->
            closed


deleteView : DeleteState -> DeleteView
deleteView state =
    case state of
        DeleteIdle ->
            closed

        DeleteConfirming ->
            confirmingDelete

        Deleting ->
            pendingDelete

        DeleteFailed message ->
            failedDelete message


closed : DeleteView
closed =
    { open = False, pending = False, cancelDisabled = False, error = Nothing }


confirmingDelete : DeleteView
confirmingDelete =
    { open = True, pending = False, cancelDisabled = False, error = Nothing }


pendingDelete : DeleteView
pendingDelete =
    { open = True, pending = True, cancelDisabled = True, error = Nothing }


failedDelete : String -> DeleteView
failedDelete message =
    { open = True, pending = False, cancelDisabled = False, error = Just message }


previewRequest : MealShow.OutMsg -> Maybe ( String, String, String )
previewRequest outMsg =
    case outMsg of
        MealShow.RequestNutrientPreview mealId amount unit ->
            Just ( mealId, amount, unit )

        _ ->
            Nothing


contentFor : MealShow.Model -> Query.Single MealShow.Msg
contentFor model =
    MealShow.view
        { theme = Theme.light
        , device = { class = Phone, orientation = Portrait }
        , language = Util.EN_US
        }
        model
        |> Element.layout []
        |> Query.fromHtml


step : MealShow.Msg -> MealShow.Model -> MealShow.Model
step msg model =
    Fixtures.tupleFirst (MealShow.update msg model)


stepWithOut :
    MealShow.Msg
    -> MealShow.Model
    -> ( MealShow.Model, MealShow.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            MealShow.update msg model
    in
    ( next, outMsg )


out : MealShow.Msg -> MealShow.Model -> MealShow.OutMsg
out msg model =
    Fixtures.tupleThird (MealShow.update msg model)


previewFor : String -> String -> List NutrientAmount -> MealNutritionResponse
previewFor amount unit nutrients =
    { mealId = "meal-1"
    , quantity = { amount = amount, unit = unit }
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
          , quantity = { amount = "100", unit = "g" }
          , nutritionSummary = Nothing
          }
        ]
    , createdAt = "2026-08-18T10:00:00Z"
    , updatedAt = "2026-08-18T10:00:00Z"
    }


twoProductMeal : Meal
twoProductMeal =
    { meal
        | components =
            meal.components
                ++ [ { id = "component-2"
                     , item = { itemType = ItemRef.Product, id = "food-2" }
                     , quantity = { amount = "50", unit = "g" }
                     , nutritionSummary = Nothing
                     }
                   ]
    }


appleProduct : ProductDetail
appleProduct =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Apple"
    , brand = Nothing
    , categories = []
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    , nutrients = []
    , servings = []
    , allowedUnits = []
    }


otherMeal : Meal
otherMeal =
    { meal | id = "meal-2", name = "Dinner" }


nutrient : NutrientAmount
nutrient =
    { code = "ENERGY_KCAL", amount = "120", unit = "kcal" }


scaledNutrient : NutrientAmount
scaledNutrient =
    { code = "ENERGY_KCAL", amount = "180", unit = "kcal" }


servingNutrient : NutrientAmount
servingNutrient =
    { code = "ENERGY_KCAL", amount = "90", unit = "kcal" }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }
