module StoreTest exposing (tests)

import Data.FoodLog exposing (FoodLog)
import Expect
import Lib.Date as LocalDate exposing (LocalDate)
import Store exposing (Store)
import Test exposing (Test, describe, test)
import Time


tests : Test
tests =
    describe "Store"
        [ describe "request"
            [ test "issues a request for a resource nothing has asked for" <|
                \_ ->
                    Store.request logsForDay Store.empty
                        |> Maybe.map (always True)
                        |> Expect.equal (Just True)
            , test "declines a second request while the first is in flight" <|
                \_ ->
                    case Store.request logsForDay Store.empty of
                        Nothing ->
                            Expect.fail "the first request should have been issued"

                        Just ( inFlight, _ ) ->
                            Store.request logsForDay inFlight
                                |> Expect.equal Nothing
            , test "declines a request for a resource already settled" <|
                \_ ->
                    Store.request logsForDay (Store.seed logsForDay [] Store.empty)
                        |> Expect.equal Nothing
            , test "keys date resources independently" <|
                \_ ->
                    case Store.request logsForDay Store.empty of
                        Nothing ->
                            Expect.fail "the first request should have been issued"

                        Just ( inFlight, _ ) ->
                            Store.request (Store.diaryLogsAt otherDay) inFlight
                                |> Expect.notEqual Nothing
            ]
        , describe "settle"
            [ test "records the result against the token it was issued" <|
                \_ ->
                    case Store.request logsForDay Store.empty of
                        Nothing ->
                            Expect.fail "the request should have been issued"

                        Just ( inFlight, token ) ->
                            Store.settle logsForDay token (Ok []) inFlight
                                |> Maybe.andThen (Store.cached logsForDay)
                                |> Expect.equal (Just (Ok []))
            , test "rejects a token from a previous session even when its request id repeats" <|
                \_ ->
                    -- reset restarts request ids, so the only thing separating
                    -- the stale token from the live one is its generation.
                    case sessionsWithRepeatedRequestId of
                        Nothing ->
                            Expect.fail "both requests should have been issued"

                        Just ( store, staleToken, _ ) ->
                            Store.settle logsForDay staleToken (Ok []) store
                                |> Expect.equal Nothing
            , test "accepts the token of the current session's request" <|
                \_ ->
                    case sessionsWithRepeatedRequestId of
                        Nothing ->
                            Expect.fail "both requests should have been issued"

                        Just ( store, _, liveToken ) ->
                            Store.settle logsForDay liveToken (Ok []) store
                                |> Maybe.andThen (Store.cached logsForDay)
                                |> Expect.equal (Just (Ok []))
            , test "rejects a token whose request an invalidation superseded" <|
                \_ ->
                    case Store.request logsForDay Store.empty of
                        Nothing ->
                            Expect.fail "the request should have been issued"

                        Just ( inFlight, token ) ->
                            Store.settle logsForDay
                                token
                                (Ok [])
                                (Store.invalidate logsForDay inFlight)
                                |> Expect.equal Nothing
            , test "rejects a token whose request a seeded value superseded" <|
                \_ ->
                    case Store.request logsForDay Store.empty of
                        Nothing ->
                            Expect.fail "the request should have been issued"

                        Just ( inFlight, token ) ->
                            Store.settle logsForDay
                                token
                                (Ok [])
                                (Store.seed logsForDay [] inFlight)
                                |> Expect.equal Nothing
            , test "rejects a duplicate of a response already settled" <|
                \_ ->
                    case Store.request logsForDay Store.empty of
                        Nothing ->
                            Expect.fail "the request should have been issued"

                        Just ( inFlight, token ) ->
                            Store.settle logsForDay token (Ok []) inFlight
                                |> Maybe.andThen (Store.settle logsForDay token (Ok []))
                                |> Expect.equal Nothing
            ]
        , describe "cached"
            [ test "reports nothing while a request is in flight" <|
                \_ ->
                    case Store.request logsForDay Store.empty of
                        Nothing ->
                            Expect.fail "the request should have been issued"

                        Just ( inFlight, _ ) ->
                            Store.cached logsForDay inFlight
                                |> Expect.equal Nothing
            , test "reports a session-scoped resource once seeded" <|
                \_ ->
                    Store.empty
                        |> Store.seed Store.units { items = [] }
                        |> Store.cached Store.units
                        |> Expect.equal (Just (Ok { items = [] }))
            ]
        , describe "reset"
            [ test "drops cached data from the previous session" <|
                \_ ->
                    Store.empty
                        |> Store.seed logsForDay []
                        |> Store.seed Store.units { items = [] }
                        |> Store.reset
                        |> Expect.all
                            [ Store.cached logsForDay >> Expect.equal Nothing
                            , Store.cached Store.units >> Expect.equal Nothing
                            ]
            ]
        ]


{-| Two sessions whose tokens carry the same request id, so that only the
generation separates the stale token from the live one.
-}
sessionsWithRepeatedRequestId : Maybe ( Store, Store.RequestToken, Store.RequestToken )
sessionsWithRepeatedRequestId =
    Store.request logsForDay Store.empty
        |> Maybe.andThen
            (\( firstSession, staleToken ) ->
                Store.request logsForDay (Store.reset firstSession)
                    |> Maybe.map
                        (\( secondSession, liveToken ) ->
                            ( secondSession, staleToken, liveToken )
                        )
            )


logsForDay : Store.Access (List FoodLog)
logsForDay =
    Store.diaryLogsAt (date "2026-08-18")


otherDay : LocalDate
otherDay =
    date "2026-08-17"


date : String -> LocalDate
date raw =
    case LocalDate.fromString raw of
        Just value ->
            value

        Nothing ->
            LocalDate.fromPosix Time.utc (Time.millisToPosix 0)
