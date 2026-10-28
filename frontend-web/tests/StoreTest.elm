module StoreTest exposing (tests)

{-| Cache and request-token laws for `Store`.

Every law is fuzzed over the resource data it depends on (dates, logs, and
preference values) so a regression in keying or token bookkeeping cannot hide
behind one fixed fixture.

This is the allowed token/session exception: `Store` is a cross-page cache with
no page owner, so its stale-response and failure-caching laws stay at the state
layer instead of being duplicated in page stories.

-}

import Api.Client as Client exposing (ApiError)
import Api.Foods exposing (NutrientListResponse, UnitListResponse)
import Api.Logs exposing (LatestSlotsResponse)
import Data.DiaryPrefs exposing (DiaryPrefs)
import Data.FoodLog exposing (FoodLog)
import Data.Goals exposing (GoalSnapshot, GoalSource(..))
import Expect exposing (Expectation)
import Lib.Date as LocalDate exposing (LocalDate)
import Store exposing (Access, RequestToken, Store)
import Support.Fuzz as FuzzSupport
import Test exposing (Test, describe, fuzz, fuzz2)


tests : Test
tests =
    describe "Store"
        [ requestIsIssuedOnce
        , tokenGuardsSettlement
        , settleRejectsSupersededRequests
        , failedSettlementIsCached
        , resetInvalidatesEverything
        , clearDateKeyedFamilies
        , seedAndInvalidate
        , resourceKeysAreIndependent
        ]


requestIsIssuedOnce : Test
requestIsIssuedOnce =
    fuzz2 FuzzSupport.localDate
        FuzzSupport.foodLogList
        "a resource is requested once until its response settles"
        (\date logs ->
            let
                access : Access (List FoodLog)
                access =
                    Store.diaryLogsAt date
            in
            case Store.request access Store.empty of
                Nothing ->
                    Expect.fail "the first request should have been issued"

                Just ( inFlight, token ) ->
                    Expect.all
                        [ \_ ->
                            Store.cached access inFlight
                                |> Expect.equal Nothing
                        , \_ ->
                            Store.request access inFlight
                                |> Expect.equal Nothing
                        , \_ ->
                            case Store.settle access token (Ok logs) inFlight of
                                Nothing ->
                                    Expect.fail "the live token should settle"

                                Just settled ->
                                    Expect.all
                                        [ \_ ->
                                            Store.cached access settled
                                                |> Expect.equal (Just (Ok logs))
                                        , \_ ->
                                            Store.request access settled
                                                |> Expect.equal Nothing
                                        ]
                                        ()
                        ]
                        ()
        )


{-| Both halves of the token must match the live in-flight request: the request
id stops one resource's response settling another, and the generation stops a
response from before `reset` settling the reissued request with the same id.
-}
tokenGuardsSettlement : Test
tokenGuardsSettlement =
    fuzz2 FuzzSupport.interiorLocalDate
        FuzzSupport.foodLogList
        "a token settles only its own request id in the current generation"
        (\date logs ->
            let
                access : Access (List FoodLog)
                access =
                    Store.diaryLogsAt date

                secondAccess : Access (List FoodLog)
                secondAccess =
                    Store.diaryLogsAt (LocalDate.addDays 1 date)
            in
            case requestPair access secondAccess Store.empty of
                Nothing ->
                    Expect.fail "both independent requests should have been issued"

                Just ( bothInFlight, firstToken, secondToken ) ->
                    case Store.request access (Store.reset bothInFlight) of
                        Nothing ->
                            Expect.fail "the request after reset should have been issued"

                        Just ( afterReset, liveToken ) ->
                            Expect.all
                                [ \_ ->
                                    Store.settle secondAccess firstToken (Ok logs) bothInFlight
                                        |> Expect.equal Nothing
                                , \_ ->
                                    Store.settle access secondToken (Ok logs) bothInFlight
                                        |> Expect.equal Nothing
                                , \_ ->
                                    Store.settle access firstToken (Ok logs) afterReset
                                        |> Expect.equal Nothing
                                , \_ ->
                                    Store.settle access liveToken (Ok logs) afterReset
                                        |> Maybe.andThen (Store.cached access)
                                        |> Expect.equal (Just (Ok logs))
                                ]
                                ()
        )


