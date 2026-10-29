module Page.CustomFood.ListTest exposing (tests)

import Api.Foods exposing (ProductDetail)
import Data.Route exposing (Route(..))
import Expect
import Page.CustomFood.List as CustomFoodList
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.CustomFood.List"
        [ test "a loaded list opens a food" <|
            \_ ->
                loadedList
                    |> step (CustomFoodList.OpenFoodClicked "food-1")
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal
                                    (CustomFoodList.Navigate (CustomFoodShow "food-1"))
                        )
        , test "a loaded list starts manual food creation" <|
            \_ ->
                loadedList
                    |> step CustomFoodList.CreateManuallyClicked
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal (CustomFoodList.Navigate CustomFoodCreate)
                        )
        , test "a loaded list starts AI food creation" <|
            \_ ->
                loadedList
                    |> step CustomFoodList.CreateWithAiClicked
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg
                                |> Expect.equal
                                    (CustomFoodList.Navigate CustomFoodCreateWithAi)
                        )
        ]



-- STORY PIPELINE


type alias Journey =
    Story.Journey CustomFoodList.Model CustomFoodList.OutMsg


step : CustomFoodList.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd CustomFoodList.update)


finish :
    (( CustomFoodList.Model, CustomFoodList.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


loadedList : Journey
loadedList =
    CustomFoodList.init
        |> Story.start
        |> step (CustomFoodList.FoodsLoaded (Ok { items = [ food ] }))


food : ProductDetail
food =
    { id = "food-1"
    , source = "USER"
    , sourceId = Nothing
    , visibility = "private"
    , barcode = Nothing
    , name = "Paneer"
    , brand = Just "Local"
    , categories = []
    , defaultQuantity = Nothing
    , defaultUnit = Nothing
    , nutritionSummary =
        { per100g =
            { energyKcal = Just "120"
            , proteinG = Nothing
            , carbsG = Nothing
            , fatG = Nothing
            , fiberG = Nothing
            }
        }
    , nutrients = []
    , servings = []
    , allowedUnits = []
    }
