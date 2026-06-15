module Page.CustomFood.ShowTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Page.CustomFood.Show as CustomFoodShow
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.CustomFood.Show"
        [ test "edit action navigates to custom food edit" <|
            \_ ->
                CustomFoodShow.update CustomFoodShow.EditClicked loadedModel
                    |> third
                    |> Expect.equal (CustomFoodShow.Navigate (CustomFoodEdit "food-1"))
        , test "delete click opens confirmation state" <|
            \_ ->
                CustomFoodShow.update CustomFoodShow.DeleteClicked loadedModel
                    |> first
                    |> deleteStateOf
                    |> Expect.equal (Just CustomFoodShow.DeleteConfirming)
        , test "delete confirm requests food deletion" <|
            \_ ->
                CustomFoodShow.update CustomFoodShow.DeleteClicked loadedModel
                    |> first
                    |> CustomFoodShow.update CustomFoodShow.ConfirmDeleteClicked
                    |> third
                    |> Expect.equal (CustomFoodShow.RequestDeleteCustomFood "food-1")
        , test "delete failure keeps confirmation state open with error" <|
            \_ ->
                CustomFoodShow.update
                    (CustomFoodShow.DeleteCompleted (Err Client.NetworkError))
                    deletingModel
                    |> first
                    |> deleteStateOf
                    |> Expect.equal (Just (CustomFoodShow.DeleteFailed "Network error"))
        ]


loadedModel : CustomFoodShow.Model
loadedModel =
    CustomFoodShow.Loaded
        { productId = "food-1"
        , food = food
        , units = []
        , delete = CustomFoodShow.DeleteIdle
        }


deletingModel : CustomFoodShow.Model
deletingModel =
    CustomFoodShow.Loaded
        { productId = "food-1"
        , food = food
        , units = []
        , delete = CustomFoodShow.Deleting
        }


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
    , servingSizeG = Just "100"
    , nutritionSummary = { per100g = Nutrition.emptySummary, perServing = Nothing }
    , nutrients = []
    , servings = []
    , allowedUnits = []
    }


deleteStateOf : CustomFoodShow.Model -> Maybe CustomFoodShow.DeleteState
deleteStateOf model =
    case model of
        CustomFoodShow.Loaded loaded ->
            Just loaded.delete

        _ ->
            Nothing


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
