module Support.Fuzz exposing
    ( amountString
    , apiError
    , device
    , foodLogList
    , interiorLocalDate
    , invalidCanonicalDateStrings
    , localDate
    , maybeMealSlot
    , mealSlot
    , mealSlotList
    , monthBoundaryCases
    , monthPeriod
    , nonNegativeAmountString
    , route
    , segment
    , year
    )

import Api.Client exposing (ApiError(..))
import Data.FoodLog exposing (FoodLog, LogItem(..))
import Data.MealSlot as MealSlot exposing (MealSlot)
import Data.Nutrition as Nutrition
import Data.Route exposing (Route(..))
import Element exposing (DeviceClass(..), Orientation(..))
import Fuzz exposing (Fuzzer)
import Lib.Date as LocalDate exposing (LocalDate)


{-| Shared fuzzers for the frontend test suite.

`localDate` deliberately does not filter or fall back with `Maybe.withDefault`.
It builds a year, then a month, then a day whose upper bound comes from an
independent `daysInMonth` calendar, and finally converts through
`LocalDate.fromParts`. If production's calendar disagrees with that independent
calculation, the fuzzer becomes `Fuzz.invalid` with the offending date instead
of silently shrinking to `2000-01-01`.

`interiorLocalDate` is the same generator restricted to years 100..9900, so
adding or subtracting up to 60 days always stays inside the four-digit year
range accepted by `LocalDate.fromString`.

`invalidCanonicalDateStrings` uses the same independent calendar to build, for
a given year, canonical-shaped strings with an impossible month or day for every
month 1..12: day 00 and `daysInMonth + 1`, plus month 00 and month 13 with a
valid day.

`monthBoundaryCases` builds both directions of every month transition for a
given year, using the independent calendar. December of year 9999 is skipped
because its next transition is outside the four-digit year range.

Edge coverage comes from three layers: weighted year buckets (century rules and
the years 1..5 and 9995..9999), a month bucket that makes February about seven
times as likely as any other single month, and an explicit pool of month-end,
leap-day, and year-boundary dates. No `Fuzz.filter` retries are used, so a
rejection always means an intentional calendar disagreement rather than a
generator miss.

-}
localDate : Fuzzer LocalDate
localDate =
    Fuzz.frequency [ ( 2, arbitraryLocalDate ), ( 1, edgeCaseLocalDate ) ]


interiorLocalDate : Fuzzer LocalDate
interiorLocalDate =
    interiorYearFuzzer |> Fuzz.andThen dateInYear


year : Fuzzer Int
year =
    Fuzz.frequency
        [ ( 6, Fuzz.intRange 1 9999 )
        , ( 3, Fuzz.oneOfValues [ 1, 2, 3, 4, 5, 9995, 9996, 9997, 9998, 9999 ] )
        , ( 2, Fuzz.oneOfValues [ 100, 400, 1899, 1900, 1901, 1999, 2000, 2001, 2100, 2400 ] )
        ]


invalidCanonicalDateStrings : Int -> List String
invalidCanonicalDateStrings yearValue =
    List.concatMap
        (\month ->
            [ canonicalString yearValue month 0
            , canonicalString yearValue month (daysInMonth yearValue month + 1)
            ]
        )
        (List.range 1 12)
        ++ [ canonicalString yearValue 0 15, canonicalString yearValue 13 15 ]


monthBoundaryCases : Int -> List ( String, Int, String )
monthBoundaryCases yearValue =
    List.concatMap
        (\month ->
            let
                lastDay : Int
                lastDay =
                    daysInMonth yearValue month

                nextMonth : Int
                nextMonth =
                    if month == 12 then
                        1

                    else
                        month + 1

                nextYear : Int
                nextYear =
                    if month == 12 then
                        yearValue + 1

                    else
                        yearValue

                last : String
                last =
                    canonicalString yearValue month lastDay

                firstNext : String
                firstNext =
                    canonicalString nextYear nextMonth 1
            in
            if month == 12 && yearValue >= 9999 then
                []

            else
                [ ( last, 1, firstNext )
                , ( firstNext, -1, last )
                ]
        )
        (List.range 1 12)


canonicalString : Int -> Int -> Int -> String
canonicalString yearValue month day =
    pad4 yearValue ++ "-" ++ pad2 month ++ "-" ++ pad2 day


