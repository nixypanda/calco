module Page.Meal.ShowTest exposing (tests)

import Api.Meals exposing (Meal, MealNutritionResponse)
import Data.ItemRef as ItemRef
import Data.Nutrition as Nutrition exposing (NutrientAmount)
import Data.Route exposing (Route(..))
import Expect
import Page.Meal.Show as MealShow
import Support.Story as Story
import Test exposing (Test, describe, test)
import View.Nutrients exposing (NutritionState(..))


tests : Test
tests =
    describe "Page.Meal.Show"
        [ test "a user opens a meal and edits it" <|
            \_ ->
                loadedMeal
                    |> step MealShow.EditClicked
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (MealShow.Navigate (MealEdit "meal-1"))
                        )
        , test "changing the amount updates the nutrition preview" <|
            \_ ->
                loadedMeal
                    |> step (MealShow.AmountChanged "150")
                    |> bind
                        (\out ->
                            case out of
                                MealShow.RequestNutrientPreview mealId amount unit ->
                                    Ok
                                        (MealShow.NutrientPreviewLoaded mealId
                                            (Ok (previewFor amount unit [ scaledNutrient ]))
                                        )

                                _ ->
                                    Err "the amount change produced no nutrition request"
                        )
                    |> finish
                        (\( model, _ ) ->
                            nutritionScreen model
                                |> Expect.equal
                                    { name = "Lunch"
                                    , amount = "150"
                                    , unit = "g"
                                    , nutrients = [ "ENERGY_KCAL:180" ]
                                    , error = Nothing
                                    }
                        )
        , test "a user deletes a meal" <|
            \_ ->
                loadedMeal
                    |> step MealShow.DeleteClicked
                    |> step MealShow.ConfirmDeleteClicked
                    |> step (MealShow.DeleteCompleted (Ok ()))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal (MealShow.Navigate MealList)
                        )
        ]


type alias NutritionScreen =
    { name : String
    , amount : String
    , unit : String
    , nutrients : List String
    , error : Maybe String
    }


nutritionScreen : MealShow.Model -> NutritionScreen
nutritionScreen model =
    case model of
        MealShow.Loaded loaded ->
            let
                ( amount, unit ) =
                    nutritionFields loaded.nutrition
            in
            { name = loaded.meal.name
            , amount = amount
            , unit = unit
            , nutrients = nutritionAmounts loaded.nutrition
            , error = nutritionFailure loaded.nutrition
            }

        _ ->
            { name = "", amount = "", unit = "", nutrients = [], error = Nothing }


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



-- STORY PIPELINE


type alias Journey =
    Story.Journey MealShow.Model MealShow.OutMsg


step : MealShow.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd MealShow.update)


bind :
    (MealShow.OutMsg -> Result String MealShow.Msg)
    -> Journey
    -> Journey
bind =
    Story.bind (Story.ignoreCmd MealShow.update)


finish :
    (( MealShow.Model, MealShow.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


loadedMeal : Journey
loadedMeal =
    MealShow.init "meal-1" |> Story.start |> step (MealShow.MealLoaded "meal-1" (Ok meal))


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


scaledNutrient : NutrientAmount
scaledNutrient =
    { code = "ENERGY_KCAL", amount = "180", unit = "kcal" }
