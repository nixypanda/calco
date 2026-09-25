module Page.CustomFood.EditTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (CreateFoodRequest, NutrientItem, ProductDetail, UnitItem)
import Component.FoodEditor as Form
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Lib.Ticket as Ticket exposing (Ticket)
import Page.CustomFood.Edit as CustomFoodEdit
import Test exposing (Test, describe, test)


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


tests : Test
tests =
    describe "Page.CustomFood.Edit"
        [ test "loading composes the edit form and seeds the nutrient catalog" <|
            \_ ->
                let
                    ( _, initialRequest ) =
                        CustomFoodEdit.init "food-1"

                    loaded : CustomFoodEdit.Model
                    loaded =
                        emptyModel
                            |> step (CustomFoodEdit.FoodLoaded "food-1" (Ok food))
                            |> step (CustomFoodEdit.NutrientsLoaded (Ok { items = nutrientItems }))
                            |> step (CustomFoodEdit.UnitsLoaded (Ok { items = [ gram ] }))
                            |> step
                                (CustomFoodEdit.FormMsg
                                    (Form.NutrientCodeChanged 0 "MONOUNSATURATED_FAT_G")
                                )
                in
                { initialRequest = initialRequest
                , screen = toScreen loaded
                }
                    |> Expect.equal
                        { initialRequest = CustomFoodEdit.RequestInitialData "food-1"
                        , screen =
                            { phase = "loaded"
                            , name = Just "Curd"
                            , firstNutrientUnit = Just "g"
                            , submit = Just Form.Idle
                            , error = Nothing
                            }
                        }
        , test "a failed load shows a retryable error and retry restarts the load" <|
            \_ ->
                let
                    failed : CustomFoodEdit.Model
                    failed =
                        step (CustomFoodEdit.NutrientsLoaded (Err Client.NetworkError)) emptyModel

                    retried : CustomFoodEdit.Model
                    retried =
                        step CustomFoodEdit.RetryClicked failed
                in
                { failedScreen = toScreen failed
                , retryRequest = out CustomFoodEdit.RetryClicked failed
                , retriedPhase = toScreen retried |> .phase
                }
                    |> Expect.equal
                        { failedScreen =
                            { phase = "failed"
                            , name = Nothing
                            , firstNutrientUnit = Nothing
                            , submit = Nothing
                            , error = Just networkErrorMessage
                            }
                        , retryRequest = CustomFoodEdit.RequestInitialData "food-1"
                        , retriedPhase = "loading"
                        }
        , test "an unauthorized load expires the session" <|
            \_ ->
                out
                    (CustomFoodEdit.NutrientsLoaded
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    emptyModel
                    |> Expect.equal CustomFoodEdit.SessionExpired
        , test "a response for another product or after a failure is ignored" <|
            \_ ->
                let
                    otherProduct : CustomFoodEdit.Model
                    otherProduct =
                        step (CustomFoodEdit.FoodLoaded "other" (Ok food)) validLoadedModel

                    lateSuccess : CustomFoodEdit.Model
                    lateSuccess =
                        step (CustomFoodEdit.FoodLoaded "food-1" (Ok food)) failedModel
                in
                { otherName = toScreen otherProduct |> .name
                , lateSuccess = toScreen lateSuccess
                }
                    |> Expect.equal
                        { otherName = Just "Paneer"
                        , lateSuccess = toScreen failedModel
                        }
        , test "submitting requests an update and a confirmed save navigates to the detail" <|
            \_ ->
                let
                    invalidSubmit : UpdateResult
                    invalidSubmit =
                        submit (loadedWithForm Form.emptyForm)

                    validSubmit : UpdateResult
                    validSubmit =
                        submit validLoadedModel

                    submitting : CustomFoodEdit.Model
                    submitting =
                        first validSubmit

                    saveFailed : UpdateResult
                    saveFailed =
                        saveCompleted (Err Client.NetworkError) submitting

                    saved : CustomFoodEdit.OutMsg
                    saved =
                        out (CustomFoodEdit.SaveCompleted (Ok { id = "food-1" })) submitting
                in
                { invalidRequest = third invalidSubmit
                , invalidSubmitState = toScreen (first invalidSubmit) |> .submit
                , validRequest = third validSubmit
                , validSubmitState = toScreen submitting |> .submit
                , failureRequest = third saveFailed
                , failureSubmitState = toScreen (first saveFailed) |> .submit
                , retryRequest = out CustomFoodEdit.SubmitClicked (first saveFailed)
                , saveSuccess = saved
                }
                    |> Expect.equal
                        { invalidRequest = CustomFoodEdit.NoOp
                        , invalidSubmitState = Just (Form.SubmitFailed "Name is required")
                        , validRequest = CustomFoodEdit.RequestUpdateFood "food-1" validRequest
                        , validSubmitState = Just Form.Submitting
                        , failureRequest = CustomFoodEdit.NoOp
                        , failureSubmitState = Just (Form.SubmitFailed networkErrorMessage)
                        , retryRequest = CustomFoodEdit.RequestUpdateFood "food-1" validRequest
                        , saveSuccess = CustomFoodEdit.Navigate (CustomFoodShow "food-1")
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , name : Maybe String
    , firstNutrientUnit : Maybe String
    , submit : Maybe Form.SubmitState
    , error : Maybe String
    }


toScreen : CustomFoodEdit.Model -> Screen
toScreen model =
    case model of
        CustomFoodEdit.Loaded loaded ->
            { phase = "loaded"
            , name = Just loaded.form.name
            , firstNutrientUnit = loaded.form.nutrients |> List.head |> Maybe.map .unit
            , submit = Just loaded.form.submit
            , error = Nothing
            }

        CustomFoodEdit.Loading _ ->
            { phase = "loading"
            , name = Nothing
            , firstNutrientUnit = Nothing
            , submit = Nothing
            , error = Nothing
            }

        CustomFoodEdit.LoadFailed failed ->
            { phase = "failed"
            , name = Nothing
            , firstNutrientUnit = Nothing
            , submit = Nothing
            , error = Just failed.message
            }


type alias UpdateResult =
    ( CustomFoodEdit.Model, Cmd CustomFoodEdit.Msg, CustomFoodEdit.OutMsg )


step : CustomFoodEdit.Msg -> CustomFoodEdit.Model -> CustomFoodEdit.Model
step msg model =
    first (CustomFoodEdit.update msg model)


out : CustomFoodEdit.Msg -> CustomFoodEdit.Model -> CustomFoodEdit.OutMsg
out msg model =
    third (CustomFoodEdit.update msg model)


submit : CustomFoodEdit.Model -> UpdateResult
submit model =
    CustomFoodEdit.update CustomFoodEdit.SubmitClicked model


saveCompleted : Result Client.ApiError { id : String } -> CustomFoodEdit.Model -> UpdateResult
saveCompleted result model =
    CustomFoodEdit.update (CustomFoodEdit.SaveCompleted result) model


emptyModel : CustomFoodEdit.Model
emptyModel =
    Tuple.first (CustomFoodEdit.init "food-1")


failedModel : CustomFoodEdit.Model
failedModel =
    step (CustomFoodEdit.NutrientsLoaded (Err Client.NetworkError)) emptyModel


validLoadedModel : CustomFoodEdit.Model
validLoadedModel =
    let
        base : Form.FormModel
        base =
            Form.emptyForm
    in
    loadedWithForm
        { base
            | name = "Paneer"
            , brand = "Local"
            , categoryInput =
                { selected = [ "dairy" ]
                , query = ""
                , suggestions = []
                , token = ticket 0
                }
            , nutrients = [ { code = "PROTEIN_G", amount = "18", unit = "g" } ]
            , servings = [ { unit = "piece", gramsPerUnit = "50" } ]
        }


loadedWithForm : Form.FormModel -> CustomFoodEdit.Model
loadedWithForm form =
    CustomFoodEdit.Loaded
        { productId = "food-1"
        , form = form
        , nutrients = nutrientItems
        , units = [ gram ]
        }


validRequest : CreateFoodRequest
validRequest =
    { name = "Paneer"
    , brand = Just "Local"
    , categories = [ "dairy" ]
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , nutrients = [ { code = "PROTEIN_G", amountPer100g = 18 } ]
    , servings = [ { unit = "piece", gramsPerUnit = 50 } ]
    }


food : ProductDetail
food =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Curd"
    , brand = Just "Local"
    , categories = [ "dairy" ]
    , defaultQuantity = Just "1"
    , defaultUnit = Just "cup"
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    , nutrients = []
    , servings = []
    , allowedUnits = [ gram ]
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


nutrientItems : List NutrientItem
nutrientItems =
    [ { code = "ENERGY_KCAL"
      , name = "Energy"
      , unit = "kcal"
      , category = "energy"
      }
    , { code = "MONOUNSATURATED_FAT_G"
      , name = "Monounsaturated Fat"
      , unit = "g"
      , category = "macros"
      }
    ]


ticket : Int -> Ticket
ticket count =
    List.foldl (\_ value -> Ticket.next value) Ticket.initial (List.range 1 count)


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
