module Page.NutritionDetailsTest exposing (tests)

{-| Nutrition-details stories.

Advice expansion, the paging ceiling, stale responses, and the page-level 401
check are steps inside the two flows rather than standalone branch tests.

-}

import Api.Client as Client
import Data.NutritionDetails as Details
import Data.Route exposing (Route(..))
import Expect
import I18n
import Lib.Date as LocalDate exposing (LocalDate)
import Page.NutritionDetails as N
import Set
import Support.Fixtures as Fixtures
import Test exposing (Test, describe, test)
import Translations.Ids exposing (TranslationId(..))


tests : Test
tests =
    describe "Page.NutritionDetails"
        [ test "advice toggles, days page, a stale response is ignored, and today clamps" <|
            \_ ->
                let
                    ( loading, initialOut ) =
                        N.init { date = today, today = today }

                    loaded : N.Model
                    loaded =
                        step (N.NutritionDetailsLoaded today (Ok reportToday))
                            loading

                    ( adviceOpen, _ ) =
                        stepOnce (N.NutrientAdviceToggled "FIBER_G") loaded

                    ( adviceClosed, adviceClosedOut ) =
                        stepOnce (N.NutrientAdviceToggled "FIBER_G")
                            adviceOpen

                    ( previous, previousOut ) =
                        stepOnce N.PreviousDayClicked adviceClosed

                    ( afterStale, staleOut ) =
                        stepOnce
                            (N.NutritionDetailsLoaded today (Ok reportToday))
                            previous

                    ( yesterdayLoaded, _ ) =
                        stepOnce
                            (N.NutritionDetailsLoaded
                                yesterday
                                (Ok reportYesterday)
                            )
                            afterStale

                    ( next, nextOut ) =
                        stepOnce N.NextDayClicked yesterdayLoaded

                    ( todayLoaded, _ ) =
                        stepOnce
                            (N.NutritionDetailsLoaded today (Ok reportToday))
                            next

                    ( clamped, clampOut ) =
                        stepOnce N.NextDayClicked todayLoaded
                in
                { initialOut = initialOut
                , loaded = toScreen loaded
                , advice = ( .advice <| toScreen adviceOpen, adviceClosedOut )
                , adviceClosed = toScreen adviceClosed
                , previousOut = previousOut
                , previousDate = (toScreen previous).date
                , staleOut = staleOut
                , staleUnchanged = toScreen afterStale == toScreen previous
                , yesterdayBanner = (toScreen yesterdayLoaded).banner
                , nextOut = nextOut
                , todayBanner = (toScreen todayLoaded).banner
                , clamp = ( clampOut, (toScreen clamped).date )
                }
                    |> Expect.equal
                        { initialOut = N.RequestNutritionDetails today
                        , loaded = loadedTodayScreen
                        , advice = ( [ fiberAdvice ], N.NoOp )
                        , adviceClosed = loadedTodayScreen
                        , previousOut =
                            N.Navigate (NutritionDetails (Just yesterday))
                        , previousDate = "2026-08-17"
                        , staleOut = N.NoOp
                        , staleUnchanged = True
                        , yesterdayBanner = Just oneItemBanner
                        , nextOut =
                            N.Navigate (NutritionDetails (Just today))
                        , todayBanner = Just twoItemBanner
                        , clamp = ( N.NoOp, "2026-08-18" )
                        }
        , test "a failed load recovers, TodayChanged lifts the ceiling, then 401 expires" <|
            \_ ->
                let
                    ( loading, initialOut ) =
                        N.init { date = today, today = today }

                    failed : N.Model
                    failed =
                        step
                            (N.NutritionDetailsLoaded
                                today
                                (Err Client.NetworkError)
                            )
                            loading

                    ( previous, previousOut ) =
                        stepOnce N.PreviousDayClicked failed

                    ( yesterdayLoaded, _ ) =
                        stepOnce
                            (N.NutritionDetailsLoaded
                                yesterday
                                (Ok reportYesterday)
                            )
                            previous

                    ( todayChanged, todayChangedOut ) =
                        stepOnce (N.TodayChanged tomorrow) yesterdayLoaded

                    ( next, nextOut ) =
                        stepOnce N.NextDayClicked todayChanged

                    ( todayLoaded, _ ) =
                        stepOnce
                            (N.NutritionDetailsLoaded today (Ok reportToday))
                            next

                    ( tomorrowDate, tomorrowOut ) =
                        stepOnce N.NextDayClicked todayLoaded

                    finalOut : N.OutMsg
                    finalOut =
                        stepOnce
                            (N.NutritionDetailsLoaded
                                tomorrow
                                (Err Fixtures.unauthorized)
                            )
                            tomorrowDate
                            |> Tuple.second
                in
                { initialOut = initialOut
                , failure = ( (toScreen failed).error, (toScreen failed).date )
                , previousOut = previousOut
                , yesterdayBanner = (toScreen yesterdayLoaded).banner
                , todayChanged = ( todayChangedOut, (toScreen todayChanged).date )
                , nextOut = nextOut
                , tomorrowOut = tomorrowOut
                , finalOut = finalOut
                }
                    |> Expect.equal
                        { initialOut = N.RequestNutritionDetails today
                        , failure = ( Just Fixtures.networkErrorMessage, "2026-08-18" )
                        , previousOut =
                            N.Navigate (NutritionDetails (Just yesterday))
                        , yesterdayBanner = Just oneItemBanner
                        , todayChanged = ( N.NoOp, "2026-08-17" )
                        , nextOut =
                            N.Navigate (NutritionDetails (Just today))
                        , tomorrowOut =
                            N.Navigate (NutritionDetails (Just tomorrow))
                        , finalOut = N.SessionExpired
                        }
        ]



