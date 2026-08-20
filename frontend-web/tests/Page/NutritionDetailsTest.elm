module Page.NutritionDetailsTest exposing (tests)

import Data.Route exposing (Route(..))
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.NutritionDetails as NutritionDetails
import Test exposing (Test, describe, test)
import Time


tests : Test
tests =
    describe "Page.NutritionDetails"
        [ test "next day does nothing when the report is for today" <|
            \_ ->
                initModel today
                    |> NutritionDetails.update NutritionDetails.NextDayClicked
                    |> third
                    |> Expect.equal NutritionDetails.NoOp
        , test "a day that rolls over stops being the last navigable one" <|
            \_ ->
                initModel today
                    |> NutritionDetails.update (NutritionDetails.TodayChanged tomorrow)
                    |> first
                    |> NutritionDetails.update NutritionDetails.NextDayClicked
                    |> third
                    |> Expect.equal
                        (NutritionDetails.Navigate
                            (NutritionDetails (Just "2026-05-31"))
                        )
        ]


initModel : LocalDate -> NutritionDetails.Model
initModel currentDate =
    NutritionDetails.init { date = currentDate, today = today }
        |> Tuple.first


today : LocalDate
today =
    date "2026-05-30"


tomorrow : LocalDate
tomorrow =
    date "2026-05-31"


date : String -> LocalDate
date raw =
    case LocalDate.fromString raw of
        Just value ->
            value

        Nothing ->
            LocalDate.fromPosix Time.utc (Time.millisToPosix 0)


first : ( a, b, c ) -> a
first ( value, _, _ ) =
    value


third : ( a, b, c ) -> c
third ( _, _, value ) =
    value