{-| A valid month period with a four-digit year. The year range leaves room for
every month-shift law used by the calendar tests without leaving the canonical
four-digit `YYYY-MM` shape.
-}
monthPeriod : Fuzzer String
monthPeriod =
    Fuzz.map2 (\yearValue month -> pad4 yearValue ++ "-" ++ pad2 month)
        (Fuzz.frequency
            [ ( 6, Fuzz.intRange 1000 9998 )
            , ( 2, Fuzz.oneOfValues [ 1000, 1900, 2000, 2100, 2400, 9998 ] )
            ]
        )
        (Fuzz.intRange 1 12)


mealSlot : Fuzzer MealSlot
mealSlot =
    Fuzz.oneOfValues MealSlot.all


maybeMealSlot : Fuzzer (Maybe MealSlot)
maybeMealSlot =
    Fuzz.oneOf [ Fuzz.constant Nothing, Fuzz.map Just mealSlot ]


mealSlotList : Fuzzer (List MealSlot)
mealSlotList =
    Fuzz.listOfLengthBetween 0 8 mealSlot


maybeLocalDate : Fuzzer (Maybe LocalDate)
maybeLocalDate =
    Fuzz.oneOf [ Fuzz.constant Nothing, Fuzz.map Just localDate ]


{-| Decimal strings, including blank, non-numeric, negative, zero, and large
finite values. `NaN` and `Infinity` are deliberately absent: the properties
that consume this fuzzer model finite amounts, and `safeAmount` has no defined
policy for non-finite input yet.
-}
amountString : Fuzzer String
amountString =
    Fuzz.oneOf
        [ Fuzz.constant ""
        , Fuzz.constant " "
        , Fuzz.constant "nope"
        , Fuzz.constant "-1"
        , Fuzz.constant "-0.5"
        , Fuzz.constant "0"
        , Fuzz.constant "100"
        , Fuzz.map String.fromFloat (Fuzz.floatRange -100000 100000)
        , Fuzz.map2
            (\whole fraction ->
                String.fromInt whole ++ "." ++ pad2 (modBy 100 fraction)
            )
            (Fuzz.intRange 0 100000)
            (Fuzz.intRange 0 99)
        ]


{-| Finite, non-negative decimal strings for arithmetic properties.
-}
nonNegativeAmountString : Fuzzer String
nonNegativeAmountString =
    Fuzz.oneOf
        [ Fuzz.constant "0"
        , Fuzz.constant "100"
        , Fuzz.map String.fromFloat (Fuzz.floatRange 0 100000)
        , Fuzz.map2
            (\whole fraction ->
                String.fromInt whole ++ "." ++ pad2 (modBy 100 fraction)
            )
            (Fuzz.intRange 0 10000)
            (Fuzz.intRange 0 99)
        ]


{-| A non-empty arbitrary URL path segment.

Backend IDs are UUID strings, so empty segments, `"."`, and `".."` are outside
the route-ID contract: no path encoding can survive browser dot-segment
normalization for those values. Everything else, including whitespace, slashes,
percent signs, and non-ASCII text, is in the pool so the route roundtrip proves
the encoder escapes dynamic IDs rather than assuming they are URL-safe. The
edge pool makes the reserved `new`/`custom` escapes and percent decoding
deterministic instead of relying on random strings.

`arbitrarySegment` always has a head character, so it cannot be empty. If its
raw value is exactly `"."` or `".."`, `avoidDotSegments` appends `"x"`; every
other value is unchanged. Filtering would retry and bias the generator, while
remapping changes only the two values a browser cannot carry through a URL.

-}
segment : Fuzzer String
segment =
    Fuzz.frequency [ ( 8, arbitrarySegment ), ( 1, Fuzz.oneOfValues edgeSegments ) ]


arbitrarySegment : Fuzzer String
arbitrarySegment =
    Fuzz.map2 (\head tail -> String.fromChar head ++ tail)
        Fuzz.char
        (Fuzz.map String.fromList (Fuzz.listOfLengthBetween 0 12 Fuzz.char))
        |> Fuzz.map avoidDotSegments


avoidDotSegments : String -> String
avoidDotSegments value =
    if value == "." || value == ".." then
        value ++ "x"

    else
        value


edgeSegments : List String
edgeSegments =
    [ "new"
    , "custom"
    , "new "
    , " custom"
    , "%"
    , "%2F"
    , "%41"
    , "100%"
    , "+"
    , " "
    , "/"
    , "?"
    , "#"
    , "a b"
    , "a/b"
    , "a?b"
    , "a#b"
    , "é"
    ]


