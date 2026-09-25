module Page.CustomFood.ShowTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Page.CustomFood.Show as CustomFoodShow
import Test exposing (Test, describe, test)
import View.DeleteModal exposing (DeleteState(..))


networkErrorMessage : String
networkErrorMessage =
    "Could not reach the server. Check your connection and try again."


tests : Test
tests =
    describe "Page.CustomFood.Show"
        [ test "loading a custom food composes the food and unit loads into the detail screen" <|
            \_ ->
                let
                    ( loading, initialRequest ) =
                        CustomFoodShow.init "food-1"

                    afterFood : CustomFoodShow.Model
                    afterFood =
                        step (CustomFoodShow.FoodLoaded "food-1" (Ok food)) loading

                    loaded : CustomFoodShow.Model
                    loaded =
                        step (CustomFoodShow.UnitsLoaded (Ok { items = [ gram ] })) afterFood
                in
                { initialRequest = initialRequest
                , loadingPhase = toScreen loading |> .phase
                , partialPhase = toScreen afterFood |> .phase
                , loaded = toScreen loaded
                }
                    |> Expect.equal
                        { initialRequest = CustomFoodShow.RequestInitialData "food-1"
                        , loadingPhase = "loading"
                        , partialPhase = "loading"
                        , loaded =
                            { phase = "loaded"
                            , name = Just "Apple"
                            , units = Just [ gram ]
                            , delete = Just DeleteIdle
                            , error = Nothing
                            }
                        }
        , test "a failed load can be retried and an unauthorized load expires the session" <|
            \_ ->
                let
                    failed : CustomFoodShow.Model
                    failed =
                        step
                            (CustomFoodShow.FoodLoaded "food-1" (Err Client.NetworkError))
                            emptyModel

                    retried : CustomFoodShow.Model
                    retried =
                        step CustomFoodShow.RetryClicked failed
                in
                { failedScreen = toScreen failed
                , retryRequest = out CustomFoodShow.RetryClicked failed
                , retriedPhase = toScreen retried |> .phase
                , unauthorized =
                    out
                        (CustomFoodShow.UnitsLoaded
                            (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                        )
                        emptyModel
                }
                    |> Expect.equal
                        { failedScreen =
                            { phase = "failed"
                            , name = Nothing
                            , units = Nothing
                            , delete = Nothing
                            , error = Just networkErrorMessage
                            }
                        , retryRequest = CustomFoodShow.RequestInitialData "food-1"
                        , retriedPhase = "loading"
                        , unauthorized = CustomFoodShow.SessionExpired
                        }
        , test "a response for another product or after a failure is ignored" <|
            \_ ->
                let
                    otherProduct : CustomFoodShow.Model
                    otherProduct =
                        step (CustomFoodShow.FoodLoaded "other" (Ok food)) loadedModel

                    lateSuccess : CustomFoodShow.Model
                    lateSuccess =
                        step (CustomFoodShow.FoodLoaded "food-1" (Ok food)) failedModel
                in
                { otherProductScreen = toScreen otherProduct
                , lateSuccessScreen = toScreen lateSuccess
                }
                    |> Expect.equal
                        { otherProductScreen = toScreen loadedModel
                        , lateSuccessScreen = toScreen failedModel
                        }
        , test "edit is offered only for user foods and navigates to the editor" <|
            \_ ->
                { userEdit = out CustomFoodShow.EditClicked loadedModel
                , catalogEdit =
                    out CustomFoodShow.EditClicked (loadedWithFood { food | source = "IFCT" })
                }
                    |> Expect.equal
                        { userEdit = CustomFoodShow.Navigate (CustomFoodEdit "food-1")
                        , catalogEdit = CustomFoodShow.NoOp
                        }
        , test "deleting a user food confirms, can be cancelled, and navigates to the list" <|
            \_ ->
                let
                    confirming : CustomFoodShow.Model
                    confirming =
                        step CustomFoodShow.DeleteClicked loadedModel

                    cancelled : CustomFoodShow.Model
                    cancelled =
                        step CustomFoodShow.CancelDeleteClicked confirming

                    reconfirmed : CustomFoodShow.Model
                    reconfirmed =
                        step CustomFoodShow.DeleteClicked cancelled

                    requested : CustomFoodShow.Model
                    requested =
                        step CustomFoodShow.ConfirmDeleteClicked reconfirmed

                    completed : CustomFoodShow.Model
                    completed =
                        step (CustomFoodShow.DeleteCompleted (Ok ())) requested
                in
                { confirming = toScreen confirming |> .delete
                , cancelRequest = out CustomFoodShow.CancelDeleteClicked confirming
                , cancelled = toScreen cancelled |> .delete
                , deleteRequest = out CustomFoodShow.ConfirmDeleteClicked reconfirmed
                , deleteCompleted = out (CustomFoodShow.DeleteCompleted (Ok ())) requested
                , completedPhase = toScreen completed |> .phase
                }
                    |> Expect.equal
                        { confirming = Just DeleteConfirming
                        , cancelRequest = CustomFoodShow.NoOp
                        , cancelled = Just DeleteIdle
                        , deleteRequest = CustomFoodShow.RequestDeleteCustomFood "food-1"
                        , deleteCompleted = CustomFoodShow.Navigate CustomFoodList
                        , completedPhase = "loaded"
                        }
        , test "a failed delete keeps the confirmation open and retrying reissues the request" <|
            \_ ->
                let
                    deleting : CustomFoodShow.Model
                    deleting =
                        step CustomFoodShow.DeleteClicked loadedModel
                            |> step CustomFoodShow.ConfirmDeleteClicked

                    failed : CustomFoodShow.Model
                    failed =
                        step (CustomFoodShow.DeleteCompleted (Err Client.NetworkError)) deleting
                in
                { afterFailure = toScreen failed
                , retryRequest = out CustomFoodShow.ConfirmDeleteClicked failed
                , idleCompletion = out (CustomFoodShow.DeleteCompleted (Ok ())) loadedModel
                }
                    |> Expect.equal
                        { afterFailure =
                            { phase = "loaded"
                            , name = Just "Apple"
                            , units = Just []
                            , delete = Just (DeleteFailed networkErrorMessage)
                            , error = Nothing
                            }
                        , retryRequest = CustomFoodShow.RequestDeleteCustomFood "food-1"
                        , idleCompletion = CustomFoodShow.NoOp
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { phase : String
    , name : Maybe String
    , units : Maybe (List UnitItem)
    , delete : Maybe DeleteState
    , error : Maybe String
    }


toScreen : CustomFoodShow.Model -> Screen
toScreen model =
    case model of
        CustomFoodShow.Loaded loaded ->
            { phase = "loaded"
            , name = Just loaded.food.name
            , units = Just loaded.units
            , delete = Just loaded.delete
            , error = Nothing
            }

        CustomFoodShow.Loading _ ->
            { phase = "loading"
            , name = Nothing
            , units = Nothing
            , delete = Nothing
            , error = Nothing
            }

        CustomFoodShow.LoadFailed failed ->
            { phase = "failed"
            , name = Nothing
            , units = Nothing
            , delete = Nothing
            , error = Just failed.message
            }


step : CustomFoodShow.Msg -> CustomFoodShow.Model -> CustomFoodShow.Model
step msg model =
    first (CustomFoodShow.update msg model)


out : CustomFoodShow.Msg -> CustomFoodShow.Model -> CustomFoodShow.OutMsg
out msg model =
    third (CustomFoodShow.update msg model)


emptyModel : CustomFoodShow.Model
emptyModel =
    Tuple.first (CustomFoodShow.init "food-1")


loadedModel : CustomFoodShow.Model
loadedModel =
    step (CustomFoodShow.FoodLoaded "food-1" (Ok food)) emptyModel
        |> step (CustomFoodShow.UnitsLoaded (Ok { items = [] }))


loadedWithFood : ProductDetail -> CustomFoodShow.Model
loadedWithFood nextFood =
    step (CustomFoodShow.FoodLoaded "food-1" (Ok nextFood)) emptyModel
        |> step (CustomFoodShow.UnitsLoaded (Ok { items = [] }))


failedModel : CustomFoodShow.Model
failedModel =
    step (CustomFoodShow.FoodLoaded "food-1" (Err Client.NetworkError)) emptyModel


food : ProductDetail
food =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Apple"
    , brand = Just "Local"
    , categories = [ "fruit" ]
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , nutritionSummary = { per100g = Nutrition.emptySummary }
    , nutrients = []
    , servings = []
    , allowedUnits = []
    }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
