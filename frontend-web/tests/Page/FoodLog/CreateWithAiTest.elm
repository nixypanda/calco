module Page.FoodLog.CreateWithAiTest exposing (tests)

import Api.Client as Client
import Api.Foods exposing (NutrientItem)
import Data.FoodAssistant exposing (FoodDraftTurn(..))
import Expect
import Page.Food.Assistant as Assistant
import Page.Food.Editor as Editor
import Page.FoodLog.CreateAdHoc as Review
import Page.FoodLog.CreateWithAi as CreateWithAi
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.FoodLog.CreateWithAi"
        [ test "a completed estimate becomes an editable portion review" <|
            \_ ->
                reviewedModel
                    |> .review
                    |> Maybe.map
                        (\review ->
                            ( review.form.name
                            , Editor.logPortionWeight review.form
                            , List.map .amount review.form.nutrients
                            )
                        )
                    |> Expect.equal
                        (Just
                            ( "Paneer wrap"
                            , Just "250"
                            , [ "500", "25", "50", "30", "12.5" ]
                            )
                        )
        , test "save-off review submits only an ad-hoc log" <|
            \_ ->
                reviewedModel
                    |> CreateWithAi.update (CreateWithAi.ReviewMsg Review.SubmitClicked)
                    |> third
                    |> (\outMsg ->
                            case outMsg of
                                CreateWithAi.RequestAdHocLog request ->
                                    Expect.equal
                                        ( request.name, request.quantity.amount )
                                        ( "Paneer wrap", "1" )

                                _ ->
                                    Expect.fail "expected an ad-hoc log request"
                       )
        , test "save-on review creates a custom food first" <|
            \_ ->
                reviewedModel
                    |> CreateWithAi.update
                        (CreateWithAi.ReviewMsg
                            (Review.FormMsg Editor.LogPersistenceToggled)
                        )
                    |> first
                    |> CreateWithAi.update (CreateWithAi.ReviewMsg Review.SubmitClicked)
                    |> third
                    |> (\outMsg ->
                            case outMsg of
                                CreateWithAi.RequestCreateFood request ->
                                    Expect.equal
                                        ( request.categories, request.servings )
                                        ( [ "wrap" ]
                                        , [ { unit = "serving", gramsPerUnit = 250 }
                                          , { unit = "piece", gramsPerUnit = 125 }
                                          ]
                                        )

                                _ ->
                                    Expect.fail "expected a custom-food request"
                       )
        , test "retry after a product-log failure reuses the saved food id" <|
            \_ ->
                let
                    saving : CreateWithAi.Model
                    saving =
                        reviewedModel
                            |> CreateWithAi.update
                                (CreateWithAi.ReviewMsg
                                    (Review.FormMsg Editor.LogPersistenceToggled)
                                )
                            |> first
                            |> CreateWithAi.update
                                (CreateWithAi.ReviewMsg Review.SubmitClicked)
                            |> first

                    logging : CreateWithAi.Model
                    logging =
                        saving
                            |> CreateWithAi.update
                                (CreateWithAi.ReviewMsg
                                    (Review.CustomFoodCompleted (Ok { id = "food-1" }))
                                )
                            |> first

                    failed : CreateWithAi.Model
                    failed =
                        logging
                            |> CreateWithAi.update
                                (CreateWithAi.ReviewMsg
                                    (Review.ProductLogCompleted (Err Client.NetworkError))
                                )
                            |> first
                in
                failed
                    |> CreateWithAi.update
                        (CreateWithAi.ReviewMsg Review.SubmitClicked)
                    |> third
                    |> (\outMsg ->
                            case outMsg of
                                CreateWithAi.RequestProductLog request ->
                                    Expect.equal request.item.id "food-1"

                                _ ->
                                    Expect.fail "retry should log the existing product"
                       )
        ]


reviewedModel : CreateWithAi.Model
reviewedModel =
    let
        initial : CreateWithAi.Model
        initial =
            CreateWithAi.init (Just "2026-09-14") Nothing |> Tuple.first
    in
    initial
        |> CreateWithAi.update
            (CreateWithAi.NutrientsLoaded (Ok { items = catalog }))
        |> first
        |> CreateWithAi.update
            (CreateWithAi.UnitsLoaded
                (Ok
                    { items =
                        [ { code = "g", name = "Gram", kind = "mass" }
                        , { code = "serving", name = "Serving", kind = "serving" }
                        , { code = "piece", name = "Piece", kind = "serving" }
                        ]
                    }
                )
            )
        |> first
        |> CreateWithAi.update
            (CreateWithAi.AssistantMsg
                (Assistant.StatusLoaded (Ok { enabled = True, supportsImages = True }))
            )
        |> first
        |> CreateWithAi.update
            (CreateWithAi.AssistantMsg (Assistant.DraftCompleted (Ok readyTurn)))
        |> first
        |> CreateWithAi.update
            (CreateWithAi.AssistantMsg (Assistant.ApplyDraftClicked False))
        |> first


readyTurn : FoodDraftTurn
readyTurn =
    DraftReady
        { assistantMessage = "Review this estimate."
        , draft =
            { name = "Paneer wrap"
            , brand = Nothing
            , categories = [ "wrap" ]
            , defaultQuantity = Just "1"
            , defaultUnit = Just "serving"
            , nutrients =
                [ { code = "ENERGY_KCAL", amountPer100g = "200" }
                , { code = "PROTEIN_G", amountPer100g = "10" }
                , { code = "CARBS_G", amountPer100g = "20" }
                , { code = "FAT_G", amountPer100g = "12" }
                , { code = "FIBER_G", amountPer100g = "5" }
                ]
            , servings =
                [ { unit = "serving", gramsPerUnit = "250" }
                , { unit = "piece", gramsPerUnit = "125" }
                ]
            }
        , suggestedLog =
            Just { amount = "1", unit = "serving", totalWeightGrams = "250" }
        , warnings = [ "Estimated from description" ]
        }


catalog : List NutrientItem
catalog =
    [ nutrient "ENERGY_KCAL" "Calories" "kcal"
    , nutrient "PROTEIN_G" "Protein" "g"
    , nutrient "CARBS_G" "Carbohydrates" "g"
    , nutrient "FAT_G" "Fat" "g"
    , nutrient "FIBER_G" "Fiber" "g"
    ]


nutrient : String -> String -> String -> NutrientItem
nutrient code name unit =
    { code = code, name = name, unit = unit, category = "Core" }


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