route : Fuzzer Route
route =
    Fuzz.oneOf
        [ Fuzz.constant Root
        , Fuzz.constant BootstrapSetup
        , Fuzz.constant AuthLogin
        , Fuzz.constant AdminDashboard
        , Fuzz.constant AdminCreateUser
        , Fuzz.map AdminEditUser segment
        , Fuzz.map2 DiaryDay maybeLocalDate maybePeriod
        , Fuzz.map DiaryCalendar maybePeriod
        , Fuzz.map NutritionDetails maybeLocalDate
        , Fuzz.constant GoalSettings
        , Fuzz.constant DiarySettings
        , Fuzz.constant SettingsApiKeys
        , Fuzz.constant SettingsApiKeyCreate
        , Fuzz.map3 FoodLogEntry segment maybeLocalDate maybePeriod
        , Fuzz.map2 AdHocLogCreate maybeLocalDate maybeMealSlot
        , Fuzz.map2 AiLogCreate maybeLocalDate maybeMealSlot
        , Fuzz.map2 FoodSearch maybeLocalDate maybeMealSlot
        , Fuzz.map4 FoodShow segment maybeLocalDate maybeMealSlot maybeSegment
        , Fuzz.constant CustomFoodList
        , Fuzz.constant CustomFoodCreate
        , Fuzz.constant CustomFoodCreateWithAi
        , Fuzz.map CustomFoodEdit segment
        , Fuzz.map CustomFoodShow segment
        , Fuzz.constant MealList
        , Fuzz.constant MealCreate
        , Fuzz.map MealShow segment
        , Fuzz.map MealEdit segment
        ]


maybePeriod : Fuzzer (Maybe String)
maybePeriod =
    Fuzz.oneOf [ Fuzz.constant Nothing, Fuzz.map Just monthPeriod, Fuzz.map Just segment ]


maybeSegment : Fuzzer (Maybe String)
maybeSegment =
    Fuzz.oneOf [ Fuzz.constant Nothing, Fuzz.map Just segment ]


apiError : Fuzzer ApiError
apiError =
    Fuzz.oneOf
        [ Fuzz.constant BadUrl
        , Fuzz.constant Timeout
        , Fuzz.constant NetworkError
        , Fuzz.map3 BadStatus statusCode Fuzz.string Fuzz.string
        , Fuzz.map RateLimited
            (Fuzz.oneOf
                [ Fuzz.constant Nothing
                , Fuzz.map Just (Fuzz.intRange 0 3600)
                ]
            )
        , Fuzz.constant BadBody
        ]


statusCode : Fuzzer Int
statusCode =
    Fuzz.frequency [ ( 2, Fuzz.oneOfValues [ 401, 403, 429 ] ), ( 3, Fuzz.intRange 100 599 ) ]


deviceClass : Fuzzer DeviceClass
deviceClass =
    Fuzz.oneOfValues [ Phone, Tablet, Desktop, BigDesktop ]


device : Fuzzer Element.Device
device =
    Fuzz.map2 (\class orientation -> { class = class, orientation = orientation })
        deviceClass
        (Fuzz.oneOfValues [ Portrait, Landscape ])


foodLogList : Fuzzer (List FoodLog)
foodLogList =
    Fuzz.listOfLengthBetween 0 10 foodLog


{-| A food log whose date, slot, item shape, quantity, nutrients, and notes are
all arbitrary. Filter properties use this rather than hand-built records so a
regression in any bucket field is exercised.
-}
foodLog : Fuzzer FoodLog
foodLog =
    Fuzz.map2 (\base notes -> { base | notes = notes })
        baseFoodLog
        (Fuzz.oneOf [ Fuzz.constant Nothing, Fuzz.map Just segment ])


baseFoodLog : Fuzzer FoodLog
baseFoodLog =
    Fuzz.map7
        (\id logDate deviceTimezone mealSlotValue item quantityValue nutrients ->
            { id = id
            , logDate = logDate
            , deviceTimezone = deviceTimezone
            , mealSlot = mealSlotValue
            , item = item
            , quantity = quantityValue
            , nutrients = nutrients
            , notes = Nothing
            }
        )
        (Fuzz.map (\value -> "log-" ++ String.fromInt value) (Fuzz.intRange 0 100000))
        localDate
        (Fuzz.oneOf [ Fuzz.constant Nothing, Fuzz.map Just segment ])
        maybeMealSlot
        logItem
        quantity
        (Fuzz.listOfLengthBetween 0 5 nutrientAmount)


