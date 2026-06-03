module NutritionTest exposing (tests)

import Data.Nutrition as Nutrition
import Expect
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Nutrition.safeAmount"
        [ test "parses valid amounts" <|
            \_ ->
                Nutrition.safeAmount "12.5"
                    |> Expect.within (Expect.Absolute 0.0001) 12.5
        , test "invalid amounts become zero" <|
            \_ ->
                Nutrition.safeAmount "nope"
                    |> Expect.equal 0
        , test "negative amounts become zero" <|
            \_ ->
                Nutrition.safeAmount "-1"
                    |> Expect.equal 0
        ]
