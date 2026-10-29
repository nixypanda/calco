module Page.NutritionDetailsTest exposing (tests)

import Api.Client as Client
import Data.NutritionDetails as Details
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Page.NutritionDetails as N
import Support.Fixtures as Fixtures
import Support.Story as Story
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Page.NutritionDetails"
        [ test "a user pages days and clamps at today" <|
            \_ ->
                Story.start (N.init { date = today, today = today })
                    |> step (N.NutritionDetailsLoaded today (Ok reportToday))
                    |> step (N.NutrientAdviceToggled "FIBER_G")
                    |> step (N.NutrientAdviceToggled "FIBER_G")
                    |> step N.PreviousDayClicked
                    |> step (N.NutritionDetailsLoaded today (Ok reportToday))
                    |> step (N.NutritionDetailsLoaded yesterday (Ok reportYesterday))
                    |> step N.NextDayClicked
                    |> step (N.NutritionDetailsLoaded today (Ok reportToday))
                    |> step N.NextDayClicked
                    |> finish
                        (\( model, outMsg ) ->
                            { date = LocalDate.format (dateOf model)
                            , finalOut = outMsg
                            }
                                |> Expect.equal { date = "2026-08-18", finalOut = N.NoOp }
                        )
        , test "a failed load recovers and a 401 expires" <|
            \_ ->
                Story.start (N.init { date = today, today = today })
                    |> step (N.NutritionDetailsLoaded today (Err Client.NetworkError))
                    |> step N.PreviousDayClicked
                    |> step (N.NutritionDetailsLoaded yesterday (Ok reportYesterday))
                    |> step (N.TodayChanged tomorrow)
                    |> step N.NextDayClicked
                    |> step (N.NutritionDetailsLoaded today (Ok reportToday))
                    |> step N.NextDayClicked
                    |> step (N.NutritionDetailsLoaded tomorrow (Err Fixtures.unauthorized))
                    |> finish
                        (\( _, outMsg ) ->
                            outMsg |> Expect.equal N.SessionExpired
                        )
        ]



-- STORY PIPELINE


type alias Journey =
    Story.Journey N.Model N.OutMsg


step : N.Msg -> Journey -> Journey
step =
    Story.step (Story.ignoreCmd N.update)


finish :
    (( N.Model, N.OutMsg ) -> Expect.Expectation)
    -> Journey
    -> Expect.Expectation
finish =
    Story.finish


dateOf : N.Model -> LocalDate
dateOf model =
    case model of
        N.Loading context ->
            context.currentDate

        N.Loaded context _ _ ->
            context.currentDate

        N.Failed context _ ->
            context.currentDate



-- FIXTURES (copied)


today : LocalDate
today =
    Fixtures.date "2026-08-18"


yesterday : LocalDate
yesterday =
    Fixtures.date "2026-08-17"


tomorrow : LocalDate
tomorrow =
    Fixtures.date "2026-08-19"


reportToday : Details.NutritionDetails
reportToday =
    reportOn today 2


reportYesterday : Details.NutritionDetails
reportYesterday =
    reportOn yesterday 1


reportOn : LocalDate -> Int -> Details.NutritionDetails
reportOn reportDate loggedItems =
    { date = reportDate
    , reference = reference
    , loggedItems = loggedItems
    , nutrients = nutrients
    }


reference : Details.Reference
reference =
    { code = "US_DAILY"
    , name = "Daily values"
    , authority = "FDA"
    , jurisdiction = "US"
    , populationLabel = "Adults and children"
    , sourceUrl = "https://example.com/daily-values"
    }


nutrients : List Details.Nutrient
nutrients =
    [ nutrient "ENERGY_KCAL"
        "Energy"
        Details.Overview
        (Just 1800)
        "kcal"
        Nothing
        Details.Informational
        Details.Available
    , nutrient "FIBER_G"
        "Fiber"
        Details.Carbohydrates
        (Just 18)
        "g"
        (Just 30)
        Details.Adequacy
        Details.BelowReference
    , nutrient "SODIUM_MG"
        "Sodium"
        Details.Limits
        (Just 2900)
        "mg"
        (Just 2300)
        Details.Maximum
        Details.OverLimit
    ]


nutrient :
    String
    -> String
    -> Details.NutrientSection
    -> Maybe Float
    -> String
    -> Maybe Float
    -> Details.GuidanceKind
    -> Details.NutrientStatus
    -> Details.Nutrient
nutrient code name section knownAmount unit referenceAmount guidance status =
    { code = code
    , name = name
    , section = section
    , knownAmount = knownAmount
    , unit = unit
    , referenceAmount = referenceAmount
    , guidanceKind = guidance
    , itemsWithData = 2
    , coverage = Details.CompleteCoverage
    , status = status
    }