{-| A failed settlement is a cached outcome like any other: it is exposed to
readers, blocks a duplicate request while cached, and is cleared by
`invalidate` so the user can retry.
-}
failedSettlementIsCached : Test
failedSettlementIsCached =
    fuzz FuzzSupport.localDate
        "a settled error is cached, blocks a second request, and invalidate retries"
        (\date ->
            let
                access : Access (List FoodLog)
                access =
                    Store.diaryLogsAt date

                failure : Result ApiError (List FoodLog)
                failure =
                    Err (Client.BadStatus 500 "server_error" "Server failed")
            in
            case Store.request access Store.empty of
                Nothing ->
                    Expect.fail "the first request should have been issued"

                Just ( inFlight, token ) ->
                    case Store.settle access token failure inFlight of
                        Nothing ->
                            Expect.fail "the live token should settle a failure"

                        Just settled ->
                            let
                                retryable : Store
                                retryable =
                                    Store.invalidate access settled
                            in
                            Expect.all
                                [ \_ ->
                                    Store.cached access settled
                                        |> Expect.equal (Just failure)
                                , \_ ->
                                    Store.request access settled
                                        |> Expect.equal Nothing
                                , \_ ->
                                    Store.cached access retryable
                                        |> Expect.equal Nothing
                                , \_ ->
                                    Store.request access retryable
                                        |> Maybe.map (always True)
                                        |> Expect.equal (Just True)
                                ]
                                ()
        )


{-| Once a request is no longer the live in-flight one, every later settle is a
no-op: a duplicate completion, an invalidated request, and a request whose
value was seeded by the caller.
-}
settleRejectsSupersededRequests : Test
settleRejectsSupersededRequests =
    fuzz2 FuzzSupport.localDate
        FuzzSupport.foodLogList
        "duplicate, invalidated, and seeded-superseded tokens settle nothing"
        (\date logs ->
            let
                access : Access (List FoodLog)
                access =
                    Store.diaryLogsAt date
            in
            case Store.request access Store.empty of
                Nothing ->
                    Expect.fail "the first request should have been issued"

                Just ( inFlight, token ) ->
                    case Store.settle access token (Ok logs) inFlight of
                        Nothing ->
                            Expect.fail "the live token should settle"

                        Just settled ->
                            let
                                invalidated : Store
                                invalidated =
                                    Store.invalidate access inFlight

                                seeded : Store
                                seeded =
                                    Store.seed access logs inFlight
                            in
                            [ ( "duplicate settle"
                              , Store.settle access token (Ok logs) settled
                              )
                            , ( "invalidated request"
                              , Store.settle access token (Ok logs) invalidated
                              )
                            , ( "seeded-superseded request"
                              , Store.settle access token (Ok logs) seeded
                              )
                            ]
                                |> List.map
                                    (\( label, outcome ) ->
                                        outcome |> Expect.equal Nothing |> Expect.onFail label
                                    )
                                |> expectAll
        )