-- SCREEN PROJECTION


type alias Screen =
    { date : String
    , banner : Maybe String
    , advice : List String
    , error : Maybe String
    }


toScreen : N.Model -> Screen
toScreen model =
    { date = LocalDate.format (dateOf model)
    , banner = bannerOf model
    , advice = adviceOf model
    , error =
        case model of
            N.Failed _ message ->
                Just message

            _ ->
                Nothing
    }


dateOf : N.Model -> LocalDate
dateOf model =
    case model of
        N.Loading context ->
            context.currentDate

        N.Loaded context _ _ ->
            context.currentDate

        N.Failed context _ ->
            context.currentDate


bannerOf : N.Model -> Maybe String
bannerOf model =
    case model of
        N.Loaded _ report _ ->
            Just
                (if report.loggedItems == 1 then
                    oneItemBanner

                 else
                    twoItemBanner
                )

        _ ->
            Nothing


adviceOf : N.Model -> List String
adviceOf model =
    case model of
        N.Loaded _ _ expanded ->
            if Set.isEmpty expanded then
                []

            else
                [ fiberAdvice ]

        _ ->
            []


loadedTodayScreen : Screen
loadedTodayScreen =
    { date = "2026-08-18", banner = Just twoItemBanner, advice = [], error = Nothing }



-- HELPERS


step :
    N.Msg
    -> N.Model
    -> N.Model
step msg model =
    Tuple.first (stepOnce msg model)


stepOnce :
    N.Msg
    -> N.Model
    -> ( N.Model, N.OutMsg )
stepOnce msg model =
    let
        ( next, _, outMsg ) =
            N.update msg model
    in
    ( next, outMsg )



-- FIXTURES


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


twoItemBanner : String
twoItemBanner =
    I18n.en (TidNutritionDetailsLoggedItemsIncludedOther "2")


oneItemBanner : String
oneItemBanner =
    I18n.en (TidNutritionDetailsLoggedItemsIncludedOne "1")


fiberAdvice : String
fiberAdvice =
    I18n.en TidNutritionDetailsAdviceFiber
