module Page.CustomFood.ShowTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Page.CustomFood.Show as CustomFoodShow
import Support.Fixtures as Fixtures
import Support.Story exposing (runSteps, runStepsResult)
import Test exposing (Test, describe, test)
import View.DeleteModal exposing (DeleteState(..))


tests : Test
tests =
    describe "Page.CustomFood.Show"
        [ test "confirm, cancel, confirm, then a failed delete retries and succeeds" <|
            \_ ->
                let
                    loaded : CustomFoodShow.Model
                    loaded =
                        CustomFoodShow.init "food-1"
                            |> Tuple.first
                            |> runSteps step
                                [ CustomFoodShow.FoodLoaded "food-1" (Ok food)
                                , CustomFoodShow.UnitsLoaded (Ok { items = [ gram ] })
                                ]

                    confirming : CustomFoodShow.Model
                    confirming =
                        step CustomFoodShow.DeleteClicked loaded

                    cancelled : CustomFoodShow.Model
                    cancelled =
                        step CustomFoodShow.CancelDeleteClicked confirming

                    reconfirming : CustomFoodShow.Model
                    reconfirming =
                        step CustomFoodShow.DeleteClicked cancelled

                    deleting : CustomFoodShow.Model
                    deleting =
                        step CustomFoodShow.ConfirmDeleteClicked reconfirming

                    failed : CustomFoodShow.Model
                    failed =
                        step
                            (CustomFoodShow.DeleteCompleted (Err Client.NetworkError))
                            deleting
                in
                case
                    runStepsResult stepWithOut
                        [ CustomFoodShow.ConfirmDeleteClicked
                        , CustomFoodShow.DeleteCompleted (Ok ())
                        ]
                        failed
                of
                    Ok ( final, [ retryOut, completionOut ] ) ->
                        { loaded = toScreen loaded
                        , confirming = toScreen confirming
                        , cancelled = toScreen cancelled
                        , pending = toScreen deleting
                        , duplicateConfirmOut =
                            out CustomFoodShow.ConfirmDeleteClicked deleting
                        , failed = toScreen failed
                        , lateDeleteOut =
                            out (CustomFoodShow.DeleteCompleted (Ok ())) failed
                        , retryOut = retryOut
                        , screen = toScreen final
                        , finalOut = completionOut
                        }
                            |> Expect.equal
                                { loaded =
                                    { name = "Apple", delete = closed, loadError = Nothing }
                                , confirming =
                                    { name = "Apple"
                                    , delete = confirmingDelete
                                    , loadError = Nothing
                                    }
                                , cancelled =
                                    { name = "Apple", delete = closed, loadError = Nothing }
                                , pending =
                                    { name = "Apple", delete = pendingDelete, loadError = Nothing }
                                , duplicateConfirmOut = CustomFoodShow.NoOp
                                , failed =
                                    { name = "Apple"
                                    , delete = failedDelete Fixtures.networkErrorMessage
                                    , loadError = Nothing
                                    }
                                , lateDeleteOut = CustomFoodShow.NoOp
                                , retryOut = CustomFoodShow.RequestDeleteCustomFood "food-1"
                                , screen =
                                    { name = "Apple", delete = pendingDelete, loadError = Nothing }
                                , finalOut = CustomFoodShow.Navigate CustomFoodList
                                }

                    Ok _ ->
                        Expect.fail "the delete retry produced unexpected out messages"

                    Err message ->
                        Expect.fail message
        , test "stale products and a failed load retry, then a 401 delete expires" <|
            \_ ->
                let
                    started : CustomFoodShow.Model
                    started =
                        CustomFoodShow.init "food-1" |> Tuple.first

                    failedLoad : CustomFoodShow.Model
                    failedLoad =
                        step
                            (CustomFoodShow.FoodLoaded "food-1" (Err Client.NetworkError))
                            started

                    lateLoad : CustomFoodShow.Model
                    lateLoad =
                        step (CustomFoodShow.FoodLoaded "food-1" (Ok food)) failedLoad

                    retried : CustomFoodShow.Model
                    retried =
                        step CustomFoodShow.RetryClicked lateLoad

                    staleBefore : CustomFoodShow.Model
                    staleBefore =
                        step (CustomFoodShow.FoodLoaded "other" (Ok otherFood)) retried

                    loaded : CustomFoodShow.Model
                    loaded =
                        staleBefore
                            |> runSteps step
                                [ CustomFoodShow.FoodLoaded "food-1" (Ok food)
                                , CustomFoodShow.UnitsLoaded (Ok { items = [ gram ] })
                                ]

                    staleAfter : CustomFoodShow.Model
                    staleAfter =
                        step (CustomFoodShow.FoodLoaded "other" (Ok otherFood)) loaded

                    expired : CustomFoodShow.Model
                    expired =
                        loaded
                            |> step CustomFoodShow.DeleteClicked
                            |> step CustomFoodShow.ConfirmDeleteClicked
                            |> step
                                (CustomFoodShow.DeleteCompleted (Err Fixtures.unauthorized))
                in
                { failedLoad = toScreen failedLoad
                , lateLoad = toScreen lateLoad
                , retried = toScreen retried
                , staleBefore = toScreen staleBefore
                , staleAfter = toScreen staleAfter
                , editOut = out CustomFoodShow.EditClicked loaded
                , screen = toScreen expired
                , finalOut =
                    out
                        (CustomFoodShow.DeleteCompleted (Err Fixtures.unauthorized))
                        (loaded
                            |> step CustomFoodShow.DeleteClicked
                            |> step CustomFoodShow.ConfirmDeleteClicked
                        )
                }
                    |> Expect.equal
                        { failedLoad =
                            { name = ""
                            , delete = closed
                            , loadError = Just Fixtures.networkErrorMessage
                            }
                        , lateLoad =
                            { name = ""
                            , delete = closed
                            , loadError = Just Fixtures.networkErrorMessage
                            }
                        , retried =
                            { name = "", delete = closed, loadError = Nothing }
                        , staleBefore =
                            { name = "", delete = closed, loadError = Nothing }
                        , staleAfter =
                            { name = "Apple", delete = closed, loadError = Nothing }
                        , editOut =
                            CustomFoodShow.Navigate (CustomFoodEdit "food-1")
                        , screen =
                            { name = "Apple"
                            , delete = failedDelete "Sign in again"
                            , loadError = Nothing
                            }
                        , finalOut = CustomFoodShow.SessionExpired
                        }
        ]