logItem : Fuzzer LogItem
logItem =
    Fuzz.oneOf
        [ Fuzz.map3
            (\id name brand -> ProductLogItem { id = id, name = name, brand = brand })
            segment
            segment
            maybeSegment
        , Fuzz.map2 (\id name -> MealLogItem { id = id, name = name }) segment segment
        , Fuzz.map2 (\name brand -> AdHocLogItem { name = name, brand = brand })
            segment
            maybeSegment
        ]


quantity : Fuzzer Nutrition.Quantity
quantity =
    Fuzz.map2 (\amount unit -> { amount = amount, unit = unit }) nonNegativeAmountString segment


nutrientAmount : Fuzzer Nutrition.NutrientAmount
nutrientAmount =
    Fuzz.map3 (\code amount unit -> { code = code, amount = amount, unit = unit })
        segment
        amountString
        segment


arbitraryLocalDate : Fuzzer LocalDate
arbitraryLocalDate =
    year |> Fuzz.andThen dateInYear


dateInYear : Int -> Fuzzer LocalDate
dateInYear yearValue =
    monthFuzzer
        |> Fuzz.andThen
            (\month ->
                Fuzz.intRange 1 (daysInMonth yearValue month)
                    |> Fuzz.andThen (expectLocalDate yearValue month)
            )


edgeCaseLocalDate : Fuzzer LocalDate
edgeCaseLocalDate =
    Fuzz.oneOfValues edgeCaseParts
        |> Fuzz.andThen
            (\( yearValue, month, day ) ->
                expectLocalDate yearValue month day
            )


edgeCaseParts : List ( Int, Int, Int )
edgeCaseParts =
    [ ( 2024, 1, 31 )
    , ( 2024, 2, 28 )
    , ( 2024, 2, 29 )
    , ( 2023, 2, 28 )
    , ( 2000, 2, 29 )
    , ( 1900, 2, 28 )
    , ( 2024, 3, 1 )
    , ( 2024, 12, 31 )
    , ( 1, 1, 1 )
    , ( 1, 12, 31 )
    , ( 9999, 1, 1 )
    , ( 9999, 12, 31 )
    , ( 100, 2, 28 )
    , ( 400, 2, 29 )
    ]


interiorYearFuzzer : Fuzzer Int
interiorYearFuzzer =
    Fuzz.frequency
        [ ( 6, Fuzz.intRange 100 9900 )
        , ( 2
          , Fuzz.oneOfValues
                [ 100, 101, 400, 1899, 1900, 2000, 2001, 2400, 9899, 9900 ]
          )
        ]


monthFuzzer : Fuzzer Int
monthFuzzer =
    Fuzz.frequency [ ( 4, Fuzz.intRange 1 12 ), ( 2, Fuzz.constant 2 ) ]


expectLocalDate : Int -> Int -> Int -> Fuzzer LocalDate
expectLocalDate yearValue month day =
    if day < 1 || day > daysInMonth yearValue month then
        Fuzz.invalid (invalidMessage "independent calendar rejects" yearValue month day)

    else
        case LocalDate.fromParts yearValue month day of
            Just date ->
                Fuzz.constant date

            Nothing ->
                Fuzz.invalid (invalidMessage "LocalDate.fromParts rejects" yearValue month day)


invalidMessage : String -> Int -> Int -> Int -> String
invalidMessage reason yearValue month day =
    "Support.Fuzz: "
        ++ reason
        ++ " "
        ++ String.fromInt yearValue
        ++ "-"
        ++ pad2 month
        ++ "-"
        ++ pad2 day


pad2 : Int -> String
pad2 value =
    if value < 10 then
        "0" ++ String.fromInt value

    else
        String.fromInt value


pad4 : Int -> String
pad4 value =
    let
        raw : String
        raw =
            String.fromInt value
    in
    String.repeat (max 0 (4 - String.length raw)) "0" ++ raw


daysInMonth : Int -> Int -> Int
daysInMonth yearValue month =
    case month of
        1 ->
            31

        2 ->
            if isLeapYear yearValue then
                29

            else
                28

        3 ->
            31

        4 ->
            30

        5 ->
            31

        6 ->
            30

        7 ->
            31

        8 ->
            31

        9 ->
            30

        10 ->
            31

        11 ->
            30

        12 ->
            31

        _ ->
            0


isLeapYear : Int -> Bool
isLeapYear yearValue =
    (modBy 4 yearValue == 0 && modBy 100 yearValue /= 0) || modBy 400 yearValue == 0