resetInvalidatesEverything : Test
resetInvalidatesEverything =
    fuzz2 FuzzSupport.interiorLocalDate
        FuzzSupport.foodLogList
        "reset clears every cached resource family and rejects outstanding tokens"
        (\date logs ->
            let
                access : Access (List FoodLog)
                access =
                    Store.diaryLogsAt date

                otherAccess : Access (List FoodLog)
                otherAccess =
                    Store.diaryLogsAt (LocalDate.addDays 1 date)

                goalAccess : Access GoalSnapshot
                goalAccess =
                    Store.diaryGoalAt date

                slotsAccess : Access LatestSlotsResponse
                slotsAccess =
                    Store.latestSlotsAt date

                goalSnapshot : GoalSnapshot
                goalSnapshot =
                    goalValue date

                seeded : Store
                seeded =
                    Store.empty
                        |> Store.seed access logs
                        |> Store.seed otherAccess logs
                        |> Store.seed goalAccess goalSnapshot
                        |> Store.seed slotsAccess latestSlotsValue
                        |> Store.seed Store.prefs emptyPrefs
                        |> Store.seed Store.units unitsValue
                        |> Store.seed Store.nutrients nutrientsValue
            in
            case Store.request (Store.diaryLogsAt (LocalDate.addDays 2 date)) seeded of
                Nothing ->
                    Expect.fail "an unseeded date resource should be requestable"

                Just ( withOutstanding, token ) ->
                    let
                        resetStore : Store
                        resetStore =
                            Store.reset withOutstanding
                    in
                    Expect.all
                        [ \_ -> expectCached access logs withOutstanding
                        , \_ -> expectCached otherAccess logs withOutstanding
                        , \_ -> expectCached goalAccess goalSnapshot withOutstanding
                        , \_ -> expectCached slotsAccess latestSlotsValue withOutstanding
                        , \_ -> expectCached Store.prefs emptyPrefs withOutstanding
                        , \_ -> expectCached Store.units unitsValue withOutstanding
                        , \_ -> expectCached Store.nutrients nutrientsValue withOutstanding
                        , \_ -> Store.cached access resetStore |> Expect.equal Nothing
                        , \_ -> Store.cached otherAccess resetStore |> Expect.equal Nothing
                        , \_ -> Store.cached goalAccess resetStore |> Expect.equal Nothing
                        , \_ -> Store.cached slotsAccess resetStore |> Expect.equal Nothing
                        , \_ -> Store.cached Store.prefs resetStore |> Expect.equal Nothing
                        , \_ -> Store.cached Store.units resetStore |> Expect.equal Nothing
                        , \_ -> Store.cached Store.nutrients resetStore |> Expect.equal Nothing
                        , \_ ->
                            Store.settle access token (Ok logs) resetStore
                                |> Expect.equal Nothing
                        , \_ -> isRequestable access resetStore
                        , \_ -> isRequestable otherAccess resetStore
                        , \_ -> isRequestable goalAccess resetStore
                        , \_ -> isRequestable slotsAccess resetStore
                        , \_ -> isRequestable Store.prefs resetStore
                        , \_ -> isRequestable Store.units resetStore
                        , \_ -> isRequestable Store.nutrients resetStore
                        ]
                        ()
        )


{-| `clearGoals` and `clearLatestSlots` are the two date-keyed family clears:
each drops only its own family and leaves the other families, including the
same date key in another dictionary, intact.
-}
clearDateKeyedFamilies : Test
clearDateKeyedFamilies =
    fuzz2 FuzzSupport.interiorLocalDate
        FuzzSupport.foodLogList
        "clearGoals and clearLatestSlots remove only their own date-keyed family"
        (\date logs ->
            let
                goalAccess : Access GoalSnapshot
                goalAccess =
                    Store.diaryGoalAt date

                slotsAccess : Access LatestSlotsResponse
                slotsAccess =
                    Store.latestSlotsAt date

                logsAccess : Access (List FoodLog)
                logsAccess =
                    Store.diaryLogsAt date

                goalSnapshot : GoalSnapshot
                goalSnapshot =
                    goalValue date

                seeded : Store
                seeded =
                    Store.empty
                        |> Store.seed goalAccess goalSnapshot
                        |> Store.seed slotsAccess latestSlotsValue
                        |> Store.seed logsAccess logs
                        |> Store.seed Store.units unitsValue

                withoutGoals : Store
                withoutGoals =
                    Store.clearGoals seeded

                withoutSlots : Store
                withoutSlots =
                    Store.clearLatestSlots seeded
            in
            Expect.all
                [ \_ -> Store.cached goalAccess withoutGoals |> Expect.equal Nothing
                , \_ -> expectCached slotsAccess latestSlotsValue withoutGoals
                , \_ -> expectCached logsAccess logs withoutGoals
                , \_ -> expectCached Store.units unitsValue withoutGoals
                , \_ -> expectCached goalAccess goalSnapshot withoutSlots
                , \_ -> Store.cached slotsAccess withoutSlots |> Expect.equal Nothing
                , \_ -> expectCached logsAccess logs withoutSlots
                , \_ -> expectCached Store.units unitsValue withoutSlots
                ]
                ()
        )


seedAndInvalidate : Test
seedAndInvalidate =
    fuzz2 FuzzSupport.localDate
        FuzzSupport.foodLogList
        "seed exposes the value and invalidate makes the resource requestable again"
        (\date logs ->
            let
                access : Access (List FoodLog)
                access =
                    Store.diaryLogsAt date

                seeded : Store
                seeded =
                    Store.seed access logs Store.empty

                invalidated : Store
                invalidated =
                    Store.invalidate access seeded
            in
            Expect.all
                [ \_ -> Store.cached access seeded |> Expect.equal (Just (Ok logs))
                , \_ -> Store.cached access invalidated |> Expect.equal Nothing
                , \_ ->
                    Store.request access invalidated
                        |> Maybe.map (always True)
                        |> Expect.equal (Just True)
                ]
                ()
        )