type alias Screen =
    { name : String
    , delete : DeleteView
    , loadError : Maybe String
    }


type alias DeleteView =
    { open : Bool
    , pending : Bool
    , cancelDisabled : Bool
    , error : Maybe String
    }


toScreen : CustomFoodShow.Model -> Screen
toScreen model =
    case model of
        CustomFoodShow.Loaded loaded ->
            { name = loaded.food.name
            , delete = deleteView loaded.delete
            , loadError = Nothing
            }

        CustomFoodShow.LoadFailed failed ->
            { name = "", delete = closed, loadError = Just failed.message }

        CustomFoodShow.Loading _ ->
            { name = "", delete = closed, loadError = Nothing }


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


step : CustomFoodShow.Msg -> CustomFoodShow.Model -> CustomFoodShow.Model
step msg model =
    Fixtures.tupleFirst (CustomFoodShow.update msg model)


stepWithOut :
    CustomFoodShow.Msg
    -> CustomFoodShow.Model
    -> Maybe ( CustomFoodShow.Model, CustomFoodShow.OutMsg )
stepWithOut msg model =
    let
        ( next, _, outMsg ) =
            CustomFoodShow.update msg model
    in
    if next == model && outMsg == CustomFoodShow.NoOp then
        Nothing

    else
        Just ( next, outMsg )


out : CustomFoodShow.Msg -> CustomFoodShow.Model -> CustomFoodShow.OutMsg
out msg model =
    Fixtures.tupleThird (CustomFoodShow.update msg model)


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


otherFood : ProductDetail
otherFood =
    { food | id = "food-2", name = "Ghee" }


gram : UnitItem
gram =
    { code = "g", name = "Gram", kind = "mass" }
