module Page.CustomFood.ShowTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Page.CustomFood.Show as CustomFoodShow
import Test exposing (Test, describe, test)
import View.DeleteModal exposing (DeleteState(..))


tests : Test
tests =
    describe "Page.CustomFood.Show"
        [ test "init requests initial data" <|
            \_ ->
                CustomFoodShow.init "food-1"
                    |> Tuple.second
                    |> Expect.equal (CustomFoodShow.RequestInitialData "food-1")
        , test "food then units load completes model" <|
            \_ ->
                CustomFoodShow.init "food-1"
                    |> Tuple.first
                    |> CustomFoodShow.update (CustomFoodShow.FoodLoaded (Ok food))
                    |> first
                    |> CustomFoodShow.update (CustomFoodShow.UnitsLoaded (Ok { items = [ gram ] }))
                    |> first
                    |> loadedSummary
                    |> Expect.equal (Just ( "food-1", [ gram ], DeleteIdle ))
        , test "units then food load completes model" <|
            \_ ->
                CustomFoodShow.init "food-1"
                    |> Tuple.first
                    |> CustomFoodShow.update (CustomFoodShow.UnitsLoaded (Ok { items = [ gram ] }))
                    |> first
                    |> CustomFoodShow.update (CustomFoodShow.FoodLoaded (Ok food))
                    |> first
                    |> loadedSummary
                    |> Expect.equal (Just ( "food-1", [ gram ], DeleteIdle ))
        , test "food load refreshes loaded food and clears delete state" <|
            \_ ->
                CustomFoodShow.update
                    (CustomFoodShow.FoodLoaded (Ok { food | name = "Pear" }))
                    (CustomFoodShow.Loaded
                        { loadedModelRecord
                            | delete = DeleteFailed "old"
                        }
                    )
                    |> first
                    |> loadedFoodNameAndDelete
                    |> Expect.equal (Just ( "Pear", DeleteIdle ))
        , test "unit load refreshes loaded units" <|
            \_ ->
                CustomFoodShow.update
                    (CustomFoodShow.UnitsLoaded (Ok { items = [ gram ] }))
                    loadedModel
                    |> first
                    |> loadedSummary
                    |> Expect.equal (Just ( "food-1", [ gram ], DeleteIdle ))
        , test "load failure stores error" <|
            \_ ->
                CustomFoodShow.update
                    (CustomFoodShow.FoodLoaded (Err Client.NetworkError))
                    (Tuple.first (CustomFoodShow.init "food-1"))
                    |> first
                    |> Expect.equal (CustomFoodShow.LoadFailed "Network error")
        , test "load unauthorized expires session" <|
            \_ ->
                CustomFoodShow.update
                    (CustomFoodShow.UnitsLoaded
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    (Tuple.first (CustomFoodShow.init "food-1"))
                    |> third
                    |> Expect.equal CustomFoodShow.SessionExpired
        , test "load success is ignored after load failed" <|
            \_ ->
                CustomFoodShow.update
                    (CustomFoodShow.FoodLoaded (Ok food))
                    (CustomFoodShow.LoadFailed "old")
                    |> first
                    |> Expect.equal (CustomFoodShow.LoadFailed "old")
        , test "edit action navigates to custom food edit" <|
            \_ ->
                CustomFoodShow.update CustomFoodShow.EditClicked loadedModel
                    |> third
                    |> Expect.equal (CustomFoodShow.Navigate (CustomFoodEdit "food-1"))
        , test "edit action is no-op for non-user food" <|
            \_ ->
                CustomFoodShow.update
                    CustomFoodShow.EditClicked
                    (loadedWithFood { food | source = "IFCT" })
                    |> third
                    |> Expect.equal CustomFoodShow.NoOp
        , test "delete click opens confirmation state" <|
            \_ ->
                CustomFoodShow.update CustomFoodShow.DeleteClicked loadedModel
                    |> first
                    |> deleteStateOf
                    |> Expect.equal (Just DeleteConfirming)
        , test "cancel delete returns to idle" <|
            \_ ->
                CustomFoodShow.update
                    CustomFoodShow.CancelDeleteClicked
                    (CustomFoodShow.Loaded
                        { loadedModelRecord | delete = DeleteConfirming }
                    )
                    |> first
                    |> deleteStateOf
                    |> Expect.equal (Just DeleteIdle)
        , test "delete confirm requests food deletion" <|
            \_ ->
                CustomFoodShow.update CustomFoodShow.DeleteClicked loadedModel
                    |> first
                    |> CustomFoodShow.update CustomFoodShow.ConfirmDeleteClicked
                    |> third
                    |> Expect.equal (CustomFoodShow.RequestDeleteCustomFood "food-1")
        , test "delete confirm retries after failure" <|
            \_ ->
                CustomFoodShow.update
                    CustomFoodShow.ConfirmDeleteClicked
                    (CustomFoodShow.Loaded
                        { loadedModelRecord
                            | delete = DeleteFailed "Try again"
                        }
                    )
                    |> third
                    |> Expect.equal (CustomFoodShow.RequestDeleteCustomFood "food-1")
        , test "delete confirm is no-op unless confirming or failed" <|
            \_ ->
                CustomFoodShow.update CustomFoodShow.ConfirmDeleteClicked loadedModel
                    |> third
                    |> Expect.equal CustomFoodShow.NoOp
        , test "delete success navigates to custom food list" <|
            \_ ->
                CustomFoodShow.update
                    (CustomFoodShow.DeleteCompleted (Ok ()))
                    deletingModel
                    |> third
                    |> Expect.equal (CustomFoodShow.Navigate CustomFoodList)
        , test "delete failure keeps confirmation state open with error" <|
            \_ ->
                CustomFoodShow.update
                    (CustomFoodShow.DeleteCompleted (Err Client.NetworkError))
                    deletingModel
                    |> first
                    |> deleteStateOf
                    |> Expect.equal (Just (DeleteFailed "Network error"))
        , test "delete unauthorized expires session" <|
            \_ ->
                CustomFoodShow.update
                    (CustomFoodShow.DeleteCompleted
                        (Err (Client.BadStatus 401 "unauthorized" "Sign in again"))
                    )
                    deletingModel
                    |> third
                    |> Expect.equal CustomFoodShow.SessionExpired
        , test "delete completion is ignored unless deleting" <|
            \_ ->
                CustomFoodShow.update
                    (CustomFoodShow.DeleteCompleted (Ok ()))
                    loadedModel
                    |> third
                    |> Expect.equal CustomFoodShow.NoOp
        ]


loadedModel : CustomFoodShow.Model
loadedModel =
    CustomFoodShow.Loaded
        loadedModelRecord


loadedModelRecord : CustomFoodShow.LoadedModel
loadedModelRecord =
    { productId = "food-1"
    , food = food
    , units = []
    , delete = DeleteIdle
    }


deletingModel : CustomFoodShow.Model
deletingModel =
    CustomFoodShow.Loaded
        { loadedModelRecord | delete = Deleting }


loadedWithFood : ProductDetail -> CustomFoodShow.Model
loadedWithFood nextFood =
    CustomFoodShow.Loaded { loadedModelRecord | food = nextFood }


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


deleteStateOf : CustomFoodShow.Model -> Maybe DeleteState
deleteStateOf model =
    case model of
        CustomFoodShow.Loaded loaded ->
            Just loaded.delete

        _ ->
            Nothing


loadedSummary :
    CustomFoodShow.Model
    -> Maybe ( String, List UnitItem, DeleteState )
loadedSummary model =
    case model of
        CustomFoodShow.Loaded loaded ->
            Just ( loaded.productId, loaded.units, loaded.delete )

        _ ->
            Nothing


loadedFoodNameAndDelete :
    CustomFoodShow.Model
    -> Maybe ( String, DeleteState )
loadedFoodNameAndDelete model =
    case model of
        CustomFoodShow.Loaded loaded ->
            Just ( loaded.food.name, loaded.delete )

        _ ->
            Nothing


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