{-| Date keys and different resource families live in separate entries, so a
settlement or invalidation of one must leave the others untouched.
-}
resourceKeysAreIndependent : Test
resourceKeysAreIndependent =
    fuzz2 FuzzSupport.interiorLocalDate
        FuzzSupport.foodLogList
        "independent date keys and resource families do not interfere"
        (\date logs ->
            let
                access : Access (List FoodLog)
                access =
                    Store.diaryLogsAt date

                otherDateAccess : Access (List FoodLog)
                otherDateAccess =
                    Store.diaryLogsAt (LocalDate.addDays 1 date)

                prefsValue : DiaryPrefs
                prefsValue =
                    { enabledMealSlots = [] }
            in
            case requestPair access otherDateAccess Store.empty of
                Nothing ->
                    Expect.fail "both independent requests should have been issued"

                Just ( bothInFlight, firstToken, secondToken ) ->
                    case Store.request Store.prefs bothInFlight of
                        Nothing ->
                            Expect.fail "the prefs request should have been issued"

                        Just ( allInFlight, _ ) ->
                            let
                                settledBoth : Maybe Store
                                settledBoth =
                                    Store.settle access firstToken (Ok logs) allInFlight
                                        |> Maybe.andThen
                                            (Store.settle otherDateAccess secondToken (Ok logs))
                            in
                            case settledBoth of
                                Nothing ->
                                    Expect.fail "both live tokens should settle"

                                Just settled ->
                                    let
                                        withPrefs : Store
                                        withPrefs =
                                            Store.seed Store.prefs prefsValue settled

                                        withoutFirst : Store
                                        withoutFirst =
                                            Store.invalidate access withPrefs
                                    in
                                    Expect.all
                                        [ \_ ->
                                            Store.cached access withPrefs
                                                |> Expect.equal (Just (Ok logs))
                                        , \_ ->
                                            Store.cached otherDateAccess withPrefs
                                                |> Expect.equal (Just (Ok logs))
                                        , \_ ->
                                            Store.cached Store.prefs withPrefs
                                                |> Expect.equal (Just (Ok prefsValue))
                                        , \_ ->
                                            Store.cached access withoutFirst
                                                |> Expect.equal Nothing
                                        , \_ ->
                                            Store.cached otherDateAccess withoutFirst
                                                |> Expect.equal (Just (Ok logs))
                                        , \_ ->
                                            Store.cached Store.prefs withoutFirst
                                                |> Expect.equal (Just (Ok prefsValue))
                                        ]
                                        ()
        )


requestPair : Access a -> Access b -> Store -> Maybe ( Store, RequestToken, RequestToken )
requestPair first second store =
    Store.request first store
        |> Maybe.andThen
            (\( afterFirst, firstToken ) ->
                Store.request second afterFirst
                    |> Maybe.map
                        (\( afterSecond, secondToken ) ->
                            ( afterSecond, firstToken, secondToken )
                        )
            )


expectAll : List Expectation -> Expectation
expectAll expectations =
    Expect.all (List.map (\expectation _ -> expectation) expectations) ()


goalValue : LocalDate -> GoalSnapshot
goalValue date =
    { requestedDate = date
    , effectiveFrom = Nothing
    , source = Default
    , targets =
        { calorieTarget = 0
        , proteinTargetG = 0
        , carbsTargetG = 0
        , fatTargetG = 0
        }
    }


emptyPrefs : DiaryPrefs
emptyPrefs =
    { enabledMealSlots = [] }


latestSlotsValue : LatestSlotsResponse
latestSlotsValue =
    { slots = [] }


unitsValue : UnitListResponse
unitsValue =
    { items = [] }


nutrientsValue : NutrientListResponse
nutrientsValue =
    { items = [] }


expectCached : Access a -> a -> Store -> Expectation
expectCached access value store =
    Store.cached access store
        |> Expect.equal (Just (Ok value))


isRequestable : Access a -> Store -> Expectation
isRequestable access store =
    Store.request access store
        |> Maybe.map (always True)
        |> Expect.equal (Just True)
