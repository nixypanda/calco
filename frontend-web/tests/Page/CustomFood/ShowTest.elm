module Page.CustomFood.ShowTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (ProductDetail, UnitItem)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Expect
import Page.CustomFood.Show as CustomFoodShow
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.CustomFood.Show"
        [ test "a user opens a food and edits it" <|
            \_ ->
                loadedFood
                    |> step CustomFoodShow.EditClicked
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal
                                    (CustomFoodShow.Navigate (CustomFoodEdit "food-1"))
                        )
        , test "a user deletes a food" <|
            \_ ->
                loadedFood
                    |> step CustomFoodShow.DeleteClicked
                    |> step CustomFoodShow.ConfirmDeleteClicked
                    |> step (CustomFoodShow.DeleteCompleted (Ok ()))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (CustomFoodShow.Navigate CustomFoodList)
                        )
        , test "a failed delete can be retried" <|
            \_ ->
                loadedFood
                    |> step CustomFoodShow.DeleteClicked
                    |> step CustomFoodShow.ConfirmDeleteClicked
                    |> step (CustomFoodShow.DeleteCompleted (Err Client.NetworkError))
                    |> step CustomFoodShow.ConfirmDeleteClicked
                    |> step (CustomFoodShow.DeleteCompleted (Ok ()))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (CustomFoodShow.Navigate CustomFoodList)
                        )
        ]



-- STORY PIPELINE


type alias Journey =
    Story.Journey CustomFoodShow.Model CustomFoodShow.OutMsg


step : CustomFoodShow.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd CustomFoodShow.update)


finish :
    (( CustomFoodShow.Model, CustomFoodShow.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


loadedFood : Journey
loadedFood =
    CustomFoodShow.init "food-1"
        |> Story.start
        |> step (CustomFoodShow.FoodLoaded "food-1" (Ok food))
        |> step (CustomFoodShow.UnitsLoaded (Ok { items = [ gram ] }))


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
